defmodule Raxol.Harness.EditorSuspend do
  @moduledoc """
  The PURE side of the composer's external-editor handoff: editor
  resolution policy, the draft round-trip discipline, the temp-file
  naming policy, and -- the load-bearing part -- the suspend/resume
  state machine with per-step compensation.

  No IO, no processes, no tty anywhere in this module. The thin impure
  runner (`Raxol.Harness.EditorSession`) drives this machine and
  interprets each emitted step against the real device/stty/reader;
  keeping the sequencing HERE means the ordering and the
  failure-recovery table are plain data, exhaustively testable with a
  ledger fold instead of a mocked terminal.

  ## The step sequence (pinned, order is load-bearing)

  Suspend bracket:

    1. `:write_tmp` -- persist the draft first: the cheapest step, and
       failing it unwinds nothing.
    2. `:disable_reader` -- quiesce the BEAM's tty reader
       (`Raxol.Terminal.InlineDriver.ReaderGate`) BEFORE any terminal
       bytes: from this point typed keystrokes queue in the kernel for
       the editor instead of being split between two readers. It is also
       the most failure-prone step, and failing here still unwinds
       nothing terminal-visible.
    3. `:release_screen` -- the canonical suspend bytes
       (`Raxol.Terminal.InlineDriver.Sequences.suspend_bytes/1`: modes
       off, `CSI r`, autowrap+cursor, bare park). MUST run while the tty
       is still raw, else the escapes are line-processed as garbage --
       the same invariant the teardown order pins.
    4. `:restore_tty` -- cooked modes, LAST among the terminal
       operations: the editor needs sane modes to start from (a
       line-based `$EDITOR` would be unusable raw, and Ctrl-C must work
       if it wedges before installing its own termios).
    5. `:spawn_editor` / `:await_editor` -- the synchronous handoff.

  Resume bracket:

    6. `:requery_size` -- while still cooked: the terminal may have been
       resized while the editor owned it.
    7. `:raw_tty` -- before the reader is re-enabled, so no cooked-mode
       echo race on queued typing.
    8. `:enable_reader` -- the gate reopens; the reader's armed state
       persisted across the bracket.
    9. `:reinit_modes` -- `Sequences.init_bytes/0` (bracketed paste +
       focus reporting back on; the suspend's modes-off turned them off).
   10. `:reassert_region` -- the UNCONDITIONAL DECSTBM re-pin
       (`InlineAuthority.reassert/1`; a geometry-gated resize alone would
       skip the write when nothing changed).
   11. `:reload_draft` -- read the temp file back (exit-status policy is
       the runner's concern; this machine only sequences).
   12. `:cleanup_tmp` -- always last, every path.

  ## Compensation (what is restorable at each failure point)

  Each step's effect on the externally observable resources is a ledger
  transition over `{tty, reader, screen, modes, tmp}`. `advance/2` with
  `{:error, reason}` (and `recovery/1`, the runner's rescue seam)
  derives the compensation from the ledger, emitted in the safe resume
  order: `:raw_tty`, `:enable_reader`, `:reinit_modes`,
  `:reassert_region`, `:cleanup_tmp` (each included only when the
  ledger actually deviates). By construction, completed-steps ++
  compensation always folds back to the invariant
  `{raw, enabled, asserted, on, absent}` -- the exhaustive test in
  `editor_suspend_test.exs` pins exactly that, over every failure point.

  ### Worst-case assumption for suspend-phase failures

  A FAILED suspend-phase step (`:write_tmp`, `:disable_reader`,
  `:release_screen`, `:restore_tty`) is folded into the ledger AS IF its
  effects landed: a failed `File.write` may have created the file
  (ENOSPC after create), a raising `IO.write` may have emitted part of
  its bytes, a timed-out stty/gate call may have taken effect with the
  reply lost. Compensating effects that never happened is harmless
  (every compensation is idempotent toward the invariant -- an enable
  against a never-disabled reader is ignored and times out, a re-raw of
  an already-raw tty is a no-op); NOT compensating effects that DID
  happen strands the terminal. Resume-phase steps get the opposite
  assumption -- a failed `:raw_tty`/`:reinit_modes` is NOT done, so
  compensation retries it.

  ### Degradable steps: `:enable_reader`

  `:enable_reader` is the one step whose failure must NOT abort: the
  resume is already half-done, and finishing it (modes, region, draft
  reload) with degraded input beats stranding the terminal mid-resume.
  The runner reports it via `advance(machine, {:degraded, reason})`:
  the machine continues to the next step but records the degradation --
  the ledger keeps `reader: :disabled` (a degraded enable is honestly
  NOT an enable, so a later failure's compensation retries the reader),
  and `degradations/1` exposes the list so the runner/caller MUST
  surface it (notice + telemetry) instead of a silent `{:ok, ...}`.
  A `{:degraded, _}` report on any non-degradable step raises: it is a
  programmer error, not a policy choice.

  ## Draft round-trip discipline

  `encode_draft/1` is the identity -- the draft is written verbatim.
  `decode_draft/1` strips exactly ONE trailing line terminator (`\\r\\n`
  or `\\n`), nothing else: POSIX editors append exactly one trailing
  newline to a saved file, so stripping one restores the draft
  byte-for-byte for any draft not itself ending in a newline (composer
  drafts never do -- Enter submits). Mirrors the OTP shell editor's
  `string:chomp` choice.
  """

  @type step ::
          :write_tmp
          | :disable_reader
          | :release_screen
          | :restore_tty
          | :spawn_editor
          | :await_editor
          | :requery_size
          | :raw_tty
          | :enable_reader
          | :reinit_modes
          | :reassert_region
          | :reload_draft
          | :cleanup_tmp

  @type completion :: {step(), :ok | {:degraded, term()}}
  @type machine :: %{completed: [completion()], pending: step() | nil}

  @steps [
    :write_tmp,
    :disable_reader,
    :release_screen,
    :restore_tty,
    :spawn_editor,
    :await_editor,
    :requery_size,
    :raw_tty,
    :enable_reader,
    :reinit_modes,
    :reassert_region,
    :reload_draft,
    :cleanup_tmp
  ]

  # Compensation steps in the safe resume order: tty raw first (no
  # cooked-echo race), then the reader, then modes/region bytes, tmp
  # cleanup always last.
  @recovery_order [
    :raw_tty,
    :enable_reader,
    :reinit_modes,
    :reassert_region,
    :cleanup_tmp
  ]

  # Suspend-phase steps whose FAILURE is folded into the ledger as if
  # their effects landed (worst case) -- see the moduledoc's
  # "Worst-case assumption" section.
  @assume_done_on_failure [
    :write_tmp,
    :disable_reader,
    :release_screen,
    :restore_tty
  ]

  # Steps whose failure may be reported as {:degraded, reason} instead of
  # {:error, reason} -- see the moduledoc's "Degradable steps" section.
  @degradable [:enable_reader]

  @initial_ledger %{
    tty: :raw,
    reader: :enabled,
    screen: :asserted,
    modes: :on,
    tmp: :absent
  }

  # -- policy -----------------------------------------------------------

  @doc """
  `$VISUAL` || `$EDITOR` || `"vi"` -- first NON-EMPTY wins (an
  empty-string export is treated as unset, not as an editor named "").
  Always succeeds: the fallback exists by policy; a missing binary
  surfaces later as the shell's exit 127, which the runner maps to a
  keep-the-draft notice rather than a crash.
  """
  @spec resolve_editor(%{optional(String.t()) => String.t()}) ::
          {:ok, String.t()}
  def resolve_editor(env) when is_map(env) do
    editor =
      [Map.get(env, "VISUAL"), Map.get(env, "EDITOR"), "vi"]
      |> Enum.find(fn value -> is_binary(value) and value != "" end)

    {:ok, editor}
  end

  @doc "Draft -> file content: the identity (written verbatim)."
  @spec encode_draft(String.t()) :: String.t()
  def encode_draft(draft) when is_binary(draft), do: draft

  @doc """
  File content -> draft: strips exactly one trailing `\\r\\n` or `\\n`
  (see the moduledoc's round-trip discipline). Everything else is
  preserved byte-for-byte.
  """
  @spec decode_draft(binary()) :: String.t()
  def decode_draft(content) when is_binary(content) do
    cond do
      String.ends_with?(content, "\r\n") ->
        binary_part(content, 0, byte_size(content) - 2)

      String.ends_with?(content, "\n") ->
        binary_part(content, 0, byte_size(content) - 1)

      true ->
        content
    end
  end

  @doc "Pure temp-file naming policy; the runner joins it to the tmpdir."
  @spec tmp_filename(String.t()) :: String.t()
  def tmp_filename(unique) when is_binary(unique),
    do: "raxol_draft_#{unique}.md"

  # -- the machine ------------------------------------------------------

  @doc "The canonical ordered step list (see the moduledoc)."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc "A fresh machine: nothing completed, nothing pending."
  @spec new() :: machine()
  def new, do: %{completed: [], pending: nil}

  @doc """
  Report the outcome of the pending step and receive the next effect.

    * `advance(machine, :ok)` -- the pending step (if any) completed;
      returns `{:effect, next_step, machine}` with the next step now
      pending, or `{:done, machine}` when the sequence is exhausted.
    * `advance(machine, {:degraded, reason})` -- the pending step is a
      DEGRADABLE step (`:enable_reader`) whose work failed but whose
      failure must not abort the resume: the machine continues exactly
      like `:ok` but RECORDS the degradation (`degradations/1`), and the
      ledger keeps the resource un-repaired so a later failure's
      compensation retries it. Raises `ArgumentError` on a
      non-degradable step (programmer error, not policy).
    * `advance(machine, {:error, reason})` -- the pending step FAILED;
      returns `{:abort, compensation, machine}` where `compensation`
      covers the completed steps PLUS, for a suspend-phase pending step,
      the worst-case assumption that its effects landed (see the
      moduledoc), in the safe resume order.
  """
  @spec advance(machine(), :ok | {:degraded, term()} | {:error, term()}) ::
          {:effect, step(), machine()}
          | {:done, machine()}
          | {:abort, [step()], machine()}
  def advance(%{completed: completed, pending: pending}, :ok) do
    completed = if pending, do: completed ++ [{pending, :ok}], else: completed
    continue(completed)
  end

  def advance(%{completed: completed, pending: pending}, {:degraded, reason})
      when pending in @degradable do
    continue(completed ++ [{pending, {:degraded, reason}}])
  end

  def advance(%{pending: pending}, {:degraded, _reason}) do
    raise ArgumentError,
          "step #{inspect(pending)} is not degradable -- only " <>
            "#{inspect(@degradable)} may report {:degraded, reason}; " <>
            "a failure here must be {:error, reason} (abort + compensation)"
  end

  def advance(
        %{completed: completed, pending: pending} = machine,
        {:error, _reason}
      ) do
    {:abort, compensation(completed, pending), %{machine | pending: nil}}
  end

  @doc """
  The compensation the abort path would take from this machine's
  position -- the runner's rescue seam: on an EXCEPTION mid-step (rather
  than an error return), the runner interprets exactly these steps
  before surfacing the failure. Identical to what
  `advance(machine, {:error, _})` would return.
  """
  @spec recovery(machine()) :: [step()]
  def recovery(%{completed: completed, pending: pending}),
    do: compensation(completed, pending)

  @doc """
  Every degradation recorded so far, as `{step, reason}` in step order.
  A non-empty list at `:done` means the run COMPLETED but a resource
  could not be restored (today: the stdin reader after the editor) --
  the runner must surface this to the operator, never swallow it.
  """
  @spec degradations(machine()) :: [{step(), term()}]
  def degradations(%{completed: completed}) do
    for {step, {:degraded, reason}} <- completed, do: {step, reason}
  end

  # -- private ----------------------------------------------------------

  defp continue(completed) do
    case Enum.at(@steps, length(completed)) do
      nil -> {:done, %{completed: completed, pending: nil}}
      step -> {:effect, step, %{completed: completed, pending: step}}
    end
  end

  # Derive compensation from the ledger: fold the completed work (a
  # degraded completion contributes NO effect -- the resource was not
  # repaired) plus, for a suspend-phase pending step that failed, the
  # worst-case assumption that its effects landed. Include each recovery
  # step (in @recovery_order) only when the resource it repairs actually
  # deviates from the invariant.
  defp compensation(completed, pending) do
    assumed =
      if pending in @assume_done_on_failure, do: [{pending, :ok}], else: []

    ledger =
      Enum.reduce(
        completed ++ assumed,
        @initial_ledger,
        &apply_completion(&2, &1)
      )

    Enum.filter(@recovery_order, fn
      :raw_tty -> ledger.tty != :raw
      :enable_reader -> ledger.reader != :enabled
      :reinit_modes -> ledger.modes != :on
      :reassert_region -> ledger.screen != :asserted
      :cleanup_tmp -> ledger.tmp != :absent
    end)
  end

  # A step that completed :ok applies its ledger transition; a DEGRADED
  # completion applies none -- the resource it was meant to repair is
  # honestly still broken (see the moduledoc's degradable-steps section).
  defp apply_completion(ledger, {step, :ok}), do: apply_step(ledger, step)
  defp apply_completion(ledger, {_step, {:degraded, _reason}}), do: ledger

  # The resource-ledger transition table -- one clause per step (and the
  # compensation steps reuse the same vocabulary, so a compensated
  # prefix folds back to the invariant with the same function).
  defp apply_step(ledger, :write_tmp), do: %{ledger | tmp: :present}
  defp apply_step(ledger, :disable_reader), do: %{ledger | reader: :disabled}

  defp apply_step(ledger, :release_screen),
    do: %{ledger | screen: :released, modes: :off}

  defp apply_step(ledger, :restore_tty), do: %{ledger | tty: :cooked}
  defp apply_step(ledger, :spawn_editor), do: ledger
  defp apply_step(ledger, :await_editor), do: ledger
  defp apply_step(ledger, :requery_size), do: ledger
  defp apply_step(ledger, :raw_tty), do: %{ledger | tty: :raw}
  defp apply_step(ledger, :enable_reader), do: %{ledger | reader: :enabled}
  defp apply_step(ledger, :reinit_modes), do: %{ledger | modes: :on}
  defp apply_step(ledger, :reassert_region), do: %{ledger | screen: :asserted}
  defp apply_step(ledger, :reload_draft), do: ledger
  defp apply_step(ledger, :cleanup_tmp), do: %{ledger | tmp: :absent}
end
