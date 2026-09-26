# Real-pty fixture for the full-screen `Raxol.Terminal.Driver`. Runs INSIDE a
# pty (tmux/expect) via `Raxol.Terminal.PtyHarness`, NOT as a unit test.
#
# Same file protocol as input_canary_app.exs: once the Driver is up it writes
# `<out>.ready` with what it can see, collects CANARY_N key events, writes one
# token per line to $CANARY_OUT, and halts.
#
# The Driver skips all terminal setup while MIX_ENV is "test"
# (`Raxol.Terminal.Env.test?/0`), and the harness boots this from the test
# build, so the variable is cleared before the Driver starts: the point is its
# real TTY branch.
System.delete_env("MIX_ENV")

defmodule FullscreenIsigApp do
  alias Raxol.Core.Events.Event

  def run do
    out = System.get_env("CANARY_OUT") || raise "CANARY_OUT not set"
    n = String.to_integer(System.get_env("CANARY_N") || "1")

    {:ok, _driver} = Raxol.Terminal.Driver.start_link(dispatcher_pid: self())

    # The live flags once init has returned, which is what a ^C meets.
    File.write!(
      out <> ".ready",
      "otp=#{System.otp_release()} isig_off=#{Raxol.Terminal.Driver.Stty.isig_off?()}"
    )

    tokens = collect(n, [])
    File.write!(out, Enum.join(tokens, "\n"))

    # Exit at once so the pty closes; the terminal is the harness's to discard.
    System.halt(0)
  end

  defp collect(n, acc) when length(acc) >= n, do: Enum.reverse(acc)

  defp collect(n, acc) do
    receive do
      {:"$gen_cast", {:dispatch, %Event{type: :key, data: data}}} ->
        collect(n, [token(data) | acc])

      _ ->
        collect(n, acc)
    after
      4000 -> Enum.reverse(acc)
    end
  end

  # Byte 0x03 parses to `%{ctrl: true, char: "c"}`, the same char a bare `c`
  # produces, so ctrl chords are prefixed.
  defp token(%{ctrl: true} = data), do: "ctrl-" <> to_string(data[:char] || data[:key])
  defp token(data), do: to_string(data[:char] || data[:key])
end

FullscreenIsigApp.run()
