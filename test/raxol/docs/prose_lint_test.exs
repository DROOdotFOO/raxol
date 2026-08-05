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
      assert ProseLint.check_content(allowed, "the strip renders `—` here —") == []
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
      [finding] = ProseLint.check_content("probe.md", "## Next Steps", headings: true)
      assert finding.severity == :warning
    end

    test "leaves a sentence-case heading alone" do
      assert rules("## Quick start", headings: true) == []
    end

    test "does not fire past a colon or a dash separator" do
      assert rules("### Stage 3: Output generation", headings: true) == []
      assert rules("### Sprint 5 - Critical Architectural Fixes", headings: true) == []
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
end
