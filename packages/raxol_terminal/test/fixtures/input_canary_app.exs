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

    {:ok, pid} =
      Raxol.Terminal.InlineDriver.start_link(
        device: :standard_io,
        subscriber: self(),
        tty?: true,
        stty_enabled?: true,
        install_reader?: true,
        probe?: false
      )

    # Signal readiness -- and say what was actually established, not just that
    # start_link returned. The driving test cannot see into this VM, so when it
    # ends up with no keystrokes this file is the only evidence of whether the
    # reader was armed and whether the tty was actually in raw mode. Without it
    # a missed keystroke and a moved OTP protocol look identical.
    File.write!(out <> ".ready", diagnostics(pid))

    tokens = collect(n, [])
    File.write!(out, Enum.join(tokens, "\n"))

    # Exit immediately so the pty closes and the driving test's `eof`/output wait
    # returns at once instead of blocking on a slow BEAM/mix shutdown.
    System.halt(0)
  end

  # What this VM can see about its own input path, as one greppable line.
  defp diagnostics(pid) do
    "otp=#{System.otp_release()} reader=#{reader_status()} raw=#{raw_status(pid)}"
  end

  # Is the prim_tty reader actually being traced? `start_stdin_reader/1` only
  # traces `:user_drv_reader` `if reader` -- when the process is not registered
  # it silently no-ops and the driver comes up looking healthy while no input
  # can ever arrive. That distinction is invisible from outside the VM.
  defp reader_status do
    case Process.whereis(:user_drv_reader) do
      nil ->
        "absent"

      reader ->
        case :erlang.trace_info(reader, :flags) do
          {:flags, flags} ->
            if :send in flags, do: "traced", else: "untraced#{inspect(flags)}"

          other ->
            "unknown#{inspect(other)}"
        end
    end
  end

  # Raw mode is what makes a bare keystroke deliverable: in canonical mode the
  # reader hands nothing over until a newline, and this canary types `a` and `b`
  # with no newline. `boot_confirmed?` is the driver's own verify-then-assert
  # result; `isig_off?` is the live flags.
  defp raw_status(pid) do
    case Raxol.Terminal.InlineDriver.isig_report(pid) do
      %{boot_confirmed?: confirmed, isig_off?: off} ->
        "boot_confirmed=#{confirmed},isig_off=#{off}"

      other ->
        "unexpected#{inspect(other)}"
    end
  catch
    kind, reason -> "unavailable(#{inspect(kind)},#{inspect(reason)})"
  end

  defp collect(n, acc) when length(acc) >= n, do: Enum.reverse(acc)

  defp collect(n, acc) do
    receive do
      {:inline_input, %Raxol.Core.Events.Event{type: :key, data: data}} ->
        collect(n, [token(data) | acc])

      _ ->
        collect(n, acc)
    after
      4000 -> Enum.reverse(acc)
    end
  end

  # `ctrl` is carried separately from the char, and byte 0x03 parses to
  # `%{ctrl: true, char: "c"}` -- the same char a bare `c` keystroke
  # produces. Without the prefix a decoded ^C and a typed `c` are the
  # same token, which is exactly the distinction the isig test turns on.
  defp token(%{ctrl: true} = data), do: "ctrl-" <> to_string(data[:char] || data[:key])
  defp token(data), do: to_string(data[:char] || data[:key])
end

InputCanaryApp.run()
