defmodule Raxol.Symphony.Runners.Codex.SessionStopTest do
  @moduledoc """
  `Session.stop/1` runs in the `after` block of every codex run, so whatever it
  fails to clean up is left behind once per run -- and it does not run at all
  when the run is killed outright, which is how the orchestrator tears workers
  down (`stop_run`, stall detection, reconcile-kill).

  Closing the port delivers EOF, which stops a codex that is reading stdin and
  nothing else. These drive the cases it does not cover, against real processes
  standing in for the app-server and the tools it spawns.
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.PortReaper
  alias Raxol.Symphony.Runners.Codex.Session

  @fake_codex Path.expand("../../../../support/fake_codex.sh", __DIR__)
  @wait_ms 5_000

  defp open_session_port(script) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:line, 1_048_576},
          {:cd, System.tmp_dir!()},
          {:args, ["-lc", script]}
        ]
      )

    # Waits on the script's own announcement, placed after whatever it spawns.
    receive do
      {^port, {:data, {:eol, "ready"}}} -> :ok
    after
      @wait_ms -> flunk("child never signalled ready")
    end

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp policy(overrides \\ []) do
    Enum.into(overrides, %{
      approval_policy: "never",
      thread_sandbox: "danger-full-access",
      turn_sandbox_policy: %{},
      read_timeout_ms: 2_000,
      turn_timeout_ms: 5_000,
      auto_approve?: true,
      dynamic_tools: []
    })
  end

  defp kill_exe, do: System.find_executable("kill") || "/bin/kill"

  defp alive?(target) do
    {_out, status} = System.cmd(kill_exe(), ["-0", target], stderr_to_stdout: true)
    status == 0
  end

  # A signal is delivered, not awaited: `kill` returns once the kernel has taken
  # it, and the target is a zombie until `erl_child_setup` reaps it. Polling for
  # the transition beats asserting it has already happened.
  defp wait_until(fun, timeout_ms \\ @wait_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end

  test "stops a session that is not reading stdin" do
    # Wedged, or busy inside a turn: the EOF lands on a codex that never looks.
    {port, os_pid} = open_session_port("echo ready; sleep 30")

    assert :ok = Session.stop(port)

    assert wait_until(fn -> not alive?("-#{os_pid}") end)
  end

  test "reaps the tool subprocesses a cleanly exited codex left behind" do
    {port, os_pid} = open_session_port("( sleep 30 ) & echo ready; cat > /dev/null")

    assert :ok = Session.stop(port)

    assert wait_until(fn -> not alive?("-#{os_pid}") end),
           "the app-server exits on EOF, but its tool subprocess does not"
  end

  test "accepts a session map and a already-dead port" do
    {port, os_pid} = open_session_port("echo ready; sleep 30")

    assert :ok = Session.stop(%{port: port})
    assert wait_until(fn -> not alive?("-#{os_pid}") end)

    # Stopping twice must not raise on the already-closed port.
    assert :ok = Session.stop(port)
    assert :ok = Session.stop(nil)
  end

  test "reaps the session when the owning process is killed outright" do
    # `Process.exit(pid, :kill)` does not run `try/after`, so the `after
    # Session.stop(session)` in `Codex.do_run/3` never fires. The orchestrator
    # tears workers down that way on all three of its teardown paths, and the
    # stall path is the one that matters -- it fires precisely when codex is
    # wedged, which is the case EOF cannot reach.
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, session} =
          Session.start(
            System.tmp_dir!(),
            @fake_codex,
            policy(),
            [{~c"FAKE_CODEX_SPAWN_SECONDS", ~c"30"}]
          )

        {:os_pid, os_pid} = Port.info(session.port, :os_pid)
        send(test_pid, {:started, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, os_pid}, @wait_ms
    assert alive?("-#{os_pid}")

    Process.exit(owner, :kill)

    assert wait_until(fn -> not alive?("-#{os_pid}") end),
           "the reap has to survive a caller that cannot run its own cleanup"
  end

  @tag :tmp_dir
  test "reaps a codex whose handshake never completed", %{tmp_dir: tmp_dir} do
    # Only a session that was successfully built ever reaches `stop/1`, so a
    # codex that fails to answer `initialize` was left running.
    pgid_file = Path.join(tmp_dir, "pgid")
    command = "( sleep 30 ) & echo $$ > #{pgid_file}; sleep 30"

    assert {:error, _} = Session.start(tmp_dir, command, policy(read_timeout_ms: 500))

    assert wait_until(fn -> File.exists?(pgid_file) end)
    pgid = pgid_file |> File.read!() |> String.trim()

    assert wait_until(fn -> not alive?("-#{pgid}") end)
  end

  test "a remote session waits longer than a local one before insisting" do
    # `ssh` does not exit on stdin EOF -- its clean teardown is a network round
    # trip -- so a local-sized grace SIGKILLs a well-behaved client partway
    # through one.
    local = Session.stop_grace_ms(nil)
    remote = Session.stop_grace_ms(%Raxol.Symphony.Worker.HostSpec{host: "worker-1"})

    assert remote > local
  end

  test "release/1 tolerates a session built without a watcher" do
    assert :ok = PortReaper.release(nil)
  end
end
