defmodule Raxol.Payments.DeliveryFloor do
  @moduledoc """
  The caller's `min_to_amount`, read the same way by every action that takes
  one: `ExecuteXochiIntent`, `ExecuteRelayTransfer` and `ExecuteDepositRoute`.

  ## Reading it

  `nil`, `""` and `0` are absent. Anything else must be a non-negative integer
  no larger than 2^256 - 1, in destination-chain atomic units, as a string of
  digits -- the type every action's tool schema declares -- or an integer from
  a direct `run/2` caller; `"1e6"`, `"995000.0"`, `"1,000,000"` and `"-1"` are
  refused as `{:invalid_min_to_amount, value}` rather than read as absent,
  because a floor the caller wrote and we ignored bounds nothing while looking
  as if it did.

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

  The floor is compared with the LOWEST amount the quote states anywhere: its
  `to_amount`, which must be present, its own `min_to_amount` when it carries
  one, and, when the EIP-712 message the wallet is asked to sign declares a
  `toAmount` field on its primary type, that field read exactly as
  `Raxol.Payments.EIP712` encodes it: a null or missing value is signed as 0
  and so judged as 0. A quote that states a high minimum beside a low
  estimate, or signs for less than it advertises, is judged on the low figure.
  Every amount must read as an integer in 0..2^256 - 1, or the floor fails: a
  larger one would sign as its low 256 bits. None of these figures is attested
  by Xochi's deposit attestation, so on the deposit route this is a
  pre-funding filter on what the quote says, not a bound on what is delivered.
  """

  alias Raxol.Payments.{Assets, EIP712}
  alias Raxol.Payments.Protocols.Xochi

  @max_uint256 Integer.pow(2, 256) - 1

  @type floor :: {:floor, pos_integer()} | :none

  @doc "Read `min_to_amount`: `{:ok, nil}` when absent, else a positive integer."
  @spec parse(term()) :: {:ok, pos_integer() | nil} | {:error, {:invalid_min_to_amount, term()}}
  def parse(nil), do: {:ok, nil}
  def parse(0), do: {:ok, nil}
  def parse(n) when is_integer(n) and n > 0 and n <= @max_uint256, do: {:ok, n}

  def parse(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        if trimmed =~ ~r/\A[0-9]{1,78}\z/ and String.to_integer(trimmed) <= @max_uint256,
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
  Check a quote against a floor, on the lowest amount it states (see the
  moduledoc). `{:delivery_below_floor, detail}` names the floor, the lowest
  readable amount (`nil` when one did not read) and each figure as served.
  """
  @spec check(map(), floor()) :: :ok | {:error, {:delivery_below_floor, map()}}
  def check(_quote, :none), do: :ok

  def check(quote, {:floor, floor}) do
    stated = stated(quote)

    lowest =
      Enum.reduce_while(stated, nil, fn {_field, value}, lowest ->
        case amount(value) do
          {:ok, n} -> {:cont, if(lowest, do: min(lowest, n), else: n)}
          :error -> {:halt, nil}
        end
      end)

    if is_integer(lowest) and lowest >= floor,
      do: :ok,
      else: {:error, {:delivery_below_floor, Map.merge(%{floor: floor, lowest: lowest}, stated)}}
  end

  # `to_amount` is required, so it is always listed; the others only when the
  # quote carries them.
  defp stated(quote) do
    optional = [
      min_to_amount: Map.get(quote, :min_to_amount),
      signed_to_amount: signed_to_amount(quote)
    ]

    Map.new([
      {:to_amount, Map.get(quote, :to_amount)} | Enum.reject(optional, &is_nil(elem(&1, 1)))
    ])
  end

  # The signed `toAmount`, or nil when the signed struct has no such field. A
  # declared field the message leaves null or out is signed as 0, so it reads
  # as 0. A types map or message the encoder cannot read signs nothing usable;
  # it reads as an unreadable amount, so the floor fails closed.
  defp signed_to_amount(%{eip712_data: %{} = eip712}) do
    types = Xochi.eip712_types(eip712)
    fields = Map.get(types, EIP712.primary_type(types), [])

    message =
      case eip712["message"] do
        %{} = message -> message
        _ -> %{}
      end

    if Enum.any?(fields, &match?({"toAmount", _type}, &1)),
      do: Map.get(message, "toAmount") || 0,
      else: nil
  rescue
    _malformed -> :unreadable
  end

  defp signed_to_amount(_quote), do: nil

  defp amount(n) when is_integer(n) and n >= 0 and n <= @max_uint256, do: {:ok, n}

  defp amount(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- trimmed =~ ~r/\A[0-9]{1,78}\z/,
         n when n <= @max_uint256 <- String.to_integer(trimmed) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp amount(_value), do: :error

  defp rescale(amount, from, to) when to >= from, do: amount * Integer.pow(10, to - from)
  defp rescale(amount, from, to), do: div(amount, Integer.pow(10, from - to))
end
