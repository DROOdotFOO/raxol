defmodule Raxol.Symphony.Review.ContractTest do
  use ExUnit.Case, async: true

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
        assert args == ["diff", "HEAD"]
        assert cwd == "/tmp/ws"
        {:ok, "GIT DIFF"}
      end

      c = Contract.build(issue(), workspace_path: "/tmp/ws", git_runner: git)
      assert c.diff == "GIT DIFF"
    end

    test "uses base_ref in the diff range when provided" do
      git = fn args, _cwd ->
        assert args == ["diff", "main...HEAD"]
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
end
