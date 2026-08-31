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
    test "anchors each line by default" do
      hash = Raxol.Agent.Actions.Anchor.hash("hello world")

      assert {:ok, %{content: content, anchored: true, truncated: false}} =
               Fs.ReadFile.run(%{path: "hello.txt"}, %{})

      assert content == "1:#{hash}|hello world"
    end

    test "anchors: false returns the raw bytes" do
      assert {:ok, %{content: "hello world", anchored: false, truncated: false}} =
               Fs.ReadFile.run(%{path: "hello.txt", anchors: false}, %{})
    end

    test "errors on missing file" do
      assert {:error, :enoent} = Fs.ReadFile.run(%{path: "nope.txt"}, %{})
    end

    test "errors outside the working dir" do
      assert {:error, :outside_cwd} =
               Fs.ReadFile.run(%{path: "../secrets"}, %{})
    end

    # The cap branch fires on the ANCHORED cost (line + `LINE:HASH|` prefix)
    # while the cut was against raw bytes, so a line a few bytes UNDER the cap
    # could cost more than it -- and `binary_part/3` raises when asked for more
    # bytes than the binary holds. Reading such a file crashed the tool.
    @max_bytes 262_144

    # An anchored line costs `bytes + hash(6) + digits(1) + 2`, so on line 1 the
    # clamp branch fires at `bytes >= @max_bytes - 8` while the cut was against
    # `bytes` alone. Slack 1..8 is the band where the branch fires on a line
    # SHORTER than the cut it then asked for, which is what raised.
    for slack <- [0, 1, 5, 8] do
      test "a first line #{slack} bytes under the cap truncates instead of raising",
           %{dir: dir} do
        line = String.duplicate("x", @max_bytes - unquote(slack))
        File.write!(Path.join(dir, "huge.txt"), line <> "\n")

        assert {:ok, result} = Fs.ReadFile.run(%{path: "huge.txt"}, %{})
        assert result.truncated
        assert byte_size(result.content) <= @max_bytes
      end
    end

    test "the longest line that still fits its anchor is not truncated", %{dir: dir} do
      line = String.duplicate("x", @max_bytes - 9)
      File.write!(Path.join(dir, "huge.txt"), line <> "\n")

      assert {:ok, result} = Fs.ReadFile.run(%{path: "huge.txt"}, %{})
      refute result.truncated
      assert result.anchored
    end

    # An oversized line cannot carry an honest anchor: hashing the CLAMPED text
    # gives one that never verifies, so `edit_file` would report the file as
    # changed when it had not, and hashing the full line gives one that DOES
    # verify and then replaces bytes the model never saw.
    test "a clamped line is reported unanchored rather than given a false anchor",
         %{dir: dir} do
      line = String.duplicate("x", @max_bytes + 10)
      File.write!(Path.join(dir, "huge.txt"), line <> "\n")

      assert {:ok, result} = Fs.ReadFile.run(%{path: "huge.txt"}, %{})
      assert result.truncated
      refute result.anchored
      refute result.content =~ "|"
    end

    test "a line that fits is still anchored and truncation is not claimed",
         %{dir: dir} do
      File.write!(Path.join(dir, "fits.txt"), String.duplicate("y", 1_000) <> "\n")

      assert {:ok, %{anchored: true, truncated: false}} =
               Fs.ReadFile.run(%{path: "fits.txt"}, %{})
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
               Fs.ReadFile.run(%{path: "hello.txt", anchors: false}, %{})

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
