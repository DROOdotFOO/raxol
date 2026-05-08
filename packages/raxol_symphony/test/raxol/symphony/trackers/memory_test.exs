defmodule Raxol.Symphony.Trackers.MemoryTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Tracker}
  alias Raxol.Symphony.Trackers.Memory

  setup do
    # Use start_supervised to avoid leaking processes between tests; this
    # rules out async: true since Memory is registered globally.
    start_supervised!({Memory, []})

    config =
      Config.from_workflow(%{
        config: %{
          tracker: %{
            kind: "memory",
            active_states: ["Todo", "In Progress"]
          }
        },
        prompt_template: ""
      })

    %{config: config}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  describe "fetch_candidate_issues/1" do
    test "returns only issues in active_states", %{config: config} do
      Memory.put_issues([
        issue("a", "MT-1", "Todo"),
        issue("b", "MT-2", "In Progress"),
        issue("c", "MT-3", "Done"),
        issue("d", "MT-4", "Cancelled")
      ])

      assert {:ok, issues} = Tracker.fetch_candidate_issues(config)
      identifiers = Enum.map(issues, & &1.identifier) |> Enum.sort()
      assert identifiers == ["MT-1", "MT-2"]
    end

    test "returns empty list when nothing is in active_states", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Done"))
      assert {:ok, []} = Tracker.fetch_candidate_issues(config)
    end

    test "matches active_states case-insensitively", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "TODO"))
      Memory.put_issue(issue("b", "MT-2", "in progress"))

      assert {:ok, issues} = Tracker.fetch_candidate_issues(config)
      assert length(issues) == 2
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns issues matching given states", %{config: config} do
      Memory.put_issues([
        issue("a", "MT-1", "Done"),
        issue("b", "MT-2", "Cancelled"),
        issue("c", "MT-3", "Todo")
      ])

      assert {:ok, issues} = Tracker.fetch_issues_by_states(config, ["Done", "Cancelled"])
      assert Enum.map(issues, & &1.identifier) |> Enum.sort() == ["MT-1", "MT-2"]
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns refreshed issues for given IDs only", %{config: config} do
      Memory.put_issues([
        issue("a", "MT-1", "Todo"),
        issue("b", "MT-2", "In Progress"),
        issue("c", "MT-3", "Done")
      ])

      assert {:ok, issues} = Tracker.fetch_issue_states_by_ids(config, ["a", "c"])
      assert Enum.map(issues, & &1.id) == ["a", "c"]
      assert Enum.map(issues, & &1.state) == ["Todo", "Done"]
    end

    test "skips missing IDs without erroring", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))

      assert {:ok, [%Issue{id: "a"}]} =
               Tracker.fetch_issue_states_by_ids(config, ["a", "missing"])
    end

    test "transition/3 updates state seen by subsequent fetches", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Memory.transition("a", "In Progress")

      assert {:ok, [%Issue{state: "In Progress"}]} =
               Tracker.fetch_issue_states_by_ids(config, ["a"])
    end

    test "remove_issue/1 drops the issue", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Memory.remove_issue("a")
      assert {:ok, []} = Tracker.fetch_issue_states_by_ids(config, ["a"])
    end
  end

  describe "Tracker dispatcher" do
    test "returns error for unsupported tracker kind" do
      config =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "jira"}},
          prompt_template: ""
        })

      assert {:error, {:unsupported_tracker_kind, "jira"}} =
               Tracker.fetch_candidate_issues(config)
    end

    test "dispatches to Linear adapter when kind is \"linear\"" do
      config =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "linear", api_key: nil, project_slug: "demo"}},
          prompt_template: ""
        })

      # Real adapter surfaces its own validation error rather than :not_implemented.
      assert {:error, :missing_tracker_api_key} = Tracker.fetch_candidate_issues(config)
    end

    test "dispatches to GitHub adapter when kind is \"github\"" do
      config =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "github", api_key: nil}},
          prompt_template: ""
        })

      assert {:error, :missing_tracker_api_key} = Tracker.fetch_candidate_issues(config)
    end
  end
end
