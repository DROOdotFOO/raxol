defmodule Raxol.Docs.ProseLint do
  @moduledoc """
  House prose rules for Markdown, as pure functions over file contents.

  The rules encode style decisions that were previously enforced by hand and
  kept regressing: three separate sweeps removed em-dashes from `docs/` and each
  time they came back, and the sweep that cleaned `docs/` never covered
  `packages/` at all. A rule that lives in a checker cannot have that scope gap.

  Three rules run by default, all errors:

    * `:unicode_punctuation` - em-dash, en-dash, and curly quotes. House style
      is ASCII (see the repo `CLAUDE.md`).
    * `:prose_dash` - ` -- ` used as an em-dash substitute. Fenced code, inline
      code spans, and all-dash table cells are exempt, so CLI flags
      (`mix ... -- --quick`), Lua comments, and `| -- |` placeholders pass.
    * `:broken_link` - a relative Markdown link whose target file or `#anchor`
      does not resolve.

  A fourth rule, `:heading_case`, is opt-in via `headings: true` and reports
  warnings. It cannot be a default: distinguishing a Title Case heading from a
  proper noun needs a dictionary, and on this repo the naive form flagged
  `## The Elm Architecture (TEA)` and `### Stage 3: Output generation`. It fires
  only when every alphabetic word in the heading is capitalized *and* one of them
  is in `@title_case_words`, which keeps it useful for a sweep without making the
  default run noisy enough to ignore.

  `check_file/2` returns findings; the caller decides what is fatal.
  """

  @type finding :: %{
          path: String.t(),
          line: pos_integer(),
          rule: atom(),
          severity: :error | :warning,
          message: String.t(),
          text: String.t()
        }

  # Files where the character under test is the subject, not the punctuation.
  @allowlist [
    "docs/proposals/in-flight/agent-lane-response-to-ui-intersection.md",
    "test/fixtures/harness/sessions/adversarial.notes.md",
    "test/fixtures/harness/sessions/projection-panels.notes.md"
  ]

  @unicode_punctuation %{
    "—" => "em-dash",
    "–" => "en-dash",
    "“" => "curly double quote",
    "”" => "curly double quote",
    "‘" => "curly single quote",
    "’" => "curly single quote"
  }

  # Title Case that is a name, not a style choice.
  @proper_phrases ["The Elm Architecture"]

  # Common words that should be lowercase in a sentence-case heading. Kept
  # deliberately short: every entry is a word with no plausible reading as a
  # proper noun or module name in this repo. Extend it when a real Title Case
  # heading slips through, never with a word that could name a thing.
  @title_case_words ~w(
    Actions Analysis Architecture Avoid Backend Backends Best Boundaries
    Caching Categories Changes Checklist Comparison Configuration Contract
    Conventions Coverage Design Details Dispatch Environment Example Examples
    Extension Filtering Fixes Flow Guide Handling Helpers Hints Impact Input
    Isolation Issues Level Levels Lifecycle Limits Management Manifest Model
    Modules Monitoring Notes Notifications Order Output Overrides Overview
    Palettes Patterns Payloads Pitfalls Points Policies Practices Priority
    Problem Recipes Reference Registration Rendering Results Rule Rules Schema
    Scrolling Selection Setup Shape Space Stack Start Status Steps Strategies
    Structure Support Synchronization System Table Tags Targets Teams Testing
    Tests Theming Tips Types Usage Validation Values Variables Watcher Work
  )

  @doc """
  Lint one Markdown file.

  Options: `:root` (repository root the path is relative to, default `"."`) and
  `:headings` (run the opt-in heading-case rule, default `false`).
  """
  @spec check_file(String.t(), keyword()) :: [finding()]
  def check_file(path, opts \\ []) do
    root = Keyword.get(opts, :root, ".")

    case File.read(Path.join(root, path)) do
      {:ok, content} -> check_content(path, content, opts)
      {:error, _} -> []
    end
  end

  @doc "Lint already-read content. Split out so tests do not touch disk."
  @spec check_content(String.t(), String.t(), keyword()) :: [finding()]
  def check_content(path, content, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    masked = content |> String.split("\n") |> mask_code()

    headings =
      if Keyword.get(opts, :headings, false),
        do: heading_findings(path, masked),
        else: []

    punctuation_findings(path, masked) ++
      dash_findings(path, masked) ++
      headings ++
      link_findings(path, content, root)
  end

  @doc """
  Lint a list of candidate paths, keeping only the Markdown this repo owns.

  Drops non-`.md` paths, `node_modules/`, and vendored copies, then sorts by
  `{path, line}` so output is stable regardless of the order paths arrive in.

  Lives here rather than in the Mix task because two entry points need it: the
  task, and `scripts/prose_lint.exs`, which the pre-commit hook runs WITHOUT
  Mix. Keeping selection next to the rules means the hook and CI cannot come to
  different conclusions about which files are in scope.
  """
  @spec lint_files([String.t()], keyword()) :: [finding()]
  def lint_files(paths, opts \\ []) do
    # `:root` is forwarded, not just `:headings`. `check_file/2` joins the path
    # onto the root, so dropping it made every path resolve against `"."` and an
    # unreadable file lints as clean -- a linter silently passing is worse than
    # one that errors.
    lint_opts = [
      headings: Keyword.get(opts, :headings, false),
      root: Keyword.get(opts, :root, ".")
    ]

    paths
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reject(&(String.contains?(&1, "node_modules/") or vendored?(&1)))
    |> Enum.flat_map(&check_file(&1, lint_opts))
    |> Enum.sort_by(&{&1.path, &1.line})
  end

  # Upstream sources we re-publish unmodified. Rewriting their prose would make
  # the vendored copy diverge from the thing it is a copy of.
  defp vendored?(path), do: String.contains?(path, "termbox2/README.md")

  @doc """
  Render findings as display lines, two per finding (location, then the text).

  Returns lines rather than printing them so the Mix task can route them
  through `Mix.shell/0` and the hook script can put them on stderr.
  """
  @spec format_findings([finding()]) :: [String.t()]
  def format_findings(findings) do
    Enum.flat_map(findings, fn f ->
      [
        "  #{f.path}:#{f.line}  [#{f.rule}] #{f.message}",
        "      #{truncate(f.text)}"
      ]
    end)
  end

  defp truncate(text) when byte_size(text) > 120,
    do: binary_part(text, 0, 117) <> "..."

  defp truncate(text), do: text

  # --- code masking -------------------------------------------------------

  # Replace fenced blocks and inline code spans with same-length filler so
  # offsets and line numbers survive, then prose rules cannot see code.
  defp mask_code(lines) do
    {masked, _} =
      Enum.map_reduce(lines, {false, false}, fn line, {in_fence?, in_vendor?} ->
        trimmed = String.trim_leading(line)

        cond do
          vendor_start?(trimmed) -> {"", {in_fence?, true}}
          vendor_end?(trimmed) -> {"", {in_fence?, false}}
          in_vendor? -> {"", {in_fence?, true}}
          String.starts_with?(trimmed, "```") -> {"", {!in_fence?, in_vendor?}}
          in_fence? -> {"", {true, in_vendor?}}
          true -> {mask_inline_code(line), {false, in_vendor?}}
        end
      end)

    Enum.with_index(masked, 1)
  end

  # Content injected by another tool (`mix usage_rules.sync` writes these
  # markers). Linting it is pointless: the next sync overwrites any fix.
  defp vendor_start?(line),
    do: Regex.match?(~r/<!--\s*usage_rules.*-start\s*-->/, line)

  defp vendor_end?(line),
    do: Regex.match?(~r/<!--\s*usage_rules.*-end\s*-->/, line)

  defp mask_inline_code(line) do
    Regex.replace(~r/`[^`]*`/, line, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end

  # --- rules --------------------------------------------------------------

  defp punctuation_findings(path, _masked) when path in @allowlist, do: []

  defp punctuation_findings(path, masked) do
    for {line, num} <- masked,
        {char, name} <- @unicode_punctuation,
        String.contains?(line, char) do
      finding(
        path,
        num,
        :unicode_punctuation,
        :error,
        "#{name} in prose, use ASCII",
        line
      )
    end
  end

  defp dash_findings(path, masked) do
    for {line, num} <- masked,
        String.contains?(line, " -- "),
        not placeholder_row?(line) do
      finding(
        path,
        num,
        :prose_dash,
        :error,
        "` -- ` as em-dash substitute",
        line
      )
    end
  end

  # A table row whose only ` -- ` occurrences sit in cells that are pure dashes:
  # separator rows (`|---|`) and "not applicable" cells (`| -- |`).
  defp placeholder_row?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "|") and
      trimmed
      |> String.split("|", trim: true)
      |> Enum.filter(&String.contains?(&1, " -- "))
      |> Enum.all?(&Regex.match?(~r/^\s*-+\s*$/, &1))
  end

  defp heading_findings(path, masked) do
    for {line, num} <- masked,
        [_, hashes, title] <- [Regex.run(~r/^(\#{2,6})\s+(.*)$/, line)],
        offender = title_case_offender(title),
        offender != nil do
      finding(
        path,
        num,
        :heading_case,
        :warning,
        "Title Case heading (`#{offender}`), house style is sentence case",
        String.trim("#{hashes} #{title}")
      )
    end
  end

  # Fires only on a heading whose every alphabetic word is capitalized, which is
  # what actual Title Case looks like. A single lowercase word ("Stage 3: Output
  # generation", "1. Actions as callable functions") means the author was
  # already writing sentence case and the capital is a proper noun or follows a
  # colon, so there is nothing to report.
  defp title_case_offender(title) do
    # Only the segment before a colon or a dash separator is under the rule: the
    # word after either is meant to be capitalized ("Stage 3: Output generation",
    # "Sprint 5 - Critical Fixes").
    head = title |> String.split(~r/:| - /, parts: 2) |> hd() |> String.trim()

    words =
      head
      |> String.split(~r/[\s\/]+/, trim: true)
      |> Enum.filter(&Regex.match?(~r/^[A-Za-z]/, &1))

    cond do
      Enum.any?(@proper_phrases, &String.starts_with?(head, &1)) -> nil
      # A parenthesized heading is quoting an external name, not writing prose.
      String.starts_with?(head, "(") -> nil
      words == [] -> nil
      not Enum.all?(words, &Regex.match?(~r/^[A-Z]/, &1)) -> nil
      true -> words |> Enum.drop(1) |> Enum.find(&(&1 in @title_case_words))
    end
  end

  # Links are checked against the raw content: a link inside a fenced block is
  # still a link a reader will follow from a rendered page.
  defp link_findings(path, content, root) do
    dir = Path.dirname(path)

    ~r/\[[^\]]*\]\((?!https?:|mailto:|#\/)([^)#\s]*)(#[^)\s]*)?\)/
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(&resolve_link(&1, path, content, dir, root))
  end

  defp resolve_link([{start, len}, target_idx | rest], path, content, dir, root) do
    whole = binary_part(content, start, len)
    target = slice(content, target_idx)
    fragment = rest |> List.first() |> then(&slice(content, &1))
    line = line_number(content, start)

    # A same-file anchor resolves against the content already in hand. Re-reading
    # `path` from disk would be wrong for `check_content/3` on unsaved text, and
    # pointless otherwise.
    if target == "" do
      if fragment != "" and fragment_of(fragment) not in anchors(content) do
        [
          finding(
            path,
            line,
            :broken_link,
            :error,
            "anchor does not exist",
            whole
          )
        ]
      else
        []
      end
    else
      resolve_external(whole, target, fragment, line, path, dir, root)
    end
  end

  defp resolve_external(whole, target, fragment, line, path, dir, root) do
    absolute = dir |> Path.join(target) |> Path.expand(root)

    cond do
      not File.exists?(absolute) ->
        [
          finding(
            path,
            line,
            :broken_link,
            :error,
            "link target does not exist",
            whole
          )
        ]

      fragment != "" and String.ends_with?(absolute, ".md") and
          not anchor_exists?(absolute, fragment) ->
        [
          finding(
            path,
            line,
            :broken_link,
            :error,
            "anchor does not exist",
            whole
          )
        ]

      true ->
        []
    end
  end

  defp fragment_of("#" <> rest), do: rest
  defp fragment_of(other), do: other

  defp slice(_content, nil), do: ""
  defp slice(_content, {_, 0}), do: ""
  defp slice(content, {start, len}), do: binary_part(content, start, len)

  defp anchor_exists?(file, "#" <> fragment), do: anchor_exists?(file, fragment)

  defp anchor_exists?(file, fragment) do
    case File.read(file) do
      {:ok, content} -> fragment in anchors(content)
      {:error, _} -> false
    end
  end

  # GitHub anchor derivation: lowercase, drop everything that is not word,
  # space, or hyphen, then spaces to hyphens.
  defp anchors(content) do
    content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\#{1,6}\s+(.*)$/, line) do
        [_, title] ->
          [
            title
            |> String.downcase()
            |> String.replace(~r/[^\w\s-]/u, "")
            |> String.trim()
            |> String.replace(~r/\s+/, "-")
          ]

        _ ->
          []
      end
    end)
  end

  defp line_number(content, offset) do
    content |> binary_part(0, offset) |> String.split("\n") |> length()
  end

  defp finding(path, line, rule, severity, message, text) do
    %{
      path: path,
      line: line,
      rule: rule,
      severity: severity,
      message: message,
      text: String.trim(text)
    }
  end
end
