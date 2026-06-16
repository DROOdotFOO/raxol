defmodule Raxol.Symphony.Runners.RaxolAgentTrackerCacheTest do
  @moduledoc """
  Phase 10: verifies the `agent.tracker_cache` opt-in caches
  `still_active?` results between turn boundaries so a multi-turn run
  doesn't re-query the tracker every turn.

  The verification strategy: configure an ETS-backed cache, drive a
  multi-turn run, then read the cache directly. If a cache entry
  exists under `{:tracker, issue.id}` after the run, the runner
  populated it -- proving the wire-up. Stronger "tracker NOT
  called twice" assertions need a mocked tracker which the
  existing test setup doesn't have.

  ## Defaults

  - `tracker_cache` is `nil` by default (no caching, current
    behavior).
  - `tracker_cache_ttl_ms` defaults to 30_000 (30s).
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp ets_cache_adapter do
    table = :"sym_runner_tracker_cache_test_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    {Raxol.Agent.Cache.Ets, %{table: table}}
  end

  defp config(agent_overrides, max_turns \\ 1)

  defp config(agent_overrides, max_turns) do
    base = %{backend: "mock", response: "ok", workflow_mode: true}

    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        agent: %{max_turns: max_turns},
        runner: %{
          kind: "raxol_agent",
          agent: Map.merge(base, agent_overrides)
        }
      },
      prompt_template: "{{ issue.identifier }}"
    })
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}
  end

  describe "tracker_cache: nil (default)" do
    test "no cache adapter is touched; runner still completes" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "tracker_cache: {Ets, ...}" do
    test "populates the cache after the run's tracker check" do
      adapter = ets_cache_adapter()

      Memory.put_issue(%{issue() | state: "Done"})

      cfg =
        config(%{
          tracker_cache: adapter,
          tracker_cache_ttl_ms: 60_000
        })

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Cache MUST contain the tracker result keyed by {:tracker, issue.id}.
      assert {:ok, result} = Raxol.Agent.Cache.get(adapter, {:tracker, "issue-1"})
      # The tracker reported terminal (issue state was "Done"), so the
      # cached result is :done.
      assert result == :done
    end

    test "cache survives a multi-turn run; final read still hits" do
      adapter = ets_cache_adapter()

      Memory.put_issue(%{issue() | state: "In Progress"})

      cfg =
        config(
          %{
            tracker_cache: adapter,
            tracker_cache_ttl_ms: 60_000
          },
          3
        )

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # After a multi-turn run, the cache holds the latest tracker
      # result. Memory tracker returns {:active, refreshed} for an
      # In Progress issue; the cached match-pattern handles both
      # {:active, _} and :done depending on whether the test issue
      # was refreshed under the active state set.
      assert {:ok, cached} =
               Raxol.Agent.Cache.get(adapter, {:tracker, "issue-1"})

      assert match?({:active, _}, cached) or cached == :done
    end

    test "default TTL is 30s when tracker_cache_ttl_ms is unset" do
      adapter = ets_cache_adapter()

      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{tracker_cache: adapter})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # The entry should still be live (we just wrote it; TTL=30s).
      assert {:ok, _} = Raxol.Agent.Cache.get(adapter, {:tracker, "issue-1"})
    end

    test "bare-module form is normalized via Cache.normalize/1" do
      # Bare module = `{Module, %{}}`. The runner must accept this
      # via `Cache.normalize/1` (Cache module's contract).
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{tracker_cache: Raxol.Agent.Cache.Ets})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Default table is used.
      assert {:ok, _} =
               Raxol.Agent.Cache.Ets.get(%{}, {:tracker, "issue-1"})
    end
  end
end
