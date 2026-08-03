defmodule Raxol.Earn.AssetToken do
  @moduledoc """
  Token-amount value object used throughout v2 budget / fund / submit
  flows.

  Replaces the v1 `Fare` / `FareAmount` pair. An `AssetToken` carries
  the address, symbol, decimal precision, and raw amount so a single
  value can travel through `set_budget/fund/submit` calls without
  needing chain-specific lookup tables at every step.

  ## Construction

      Raxol.Earn.AssetToken.usdc(0.1, 8453)           # 100_000 raw (6 dp)
      Raxol.Earn.AssetToken.usdc_from_raw(100_000, 8453)
      Raxol.Earn.AssetToken.create(
        address: "0x...",
        symbol: "WETH",
        decimals: 18,
        amount: Decimal.new("1.5")
      )

  ## Equivalence with the SDK

  Mirrors `AssetToken.usdc(amount, chainId)` and
  `AssetToken.usdcFromRaw(rawAmount, chainId)` in `acp-node-v2`
  (`src/core/assetToken.ts`). The shape is intentionally identical so
  on-the-wire payloads round-trip.
  """

  alias Raxol.Earn.Chain

  @type t :: %__MODULE__{
          address: String.t(),
          symbol: String.t(),
          decimals: pos_integer(),
          raw_amount: non_neg_integer(),
          chain_id: pos_integer()
        }

  defstruct [:address, :symbol, :decimals, :raw_amount, :chain_id]

  @doc """
  Build a USDC token amount for the given chain. `amount` is in
  human-readable units (e.g. `0.1` for 0.1 USDC). The chain must be a
  known ACP chain (`Chain.mainnet/0` or `Chain.sepolia/0`).
  """
  @spec usdc(number() | Decimal.t(), pos_integer()) :: t()
  def usdc(amount, chain_id) when is_integer(chain_id) do
    config = chain_config_by_id!(chain_id)
    decimals = 6
    raw = to_raw(amount, decimals)

    %__MODULE__{
      address: config.usdc_address,
      symbol: "USDC",
      decimals: decimals,
      raw_amount: raw,
      chain_id: chain_id
    }
  end

  @doc "Build a USDC token amount from a raw integer (e.g. `100_000` = 0.1 USDC)."
  @spec usdc_from_raw(non_neg_integer(), pos_integer()) :: t()
  def usdc_from_raw(raw_amount, chain_id)
      when is_integer(raw_amount) and raw_amount >= 0 and is_integer(chain_id) do
    config = chain_config_by_id!(chain_id)

    %__MODULE__{
      address: config.usdc_address,
      symbol: "USDC",
      decimals: 6,
      raw_amount: raw_amount,
      chain_id: chain_id
    }
  end

  @doc """
  Build a token amount for an arbitrary ERC-20. All fields required.

      AssetToken.create(
        address: "0x...",
        symbol: "WETH",
        decimals: 18,
        amount: Decimal.new("1.5"),
        chain_id: 8453
      )
  """
  @spec create(keyword()) :: t()
  def create(opts) do
    address = Keyword.fetch!(opts, :address)
    symbol = Keyword.fetch!(opts, :symbol)
    decimals = Keyword.fetch!(opts, :decimals)
    chain_id = Keyword.fetch!(opts, :chain_id)

    raw =
      case Keyword.fetch(opts, :raw_amount) do
        {:ok, raw} when is_integer(raw) and raw >= 0 ->
          raw

        :error ->
          opts |> Keyword.fetch!(:amount) |> to_raw(decimals)
      end

    %__MODULE__{
      address: address,
      symbol: symbol,
      decimals: decimals,
      raw_amount: raw,
      chain_id: chain_id
    }
  end

  @doc "Return the human-readable amount as a `Decimal`."
  @spec to_human(t()) :: Decimal.t()
  def to_human(%__MODULE__{raw_amount: raw, decimals: dp}) do
    Decimal.div(Decimal.new(raw), Decimal.new(Integer.pow(10, dp)))
  end

  # -- Internal --

  defp to_raw(%Decimal{} = amount, decimals) do
    amount
    |> Decimal.mult(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.round(0, :down)
    |> Decimal.to_integer()
  end

  defp to_raw(amount, decimals) when is_integer(amount) do
    amount * Integer.pow(10, decimals)
  end

  defp to_raw(amount, decimals) when is_float(amount) do
    amount
    |> Decimal.from_float()
    |> to_raw(decimals)
  end

  defp chain_config_by_id!(8453), do: Chain.mainnet()
  defp chain_config_by_id!(84_532), do: Chain.sepolia()

  defp chain_config_by_id!(other) do
    raise ArgumentError,
          "AssetToken: unknown chain_id #{inspect(other)}. " <>
            "ACP v2 currently supports Base Mainnet (8453) and Base Sepolia (84532)."
  end
end
