defmodule Raxol.Docs.ProseLintTest do
  use ExUnit.Case, async: true

  alias Raxol.Docs.ProseLint

  defp rules(content, opts \\ []) do
    "probe.md"
    |> ProseLint.check_content(content, opts)
    |> Enum.map(& &1.rule)
  end

  describe "unicode punctuation" do
    test "flags em-dash, en-dash, and curly quotes" do
      assert :unicode_punctuation in rules("A sentence — with a dash.")
      assert :unicode_punctuation in rules("Range I1–I10 here.")
      assert :unicode_punctuation in rules(~s(He said “hello” loudly.))
    end

    test "passes ASCII punctuation" do
      assert rules("A sentence, with a comma. And a colon: like this.") == []
    end

    test "skips files where the character is the subject" do
      allowed = "test/fixtures/harness/sessions/adversarial.notes.md"

      assert ProseLint.check_content(allowed, "the strip renders `—` here —") ==
               []
    end
  end

  describe "prose dash" do
    test "flags ` -- ` used as an em-dash substitute" do
      assert :prose_dash in rules("A label -- and its elaboration.")
    end

    test "ignores a CLI flag separator inside a code span" do
      assert rules("Run `mix bench -- --quick` to skip the slow suites.") == []
    end

    test "ignores a fenced block, including Lua comments" do
      content = """
      Prose above.

      ```lua
      local x = 1 -- a lua comment
      ```
      """

      assert rules(content) == []
    end

    test "ignores all-dash table cells" do
      content = """
      | tool | module | note |
      |------|--------|------|
      | text | --     | none |
      """

      assert rules(content) == []
    end

    test "still flags a real dash inside a table cell" do
      assert :prose_dash in rules("| text | a label -- an elaboration | yes |")
    end
  end

  describe "links" do
    @tag :tmp_dir
    test "flags a missing target and a missing anchor", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "other.md"), "# Other\n\n## Real heading\n")

      content = """
      [gone](./missing.md)
      [bad anchor](./other.md#no-such-heading)
      [fine](./other.md#real-heading)
      """

      findings = ProseLint.check_content("probe.md", content, root: dir)
      assert Enum.map(findings, & &1.rule) == [:broken_link, :broken_link]
      assert Enum.all?(findings, &(&1.severity == :error))
    end

    @tag :tmp_dir
    test "resolves an anchor within the same file", %{tmp_dir: dir} do
      content = "## Quick start\n\nSee [above](#quick-start).\n"
      assert ProseLint.check_content("probe.md", content, root: dir) == []
    end
  end

  describe "heading case" do
    test "is off unless requested" do
      assert rules("## Quick Start") == []
    end

    test "flags a fully Title Case heading when enabled" do
      assert rules("## Quick Start", headings: true) == [:heading_case]
    end

    test "reports a warning, never an error" do
      [finding] =
        ProseLint.check_content("probe.md", "## Next Steps", headings: true)

      assert finding.severity == :warning
    end

    test "leaves a sentence-case heading alone" do
      assert rules("## Quick start", headings: true) == []
    end

    test "does not fire past a colon or a dash separator" do
      assert rules("### Stage 3: Output generation", headings: true) == []

      assert rules("### Sprint 5 - Critical Architectural Fixes",
               headings: true
             ) == []
    end

    test "does not fire on a known proper phrase or a quoted external name" do
      assert rules("## The Elm Architecture (TEA)", headings: true) == []
      assert rules("### (CSS Text Module Level 3)", headings: true) == []
    end

    test "ignores H1, which names an entity" do
      assert rules("# Component Gallery", headings: true) == []
    end
  end

  describe "vendored regions" do
    test "skips content between usage_rules sync markers" do
      content = """
      Our prose is clean.

      <!-- usage_rules:elixir-start -->
      ## Error Handling

      Injected text with an em-dash — that we do not own.
      <!-- usage_rules:elixir-end -->

      Ours again.
      """

      assert rules(content, headings: true) == []
    end
  end

  # `lint_files/2` and `format_findings/1` are the contract the pre-commit hook
  # runs through `scripts/prose_lint.exs`, without Mix. They used to live in the
  # Mix task, where the hook could not reach them; a disagreement about scope
  # between the hook and CI is exactly what these pin.
  describe "lint_files/2" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "prose_lint_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    # Paths are relative to `:root`, the way the hook passes git's own
    # repo-relative output.
    defp write(dir, rel, content) do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      rel
    end

    test "skips paths that are not Markdown", %{dir: dir} do
      rel = write(dir, "notes.txt", "An em-dash — in a text file.")
      assert ProseLint.lint_files([rel], root: dir) == []
    end

    test "skips node_modules", %{dir: dir} do
      rel = write(dir, "node_modules/pkg/README.md", "An em-dash — here.")
      assert ProseLint.lint_files([rel], root: dir) == []
    end

    test "skips the vendored termbox2 readme", %{dir: dir} do
      rel = write(dir, "termbox2/README.md", "An em-dash — here.")
      assert ProseLint.lint_files([rel], root: dir) == []
    end

    test "lints Markdown it does own", %{dir: dir} do
      rel = write(dir, "own.md", "An em-dash — here.")

      assert [%{rule: :unicode_punctuation}] =
               ProseLint.lint_files([rel], root: dir)
    end

    test "resolves against :root rather than the cwd", %{dir: dir} do
      rel = write(dir, "own.md", "An em-dash — here.")

      # The regression this pins: dropping `:root` made every path resolve
      # against "." and the unreadable result lint as clean.
      assert ProseLint.lint_files([rel], root: dir) != []
      assert ProseLint.lint_files([rel]) == []
    end

    test "sorts by path then line regardless of input order", %{dir: dir} do
      b = write(dir, "b.md", "An em-dash — here.")
      a = write(dir, "a.md", "Line one is fine.\nAn em-dash — here.\n")

      assert [first, second] = ProseLint.lint_files([b, a], root: dir)
      assert first.path == a and first.line == 2
      assert second.path == b
    end
  end

  describe "format_findings/1" do
    test "renders two lines per finding" do
      findings = ProseLint.check_content("probe.md", "An em-dash — here.")

      assert [location, text] = ProseLint.format_findings(findings)
      assert location =~ "probe.md:1"
      assert location =~ "[unicode_punctuation]"
      assert text =~ "An em-dash"
    end

    test "truncates a long source line" do
      long = String.duplicate("x", 200)
      findings = ProseLint.check_content("probe.md", "#{long} — tail")

      assert [_location, text] = ProseLint.format_findings(findings)
      assert String.ends_with?(text, "...")
      assert String.length(text) < 130
    end

    test "renders nothing for no findings" do
      assert ProseLint.format_findings([]) == []
    end
  end
end
