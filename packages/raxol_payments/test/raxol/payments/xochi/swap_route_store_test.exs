defmodule Raxol.Payments.Xochi.SwapRouteStoreTest do
  # async: false -- exercises the named singleton and its ETS table.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Xochi.SwapRouteStore

  test "self-starts once and registers under the module name" do
    SwapRouteStore.remember("intent_reg", %{from_chain_id: 8453})
    assert is_pid(Process.whereis(SwapRouteStore))
  end

  test "repeated remember does not spawn a second owner or crash" do
    SwapRouteStore.remember("intent_a", %{a: 1})
    pid = Process.whereis(SwapRouteStore)

    # A second remember must reuse the singleton, not start (and crash) a new
    # GenServer on the duplicate named table.
    SwapRouteStore.remember("intent_b", %{b: 2})
    assert Process.whereis(SwapRouteStore) == pid
    assert Process.alive?(pid)
  end

  test "take reads then deletes the route" do
    SwapRouteStore.remember("intent_take", %{from_token: "0xUSDC"})
    assert {:ok, %{from_token: "0xUSDC"}} = SwapRouteStore.take("intent_take")
    assert :error == SwapRouteStore.take("intent_take")
  end

  test "take on an unknown intent is a miss, not a crash" do
    assert :error == SwapRouteStore.take("intent_never_seen")
  end

  test "an expired entry is not returned" do
    # ttl_ms: -1 -> expiry is strictly before now, so any later take is past it
    # (monotonic time has millisecond granularity, so ttl_ms: 0 could tie).
    SwapRouteStore.remember("intent_ttl", %{x: 1}, ttl_ms: -1)
    assert :error == SwapRouteStore.take("intent_ttl")
  end

  test "two executes in one spawned agent process settle cleanly" do
    # Pins the singleton-registration fix: the original crash only reproduced
    # from a spawned process running two swaps back to back (whereis -> nil ->
    # re-start_link -> :ets.new on the existing named table raises in init and
    # the linked crash killed the caller after funds moved). This must stay a
    # no-op-safe stash.
    parent = self()

    spawn(fn ->
      SwapRouteStore.remember("spawn_1", %{leg: 1})
      SwapRouteStore.remember("spawn_2", %{leg: 2})
      send(parent, :done)
    end)

    assert_receive :done, 1000
    assert {:ok, %{leg: 1}} = SwapRouteStore.take("spawn_1")
    assert {:ok, %{leg: 2}} = SwapRouteStore.take("spawn_2")
    assert Process.alive?(Process.whereis(SwapRouteStore))
  end

  test "reinserting the same intent id updates rather than duplicates" do
    SwapRouteStore.remember("intent_update", %{v: 1})
    SwapRouteStore.remember("intent_update", %{v: 2})
    assert {:ok, %{v: 2}} = SwapRouteStore.take("intent_update")
    assert :error == SwapRouteStore.take("intent_update")
  end
end
