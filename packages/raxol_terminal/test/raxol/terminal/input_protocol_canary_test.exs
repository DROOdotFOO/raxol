defmodule Raxol.Terminal.InputProtocolCanaryTest do
  @moduledoc """
  The one test permitted to claim prim_tty PROTOCOL coverage.

  Every other input test fabricates the `{:trace, ...}` message it asserts on, so
  it can only fail if our handler changes -- never if OTP moves the private
  protocol underneath us (the reader's message shape, the `{:read, :infinity}`
  re-arm). This one drives a REAL pty via `Raxol.Terminal.PtyHarness`: it boots
  the actual `InlineDriver` stdin reader inside a terminal multiplexer, types
  real keystrokes, and asserts they decode into events. That makes it the one
  test a bump of `OTP_VERSION` in CI should surface loudly instead of shipping.

  A red here does NOT on its own mean "OTP moved". Several things sit between a
  keystroke and a decoded event, and most of them are ours: the app has to boot
  and arm, the multiplexer has to accept the keystroke, and the reader has to be
  traced. Only when all of those held and the bytes still did not arrive is the
  protocol the remaining explanation. The failure report names the stage that
  actually broke and prints what the app could see from inside its own VM, so
  the two are told apart instead of guessed at.

  Two keystrokes (not one) with a gap between them: a drift that delivers the
  first read but breaks re-arming would sail through a single-byte test.

  Runs on every OTP in the matrix, including those where `user_drv` will not
  hand out a raw noshell tty and `Raxol.Terminal.Driver.Stty` has to establish
  raw mode itself (OTP 26/27 -- see `Stty`'s moduledoc). Keeping it unskipped
  there is the point: that path has no other end-to-end coverage.

  The `-isig` half of the raw-mode contract is a different claim and lives in
  `input_isig_contract_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Terminal.PtyHarness

  @moduletag :unix_only
  @moduletag :input_protocol_canary
  # A cold `mix run` inside the pty dominates wall-clock; the decode itself is
  # sub-second. Give the boot room so the canary never flakes on its own latency.
  @moduletag timeout: 180_000

  @keys [{:literal, "a"}, {:literal, "b"}]
  @expected ["a", "b"]

  test "real keystrokes decode through the live prim_tty reader" do
    case PtyHarness.driver() do
      nil ->
        IO.puts(:stderr, "[input canary] skipped: neither tmux nor expect on PATH")

      driver ->
        result = PtyHarness.run(driver, @keys, @expected)

        assert result.tokens == @expected,
               PtyHarness.report(result, driver, @expected, explain(result.stage))
    end
  end

  # What each stage means FOR THIS CLAIM. Every one of these used to surface as
  # `got []`, which said "OTP moved the protocol" no matter which of them it
  # was -- and for most of them that claim is simply false.
  defp explain(:ready_timeout) do
    """
    The app never signalled ready, so NO keystroke was ever sent. This is not a
    protocol break: the app failed to boot or to arm its reader within the
    #{PtyHarness.ready_budget_ms()}ms budget. Look at the app's own startup, not
    at the trace handler.
    """
  end

  defp explain(:send_failed) do
    """
    The pty driver refused to deliver a keystroke (non-zero exit from send-keys).
    Nothing reached the app, so this says nothing about the input path -- suspect
    the tmux session or the CI environment.
    """
  end

  defp explain(:no_output) do
    """
    Keystrokes were sent, but the app never wrote its output file at all -- it
    is still blocked or it died before finishing. Check whether the app crashed
    inside the pty.
    """
  end

  defp explain(:partial) do
    """
    The FIRST keystroke decoded and a later one did not. This is the re-arm
    break the two-keystroke design exists to catch: the reader delivered one
    read and never re-armed. See `start_stdin_reader/1`'s `{:read, :infinity}`.
    """
  end

  defp explain(:empty) do
    """
    The app armed and ran, keystrokes were sent, and it decoded NOTHING. Read
    the diagnostics below before blaming the protocol:

      * `reader=absent` -- `:user_drv_reader` was not registered, so
        `start_stdin_reader/1` silently traced nothing. Not a protocol change.
      * `reader=untraced...` -- the trace never attached.
      * `reader=traced` -- everything this side controls was in place and the
        bytes still did not arrive. THAT is the case that points at OTP moving
        the reader's private message shape or its re-arm contract
        (`Raxol.Terminal.Driver`'s `{:trace, ...}` handler).

    Do NOT read `isig_off=false` as "not in raw mode, so of course nothing
    arrived". It is not that evidence, in either direction. Once the reader is
    armed, prim_tty owns the termios and re-applies ITS raw mode, which keeps
    ISIG ENABLED (the whole reason `reassert_raw_until_isig_off/1` exists) --
    so `isig_off=false` is the ordinary steady state, and keystrokes decode
    through it perfectly well. It means "prim_tty won the termios race",
    nothing more. `-icanon` is what governs whether a bare keystroke is
    deliverable, and prim_tty's own raw mode sets it whether or not our `stty`
    ever ran.
    """
  end

  defp explain(other), do: "Unrecognized stage: #{inspect(other)}."
end
