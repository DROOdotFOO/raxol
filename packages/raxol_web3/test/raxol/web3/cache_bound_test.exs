defmodule Raxol.Web3.CacheBoundTest do
  # `async: false`, and both halves of that are load-bearing. The ceilings are
  # application env, so lowering them for a test would lower them for a
  # sibling running at the same time; and asserting on the table's size means
  # nothing while another test is writing to it. ExUnit runs every async
  # module before any sync one, so a flush here cannot clear a live sibling's
  # entries either.
  use ExUnit.Case, async: false

  alias Raxol.Web3.Cache
  alias Raxol.Web3.Tables

  @cap 16

  setup do
    previous = [
      cache_max_entries: Application.get_env(:raxol_web3, :cache_max_entries),
      cache_max_value_bytes: Application.get_env(:raxol_web3, :cache_max_value_bytes)
    ]

    Application.put_env(:raxol_web3, :cache_max_entries, @cap)
    Cache.flush()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:raxol_web3, key)
        {key, value} -> Application.put_env(:raxol_web3, key, value)
      end)

      Cache.flush()
    end)

    :ok
  end

  defp key(name), do: {__MODULE__, name}

  defp size, do: :ets.info(Tables.cache(), :size)

  describe "the entry ceiling" do
    test "putting past the cap evicts rather than growing the table" do
      Enum.each(1..64, &Cache.put(key({:fill, &1}), :v, 600_000 + &1))

      assert size() <= @cap
    end

    test "eviction takes the soonest expiry and keeps the furthest" do
      soonest = key(:soonest)
      furthest = key(:furthest)

      Cache.put(soonest, :v, 100_000)
      Cache.put(furthest, :v, 600_000)
      Enum.each(1..20, &Cache.put(key({:fill, &1}), :v, 300_000 + &1))

      assert :miss = Cache.get(soonest)
      assert {:ok, :v} = Cache.get(furthest)
    end

    test "refreshing a key already at the cap evicts nothing" do
      hot = key(:hot)

      Cache.put(hot, :first, 600_000)
      Enum.each(2..@cap, &Cache.put(key({:fill, &1}), :v, 600_000))
      assert size() == @cap

      Enum.each(1..5, fn _ -> Cache.put(hot, :refreshed, 600_000) end)

      assert size() == @cap
      assert {:ok, :refreshed} = Cache.get(hot)
    end
  end

  describe "reclaiming expired entries" do
    test "an expired entry is reclaimed without ever being read" do
      # Written straight into the table with an expiry already in the past,
      # rather than put with a short TTL and slept on: the point is an entry
      # nobody reads, and a sleep would only make the test slower and racier.
      past = System.monotonic_time(:millisecond) - 1
      stale = Enum.map(1..10, &key({:stale, &1}))
      Enum.each(stale, &:ets.insert(Tables.cache(), {&1, :v, past}))

      Enum.each(1..8, &Cache.put(key({:live, &1}), :v, 600_000))

      assert Enum.all?(stale, &(:ets.lookup(Tables.cache(), &1) == []))
      assert size() == 8
    end
  end

  describe "the per-value ceiling" do
    test "a value over the ceiling is declined, not stored" do
      Application.put_env(:raxol_web3, :cache_max_value_bytes, 1_024)
      k = key(:oversized)

      assert :ok = Cache.put(k, %{status: 200, body: :binary.copy("x", 4_096)}, 600_000)
      assert :miss = Cache.get(k)
      assert [] = :ets.lookup(Tables.cache(), k)
    end

    test "a value under the ceiling is stored as before" do
      Application.put_env(:raxol_web3, :cache_max_value_bytes, 1_024)
      k = key(:small)

      assert :ok = Cache.put(k, %{status: 200, body: :binary.copy("x", 64)}, 600_000)
      assert {:ok, %{status: 200}} = Cache.get(k)
    end
  end
end
