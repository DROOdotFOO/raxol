defmodule Raxol.Terminal.InputIsigContractTest do
  @moduledoc """
  The live `-isig` guarantee: ^C reaches the app as byte 0x03, not as a SIGINT.

  `Raxol.Terminal.Driver.Stty.raw!/0` asks for `-isig` so that the arm-quit
  protocol owns Ctrl-C, rather than the kernel turning it into a signal the app
  never sees. Nothing else covers that end to end.

  It is worth a real pty (via `Raxol.Terminal.PtyHarness`) because the two
  outcomes are not "assert true vs false" -- they are different PROCESS fates.
  With ISIG off, 0x03 is delivered and decodes to a ctrl-c key event. With ISIG
  on, the line discipline raises SIGINT on the foreground group instead and the
  app dies (or drops into the VM BREAK menu) without ever writing its output --
  so a regression surfaces as `:no_output`, not as a wrong token. Verified by
  reverting the fix that made `Stty` functional: this test failed at exactly
  that stage while the protocol canary went on passing.

  It asserts the in-VM termios diagnostics as well as the decode, and that is
  deliberate. The decode alone is what let this contract stay vacuous for so
  long: every `stty` call used to no-op silently (it targeted `/dev/tty`, which
  a `System.cmd` child in a fresh session cannot open), so `isig_off` read false
  on every OTP while the suite stayed green. Asserting the flags is what stops
  it going quiet again.

  Ctrl-C decodes to `%{ctrl: true, char: "c"}` -- the same char a bare `c`
  keystroke produces -- so the fixture prefixes ctrl chords. Without that a
  decoded ^C and a typed `c` are the same token and this test would pass for
  the wrong reason.
  """
  use ExUnit.Case, async: false

  alias Raxol.Terminal.PtyHarness

  @moduletag :unix_only
  # Shares the nightly canary's tag: both are the real-pty input contract, and
  # a bump of `OTP_VERSION` in CI must surface both together.
  @moduletag :input_protocol_canary
  @moduletag timeout: 180_000

  @keys [{:named, "C-c"}]
  @expected ["ctrl-c"]

  test "^C arrives as byte 0x03 instead of raising SIGINT" do
    case PtyHarness.driver() do
      nil ->
        IO.puts(:stderr, "[isig contract] skipped: neither tmux nor expect on PATH")

      driver ->
        result = PtyHarness.run(driver, @keys, @expected)

        assert result.tokens == @expected,
               PtyHarness.report(result, driver, @expected, explain(result.stage))

        assert result.diag =~ "isig_off=true",
               """
               ^C decoded, but the app reports ISIG still ON. The keystroke got \
               through on something other than the `-isig` this contract \
               promises, so the guarantee is not actually in force.

               #{result.diag}
               """

        assert result.diag =~ "boot_confirmed=true",
               """
               `-isig` was never confirmed during boot: the verify-then-assert \
               loop (`reassert_raw_until_isig_off/1`) gave up. That is the \
               signature of `stty` silently no-oping -- check \
               `Stty.tty_device/0` resolution before anything else.

               #{result.diag}
               """
    end
  end

  # What each stage means FOR THIS CLAIM -- which is mostly not what it means
  # for the protocol canary.
  defp explain(:no_output) do
    """
    THIS IS THE REGRESSION THIS TEST EXISTS TO CATCH. ^C was delivered and the
    app then died without writing its output: the signature of ISIG being back
    ON, the line discipline raising SIGINT on the foreground group instead of
    passing byte 0x03 through. Check that `Stty.raw!/0`'s `-isig` is actually
    reaching a real device (`Stty.tty_device/0`) rather than failing silently.
    """
  end

  defp explain(:empty) do
    """
    The app survived (so ISIG is plausibly off) but decoded nothing at all.
    That points at the input path in general rather than at this contract --
    check the protocol canary first, since it isolates exactly that.
    """
  end

  defp explain(:ready_timeout) do
    """
    The app never signalled ready, so no ^C was ever sent. Nothing to say about
    ISIG: the app failed to boot within the #{PtyHarness.ready_budget_ms()}ms
    budget.
    """
  end

  defp explain(:send_failed) do
    """
    The pty driver refused to deliver the keystroke (non-zero exit from
    send-keys) -- suspect the tmux session or the CI environment, not the
    termios.
    """
  end

  defp explain(other), do: "Unrecognized stage: #{inspect(other)}."
end
