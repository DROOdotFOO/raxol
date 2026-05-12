defmodule Mix.Tasks.Raxol.CheckDocs do
  @moduledoc """
  Validate documentation counts against actual code.

  Checks that hardcoded demo/category counts in CLAUDE.md match
  the catalog module, and flags stale counts in other doc files.

  ## Usage

      mix raxol.check_docs
  """

  use Mix.Task

  @shortdoc "Validate doc counts against catalog"

  @doc_files ~w[
    README.md
    CLAUDE.md
    docs/README.md
    docs/getting-started/COMPONENT_GALLERY.md
    docs/features/README.md
  ]

  # Patterns that should not appear in docs (stale hardcoded counts).
  # Updated each time the catalog changes.
  @stale_patterns [
    {~r/\b23 (widgets|demos|interactive demos)\b/i, "stale count '23'"},
    {~r/\b27 (demos|live demos)\b/i, "stale count '27'"},
    {~r/\b7 categories\b/i, "stale count '7 categories'"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    catalog_count = length(Raxol.Playground.Catalog.list_components())
    category_count = length(Raxol.Playground.Catalog.list_categories())

    errors = []

    # Check CLAUDE.md has correct counts
    errors = errors ++ check_claude_md(catalog_count, category_count)

    # Check all doc files for stale patterns
    errors = errors ++ check_stale_patterns()

    case errors do
      [] ->
        Mix.shell().info(
          "Docs OK: #{catalog_count} demos, #{category_count} categories"
        )

      _ ->
        Enum.each(errors, &Mix.shell().error("  #{&1}"))
        Mix.raise("Documentation drift detected (#{length(errors)} issues)")
    end
  end

  defp check_claude_md(expected_demos, expected_categories) do
    case File.read("CLAUDE.md") do
      {:ok, content} ->
        errors = []

        # Check playground line has correct demo count
        errors =
          if String.contains?(
               content,
               "#{expected_demos} demos across #{expected_categories} categories"
             ) do
            errors
          else
            [
              "CLAUDE.md: playground description should say '#{expected_demos} demos across #{expected_categories} categories'"
              | errors
            ]
          end

        errors

      {:error, _} ->
        ["CLAUDE.md: file not found"]
    end
  end

  defp check_stale_patterns do
    Enum.flat_map(@doc_files, &check_file_for_stale_patterns/1)
  end

  defp check_file_for_stale_patterns(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(&check_line_for_stale_patterns(path, &1))

      {:error, _} ->
        []
    end
  end

  defp check_line_for_stale_patterns(path, {line, line_num}) do
    Enum.flat_map(@stale_patterns, fn {regex, label} ->
      if Regex.match?(regex, line) do
        ["#{path}:#{line_num}: #{label} -- #{String.trim(line)}"]
      else
        []
      end
    end)
  end
end
