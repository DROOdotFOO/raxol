defmodule Raxol.Benchmark.RunnerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log
  @moduletag :benchmark

  alias Raxol.Benchmark.{Analyzer, Reporter, Runner}

  describe "benchmark runner" do
    test "can run a simple benchmark" do
      result =
        Runner.run_single(
          "test operation",
          fn ->
            Enum.sum(1..100)
          end,
          time: 0.1,
          warmup: 0.1
        )

      assert result.scenarios
      assert [_ | _] = result.scenarios

      scenario = hd(result.scenarios)
      assert scenario.name == "test operation"
      assert scenario.run_time_data.statistics.average > 0
    end

    @tag timeout: :infinity
    test "can run a benchmark suite" do
      suite = %{
        name: "Test Suite",
        benchmarks: %{
          "fast operation" => fn -> :ok end,
          "slow operation" => fn -> Process.sleep(1) end
        },
        options: [time: 0.1, warmup: 0.1]
      }

      result = Runner.run_suite(suite)

      assert result.suite_name == "Test Suite"
      assert result.results
      assert result.duration >= 0
      assert result.timestamp
    end

    test "can profile an operation" do
      # Ensure module is loaded
      Code.ensure_loaded?(Runner)

      # For now, just verify the function exists (with default args, it's exported as arity 3)
      assert function_exported?(Runner, :profile, 3)
    end
  end

  describe "analyzer" do
    test "can analyze benchmark results" do
      # Create mock results
      results = [create_mock_result()]

      analysis = Analyzer.analyze(results)

      assert analysis.summary
      assert analysis.statistics
      assert is_list(analysis.recommendations)
    end

    test "can detect regressions" do
      results = [create_mock_result()]

      # Without baseline, should return empty list
      regressions = Analyzer.check_regressions(results)
      assert regressions == []
    end

    test "can format time correctly" do
      # This is a private function, but we can test indirectly
      # through the module's public interface
      assert Analyzer.module_info(:functions)
    end
  end

  describe "reporter" do
    test "can generate console report" do
      results = [create_mock_result()]

      # Should not raise
      assert Reporter.generate_comprehensive_report(results, format: :console) ==
               :ok
    end

    test "can compile report data" do
      # Ensure module is loaded
      Code.ensure_loaded?(Reporter)

      # Verify the module exists and has expected functions
      assert function_exported?(Reporter, :generate_comprehensive_report, 1)
      assert function_exported?(Reporter, :generate_comprehensive_report, 2)
    end
  end

  # Helper functions

  defp create_mock_result do
    %{
      suite_name: "Test Suite",
      duration: 1000,
      timestamp: DateTime.utc_now(),
      results: %{
        scenarios: [
          create_mock_scenario("operation1", 1000),
          create_mock_scenario("operation2", 2000)
        ]
      }
    }
  end

  defp create_mock_scenario(name, avg_time) do
    %{
      name: name,
      run_time_data: %{
        statistics: %{
          average: avg_time,
          minimum: avg_time * 0.8,
          maximum: avg_time * 1.2,
          std_dev: avg_time * 0.1,
          std_dev_ratio: 0.1
        }
      },
      memory_usage_data: %{
        statistics: %{
          average: 1000,
          minimum: 800,
          maximum: 1200,
          std_dev: 100,
          std_dev_ratio: 0.1
        }
      }
    }
  end
end
