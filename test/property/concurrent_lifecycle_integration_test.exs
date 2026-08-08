defmodule Raxol.Property.ConcurrentLifecycleIntegrationTest do
  @moduledoc """
  Whole-stack regression: starts N concurrent `:ssh` Lifecycles end-to-end
  and asserts they all init cleanly with distinct dispatcher pids and a
  shared plugin manager pid.

  This is the integration test for the singleton class of bugs surfaced
  by #228 and #229. The granular tests (`concurrent_ssh_lifecycle_test`
  and `concurrent_plugin_manager_test`) cover the Dispatcher and
  PluginManager layers individually. This test exercises both fixes
  together through `Raxol.Core.Runtime.Lifecycle.start_link/2`, which is
  the actual API SSH sessions use.

  If either fix regresses, this test fails immediately with a clear
  pointer to which singleton collision happened.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Lifecycle

  defmodule TestApp do
    @moduledoc false
    def init(_), do: {:ok, %{counter: 0}}
    def update(_, model), do: {model, []}
    def view(_), do: %{type: :text, content: "ok"}
  end

  defp ssh_opts(idx) do
    [
      environment: :ssh,
      width: 80,
      height: 24,
      io_writer: fn _ -> :ok end,
      name: :"test_ssh_session_#{idx}_#{System.unique_integer([:positive])}"
    ]
  end

  defp start_one(idx) do
    case Lifecycle.start_link(TestApp, ssh_opts(idx)) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_all(pids) do
    Enum.each(pids, fn pid ->
      try do
        Lifecycle.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp dispatcher_pid(lifecycle_pid) do
    state = :sys.get_state(lifecycle_pid, 5_000)
    state.dispatcher_pid
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp plugin_manager_pid(lifecycle_pid) do
    state = :sys.get_state(lifecycle_pid, 5_000)
    state.plugin_manager
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  describe "concurrent :ssh Lifecycles (regression for #228 + #229)" do
    test "four concurrent Lifecycles all init successfully" do
      results = for i <- 1..4, do: start_one(i)

      pids =
        for {:ok, pid} <- results, do: pid

      errors =
        for {:error, reason} <- results, do: reason

      assert errors == [],
             "all four Lifecycles should init successfully. " <>
               "Errors: #{inspect(errors)}\n" <>
               "If this fails with {:already_started, _} or " <>
               ":dispatcher_start_failed, regression of #228. " <>
               "If with :plugin_manager_start_failed, regression of #229."

      assert length(pids) == 4

      try do
        dispatchers =
          Enum.map(pids, &dispatcher_pid/1) |> Enum.reject(&is_nil/1)

        assert length(dispatchers) == 4,
               "every Lifecycle should expose a dispatcher pid"

        assert length(Enum.uniq(dispatchers)) == 4,
               "dispatcher pids must be distinct (regression of #228)"

        managers = Enum.map(pids, &plugin_manager_pid/1)

        assert managers == [nil, nil, nil, nil],
               "an :ssh session must own no PluginManager. It is a VM " <>
                 "singleton registered by name, so sessions could only ever " <>
                 "SHARE one -- and then the owner's link would carry any one " <>
                 "session's teardown into every other. Owning none removes " <>
                 "both the contention #229 hit and that cross-kill. Got: " <>
                 inspect(managers)
      after
        stop_all(pids)
      end
    end
  end
end
