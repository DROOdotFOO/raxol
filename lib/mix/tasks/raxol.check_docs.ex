defmodule Mix.Tasks.Raxol.CheckDocs do
  @moduledoc """
  Validate documentation against the code and the house prose rules.

  Two independent checks:

    * **Counts.** Demo and category counts quoted in prose are compared
      against `Raxol.Playground.Catalog`, and widget counts against
      `Raxol.UI.Registry`, so a doc cannot claim a number neither produces.
      The two sources are kept apart: a demo is a runnable example, a widget
      is a declaration type, and the counts are not the same number.
    * **Prose.** Every tracked `.md` is linted by `Raxol.Docs.ProseLint`:
      unicode punctuation, ` -- ` as an em-dash substitute, broken relative
      links and anchors. Title Case headings are opt-in via `--headings`.

  ## Usage

      mix raxol.check_docs                    # everything, all tracked Markdown
      mix raxol.check_docs --only prose       # skip the catalog counts
      mix raxol.check_docs --only counts      # skip the prose lint
      mix raxol.check_docs --files a.md b.md  # lint just these
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

  defp lint([], opts), do: lint(tracked_docs(), opts)

  # Selection and filtering live in `ProseLint` so this task and
  # `scripts/prose_lint.exs` (which the pre-commit hook runs without Mix) cannot
  # disagree about which files are in scope.
  defp lint(files, opts),
    do:
      ProseLint.lint_files(files, headings: Keyword.get(opts, :headings, false))

  # Prose-count scanning is Markdown-only: it reads sentences that quote a
  # catalog number, which doc strings do not.
  defp tracked_markdown do
    case System.cmd("git", ["ls-files", "*.md"], stderr_to_stdout: true) do
      {out, 0} ->
        String.split(out, "\n", trim: true)

      _ ->
        Path.wildcard("{docs,packages,examples,web,test}/**/*.md") ++
          Path.wildcard("*.md")
    end
  end

  # Markdown AND Elixir sources: a relative link in a `@moduledoc` is
  # documentation a reader follows on hexdocs, and it went unchecked until a
  # package moduledoc shipped one that pointed outside the repo root.
  defp tracked_docs do
    case System.cmd("git", ["ls-files", "*.md", "*.ex", "*.exs"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        String.split(out, "\n", trim: true)

      _ ->
        Path.wildcard("{docs,packages,examples,web,test}/**/*.md") ++
          Path.wildcard("*.md") ++
          Path.wildcard("{lib,packages,web}/**/*.{ex,exs}")
    end
  end

  defp report([], _label), do: :ok

  defp report(findings, label) do
    Mix.shell().error("\n#{length(findings)} #{label}(s):")

    Enum.each(ProseLint.format_findings(findings), fn line ->
      Mix.shell().error(line)
    end)
  end

  defp summary(only, files, warnings) do
    scope =
      if files == [],
        do: "all tracked Markdown and doc strings",
        else: "#{length(files)} file(s)"

    warn =
      if warnings == [],
        do: "",
        else: " (#{length(warnings)} heading warning(s))"

    case only do
      "prose" -> "Docs OK: prose clean across #{scope}#{warn}"
      "counts" -> "Docs OK: catalog and registry counts match"
      _ -> "Docs OK: counts match, prose clean across #{scope}#{warn}"
    end
  end

  # --- counts -------------------------------------------------------------

  defp check_counts do
    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    demos = length(Raxol.Playground.Catalog.list_components())
    categories = length(Raxol.Playground.Catalog.list_categories())

    check_claude_md(demos, categories) ++ stale_counts(count_sources())
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

  # Every prose claim that quotes a number the code produces, paired with the
  # module that produces it. Derived rather than a hand-maintained list of
  # stale numbers, so it needs no editing when the catalog or the registry
  # changes.
  #
  # Widgets and demos are two different populations, and gating both against
  # one number would force a doc to be wrong to keep this check green:
  # `Raxol.UI.Registry` lists declaration types the layout engine dispatches
  # on, `Raxol.Playground.Catalog` lists runnable examples. Several demos
  # hand-roll their subject with the View DSL and several registered types
  # have no demo, so neither count bounds the other.
  #
  # The widget rows exist because "23 widgets" shipped in prose while the
  # registry held no such number: nothing derived the claim, so nothing could
  # contradict it.
  @doc false
  @spec count_sources() :: [
          {Regex.t(), non_neg_integer(), String.t(), String.t()}
        ]
  def count_sources do
    demos = length(Raxol.Playground.Catalog.list_components())
    categories = length(Raxol.Playground.Catalog.list_categories())
    widgets = length(Raxol.UI.Registry.list())
    tool_providers = length(Raxol.UI.Registry.mcp_types())

    [
      {~r/\b(\d+) (?:interactive |live |widget )?demos\b/i, demos, "demos",
       "Raxol.Playground.Catalog"},
      {~r/\b(\d+) categories\b/i, categories, "categories",
       "Raxol.Playground.Catalog"},
      {~r/\b(\d+) (?:first-class |core |registered )?widgets\b/i, widgets,
       "widgets", "Raxol.UI.Registry"},
      {~r/\b(\d+) (?:first-class |core |registered )?widget types\b/i, widgets,
       "widget types", "Raxol.UI.Registry"},
      {~r/\b(\d+) [Cc]omponent modules implement\b/, tool_providers,
       "ToolProvider implementations", "Raxol.UI.Registry.mcp_types/0"}
    ]
  end

  defp stale_counts(patterns) do
    tracked_markdown()
    |> Enum.reject(&skipped_for_counts?/1)
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> [{path, content}]
        {:error, _} -> []
      end
    end)
    |> scan_counts(patterns)
  end

  defp skipped_for_counts?(path) do
    # CHANGELOGs quote the count that was true for that release.
    String.contains?(path, "node_modules/") or
      String.ends_with?(path, "CHANGELOG.md")
  end

  @doc false
  @spec scan_counts(
          [{String.t(), String.t()}],
          [{Regex.t(), non_neg_integer(), String.t(), String.t()}]
        ) :: [String.t()]
  def scan_counts(files, patterns) do
    for {path, content} <- files,
        {line, num} <- Enum.with_index(String.split(content, "\n"), 1),
        {regex, expected, label, source} <- patterns,
        [_, found] <- [Regex.run(regex, line)],
        String.to_integer(found) != expected do
      "#{path}:#{num}: says #{found} #{label}, #{source} has #{expected}: #{String.trim(line)}"
    end
  end
end
