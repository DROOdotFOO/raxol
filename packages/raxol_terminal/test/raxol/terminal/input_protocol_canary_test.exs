defmodule Raxol.Terminal.InputProtocolCanaryTest do
  @moduledoc """
  The one test permitted to claim prim_tty PROTOCOL coverage.

  Every other input test fabricates the `{:trace, ...}` message it asserts on, so
  it can only fail if our handler changes -- never if OTP moves the private
  protocol underneath us (the reader's message shape, the `{:read, :infinity}`
  re-arm). This one drives a REAL pty: it boots the actual `InlineDriver` stdin
  reader inside a terminal multiplexer, types real keystrokes, and asserts they
  decode into events. That makes it the one test a bump of `OTP_VERSION` in CI
  should surface loudly instead of shipping.

  A red here does NOT on its own mean "OTP moved". Several things sit between a
  keystroke and a decoded event, and most of them are ours: the app has to boot
  and arm, the multiplexer has to accept the keystroke, and the reader has to be
  traced. Only when all of those held and the bytes still did not arrive is the
  protocol the remaining explanation. The failure report names the stage that
  actually broke and prints what the app could see from inside its own VM, so
  the two are told apart instead of guessed at.

  Two keystrokes (not one) with a gap between them: a drift that delivers the
  first read but breaks re-arming would sail through a single-byte test.

  Driver: tmux when present (same mechanism the Terminal-Bench harness uses to
  drive agents), else `expect` as a portable fallback. Skips only when neither
  is installed. `unix_only` -- there is no pty to drive on Windows.

  Runs on every OTP in the matrix, including those where `user_drv` will not
  hand out a raw noshell tty and `Raxol.Terminal.Driver.Stty` has to establish
  raw mode itself (OTP 26/27 -- see `Stty`'s moduledoc). Keeping it unskipped
  there is the point: that path has no other end-to-end coverage.
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
  @ready_suffix ".ready"
  @ready_tries 900
  @output_tries 60

  test "real keystrokes decode through the live prim_tty reader" do
    driver = pty_driver()

    if driver == nil do
      IO.puts(
        :stderr,
        "[input canary] skipped: neither tmux nor expect on PATH"
      )
    else
      {result, attempt} = drive_until(driver, @max_attempts)

      assert result.tokens == ["a", "b"],
             failure_report(result, driver, attempt)
    end
  end

  # Name the stage that actually failed. Every one of these used to surface as
  # `got []`, which said "OTP moved the protocol" no matter which of them it
  # was -- and for most of them that claim is simply false.
  defp failure_report(result, driver, attempt) do
    """
    prim_tty input protocol canary FAILED on OTP #{System.otp_release()} \
    (driver: #{driver}) after #{attempt} attempt(s), at stage: #{result.stage}.
    Expected ["a", "b"], got #{inspect(result.tokens)}.

    #{stage_explanation(result.stage)}

    In-VM diagnostics from the app (#{@ready_suffix} file):
      #{result.diag}
    """
  end

  defp stage_explanation(:ready_timeout) do
    """
    The app never signalled ready, so NO keystroke was ever sent. This is not a
    protocol break: the app failed to boot or to arm its reader within the
    #{@ready_tries * 100}ms budget. Look at the app's own startup, not at the
    trace handler.
    """
  end

  defp stage_explanation(:send_failed) do
    """
    The pty driver refused to deliver a keystroke (non-zero exit from send-keys).
    Nothing reached the app, so this says nothing about the input path -- suspect
    the tmux session or the CI environment.
    """
  end

  defp stage_explanation(:no_output) do
    """
    Keystrokes were sent, but the app never wrote its output file at all -- it
    is still blocked or it died before finishing. Check whether the app crashed
    inside the pty.
    """
  end

  defp stage_explanation(:partial) do
    """
    The FIRST keystroke decoded and a later one did not. This is the re-arm
    break the two-keystroke design exists to catch: the reader delivered one
    read and never re-armed. See `start_stdin_reader/1`'s `{:read, :infinity}`.
    """
  end

  defp stage_explanation(:empty) do
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

  defp stage_explanation(other), do: "Unrecognized stage: #{inspect(other)}."

  # A cold pty boot inside tmux/expect can drop the first keystroke if it lands
  # before the reader has armed its select loop -- a timing flake, not a protocol
  # failure. Retry the whole drive: a real OTP break fails every attempt, a race
  # succeeds on a later one.
  defp drive_until(driver, attempts_left, attempt \\ 1) do
    result = attempt_drive(driver)

    cond do
      result.tokens == ["a", "b"] -> {result, attempt}
      attempts_left <= 1 -> {result, attempt}
      true -> drive_until(driver, attempts_left - 1, attempt + 1)
    end
  end

  defp attempt_drive(driver) do
    out = Path.join(System.tmp_dir!(), "raxol_input_canary_#{unique()}")

    try do
      stage = drive(driver, out)
      diag = read_diagnostics(out)

      case {stage, File.read(out)} do
        {:sent, {:ok, body}} ->
          tokens = String.split(body, "\n", trim: true)
          %{tokens: tokens, stage: classify(tokens), diag: diag}

        {:sent, {:error, _}} ->
          %{tokens: [], stage: :no_output, diag: diag}

        {stage, _} ->
          %{tokens: [], stage: stage, diag: diag}
      end
    after
      File.rm(out)
      File.rm(out <> @ready_suffix)
    end
  end

  defp classify(["a", "b"]), do: :ok
  defp classify([]), do: :empty
  defp classify(_partial), do: :partial

  # The app's own account of what it established. Absent when it never got far
  # enough to write one, which is itself the answer.
  defp read_diagnostics(out) do
    case File.read(out <> @ready_suffix) do
      {:ok, body} -> String.trim(body)
      {:error, _} -> "(no ready file -- the app never signalled)"
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
      case wait_for_ready(out) do
        :ok ->
          Process.sleep(@settle_ms)
          type_both(session, out)

        :timeout ->
          :ready_timeout
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

    # `expect` does its own waiting inside the script, so reaching here means
    # the keystrokes were written to the pty.
    :sent
  end

  defp type_both(session, out) do
    with :ok <- send_key(session, "a"),
         :ok <- gap_then_send(session, "b") do
      wait_for_output(out)
      :sent
    end
  end

  defp gap_then_send(session, key) do
    Process.sleep(@gap_ms)
    send_key(session, key)
  end

  # A refused keystroke must not read as a decode failure. The exit status was
  # dropped once, which made a dead tmux session and a moved protocol produce
  # the same empty result.
  defp send_key(session, key) do
    case System.cmd("tmux", ["send-keys", "-t", session, "-l", key], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_out, _status} -> :send_failed
    end
  end

  # Type only once the reader is armed, so we never send before the pty listens.
  defp wait_for_ready(out), do: poll(out <> @ready_suffix, @ready_tries)
  defp wait_for_output(out), do: poll(out, @output_tries)

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
