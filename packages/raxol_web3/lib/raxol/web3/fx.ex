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

  `pegs` maps each symbol this function may price to its registered peg
  currency (`Raxol.Payments.Assets.fx_pegs/0`, passed in because this package
  does not depend on `raxol_payments`). Every symbol in it answers from here,
  and every other symbol goes to `fallback`, dollar stablecoins included, so
  no snapshot can change how ETH or POL is priced.

  A registered symbol is priced at the Chainlink rate for its REGISTERED peg
  when every listing of it in the snapshot agrees on that peg and is judged
  `:ok` against it, and at `nil` otherwise: absent, vetoed, unrated or a failed
  snapshot. Sleuth's data can only veto. It chooses neither which symbols are
  repriced nor at which rate, and a `nil` is never handed to `fallback`, which
  might price a euro at a dollar.

  One snapshot of the partner set and one rate read per registered peg, taken
  when the function is built and then closed over, so a report does not touch
  the network per lookup. A failed snapshot is logged, and leaves the
  registered symbols unpriced for the ledger to count.
  """
  @spec price_fn(t(), %{String.t() => String.t()}, (String.t() -> Decimal.t() | nil)) ::
          (String.t() -> Decimal.t() | nil)
  def price_fn(%__MODULE__{} = fx, pegs, fallback \\ fn _symbol -> nil end)
      when is_map(pegs) and is_function(fallback, 1) do
    prices = fx_prices(fx, pegs)

    fn symbol ->
      case Map.fetch(prices, symbol) do
        {:ok, price} -> price
        :error -> fallback.(symbol)
      end
    end
  end

  # symbol -> Decimal | nil, with a key for every registered symbol.
  defp fx_prices(fx, pegs) do
    case Sleuth.stables(fx.sleuth, partner_only: true) do
      {:ok, %{assets: assets}} ->
        listings = Enum.group_by(assets, & &1.symbol)
        rates = Map.new(Enum.uniq(Map.values(pegs)), &{&1, Chainlink.rate(fx.chainlink, &1)})

        Map.new(pegs, fn {symbol, peg} ->
          {symbol, registered_price(Map.get(listings, symbol, []), peg, rates)}
        end)

      {:error, reason} ->
        require Logger
        Logger.warning("FX price snapshot failed (#{inspect(reason)}); non-USD legs unpriced")
        Map.new(pegs, fn {symbol, _peg} -> {symbol, nil} end)
    end
  end

  # Judged against the registered peg. A listing that names another peg is a
  # veto, not a request for that peg's rate.
  defp registered_price([], _peg, _rates), do: nil

  defp registered_price(listings, peg, rates) do
    verdicts =
      Enum.map(listings, fn
        %{peg_currency: ^peg} = asset -> Quality.judge(asset, rates)
        _relabelled -> nil
      end)

    if Enum.all?(verdicts, &match?(%{status: :ok}, &1)),
      do: hd(verdicts).rate,
      else: nil
  end

  defp judged(asset, rates), do: Map.put(asset, :quality, Quality.judge(asset, rates))
end
