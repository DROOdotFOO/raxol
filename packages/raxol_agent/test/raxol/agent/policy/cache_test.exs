defmodule Raxol.Agent.Policy.CacheTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Policy.Cache

  describe "ets/1" do
    test "builds with required + default config" do
      key_fn = & &1.id

      policy = Cache.ets(ttl_ms: 60_000, key_fn: key_fn)

      assert {Raxol.Agent.Cache.Ets, %{}} = policy.storage
      assert policy.ttl_ms == 60_000
      assert policy.key_fn == key_fn
    end

    test "respects :table override" do
      policy = Cache.ets(ttl_ms: 60_000, key_fn: & &1, table: :custom)
      assert {Raxol.Agent.Cache.Ets, %{table: :custom}} = policy.storage
    end

    test "raises on negative ttl_ms" do
      assert_raise ArgumentError, ~r/ttl_ms/, fn ->
        Cache.ets(ttl_ms: -1, key_fn: & &1)
      end
    end

    test "raises on non-function key_fn" do
      assert_raise ArgumentError, ~r/key_fn/, fn ->
        Cache.ets(ttl_ms: 60_000, key_fn: :not_a_function)
      end
    end
  end

  describe "postgrex/1" do
    test "builds with conn + optional table" do
      policy =
        Cache.postgrex(
          ttl_ms: 300_000,
          key_fn: & &1.id,
          conn: MyApp.Postgrex
        )

      assert {Raxol.Agent.Cache.Postgrex, %{conn: MyApp.Postgrex}} =
               policy.storage

      assert policy.ttl_ms == 300_000
    end

    test "honors :table when supplied" do
      policy =
        Cache.postgrex(
          ttl_ms: 300_000,
          key_fn: & &1.id,
          conn: MyApp.Postgrex,
          table: "agent_cache"
        )

      assert {Raxol.Agent.Cache.Postgrex, %{conn: MyApp.Postgrex, table: "agent_cache"}} =
               policy.storage
    end

    test "raises without :conn" do
      assert_raise KeyError, fn ->
        Cache.postgrex(ttl_ms: 60_000, key_fn: & &1)
      end
    end
  end
end
