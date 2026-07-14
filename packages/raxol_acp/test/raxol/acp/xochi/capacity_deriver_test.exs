defmodule Raxol.ACP.Xochi.CapacityDeriverTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.CapacityDeriver

  @rows [
    %{chain: 8453, token: "0xusdc", symbol: "USDC", raw: 48_840_000_000, usd: 48_840.0},
    %{chain: 10, token: "0xusdc10", symbol: "USDC", raw: 52_000_000, usd: 52.0},
    %{chain: 8453, token: "0xusdt", symbol: "USDT", raw: 17_000_000, usd: 17.0}
  ]

  test "project applies the fraction and closes sub-min-usd corridors" do
    caps = CapacityDeriver.project(@rows, 0.2, 50.0)

    assert caps[{8453, "0xusdc"}] == trunc(48_840_000_000 * 0.2)
    assert caps[{10, "0xusdc10"}] == trunc(52_000_000 * 0.2)
    # $17 < $50 -> closed
    assert caps[{8453, "0xusdt"}] == 0
  end

  test "cap_value floors above min_usd and closes below it" do
    row = %{chain: 1, token: "0x", symbol: "USDC", raw: 1_000_000_000, usd: 1000.0}

    assert CapacityDeriver.cap_value(row, 0.9, 50.0) == 900_000_000
    assert CapacityDeriver.cap_value(%{row | usd: 10.0}, 0.9, 50.0) == 0
  end

  test "rpc_url prefers the DERIVE_RPC_<chain> env, else a public default, else nil" do
    assert CapacityDeriver.rpc_url(8453) =~ "base"

    System.put_env("DERIVE_RPC_4663", "https://rpc.example")
    on_exit(fn -> System.delete_env("DERIVE_RPC_4663") end)

    assert CapacityDeriver.rpc_url(4663) == "https://rpc.example"
    assert CapacityDeriver.rpc_url(999_999) == nil
  end
end
