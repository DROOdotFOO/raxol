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
  message (verified against OTP kernel `prim_tty.erl`'s `reader_loop/2`):
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
  """

  @default_timeout_ms 2_000

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
  defp call(reader, msg, timeout) do
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
end
