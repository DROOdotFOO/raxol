defmodule Raxol.Web3.FX do
  @moduledoc """
  FX market data with our verdict attached (ADR-0040).

  Sleuth supplies the market (`Raxol.Web3.FX.Sleuth`), Chainlink the rate of
  record (`Raxol.Web3.FX.Chainlink`), and `Raxol.Web3.FX.Quality` the verdict.
  This module pairs them: every asset it returns carries a `:quality` verdict.

  FX is market data beside the chain backends, not one of them: Sleuth answers
  neither `chain_info/1` nor `block_height/1` (ADR-0039), so nothing here
  implements `Raxol.Web3.Backend`.
  """

  alias Raxol.Web3.FX.{Chainlink, Quality, Sleuth}

  @enforce_keys [:sleuth, :chainlink]
  defstruct [:sleuth, :chainlink]

  @type t :: %__MODULE__{sleuth: Sleuth.t(), chainlink: Chainlink.t()}

  @doc "Pair a Sleuth handle with a Chainlink handle."
  @spec new(Sleuth.t(), Chainlink.t()) :: t()
  def new(%Sleuth{} = sleuth, %Chainlink{} = chainlink),
    do: %__MODULE__{sleuth: sleuth, chainlink: chainlink}

  @doc "`Sleuth.stables/2`, with a `:quality` verdict on every asset."
  @spec stables(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stables(%__MODULE__{} = fx, opts \\ []) do
    with {:ok, snapshot} <- Sleuth.stables(fx.sleuth, opts) do
      rates = rates(fx.chainlink, snapshot.assets)
      {:ok, %{snapshot | assets: Enum.map(snapshot.assets, &judged(&1, rates))}}
    end
  end

  @doc "`Sleuth.stable/2`, with a `:quality` verdict on the asset."
  @spec stable(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stable(%__MODULE__{} = fx, symbol) do
    with {:ok, %{asset: asset} = detail} <- Sleuth.stable(fx.sleuth, symbol) do
      {:ok, %{detail | asset: judged(asset, rates(fx.chainlink, [asset]))}}
    end
  end

  @doc "`Sleuth.corridors/2` unchanged: corridor totals carry no per-asset verdict."
  @spec corridors(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def corridors(%__MODULE__{} = fx, opts \\ []), do: Sleuth.corridors(fx.sleuth, opts)

  @doc """
  One rate read per distinct peg the assets need, and only for pegs Chainlink
  can rate, so a page of 300 assets costs at most three feed reads.
  """
  @spec rates(Chainlink.t(), [map()]) :: %{String.t() => {:ok, map()} | {:error, term()}}

  def rates(%Chainlink{} = chainlink, assets) do
    assets
    |> Enum.map(& &1.peg_currency)
    |> Enum.uniq()
    |> Enum.filter(&(&1 in Chainlink.pegs()))
    |> Map.new(&{&1, Chainlink.rate(chainlink, &1)})
  end

  @doc """
  A `(symbol -> Decimal.t() | nil)` for accounting (ADR-0040 decision 6).

  One snapshot of the partner set and one rate read per peg, taken when the
  function is built, then closed over, so a report does not touch the network
  per lookup. A symbol pegged to a currency other than the dollar is priced at
  the Chainlink rate for its peg when its verdict is `:ok`, and at `nil`
  otherwise: accounting is priced at the rate of record, and Sleuth's price can
  only veto. Every other symbol, dollar stablecoins included, goes to
  `fallback`, so ETH and POL pricing is whatever it was.

  A failed snapshot logs its reason and prices only through `fallback`: a
  report with EUR legs unpriced is counted as such by the ledger, which is
  better than a report that fails outright.
  """
  @spec price_fn(t(), (String.t() -> Decimal.t() | nil)) :: (String.t() -> Decimal.t() | nil)
  def price_fn(%__MODULE__{} = fx, fallback \\ fn _symbol -> nil end)
      when is_function(fallback, 1) do
    prices = fx_prices(fx)

    fn symbol ->
      case Map.fetch(prices, symbol) do
        {:ok, price} -> price
        :error -> fallback.(symbol)
      end
    end
  end

  # symbol -> Decimal | nil, for every non-USD asset in the snapshot. An entry
  # with `nil` is deliberate: a judged EUR asset must not fall through to a
  # fallback that might price it at par.
  defp fx_prices(fx) do
    case stables(fx, partner_only: true) do
      {:ok, %{assets: assets}} ->
        for %{peg_currency: peg} = asset <- assets, peg != "USD", into: %{} do
          {asset.symbol, ok_rate(asset.quality)}
        end

      {:error, reason} ->
        require Logger
        Logger.warning("FX price snapshot failed (#{inspect(reason)}); non-USD legs unpriced")
        %{}
    end
  end

  defp ok_rate(%{status: :ok, rate: rate}), do: rate
  defp ok_rate(_verdict), do: nil

  defp judged(asset, rates), do: Map.put(asset, :quality, Quality.judge(asset, rates))
end
