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
end
