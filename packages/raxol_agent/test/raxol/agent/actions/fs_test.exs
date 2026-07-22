defmodule Raxol.Agent.Actions.FsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Fs

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-fs-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "hello.txt"), "hello world")

    previous = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", dir)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("RAXOL_CLI_CWD")
        value -> System.put_env("RAXOL_CLI_CWD", value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "resolve/1" do
    test "accepts paths under the working dir", %{dir: dir} do
      assert {:ok, abs} = Fs.resolve("hello.txt")
      assert abs == Path.join(dir, "hello.txt")
      assert {:ok, ^dir} = Fs.resolve(".")
    end

    test "rejects escapes and outside absolute paths" do
      assert {:error, :outside_cwd} = Fs.resolve("../etc/passwd")
      assert {:error, :outside_cwd} = Fs.resolve("/etc/passwd")
      assert {:error, :outside_cwd} = Fs.resolve("sub/../../outside")
    end

    test "working_dir honors RAXOL_CLI_CWD", %{dir: dir} do
      assert Fs.working_dir() == dir
    end
  end

  describe "ListDir" do
    test "lists sorted entries with trailing slash on directories" do
      assert {:ok, %{entries: entries}} = Fs.ListDir.run(%{path: "."}, %{})
      assert entries == ["hello.txt", "sub/"]
    end

    test "defaults to the working dir root" do
      assert {:ok, %{path: ".", entries: entries}} = Fs.ListDir.run(%{}, %{})
      assert "hello.txt" in entries
    end
  end

  describe "ReadFile" do
    test "reads content with truncation flag" do
      assert {:ok, %{content: "hello world", truncated: false}} =
               Fs.ReadFile.run(%{path: "hello.txt"}, %{})
    end

    test "errors on missing file" do
      assert {:error, :enoent} = Fs.ReadFile.run(%{path: "nope.txt"}, %{})
    end

    test "errors outside the working dir" do
      assert {:error, :outside_cwd} =
               Fs.ReadFile.run(%{path: "../secrets"}, %{})
    end
  end

  describe "FileStat" do
    test "stats a file" do
      assert {:ok, %{type: "regular", size: size}} =
               Fs.FileStat.run(%{path: "hello.txt"}, %{})

      assert size == byte_size("hello world")
    end
  end

  describe "symlink containment" do
    setup %{dir: dir} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "raxol-fs-test-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "top secret")

      on_exit(fn -> File.rm_rf!(outside) end)

      %{dir: dir, outside: outside}
    end

    test "a symlinked directory pointing outside the sandbox is rejected",
         %{dir: dir, outside: outside} do
      link = Path.join(dir, "escape_dir")
      File.ln_s!(outside, link)

      assert {:error, :outside_cwd} = Fs.resolve("escape_dir/secret.txt")

      assert {:error, :outside_cwd} =
               Fs.ReadFile.run(%{path: "escape_dir/secret.txt"}, %{})

      assert {:error, :outside_cwd} =
               Fs.ListDir.run(%{path: "escape_dir"}, %{})
    end

    test "a symlinked file pointing outside the sandbox is rejected",
         %{dir: dir, outside: outside} do
      target = Path.join(outside, "secret.txt")
      link = Path.join(dir, "escape_file.txt")
      File.ln_s!(target, link)

      assert {:error, :outside_cwd} = Fs.resolve("escape_file.txt")

      assert {:error, :outside_cwd} =
               Fs.ReadFile.run(%{path: "escape_file.txt"}, %{})

      assert {:error, :outside_cwd} =
               Fs.FileStat.run(%{path: "escape_file.txt"}, %{})
    end

    # Regression trap: on macOS, `System.tmp_dir!/0`'s result (and plain
    # `/tmp`) sits behind a real symlink to `/private/...`. A prefix
    # check that canonicalizes the candidate but not the sandbox root
    # (or vice versa) either false-positives every ordinary call or
    # false-negatives an escape through the same discrepancy.
    test "a normal relative path inside cwd still resolves when the sandbox root itself is behind a symlink",
         %{dir: dir} do
      assert {:ok, abs} = Fs.resolve("hello.txt")
      assert abs == Path.join(dir, "hello.txt")

      assert {:ok, %{content: "hello world", truncated: false}} =
               Fs.ReadFile.run(%{path: "hello.txt"}, %{})

      assert {:ok, %{entries: entries}} = Fs.ListDir.run(%{path: "."}, %{})
      assert "hello.txt" in entries
    end

    test "a symlink chain that stays inside the sandbox still resolves",
         %{dir: dir} do
      target = Path.join(dir, "sub")
      link = Path.join(dir, "inside_link")
      File.ln_s!(target, link)

      assert {:ok, _abs} = Fs.resolve("inside_link")
      assert {:ok, %{entries: []}} = Fs.ListDir.run(%{path: "inside_link"}, %{})
    end
  end
end
