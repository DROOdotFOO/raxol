defmodule Raxol.Harness.TpPtyTest do
  @moduledoc """
  Unit TP smoke test (`docs/proposals/in-flight/harness-ui-roadmap.md`,
  design in `harness-ui-testing/03-lifecycle.md` §1.2-1.3): proves the pty
  harness itself -- spawn-under-pty, real signal delivery to the BEAM's
  child, and post-mortem `stty -a` capture -- before any T2d/T2a/T25 test
  builds on it.

  Tier B (real kernel pty). No termbox anywhere in this path; requires
  only `python3` + `sh` + `stty`. Tagged `:skip_on_ci` because real-pty
  signal-delivery timing is unreliable on shared CI runners (no
  controlling terminal, non-deterministic scheduler) -- a flake in the
  kernel/runner, not in the assertions -- so it is gated off the default
  CI path (which sets `SKIP_TERMBOX2_TESTS=true`) and runs locally /
  watched. Note: `SKIP_TERMBOX2_TESTS=true` is also set automatically for
  local agent sessions (see `.claude/settings.json`), so this suite is
  skipped there too -- run it explicitly with
  `mix test --include skip_on_ci test/harness/tp_pty_test.exs` or in a
  clean env. Skips cleanly (not a failure) when `python3` is absent.
  """

  use ExUnit.Case, async: true

  alias Raxol.Test.PtyHarness

  @moduletag :pty
  @moduletag :unix_only
  @moduletag :skip_on_ci

  # `trap ... TERM` intercepts SIGTERM: the shell prints CLEANUP, then exits
  # via a normal `exit()` syscall (WIFEXITED true) -- verified empirically
  # under this harness with `sh` as pty session leader, exit code 143
  # (128+SIGTERM, the shell's own convention for "died to a trapped fatal
  # signal", not the kernel forcibly killing it). SIGKILL bypasses the trap
  # entirely -- the kernel just ends the process (WIFSIGNALED true, signal
  # 9), so CLEANUP is never printed. WIFEXITED-vs-WIFSIGNALED is the load
  # bearing distinction here, not the exact exit code.
  @trap_script ~s(trap "echo CLEANUP" TERM; echo READY; sleep 30)

  setup_all do
    if PtyHarness.available?() do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  # Stops the wrapper (killing anything still running under it) and removes
  # the capture file, so a green run leaves nothing behind in `TMPDIR`.
  defp cleanup(session) do
    PtyHarness.stop(session)
    File.rm(session.capture_path)
  end

  # `stty -a` renders each mode as a bare token ("icanon") when set and a
  # minus-prefixed token ("-icanon") when clear. Exact token membership
  # avoids the substring trap ("-echo" contains "echo").
  defp stty_tokens(output), do: String.split(output, ~r/[\s;]+/, trim: true)

  describe "signal delivery + post-mortem" do
    test "SIGTERM: trap fires (CLEANUP captured), exits (not signaled), post-mortem stty readable" do
      {:ok, session} = PtyHarness.start(["sh", "-c", @trap_script])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 3_000)

      assert :ok = PtyHarness.signal(session, :term)
      # WIFEXITED, not WIFSIGNALED: the trap ran to completion. Exit code
      # follows the shell's 128+signum convention (see @trap_script above).
      assert {:ok, {:exit, 143}} = PtyHarness.await(session, 3_000)

      assert :ok = PtyHarness.await_capture(session, "CLEANUP", 2_000)
      {:ok, output} = PtyHarness.read_output(session)
      assert output =~ "READY"
      assert output =~ "CLEANUP"

      assert {:ok, stty_output} = PtyHarness.post_mortem(session)
      assert is_binary(stty_output)
      assert byte_size(stty_output) > 0
    end

    test "SIGKILL: no trap run (no CLEANUP), exit reported as signaled" do
      {:ok, session} = PtyHarness.start(["sh", "-c", @trap_script])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 3_000)

      assert :ok = PtyHarness.signal(session, :kill)
      assert {:ok, {:signaled, 9}} = PtyHarness.await(session, 3_000)

      {:ok, output} = PtyHarness.read_output(session)
      assert output =~ "READY"
      refute output =~ "CLEANUP"

      # The pty slave outlives the child (the wrapper still owns the
      # master), so post-mortem inspection after a SIGKILL is exactly the
      # "documented residual is a tested fact" case from the design doc.
      assert {:ok, stty_output} = PtyHarness.post_mortem(session)
      assert is_binary(stty_output)
      assert byte_size(stty_output) > 0
    end

    # Signals go to the process GROUP, not just the direct child pid: a
    # backgrounded grandchild must die with the group, or `sh -c` chains
    # leave orphan processes behind every interrupt.
    test "SIGTERM reaches the whole process group, not just the shell pid" do
      script =
        ~s[trap "echo CLEANUP" TERM; (sleep 30)& echo BGPID=$!; echo READY; wait]

      {:ok, session} = PtyHarness.start(["sh", "-c", script])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 3_000)

      {:ok, output} = PtyHarness.read_output(session)
      [_, bgpid] = Regex.run(~r/BGPID=(\d+)/, output)

      assert :ok = PtyHarness.signal(session, :term)
      assert {:ok, {:exit, _}} = PtyHarness.await(session, 3_000)
      assert :ok = PtyHarness.await_capture(session, "CLEANUP", 2_000)

      # the backgrounded grandchild must be gone too -- no orphan sleep
      assert :ok = await_process_death(bgpid, 2_000)
    end
  end

  # Polls `kill -0 pid` until the process is gone (exit status != 0) or the
  # deadline passes. kill -0 delivers nothing; it only probes existence.
  defp await_process_death(pid_str, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_process_death(pid_str, deadline)
  end

  defp poll_process_death(pid_str, deadline) do
    {_, status} = System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true)

    cond do
      status != 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :still_alive}

      true ->
        Process.sleep(20)
        poll_process_death(pid_str, deadline)
    end
  end

  describe "spawn/inspect/exit round-trip" do
    test "a trivial script's exit code round-trips through WAIT" do
      {:ok, session} = PtyHarness.start(["sh", "-c", "echo hi; exit 5"])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "hi", 3_000)
      assert {:ok, {:exit, 5}} = PtyHarness.await(session, 3_000)
    end

    test "WRITE injects input bytes into the pty master" do
      # `cat` echoes stdin back out; sending Ctrl-D (EOT) via WRITE should
      # let it see EOF and exit cleanly once its own input is closed.
      {:ok, session} = PtyHarness.start(["cat"])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.write(session, "hello\n")
      assert :ok = PtyHarness.await_capture(session, "hello", 2_000)

      assert :ok = PtyHarness.write(session, <<4>>)
      assert {:ok, {:exit, 0}} = PtyHarness.await(session, 3_000)
    end

    # (A RECOVER-after-kill smoke test used to live here; it was vacuous --
    # it passed even with a no-op recover. PTY-SELF-3 below is the real
    # assertion: recover on a deliberately-stuck slave restores sane.)

    # DRAIN BARRIER: a successful await must guarantee capture
    # completeness -- the wrapper joins the pump thread (drain to EOF +
    # close) before replying to WAIT. Without it, the last bytes written
    # right at exit can race the reply, which is exactly the truncation
    # LC-P-SIGTERM exists to detect. Looped to catch the race, which is
    # timing-dependent by nature.
    test "drain barrier: burst-then-exit output is fully captured after await (20x)" do
      burst_script =
        "i=0; while [ $i -lt 100 ]; do echo LINE$i; i=$((i+1)); done; " <>
          "echo FINAL_MARKER; exit 0"

      for round <- 1..20 do
        {:ok, session} = PtyHarness.start(["sh", "-c", burst_script])

        assert {:ok, {:exit, 0}} = PtyHarness.await(session, 5_000)
        {:ok, output} = PtyHarness.read_output(session)

        assert output =~ "LINE0", "round #{round}: head of burst missing"
        assert output =~ "LINE99", "round #{round}: tail of burst missing"

        assert output =~ "FINAL_MARKER",
               "round #{round}: trailing bytes lost to the reply race"

        cleanup(session)
      end
    end
  end

  describe "harness self-tests (03-lifecycle §3.3)" do
    # PTY-SELF-2: the STTY probe must decisively distinguish a raw-mode
    # slave from a default (sane-ish) one, or every raw/sane assertion
    # built on it is meaningless.
    test "PTY-SELF-2: STTY probe distinguishes raw-mode slave from default" do
      {:ok, raw_session} =
        PtyHarness.start(["sh", "-c", "stty raw -echo; echo ARMED; sleep 30"])

      on_exit(fn -> cleanup(raw_session) end)

      {:ok, sane_session} =
        PtyHarness.start(["sh", "-c", "echo IDLE; sleep 30"])

      on_exit(fn -> cleanup(sane_session) end)

      assert :ok = PtyHarness.await_capture(raw_session, "ARMED", 3_000)
      assert :ok = PtyHarness.await_capture(sane_session, "IDLE", 3_000)

      {:ok, raw_stty} = PtyHarness.post_mortem(raw_session)
      {:ok, sane_stty} = PtyHarness.post_mortem(sane_session)

      raw_tokens = stty_tokens(raw_stty)
      sane_tokens = stty_tokens(sane_stty)

      # raw slave: icanon and echo are CLEAR
      assert "-icanon" in raw_tokens
      assert "-echo" in raw_tokens

      # untouched slave: icanon and echo are SET
      assert "icanon" in sane_tokens
      assert "echo" in sane_tokens
    end

    # PTY-SELF-3: RECOVER resets a DELIBERATELY-stuck slave. The child puts
    # the tty into raw -echo and then hangs (a frozen/hung app in raw mode
    # -- pinned as stuck by SIGSTOP so it can't interfere); the documented
    # one-liner must bring the line discipline back to sane while the app
    # is still holding the tty. This is the "recovery is a passing test"
    # fact from the design doc, not a smoke assertion on a never-stuck tty.
    #
    # Measured constraint (macOS): once the child -- the pty's SESSION
    # LEADER -- dies and the last slave fd closes, the kernel resets the
    # pty's termios, so a reopened-slave probe after SIGKILL shows fresh
    # defaults, not residual raw. Residual-after-kill therefore can't be
    # asserted through this probe; residual-while-hung is the honest
    # cross-platform fact, and the byte-stream absence of teardown tokens
    # after SIGKILL stays covered by Oracle A in the T2d suite.
    test "PTY-SELF-3: RECOVER resets a deliberately-stuck slave to sane" do
      {:ok, session} =
        PtyHarness.start(["sh", "-c", "stty raw -echo; echo ARMED; sleep 30"])

      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "ARMED", 3_000)

      # freeze the app mid-raw-mode: stuck AND unresponsive
      assert :ok = PtyHarness.signal(session, :stop)
      assert {:ok, {:stopped, _}} = PtyHarness.await(session, 3_000)

      {:ok, stuck_stty} = PtyHarness.post_mortem(session)
      stuck_tokens = stty_tokens(stuck_stty)
      assert "-icanon" in stuck_tokens
      assert "-echo" in stuck_tokens

      # the documented recovery one-liner (ESC[r + stty sane)
      assert :ok = PtyHarness.recover(session)

      {:ok, recovered_stty} = PtyHarness.post_mortem(session)
      recovered_tokens = stty_tokens(recovered_stty)
      assert "icanon" in recovered_tokens
      assert "echo" in recovered_tokens
    end
  end

  describe "job control (WUNTRACED)" do
    # A stopped child must be observable as {:stopped, sig} -- distinct
    # from {:error, :timeout} -- for T25's Ctrl-Z/fg tests. SIGSTOP is used
    # here because the spawned child's process group is ORPHANED (session
    # leader, parent in another session) and POSIX discards default-action
    # SIGTSTP to orphaned process groups (measured: `signal(s, :tstp)` on
    # this `sh` never stops it). Real T25 targets HANDLE SIGTSTP (release
    # raw+region, then re-raise), and handled signals are not discarded --
    # so the discard rule doesn't weaken T25; it just makes plain-`sh`
    # smoke tests use the uncatchable stop signal.
    test "stopped child reports {:stopped, sig}; SIGCONT resumes; exit still observable" do
      {:ok, session} = PtyHarness.start(["sh", "-c", "echo READY; sleep 30"])
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 3_000)

      assert :ok = PtyHarness.signal(session, :stop)
      assert {:ok, {:stopped, stop_sig}} = PtyHarness.await(session, 3_000)
      assert stop_sig > 0

      # resume, then terminate: the stop did NOT reap the child, so the
      # eventual death is still observable through a later await.
      assert :ok = PtyHarness.signal(session, :cont)
      assert :ok = PtyHarness.signal(session, :kill)
      assert {:ok, {:signaled, 9}} = PtyHarness.await(session, 3_000)
    end
  end

  describe "start/2 consumer options" do
    test "winsize, env, and cwd reach the child" do
      cwd_dir =
        Path.join(
          System.tmp_dir!(),
          "raxol_pty_cwd_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(cwd_dir)
      on_exit(fn -> File.rm_rf!(cwd_dir) end)

      {:ok, session} =
        PtyHarness.start(
          ["sh", "-c", "stty size; echo MARKER=$TP_MARKER; pwd"],
          winsize: {40, 100},
          env: %{"TP_MARKER" => "tp_env_ok"},
          cwd: cwd_dir
        )

      on_exit(fn -> cleanup(session) end)

      assert {:ok, {:exit, 0}} = PtyHarness.await(session, 3_000)
      {:ok, output} = PtyHarness.read_output(session)

      # TIOCSWINSZ: `stty size` prints "rows cols"
      assert output =~ "40 100"
      # env merge
      assert output =~ "MARKER=tp_env_ok"
      # cwd (compare by unique basename -- /tmp may resolve to /private/tmp)
      assert output =~ Path.basename(cwd_dir)
    end
  end

  describe "dead-wrapper guard" do
    test "commands after stop/1 return {:error, :wrapper_exited}, not a crash" do
      {:ok, session} = PtyHarness.start(["sh", "-c", "echo BYE"])
      assert :ok = PtyHarness.await_capture(session, "BYE", 3_000)
      assert {:ok, {:exit, 0}} = PtyHarness.await(session, 3_000)

      :ok = PtyHarness.stop(session)
      on_exit(fn -> File.rm(session.capture_path) end)

      assert {:error, :wrapper_exited} = PtyHarness.signal(session, :term)
      assert {:error, :wrapper_exited} = PtyHarness.write(session, "x")
      assert {:error, :wrapper_exited} = PtyHarness.post_mortem(session)
      assert {:error, :wrapper_exited} = PtyHarness.await(session, 100)
    end
  end

  describe "availability guard" do
    test "available?/0 reflects whether python3 is on PATH" do
      assert PtyHarness.available?() ==
               (System.find_executable("python3") != nil)
    end
  end
end
