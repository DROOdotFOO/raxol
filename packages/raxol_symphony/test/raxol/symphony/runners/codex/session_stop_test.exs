defmodule Raxol.Symphony.Runners.Codex.SessionStopTest do
  @moduledoc """
  `Session.stop/1` runs in the `after` block of every codex run, so whatever it
  fails to clean up is left behind once per run.

  Closing the port delivers EOF, which stops a codex that is reading stdin and
  nothing else. These drive the two cases it does not cover, against real
  processes standing in for the app-server and the tools it spawns.
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Runners.Codex.Session

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

    Process.sleep(300)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp alive?(target) do
    {_out, status} = System.cmd("/bin/kill", ["-0", target], stderr_to_stdout: true)
    status == 0
  end

  test "stops a session that is not reading stdin" do
    # Wedged, or busy inside a turn: the EOF lands on a codex that never looks.
    {port, os_pid} = open_session_port("sleep 30")

    assert :ok = Session.stop(port)

    refute alive?("-#{os_pid}")
  end

  test "reaps the tool subprocesses a cleanly exited codex left behind" do
    {port, os_pid} = open_session_port("( sleep 30 ) & cat > /dev/null")

    assert :ok = Session.stop(port)

    refute alive?("-#{os_pid}"),
           "the app-server exits on EOF, but its tool subprocess does not"
  end

  test "accepts a session map and a already-dead port" do
    {port, os_pid} = open_session_port("sleep 30")

    assert :ok = Session.stop(%{port: port})
    refute alive?("-#{os_pid}")

    # Stopping twice must not raise on the already-closed port.
    assert :ok = Session.stop(port)
    assert :ok = Session.stop(nil)
  end
end
