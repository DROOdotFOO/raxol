defmodule Raxol.Agent.Code.ProjectContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ProjectContext

  # A workspace rooted at a `.git` marker, so the upward walk has a stop.
  defp workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-projctx-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".git"), "gitdir: elsewhere\n")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  # The global file lives under a real home directory; tests point at their
  # own so a developer's `~/.raxol/AGENTS.md` cannot change the result.
  defp load(dir, opts \\ []) do
    ProjectContext.load(dir, Keyword.put_new(opts, :global, false))
  end

  describe "discovery" do
    test "reads AGENTS.md from the working directory" do
      dir = workspace()
      path = write(dir, "AGENTS.md", "use tabs")

      assert %{files: [%{path: ^path, content: "use tabs", truncated?: false}]} = load(dir)
    end

    test "reads AGENTS.md and CLAUDE.md, AGENTS.md first" do
      dir = workspace()
      write(dir, "CLAUDE.md", "claude rules")
      write(dir, "AGENTS.md", "agents rules")

      assert %{files: [first, second]} = load(dir)
      assert Path.basename(first.path) == "AGENTS.md"
      assert Path.basename(second.path) == "CLAUDE.md"
    end

    test "no instruction files is an empty result" do
      assert load(workspace()) == %{files: [], bytes: 0}
    end

    test "walks up to the repository root, outermost file first" do
      root = workspace()
      nested = Path.join(root, "packages/thing")
      File.mkdir_p!(nested)

      write(root, "AGENTS.md", "root rules")
      write(nested, "AGENTS.md", "nested rules")

      assert %{files: [outer, inner]} = load(nested)
      assert outer.content == "root rules"
      assert inner.content == "nested rules"
    end

    test "stops at the repository root and does not read above it" do
      root = workspace()
      inner = Path.join(root, "sub")
      File.mkdir_p!(inner)
      write(inner, "AGENTS.md", "inner")

      # A file in the parent of the repository root must not be picked up.
      above = Path.dirname(root)
      stray = Path.join(above, "AGENTS.md")
      refute File.exists?(stray), "test fixture would clobber a real file"

      assert %{files: [only]} = load(inner)
      assert only.content == "inner"
    end

    test "a directory outside any repository contributes only itself" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol-projctx-bare-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      write(dir, "AGENTS.md", "bare")

      assert %{files: [%{content: "bare"}]} = load(dir)
    end

    test ":root bounds the walk below the repository root" do
      root = workspace()
      jail = Path.join(root, "tenant/work")
      File.mkdir_p!(jail)

      write(root, "AGENTS.md", "host rules")
      write(jail, "AGENTS.md", "tenant rules")

      assert %{files: [only]} = load(jail, root: jail)
      assert only.content == "tenant rules"
    end
  end

  describe "the user-global file" do
    test "is read ahead of the workspace files" do
      dir = workspace()
      global = workspace()
      write(global, "AGENTS.md", "global rules")
      write(dir, "AGENTS.md", "repo rules")

      assert %{files: [first, second]} =
               ProjectContext.load(dir, global: true, global_dir: global)

      assert first.content == "global rules"
      assert second.content == "repo rules"
    end

    test "is skipped when disabled" do
      dir = workspace()
      global = workspace()
      write(global, "AGENTS.md", "global rules")

      assert %{files: []} = ProjectContext.load(dir, global: false, global_dir: global)
    end
  end

  describe "limits" do
    test "truncates a file past the per-file cap and marks it" do
      dir = workspace()
      write(dir, "AGENTS.md", String.duplicate("x", 100))

      assert %{files: [file]} = load(dir, max_file_bytes: 10)
      assert file.content == String.duplicate("x", 10)
      assert file.truncated?
    end

    test "stops once the total cap is exhausted" do
      root = workspace()
      nested = Path.join(root, "sub")
      File.mkdir_p!(nested)
      write(root, "AGENTS.md", String.duplicate("a", 30))
      write(nested, "AGENTS.md", String.duplicate("b", 30))

      assert %{files: [only], bytes: 20} = load(nested, max_total_bytes: 20)
      assert only.content == String.duplicate("a", 20)
    end

    test "truncation lands on a codepoint boundary" do
      dir = workspace()
      # Three-byte codepoints, so a 4-byte cap splits the second one.
      write(dir, "AGENTS.md", String.duplicate("★", 4))

      assert %{files: [file]} = load(dir, max_file_bytes: 4)
      assert file.content == "★"
      assert String.valid?(file.content)
    end

    test "skips a file that is not valid UTF-8" do
      dir = workspace()
      File.write!(Path.join(dir, "AGENTS.md"), <<0xFF, 0xFE, 0xFD, 0xFC>>)

      assert %{files: []} = load(dir)
    end

    test "skips an empty or whitespace-only file" do
      dir = workspace()
      write(dir, "AGENTS.md", "   \n\n  ")

      assert %{files: []} = load(dir)
    end

    test "skips a directory named like an instruction file" do
      dir = workspace()
      File.mkdir_p!(Path.join(dir, "AGENTS.md"))

      assert %{files: []} = load(dir)
    end
  end

  describe "render/1" do
    test "returns nil when nothing was discovered" do
      assert ProjectContext.render(%{files: [], bytes: 0}) == nil
    end

    test "fences each file under its own path" do
      dir = workspace()
      path = write(dir, "AGENTS.md", "use tabs")

      text = dir |> load() |> ProjectContext.render()

      assert text =~ "## Workspace instructions"
      assert text =~ "### #{path}"
      assert text =~ "use tabs"
      refute text =~ "truncated"
    end

    test "says so when a file was truncated" do
      dir = workspace()
      write(dir, "AGENTS.md", String.duplicate("x", 100))

      text = dir |> load(max_file_bytes: 10) |> ProjectContext.render()

      assert text =~ "[truncated: file exceeds the size cap]"
    end
  end

  # Hooks and MCP servers are refused in a jail because the workspace is
  # TENANT-written. These files are read rather than executed so they are kept,
  # but the same fact applies: telling the model to follow tenant-written text
  # "as operator instructions" hands whoever can write the workspace the most
  # privileged position in the conversation.
  describe "trust framing" do
    test "an untrusted render does not claim operator authority" do
      dir = workspace()
      write(dir, "AGENTS.md", "use tabs")

      text = dir |> load() |> ProjectContext.render(trusted: false)

      # The content still reaches the model.
      assert text =~ "use tabs"

      refute text =~ "operator instructions"
      assert text =~ "untrusted"
      assert text =~ "tools, permissions, or the"
    end

    test "a trusted render is unchanged" do
      dir = workspace()
      write(dir, "AGENTS.md", "use tabs")

      text = dir |> load() |> ProjectContext.render(trusted: true)

      assert text =~ "Follow them as operator instructions"
      refute text =~ "untrusted"
    end

    test "trusted is the default, so a normal session is unaffected" do
      dir = workspace()
      write(dir, "AGENTS.md", "use tabs")

      assert dir |> load() |> ProjectContext.render() ==
               dir |> load() |> ProjectContext.render(trusted: true)
    end

    test "augment/3 carries the framing through" do
      dir = workspace()
      write(dir, "AGENTS.md", "use tabs")

      jailed = ProjectContext.augment("base", dir, root: dir, global: false, trusted: false)

      assert jailed =~ "base"
      assert jailed =~ "untrusted"
      refute jailed =~ "operator instructions"
    end
  end
end
