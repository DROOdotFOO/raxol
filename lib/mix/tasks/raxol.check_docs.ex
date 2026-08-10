defmodule Mix.Tasks.Raxol.CheckDocs do
  @moduledoc """
  Validate documentation against the code and the house prose rules.

  Two independent checks:

    * **Counts.** Playground demo and category counts quoted in prose are
      compared against `Raxol.Playground.Catalog`, so a doc cannot claim a
      number the catalog does not produce.
    * **Prose.** Every tracked `.md` is linted by `Raxol.Docs.ProseLint`:
      unicode punctuation, ` -- ` as an em-dash substitute, broken relative
      links and anchors. Title Case headings are opt-in via `--headings`.

  ## Usage

      mix raxol.check_docs                    # everything, all tracked Markdown
      mix raxol.check_docs --only prose       # skip the catalog counts
      mix raxol.check_docs --only counts      # skip the prose lint
      mix raxol.check_docs --files a.md b.md  # lint just these (pre-commit hook)
      mix raxol.check_docs --headings         # add the opt-in heading-case sweep
      mix raxol.check_docs --headings --warnings-as-errors

  Heading case is off by default and warning-only when enabled: proper nouns are
  indistinguishable from common words without a dictionary. Use `--headings` for
  a sweep, and `--warnings-as-errors` to make it fail.
  """

  use Mix.Task

  alias Raxol.Docs.ProseLint

  @shortdoc "Validate docs against the catalog and the prose rules"

  @switches [
    only: :string,
    files: :keep,
    headings: :boolean,
    warnings_as_errors: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    only = opts[:only]
    files = Keyword.get_values(opts, :files)

    count_errors = if only in [nil, "counts"], do: check_counts(), else: []
    findings = if only in [nil, "prose"], do: lint(files, opts), else: []

    {errors, warnings} = Enum.split_with(findings, &(&1.severity == :error))
    report(warnings, "warning")
    report(errors, "error")

    fatal =
      length(count_errors) + length(errors) +
        if(opts[:warnings_as_errors], do: length(warnings), else: 0)

    Enum.each(count_errors, &Mix.shell().error("  #{&1}"))

    if fatal > 0 do
      Mix.raise("Documentation drift detected (#{fatal} issues)")
    else
      Mix.shell().info(summary(only, files, warnings))
    end
  end

  # --- prose --------------------------------------------------------------

  defp lint([], opts), do: lint(tracked_markdown(), opts)

  defp lint(files, opts) do
    lint_opts = [headings: Keyword.get(opts, :headings, false)]

    files
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reject(&(String.contains?(&1, "node_modules/") or vendored?(&1)))
    |> Enum.flat_map(&ProseLint.check_file(&1, lint_opts))
    |> Enum.sort_by(&{&1.path, &1.line})
  end

  # Upstream sources we re-publish unmodified. Rewriting their prose would make
  # the vendored copy diverge from the thing it is a copy of.
  defp vendored?(path), do: String.contains?(path, "termbox2/README.md")

  defp tracked_markdown do
    case System.cmd("git", ["ls-files", "*.md"], stderr_to_stdout: true) do
      {out, 0} ->
        String.split(out, "\n", trim: true)

      _ ->
        Path.wildcard("{docs,packages,examples,web,test}/**/*.md") ++
          Path.wildcard("*.md")
    end
  end

  defp report([], _label), do: :ok

  defp report(findings, label) do
    Mix.shell().error("\n#{length(findings)} #{label}(s):")

    Enum.each(findings, fn f ->
      Mix.shell().error("  #{f.path}:#{f.line}  [#{f.rule}] #{f.message}")
      Mix.shell().error("      #{truncate(f.text)}")
    end)
  end

  defp truncate(text) when byte_size(text) > 120,
    do: binary_part(text, 0, 117) <> "..."

  defp truncate(text), do: text

  defp summary(only, files, warnings) do
    scope =
      if files == [],
        do: "all tracked Markdown",
        else: "#{length(files)} file(s)"

    warn =
      if warnings == [],
        do: "",
        else: " (#{length(warnings)} heading warning(s))"

    case only do
      "prose" -> "Docs OK: prose clean across #{scope}#{warn}"
      "counts" -> "Docs OK: catalog counts match"
      _ -> "Docs OK: catalog counts match, prose clean across #{scope}#{warn}"
    end
  end

  # --- counts -------------------------------------------------------------

  defp check_counts do
    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    demos = length(Raxol.Playground.Catalog.list_components())
    categories = length(Raxol.Playground.Catalog.list_categories())

    check_claude_md(demos, categories) ++ check_stale_counts(demos, categories)
  end

  defp check_claude_md(demos, categories) do
    expected = "#{demos} demos across #{categories} categories"

    case File.read("CLAUDE.md") do
      {:ok, content} ->
        if String.contains?(content, expected),
          do: [],
          else: ["CLAUDE.md: playground description should say '#{expected}'"]

      {:error, _} ->
        ["CLAUDE.md: file not found"]
    end
  end

  # Any "<n> demos" / "<n> categories" claim that disagrees with the catalog.
  # Derived from the catalog rather than a hand-maintained list of stale
  # numbers, so it does not need editing when the catalog changes.
  #
  # "widgets" is deliberately not a synonym for "demos": the MCP docs count
  # Component types that implement `ToolProvider`, which is a different number.
  defp check_stale_counts(demos, categories) do
    patterns = [
      {~r/\b(\d+) (?:interactive |live )?demos\b/i, demos, "demos"},
      {~r/\b(\d+) categories\b/i, categories, "categories"}
    ]

    for path <- tracked_markdown(),
        not String.contains?(path, "node_modules/"),
        # CHANGELOGs quote the count that was true for that release.
        not String.ends_with?(path, "CHANGELOG.md"),
        {:ok, content} <- [File.read(path)],
        {line, num} <- Enum.with_index(String.split(content, "\n"), 1),
        {regex, expected, label} <- patterns,
        [_, found] <- [Regex.run(regex, line)],
        String.to_integer(found) != expected do
      "#{path}:#{num}: says #{found} #{label}, catalog has #{expected}: #{String.trim(line)}"
    end
  end
end
