defmodule Raxol.Broker.IntentTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Intent
  alias Raxol.Broker.Test.Hostile

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

  describe "normalize/1" do
    defp every_kind do
      p = [provenance: {:untrusted, "email"}, strategy: :momentum]

      for {:ok, intent} <- [
            Intent.buy_usd("AAPL", d("100"), p),
            Intent.buy_shares("AAPL", d("2"), provenance: :llm),
            Intent.sell("AAPL", d("1.5"), provenance: {:untrusted, :rss}),
            Intent.limit(:buy, "AAPL", d("1"), d("190"), p),
            Intent.stop_limit(:sell, "AAPL", d("1"), d("180"), d("179"), p),
            Intent.stop_market(:sell, "AAPL", d("1"), d("180"), p),
            Intent.option(:buy, "AAPL", d("500"), Keyword.put(p, :params, %{"legs" => [1, 2]})),
            Intent.advanced(:buy, "AAPL", d("500"), Keyword.put(p, :params, %{"kind" => "oco"})),
            Intent.cancel("order-1", provenance: :human)
          ],
          do: intent
    end

    test "every constructed kind round-trips unchanged" do
      intents = every_kind()
      assert length(intents) == length(Intent.kinds())

      for intent <- intents, do: assert({:ok, ^intent} = Intent.normalize(intent))
    end

    test "a hostile struct in any field is refused without running its callbacks" do
      {:ok, intent} = Intent.option(:buy, "AAPL", d("500"), provenance: :llm)

      assert {:error, {:not_plain, [:symbol]}} =
               Intent.normalize(%{intent | symbol: Hostile.new()})

      assert {:error, {:not_plain, [:params, "legs"]}} =
               Intent.normalize(%{intent | params: %{"legs" => Hostile.new()}})

      assert {:error, {:not_plain, [:params]}} =
               Intent.normalize(%{intent | params: Hostile.new()})

      assert {:error, {:not_plain, [:provenance, 1]}} =
               Intent.normalize(%{intent | provenance: {:untrusted, Hostile.new()}})

      assert {:error, {:not_plain, [:notional]}} =
               Intent.normalize(%{intent | notional: Hostile.new()})

      assert {:error, :not_an_intent} = Intent.normalize(Hostile.new())
      refute_received {:hostile, _callback}
    end

    test "forged decimals, floats, pids and functions are refused" do
      {:ok, intent} = Intent.buy_shares("AAPL", d("2"), provenance: :human)

      assert {:error, {:not_plain, [:qty]}} =
               Intent.normalize(%{intent | qty: %Decimal{sign: 1, coef: :inf, exp: 0}})

      assert {:error, {:not_plain, [:qty]}} =
               Intent.normalize(%{intent | qty: %Decimal{sign: 1, coef: 2.0, exp: 0}})

      assert {:error, {:not_plain, [:qty]}} = Intent.normalize(%{intent | qty: 2.0})
      assert {:error, {:not_plain, [:strategy]}} = Intent.normalize(%{intent | strategy: self()})

      assert {:error, {:not_plain, [:id]}} =
               Intent.normalize(%{intent | id: fn -> "intent-1" end})
    end

    test "plain values that break the constructor rules are refused without echoing them" do
      {:ok, intent} = Intent.buy_shares("AAPL", d("2"), provenance: :human)

      assert {:error, {:invalid, :qty}} = Intent.normalize(%{intent | qty: d("-1")})
      assert {:error, {:invalid, :symbol}} = Intent.normalize(%{intent | symbol: "not a ticker"})
      assert {:error, {:invalid, :kind}} = Intent.normalize(%{intent | kind: :yolo})
      assert {:error, {:invalid, :provenance}} = Intent.normalize(%{intent | provenance: :model})
      assert {:error, {:invalid, :params}} = Intent.normalize(%{intent | params: %{"a" => 1}})
      assert {:error, {:invalid, :id}} = Intent.normalize(%{intent | id: ""})
      assert {:error, :not_an_intent} = Intent.normalize(%{kind: :buy_shares})
    end
  end
end
