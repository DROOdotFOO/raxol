defmodule Raxol.Symphony.PortReaperTest do
  @moduledoc """
  `Port.close/1` signals nothing, so what a port's child does next is the
  child's own business. These drive the three behaviours that fall out of that,
  against real spawned processes:

    * a child that reads stdin exits on the EOF a close delivers
    * a child that does not read stdin ignores it entirely
    * a tool subprocess survives a parent that exited cleanly

  Liveness is asked of the OS (`kill -0`) rather than inferred from a witness
  file, since the question is whether a process is still running, not whether it
  got as far as some side effect.
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.PortReaper

  # Mirrors `Runners.Codex.Session.base_port_opts/0`: no `:in`, so stdin is a
  # live pipe and closing the port is what delivers EOF.
  defp open_child(script) do
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

    # Let bash get as far as spawning whatever the script spawns.
    Process.sleep(300)
    port
  end

  defp alive?(target) do
    {_out, status} = System.cmd("/bin/kill", ["-0", target], stderr_to_stdout: true)
    status == 0
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  describe "capture/1" do
    test "reports the child as its own process group leader" do
      port = open_child("sleep 30")

      assert {:group, pgid} = PortReaper.capture(port)
      assert {:os_pid, ^pgid} = Port.info(port, :os_pid)

      close(port)
      PortReaper.kill({:group, pgid})
    end

    test "is :none once the port is closed" do
      port = open_child("sleep 30")
      target = PortReaper.capture(port)
      close(port)
      PortReaper.kill(target)

      assert PortReaper.capture(port) == :none
    end
  end

  describe "kill/1" do
    test "kills a child that never reads stdin" do
      port = open_child("sleep 30")
      target = PortReaper.capture(port)
      {:group, pgid} = target

      close(port)
      assert alive?("-#{pgid}"), "closing the port must not be what stops it"

      assert :ok = PortReaper.kill(target)
      Process.sleep(200)
      refute alive?("-#{pgid}")
    end

    test "is a no-op for :none" do
      assert :ok = PortReaper.kill(:none)
    end
  end

  describe "await_exit/2" do
    test "reaps a tool subprocess that outlived a cleanly exited parent" do
      # The codex shape: the app-server exits on EOF, the tool it spawned does
      # not, and the group outlives its leader.
      port = open_child("( sleep 30 ) & cat > /dev/null")
      {:group, pgid} = target = PortReaper.capture(port)

      close(port)
      Process.sleep(400)

      refute alive?("#{pgid}"), "the parent should have exited on EOF"
      assert alive?("-#{pgid}"), "the orphaned tool should still hold the group"

      assert :ok = PortReaper.await_exit(target, 1_000)
      refute alive?("-#{pgid}")
    end

    test "returns as soon as a well-behaved child exits, without spending the grace" do
      port = open_child("cat > /dev/null")
      {:group, pgid} = target = PortReaper.capture(port)

      close(port)

      elapsed =
        wall_ms(fn ->
          assert :ok = PortReaper.await_exit(target, 10_000)
        end)

      refute alive?("-#{pgid}")

      # Bounded well under the grace: the point is that a clean exit is detected
      # rather than waited out. Generous enough not to be a timing race.
      assert elapsed < 5_000
    end

    test "is a no-op for :none" do
      assert :ok = PortReaper.await_exit(:none, 10_000)
    end
  end

  defp wall_ms(fun) do
    started = System.monotonic_time(:millisecond)
    fun.()
    System.monotonic_time(:millisecond) - started
  end
end
