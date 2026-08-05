defmodule Raxol.Terminal.InputProtocolCanaryTest do
  @moduledoc """
  The real-pty input tests -- the only ones permitted to claim prim_tty PROTOCOL
  coverage or a live `-isig` guarantee.

  Two separate claims, sharing one harness because both need a REAL terminal and
  neither can be had without one:

    * the protocol canary -- keystrokes decode through the live reader;
    * the `-isig` contract -- ^C arrives as byte 0x03 rather than a SIGINT.

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

  @plain_keys [{:literal, "a"}, {:literal, "b"}]
  @ctrl_c_keys [{:named, "C-c"}]

  test "real keystrokes decode through the live prim_tty reader" do
    with_pty(fn driver ->
      {result, attempt} = drive_until(driver, @plain_keys, ["a", "b"], @max_attempts)

      assert result.tokens == ["a", "b"],
             failure_report(result, driver, attempt, ["a", "b"])
    end)
  end

  # The `-isig` half of the raw-mode contract, which nothing else covers end to
  # end. `Stty.raw!/0` asks for `-isig` so that ^C reaches the app as byte 0x03
  # and the arm-quit protocol owns it, rather than the kernel turning it into a
  # SIGINT the app never sees.
  #
  # This is worth a real pty because the two outcomes are not "assert true vs
  # false" -- they are different PROCESS fates. With ISIG off, 0x03 is delivered
  # and decodes to a ctrl-c key event. With ISIG on, the line discipline raises
  # SIGINT on the foreground group instead, and the app dies (or drops into the
  # VM BREAK menu) without ever writing its output file -- so a regression
  # surfaces as `:no_output`/`:ready_timeout`, not as a wrong token.
  #
  # It also pins the thing that made this contract vacuous for so long: the
  # in-VM diagnostics must show the termios was actually ESTABLISHED. Every
  # `stty` call used to no-op silently (it targeted `/dev/tty`, which a port
  # child in a fresh session cannot open), so `isig_off` read false on every
  # OTP while the suite stayed green. Asserting the flags -- not just the
  # decode -- is what stops that from going quiet again.
  test "^C arrives as byte 0x03 instead of raising SIGINT (-isig holds)" do
    with_pty(fn driver ->
      {result, attempt} = drive_until(driver, @ctrl_c_keys, ["ctrl-c"], @max_attempts)

      assert result.tokens == ["ctrl-c"],
             failure_report(result, driver, attempt, ["ctrl-c"])

      assert result.diag =~ "isig_off=true",
             """
             ^C decoded, but the app reports ISIG still ON. The keystroke got \
             through on something other than the `-isig` this contract promises, \
             so the guarantee is not actually in force.

             #{result.diag}
             """

      assert result.diag =~ "boot_confirmed=true",
             """
             `-isig` was never confirmed during boot: the verify-then-assert loop \
             (`reassert_raw_until_isig_off/1`) gave up. That is the signature of \
             `stty` silently no-oping -- check `Stty.tty_device/0` resolution \
             before anything else.

             #{result.diag}
             """
    end)
  end

  defp with_pty(fun) do
    case pty_driver() do
      nil ->
        IO.puts(
          :stderr,
          "[input canary] skipped: neither tmux nor expect on PATH"
        )

      driver ->
        fun.(driver)
    end
  end

  # Name the stage that actually failed. Every one of these used to surface as
  # `got []`, which said "OTP moved the protocol" no matter which of them it
  # was -- and for most of them that claim is simply false.
  defp failure_report(result, driver, attempt, expected) do
    """
    prim_tty real-pty input test FAILED on OTP #{System.otp_release()} \
    (driver: #{driver}) after #{attempt} attempt(s), at stage: #{result.stage}.
    Expected #{inspect(expected)}, got #{inspect(result.tokens)}.

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
  defp drive_until(driver, keys, expected, attempts_left, attempt \\ 1) do
    result = attempt_drive(driver, keys)

    cond do
      result.tokens == expected -> {result, attempt}
      attempts_left <= 1 -> {result, attempt}
      true -> drive_until(driver, keys, expected, attempts_left - 1, attempt + 1)
    end
  end

  defp attempt_drive(driver, keys) do
    out = Path.join(System.tmp_dir!(), "raxol_input_canary_#{unique()}")

    try do
      stage = drive(driver, out, keys)
      diag = read_diagnostics(out)

      case {stage, File.read(out)} do
        {:sent, {:ok, body}} ->
          tokens = String.split(body, "\n", trim: true)
          %{tokens: tokens, stage: classify(tokens, keys), diag: diag}

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

  defp classify([], _keys), do: :empty
  defp classify(tokens, keys) when length(tokens) < length(keys), do: :partial
  defp classify(_tokens, _keys), do: :ok

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

  defp drive(:tmux, out, keys) do
    session = "raxol-input-canary-#{unique()}"

    cmd =
      "cd #{@pkg_dir} && CANARY_OUT=#{out} CANARY_N=#{length(keys)} " <>
        "MIX_ENV=test mix run --no-compile #{@app}"

    try do
      {_, 0} =
        System.cmd(
          "tmux",
          ["new-session", "-d", "-s", session, "-x", "80", "-y", "24", cmd],
          stderr_to_stdout: true
        )

      # Only type once the reader signalled ready, then settle briefly so its
      # select loop is armed.
      case wait_for_ready(out) do
        :ok ->
          Process.sleep(@settle_ms)
          type_all(session, out, keys)

        :timeout ->
          :ready_timeout
      end
    after
      System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    end
  end

  defp drive(:expect, out, keys) do
    # The canary app `System.halt/0`s right after writing output, so `eof`
    # returns promptly. `--no-compile`: the parent test already compiled, so the
    # nested run must not recompile under lock contention.
    sends =
      keys
      |> Enum.map(&~s|send "#{expect_bytes(&1)}"\nafter #{@gap_ms}|)
      |> Enum.join("\n")

    script = """
    set timeout 120
    spawn env CANARY_OUT=#{out} CANARY_N=#{length(keys)} MIX_ENV=test mix run --no-compile #{@app}
    set t 0
    while {![file exists "#{out}.ready"] && $t < 900} { after 100; incr t }
    after #{@settle_ms}
    #{sends}
    expect eof
    """

    System.cmd("expect", ["-c", script], cd: @pkg_dir, stderr_to_stdout: true)

    # `expect` does its own waiting inside the script, so reaching here means
    # the keystrokes were written to the pty.
    :sent
  end

  defp type_all(session, out, keys) do
    result =
      Enum.reduce_while(keys, :ok, fn key, _acc ->
        case send_key(session, key) do
          :ok ->
            Process.sleep(@gap_ms)
            {:cont, :ok}

          other ->
            {:halt, other}
        end
      end)

    case result do
      :ok ->
        wait_for_output(out)
        :sent

      other ->
        other
    end
  end

  # A refused keystroke must not read as a decode failure. The exit status was
  # dropped once, which made a dead tmux session and a moved protocol produce
  # the same empty result.
  #
  # `-l` sends the bytes literally; a `{:named, _}` key is a tmux key NAME
  # (`C-c`), which must NOT be sent literally or tmux types the three
  # characters `C`, `-`, `c` instead of the control byte.
  defp send_key(session, key) do
    args =
      case key do
        {:literal, k} -> ["send-keys", "-t", session, "-l", k]
        {:named, k} -> ["send-keys", "-t", session, k]
      end

    case System.cmd("tmux", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_out, _status} -> :send_failed
    end
  end

  defp expect_bytes({:literal, k}), do: k
  defp expect_bytes({:named, "C-c"}), do: "\\003"

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
