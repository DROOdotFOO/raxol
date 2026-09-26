defmodule Raxol.Core.Runtime.Lifecycle.ShutdownTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Raxol.Core.Runtime.Lifecycle.Shutdown

  describe "stop_process/2" do
    test "no-ops on nil pid" do
      assert :ok = Shutdown.stop_process(nil, "test")
    end

    test "stops a live GenServer process" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :running end)
      assert Process.alive?(pid)

      Shutdown.stop_process(pid, "test_agent")

      refute Process.alive?(pid)
    end

    test "handles already-dead process gracefully" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :running end)
      Agent.stop(pid)
      refute Process.alive?(pid)

      assert Shutdown.stop_process(pid, "dead_agent") == :ok
    end
  end

  # capture_log sees every process's events, so each test tells its own apart
  # by content.
  describe "quietly/3" do
    test "drops the events of the caller and the listed processes, and no others" do
      child = start_logger()
      bystander = start_logger()

      log =
        capture_log(fn ->
          Shutdown.quietly(true, [child], fn ->
            Logger.error("logged by the teardown itself")
            log_in(child, "logged by a child being stopped")
            log_in(bystander, "logged by a bystander")
          end)
        end)

      refute log =~ "logged by the teardown itself"
      refute log =~ "logged by a child being stopped"
      assert log =~ "logged by a bystander"
    end

    # `after` does not run in a killed process. A supervisor's shutdown
    # timeout can kill a Lifecycle mid-teardown.
    test "a teardown killed half-way leaves logging as it found it" do
      filters = primary_filters()
      teardown = start_teardown()
      Process.unlink(teardown)
      ref = Process.monitor(teardown)

      Process.exit(teardown, :kill)
      assert_receive {:DOWN, ^ref, :process, ^teardown, :killed}

      assert eventually(fn -> primary_filters() == filters end),
             "the killed teardown's filter is still installed: #{inspect(primary_filters())}"

      assert capture_log(fn ->
               Logger.error("logged after the teardown was killed")
             end) =~
               "logged after the teardown was killed"
    end

    test "concurrent teardowns each lift only their own silence" do
      filters = primary_filters()
      first = start_teardown()
      second = start_teardown()

      finish_teardown(first)

      log =
        capture_log(fn ->
          log_in(first, "logged by the finished teardown")
          log_in(second, "logged by the running teardown")
        end)

      assert log =~ "logged by the finished teardown"
      refute log =~ "logged by the running teardown"

      finish_teardown(second)
      assert primary_filters() == filters
    end
  end

  describe "cleanup_plugin_manager/2" do
    test "no-ops on nil" do
      assert :ok = Shutdown.cleanup_plugin_manager(nil, %{})
    end

    test "no-ops on false" do
      assert :ok = Shutdown.cleanup_plugin_manager(false, %{})
    end

    test "stops plugin manager when true and process alive" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :pm_state end)
      state = %{plugin_manager: pid}

      Shutdown.cleanup_plugin_manager(true, state)

      refute Process.alive?(pid)
    end
  end

  describe "cleanup_registry_table/2" do
    test "no-ops on nil" do
      assert :ok = Shutdown.cleanup_registry_table(nil, %{})
    end

    test "no-ops on false" do
      assert :ok = Shutdown.cleanup_registry_table(false, %{})
    end

    test "deletes existing ETS table when true" do
      table_name = :shutdown_test_table
      :ets.new(table_name, [:set, :named_table, :public])
      state = %{command_registry_table: table_name}

      Shutdown.cleanup_registry_table(true, state)

      assert :ets.info(table_name) == :undefined
    end

    test "handles non-existent table gracefully" do
      state = %{command_registry_table: :nonexistent_table_xyz}

      # Should not raise
      Shutdown.cleanup_registry_table(true, state)
    end
  end

  defp primary_filters, do: :logger.get_primary_config().filters

  # A process that logs on request and acknowledges once the event is out.
  defp start_logger do
    spawn_link(fn -> serve_logs(nil) end)
  end

  # A process that logs on request from inside `quietly/3` until told to
  # finish, then keeps logging on request outside it.
  defp start_teardown do
    test_pid = self()

    pid =
      spawn_link(fn ->
        Shutdown.quietly(true, [], fn ->
          send(test_pid, {:tearing_down, self()})
          serve_logs(:finish)
        end)

        send(test_pid, {:finished, self()})
        serve_logs(nil)
      end)

    assert_receive {:tearing_down, ^pid}
    pid
  end

  defp finish_teardown(pid) do
    send(pid, :finish)
    assert_receive {:finished, ^pid}
  end

  defp serve_logs(stop_on) do
    receive do
      {:log, from, message} ->
        Logger.error(message)
        send(from, {:logged, self()})
        serve_logs(stop_on)

      ^stop_on ->
        :ok
    end
  end

  defp log_in(pid, message) do
    send(pid, {:log, self(), message})
    assert_receive {:logged, ^pid}
  end

  defp eventually(check, tries \\ 200) do
    cond do
      check.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, tries - 1)
    end
  end
end
