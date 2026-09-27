defmodule Raxol.Payments.Prices.CoinGecko do
  @moduledoc """
  A `price_fn` for native gas tokens and the non-dollar settlement assets it can
  price, backed by the public CoinGecko REST API.

  Fetches ETH, POL (Polygon), EURe (Monerium EUR e-money, quoted in USD, so about
  1.1x a dollar rather than par), and RAXOL (Robinhood Chain) once when the fn is
  built and closes over them, so aggregation does not hit the network per lookup.
  Any failure (or a missing symbol) yields `nil` for that symbol, so
  `SettlementLedger` aggregations degrade to raw fee/gas totals rather than
  crashing -- a leg CoinGecko cannot price is reported unpriced, never at par.

      price_fn = Raxol.Payments.Prices.CoinGecko.price_fn()
      Raxol.Payments.SettlementLedger.report(ledger, price_fn: price_fn)
  """

  @default_url "https://api.coingecko.com/api/v3/simple/price"

  # symbol -> CoinGecko coin id. Each non-native id is the coin CoinGecko maps
  # the canonical contract to: "monerium-eur-money-2" carries the current EURe
  # contracts (Arbitrum 0x0c06...44f8; "monerium-eur-money" is the retired v1
  # set), and "raxol" carries Robinhood Chain 0xf447...53af.
  @ids %{
    "ETH" => "ethereum",
    "POL" => "polygon-ecosystem-token",
    "EURe" => "monerium-eur-money-2",
    "RAXOL" => "raxol"
  }

  @doc """
  Build a `(symbol -> Decimal.t() | nil)` after one REST fetch.

  Options: `:url` (override endpoint), `:req_options` (extra `Req` options, e.g.
  `plug:` for `Req.Test`).
  """
  @spec price_fn(keyword()) :: (String.t() -> Decimal.t() | nil)
  def price_fn(opts \\ []) do
    prices = fetch(opts)
    fn symbol -> Map.get(prices, symbol) end
  end

  defp fetch(opts) do
    url = Keyword.get(opts, :url, @default_url)
    req_options = Keyword.get(opts, :req_options, [])
    ids = @ids |> Map.values() |> Enum.join(",")

    req =
      [url: url, params: [ids: ids, vs_currencies: "usd"]]
      |> Keyword.merge(req_options)
      |> Req.new()

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> parse(body)
      _ -> %{}
    end
  end

  defp parse(body) do
    @ids
    |> Enum.flat_map(fn {symbol, id} ->
      case get_in(body, [id, "usd"]) do
        n when is_integer(n) -> [{symbol, Decimal.new(n)}]
        f when is_float(f) -> [{symbol, Decimal.from_float(f)}]
        _ -> []
      end
    end)
    |> Map.new()
  end
end
