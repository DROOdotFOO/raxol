defmodule Raxol.Core.MetricsTest do
  # The collector and the aggregator are singletons registered under global names.
  use ExUnit.Case, async: false

  alias Raxol.Core.Metrics
  alias Raxol.Core.Metrics.{Aggregator, MetricsCollector}

  setup do
    stop_if_running(Aggregator)
    stop_if_running(MetricsCollector)
    on_exit(fn -> stop_if_running(MetricsCollector) end)
  end

  # `Raxol.Core.start_application/2` calls this during core init.
  test "init/1 starts metrics without the opt-in aggregator and alert manager" do
    assert :ok = Metrics.init([])

    assert :ok = Metrics.record("metrics_test_init", 3)

    assert {:ok, %{custom: %{"metrics_test_init" => [%{value: 3} | _]}}} =
             Metrics.get_metrics()
  end

  test "clear_metrics/0 clears the collector when no aggregator is running" do
    start_supervised!({MetricsCollector, auto_collect_system_metrics: false})
    assert :ok = Metrics.record("metrics_test_clear", 1)

    assert :ok = Metrics.clear_metrics()
    assert {:ok, metrics} = Metrics.get_metrics()
    assert metrics == %{}
  end

  defp stop_if_running(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, {:noproc, _} -> :ok
  end
end
