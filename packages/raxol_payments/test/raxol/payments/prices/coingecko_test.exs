defmodule Raxol.Payments.Prices.CoinGeckoTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Prices.CoinGecko

  # Build a price_fn that fetches through the Req.Test plug (the only mocked
  # boundary -- CoinGecko's HTTP call, never an internal module). `retry: false`
  # keeps the 5xx case deterministic and instant: we assert CoinGecko's handling
  # of the final response, not Req's exponential-backoff retry of it.
  defp price_fn do
    CoinGecko.price_fn(
      url: "https://cg.test",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )
  end

  defp stub_json(body) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end

  test "resolves ETH and POL from a 200 response" do
    stub_json(%{
      "ethereum" => %{"usd" => 1700},
      "polygon-ecosystem-token" => %{"usd" => 0.07}
    })

    pf = price_fn()
    assert Decimal.equal?(pf.("ETH"), Decimal.new(1700))
    assert Decimal.equal?(pf.("POL"), Decimal.from_float(0.07))
  end

  test "parses an integer usd value" do
    stub_json(%{"ethereum" => %{"usd" => 3000}})
    assert Decimal.equal?(price_fn().("ETH"), Decimal.new(3000))
  end

  test "a symbol missing from the response resolves to nil" do
    # Only ETH present; POL is absent.
    stub_json(%{"ethereum" => %{"usd" => 1700}})
    pf = price_fn()

    assert Decimal.equal?(pf.("ETH"), Decimal.new(1700))
    assert pf.("POL") == nil
  end

  test "a symbol the module does not know is always nil" do
    stub_json(%{"ethereum" => %{"usd" => 1700}})
    assert price_fn().("BTC") == nil
  end

  test "a non-200 response degrades every symbol to nil (no crash)" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "upstream error") end)
    pf = price_fn()

    assert pf.("ETH") == nil
    assert pf.("POL") == nil
  end

  test "a 200 with a non-map body degrades to nil" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s(["unexpected"]))
    end)

    assert price_fn().("ETH") == nil
  end

  test "a usd field that is not numeric resolves to nil" do
    stub_json(%{"ethereum" => %{"usd" => "not-a-number"}})
    assert price_fn().("ETH") == nil
  end
end
