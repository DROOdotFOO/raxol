defmodule Raxol.Harness.EditorSession do
  @moduledoc """
  The THIN impure runner for the composer's external-editor handoff:
  drives `Raxol.Harness.EditorSuspend`'s pure state machine and
  interprets each step against the real device / stty / reader gate /
  editor process. All sequencing, ordering, and failure-recovery policy
  lives in the pure machine; this module only performs effects.

  ## The spawn mechanism (why a Port with `:nouse_stdio`)

  The editor must own the REAL tty. `System.cmd/3` can never provide
  that -- its child's stdio is a pipe pair back to the BEAM. A
  `Port.open({:spawn, cmd}, [:nouse_stdio, :exit_status])` moves the
  port's own pipe protocol to fds 3/4, so the child INHERITS the BEAM's
  fds 0/1/2 -- the terminal itself. This is byte-for-byte the mechanism
  OTP's own shell uses for its open-in-editor feature (`user_drv`'s
  Ctrl+O path: `disable_reader` -> `open_port(..., [nouse_stdio])` ->
  reload on port exit -> `enable_reader`), so the approach is
  OTP-sanctioned, not novel. `{:spawn, string}` goes through `/bin/sh`,
  which buys two things: `$EDITOR` values carrying arguments
  (`"code -w"`) work unmodified, and a missing editor binary surfaces
  as the shell's exit status 127 -- mapped here to a keep-the-draft
  `{:editor_not_found, cmd}` outcome instead of a crash. The temp-file
  path is single-quote shell-escaped before it joins the command line.

  The `:spawn_fun` seam is `(shell_command :: String.t()) ->
  non_neg_integer() | :crashed | :timeout` -- synchronous, returning the
  editor's exit status (`:crashed` when the port died without ever
  delivering one; `:timeout` when `:editor_timeout_ms` elapsed first).
  The default implementation is the Port described above.

  The default `:editor_timeout_ms` is `:infinity` -- an interactive
  human legitimately edits for arbitrary time on their own tty and can
  always quit the editor themselves. This deliberately leaves
  NON-interactive embedders (automation, agents, CI harnesses driving a
  pty) unprotected against a wedged editor by default: such embedders
  MUST set a bound (via this option, or the host's `:editor_opts` —
  the retired `Raxol.Harness.Surface` forwarded one), or a never-exiting
  editor blocks the calling loop forever.

  ## Outcomes

    * `{:ok, %{text: edited, width: w, rows: h, degraded: [...]}}` --
      editor exited 0 and the temp file read back; `text` is the
      decoded draft (`EditorSuspend.decode_draft/1`).
    * `{:kept, reason, %{width: w, rows: h, degraded: [...]}}` -- the
      terminal was suspended and RESUMED, but the draft is kept
      unchanged: `:editor_nonzero` | `{:editor_not_found, cmd}` |
      `:editor_crashed` | `:editor_timeout` | `:reload_failed`.
    * `{:error, {:reader_disable, reason}}` / `{:error, {step, reason}}`
      -- a step failed before the handoff completed; the machine's
      compensation ran, so the terminal is back in a recoverable state.
      In particular a reader-disable failure aborts BEFORE any byte
      touches the device: never hand the tty to an editor while the
      BEAM reader still competes for its keystrokes.

  `degraded` is the machine's `EditorSuspend.degradations/1` list --
  `[]` on a clean run. A non-empty list (today: `{:enable_reader,
  reason}` when the stdin reader failed to re-enable after the editor)
  means the run COMPLETED but keyboard input may be dead; the failure
  also emits `[:raxol, :harness, :editor, :reader_enable_failed]`
  telemetry with `%{reason: reason}` metadata. Callers MUST surface a
  non-empty `degraded` to the operator (Surface renders a footer
  warning) -- it is never safe to show the edited draft as if nothing
  happened while the tty cannot type.

  A step that RAISES (rather than returning an error) still runs the
  machine's `recovery/1` compensation first, then the exception
  propagates unchanged -- callers that must not crash (the harness UI
  loop) wrap their call; the terminal is already restored by the time
  the exception reaches them either way. The temp file is additionally
  removed in a `try/after`, so no path -- including the raise path --
  leaks it.

  ## Draft confidentiality (the temp file is a secret)

  A composer draft can contain anything the operator types -- API keys,
  private text. It is therefore never written bare into the shared
  tmp dir: each run creates a fresh per-run subdirectory chmod'd `0700`
  (unreadable to other local users regardless of file modes or umask),
  with an unpredictable `:crypto.strong_rand_bytes`-suffixed name, and
  the draft file inside it is created by `write_draft_file/2` with
  `[:exclusive]` (`O_CREAT | O_EXCL` -- creation FAILS on any
  pre-existing path, and per POSIX the final path component is never
  followed as a symlink under `O_EXCL`, so a pre-planted symlink cannot
  redirect the write) and chmod'd `0600`. Cleanup removes the whole
  per-run directory on every path.

  ## Trust boundary: `$VISUAL`/`$EDITOR` is the operator's own shell config

  The editor command is interpolated into a `/bin/sh` command line
  UNVALIDATED, by design -- the same contract git, crontab, and OTP's
  own shell honor (all of them sh-execute `$EDITOR`, precisely so
  values like `"code -w"` or `emacsclient -a ""` work; a metacharacter
  allowlist would break real configurations while defending a boundary
  that does not exist here). It is safe under exactly one assumption:
  the process environment is the SAME trust domain as the operator's
  shell -- whoever set `$EDITOR` could already run commands as this
  user. The draft content itself never reaches the shell (only the
  quoted generated path does). Embedders that expose the harness across
  a privilege boundary where the environment is attacker-influenceable
  (SSH `AcceptEnv`/`ForceCommand` setups, sudo `env_keep`, a service
  manager injecting env) MUST NOT pass the ambient environment through
  -- inject a vetted `:env` explicitly instead.

  ## What this module deliberately does NOT do

  It never writes DECSTBM region bytes. The machine's
  `:reassert_region` step is interpreted as a no-op HERE because region
  emission is owned by the paint authority
  (`Raxol.UI.Rendering.PaintAuthority.InlineAuthority.reassert/1` over
  its `ScrollRegionManager` state -- the single-DECSTBM-owner rule): the
  caller that owns the authority (the retired `Raxol.Harness.Surface`'s
  edit-draft dispatch) composes `resize |> reassert` on EVERY return from this
  function -- ok, kept, or error -- so the pin is guaranteed
  belt-and-braces regardless of where a failure landed. Geometry is
  re-queried here (while still cooked, before re-entering raw mode) and
  returned so that caller re-pins at the terminal's CURRENT size.

  Every injectable seam has a real default: `:stty` (module),
  `:reader_gate` (module), `:reader` (pid), `:env`, `:tmp_dir`,
  `:spawn_fun`, `:size_fun`, `:device`. Tests drive the full sequence
  with fakes and a StringIO device; the real tty is never touched by
  the suite.
  """

  alias Raxol.Harness.EditorSuspend
  alias Raxol.Terminal.InlineDriver.ReaderGate
  alias Raxol.Terminal.InlineDriver.Sequences

  @type outcome ::
          {:ok,
           %{
             text: String.t(),
             width: pos_integer(),
             rows: pos_integer(),
             degraded: [{EditorSuspend.step(), term()}]
           }}
          | {:kept, term(),
             %{
               width: pos_integer(),
               rows: pos_integer(),
               degraded: [{EditorSuspend.step(), term()}]
             }}
          | {:error, {atom(), term()}}

  @spec run(String.t(), keyword()) :: outcome()
  def run(draft, opts) when is_binary(draft) and is_list(opts) do
    rows = Keyword.fetch!(opts, :rows)
    stty = Keyword.get(opts, :stty, Raxol.Terminal.Driver.Stty)

    {:ok, editor} =
      opts
      |> Keyword.get_lazy(:env, fn -> System.get_env() end)
      |> EditorSuspend.resolve_editor()

    # A fresh, unpredictably-named per-run directory (see the moduledoc's
    # confidentiality section) -- created 0700 by :write_tmp, removed
    # whole by :cleanup_tmp / the `after` below.
    dir =
      opts
      |> Keyword.get_lazy(:tmp_dir, &System.tmp_dir!/0)
      |> Path.join("raxol_editor_" <> unique())

    editor_timeout = Keyword.get(opts, :editor_timeout_ms, :infinity)

    ctx = %{
      draft: draft,
      editor: editor,
      dir: dir,
      path: Path.join(dir, EditorSuspend.tmp_filename(unique())),
      cmd: nil,
      device: Keyword.get(opts, :device, :stdio),
      rows: rows,
      width: Keyword.get(opts, :width, 80),
      stty: stty,
      gate: Keyword.get(opts, :reader_gate, ReaderGate),
      reader:
        Keyword.get_lazy(opts, :reader, fn ->
          Process.whereis(:user_drv_reader)
        end),
      spawn_fun:
        Keyword.get(opts, :spawn_fun, fn cmd ->
          default_spawn(cmd, editor_timeout)
        end),
      size_fun: Keyword.get(opts, :size_fun, fn -> stty.size() end),
      exit_status: nil,
      outcome: nil
    }

    try do
      drive(EditorSuspend.new(), ctx)
    after
      # Belt-and-braces: the machine's own :cleanup_tmp (happy path) or
      # compensation (failure path) already removes the directory; this
      # `after` guarantees it even on the raise path. Removing an
      # already-removed directory is a harmless no-op.
      _ = File.rm_rf(dir)
    end
  end

  @doc false
  # The exclusive-create draft write, exposed for the security suite:
  # `[:exclusive]` = O_CREAT|O_EXCL, so a pre-existing path (including a
  # pre-planted symlink -- O_EXCL never follows the final component) is
  # refused with {:error, :eexist} instead of truncated/redirected. The
  # file is chmod'd 0600 after the write; its 0700 parent directory is
  # what actually confines the content window in between.
  @spec write_draft_file(Path.t(), binary()) :: :ok | {:error, term()}
  def write_draft_file(path, content) do
    with {:ok, io} <- :file.open(path, [:write, :exclusive, :binary, :raw]),
         :ok <- :file.write(io, content),
         :ok <- :file.close(io) do
      File.chmod(path, 0o600)
    end
  end

  # -- the machine loop --------------------------------------------------

  defp drive(machine, ctx, event \\ :ok) do
    case EditorSuspend.advance(machine, event) do
      {:done, machine} ->
        finish(ctx, machine)

      {:effect, step, machine} ->
        run_step(step, machine, ctx)
    end
  end

  # A raise inside a step still runs the machine's compensation (the
  # `recovery/1` rescue seam) before propagating unchanged -- the
  # terminal must be recoverable even when the failure is an exception,
  # not an error return.
  defp run_step(step, machine, ctx) do
    interpret(step, ctx)
  rescue
    error ->
      Enum.each(EditorSuspend.recovery(machine), &compensate(&1, ctx))
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      Enum.each(EditorSuspend.recovery(machine), &compensate(&1, ctx))
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    {:ok, ctx} ->
      drive(machine, ctx, :ok)

    {:degraded, reason} ->
      # The step failed but must not abort (today: :enable_reader) --
      # the machine records it so `finish/2` reports it; interpret/2
      # already emitted the telemetry.
      drive(machine, ctx, {:degraded, reason})

    {:error, reason} ->
      {:abort, compensation, _machine} =
        EditorSuspend.advance(machine, {:error, reason})

      Enum.each(compensation, &compensate(&1, ctx))
      {:error, {error_tag(step), reason}}
  end

  defp finish(%{outcome: nil} = ctx, machine) do
    {:ok,
     %{
       text: ctx.text,
       width: ctx.width,
       rows: ctx.rows,
       degraded: EditorSuspend.degradations(machine)
     }}
  end

  defp finish(%{outcome: {:kept, reason}} = ctx, machine) do
    {:kept, reason,
     %{
       width: ctx.width,
       rows: ctx.rows,
       degraded: EditorSuspend.degradations(machine)
     }}
  end

  # The one step whose public error tag differs from its machine name:
  # callers see the RESOURCE that failed (the reader gate), not the
  # machine-internal step atom.
  defp error_tag(:disable_reader), do: :reader_disable
  defp error_tag(step), do: step

  # -- step interpretation ----------------------------------------------

  defp interpret(:write_tmp, ctx) do
    # 0700 per-run dir FIRST (the confinement), then the exclusive-create
    # 0600 draft file inside it -- see the moduledoc's confidentiality
    # section. The mkdir itself is fresh-named (strong-random suffix), so
    # an existing path here is already suspicious and refused.
    with :ok <- File.mkdir(ctx.dir),
         :ok <- File.chmod(ctx.dir, 0o700),
         :ok <-
           write_draft_file(ctx.path, EditorSuspend.encode_draft(ctx.draft)) do
      {:ok, ctx}
    end
  end

  defp interpret(:disable_reader, ctx) do
    # A disable failure ABORTS the suspend: never hand the tty to an
    # editor while the BEAM reader still competes for its bytes.
    case ctx.gate.disable(ctx.reader) do
      :ok -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interpret(:release_screen, ctx) do
    IO.write(ctx.device, Sequences.suspend_bytes(ctx.rows))
    {:ok, ctx}
  end

  defp interpret(:restore_tty, ctx) do
    # `restore(nil)` falls through to `stty sane` -- the canonical cooked
    # baseline. The pre-raw snapshot belongs to the InlineDriver (it
    # restores it at final teardown); this bracket only needs sane modes
    # for the editor to start from.
    ctx.stty.restore(nil)
    {:ok, ctx}
  end

  defp interpret(:spawn_editor, ctx) do
    # Pure bookkeeping: assemble the shell command. The synchronous
    # handoff itself happens at :await_editor -- keeping the two steps
    # distinct preserves the machine's step vocabulary even though the
    # default spawn is blocking.
    {:ok, %{ctx | cmd: ctx.editor <> " " <> shell_quote(ctx.path)}}
  end

  defp interpret(:await_editor, ctx) do
    {:ok, %{ctx | exit_status: ctx.spawn_fun.(ctx.cmd)}}
  end

  defp interpret(:requery_size, ctx) do
    case ctx.size_fun.() do
      {:ok, cols, rows} when is_integer(cols) and is_integer(rows) ->
        {:ok, %{ctx | width: cols, rows: rows}}

      _other ->
        # No honest answer -- keep the geometry the caller passed in.
        {:ok, ctx}
    end
  end

  defp interpret(:raw_tty, ctx) do
    ctx.stty.raw!()
    {:ok, ctx}
  end

  defp interpret(:enable_reader, ctx) do
    # An enable failure leaves input degraded but must not abort a
    # resume that is already half-done -- and it must NEVER be silent:
    # the {:degraded, reason} report is recorded by the machine, carried
    # on the outcome for the caller to surface, and telemetry-emitted
    # here (review finding: the old `_ = enable(...)` swallow reported
    # a permanently-deaf tty as a clean {:ok, text}).
    case ctx.gate.enable(ctx.reader) do
      :ok ->
        {:ok, ctx}

      {:error, reason} ->
        :telemetry.execute(
          [:raxol, :harness, :editor, :reader_enable_failed],
          %{},
          %{reason: reason}
        )

        {:degraded, reason}
    end
  end

  defp interpret(:reinit_modes, ctx) do
    IO.write(ctx.device, Sequences.init_bytes())
    {:ok, ctx}
  end

  defp interpret(:reassert_region, ctx) do
    # Deliberate no-op HERE: region bytes are owned by the paint
    # authority; the caller composes `resize |> reassert` on every
    # return (see the moduledoc's "does NOT do" section).
    {:ok, ctx}
  end

  defp interpret(:reload_draft, %{exit_status: 0} = ctx) do
    case File.read(ctx.path) do
      {:ok, content} ->
        {:ok, Map.put(ctx, :text, EditorSuspend.decode_draft(content))}

      {:error, _posix} ->
        {:ok, %{ctx | outcome: {:kept, :reload_failed}}}
    end
  end

  defp interpret(:reload_draft, %{exit_status: 127} = ctx),
    do: {:ok, %{ctx | outcome: {:kept, {:editor_not_found, ctx.editor}}}}

  defp interpret(:reload_draft, %{exit_status: :crashed} = ctx),
    do: {:ok, %{ctx | outcome: {:kept, :editor_crashed}}}

  defp interpret(:reload_draft, %{exit_status: :timeout} = ctx),
    do: {:ok, %{ctx | outcome: {:kept, :editor_timeout}}}

  defp interpret(:reload_draft, ctx),
    do: {:ok, %{ctx | outcome: {:kept, :editor_nonzero}}}

  defp interpret(:cleanup_tmp, ctx) do
    _ = File.rm_rf(ctx.dir)
    {:ok, ctx}
  end

  # -- compensation interpretation ---------------------------------------

  defp compensate(:raw_tty, ctx), do: ctx.stty.raw!()
  defp compensate(:enable_reader, ctx), do: ctx.gate.enable(ctx.reader)

  defp compensate(:reinit_modes, ctx),
    do: IO.write(ctx.device, Sequences.init_bytes())

  # Region bytes stay with the authority owner -- same rationale as the
  # forward step; the caller reasserts on every return.
  defp compensate(:reassert_region, _ctx), do: :ok
  defp compensate(:cleanup_tmp, ctx), do: File.rm_rf(ctx.dir)

  # -- the real spawn ----------------------------------------------------

  # Synchronous: opens the port (the editor now owns fds 0/1/2 -- the
  # tty) and blocks until it delivers an exit status. `:crashed` when
  # the port dies without one; `:timeout` when `:editor_timeout_ms`
  # elapses first (default `:infinity` -- a human legitimately edits for
  # an arbitrary time on their own tty and can always quit the editor
  # themselves; the bound exists for embedders/automation, threaded
  # through Surface's `:editor_opts`). On timeout the editor process is
  # best-effort SIGTERMed and the port closed before returning, so the
  # resume bracket does not race a still-writing editor.
  defp default_spawn(cmd, timeout) do
    port = Port.open({:spawn, cmd}, [:nouse_stdio, :exit_status])
    ref = Port.monitor(port)

    receive do
      {^port, {:exit_status, status}} ->
        Port.demonitor(ref, [:flush])
        status

      {:DOWN, ^ref, :port, ^port, _reason} ->
        :crashed
    after
      timeout ->
        kill_editor(port, ref)
        :timeout
    end
  end

  defp kill_editor(port, ref) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        _ =
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)],
            stderr_to_stdout: true
          )

      _no_pid ->
        :ok
    end

    Port.demonitor(ref, [:flush])

    if Port.info(port), do: Port.close(port)

    # Drain a raced exit_status: the editor may have exited in the window
    # between the timeout firing and the close above, leaving a stray
    # `{port, {:exit_status, _}}` in THIS process's mailbox -- which is
    # the harness dispatcher/TEA-loop process, where an unmatched message
    # would sit forever (round-2 review). Zero-timeout receive: gone if
    # present, free if not.
    receive do
      {^port, {:exit_status, _late}} -> :ok
    after
      0 -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Single-quote wrapping with the canonical '\'' escape -- the tmp path
  # is generated (safe characters only), but quote it anyway: `{:spawn,
  # string}` goes through /bin/sh.
  defp shell_quote(path),
    do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  # Counter + timestamp for uniqueness/debuggability, PLUS a
  # :crypto.strong_rand_bytes segment for unpredictability -- the
  # confidentiality section's claim, honored in code (round-2 review
  # caught the doc promising crypto randomness the old counter+timestamp
  # name did not deliver). 6 bytes -> 8 url-safe base64 chars.
  defp unique do
    random =
      6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    "#{:erlang.unique_integer([:positive, :monotonic])}_#{System.os_time(:microsecond)}_#{random}"
  end
end
