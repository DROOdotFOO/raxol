defmodule Raxol.Web3.FX.Quality do
  @moduledoc """
  Our verdict on an asset, against the rate of record (ADR-0040 decision 4).

  Pure: it takes an asset from `Raxol.Web3.FX.Sleuth` and the rates from
  `Raxol.Web3.FX.Chainlink`, and never reads Sleuth's own `deviationBps`,
  `pegTargetUsd` or FX rates. It does not depend on the caller's `Decimal`
  context either: the line is drawn without division, as
  `|price - rate| * 100 > rate`, inside a pinned context wide enough to make
  that exact for every figure the decoder lets through, and the displayed
  deviation is computed in a pinned context too.

      deviation_bps = (price_usd / rate(peg_currency) - 1) * 10_000

  One status per asset; the first matching rule wins:

    * `:yield_bearing` - drifts above its peg by design, so no deviation;
    * `:no_rate` - no usable rate for the peg currency, including every peg
      outside USD, EUR and CHF;
    * `:suspect` - no price, or |deviation_bps| > #{100}, whatever the peg
      mechanism, judged on the exact deviation and not on the rounded figure
      the verdict carries for display (100.4 bps is suspect and shows as 100).
      A broken feed and a real depeg look the same here, and neither may be
      priced at its peg;
    * `:ok` - otherwise.
  """

  @type status :: :ok | :no_rate | :suspect | :yield_bearing

  @type verdict :: %{
          status: status(),
          deviation_bps: integer() | nil,
          rate: Decimal.t() | nil,
          rate_precision_bps: non_neg_integer() | nil
        }

  @suspect_bps 100

  @doc "The |deviation| above which an asset is `:suspect`, in bps."
  @spec suspect_bps() :: pos_integer()
  def suspect_bps, do: @suspect_bps

  @doc """
  Judge one asset. `rates` maps a peg currency to the result of
  `Raxol.Web3.FX.Chainlink.rate/2`; a peg that is absent counts as no rate.
  """
  @spec judge(map(), %{String.t() => {:ok, map()} | {:error, term()}}) :: verdict()
  def judge(%{yield_bearing?: true}, _rates), do: verdict(:yield_bearing, nil, nil)

  def judge(%{peg_currency: peg} = asset, rates) do
    case Map.get(rates, peg) do
      {:ok, %{rate: %Decimal{} = rate} = usable} ->
        if Decimal.gt?(rate, 0),
          do: against(asset, rate, usable.precision_bps),
          else: verdict(:no_rate, nil, nil)

      _ ->
        verdict(:no_rate, nil, nil)
    end
  end

  # 200 digits holds `|price - rate| * 100` exactly: a decoded price has at most
  # 38 digits and an exponent within ±30, and a Chainlink rate is an int256
  # answer over 10^8, at most 77 digits.
  @exact %Decimal.Context{precision: 200, rounding: :half_even, traps: []}
  @display %Decimal.Context{precision: 50, rounding: :half_even, traps: []}

  defp against(%{price_usd: %Decimal{} = price}, rate, precision) do
    status = if suspect?(price, rate), do: :suspect, else: :ok
    verdict(status, deviation_bps(price, rate), {rate, precision})
  end

  defp against(_asset, rate, precision), do: verdict(:suspect, nil, {rate, precision})

  defp suspect?(price, rate) do
    Decimal.Context.with(@exact, fn ->
      price
      |> Decimal.sub(rate)
      |> Decimal.abs()
      |> Decimal.mult(10_000)
      |> Decimal.gt?(Decimal.mult(rate, @suspect_bps))
    end)
  end

  @doc "`(price / rate - 1) * 10_000`, rounded half-even to an integer, for display."
  @spec deviation_bps(Decimal.t(), Decimal.t()) :: integer()
  def deviation_bps(price, rate) do
    Decimal.Context.with(@display, fn ->
      price
      |> Decimal.div(rate)
      |> Decimal.sub(1)
      |> Decimal.mult(10_000)
      |> Decimal.round(0, :half_even)
      |> Decimal.to_integer()
    end)
  end

  defp verdict(status, deviation, nil),
    do: %{status: status, deviation_bps: deviation, rate: nil, rate_precision_bps: nil}

  defp verdict(status, deviation, {rate, precision}),
    do: %{status: status, deviation_bps: deviation, rate: rate, rate_precision_bps: precision}
end
