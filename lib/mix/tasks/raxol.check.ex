defmodule Mix.Tasks.Raxol.Check do
  @moduledoc """
  Run comprehensive quality checks on the Raxol codebase.

  This task runs multiple quality checks in sequence:
  1. Compilation check
  2. Format check
  3. Credo analysis
  4. Dialyzer (if available)
  5. Security audit
  6. Test suite

  ## Usage

      mix raxol.check [OPTIONS]

  ## Options

    * `--only CHECKS` - Run only specific checks (comma-separated)
    * `--skip CHECKS` - Skip specific checks (comma-separated)
    * `--strict` - Run all checks in strict mode
    * `--quick` - Run only fast checks (skip dialyzer)

  ## Examples

      # Run all checks
      mix raxol.check

      # Run only format and compile checks
      mix raxol.check --only compile,format

      # Skip dialyzer
      mix raxol.check --skip dialyzer

      # Quick check (no dialyzer)
      mix raxol.check --quick
  """

  use Mix.Task
  alias Raxol.CLI.Colors
  alias Raxol.CLI.ErrorDisplay
  alias Raxol.CLI.Spinner

  @shortdoc "Run comprehensive quality checks"

  @all_checks [
    :lockfile,
    :compile,
    :format,
    :credo,
    :dialyzer,
    :security,
    :docs,
    :test
  ]
  @quick_checks [:lockfile, :compile, :format, :credo, :docs, :test]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          only: :string,
          skip: :string,
          strict: :boolean,
          quick: :boolean
        ]
      )

    checks = determine_checks(opts)
    total_checks = length(checks)

    Mix.shell().info(Colors.section_header("Raxol Quality Checks"))

    Mix.shell().info(
      Colors.muted("Running #{total_checks} checks: #{Enum.join(checks, ", ")}")
    )

    Mix.shell().info("")

    results =
      checks
      |> Enum.with_index(1)
      |> Enum.map(fn {check, index} ->
        Spinner.step(index, total_checks, "#{check}")
        run_check(check)
      end)

    print_summary(results)

    # Only fail on actual errors, not warnings or skipped checks
    case Enum.any?(results, fn {_, status} -> status == :error end) do
      true -> Mix.raise("Some checks failed")
      false -> :ok
    end
  end

  defp determine_checks(opts) do
    base_checks =
      cond do
        opts[:only] ->
          parse_check_list(opts[:only])

        opts[:quick] ->
          @quick_checks

        true ->
          @all_checks
      end

    # Apply skip filter after determining base checks
    case opts[:skip] do
      nil ->
        base_checks

      skip_str ->
        skip = parse_check_list(skip_str)
        Enum.reject(base_checks, &(&1 in skip))
    end
  end

  defp parse_check_list(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp run_check(:lockfile) do
    Mix.shell().info(Colors.subsection_header("Lockfile check"))

    case Mix.shell().cmd("mix deps.get --check-locked") do
      0 ->
        Mix.shell().info(
          "    " <> Colors.format_success("mix.lock is consistent with mix.exs")
        )

        {:lockfile, :ok}

      _ ->
        Mix.shell().error(
          "    " <>
            Colors.format_error(
              "mix.lock is out of date",
              "run `mix deps.get` and commit the updated mix.lock"
            )
        )

        {:lockfile, :error}
    end
  end

  defp run_check(:compile) do
    Mix.shell().info(Colors.subsection_header("Compilation check"))

    try do
      System.put_env("TMPDIR", "/tmp")
      System.put_env("SKIP_TERMBOX2_TESTS", "true")
      System.put_env("MIX_ENV", "test")

      Mix.Task.run("compile", ["--warnings-as-errors"])

      Mix.shell().info(
        "    " <> Colors.format_success("Compilation successful")
      )

      {:compile, :ok}
    rescue
      e ->
        Mix.shell().error(
          "    " <>
            Colors.format_error("Compilation failed", Exception.message(e))
        )

        # Display enhanced error with suggestions
        ErrorDisplay.display_error(e, %{
          check: :compile,
          operation: "compilation"
        })

        {:compile, :error}
    end
  end

  defp run_check(:format) do
    Mix.shell().info(Colors.subsection_header("Code formatting"))

    case Mix.shell().cmd("mix format --check-formatted") do
      0 ->
        Mix.shell().info(
          "    " <> Colors.format_success("Code is properly formatted")
        )

        {:format, :ok}

      _ ->
        Mix.shell().info(
          "    " <> Colors.format_warning("Code formatting issues found")
        )

        Mix.shell().info("    " <> Colors.format_fix("Fix", "mix format"))
        {:format, :warning}
    end
  end

  defp run_check(:credo) do
    Mix.shell().info(Colors.subsection_header("Credo analysis"))

    case Code.ensure_loaded?(Credo) do
      true ->
        case Mix.shell().cmd("mix credo --strict") do
          0 ->
            Mix.shell().info(
              "    " <> Colors.format_success("Credo analysis passed")
            )

            {:credo, :ok}

          _ ->
            Mix.shell().info(
              "    " <> Colors.format_warning("Credo found issues")
            )

            {:credo, :warning}
        end

      false ->
        Mix.shell().info("    " <> Colors.format_skip("Credo not available"))
        {:credo, :skipped}
    end
  end

  defp run_check(:dialyzer) do
    Mix.shell().info(Colors.subsection_header("Dialyzer"))

    case Code.ensure_loaded?(Dialyxir) do
      true ->
        case Mix.shell().cmd("mix dialyzer") do
          0 ->
            Mix.shell().info(
              "    " <> Colors.format_success("Dialyzer analysis passed")
            )

            {:dialyzer, :ok}

          _ ->
            Mix.shell().info(
              "    " <> Colors.format_warning("Dialyzer found issues")
            )

            {:dialyzer, :warning}
        end

      false ->
        Mix.shell().info("    " <> Colors.format_skip("Dialyzer not available"))
        {:dialyzer, :skipped}
    end
  end

  defp run_check(:security) do
    Mix.shell().info(Colors.subsection_header("Security audit"))

    case Code.ensure_loaded?(Sobelow) do
      true ->
        case Mix.shell().cmd("mix sobelow --config") do
          0 ->
            Mix.shell().info(
              "    " <> Colors.format_success("Security audit passed")
            )

            {:security, :ok}

          _ ->
            Mix.shell().info(
              "    " <> Colors.format_warning("Security issues found")
            )

            {:security, :warning}
        end

      false ->
        Mix.shell().info("    " <> Colors.format_skip("Sobelow not available"))
        {:security, :skipped}
    end
  end

  defp run_check(:docs) do
    Mix.shell().info(Colors.subsection_header("Documentation audit"))

    case Mix.shell().cmd("mix raxol.check_docs") do
      0 ->
        Mix.shell().info(
          "    " <> Colors.format_success("Documentation counts are current")
        )

        {:docs, :ok}

      _ ->
        Mix.shell().info(
          "    " <> Colors.format_warning("Documentation drift detected")
        )

        Mix.shell().info(
          "    " <>
            Colors.format_fix("Fix", "Update counts in docs to match catalog")
        )

        {:docs, :warning}
    end
  end

  defp run_check(:test) do
    Mix.shell().info(Colors.subsection_header("Test suite"))

    System.put_env("TMPDIR", "/tmp")
    System.put_env("SKIP_TERMBOX2_TESTS", "true")
    System.put_env("MIX_ENV", "test")

    exit_code =
      Mix.shell().cmd(
        "mix test --exclude slow --exclude integration --exclude docker --exclude benchmark --exclude skip_on_ci --max-failures 10"
      )

    format_test_result(exit_code)
  end

  defp run_check(unknown) do
    Mix.shell().error(Colors.format_error("Unknown check: #{unknown}"))
    {unknown, :error}
  end

  defp format_test_result(0) do
    Mix.shell().info("    " <> Colors.format_success("All tests passed"))
    {:test, :ok}
  end

  defp format_test_result(exit_code) do
    Mix.shell().error("    " <> Colors.format_error("Some tests failed"))

    ErrorDisplay.display_error(
      {:error, "Test suite failed with exit code #{exit_code}"},
      %{check: :test, operation: "test_suite", exit_code: exit_code}
    )

    print_test_quick_actions()
    {:test, :error}
  end

  defp print_test_quick_actions do
    Mix.shell().info("")
    Mix.shell().info("  " <> Colors.info("Quick actions:"))

    Mix.shell().info(
      "    " <> Colors.format_fix("Re-run failed tests", "mix test --failed")
    )

    Mix.shell().info(
      "    " <> Colors.format_fix("Run with seed 0", "mix test --seed 0")
    )

    Mix.shell().info(
      "    " <> Colors.format_fix("Increase verbosity", "mix test --trace")
    )

    Mix.shell().info("")
  end

  defp print_summary(results) do
    Mix.shell().info("")
    Mix.shell().info(Colors.divider("=", 40))
    Mix.shell().info(Colors.bold("Check Summary"))
    Mix.shell().info(Colors.divider("=", 40))

    Enum.each(results, fn {check, status} ->
      indicator = Colors.status_indicator(status)
      Mix.shell().info("  #{check}: #{indicator}")
    end)

    # Show counts
    counts = count_results(results)
    Mix.shell().info("")
    Mix.shell().info(format_counts(counts))
    Mix.shell().info("")
  end

  defp count_results(results) do
    Enum.reduce(results, %{ok: 0, warning: 0, error: 0, skipped: 0}, fn {_check,
                                                                         status},
                                                                        acc ->
      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  defp format_counts(%{
         ok: ok,
         warning: warning,
         error: error,
         skipped: skipped
       }) do
    parts =
      [
        {ok, Colors.success("#{ok} passed")},
        {warning, Colors.warning("#{warning} warnings")},
        {error, Colors.error("#{error} failed")},
        {skipped, Colors.muted("#{skipped} skipped")}
      ]
      |> Enum.filter(fn {count, _} -> count > 0 end)
      |> Enum.map(fn {_, str} -> str end)

    Enum.join(parts, " | ")
  end
end
