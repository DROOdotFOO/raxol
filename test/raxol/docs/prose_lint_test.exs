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

    @tag :tmp_dir
    test "flags a target that exists but is not in the repository", %{
      tmp_dir: dir
    } do
      # The shape that made `docs/README.md` link to a gitignored `TODO.md`:
      # the file is on the author's disk, so an existence check passes locally
      # and the link is broken for everyone who clones. CI caught it only
      # because its checkout has no untracked files.
      System.cmd("git", ["init", "--quiet"], cd: dir)
      File.write!(Path.join(dir, ".gitignore"), "IGNORED.md\n")
      File.write!(Path.join(dir, "IGNORED.md"), "# Ignored\n")
      File.write!(Path.join(dir, "TRACKED.md"), "# Tracked\n")
      System.cmd("git", ["add", ".gitignore", "TRACKED.md"], cd: dir)

      content = """
      [ignored](./IGNORED.md)
      [tracked](./TRACKED.md)
      """

      findings = ProseLint.check_content("probe.md", content, root: dir)

      assert [%{rule: :broken_link, severity: :error} = finding] = findings
      assert finding.message =~ "not in the repository"
      assert finding.text =~ "IGNORED.md"

      # Same verdict through `lint_files/2`, which reads the tracked set ONCE
      # instead of asking git per link. Two code paths, one answer -- a repo-wide
      # run must not decide differently from a single-file check.
      File.write!(Path.join(dir, "probe.md"), content)

      assert [%{rule: :broken_link} = batched] =
               ProseLint.lint_files(["probe.md"], root: dir)

      assert batched.message =~ "not in the repository"
    end

    @tag :tmp_dir
    test "outside a git checkout the tracking rule stays silent", %{
      tmp_dir: dir
    } do
      # An unpacked Hex tarball or a vendored copy has no git metadata. A
      # checker that cannot tell must not invent a violation.
      File.write!(Path.join(dir, "other.md"), "# Other\n")

      assert ProseLint.check_content("probe.md", "[x](./other.md)\n", root: dir) ==
               []
    end
  end

  # A moduledoc is not rendered on a source page, so the only reader who follows
  # one of these links is on hexdocs, where ExDoc resolves it against the app's
  # :extras. Nothing checked them until a package moduledoc shipped a link four
  # levels up that lands in packages/ rather than the repo root.
  describe "doc-string links" do
    setup %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "docs/adr"))
      File.write!(Path.join(dir, "docs/adr/0014.md"), "# ADR\n")
      File.mkdir_p!(Path.join(dir, "packages/raxol_telegram/lib"))
      File.mkdir_p!(Path.join(dir, "packages/raxol_telegram/docs"))

      File.write!(
        Path.join(dir, "packages/raxol_telegram/docs/own.md"),
        "# Own\n"
      )

      :ok
    end

    defp write_source(dir, rel, doc) do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        "defmodule P do\n  @moduledoc \"\"\"\n#{doc}\n  \"\"\"\nend\n"
      )

      rel
    end

    @tag :tmp_dir
    test "flags a relative path, which no :extras entry can match", %{
      tmp_dir: dir
    } do
      rel =
        write_source(
          dir,
          "packages/raxol_telegram/lib/guardian.ex",
          "  See [adr](../../../../docs/adr/0014.md)."
        )

      assert [%{rule: :broken_link, severity: :error} = f] =
               ProseLint.lint_files([rel], root: dir)

      assert f.message =~ ":extras"
    end

    @tag :tmp_dir
    test "flags a target outside the package that owns the file", %{
      tmp_dir: dir
    } do
      # Resolves in this repo, and still cannot ship in the package's docs.
      rel =
        write_source(
          dir,
          "packages/raxol_telegram/lib/guardian.ex",
          "  See [adr](docs/adr/0014.md)."
        )

      assert [%{rule: :broken_link} = f] =
               ProseLint.lint_files([rel], root: dir)

      assert f.message =~ "outside the package"
    end

    @tag :tmp_dir
    test "accepts a target the owning package ships", %{tmp_dir: dir} do
      rel =
        write_source(
          dir,
          "packages/raxol_telegram/lib/guardian.ex",
          "  See [own](packages/raxol_telegram/docs/own.md)."
        )

      assert ProseLint.lint_files([rel], root: dir) == []
    end

    @tag :tmp_dir
    test "accepts a root-app extras path", %{tmp_dir: dir} do
      # How `Raxol.UI` links the Quickstart: exactly the extras source path.
      rel =
        write_source(dir, "lib/raxol/ui.ex", "  See [adr](docs/adr/0014.md).")

      assert ProseLint.lint_files([rel], root: dir) == []
    end

    @tag :tmp_dir
    test "ignores bracket-and-paren text that is not a path", %{tmp_dir: dir} do
      # Doc strings are full of this. Flagging it would make the rule noise.
      rel =
        write_source(
          dir,
          "lib/raxol/ui.ex",
          ~S"""
            CSS pseudo-elements [x](:after) and [y](:before), a regex [r](\d+),
            and a character class [c]([^x]+).
          """
        )

      assert ProseLint.lint_files([rel], root: dir) == []
    end

    @tag :tmp_dir
    test "leaves code outside doc strings alone", %{tmp_dir: dir} do
      path = Path.join(dir, "lib/raxol/ui.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~S|defmodule P do
  # a comment with [a](../../nope.md)
  def f, do: "[b](../../also_nope.md)"
end
|)

      assert ProseLint.lint_files(["lib/raxol/ui.ex"], root: dir) == []
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

  # `check_file/2` joined every path onto `:root`, and `Path.join(".", "/tmp/x")`
  # is `"./tmp/x"` -- so an absolute path read as MISSING and lint as clean.
  # `scripts/prose_lint.exs` made that reachable in the worst way: its
  # "named files must exist" guard resolved the real path while the lint
  # resolved the joined one, so an absolute argument passed the guard and then
  # silently found nothing.
  describe "check_file/2 with an absolute path" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "prose_lint_abs_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reads the file rather than joining it onto the root", %{dir: dir} do
      path = Path.join(dir, "abs.md")
      File.write!(path, "An em-dash \u2014 here.")

      assert [%{rule: :unicode_punctuation}] = ProseLint.check_file(path)
    end

    test "lint_files/2 finds it too, which is the path the hook script takes",
         %{dir: dir} do
      path = Path.join(dir, "abs.md")
      File.write!(path, "An em-dash \u2014 here.")

      assert [%{rule: :unicode_punctuation}] = ProseLint.lint_files([path])
    end

    test "a missing absolute path is still clean, not a crash", %{dir: dir} do
      assert ProseLint.check_file(Path.join(dir, "nope.md")) == []
    end
  end
end
