defmodule Raxol.Performance.CycleProfiler.StatsTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Performance.CycleProfiler.Stats

  describe "compute/1" do
    test "returns nil for empty list" do
      assert Stats.compute([]) == nil
    end

    test "computes stats for a single value" do
      result = Stats.compute([100])
      assert result.count == 1
      assert result.min == 100
      assert result.max == 100
      assert result.avg == 100.0
      assert result.p50 == 100
    end

    test "computes correct min/max/avg" do
      result = Stats.compute([10, 20, 30, 40, 50])
      assert result.count == 5
      assert result.min == 10
      assert result.max == 50
      assert result.avg == 30.0
    end

    test "computes percentiles" do
      values = Enum.to_list(1..100)
      result = Stats.compute(values)

      assert result.p50 == 50
      assert result.p95 == 95
      assert result.p99 == 99
    end

    test "handles unsorted input" do
      result = Stats.compute([50, 10, 30, 40, 20])
      assert result.min == 10
      assert result.max == 50
      assert result.avg == 30.0
    end
  end

  describe "format_report/2" do
    test "formats nil stats" do
      assert Stats.format_report(nil, "test") == "test: no data"
    end

    test "formats stats with label" do
      stats = Stats.compute([1000, 2000, 3000])
      report = Stats.format_report(stats, "update")
      assert report =~ "update:"
      assert report =~ "avg="
      assert report =~ "p95="
      assert report =~ "n=3"
    end

    test "formats microseconds correctly" do
      stats = Stats.compute([500])
      report = Stats.format_report(stats, "x")
      assert report =~ "us"
    end

    test "formats milliseconds for larger values" do
      stats = Stats.compute([5_000])
      report = Stats.format_report(stats, "x")
      assert report =~ "ms"
    end
  end

  describe "compute_multi/2" do
    test "computes stats for multiple fields" do
      entries = [
        %{view_us: 100, layout_us: 200},
        %{view_us: 150, layout_us: 250},
        %{view_us: 200, layout_us: 300}
      ]

      result = Stats.compute_multi(entries, [:view_us, :layout_us])

      assert result.view_us.avg == 150.0
      assert result.layout_us.avg == 250.0
    end

    test "handles missing fields" do
      entries = [%{view_us: 100}, %{view_us: 200}]
      result = Stats.compute_multi(entries, [:view_us, :missing])

      assert result.view_us.count == 2
      assert result.missing == nil
    end
  end
end
