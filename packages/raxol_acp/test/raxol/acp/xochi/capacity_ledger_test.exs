defmodule Raxol.ACP.Xochi.CapacityLedgerTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.CapacityLedger

  @dest {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85"}

  defp ledger(opts \\ []) do
    start_supervised!({CapacityLedger, [name: nil] ++ opts})
  end

  describe "reserve/confirm/release" do
    test "reserves up to capacity, then rejects the overflow" do
      l = ledger(capacity: %{@dest => 220})

      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 60_000)
      assert :ok = CapacityLedger.reserve(l, :j2, @dest, 100, 60_000)
      assert CapacityLedger.available(l, @dest) == 20
      assert {:error, :over_capacity} = CapacityLedger.reserve(l, :j3, @dest, 100, 60_000)
    end

    test "a released reservation frees its capacity; a confirmed one keeps it" do
      l = ledger(capacity: %{@dest => 100})

      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 60_000)
      assert {:error, :over_capacity} = CapacityLedger.reserve(l, :j2, @dest, 1, 60_000)

      :ok = CapacityLedger.release(l, :j1)
      assert CapacityLedger.available(l, @dest) == 100

      assert :ok = CapacityLedger.reserve(l, :j3, @dest, 100, 60_000)
      :ok = CapacityLedger.confirm(l, :j3)
      # Confirmed stays counted -- a re-derivation resets it, not a settle.
      assert {:error, :over_capacity} = CapacityLedger.reserve(l, :j4, @dest, 1, 60_000)
    end

    test "reserving is idempotent per job id" do
      l = ledger(capacity: %{@dest => 100})
      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 60_000)
      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 60_000)
      assert CapacityLedger.available(l, @dest) == 0
    end

    test "a destination with no configured capacity is unbounded" do
      l = ledger(capacity: %{})
      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 1_000_000_000, 60_000)
      assert CapacityLedger.available(l, @dest) == :infinity
    end
  end

  describe "TTL sweep" do
    test "an in-flight reservation that never settles is swept after its TTL" do
      # Deterministic clock: reserve at t=0 with a 1000ms TTL, then advance past it.
      clock = :counters.new(1, [])
      now_fn = fn -> :counters.get(clock, 1) end
      l = ledger(capacity: %{@dest => 100}, now_fn: now_fn)

      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 1_000)
      assert {:error, :over_capacity} = CapacityLedger.reserve(l, :j2, @dest, 1, 1_000)

      :counters.add(clock, 1, 2_000)
      # j1's TTL has lapsed and it never settled -> swept, capacity freed.
      assert :ok = CapacityLedger.reserve(l, :j2, @dest, 100, 1_000)
    end

    test "a confirmed reservation is never swept" do
      clock = :counters.new(1, [])
      now_fn = fn -> :counters.get(clock, 1) end
      l = ledger(capacity: %{@dest => 100}, now_fn: now_fn)

      assert :ok = CapacityLedger.reserve(l, :j1, @dest, 100, 1_000)
      :ok = CapacityLedger.confirm(l, :j1)

      :counters.add(clock, 1, 10_000)
      assert {:error, :over_capacity} = CapacityLedger.reserve(l, :j2, @dest, 1, 1_000)
    end
  end
end
