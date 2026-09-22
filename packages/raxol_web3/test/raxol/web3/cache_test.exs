defmodule Raxol.Web3.CacheTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Cache
  alias Raxol.Web3.TTL

  # One table, one node, so every test keys on something unique rather than
  # flushing: a flush in an async suite clears a sibling's entries.
  defp key(name), do: {__MODULE__, name, System.unique_integer([:positive])}

  describe "get and put" do
    test "a fresh entry comes back" do
      k = key(:fresh)

      assert :miss = Cache.get(k)
      assert :ok = Cache.put(k, %{status: 200, body: "{}"}, 60_000)
      assert {:ok, %{status: 200, body: "{}"}} = Cache.get(k)
    end

    test "a TTL of zero means no expiry, not expired already" do
      k = key(:forever)

      assert :ok = Cache.put(k, :kept, 0)
      assert {:ok, :kept} = Cache.get(k)
    end

    test "a negative TTL raises rather than being clamped" do
      # A caller's arithmetic mistake. Treating it as "already expired" or as
      # "never" would hide the bug behind a cache that merely looks cold.
      assert_raise ArgumentError, fn -> Cache.put(key(:negative), :x, -1) end
    end

    test "the last write wins" do
      k = key(:overwrite)

      Cache.put(k, :first, 60_000)
      Cache.put(k, :second, 60_000)

      assert {:ok, :second} = Cache.get(k)
    end
  end

  describe "expiry" do
    test "an expired entry is a miss, and is gone from the table" do
      # Lazy expiry: the read is what collects it. Asserted on the table
      # directly, because "returns :miss" alone would also hold for an entry
      # that stayed and was filtered on every read.
      k = key(:expired)

      Cache.put(k, :stale, 1)
      Process.sleep(5)

      assert :miss = Cache.get(k)
      assert [] = :ets.lookup(Raxol.Web3.Tables.cache(), k)
    end

    test "an entry with time left is not collected" do
      k = key(:not_yet)

      Cache.put(k, :fresh, 60_000)

      assert {:ok, :fresh} = Cache.get(k)
      assert [{^k, :fresh, _expiry}] = :ets.lookup(Raxol.Web3.Tables.cache(), k)
    end
  end

  describe "delete and flush" do
    test "delete forgets one key" do
      k = key(:deleted)

      Cache.put(k, :x, 60_000)
      assert :ok = Cache.delete(k)
      assert :miss = Cache.get(k)
    end

    test "delete of an absent key is not an error" do
      assert :ok = Cache.delete(key(:never_there))
    end
  end

  describe "TTL classes" do
    test "a height has no TTL, and asking for one raises" do
      # The one rule here that is about correctness. A cached height read
      # alongside a live finalized height produces finalized > height, which is
      # the invariant the height shape exists to express.
      assert_raise ArgumentError, ~r/height is never cached/, fn -> TTL.for(:height) end
    end

    test "an unknown class raises rather than defaulting" do
      # Answered with 0 it would mean "never expire", the worst available
      # default for a typo.
      assert_raise ArgumentError, ~r/unknown cache class/, fn -> TTL.for(:chian_stats) end
    end

    test "every class is a positive number of milliseconds" do
      for {class, ttl} <- TTL.all() do
        assert is_integer(ttl) and ttl > 0, "#{class} has no usable TTL"
        assert TTL.for(class) == ttl
      end
    end

    test "a transaction is cached far more briefly than a contract's ABI" do
      # The comparison is the point of keeping these in one table. A
      # transaction's finality is unknown at request time, so it gets seconds;
      # a verified ABI does not change, so it gets an hour.
      assert TTL.for(:transaction) < TTL.for(:chain_stats)
      assert TTL.for(:chain_stats) < TTL.for(:contract_metadata)
    end
  end
end
