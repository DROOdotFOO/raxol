defmodule Raxol.Payments.DeliveryFloor do
  @moduledoc """
  The caller's `min_to_amount`, read the same way by every action that takes
  one: `ExecuteXochiIntent`, `ExecuteRelayTransfer` and `ExecuteDepositRoute`.

  ## Reading it

  `nil`, `""` and `0` are absent. Anything else must be a non-negative integer
  in destination-chain atomic units, as an integer or a string of digits;
  `"1e6"`, `"995000.0"`, `"1,000,000"` and `"-1"` are refused as
  `{:invalid_min_to_amount, value}` rather than read as absent, because a floor
  the caller wrote and we ignored bounds nothing while looking as if it did.

  ## A floor on a non-USD stablecoin destination

  EURC, EURe and ZCHF (`Raxol.Payments.Assets.fx_peg/2`) have no FX rate behind
  them yet (ADR-0040 decision 7), so a floor is the caller's only bound on what
  arrives. It must therefore be in the destination's units: a floor below a
  tenth of the source amount rescaled to the destination's decimals is
  `{:implausible_min_to_amount, detail}`. That catches a floor written in the
  source's 6-decimal scale for an 18-decimal EURe destination (10^-12 of the
  intended bound) without pricing anything: no dollar-to-euro or dollar-to-franc
  rate is within a factor of ten of the line. It is checked only when both
  sides' decimals are registered.

  ## Checking a quote against it

  A quote's own `min_to_amount`, when it carries one, is what the solver
  guarantees after slippage, so the floor is checked against it rather than
  against the `to_amount` estimate. Neither value is attested by Xochi's
  deposit attestation, so on the deposit route this is a pre-funding filter on
  what the quote says, not a bound on what is delivered.
  """

  alias Raxol.Payments.Assets

  @type floor :: {:floor, pos_integer()} | :none

  @doc "Read `min_to_amount`: `{:ok, nil}` when absent, else a positive integer."
  @spec parse(term()) :: {:ok, pos_integer() | nil} | {:error, {:invalid_min_to_amount, term()}}
  def parse(nil), do: {:ok, nil}
  def parse(0), do: {:ok, nil}
  def parse(n) when is_integer(n) and n > 0, do: {:ok, n}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        if trimmed =~ ~r/\A[0-9]+\z/,
          do: parse(String.to_integer(trimmed)),
          else: {:error, {:invalid_min_to_amount, value}}
    end
  end

  def parse(value), do: {:error, {:invalid_min_to_amount, value}}

  @doc """
  The floor for a route whose destination may be a non-USD stablecoin, given
  the parsed `min_to_amount`. A non-USD destination without one is
  `{:unpriced_asset, detail}`; with one, it must be plausible (see the
  moduledoc). Any other destination takes the floor as given, or none.
  """
  @spec for_route(pos_integer() | nil, map()) :: {:ok, floor()} | {:error, term()}
  def for_route(min_out, %{to_chain_id: chain, to_token: token} = route) do
    case {min_out, Assets.fx_peg(chain, token)} do
      {nil, nil} ->
        {:ok, :none}

      {nil, peg} ->
        {:error,
         {:unpriced_asset, %{chain_id: chain, token: token, side: :destination, peg: peg}}}

      {n, nil} ->
        {:ok, {:floor, n}}

      {n, _peg} ->
        with :ok <- plausible(n, route), do: {:ok, {:floor, n}}
    end
  end

  @doc """
  Whether a floor on a non-USD destination is in the destination's units.
  `route` carries `from_chain_id`, `from_token`, `from_amount` (atomic),
  `to_chain_id` and `to_token`. `:ok` when either side's decimals are unknown.
  """
  @spec plausible(pos_integer(), map()) :: :ok | {:error, {:implausible_min_to_amount, map()}}
  def plausible(min_out, route) do
    with {:ok, from_decimals} <- Assets.fetch_decimals(route.from_chain_id, route.from_token),
         {:ok, to_decimals} <- Assets.fetch_decimals(route.to_chain_id, route.to_token),
         {:ok, from_amount} <- parse(route.from_amount),
         true <- is_integer(from_amount) do
      par_out = rescale(from_amount, from_decimals, to_decimals)

      if min_out * 10 >= par_out,
        do: :ok,
        else:
          {:error,
           {:implausible_min_to_amount, %{min_to_amount: min_out, par_to_amount: par_out}}}
    else
      _unknown -> :ok
    end
  end

  @doc """
  Check a quote against a floor. The quote's `min_to_amount`, when present, is
  what is compared; otherwise its `to_amount`. A value that does not read as a
  non-negative integer fails the floor.
  """
  @spec check(map(), floor()) :: :ok | {:error, {:delivery_below_floor, map()}}
  def check(_quote, :none), do: :ok

  def check(quote, {:floor, min_out}) do
    quoted = Map.get(quote, :min_to_amount) || Map.get(quote, :to_amount)

    case parse(quoted) do
      {:ok, delivered} when is_integer(delivered) and delivered >= min_out ->
        :ok

      _ ->
        {:error,
         {:delivery_below_floor,
          %{to_amount: Map.get(quote, :to_amount), quoted: quoted, min_to_amount: min_out}}}
    end
  end

  defp rescale(amount, from, to) when to >= from, do: amount * Integer.pow(10, to - from)
  defp rescale(amount, from, to), do: div(amount, Integer.pow(10, from - to))
end
