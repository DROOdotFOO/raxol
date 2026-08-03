# Real-pty input canary app. Runs INSIDE a pty (tmux/expect), NOT as a unit test.
#
# It arms the real InlineDriver stdin reader (the prim_tty trace path), collects
# CANARY_N decoded key events, and writes one token per line to $CANARY_OUT. The
# driving test then asserts on that file. This is the ONLY code permitted to
# claim prim_tty protocol coverage: it exercises the actual reader + re-arm loop
# against real keystrokes, so it fails if OTP moves the private protocol.
defmodule InputCanaryApp do
  def run do
    out = System.get_env("CANARY_OUT") || raise "CANARY_OUT not set"
    n = String.to_integer(System.get_env("CANARY_N") || "2")

    {:ok, _pid} =
      Raxol.Terminal.InlineDriver.start_link(
        device: :standard_io,
        subscriber: self(),
        tty?: true,
        stty_enabled?: true,
        install_reader?: true,
        probe?: false
      )

    # Signal that the reader is armed, so the driver sends keystrokes only after
    # the pty is ready to receive them (avoids a send-before-listen race).
    File.write!(out <> ".ready", "ok")

    tokens = collect(n, [])
    File.write!(out, Enum.join(tokens, "\n"))
    # Exit immediately so the pty closes and the driving test's `eof`/output wait
    # returns at once instead of blocking on a slow BEAM/mix shutdown.
    System.halt(0)
  end

  defp collect(n, acc) when length(acc) >= n, do: Enum.reverse(acc)

  defp collect(n, acc) do
    receive do
      {:inline_input, %Raxol.Core.Events.Event{type: :key, data: data}} ->
        token = to_string(data[:char] || data[:key])
        collect(n, [token | acc])

      _ ->
        collect(n, acc)
    after
      4000 -> Enum.reverse(acc)
    end
  end
end

InputCanaryApp.run()
