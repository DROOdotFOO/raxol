defmodule Raxol.Agent.CacheTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Cache

  describe "normalize/1" do
    test "nil pass-through" do
      assert Cache.normalize(nil) == nil
    end

    test "{module, config} tuple is preserved" do
      assert Cache.normalize({Cache.Ets, %{table: :t}}) ==
               {Cache.Ets, %{table: :t}}
    end

    test "bare module becomes {module, %{}}" do
      assert Cache.normalize(Cache.Ets) == {Cache.Ets, %{}}
    end
  end

  describe "dispatcher get/2 with nil adapter" do
    test "returns :miss without invoking anything" do
      assert Cache.get(nil, :any_key) == :miss
    end
  end

  describe "dispatcher put/4 with nil adapter" do
    test "is a no-op returning :ok" do
      assert Cache.put(nil, :k, :v, 1_000) == :ok
    end

    test "still validates ttl_ms when adapter is nil" do
      assert Cache.put(nil, :k, :v, 0) == :ok
    end
  end

  describe "dispatcher ttl validation" do
    test "negative ttl_ms raises ArgumentError" do
      assert_raise ArgumentError, ~r/non-negative/, fn ->
        Cache.put({Cache.Ets, %{table: ttl_table()}}, :k, :v, -1)
      end
    end
  end

  describe "delete/2 and flush/1 with nil adapter" do
    test "both no-op" do
      assert Cache.delete(nil, :k) == :ok
      assert Cache.flush(nil) == :ok
    end
  end

  defp ttl_table do
    :"cache_ttl_validation_#{System.unique_integer([:positive])}"
  end
end
