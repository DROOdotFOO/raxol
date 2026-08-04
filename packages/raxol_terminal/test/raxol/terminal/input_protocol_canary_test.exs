defmodule Raxol.Terminal.InputProtocolCanaryTest do
  @moduledoc """
  The one test permitted to claim prim_tty PROTOCOL coverage.

  Every other input test fabricates the `{:trace, ...}` message it asserts on, so
  it can only fail if our handler changes -- never if OTP moves the private
  protocol underneath us (the reader's message shape, the `{:read, :infinity}`
  re-arm). This one drives a REAL pty: it boots the actual `InlineDriver` stdin
  reader inside a terminal multiplexer, types real keystrokes, and asserts they
  decode into events. Its failure means "OTP moved" -- which is exactly the
  signal a bump of `OTP_VERSION` in CI should surface loudly instead of shipping.

  Two keystrokes (not one) with a gap between them: a drift that delivers the
  first read but breaks re-arming would sail through a single-byte test.

  Driver: tmux when present (same mechanism the Terminal-Bench harness uses to
  drive agents), else `expect` as a portable fallback. Skips only when neither
  is installed. `unix_only` -- there is no pty to drive on Windows.
  """
  use ExUnit.Case, async: false

  @moduletag :unix_only
  @moduletag :input_protocol_canary
  # A cold `mix run` inside the pty dominates wall-clock; the decode itself is
  # sub-second. Give the boot room so the canary never flakes on its own latency.
  @moduletag timeout: 180_000

  @app Path.expand("../../fixtures/input_canary_app.exs", __DIR__)
  @pkg_dir Path.expand("../../..", __DIR__)
  @gap_ms 300
  # Settle after the reader signals ready, before the first keystroke, so its
  # select loop is armed. Retry a few times to absorb cold-boot pty timing slop.
  @settle_ms 250
  @max_attempts 3

  test "real keystrokes decode through the live prim_tty reader" do
    driver = pty_driver()

    if driver == nil do
      IO.puts(:stderr, "[input canary] skipped: neither tmux nor expect on PATH")
    else
      {tokens, attempt} = drive_until(driver, @max_attempts)

      assert tokens == ["a", "b"], """
      prim_tty input protocol canary FAILED on OTP #{System.otp_release()} (driver: #{driver}) after #{attempt} attempt(s).
      Expected two real keystrokes to decode as ["a", "b"], got #{inspect(tokens)}.
      This retries #{@max_attempts}x, so a transient pty/tmux timing race would have
      passed on a retry -- an empty [] after all attempts is a REAL failure. It
      almost always means OTP changed the prim_tty reader's private message
      protocol or its re-arm contract -- see Raxol.Terminal.Driver's `{:trace, ...}`
      handler and `start_stdin_reader/1`.
      """
    end
  end

  # A cold pty boot inside tmux/expect can drop the first keystroke if it lands
  # before the reader has armed its select loop -- a timing flake, not a protocol
  # failure. Retry the whole drive: a real OTP break fails every attempt, a race
  # succeeds on a later one.
  defp drive_until(driver, attempts_left, attempt \\ 1) do
    tokens = attempt_drive(driver)

    cond do
      tokens == ["a", "b"] -> {tokens, attempt}
      attempts_left <= 1 -> {tokens, attempt}
      true -> drive_until(driver, attempts_left - 1, attempt + 1)
    end
  end

  defp attempt_drive(driver) do
    out = Path.join(System.tmp_dir!(), "raxol_input_canary_#{unique()}")

    try do
      drive(driver, out)

      case File.read(out) do
        {:ok, body} -> String.split(body, "\n", trim: true)
        {:error, _} -> []
      end
    after
      File.rm(out)
      File.rm(out <> ".ready")
    end
  end

  defp pty_driver do
    cond do
      System.find_executable("tmux") -> :tmux
      System.find_executable("expect") -> :expect
      true -> nil
    end
  end

  defp drive(:tmux, out) do
    session = "raxol-input-canary-#{unique()}"

    cmd =
      "cd #{@pkg_dir} && CANARY_OUT=#{out} CANARY_N=2 MIX_ENV=test mix run --no-compile #{@app}"

    try do
      {_, 0} =
        System.cmd(
          "tmux",
          ["new-session", "-d", "-s", session, "-x", "80", "-y", "24", cmd],
          stderr_to_stdout: true
        )

      # Only type once the reader signalled ready, then settle briefly so its
      # select loop is armed. `-l` sends the bytes literally (not as key names).
      if wait_for_ready(out) == :ok do
        Process.sleep(@settle_ms)
        System.cmd("tmux", ["send-keys", "-t", session, "-l", "a"], stderr_to_stdout: true)
        Process.sleep(@gap_ms)
        System.cmd("tmux", ["send-keys", "-t", session, "-l", "b"], stderr_to_stdout: true)
        wait_for_output(out)
      end
    after
      System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    end
  end

  defp drive(:expect, out) do
    # The canary app `System.halt/0`s right after writing output, so `eof`
    # returns promptly. `--no-compile`: the parent test already compiled, so the
    # nested run must not recompile under lock contention.
    script = """
    set timeout 120
    spawn env CANARY_OUT=#{out} CANARY_N=2 MIX_ENV=test mix run --no-compile #{@app}
    set t 0
    while {![file exists "#{out}.ready"] && $t < 900} { after 100; incr t }
    after #{@settle_ms}
    send "a"
    after #{@gap_ms}
    send "b"
    expect eof
    """

    System.cmd("expect", ["-c", script], cd: @pkg_dir, stderr_to_stdout: true)
  end

  # Type only once the reader is armed, so we never send before the pty listens.
  defp wait_for_ready(out), do: poll(out <> ".ready", 900)
  defp wait_for_output(out), do: poll(out, 60)

  defp poll(_path, 0), do: :timeout

  defp poll(path, tries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(100)
      poll(path, tries - 1)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
