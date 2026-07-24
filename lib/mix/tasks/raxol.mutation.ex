defmodule Mix.Tasks.Raxol.Mutation do
  use Mix.Task

  @shortdoc "Run mutation testing on Raxol core modules"

  @moduledoc """
  Custom mutation testing for Raxol using simplified approach.

  This task provides basic mutation testing capabilities when full
  mutation testing tools have compatibility issues.

  ## Usage

      mix raxol.mutation [options]

  ## Options

    * `--target` - Target module or file to mutate (default: all core modules)
    * `--mutations` - Number of mutations to generate (default: 10)
    * `--operators` - Mutation operators to use (default: arithmetic,boolean)
    * `--report` - Generate detailed report (default: true)
    * `--timeout` - Test timeout per mutation (default: 30s)

  ## Examples

      # Run basic mutation testing
      mix raxol.mutation

      # Test specific module with more mutations
      mix raxol.mutation --target lib/raxol/core/state_manager.ex --mutations 20

      # Quick check with limited operators
      mix raxol.mutation --operators arithmetic --mutations 5

  ## Mutation Types

  This tool implements basic mutation operators:
  1. **Arithmetic**: +, -, *, / operator changes
  2. **Boolean**: and/or, true/false flips
  3. **Comparison**: ==, !=, <, > changes
  4. **Conditional**: if/unless, positive/negative conditions

  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.UI.TextMeasure

  @switches [
    target: :string,
    mutations: :integer,
    operators: :string,
    report: :boolean,
    timeout: :integer,
    help: :boolean
  ]

  @aliases [
    t: :target,
    m: :mutations,
    h: :help
  ]

  @spec run(list()) :: no_return()
  def run(args) do
    {options, _remaining_args, _} =
      OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case options[:help] do
      true -> print_help()
      _ -> run_mutation_testing(options)
    end
  end

  defp run_mutation_testing(options) do
    # Ensure test environment
    Mix.env(:test)

    # Configure mutation testing
    config = configure_mutation_testing(options)

    Log.info("Starting mutation testing...")
    Log.info("   Target: #{config.target}")
    Log.info("   Mutations: #{config.mutations}")
    Log.info("   Operators: #{Enum.join(config.operators, ", ")}")

    # Run mutation analysis
    results = run_mutation_analysis(config)

    # Generate report
    generate_mutation_report(results, config)

    print_summary(results)
  end

  defp print_help do
    Log.info(@moduledoc)
  end

  defp configure_mutation_testing(options) do
    %{
      target: options[:target] || "lib/raxol/core/**/*.ex",
      mutations: options[:mutations] || 10,
      operators: parse_operators(options[:operators] || "arithmetic,boolean"),
      # Convert to ms
      timeout: (options[:timeout] || 30) * 1000,
      report: options[:report] != false
    }
  end

  defp parse_operators(operator_string) do
    operator_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp run_mutation_analysis(config) do
    target_files = discover_and_log_targets(config)
    baseline_result = run_and_check_baseline()
    mutations_results = generate_and_test_mutations(target_files, config)

    build_analysis_results(target_files, baseline_result, mutations_results)
  end

  defp discover_and_log_targets(config) do
    Log.info("\nAnalyzing target files...")
    target_files = discover_target_files(config.target)
    Log.info("   Found #{length(target_files)} files to analyze")
    target_files
  end

  defp run_and_check_baseline do
    Log.info("\nRunning baseline tests...")
    baseline_result = run_tests()
    handle_baseline_result(baseline_result)
    baseline_result
  end

  defp generate_and_test_mutations(target_files, config) do
    Log.info("\nGenerating mutations...")

    target_files
    |> Enum.take(min(3, length(target_files)))
    |> Enum.flat_map(&generate_mutations_for_file(&1, config))
    |> Enum.take(config.mutations)
    |> Enum.with_index(1)
    |> Enum.map(fn {mutation, index} ->
      test_mutation(mutation, index, config)
    end)
  end

  defp build_analysis_results(target_files, baseline_result, mutations_results) do
    %{
      target_files: target_files,
      baseline: baseline_result,
      mutations: mutations_results,
      total_mutations: length(mutations_results),
      killed_mutations: Enum.count(mutations_results, & &1.killed),
      survived_mutations: Enum.count(mutations_results, &(not &1.killed))
    }
  end

  # Using pattern matching instead of if/else
  defp handle_baseline_result(%{failures: failures} = result)
       when failures > 1 do
    Log.info(
      "ERROR: Too many baseline test failures (#{result.failures})! Fix tests before mutation testing."
    )

    System.halt(1)
  end

  defp handle_baseline_result(%{failures: 1}) do
    Log.info(
      "WARNING: Found 1 baseline test failure - continuing with mutation testing..."
    )
  end

  defp handle_baseline_result(%{failures: 0, tests: tests} = _result) do
    Log.info("OK: Baseline tests pass (#{tests} tests)")
  end

  defp discover_target_files(target_pattern) do
    get_target_files(target_pattern)
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reject(&String.contains?(&1, "test"))
  end

  # Pattern matching instead of nested if
  defp get_target_files(pattern) when is_binary(pattern) do
    case {String.contains?(pattern, "*"), File.exists?(pattern)} do
      {true, _} -> Path.wildcard(pattern)
      {false, true} -> [pattern]
      {false, false} -> Path.wildcard("lib/raxol/core/**/*.ex")
    end
  end

  defp generate_mutations_for_file(file_path, config) do
    content = File.read!(file_path)

    config.operators
    |> Enum.flat_map(fn operator ->
      apply_mutation_operator(operator, file_path, content)
    end)
  end

  defp apply_mutation_operator(:arithmetic, file_path, content) do
    generate_arithmetic_mutations(file_path, content)
  end

  defp apply_mutation_operator(:boolean, file_path, content) do
    generate_boolean_mutations(file_path, content)
  end

  defp apply_mutation_operator(:comparison, file_path, content) do
    generate_comparison_mutations(file_path, content)
  end

  defp apply_mutation_operator(_, _, _), do: []

  defp generate_arithmetic_mutations(file_path, content) do
    # Simple regex-based mutation generation (real tools use AST)
    mutations = [
      {~r/\s\+\s/, " - "},
      {~r/\s-\s/, " + "},
      {~r/\s\*\s/, " / "},
      {~r/\s\/\s/, " * "}
    ]

    mutations
    |> Enum.flat_map(fn {pattern, replacement} ->
      create_mutation_if_match(
        pattern,
        replacement,
        file_path,
        content,
        :arithmetic
      )
    end)
  end

  defp generate_boolean_mutations(file_path, content) do
    # Boolean mutations
    mutations = [
      {~r/\strue\s/, " false "},
      {~r/\sfalse\s/, " true "},
      {~r/\sand\s/, " or "},
      {~r/\sor\s/, " and "}
    ]

    mutations
    |> Enum.flat_map(fn {pattern, replacement} ->
      create_mutation_if_match(
        pattern,
        replacement,
        file_path,
        content,
        :boolean
      )
    end)
  end

  defp generate_comparison_mutations(file_path, content) do
    # Comparison mutations
    mutations = [
      {~r/\s==\s/, " != "},
      {~r/\s!=\s/, " == "},
      {~r/\s<\s/, " > "},
      {~r/\s>\s/, " < "}
    ]

    mutations
    |> Enum.flat_map(fn {pattern, replacement} ->
      create_mutation_if_match(
        pattern,
        replacement,
        file_path,
        content,
        :comparison
      )
    end)
  end

  defp create_mutation_if_match(pattern, replacement, file_path, content, type) do
    case Regex.run(pattern, content, return: :index) do
      nil ->
        []

      [{start, length}] ->
        [
          %{
            file: file_path,
            type: type,
            # BYTE offset from `return: :index` -- `String.slice/3` counts
            # graphemes, so any non-ASCII earlier in the source file made
            # `original` a mis-cut (possibly mid-character) fragment.
            original: TextMeasure.slice_bytes(content, {start, length}),
            mutated: replacement,
            position: start,
            content:
              String.replace(content, pattern, replacement, global: false)
          }
        ]

      _ ->
        []
    end
  end

  defp test_mutation(mutation, index, config) do
    IO.write(
      "   Testing mutation #{index}/#{config.mutations}: #{mutation.type} in #{Path.basename(mutation.file)}... "
    )

    # Create temporary mutated file
    backup_content = File.read!(mutation.file)
    temp_file = mutation.file <> ".mutated"

    try do
      # Write mutated content
      File.write!(temp_file, mutation.content)
      File.cp!(temp_file, mutation.file)

      # Run tests with timeout
      test_result = run_tests_with_timeout(config.timeout)

      # Determine if mutation was killed
      killed = test_result.failures > 0 or test_result.errors > 0

      Log.info(mutation_status_text(killed))

      %{
        mutation: mutation,
        index: index,
        killed: killed,
        test_result: test_result
      }
    rescue
      error ->
        Log.info("ERROR (#{inspect(error)})")

        %{
          mutation: mutation,
          index: index,
          # Compilation errors count as killed
          killed: true,
          test_result: %{errors: 1, failures: 0, tests: 0},
          error: error
        }
    after
      # Restore original file
      File.write!(mutation.file, backup_content)
      File.rm(temp_file)
    end
  end

  defp mutation_status_text(true), do: "KILLED"
  defp mutation_status_text(false), do: "SURVIVED"

  defp run_tests do
    # Simplified test runner
    {output, exit_code} =
      System.cmd(
        "mix",
        [
          "test",
          "--exclude",
          "slow",
          "--exclude",
          "integration",
          "--exclude",
          "docker"
        ],
        env: [
          {"SKIP_TERMBOX2_TESTS", "true"},
          {"TMPDIR", "/tmp"},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    # Parse basic results from output
    tests = extract_test_count(output)
    failures = determine_failure_count(exit_code, output)

    %{tests: tests, failures: failures, errors: 0, exit_code: exit_code}
  rescue
    _ -> %{tests: 0, failures: 1, errors: 1, exit_code: 1}
  end

  defp determine_failure_count(0, _output), do: 0

  defp determine_failure_count(_exit_code, output),
    do: extract_failure_count(output)

  defp run_tests_with_timeout(timeout) do
    # Run tests with timeout
    task = Task.async(fn -> run_tests() end)

    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        %{tests: 0, failures: 0, errors: 1, exit_code: 1, timeout: true}
    end
  end

  defp extract_test_count(output) do
    case Regex.run(~r/(\d+) tests?/, output) do
      [_, count_str] -> String.to_integer(count_str)
      _ -> 0
    end
  end

  defp extract_failure_count(output) do
    case Regex.run(~r/(\d+) failures?/, output) do
      [_, count_str] -> String.to_integer(count_str)
      _ -> 0
    end
  end

  defp generate_mutation_report(_results, %{report: false}), do: :ok

  defp generate_mutation_report(results, %{report: true}) do
    report_content = generate_report_content(results)

    report_file =
      "mutation_test_report_#{DateTime.to_unix(DateTime.utc_now())}.md"

    File.write!(report_file, report_content)
    Log.info("\nDetailed report saved to: #{report_file}")
  end

  defp generate_report_content(results) do
    """
    # Mutation Testing Report

    **Generated:** #{DateTime.to_iso8601(DateTime.utc_now())}

    ## Summary

    - **Total Mutations:** #{results.total_mutations}
    - **Killed Mutations:** #{results.killed_mutations}
    - **Survived Mutations:** #{results.survived_mutations}
    - **Mutation Score:** #{calculate_mutation_score(results)}%

    ## Baseline Tests

    - **Tests:** #{results.baseline.tests}
    - **Failures:** #{results.baseline.failures}
    - **Status:** #{baseline_status_text(results.baseline.failures)}

    ## Mutation Results

    #{generate_mutations_table(results.mutations)}

    ## Recommendations

    #{generate_recommendations(results)}
    """
  end

  defp baseline_status_text(0), do: "PASS"
  defp baseline_status_text(_), do: "FAIL"

  defp calculate_mutation_score(%{total_mutations: 0}), do: 0.0

  defp calculate_mutation_score(results) do
    (results.killed_mutations / results.total_mutations * 100) |> Float.round(1)
  end

  defp generate_mutations_table(mutations) do
    mutations
    |> Enum.map_join("\n", fn mutation ->
      status = mutation_table_status(mutation.killed)

      "| #{mutation.index} | #{mutation.mutation.type} | #{Path.basename(mutation.mutation.file)} | #{status} |"
    end)
    |> then(fn rows ->
      "| # | Type | File | Status |\n|---|------|------|--------|\n#{rows}"
    end)
  end

  defp mutation_table_status(true), do: "KILLED"
  defp mutation_table_status(false), do: "SURVIVED"

  defp generate_recommendations(results) do
    mutation_score = calculate_mutation_score(results)

    cond do
      mutation_score >= 80 ->
        "Excellent mutation score! Your tests are catching most bugs effectively."

      mutation_score >= 60 ->
        "Good mutation score, but consider adding more edge case tests."

      mutation_score >= 40 ->
        "Moderate mutation score. Focus on testing error conditions and edge cases."

      true ->
        "Low mutation score. Significant test coverage gaps detected. Add comprehensive tests."
    end
  end

  defp print_summary(results) do
    mutation_score = calculate_mutation_score(results)

    Log.info("\nMutation Testing Summary")
    Log.info("==========================")
    Log.info("   Total mutations: #{results.total_mutations}")
    Log.info("   Killed: #{results.killed_mutations}")
    Log.info("   Survived: #{results.survived_mutations}")
    Log.info("   Mutation score: #{mutation_score}%")

    # Show survived mutations (potential test gaps)
    print_survived_mutations(results)

    Log.info("\nRecommendation: #{generate_recommendations(results)}")
  end

  defp print_survived_mutations(%{mutations: mutations}) do
    survived = Enum.reject(mutations, & &1.killed)

    case survived do
      [] ->
        :ok

      mutations ->
        Log.info("\nWARNING: Survived mutations (potential test gaps):")
        Enum.each(mutations, &print_mutation_details/1)
    end
  end

  defp print_mutation_details(mutation) do
    Log.info(
      "   - #{mutation.mutation.type} in #{Path.basename(mutation.mutation.file)}"
    )

    Log.info(
      "     Changed: #{String.trim(mutation.mutation.original)} -> #{String.trim(mutation.mutation.mutated)}"
    )
  end
end
