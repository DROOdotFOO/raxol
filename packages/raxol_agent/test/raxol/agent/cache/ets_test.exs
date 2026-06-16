defmodule Raxol.Agent.Cache.EtsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Cache.Ets

  setup do
    table = :"cache_ets_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, config: %{table: table}}
  end

  describe "put + get" do
    test "writes a value and reads it back", %{config: config} do
      assert :ok = Ets.put(config, :alpha, %{n: 1}, 60_000)
      assert {:ok, %{n: 1}} = Ets.get(config, :alpha)
    end

    test "ttl_ms = 0 stores with no expiry", %{config: config} do
      :ok = Ets.put(config, :forever, :v, 0)
      assert {:ok, :v} = Ets.get(config, :forever)
    end

    test "last-write-wins on the same key", %{config: config} do
      :ok = Ets.put(config, :k, :v1, 60_000)
      :ok = Ets.put(config, :k, :v2, 60_000)

      assert {:ok, :v2} = Ets.get(config, :k)
    end

    test "miss for unknown key", %{config: config} do
      assert :miss = Ets.get(config, :nope)
    end
  end

  describe "TTL expiry" do
    test "expired entry returns :miss and is removed on read", %{
      config: config
    } do
      :ok = Ets.put(config, :short, :v, 1)
      Process.sleep(10)
      assert :miss = Ets.get(config, :short)

      # The lookup deleted the expired entry; a second get is still :miss.
      assert :miss = Ets.get(config, :short)
    end

    test "fresh entry survives across get", %{config: config} do
      :ok = Ets.put(config, :longer, :v, 60_000)
      assert {:ok, :v} = Ets.get(config, :longer)
      # ETS table still has it
      assert :ok = Ets.put(config, :longer, :v2, 60_000)
      assert {:ok, :v2} = Ets.get(config, :longer)
    end
  end

  describe "delete + flush" do
    test "delete removes a single key", %{config: config} do
      :ok = Ets.put(config, :doomed, :v, 60_000)
      :ok = Ets.delete(config, :doomed)
      assert :miss = Ets.get(config, :doomed)
    end

    test "delete is idempotent for unknown key", %{config: config} do
      assert :ok = Ets.delete(config, :ghost)
    end

    test "flush removes everything", %{config: config} do
      :ok = Ets.put(config, :a, 1, 60_000)
      :ok = Ets.put(config, :b, 2, 60_000)

      :ok = Ets.flush(config)

      assert :miss = Ets.get(config, :a)
      assert :miss = Ets.get(config, :b)
    end
  end

  describe "table isolation" do
    test "two configs with distinct tables don't see each other's entries" do
      a = %{table: :"cache_iso_a_#{System.unique_integer([:positive])}"}
      b = %{table: :"cache_iso_b_#{System.unique_integer([:positive])}"}

      on_exit(fn ->
        if :ets.whereis(a.table) != :undefined, do: :ets.delete(a.table)
        if :ets.whereis(b.table) != :undefined, do: :ets.delete(b.table)
      end)

      :ok = Ets.put(a, :shared, :value_a, 60_000)
      :ok = Ets.put(b, :shared, :value_b, 60_000)

      assert {:ok, :value_a} = Ets.get(a, :shared)
      assert {:ok, :value_b} = Ets.get(b, :shared)
    end
  end

  describe "complex term keys + values" do
    test "supports tuple keys + map values + list values", %{config: config} do
      :ok = Ets.put(config, {:user, 42}, %{name: "Alice"}, 60_000)
      :ok = Ets.put(config, ["nested", :list], [:a, :b, :c], 60_000)

      assert {:ok, %{name: "Alice"}} = Ets.get(config, {:user, 42})
      assert {:ok, [:a, :b, :c]} = Ets.get(config, ["nested", :list])
    end
  end
end
