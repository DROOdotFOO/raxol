defmodule Raxol.Payments.Assets do
  @moduledoc """
  Asset decimals registry.

  Centralizes the atomic-vs-human unit conversion that every payment
  protocol needs but no single protocol owns. Without this, `SpendingPolicy`
  caps written in human dollars (`Decimal.new("1.00")`) get compared
  against raw atomic amounts (USDC `1_000_000` = $1), and small policy
  caps reject every legitimate payment.

  Lookups support two shapes:

    * `decimals(chain_id, contract_address)` -- for protocols that carry
      both the chain id and the ERC-20 contract address (x402).
    * `decimals(ticker)` -- for protocols that only carry a currency
      symbol (MPP).

  Unknown assets default to **6 decimals** (USDC convention on the
  major networks). This is the safe-ish default for stablecoin flows
  and the wrong default for native-token flows -- always pass the
  contract or ticker for non-USDC payments.

  ## Adding new assets

  Add to `@addresses` (chain+contract) or `@tickers` (symbol). Keep
  addresses lowercase. Tests in `test/raxol/payments/assets_test.exs`
  pin the known set.
  """

  @default_decimals 6

  # Lowercase contract address -> decimals, keyed by chain id.
  @addresses %{
    # Base
    8453 => %{
      # USDC native (Circle)
      "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913" => 6,
      # USDC bridged (USDbC)
      "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca" => 6,
      # USDT
      "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2" => 6,
      # WETH
      "0x4200000000000000000000000000000000000006" => 18
    },
    # Ethereum mainnet
    1 => %{
      # USDC
      "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" => 6,
      # USDT
      "0xdac17f958d2ee523a2206206994597c13d831ec7" => 6,
      # DAI
      "0x6b175474e89094c44da98b954eedeac495271d0f" => 18,
      # WETH
      "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" => 18
    },
    # Optimism
    10 => %{
      # USDC native
      "0x0b2c639c533813f4aa9d7837caf62653d097ff85" => 6,
      # USDT
      "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58" => 6,
      # WETH
      "0x4200000000000000000000000000000000000006" => 18
    },
    # Arbitrum
    42_161 => %{
      "0xaf88d065e77c8cc2239327c5edb3a432268e5831" => 6,
      "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9" => 6,
      "0x82af49447d8a07e3bd95bd0d56f35241523fbab1" => 18
    },
    # Polygon
    137 => %{
      # USDC native
      "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359" => 6,
      # USDC.e bridged
      "0x2791bca1f2de4661ed88a30c99a7a9449aa84174" => 6,
      # USDT
      "0xc2132d05d31c914a87c6611c10748aeb04b58e8f" => 6,
      # WETH
      "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619" => 18
    },
    # Tron mainnet (TRC-20). Keys are lowercased to match the lookup; Tron
    # addresses are case-sensitive but USDT/USDC both use 6 decimals.
    728_126_428 => %{
      # USDT TRC-20
      "tr7nhqjekqxgtci8q8zy4pl8otszgjlj6t" => 6,
      # USDC TRC-20
      "tekxitehnzsmse2xqrbj4w32run966rdz8" => 6
    }
  }

  # EVM USDC contracts per chain (lowercase). Used to enforce the ERC-3009
  # USDC-only rule: ERC-3009 signs against the USDC contract as the EIP-712
  # verifying contract, so using it for any other token is silently invalid.
  @usdc %{
    1 => ["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"],
    8453 => [
      "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca"
    ],
    10 => ["0x0b2c639c533813f4aa9d7837caf62653d097ff85"],
    42_161 => ["0xaf88d065e77c8cc2239327c5edb3a432268e5831"],
    137 => ["0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"]
  }

  # Currency ticker fallback for protocols that don't carry an address.
  @tickers %{
    "USDC" => 6,
    "USDT" => 6,
    "USDBC" => 6,
    "PYUSD" => 6,
    "DAI" => 18,
    "ETH" => 18,
    "WETH" => 18
  }

  # Solver-fillable EVM tokens: symbol -> chain id -> lowercase address. Mirrors
  # Riddler's config/token_registry.ex for the five supported EVM chains
  # (Ethereum, Optimism, Polygon, Base, Arbitrum). Decimals live in `@addresses`.
  @evm_tokens %{
    "USDC" => %{
      1 => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      10 => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      137 => "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
      8453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      42_161 => "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    },
    "USDT" => %{
      1 => "0xdac17f958d2ee523a2206206994597c13d831ec7",
      10 => "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58",
      137 => "0xc2132d05d31c914a87c6611c10748aeb04b58e8f",
      8453 => "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2",
      42_161 => "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"
    },
    "WETH" => %{
      1 => "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      10 => "0x4200000000000000000000000000000000000006",
      137 => "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619",
      8453 => "0x4200000000000000000000000000000000000006",
      42_161 => "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"
    }
  }

  # Reverse of @evm_tokens: chain id -> %{lowercase address -> symbol}. Lets a
  # served (chain, token) be classified back to its symbol, e.g. to detect a
  # same-asset corridor (same token both sides) before sizing a delivery floor.
  @symbol_by_address (for {symbol, by_chain} <- @evm_tokens,
                          {chain, address} <- by_chain,
                          reduce: %{} do
                        acc ->
                          Map.update(
                            acc,
                            chain,
                            %{address => symbol},
                            &Map.put(&1, address, symbol)
                          )
                      end)

  @doc """
  Look up decimals by chain id and ERC-20 contract address.

  Both `chain_id` integer and CAIP-2 string (`"eip155:8453"`) are
  accepted. Address case is normalized. Returns `@default_decimals`
  (`#{@default_decimals}`) when unknown.
  """
  @spec decimals(integer() | String.t() | nil, String.t() | nil) ::
          pos_integer()
  def decimals(chain_id, contract_address)
      when is_binary(contract_address) and contract_address != "" do
    chain = normalize_chain_id(chain_id)
    address = String.downcase(contract_address)

    @addresses
    |> Map.get(chain, %{})
    |> Map.get(address, @default_decimals)
  end

  def decimals(_chain, _contract), do: @default_decimals

  @doc """
  True when `address` is a known USDC contract on `chain_id`. Case-insensitive;
  accepts an integer chain id or a CAIP-2 string. EVM only.
  """
  @spec usdc?(integer() | String.t() | nil, String.t() | nil) :: boolean()
  def usdc?(chain_id, address) when is_binary(address) do
    chain = normalize_chain_id(chain_id)
    String.downcase(address) in Map.get(@usdc, chain, [])
  end

  def usdc?(_chain, _address), do: false

  @doc """
  True when `(chain_id, address)` is a registered contract, i.e. `decimals/2`
  returns a pinned value rather than the `@default_decimals` fallback. An
  unregistered token resolves to 6 decimals, which is wrong for an 18-decimal
  token like WETH. Case-insensitive; accepts an integer chain id or a CAIP-2
  string. EVM only.
  """
  @spec known?(integer() | String.t() | nil, String.t() | nil) :: boolean()
  def known?(chain_id, address) when is_binary(address) and address != "" do
    chain = normalize_chain_id(chain_id)
    Map.has_key?(Map.get(@addresses, chain, %{}), String.downcase(address))
  end

  def known?(_chain, _address), do: false

  @doc """
  Resolve a token symbol to its contract address on `chain_id`.

  Covers the solver-fillable set (USDC, USDT, WETH) across the five supported
  EVM chains (1, 10, 137, 8453, 42161). The symbol is case-insensitive; the
  chain id accepts an integer or a CAIP-2 string. Returns `:error` for an
  unknown `(chain, symbol)` pair.
  """
  @spec address(integer() | String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | :error
  def address(chain_id, symbol) when is_binary(symbol) do
    chain = normalize_chain_id(chain_id)

    case @evm_tokens |> Map.get(String.upcase(symbol), %{}) |> Map.get(chain) do
      nil -> :error
      address -> {:ok, address}
    end
  end

  def address(_chain, _symbol), do: :error

  @doc """
  The token symbols with a resolvable `address/2` (USDC, USDT, WETH).
  """
  @spec symbols() :: [String.t()]
  def symbols, do: Map.keys(@evm_tokens)

  @doc """
  Resolve a `(chain_id, contract_address)` back to its token symbol: the reverse
  of `address/2`. Covers the solver-fillable set (USDC, USDT, WETH) on the five
  EVM chains. Case-insensitive; accepts an integer chain id or a CAIP-2 string.
  Returns `nil` for an unregistered pair, so a caller can tell "same asset" from
  "unknown" without guessing.
  """
  @spec symbol_for(integer() | String.t() | nil, String.t() | nil) :: String.t() | nil
  def symbol_for(chain_id, address) when is_binary(address) and address != "" do
    chain = normalize_chain_id(chain_id)

    @symbol_by_address
    |> Map.get(chain, %{})
    |> Map.get(String.downcase(address))
  end

  def symbol_for(_chain, _address), do: nil

  @doc """
  Look up decimals by ticker symbol. Returns `@default_decimals`
  (`#{@default_decimals}`) when unknown. Case-insensitive.
  """
  @spec decimals(String.t() | nil) :: pos_integer()
  def decimals(ticker) when is_binary(ticker) do
    Map.get(@tickers, String.upcase(ticker), @default_decimals)
  end

  def decimals(_), do: @default_decimals

  @doc """
  Convert an atomic-unit amount to a human-decimal `Decimal.t/0`.

  E.g. `to_human(10_000, 6)` -> `Decimal.new("0.01")`.
  """
  @spec to_human(integer() | String.t() | Decimal.t(), pos_integer()) ::
          Decimal.t()
  def to_human(amount, decimals) when is_integer(decimals) and decimals > 0 do
    amount
    |> to_decimal()
    |> Decimal.div(pow10(decimals))
  end

  @doc """
  Convert a human-decimal amount to atomic units.

  E.g. `to_atomic("0.01", 6)` -> `10_000`.
  """
  @spec to_atomic(integer() | String.t() | Decimal.t(), pos_integer()) ::
          non_neg_integer()
  def to_atomic(amount, decimals) when is_integer(decimals) and decimals > 0 do
    amount
    |> to_decimal()
    |> Decimal.mult(pow10(decimals))
    |> Decimal.round(0, :down)
    |> Decimal.to_integer()
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp pow10(decimals), do: Decimal.new(Integer.pow(10, decimals))

  defp normalize_chain_id(id) when is_integer(id), do: id

  defp normalize_chain_id("eip155:" <> id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_chain_id(_), do: nil
end
