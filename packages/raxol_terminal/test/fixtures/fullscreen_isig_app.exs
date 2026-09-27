# Real-pty fixture for the full-screen `Raxol.Terminal.Driver`. Runs INSIDE a
# pty (tmux/expect) via `Raxol.Terminal.PtyHarness`, NOT as a unit test.
#
# Same file protocol as input_canary_app.exs: once the Driver is up it writes
# `<out>.ready` with what it can see, collects CANARY_N tokens, writes one per
# line to $CANARY_OUT, and halts. This process stands in for both the
# Dispatcher (key events) and the runtime, and like an app that does not bind
# Ctrl+C it never quits on one: a `:quit_runtime` from the Driver is recorded
# as the token `quit`.
#
# With CANARY_SIGCONT=1 the VM is stopped and continued before `.ready`, as
# `kill -STOP` and `kill -CONT` from another terminal would.
#
# The Driver skips all terminal setup while MIX_ENV is "test"
# (`Raxol.Terminal.Env.test?/0`), and the harness boots this from the test
# build, so the variable is cleared before the Driver starts: the point is its
# real TTY branch.
System.delete_env("MIX_ENV")

defmodule FullscreenIsigApp do
  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Driver.Stty

  def run do
    out = System.get_env("CANARY_OUT") || raise "CANARY_OUT not set"
    n = String.to_integer(System.get_env("CANARY_N") || "1")

    {:ok, _driver} =
      Raxol.Terminal.Driver.start_link(dispatcher_pid: self(), runtime_pid: self())

    sigcont = if System.get_env("CANARY_SIGCONT") == "1", do: stop_and_continue()

    # The live flags once init (and any SIGCONT) is behind us, which is what a
    # ^C meets.
    File.write!(
      out <> ".ready",
      "otp=#{System.otp_release()} isig_off=#{Stty.isig_off?()} sigcont=#{sigcont}"
    )

    tokens = collect(n, [])
    File.write!(out, Enum.join(tokens, "\n"))

    # Exit at once so the pty closes; the terminal is the harness's to discard.
    System.halt(0)
  end

  # prim_tty writes its own termios, ISIG on, again on SIGCONT. Returns
  # `:settled` once the live flags show `-isig` on three reads in a row, or
  # `:unsettled` when they never do.
  defp stop_and_continue do
    pid = System.pid()
    {_, 0} = System.cmd("sh", ["-c", "kill -STOP #{pid}; kill -CONT #{pid}"])
    settle_isig_off(60, 0)
  end

  defp settle_isig_off(_tries, 3), do: :settled
  defp settle_isig_off(0, _in_a_row), do: :unsettled

  defp settle_isig_off(tries, in_a_row) do
    in_a_row = if Stty.isig_off?(), do: in_a_row + 1, else: 0
    Process.sleep(50)
    settle_isig_off(tries - 1, in_a_row)
  end

  defp collect(n, acc) when length(acc) >= n, do: Enum.reverse(acc)

  defp collect(n, acc) do
    receive do
      {:"$gen_cast", {:dispatch, %Event{type: :key, data: data}}} ->
        collect(n, [token(data) | acc])

      :quit_runtime ->
        collect(n, ["quit" | acc])

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
