defmodule Raxol.Symphony.Runners.RaxolAgentSessionPromptCacheTest do
  @moduledoc """
  Verifies the `agent.prompt_cache` opt-in on the session runner.

  The rendered seed prompt is cached across fresh runs under the stable
  per-issue key `{:prompt, issue.id}`, with the stored value
  `{sha256({issue, template, attempt}), rendered}`. The fingerprint (not
  the key) guards freshness: a mismatch is a miss + overwrite, so a stale
  render is never served and an issue holds at most one row.

  Bounding comes from three mechanisms, each exercised below:

    * overwrite on a freshness miss (the initial `attempt: nil` row is
      reclaimed by its `attempt: 1` continuation),
    * read-once delete on an exact hit (a continued issue oscillates
      between one and zero rows), and
    * `flush_prompt_cache/2`, which the orchestrator calls when an issue
      leaves the run set, reclaiming the one row a one-shot issue leaves.

  Defaults: `prompt_cache` is `nil` (no caching); `prompt_cache_ttl_ms`
  defaults to 300_000 (5 min).
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgentSession

  alias Raxol.Symphony.TestSupport.{
    SessionAgentEcho,
    SessionAgentSucceed
  }

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
  defp config(agent_overrides, module \\ SessionAgentSucceed) do
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
          agent: Map.merge(%{module: module}, agent_overrides)
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

  defp entries(adapter), do: :ets.tab2list(table_of(adapter))

  describe "prompt_cache: nil (default)" do
    test "no cache is consulted; the run still completes" do
      assert :ok = run(config(%{}))
    end
  end

  describe "prompt_cache: {Ets, ...}" do
    test "a fresh run populates the cache with a fingerprinted rendered prompt" do
      adapter = ets_cache_adapter()

      assert :ok = run(config(%{prompt_cache: adapter}))

      # Exactly one entry: value is `{fingerprint, rendered}` and renders the
      # template ("MT-1"). Key is the stable per-issue slot.
      assert [{{:prompt, "issue-1"}, {fp, "MT-1"}, _expiry}] = entries(adapter)
      assert is_binary(fp)
    end

    test "a continuation of an unchanged issue hits the cache and serves the render" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter, prompt_cache_ttl_ms: 60_000}, SessionAgentEcho)

      # First dispatch: miss -> render "MT-1" -> stored under fingerprint `fp`.
      assert :ok = run(cfg, 1)
      assert_receive {:run_event, "issue-1", %{event: :turn_complete, prompt: "MT-1"}}
      [{key, {fp, "MT-1"}, _}] = entries(adapter)

      # Poison the row's value under the SAME fingerprint. A HIT serves this
      # sentinel (the agent echoes it back) and deletes it (read-once); a MISS
      # would re-render "MT-1" and overwrite, so the sentinel would never show.
      :ok = Raxol.Agent.Cache.put(adapter, key, {fp, "SENTINEL-PROMPT"}, 60_000)

      assert :ok = run(cfg, 1)

      assert_receive {:run_event, "issue-1", %{event: :turn_complete, prompt: "SENTINEL-PROMPT"}}

      # Read-once flushed the row on the hit.
      assert :miss = Raxol.Agent.Cache.get(adapter, key)
      assert entries(adapter) == []
    end

    test "the initial attempt: nil row is reclaimed by its attempt: 1 continuation" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})

      # Initial dispatch writes the `attempt: nil` render.
      assert :ok = run(cfg, nil)
      assert [{{:prompt, "issue-1"}, {fp_nil, "MT-1"}, _}] = entries(adapter)

      # The first continuation renders at `attempt: 1`. A distinct fingerprint
      # (attempt feeds the render) makes it a miss, so it overwrites the SAME
      # per-issue key instead of orphaning a second row. Old design (attempt in
      # the key) left the nil row behind -> a permanent per-issue leak.
      assert :ok = run(cfg, 1)
      assert [{{:prompt, "issue-1"}, {fp_one, "MT-1"}, _}] = entries(adapter)

      assert :ets.info(table_of(adapter), :size) == 1
      refute fp_one == fp_nil
    end

    test "a differing attempt is a freshness miss, not a stale hit" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter}, SessionAgentEcho)

      assert :ok = run(cfg, 1)
      [{key, {fp1, "MT-1"}, _}] = entries(adapter)

      # Poison attempt-1's row (keeping its fingerprint). A run at attempt 2 has
      # a different fingerprint, so it must NOT serve the sentinel -- it
      # re-renders "MT-1" and overwrites.
      :ok = Raxol.Agent.Cache.put(adapter, key, {fp1, "STALE"}, 60_000)

      assert :ok = run(cfg, 2)

      assert_receive {:run_event, "issue-1", %{event: :turn_complete, prompt: "MT-1"}}
      refute_received {:run_event, "issue-1", %{event: :turn_complete, prompt: "STALE"}}
      assert :ets.info(table_of(adapter), :size) == 1
    end

    test "a differing issue field is a freshness miss, not a stale hit" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})

      # Both render "MT-1" (template is {{ issue.identifier }}) and share
      # issue.id, but differ in `description`, which the fingerprint covers.
      # The second run is a freshness miss that overwrites -- one row, never
      # a stale serve -- proving the fingerprint tracks all determinants.
      assert :ok =
               RaxolAgentSession.run(%{issue() | description: "A"}, cfg, parent: self())

      assert [{_key, {fp_a, "MT-1"}, _}] = entries(adapter)

      assert :ok =
               RaxolAgentSession.run(%{issue() | description: "B"}, cfg, parent: self())

      assert [{_key, {fp_b, "MT-1"}, _}] = entries(adapter)
      assert :ets.info(table_of(adapter), :size) == 1
      refute fp_b == fp_a
    end

    test "flush_prompt_cache/2 reclaims a one-shot issue's row" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})

      # A one-shot: written once, never read by a continuation.
      assert :ok = run(cfg, nil)
      assert :ets.info(table_of(adapter), :size) == 1

      # The terminal flush (what the orchestrator calls) reclaims it.
      assert :ok = RaxolAgentSession.flush_prompt_cache(cfg, "issue-1")
      assert :ets.info(table_of(adapter), :size) == 0
    end

    test "processing many one-shot issues stays bounded with terminal flush" do
      adapter = ets_cache_adapter()
      cfg = config(%{prompt_cache: adapter})
      table = table_of(adapter)

      # 50 distinct one-shot issues. Each writes one row on its only dispatch;
      # the terminal flush (orchestrator's `release_issue`) reclaims it. The
      # live count is O(in-flight) = 1, never O(issues processed).
      for n <- 1..50 do
        id = "one-shot-#{n}"
        iss = %Issue{id: id, identifier: id, title: "T", state: "Todo"}

        assert :ok = RaxolAgentSession.run(iss, cfg, parent: self(), attempt: nil)
        assert :ets.info(table, :size) == 1

        assert :ok = RaxolAgentSession.flush_prompt_cache(cfg, id)
        assert :ets.info(table, :size) == 0
      end

      assert :ets.info(table, :size) == 0
    end

    test "flush_prompt_cache/2 is a no-op when no prompt_cache is configured" do
      assert :ok = RaxolAgentSession.flush_prompt_cache(config(%{}), "issue-1")
    end

    test "default TTL is 300s when prompt_cache_ttl_ms is unset" do
      adapter = ets_cache_adapter()

      assert :ok = run(config(%{prompt_cache: adapter}))

      assert [{_key, {_fp, "MT-1"}, %DateTime{} = expiry}] = entries(adapter)

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
