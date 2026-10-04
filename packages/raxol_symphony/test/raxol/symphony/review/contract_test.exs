defmodule Raxol.Symphony.Review.ContractTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Review.Contract

  defp issue do
    %Issue{id: "i-1", identifier: "MT-7", title: "Add widget", state: "Todo"}
  end

  describe "build/2" do
    test "carries issue metadata and explicit diff" do
      c = Contract.build(issue(), diff: "DIFF", implementer_kind: "codex", summary: "did it")

      assert c.issue_identifier == "MT-7"
      assert c.issue_title == "Add widget"
      assert c.implementer_kind == "codex"
      assert c.diff == "DIFF"
      assert c.summary == "did it"
    end

    test "collects the diff with an injected git runner (no base ref)" do
      git = fn args, cwd ->
        assert List.last(args) == "HEAD"
        assert cwd == "/tmp/ws"
        {:ok, "GIT DIFF"}
      end

      c = Contract.build(issue(), workspace_path: "/tmp/ws", git_runner: git)
      assert c.diff == "GIT DIFF"
    end

    test "uses base_ref in the diff range when provided" do
      git = fn args, _cwd ->
        assert List.last(args) == "main...HEAD"
        {:ok, "RANGE DIFF"}
      end

      c = Contract.build(issue(), workspace_path: "/tmp/ws", base_ref: "main", git_runner: git)
      assert c.diff == "RANGE DIFF"
    end

    test "a git failure yields an empty diff rather than raising" do
      git = fn _args, _cwd -> {:error, :git_failed} end
      c = Contract.build(issue(), workspace_path: "/tmp/ws", git_runner: git)
      assert c.diff == ""
    end

    test "no workspace and no diff yields an empty diff" do
      c = Contract.build(issue(), implementer_kind: "codex")
      assert c.diff == ""
    end

    test "the contract never carries a workspace reference" do
      c = Contract.build(issue(), workspace_path: "/tmp/ws", diff: "X")
      refute Map.has_key?(c, :workspace_path)
      refute Map.has_key?(c, :workspace)
    end
  end

  describe "build/2 with real git" do
    @describetag :unix_only

    setup do
      previous = System.get_env("RAXOL_SLEUTH_API_KEY")
      System.put_env("RAXOL_SLEUTH_API_KEY", "sk-probe-not-real")

      on_exit(fn ->
        if previous,
          do: System.put_env("RAXOL_SLEUTH_API_KEY", previous),
          else: System.delete_env("RAXOL_SLEUTH_API_KEY")
      end)

      dir = Path.join(System.tmp_dir!(), "contract-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp git!(dir, args) do
      {out, 0} =
        System.cmd("git", ["-c", "commit.gpgsign=false" | args], cd: dir, stderr_to_stdout: true)

      out
    end

    test "a workspace's own external diff and fsmonitor never run, nor see raxol's secrets",
         %{dir: dir} do
      ws = Path.join(dir, "ws")
      File.mkdir_p!(ws)
      leak = Path.join(dir, "leak")

      hook = Path.join(dir, "hook.sh")

      File.write!(hook, """
      #!/bin/sh
      printf '%s\\n' "${RAXOL_SLEUTH_API_KEY-unset}" >> #{leak}
      printf 'external:%s\\n' "${RAXOL_SLEUTH_API_KEY-unset}"
      """)

      File.chmod!(hook, 0o755)

      git!(ws, ["init", "-q"])
      git!(ws, ["config", "user.email", "t@example.com"])
      git!(ws, ["config", "user.name", "t"])
      File.write!(Path.join(ws, "f.txt"), "one\n")
      git!(ws, ["add", "f.txt"])
      git!(ws, ["commit", "-q", "-m", "init"])
      git!(ws, ["config", "diff.external", hook])
      git!(ws, ["config", "core.fsmonitor", hook])
      File.write!(Path.join(ws, "f.txt"), "two\n")

      c = Contract.build(issue(), workspace_path: ws)

      assert c.diff =~ "-one\n+two\n"
      refute c.diff =~ "sk-probe-not-real"
      refute c.diff =~ "external:"
      refute File.exists?(leak)
    end
  end
end
