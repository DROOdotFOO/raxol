defmodule Raxol.ACP.Xochi.CapacityGateTest do
  # async: false -- the gate uses the default-registered ledger/refresher names,
  # which the offering resolves via `Process.whereis/1`.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.{CapacityGate, CapacityLedger, CapacityRefresher}

  @dest {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85"}

  test "the gate starts the ledger + refresher, and the refresher seeds the ledger" do
    start_supervised!(
      {CapacityGate,
       ledger: [capacity: %{}],
       refresher: [
         derive_fn: fn -> %{@dest => 1234} end,
         refresh_on_start: false,
         interval_ms: 60_000
       ]}
    )

    assert is_pid(Process.whereis(CapacityLedger))
    assert is_pid(Process.whereis(CapacityRefresher))

    assert :ok = CapacityRefresher.refresh()
    assert CapacityLedger.available(CapacityLedger, @dest) == 1234
  end
end
