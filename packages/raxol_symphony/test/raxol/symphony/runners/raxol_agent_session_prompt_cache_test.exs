defmodule Raxol.Symphony.Runners.RaxolAgentSessionPromptCacheTest do
  @moduledoc """
  Verifies the `agent.prompt_cache` opt-in on the session runner: the
  rendered seed prompt is cached across fresh runs under a self-invalidating
  content-hash key `{:prompt, sha256({issue, template, attempt})}`.

  Strategy mirrors the `tracker_cache` test: configure an ETS-backed cache,
  drive a real run, then read the ETS table directly. Cache HIT is proven
  decisively by poisoning the populated key with a sentinel and showing a
  second identical run leaves it untouched (a miss would re-render + overwrite).

  Defaults: `prompt_cache` is `nil` (no caching); `prompt_cache_ttl_ms`
  defaults to 300_000 (5 min).
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgentSession
  alias Raxol.Symphony.TestSupport.SessionAgentSucceed

  setup do
    case Process.whereis(Raxol.Agent.Registry) do
      nil -> start_supervised!(Raxol.Agent.Supervisor)
      _pid -> :ok
    end

    :ok
  end

  defp ets_cache_adapter do
    table =
      :"sym_session_prompt_cache_test_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {Raxol.Agent.Cache.Ets, %{table: table}}
  end

  # `prompt_template` renders to the issue identifier ("MT-1"), so the cached
  # prompt value is a known string.
  defp config(agent_overrides) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        agent: %{max_turns: 1},
        runner: %{
          kind: "raxol_agent_session",
          agent: Map.merge(%{module: SessionAgentSucceed}, agent_overrides)
        }
      },
      prompt_template: "{{ issue.identifier }}"
    })
  end

  defp issue,
    do: %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}

  defp run(cfg, attempt \\ nil) do
    RaxolAgentSession.run(issue(), cfg, parent: self(), attempt: attempt)
  end

  defp table_of({_module, %{table: table}}), do: table

  describe "prompt_cache: nil (default)" do
    test "no cache is consulted; the run still completes" do
      assert :ok = run(config(%{}))
    end
  end

  describe "prompt_cache: {Ets, ...}" do
    test "a fresh run populates the cache with the rendered prompt" do
      adapter = ets_cache_adapter()

      assert :ok = run(config(%{prompt_cache: adapter}))

      # Exactly one entry, holding the rendered template ("MT-1").
      assert [{_key, "MT-1", _expiry}] = :ets.tab2list(table_of(adapter))
    end

    test "a second identical run hits the cache instead of re-rendering" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter, prompt_cache_ttl_ms: 60_000})

      assert :ok = run(cfg)
      [{key, "MT-1", _}] = :ets.tab2list(table_of(adapter))

      # Poison the populated key. A HIT returns this without re-rendering and
      # never writes; a MISS would recompute "MT-1" and overwrite the sentinel.
      :ok = Raxol.Agent.Cache.put(adapter, key, "SENTINEL-PROMPT", 60_000)

      assert :ok = run(cfg)

      assert {:ok, "SENTINEL-PROMPT"} = Raxol.Agent.Cache.get(adapter, key)
      assert length(:ets.tab2list(table_of(adapter))) == 1
    end

    test "a different attempt is a distinct key (attempt is in the fingerprint)" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})

      assert :ok = run(cfg, 1)
      assert :ok = run(cfg, 2)

      assert length(:ets.tab2list(table_of(adapter))) == 2
    end

    test "the whole issue is fingerprinted: same render, differing field -> distinct keys" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})

      # Both render to "MT-1" (template is {{ issue.identifier }}) but differ
      # in `description`, which the template never renders. The key is the
      # full %Issue{}, so they must NOT collide -- proving the key tracks all
      # determinants, not just the rendered output, and can never drift from
      # a hand-listed field subset.
      assert :ok =
               RaxolAgentSession.run(%{issue() | description: "A"}, cfg,
                 parent: self()
               )

      assert :ok =
               RaxolAgentSession.run(%{issue() | description: "B"}, cfg,
                 parent: self()
               )

      entries = :ets.tab2list(table_of(adapter))
      assert length(entries) == 2
      assert Enum.all?(entries, fn {_k, rendered, _e} -> rendered == "MT-1" end)
    end

    test "default TTL is 300s when prompt_cache_ttl_ms is unset" do
      adapter = ets_cache_adapter()

      assert :ok = run(config(%{prompt_cache: adapter}))

      assert [{_key, "MT-1", %DateTime{} = expiry}] =
               :ets.tab2list(table_of(adapter))

      # Well beyond a 30s window -> the 300s default, not some shorter TTL.
      assert DateTime.diff(expiry, DateTime.utc_now()) > 60
    end

    test "bare-module form is accepted via Cache.normalize/1" do
      # A bare module normalizes to `{module, %{}}` (default table). We only
      # assert the run completes -- normalize/1 itself is covered elsewhere.
      assert :ok = run(config(%{prompt_cache: Raxol.Agent.Cache.Ets}))
    end
  end
end
