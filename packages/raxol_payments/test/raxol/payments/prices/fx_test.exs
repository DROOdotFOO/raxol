defmodule Raxol.Payments.Prices.FXTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Payments.Prices.FX

  @fallback_price Decimal.new("2500")

  defp fallback, do: fn _symbol -> @fallback_price end

  test "a key no header can carry leaves the FX symbols unpriced, not the sweep crashed" do
    # Refused by `Sleuth.new/1` before any request is built, so nothing here
    # reaches a network.
    {price, log} =
      with_log(fn ->
        FX.price_fn([sleuth_api_key: "key\r\nx-injected: 1", rpc_urls: %{}], fallback())
      end)

    for symbol <- Map.keys(Raxol.Payments.Assets.fx_pegs()) do
      assert price.(symbol) == nil
    end

    assert price.("ETH") == @fallback_price
    assert log =~ "invalid_argument"
    refute log =~ "x-injected"
  end
end
