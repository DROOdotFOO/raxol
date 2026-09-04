defmodule Raxol.Agent.Actions.CodeTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Actions.Code
  alias Raxol.Agent.Lsp.Pool
  alias Raxol.Agent.Sandbox

  @server Path.expand("../../../support/fake_lsp_server.py", __DIR__)
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-code-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "hello.ex"),
      "defmodule Hello do\n  :world\nend\n"
    )

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

    test "includes post-write diagnostics when LSP is available", %{dir: dir} do
      assert {:ok, result} =
               Code.Write.run(
                 %{path: "new.toy", content: "def alpha\n  BROKEN thing\n"},
                 %{lsp_pool: pool(dir)}
               )

      assert [%{severity: "error", line: 2, message: "this line is broken"}] =
               result.diagnostics
    end
  end

  describe "Edit" do
    test "replaces a unique match and returns the before/after images", %{
      dir: dir
    } do
      assert {:ok, result} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   old_string: ":world",
                   new_string: ":earth"
                 },
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
      File.write!(
        Path.join(System.get_env("RAXOL_CLI_CWD"), "dup.txt"),
        "a a a"
      )

      assert {:error, {:not_unique, 3}} =
               Code.Edit.run(
                 %{path: "dup.txt", old_string: "a", new_string: "b"},
                 %{}
               )
    end

    test "includes post-edit diagnostics when LSP is available", %{dir: dir} do
      File.write!(Path.join(dir, "edit.toy"), "def alpha\n  fine\n")

      assert {:ok, result} =
               Code.Edit.run(
                 %{
                   path: "edit.toy",
                   old_string: "fine",
                   new_string: "BROKEN now"
                 },
                 %{lsp_pool: pool(dir)}
               )

      assert [%{severity: "error", line: 2, message: "this line is broken"}] =
               result.diagnostics
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

  describe "Edit by anchor" do
    alias Raxol.Agent.Actions.Anchor

    # The anchor a model would copy out of read_file's output for `line`
    # (1-based) of the fixture file.
    defp anchor_for(dir, file, line) do
      {lines, _trailing?} = dir |> Path.join(file) |> File.read!() |> Anchor.split()
      content = Enum.at(lines, line - 1)
      "#{line}:#{Anchor.hash(content)}"
    end

    test "replaces a single line", %{dir: dir} do
      assert {:ok, result} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 2),
                   new_string: "  :earth"
                 },
                 %{}
               )

      assert result.replacements == 1

      assert File.read!(Path.join(dir, "hello.ex")) ==
               "defmodule Hello do\n  :earth\nend\n"
    end

    test "replaces a multi-line range with a different number of lines", %{dir: dir} do
      assert {:ok, _result} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 1),
                   to: anchor_for(dir, "hello.ex", 3),
                   new_string: "defmodule Hello do\n  :a\n  :b\nend"
                 },
                 %{}
               )

      assert File.read!(Path.join(dir, "hello.ex")) ==
               "defmodule Hello do\n  :a\n  :b\nend\n"
    end

    test "an empty new_string deletes the range", %{dir: dir} do
      assert {:ok, _result} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 2),
                   new_string: ""
                 },
                 %{}
               )

      assert File.read!(Path.join(dir, "hello.ex")) == "defmodule Hello do\nend\n"
    end

    test "a file without a trailing newline keeps not having one", %{dir: dir} do
      File.write!(Path.join(dir, "bare.txt"), "one\ntwo")

      assert {:ok, _result} =
               Code.Edit.run(
                 %{
                   path: "bare.txt",
                   from: anchor_for(dir, "bare.txt", 1),
                   new_string: "ONE"
                 },
                 %{}
               )

      assert File.read!(Path.join(dir, "bare.txt")) == "ONE\ntwo"
    end

    test "a trailing newline in new_string does not add a blank line", %{dir: dir} do
      assert {:ok, _result} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 2),
                   new_string: "  :earth\n"
                 },
                 %{}
               )

      assert File.read!(Path.join(dir, "hello.ex")) ==
               "defmodule Hello do\n  :earth\nend\n"
    end

    test "refuses an anchor whose line changed since it was read", %{dir: dir} do
      stale = anchor_for(dir, "hello.ex", 2)
      File.write!(Path.join(dir, "hello.ex"), "defmodule Hello do\n  :mars\nend\n")

      assert {:error, {:anchor_mismatch, 2, _expected, _actual}} =
               Code.Edit.run(
                 %{path: "hello.ex", from: stale, new_string: "  :earth"},
                 %{}
               )

      assert File.read!(Path.join(dir, "hello.ex")) =~ ":mars"
    end

    test "refuses an anchor past the end of the file", %{dir: dir} do
      anchor = anchor_for(dir, "hello.ex", 2)
      line = "99:" <> (anchor |> String.split(":") |> List.last())

      assert {:error, {:anchor_out_of_range, 99, 3}} =
               Code.Edit.run(
                 %{path: "hello.ex", from: line, new_string: "x"},
                 %{}
               )
    end

    test "refuses an inverted range", %{dir: dir} do
      assert {:error, {:range_inverted, 3, 1}} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 3),
                   to: anchor_for(dir, "hello.ex", 1),
                   new_string: "x"
                 },
                 %{}
               )
    end

    test "refuses a malformed anchor" do
      assert {:error, :malformed_anchor} =
               Code.Edit.run(
                 %{path: "hello.ex", from: "line two", new_string: "x"},
                 %{}
               )
    end

    test "refuses a call that addresses both ways", %{dir: dir} do
      assert {:error, :ambiguous_addressing} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 2),
                   old_string: ":world",
                   new_string: "x"
                 },
                 %{}
               )
    end

    test "refuses a call that addresses neither way" do
      assert {:error, :no_addressing} =
               Code.Edit.run(%{path: "hello.ex", new_string: "x"}, %{})
    end

    test "rejects a replacement identical to the addressed range", %{dir: dir} do
      assert {:error, :no_change} =
               Code.Edit.run(
                 %{
                   path: "hello.ex",
                   from: anchor_for(dir, "hello.ex", 2),
                   new_string: "  :world"
                 },
                 %{}
               )
    end

    test "an anchor copied straight out of read_file output works", %{dir: dir} do
      assert {:ok, %{content: content}} =
               Raxol.Agent.Actions.Fs.ReadFile.run(%{path: "hello.ex"}, %{})

      # Exactly what a model reads off the wire: the prefix before the pipe.
      [_first, second | _rest] = String.split(content, "\n")
      [prefix, _line] = String.split(second, "|", parts: 2)

      assert {:ok, _result} =
               Code.Edit.run(
                 %{path: "hello.ex", from: prefix, new_string: "  :earth"},
                 %{}
               )

      assert File.read!(Path.join(dir, "hello.ex")) =~ ":earth"
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

    test "a command that reads stdin sees EOF instead of an open pipe" do
      # `run_shell/4` never writes to the port, so an inherited write pipe only
      # signals "more input is coming". Without `:in`, `cat` blocks until the
      # deadline and `exit_status` comes back `:timeout`.
      assert {:ok, result} =
               Code.Bash.run(%{command: "cat", timeout_ms: 2_000}, %{})

      assert result.exit_status == 0
      assert result.truncated == false
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

    # The acceptance criterion, run through the real tool rather than the policy
    # function: with an `echo` allowlist configured, no wrapper in the corpus
    # may read or write a sentinel file outside the workspace.
    test "an allowlisted binary cannot be used to reach an outside sentinel" do
      outside =
        Path.join(
          System.tmp_dir!(),
          "raxol-sentinel-#{System.unique_integer([:positive])}"
        )

      File.write!(outside, "SENTINEL\n")
      on_exit(fn -> File.rm_rf!(outside) end)

      sandbox = Sandbox.Shell.allowlist(["echo"])

      attempts = [
        "echo x; cat #{outside}",
        "echo x && cat #{outside}",
        "echo x | cat #{outside}",
        "echo $(cat #{outside})",
        "echo `cat #{outside}`",
        "echo x\ncat #{outside}",
        "echo pwned > #{outside}",
        "echo x; rm -f #{outside}",
        "echo x; sh -c 'cat #{outside}'"
      ]

      for command <- attempts do
        assert {:error, {:shell_denied, ^command}} =
                 Code.Bash.run(%{command: command}, %{shell_sandbox: sandbox}),
               "expected a denial for: #{inspect(command)}"
      end

      # Untouched: not read out through a result, not overwritten, not deleted.
      assert File.read!(outside) == "SENTINEL\n"
    end

    test "refuses to run in a jailed session" do
      # The cwd jail does not confine a shell command line, so a jailed
      # (multi-tenant) session must not get the shell at all until per-tenant
      # OS confinement is wired.
      assert {:error, :shell_disabled_in_jail} =
               Code.Bash.run(%{command: "cat ../../other/secret"}, %{jail: true})

      # A lexical policy does NOT re-enable it. This used to pass, on the
      # strength of a `%Sandbox.Shell{}` being present at all -- which meant
      # `Sandbox.Shell.none()`, documented as "any shell command allowed",
      # handed a jailed tenant an unrestricted shell.
      sandbox = Sandbox.Shell.allowlist(["echo"])

      assert {:error, :shell_disabled_in_jail} =
               Code.Bash.run(
                 %{command: "echo ok"},
                 %{jail: true, shell_sandbox: sandbox}
               )
    end
  end

  describe "shell_jail_allow/1" do
    test "refuses a jailed context" do
      assert {:error, :shell_disabled_in_jail} =
               Code.shell_jail_allow(%{jail: true})
    end

    test "allows a non-jailed context" do
      assert :ok = Code.shell_jail_allow(%{})
      assert :ok = Code.shell_jail_allow(%{jail: false})
    end

    test "a lexical sandbox is not evidence of confinement" do
      for sandbox <- [
            Sandbox.Shell.none(),
            Sandbox.Shell.allowlist(["echo"]),
            Sandbox.Shell.denylist(["rm"])
          ] do
        assert {:error, :shell_disabled_in_jail} =
                 Code.shell_jail_allow(%{jail: true, shell_sandbox: sandbox})
      end
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

      assert {:ok, %{paths: paths}} =
               Code.Glob.run(%{pattern: "lib/**/*.ex"}, %{})

      assert "lib/one.ex" in paths
      assert "lib/two.ex" in paths
      assert paths == Enum.sort(paths)
    end
  end

  # Fs.resolve/2 confines the base directory an action is POINTED at, but the
  # walkers underneath it re-derive paths from the filesystem, where a symlink
  # leads wherever it likes. grep and glob are both auto-allowed, and the
  # executor's outside-cwd escalation only covers read_file, so nothing
  # downstream would prompt for what these return.
  describe "sandbox containment through symlinks" do
    setup %{dir: dir} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "raxol-code-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "TOPSECRET value\n")
      File.ln_s!(outside, Path.join(dir, "vendor"))

      on_exit(fn -> File.rm_rf!(outside) end)
      %{outside: outside}
    end

    test "grep does not read through a symlink pointing out of the sandbox" do
      # The native scanner is the hole: it walks with File.dir?/File.regular?,
      # which follow symlinks. Strip PATH so ripgrep cannot mask it.
      without_ripgrep(fn ->
        assert {:ok, %{matches: matches}} =
                 Code.Grep.run(%{pattern: "TOPSECRET"}, %{})

        assert matches == []
      end)
    end

    test "a regex ripgrep rejects cannot read out of the sandbox either" do
      # A backreference is the model's lever onto the native scanner even where
      # ripgrep is installed: rg exits 2 on it, and grep_ripgrep routes any
      # status outside [0, 1] to grep_native, whose PCRE compile accepts it.
      assert {:ok, %{matches: matches}} =
               Code.Grep.run(%{pattern: "(TOPSECRET)\\1?"}, %{})

      assert matches == []
    end

    test "glob does not list paths through a symlink pointing out of the sandbox" do
      assert {:ok, %{paths: paths}} = Code.Glob.run(%{pattern: "**/*.txt"}, %{})

      refute Enum.any?(paths, &(&1 =~ "secret"))
    end

    test "a file genuinely inside the sandbox is still found", %{dir: dir} do
      File.write!(Path.join(dir, "inside.txt"), "TOPSECRET value\n")

      without_ripgrep(fn ->
        assert {:ok, %{matches: matches}} =
                 Code.Grep.run(%{pattern: "TOPSECRET"}, %{})

        assert Enum.map(matches, & &1.path) == ["inside.txt"]
      end)
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

  defp pool(dir) do
    {:ok, pool} = Pool.start_link(root: dir, servers: servers())
    on_exit(fn -> Pool.stop(pool) end)
    pool
  end

  defp servers do
    [
      %{
        name: "toy",
        command: @server,
        args: [],
        extensions: [".toy"],
        language_id: "toy"
      }
    ]
  end

  # Pins the pure-Elixir scanner, which is what runs wherever ripgrep is not
  # installed and wherever the model hands us a regex ripgrep rejects.
  defp without_ripgrep(fun) do
    previous = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      fun.()
    after
      case previous do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end
    end
  end

  describe "tool-call gating (the security seam)" do
    test "sensitive write_file is denied under the default policy" do
      call = %{
        "name" => "write_file",
        "arguments" => %{"path" => "x", "content" => "y"}
      }

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
