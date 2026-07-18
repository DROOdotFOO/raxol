defmodule Raxol.Agent.Actions.WorkspaceTest do
  @moduledoc "Unit spec for the mutating + search workspace Actions."

  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Workspace
  alias Raxol.Agent.Actions.Workspace.{EditFile, Glob, Grep, WriteFile}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "raxol-ws-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", tmp)

    on_exit(fn ->
      if prev,
        do: System.put_env("RAXOL_CLI_CWD", prev),
        else: System.delete_env("RAXOL_CLI_CWD")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "write_file" do
    test "creates a file and returns a diff receipt (old empty, new content)",
         %{tmp: tmp} do
      assert {:ok, res} = WriteFile.call(%{path: "new.ex", content: "x = 1\n"})
      assert res.created == true
      assert res.old == ""
      assert res.new == "x = 1\n"
      assert res.language == "elixir"
      assert File.read!(Path.join(tmp, "new.ex")) == "x = 1\n"
    end

    test "overwrite carries the previous content as old", %{tmp: tmp} do
      File.write!(Path.join(tmp, "a.txt"), "before\n")
      assert {:ok, res} = WriteFile.call(%{path: "a.txt", content: "after\n"})
      assert res.created == false
      assert res.old == "before\n"
      assert res.new == "after\n"
    end

    test "rejects a path outside cwd" do
      assert {:error, :outside_cwd} =
               WriteFile.call(%{path: "../escape.txt", content: "no"})
    end
  end

  describe "edit_file" do
    test "replaces a unique substring and returns old/new full images", %{
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "c.ex"), "a\nTARGET\nb\n")

      assert {:ok, res} =
               EditFile.call(%{
                 path: "c.ex",
                 old_string: "TARGET",
                 new_string: "DONE"
               })

      assert res.old == "a\nTARGET\nb\n"
      assert res.new == "a\nDONE\nb\n"
      assert File.read!(Path.join(tmp, "c.ex")) == "a\nDONE\nb\n"
    end

    test "refuses a non-unique target rather than corrupting", %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "dup\ndup\n")

      assert {:error, :edit_target_not_unique} =
               EditFile.call(%{
                 path: "c.ex",
                 old_string: "dup",
                 new_string: "x"
               })
    end

    test "refuses a target that is not present", %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "nothing here\n")

      assert {:error, :edit_target_not_found} =
               EditFile.call(%{
                 path: "c.ex",
                 old_string: "absent",
                 new_string: "x"
               })
    end
  end

  # The approval PREVIEW must always be renderable (so the operator sees a
  # diff, never raw truncated args), while EXECUTION stays strict (an edit
  # only applies against an exact-unique target). These two guarantees are
  # tested as a pair: the preview may degrade; do_edit may not.
  describe "preview_edit (renderable preview / strict execution)" do
    test "exact-unique match returns the full-file diff with a real base_hash",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "a\nTARGET\nb\n")

      assert {:ok, diff} = Workspace.preview_edit("c.ex", "TARGET", "DONE")

      assert diff.match == :exact
      assert diff.path == "c.ex"
      assert diff.old == "a\nTARGET\nb\n"
      assert diff.new == "a\nDONE\nb\n"
      assert diff.language == "elixir"
      assert is_binary(diff.base_hash)
      assert diff.base_hash == Workspace.content_hash("a\nTARGET\nb\n")

      # Previewing must NOT write.
      assert File.read!(Path.join(tmp, "c.ex")) == "a\nTARGET\nb\n"
    end

    test "a NON-MATCHING old_string returns a best-effort not_found hunk, not :error",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "nothing here\n")

      assert {:ok, diff} = Workspace.preview_edit("c.ex", "absent", "replacement")

      assert diff.match == :not_found
      assert diff.path == "c.ex"
      # The proposed hunk stands in for the un-locatable full-file image.
      assert diff.old == "absent"
      assert diff.new == "replacement"
      # A best-effort preview carries NO staleness anchor (deliberately).
      refute Map.has_key?(diff, :base_hash)
    end

    test "a NON-UNIQUE old_string returns a best-effort ambiguous hunk", %{
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "c.ex"), "dup\ndup\n")

      assert {:ok, diff} = Workspace.preview_edit("c.ex", "dup", "x")

      assert diff.match == :ambiguous
      assert diff.old == "dup"
      assert diff.new == "x"
      refute Map.has_key?(diff, :base_hash)
    end

    test "a missing file still previews the proposed hunk, marked not_found" do
      assert {:ok, diff} =
               Workspace.preview_edit("does_not_exist.ex", "foo", "bar")

      assert diff.match == :not_found
      assert diff.old == "foo"
      assert diff.new == "bar"
      refute Map.has_key?(diff, :base_hash)
    end

    test "the preview degrades but do_edit stays STRICT: a non-matching edit errors and writes nothing",
         %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "nothing here\n")

      # The preview is best-effort (renderable)...
      assert {:ok, %{match: :not_found}} =
               Workspace.preview_edit("c.ex", "absent", "x")

      # ...but EXECUTION refuses the same edit and leaves the file untouched.
      assert {:error, :edit_target_not_found} =
               Workspace.do_edit("c.ex", "absent", "x")

      assert File.read!(Path.join(tmp, "c.ex")) == "nothing here\n"
    end

    test "an ambiguous preview also stays strict at execution", %{tmp: tmp} do
      File.write!(Path.join(tmp, "c.ex"), "dup\ndup\n")

      assert {:ok, %{match: :ambiguous}} =
               Workspace.preview_edit("c.ex", "dup", "x")

      assert {:error, :edit_target_not_unique} =
               Workspace.do_edit("c.ex", "dup", "x")

      assert File.read!(Path.join(tmp, "c.ex")) == "dup\ndup\n"
    end
  end

  describe "preview_write (renderable preview)" do
    test "an overwrite previews the current content as old, marked exact", %{
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "a.txt"), "before\n")

      assert {:ok, diff} = Workspace.preview_write("a.txt", "after\n")

      assert diff.match == :exact
      assert diff.old == "before\n"
      assert diff.new == "after\n"
      assert is_binary(diff.base_hash)
      # Preview must not write.
      assert File.read!(Path.join(tmp, "a.txt")) == "before\n"
    end

    test "a new file previews an empty old with an :absent base_hash" do
      assert {:ok, diff} = Workspace.preview_write("brand_new.ex", "x\n")

      assert diff.match == :exact
      assert diff.old == ""
      assert diff.new == "x\n"
      assert diff.base_hash == :absent
    end
  end

  describe "glob (read-only)" do
    test "lists matching files relative to cwd", %{tmp: tmp} do
      File.write!(Path.join(tmp, "one.ex"), "")
      File.write!(Path.join(tmp, "two.ex"), "")
      File.write!(Path.join(tmp, "skip.txt"), "")

      assert {:ok, res} = Glob.call(%{pattern: "*.ex"})
      assert "one.ex" in res.matches
      assert "two.ex" in res.matches
      refute "skip.txt" in res.matches
    end

    test "rejects a pattern escaping cwd" do
      assert {:error, :outside_cwd} = Glob.call(%{pattern: "../*"})
    end
  end

  describe "grep (read-only)" do
    test "returns matching lines with 1-based line numbers", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "log.txt"),
        "alpha\nbeta match\ngamma\ndelta match\n"
      )

      assert {:ok, res} = Grep.call(%{pattern: "match", path: "log.txt"})
      assert res.count == 2
      assert "2:beta match" in res.matches
      assert "4:delta match" in res.matches
    end

    test "rejects an invalid regex" do
      assert {:error, :invalid_pattern} =
               Grep.call(%{pattern: "[unclosed", path: "x"})
    end
  end
end
