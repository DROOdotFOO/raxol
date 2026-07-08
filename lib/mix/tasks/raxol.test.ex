defmodule Mix.Tasks.Raxol.Test do
  @moduledoc """
  Enhanced test runner for the Raxol project.

  Provides additional test running capabilities beyond the standard mix test,
  including parallel execution, flaky test detection, and coverage reporting.

  ## Usage

      mix raxol.test [OPTIONS] [FILES]

  ## Options

    * `--parallel` - Run tests in parallel
    * `--coverage` - Generate coverage report
    * `--failed` - Run only previously failed tests
    * `--watch` - Watch files and re-run tests on changes
    * `--profile` - Profile test execution time
    * `--max-failures N` - Stop after N failures
    * `--seed N` - Set random seed
    * `--only TAG` - Run only tests with specific tag
    * `--exclude TAG` - Exclude tests with specific tag

  ## Examples

      # Run all tests
      mix raxol.test

      # Run tests with coverage
      mix raxol.test --coverage

      # Run only failed tests
      mix raxol.test --failed

      # Run specific test file
      mix raxol.test test/raxol/terminal/emulator_test.exs

      # Run tests in parallel
      mix raxol.test --parallel
  """

  use Mix.Task

  alias Raxol.CLI.Colors

  @shortdoc "Enhanced test runner with additional features"

  @test_switches [
    parallel: :boolean,
    coverage: :boolean,
    failed: :boolean,
    watch: :boolean,
    profile: :boolean,
    max_failures: :integer,
    seed: :integer,
    only: :string,
    exclude: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: @test_switches)
    set_test_env()
    dispatch_test_mode(opts, files)
  end

  defp set_test_env do
    System.put_env("TMPDIR", "/tmp")
    System.put_env("SKIP_TERMBOX2_TESTS", "true")
    System.put_env("MIX_ENV", "test")
  end

  defp dispatch_test_mode(opts, files) do
    cond do
      opts[:watch] -> run_watch_mode(opts, files)
      opts[:parallel] -> run_parallel_tests(opts, files)
      opts[:coverage] -> run_with_coverage(opts, files)
      opts[:profile] -> run_with_profiling(opts, files)
      true -> run_standard_tests(opts, files)
    end
  end

  defp run_standard_tests(opts, files) do
    Mix.shell().info(Colors.section_header("Running Raxol test suite"))

    test_args = build_test_args(opts, files)
    handle_test_result(Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}"))
  end

  defp run_parallel_tests(opts, files) do
    cores = System.schedulers_online()

    Mix.shell().info(Colors.section_header("Running tests in parallel"))
    Mix.shell().info(Colors.muted("Using #{cores} parallel processes"))
    Mix.shell().info("")

    test_args = build_test_args(opts, files)

    # Add partitions for parallel execution
    test_args = test_args ++ ["--partitions", "#{cores}"]
    handle_test_result(Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}"))
  end

  defp handle_test_result(0) do
    Mix.shell().info("")
    Mix.shell().info("  " <> Colors.success("[OK]") <> " All tests passed")
  end

  defp handle_test_result(_) do
    Mix.shell().info("")
    Mix.shell().error("  " <> Colors.error("[!!]") <> " Some tests failed")

    Mix.shell().info(
      "  " <>
        Colors.muted("Run") <>
        " " <>
        Colors.info("mix test --failed") <>
        " " <> Colors.muted("to re-run failed tests")
    )

    Mix.raise("Test suite failed")
  end

  defp run_with_coverage(opts, files) do
    Mix.shell().info(Colors.section_header("Running tests with coverage"))
    Mix.shell().info("")

    test_args = build_test_args(opts, files)
    test_args = ["--cover" | test_args]

    case Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}") do
      0 ->
        Mix.shell().info("")
        Mix.shell().info("  " <> Colors.success("[OK]") <> " All tests passed")
        show_coverage_summary()

      _ ->
        Mix.shell().info("")
        Mix.shell().error("  " <> Colors.error("[!!]") <> " Some tests failed")
        show_coverage_summary()
        Mix.raise("Test suite failed")
    end
  end

  defp run_with_profiling(opts, files) do
    Mix.shell().info(Colors.section_header("Running tests with profiling"))
    Mix.shell().info("")

    {result, duration} = timed_test_run(opts, files)

    Mix.shell().info("")

    Mix.shell().info(
      Colors.muted("Execution time: ") <> Colors.info("#{duration}ms")
    )

    handle_test_result(result)
  end

  defp timed_test_run(opts, files) do
    start_time = System.monotonic_time(:millisecond)

    test_args = ["--profile-tests" | build_test_args(opts, files)]
    result = Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}")

    duration = System.monotonic_time(:millisecond) - start_time
    {result, duration}
  end

  defp run_watch_mode(opts, files) do
    Mix.shell().info("Starting test watcher...")
    Mix.shell().info("Press Ctrl+C to stop")

    test_args = build_test_args(opts, files)

    # Initial run
    Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}")

    # Start file watcher
    {:ok, pid} = FileSystem.start_link(dirs: ["lib", "test"])
    FileSystem.subscribe(pid)

    watch_loop(test_args)
  end

  defp watch_loop(test_args) do
    receive do
      {:file_event, _pid, {path, _events}} ->
        if String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") do
          Mix.shell().info("\nFile changed: #{path}")
          Mix.shell().info("Re-running tests...")
          Mix.shell().cmd("mix test #{Enum.join(test_args, " ")}")
        end

        watch_loop(test_args)

      _ ->
        watch_loop(test_args)
    end
  end

  defp build_test_args(opts, files) do
    args = []

    # Add exclusions for slow tests by default
    args = [
      "--exclude",
      "slow",
      "--exclude",
      "integration",
      "--exclude",
      "docker" | args
    ]

    # Add options
    args = if opts[:failed], do: ["--failed" | args], else: args

    args =
      if opts[:max_failures],
        do: ["--max-failures", "#{opts[:max_failures]}" | args],
        else: args

    args = if opts[:seed], do: ["--seed", "#{opts[:seed]}" | args], else: args
    args = if opts[:only], do: ["--only", opts[:only] | args], else: args

    args =
      if opts[:exclude] && opts[:exclude] != "",
        do: ["--exclude", opts[:exclude] | args],
        else: args

    # Add files
    args ++ files
  end

  defp show_coverage_summary do
    Mix.shell().info("")
    Mix.shell().info("Coverage Summary:")
    Mix.shell().info("-----------------")

    # Read coverage data if available
    cover_dir = "cover"

    if File.exists?(cover_dir) do
      # This would parse and display coverage data
      Mix.shell().info("Coverage report generated in #{cover_dir}/")
    else
      Mix.shell().info("No coverage data available")
    end
  end
end
