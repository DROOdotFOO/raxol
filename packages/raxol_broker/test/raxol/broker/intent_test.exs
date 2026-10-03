defmodule Raxol.Broker.IntentTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Intent

  defp d(value), do: Decimal.new(value)

  test "provenance is required, never defaulted" do
    assert {:error, {:missing_option, :provenance}} = Intent.buy_usd("AAPL", d("1"), [])

    assert {:error, {:invalid, :provenance, :model}} =
             Intent.buy_usd("AAPL", d("1"), provenance: :model)

    assert {:ok, %Intent{provenance: {:untrusted, "rss"}}} =
             Intent.buy_usd("AAPL", d("1"), provenance: {:untrusted, "rss"})
  end

  test "symbols are trimmed and upcased; anything else is refused" do
    assert {:ok, %Intent{symbol: "BRK.B"}} = Intent.buy_usd(" brk.b ", d("1"), provenance: :human)

    for bad <- ["", "AAPL; DROP", String.duplicate("A", 17), :AAPL, "\e[2J"] do
      assert {:error, {:invalid, :symbol, ^bad}} =
               Intent.buy_usd(bad, d("1"), provenance: :human)
    end
  end

  test "amounts must be finite and strictly positive decimals" do
    for bad <- [d("0"), d("-1"), d("NaN"), d("Infinity"), 1, "1"] do
      assert {:error, {:invalid, :qty, ^bad}} = Intent.buy_shares("AAPL", bad, provenance: :human)
    end

    assert {:error, {:invalid, :limit, _}} =
             Intent.limit(:buy, "AAPL", d("1"), d("0"), provenance: :human)

    assert {:error, {:invalid, :side, :short}} =
             Intent.limit(:short, "AAPL", d("1"), d("1"), provenance: :human)
  end

  test "params are accepted only for options and advanced orders" do
    assert {:ok, %Intent{params: %{"strike" => "200"}}} =
             Intent.option(:buy, "AAPL", d("100"),
               provenance: :human,
               params: %{"strike" => "200"}
             )

    assert {:error, {:invalid, :params, %{"x" => 1}}} =
             Intent.buy_usd("AAPL", d("1"), provenance: :human, params: %{"x" => 1})
  end

  test "ids are random unless given" do
    {:ok, a} = Intent.cancel("order-1", provenance: :human)
    {:ok, b} = Intent.cancel("order-1", provenance: :human)
    assert a.id != b.id

    assert {:ok, %Intent{id: "intent-7"}} =
             Intent.cancel("order-1", provenance: :human, id: "intent-7")
  end
end
