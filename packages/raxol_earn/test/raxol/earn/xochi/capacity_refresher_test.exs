defmodule Raxol.Earn.Xochi.CapacityRefresherTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Xochi.{CapacityLedger, CapacityRefresher}

  @dest {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85"}

  defp ledger, do: start_supervised!({CapacityLedger, [name: nil, capacity: %{}]})

  defp refresher(ledger, opts) do
    start_supervised!({CapacityRefresher, [name: nil, ledger: ledger] ++ opts})
  end

  test "a refresh loads the derived capacity into the ledger" do
    l = ledger()
    r = refresher(l, derive_fn: fn -> %{@dest => 500} end, refresh_on_start: false)

    assert :ok = CapacityRefresher.refresh(r)
    assert CapacityLedger.available(l, @dest) == 500
  end

  test "refresh_on_start derives without an explicit call" do
    l = ledger()
    parent = self()

    derive_fn = fn ->
      send(parent, :derived)
      %{@dest => 700}
    end

    refresher(l, derive_fn: derive_fn, refresh_on_start: true, interval_ms: 60_000)

    assert_receive :derived, 1_000
  end

  test "a raising derive leaves the ledger untouched" do
    l = ledger()
    r = refresher(l, derive_fn: fn -> raise "boom" end, refresh_on_start: false)

    assert {:error, :refresh_failed} = CapacityRefresher.refresh(r)
    assert CapacityLedger.available(l, @dest) == :infinity
  end

  test "an empty derive (all RPCs down) leaves prior capacity untouched" do
    l = ledger()
    :ok = CapacityLedger.set_capacity(l, @dest, 999)
    r = refresher(l, derive_fn: fn -> %{} end, refresh_on_start: false)

    assert :ok = CapacityRefresher.refresh(r)
    assert CapacityLedger.available(l, @dest) == 999
  end

  test "a later refresh merges without dropping unrefreshed corridors" do
    l = ledger()
    other = {42_161, "0xaf88d065e77c8cc2239327c5edb3a432268e5831"}
    :ok = CapacityLedger.set_capacity(l, other, 111)
    r = refresher(l, derive_fn: fn -> %{@dest => 222} end, refresh_on_start: false)

    assert :ok = CapacityRefresher.refresh(r)
    assert CapacityLedger.available(l, @dest) == 222
    # a corridor absent from this derive keeps its prior capacity (merge, not replace)
    assert CapacityLedger.available(l, other) == 111
  end
end
