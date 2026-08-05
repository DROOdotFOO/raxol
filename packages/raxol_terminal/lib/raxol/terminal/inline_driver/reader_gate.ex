defmodule Raxol.Terminal.InlineDriver.ReaderGate do
  @moduledoc """
  Quiesce/resume the BEAM's prim_tty stdin reader, so an external
  process (an `$EDITOR` handed the tty by the harness composer) is not
  robbed of keystrokes while it owns the terminal.

  ## The problem this closes

  `Raxol.Terminal.InlineDriver` arms the prim_tty reader process
  (registered as `:user_drv_reader`) with a standing `{:read, :infinity}`
  and traces its sends -- that is how raw keystrokes reach the inline
  input path at all. But the reader holds an outstanding read on the
  SAME tty an editor would read from: with both readers live, the kernel
  splits typed bytes between them arbitrarily, and the editor sees only
  a random subset of what the user types. The reader must be disabled
  for the duration of the handoff, and re-enabled on resume.

  ## The protocol (OTP's own, not an invention)

  This is byte-for-byte the wire protocol `:prim_tty.disable_reader/1` /
  `:prim_tty.enable_reader/1` speak to the reader process -- the exact
  mechanism OTP's own shell uses for its open-in-editor feature (Ctrl+O
  in `erl`; see `user_drv:open_editor/2` in the kernel application). We
  cannot call `:prim_tty` directly because its `state()` record lives
  inside `user_drv`'s gen_statem state, so this module speaks the
  reader's message protocol against the registered pid instead -- the
  same coupling `InlineDriver.start_stdin_reader/0` already accepts by
  sending `{:read, :infinity}` raw.

  The call shape is an alias-monitor request:
  `ref = monitor(process, reader, alias: :reply_demonitor)`, send
  `{ref, :disable | :enable}`, await `{ref, reply}`. While disabled the
  reader blocks in a selective receive waiting ONLY for the enable
  message (verified against OTP kernel `prim_tty.erl`'s reader loop):
  it consumes no tty bytes, so kernel input queues for the editor. Its
  armed `{:read, :infinity}` state and the erlang trace flag both
  persist across the disable/enable bracket (same process, state map
  retained), so no re-arm is needed on resume.

  ## Failure semantics

    * `nil` reader (headless, piped stdin, `install_reader?: false`) --
      `:ok`, a documented no-op: there is nothing reading the tty, so
      there is nothing to gate.
    * Reply timeout -- `{:error, :timeout}`. A `disable/2` timeout must
      ABORT the suspend (never hand the tty to an editor while the BEAM
      reader still competes for its bytes); an `enable/2` timeout leaves
      input degraded but is survivable (the caller may notify rather
      than crash).
    * Reader died -- `{:error, {:reader_down, reason}}`.

  There is one accepted race, the same one OTP accepts: a keystroke
  arriving in the instant before the disable is processed may already
  have been consumed by the reader. The window is a single scheduler
  hop; the byte is delivered to the harness (which is mid-suspend and
  ignores it) rather than lost to the kernel.

  ## Version coupling: pinned range and the drift failure mode

  This wire protocol is OTP-private. Tested/verified range: **OTP 26
  through 29** (prim_tty itself first shipped the reader in OTP 26).
  The reader loop was rewritten in OTP 28 -- `reader_loop/6` on OTP
  26/27, `reader_loop/2` on 28+ -- but the disable/enable branch this
  module speaks survived that rewrite unchanged, which is what makes
  one implementation correct across the whole range. Below the floor,
  `disable/2`/`enable/2` refuse with `{:error, {:unsupported_otp,
  release}}` rather than sending a message whose receiver semantics
  were never verified.

  If a FUTURE OTP changes the reader's message shape, the failure mode
  is fail-closed by construction, not silent corruption: the gate's
  call times out (`{:error, :timeout}`, bounded), and the one caller
  that matters treats a disable failure as ABORT-the-suspend -- the tty
  is never handed to an editor with the gate in an unknown state. What
  becomes of the unmatched message differs by release and neither case
  weakens that: OTP 28+ has a catch-all clause that discards it, while
  OTP 26/27 has none, so it simply sits in the reader's mailbox. The
  gate sends at most one message per call, so that is a bounded
  remainder, not a leak. Bumping the pinned range above is a deliberate
  act: re-read `prim_tty.erl`'s reader loop for the new release (the
  OTP 28 rewrite is the precedent for how much can move) and extend the
  ceiling in this doc; the protocol suite (`reader_gate_test.exs`,
  scripted readers) pins the wire shape this module SPEAKS, and the pty
  round-trip test exercises it against the REAL reader.
  """

  @default_timeout_ms 2_000
  @min_otp 26

  @spec disable(pid() | nil, timeout()) :: :ok | {:error, term()}
  def disable(reader \\ Process.whereis(:user_drv_reader), timeout \\ @default_timeout_ms)

  def disable(nil, _timeout), do: :ok

  def disable(reader, timeout) when is_pid(reader),
    do: call(reader, :disable, timeout)

  @spec enable(pid() | nil, timeout()) :: :ok | {:error, term()}
  def enable(reader \\ Process.whereis(:user_drv_reader), timeout \\ @default_timeout_ms)

  def enable(nil, _timeout), do: :ok

  def enable(reader, timeout) when is_pid(reader),
    do: call(reader, :enable, timeout)

  # The alias-monitor request/reply OTP's prim_tty `call/2` uses: the
  # alias doubles as the reply address and auto-demonitors on reply
  # (`:reply_demonitor`), so no stale DOWN can arrive after a success.
  # Refuses below the verified OTP floor rather than speaking an
  # unverified protocol (see the moduledoc's version-coupling section).
  defp call(reader, msg, timeout) do
    release = otp_release()

    if release < @min_otp do
      {:error, {:unsupported_otp, release}}
    else
      do_call(reader, msg, timeout)
    end
  end

  defp do_call(reader, msg, timeout) do
    ref = :erlang.monitor(:process, reader, alias: :reply_demonitor)
    send(reader, {ref, msg})

    receive do
      {^ref, _reply} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:reader_down, reason}}
    after
      timeout ->
        :erlang.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp otp_release do
    :otp_release |> :erlang.system_info() |> List.to_integer()
  rescue
    # A non-numeric release string (never seen in practice) reads as
    # "unknown, too old" -- refusing is the safe direction.
    _ -> 0
  end
end
