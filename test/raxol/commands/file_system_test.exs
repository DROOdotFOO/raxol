defmodule Raxol.Commands.FileSystemTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Commands.FileSystem

  @state_machine_paths [
    "/alpha",
    "/alpha/one",
    "/alpha/one/deep",
    "/alpha/two",
    "/beta",
    "/beta/one"
  ]

  describe "new/0" do
    test "creates filesystem with root directory" do
      fs = FileSystem.new()
      assert fs.cwd == "/"
      assert fs.prev_dir == nil
      assert Map.has_key?(fs.nodes, "/")
      assert fs.nodes["/"].type == :directory
      assert fs.nodes["/"].children == []
    end
  end

  describe "mkdir/2" do
    test "creates directory at root" do
      fs = FileSystem.new()
      assert {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      assert fs.nodes["/docs"].type == :directory
      assert fs.nodes["/docs"].children == []
      assert "docs" in fs.nodes["/"].children
    end

    test "creates nested directory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.mkdir(fs, "/docs/work")
      assert fs.nodes["/docs/work"].type == :directory
      assert "work" in fs.nodes["/docs"].children
    end

    test "fails if already exists" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      assert {:error, :already_exists} = FileSystem.mkdir(fs, "/docs")
    end

    test "fails if parent does not exist" do
      fs = FileSystem.new()
      assert {:error, :parent_not_found} = FileSystem.mkdir(fs, "/docs/work")
    end

    test "creates directory using relative path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "docs")
      assert Map.has_key?(fs.nodes, "/docs")
    end

    test "creates directory using relative path from subdirectory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      {:ok, fs} = FileSystem.mkdir(fs, "work")
      assert Map.has_key?(fs.nodes, "/docs/work")
    end
  end

  describe "create_file/3" do
    test "creates file at root" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/readme.txt", "Hello")
      assert fs.nodes["/readme.txt"].type == :file
      assert fs.nodes["/readme.txt"].content == "Hello"
      assert fs.nodes["/readme.txt"].size == 5
      assert "readme.txt" in fs.nodes["/"].children
    end

    test "creates file in subdirectory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/notes.txt", "Notes")
      assert fs.nodes["/docs/notes.txt"].type == :file
      assert "notes.txt" in fs.nodes["/docs"].children
    end

    test "fails if already exists" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")

      assert {:error, :already_exists} =
               FileSystem.create_file(fs, "/a.txt", "b")
    end

    test "fails if parent does not exist" do
      fs = FileSystem.new()

      assert {:error, :parent_not_found} =
               FileSystem.create_file(fs, "/x/a.txt", "a")
    end

    test "stores correct byte size for multi-byte content" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/utf8.txt", "héllo")
      # "héllo" is 6 bytes (é = 2 bytes UTF-8)
      assert fs.nodes["/utf8.txt"].size == 6
    end

    test "creates file using relative path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "readme.txt", "Hi")
      assert Map.has_key?(fs.nodes, "/readme.txt")
    end

    test "refuses files and directories below a file" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/parent", "payload")

      for {path, create} <- [
            {"/parent/child.txt",
             &FileSystem.create_file(&1, "/parent/child.txt", "child")},
            {"/parent/child-dir", &FileSystem.mkdir(&1, "/parent/child-dir")}
          ] do
        assert {:error, :not_a_directory} = create.(fs)
        refute FileSystem.exists?(fs, path)
      end

      assert {:ok, "payload"} = FileSystem.cat(fs, "/parent")
    end
  end

  describe "rm/2" do
    test "removes a file" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      {:ok, fs} = FileSystem.rm(fs, "/a.txt")
      refute Map.has_key?(fs.nodes, "/a.txt")
      refute "a.txt" in fs.nodes["/"].children
    end

    test "removes an empty directory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/empty")
      {:ok, fs} = FileSystem.rm(fs, "/empty")
      refute Map.has_key?(fs.nodes, "/empty")
    end

    test "fails on non-empty directory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/a.txt", "a")
      assert {:error, :directory_not_empty} = FileSystem.rm(fs, "/docs")
    end

    test "fails on non-existent path" do
      fs = FileSystem.new()
      assert {:error, :not_found} = FileSystem.rm(fs, "/nope")
    end

    test "cannot remove root" do
      fs = FileSystem.new()
      assert {:error, :cannot_remove_root} = FileSystem.rm(fs, "/")
    end
  end

  describe "exists?/2" do
    test "returns true for existing file" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      assert FileSystem.exists?(fs, "/a.txt")
    end

    test "returns true for existing directory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      assert FileSystem.exists?(fs, "/docs")
    end

    test "returns true for root" do
      assert FileSystem.exists?(FileSystem.new(), "/")
    end

    test "returns false for non-existent path" do
      refute FileSystem.exists?(FileSystem.new(), "/nope")
    end
  end

  describe "stat/2" do
    test "returns file metadata" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "hello")
      {:ok, stat} = FileSystem.stat(fs, "/a.txt")
      assert stat.type == :file
      assert stat.size == 5
      assert stat.path == "/a.txt"
      assert is_integer(stat.created_at)
      assert is_integer(stat.modified_at)
    end

    test "returns directory metadata" do
      fs = FileSystem.new()
      {:ok, stat} = FileSystem.stat(fs, "/")
      assert stat.type == :directory
      assert stat.path == "/"
    end

    test "fails on non-existent path" do
      assert {:error, :not_found} = FileSystem.stat(FileSystem.new(), "/nope")
    end
  end

  describe "ls/2" do
    test "lists root entries sorted" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/readme.txt", "hi")
      {:ok, fs} = FileSystem.mkdir(fs, "/apps")
      assert {:ok, ["apps", "docs", "readme.txt"]} = FileSystem.ls(fs, "/")
    end

    test "lists subdirectory entries" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/a.txt", "a")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/b.txt", "b")
      assert {:ok, ["a.txt", "b.txt"]} = FileSystem.ls(fs, "/docs")
    end

    test "empty directory returns empty list" do
      assert {:ok, []} = FileSystem.ls(FileSystem.new(), "/")
    end

    test "defaults to cwd" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      assert {:ok, ["a.txt"]} = FileSystem.ls(fs)
    end

    test "fails on non-existent path" do
      assert {:error, :not_found} = FileSystem.ls(FileSystem.new(), "/nope")
    end

    test "fails on file path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      assert {:error, :not_a_directory} = FileSystem.ls(fs, "/a.txt")
    end
  end

  describe "cd/2" do
    test "changes to absolute path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      assert fs.cwd == "/docs"
      assert fs.prev_dir == "/"
    end

    test "changes to relative path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "docs")
      assert fs.cwd == "/docs"
    end

    test "changes to parent with .." do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "..")
      assert fs.cwd == "/"
    end

    test "changes to previous with -" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/")
      {:ok, fs} = FileSystem.cd(fs, "-")
      assert fs.cwd == "/docs"
    end

    test "- fails when no previous directory" do
      fs = FileSystem.new()
      assert {:error, :no_previous_directory} = FileSystem.cd(fs, "-")
    end

    test "fails on non-existent path" do
      assert {:error, :not_found} = FileSystem.cd(FileSystem.new(), "/nope")
    end

    test "fails when target is a file" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      assert {:error, :not_a_directory} = FileSystem.cd(fs, "/a.txt")
    end

    test "handles nested relative path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/a")
      {:ok, fs} = FileSystem.mkdir(fs, "/a/b")
      {:ok, fs} = FileSystem.cd(fs, "a/b")
      assert fs.cwd == "/a/b"
    end

    test ".. at root stays at root" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.cd(fs, "..")
      assert fs.cwd == "/"
    end
  end

  describe "pwd/1" do
    test "returns current directory" do
      fs = FileSystem.new()
      assert FileSystem.pwd(fs) == "/"
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      assert FileSystem.pwd(fs) == "/docs"
    end
  end

  describe "cat/2" do
    test "reads file content" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "hello world")
      assert {:ok, "hello world"} = FileSystem.cat(fs, "/a.txt")
    end

    test "fails on non-existent file" do
      assert {:error, :not_found} = FileSystem.cat(FileSystem.new(), "/nope")
    end

    test "fails on directory" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      assert {:error, :is_a_directory} = FileSystem.cat(fs, "/docs")
    end

    test "reads file using relative path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/a.txt", "content")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      assert {:ok, "content"} = FileSystem.cat(fs, "a.txt")
    end
  end

  describe "tree/3" do
    test "returns tree for root" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/readme.txt", "hi")
      {:ok, tree} = FileSystem.tree(fs, "/", 2)
      assert {"/", :directory, children} = tree
      assert length(children) == 2
    end

    test "respects depth limit" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/a")
      {:ok, fs} = FileSystem.mkdir(fs, "/a/b")
      {:ok, fs} = FileSystem.mkdir(fs, "/a/b/c")
      {:ok, {"/", :directory, children}} = FileSystem.tree(fs, "/", 1)
      {_name, :directory, nested} = hd(children)
      assert nested == []
    end

    test "returns file node for file path" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      assert {:ok, {"a.txt", :file, []}} = FileSystem.tree(fs, "/a.txt")
    end

    test "fails on non-existent path" do
      assert {:error, :not_found} = FileSystem.tree(FileSystem.new(), "/nope")
    end

    test "children are sorted alphabetically" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/c.txt", "c")
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      {:ok, fs} = FileSystem.create_file(fs, "/b.txt", "b")
      {:ok, {"/", :directory, children}} = FileSystem.tree(fs, "/")
      names = Enum.map(children, fn {name, _, _} -> name end)
      assert names == ["a.txt", "b.txt", "c.txt"]
    end
  end

  describe "format_ls/3" do
    test "formats directories with trailing slash" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      assert [{"docs/", :directory}] = FileSystem.format_ls(["docs"], fs, "/")
    end

    test "formats files with size" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "hello")
      assert [{"a.txt  5B", :file}] = FileSystem.format_ls(["a.txt"], fs, "/")
    end

    test "sorts entries" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/a.txt", "a")
      result = FileSystem.format_ls(["docs", "a.txt"], fs, "/")
      names = Enum.map(result, fn {text, _} -> text end)
      assert hd(names) |> String.starts_with?("a.txt")
    end
  end

  describe "format_cat/3" do
    test "numbers lines" do
      result = FileSystem.format_cat("line1\nline2\nline3", 80, 24)
      assert length(result) == 3
      assert {"line1", 1} = hd(result)
      assert {"line3", 3} = List.last(result)
    end

    test "truncates to max_height" do
      content = Enum.map_join(1..50, "\n", &"line#{&1}")
      result = FileSystem.format_cat(content, 80, 10)
      assert length(result) == 10
    end

    test "truncates long lines to max_width" do
      long = String.duplicate("x", 100)
      [{text, 1}] = FileSystem.format_cat(long, 40, 24)
      assert String.length(text) == 40
      assert String.ends_with?(text, "~")
    end

    test "does not truncate short lines" do
      [{text, 1}] = FileSystem.format_cat("short", 80, 24)
      assert text == "short"
    end
  end

  describe "node parent invariant" do
    property "every successfully created non-root node has a directory parent" do
      check all(
              parent_type <- member_of([:directory, :file]),
              child_type <- member_of([:directory, :file]),
              tail <- list_of(vfs_operation(), max_length: 20),
              max_runs: 50
            ) do
        operations = [
          {parent_type, "/parent"},
          {child_type, "/parent/child"} | tail
        ]

        Enum.reduce(
          operations,
          {FileSystem.new(), MapSet.new(["/"])},
          &apply_operation_and_check/2
        )
      end
    end
  end

  describe "path resolution" do
    test "resolves . to cwd" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.cd(fs, "/docs")
      assert FileSystem.exists?(fs, ".")
    end

    test "resolves complex relative paths" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/a")
      {:ok, fs} = FileSystem.mkdir(fs, "/a/b")
      {:ok, fs} = FileSystem.mkdir(fs, "/a/b/c")
      {:ok, fs} = FileSystem.cd(fs, "/a/b/c")
      {:ok, fs} = FileSystem.cd(fs, "../../")
      assert fs.cwd == "/a"
    end

    test ".. past root resolves to root" do
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.cd(fs, "..")
      assert fs.cwd == "/"
      {:ok, fs} = FileSystem.cd(fs, "../../..")
      assert fs.cwd == "/"
    end
  end

  defp vfs_operation do
    tuple({
      member_of([:directory, :file, :remove]),
      member_of(@state_machine_paths)
    })
  end

  defp apply_operation_and_check({kind, path}, {fs, paths}) do
    result =
      case kind do
        :directory -> FileSystem.mkdir(fs, path)
        :file -> FileSystem.create_file(fs, path, "content")
        :remove -> FileSystem.rm(fs, path)
      end

    case result do
      {:ok, next_fs} ->
        next_paths =
          case kind do
            :remove -> MapSet.delete(paths, path)
            _ -> MapSet.put(paths, path)
          end

        assert_directory_parents(next_fs, next_paths)
        {next_fs, next_paths}

      {:error, _reason} ->
        {fs, paths}
    end
  end

  defp assert_directory_parents(fs, paths) do
    Enum.each(paths, fn
      "/" ->
        :ok

      path ->
        assert {:ok, %{type: :directory}} =
                 FileSystem.stat(fs, Path.dirname(path)),
               "#{path} has a missing or non-directory parent"
    end)
  end
end
