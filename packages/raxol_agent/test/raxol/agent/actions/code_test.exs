defmodule Raxol.Agent.Actions.CodeTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Sandbox

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-code-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.ex"), "defmodule Hello do\n  :world\nend\n")

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

  describe "Write" do
    test "creates a new file and returns a diff-shaped result", %{dir: dir} do
      assert {:ok, result} =
               Code.Write.run(%{path: "new.ex", content: "x = 1\n"}, %{})

      assert result.path == "new.ex"
      assert result.old == ""
      assert result.new == "x = 1\n"
      assert result.language == "elixir"
      assert result.created == true
      assert File.read!(Path.join(dir, "new.ex")) == "x = 1\n"
    end

    test "creates parent directories as needed", %{dir: dir} do
      assert {:ok, _} =
               Code.Write.run(%{path: "lib/deep/mod.ex", content: "ok\n"}, %{})

      assert File.read!(Path.join(dir, "lib/deep/mod.ex")) == "ok\n"
    end

    test "refuses to clobber an existing file without overwrite" do
      assert {:error, :file_exists} =
               Code.Write.run(%{path: "hello.ex", content: "nope"}, %{})
    end

    test "overwrites when overwrite is true", %{dir: dir} do
      assert {:ok, result} =
               Code.Write.run(
                 %{path: "hello.ex", content: "new\n", overwrite: true},
                 %{}
               )

      assert result.created == false
      assert result.old =~ "defmodule Hello"
      assert result.new == "new\n"
      assert File.read!(Path.join(dir, "hello.ex")) == "new\n"
    end

    test "rejects paths outside the working dir" do
      assert {:error, :outside_cwd} =
               Code.Write.run(%{path: "../escape", content: "x"}, %{})
    end
  end

  describe "Edit" do
    test "replaces a unique match and returns the before/after images", %{dir: dir} do
      assert {:ok, result} =
               Code.Edit.run(
                 %{path: "hello.ex", old_string: ":world", new_string: ":earth"},
                 %{}
               )

      assert result.replacements == 1
      assert result.old =~ ":world"
      assert result.new =~ ":earth"
      assert File.read!(Path.join(dir, "hello.ex")) =~ ":earth"
    end

    test "errors when the old_string is not found" do
      assert {:error, :no_match} =
               Code.Edit.run(
                 %{path: "hello.ex", old_string: "absent", new_string: "x"},
                 %{}
               )
    end

    test "errors when the match is not unique" do
      File.write!(Path.join(System.get_env("RAXOL_CLI_CWD"), "dup.txt"), "a a a")

      assert {:error, :not_unique} =
               Code.Edit.run(
                 %{path: "dup.txt", old_string: "a", new_string: "b"},
                 %{}
               )
    end

    test "replace_all replaces every occurrence", %{dir: dir} do
      File.write!(Path.join(dir, "dup.txt"), "a a a")

      assert {:ok, %{replacements: 3}} =
               Code.Edit.run(
                 %{
                   path: "dup.txt",
                   old_string: "a",
                   new_string: "b",
                   replace_all: true
                 },
                 %{}
               )

      assert File.read!(Path.join(dir, "dup.txt")) == "b b b"
    end

    test "rejects a no-op edit" do
      assert {:error, :no_change} =
               Code.Edit.run(
                 %{path: "hello.ex", old_string: "same", new_string: "same"},
                 %{}
               )
    end
  end

  describe "Bash" do
    test "runs a command and captures stdout + exit status" do
      assert {:ok, result} =
               Code.Bash.run(%{command: "echo hello"}, %{})

      assert result.stdout == "hello\n"
      assert result.exit_status == 0
      assert result.truncated == false
    end

    test "captures a non-zero exit status" do
      assert {:ok, %{exit_status: status}} =
               Code.Bash.run(%{command: "exit 3"}, %{})

      assert status == 3
    end

    test "runs in the working directory by default", %{dir: dir} do
      # `/bin/sh pwd` reports the physical path (macOS resolves /var ->
      # /private/var), so match on the unique dir basename rather than the
      # possibly-symlinked absolute path.
      assert {:ok, %{stdout: out}} = Code.Bash.run(%{command: "pwd"}, %{})
      assert String.ends_with?(String.trim(out), Path.basename(dir))
    end

    test "honors a shell sandbox denylist in context" do
      sandbox = Sandbox.Shell.denylist(["rm"])

      assert {:error, {:shell_denied, "rm -rf /"}} =
               Code.Bash.run(%{command: "rm -rf /"}, %{shell_sandbox: sandbox})
    end

    test "allows a command permitted by the sandbox allowlist" do
      sandbox = Sandbox.Shell.allowlist(["echo"])

      assert {:ok, %{exit_status: 0}} =
               Code.Bash.run(%{command: "echo ok"}, %{shell_sandbox: sandbox})
    end
  end

  describe "Grep" do
    test "finds matches with path, line, and text", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "alpha\nbeta\ngamma\n")

      assert {:ok, %{matches: matches, count: count}} =
               Code.Grep.run(%{pattern: "beta"}, %{})

      assert count >= 1
      assert Enum.any?(matches, &(&1.text =~ "beta" and &1.line == 2))
    end

    test "ignore_case matches case-insensitively", %{dir: dir} do
      File.write!(Path.join(dir, "b.txt"), "HELLO\n")

      assert {:ok, %{count: count}} =
               Code.Grep.run(%{pattern: "hello", ignore_case: true}, %{})

      assert count >= 1
    end

    test "rejects a directory outside the working dir" do
      assert {:error, :outside_cwd} =
               Code.Grep.run(%{pattern: "x", path: "../.."}, %{})
    end
  end

  describe "Glob" do
    test "returns sorted cwd-relative matches", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/one.ex"), "1")
      File.write!(Path.join(dir, "lib/two.ex"), "2")

      assert {:ok, %{paths: paths}} = Code.Glob.run(%{pattern: "lib/**/*.ex"}, %{})
      assert "lib/one.ex" in paths
      assert "lib/two.ex" in paths
      assert paths == Enum.sort(paths)
    end
  end

  describe "diff_result/4 image cap" do
    test "drops the diff for a large before/after image" do
      big = String.duplicate("x", 40_000)
      result = Code.diff_result("big.txt", "", big, %{created: true})

      refute Map.has_key?(result, :new)
      assert result.truncated == true
      assert result.new_bytes == 40_000
    end
  end

  describe "tool-call gating (the security seam)" do
    test "sensitive write_file is denied under the default policy" do
      call = %{"name" => "write_file", "arguments" => %{"path" => "x", "content" => "y"}}

      assert {:error, {:tool_denied, "write_file", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(call, Code.all(), %{})

      refute File.exists?(Path.join(System.get_env("RAXOL_CLI_CWD"), "x"))
    end

    test "sensitive bash is denied under the default policy" do
      call = %{"name" => "bash", "arguments" => %{"command" => "echo pwned"}}

      assert {:error, {:tool_denied, "bash", :sensitive_tool}} =
               ToolConverter.dispatch_tool_call(call, Code.all(), %{})
    end

    test "read-only grep is allowed under the default policy" do
      call = %{"name" => "grep", "arguments" => %{"pattern" => "Hello"}}

      assert {:ok, %{count: _}} =
               ToolConverter.dispatch_tool_call(call, Code.all(), %{})
    end

    test "write_file runs when an allow-all authorizer opts in", %{dir: dir} do
      call = %{
        "name" => "write_file",
        "arguments" => %{"path" => "opted.txt", "content" => "in\n"}
      }

      context = %{tool_authorizer: Raxol.Agent.ToolPolicy.allow_all()}

      assert {:ok, %{path: "opted.txt"}} =
               ToolConverter.dispatch_tool_call(call, Code.all(), context)

      assert File.read!(Path.join(dir, "opted.txt")) == "in\n"
    end
  end
end
