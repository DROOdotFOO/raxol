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
  addresses lowercase. A stablecoin pegged to a currency other than the
  dollar goes in `@fx_stables` instead, which feeds both lookups and
  `fx_peg/2`. Tests in `test/raxol/payments/assets_test.exs` pin the known
  set.
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
    # Robinhood Chain (Arbitrum Orbit L2, native gas ETH)
    4663 => %{
      # USDG (Global Dollar, Paxos) -- the chain's native stablecoin
      "0x5fc5360d0400a0fd4f2af552add042d716f1d168" => 6,
      # WETH
      "0x0bd7d308f8e1639fab988df18a8011f41eacad73" => 18,
      # RAXOL -- volatile, transfer-fee token (taxes transfers with its v2 pair)
      "0xf44702b17d9abd53815f703e772f35e9c71a53af" => 18
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

  # Circle USDC on the EVM testnets the live Xochi gate runs against (the same
  # contracts `Assets.UsdcDomains` pins). Registered for decimals and symbol
  # only: they are deliberately NOT in @evm_tokens or @usdc, so they never join
  # `supported_chain_ids/0`, the capabilities fallback, or advertised corridors.
  @testnet_usdc %{
    11_155_111 => "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238",
    11_155_420 => "0x5fd84259d66cd46123540766be93dfe6d43130d7",
    84_532 => "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
    421_614 => "0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d"
  }

  @addresses Map.merge(
               @addresses,
               Map.new(@testnet_usdc, fn {chain, addr} -> {chain, %{addr => 6}} end)
             )

  # Stablecoins pegged to a currency other than the dollar (ADR-0040 decision 6):
  # symbol -> peg currency, decimals, canonical contract per chain, and legacy
  # contracts per chain. Every address was read on-chain (`symbol()`,
  # `decimals()`) on 2026-09-30.
  #
  # Registered for scaling and recognition only. They are not solver-fillable
  # (that is `@evm_tokens`), and no fund-moving path spends or delivers one
  # until an FX rate gates the conversion: a dollar spend cap would otherwise
  # count 1 EURe as $1. `fx_peg/2` is how those paths refuse them.
  #
  # EURe's v1 contracts front the same balance as v2 (equal `totalSupply()` on
  # each chain), so they resolve back to "EURe" but `address/2` never returns
  # one: summing both would count every euro twice. EURC has no native issuance
  # on 10, 137, 100 or 42161, and the EURC-named token on Optimism is bridged,
  # so it is deliberately absent. ZCHF on the L2s is the CCIP-bridged token,
  # which has one address on all of them.
  @zchf_ccip "0xd4dd9e2f021bb459d5a5f6c24c12fe09c5d45553"

  @fx_stables %{
    "EURC" => %{
      peg: "EUR",
      decimals: 6,
      addresses: %{
        1 => "0x1abaea1f7c830bd89acc67ec4af516284b1bc33c",
        8453 => "0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42"
      },
      legacy: %{}
    },
    "EURe" => %{
      peg: "EUR",
      decimals: 18,
      addresses: %{
        1 => "0x39b8b6385416f4ca36a20319f70d28621895279d",
        100 => "0x420ca0f9b9b604ce0fd9c18ef134c705e5fa3430",
        137 => "0xe0aea583266584dafbb3f9c3211d5588c73fea8d",
        8453 => "0xbf6e2966a9c3d99c9e4d069e04f7bdb9c8aa762c",
        42_161 => "0x0c06ccf38114ddfc35e07427b9424adcca9f44f8"
      },
      legacy: %{
        1 => "0x3231cb76718cdef2155fc47b5286d82e6eda273f",
        100 => "0xcb444e90d8198415266c6a2724b7900fb12fc56e",
        137 => "0x18ec0a6e18e5bc3784fdd3a3634b31245ab704f6"
      }
    },
    "ZCHF" => %{
      peg: "CHF",
      decimals: 18,
      addresses: %{
        1 => "0xb58e61c3098d85632df34eecfb899a1ed80921cb",
        10 => @zchf_ccip,
        100 => @zchf_ccip,
        137 => @zchf_ccip,
        8453 => @zchf_ccip,
        42_161 => @zchf_ccip
      },
      legacy: %{}
    }
  }

  # chain id -> lowercase address -> {symbol, peg, decimals}, canonical and
  # legacy contracts alike.
  @fx_by_address (for {symbol, spec} <- @fx_stables,
                      {chain, address} <-
                        Map.to_list(spec.addresses) ++ Map.to_list(spec.legacy),
                      reduce: %{} do
                    acc ->
                      entry = {symbol, spec.peg, spec.decimals}
                      Map.update(acc, chain, %{address => entry}, &Map.put(&1, address, entry))
                  end)

  # Upcased symbol -> chain id -> canonical address, for `address/2`.
  @fx_addresses Map.new(@fx_stables, fn {symbol, spec} ->
                  {String.upcase(symbol), spec.addresses}
                end)

  # What the decimals lookups read: `@addresses` plus every FX stablecoin.
  @registered_decimals Map.merge(
                         @addresses,
                         Map.new(@fx_by_address, fn {chain, by_address} ->
                           {chain,
                            Map.new(by_address, fn {address, {_symbol, _peg, decimals}} ->
                              {address, decimals}
                            end)}
                         end),
                         fn _chain, usd, fx -> Map.merge(usd, fx) end
                       )

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

  # Currency ticker fallback for protocols that don't carry an address. Keys are
  # upcased because lookups upcase the ticker. The non-USD stablecoins join
  # through @ticker_decimals ("EURe" resolves via "EURE").
  @tickers %{
    "USDC" => 6,
    "USDT" => 6,
    "USDBC" => 6,
    "USDG" => 6,
    "PYUSD" => 6,
    "DAI" => 18,
    "ETH" => 18,
    "WETH" => 18,
    "RAXOL" => 18
  }

  @ticker_decimals Map.merge(
                     @tickers,
                     Map.new(@fx_stables, fn {symbol, spec} ->
                       {String.upcase(symbol), spec.decimals}
                     end)
                   )

  # Solver-fillable EVM tokens: symbol -> chain id -> lowercase address. Mirrors
  # Riddler's config/token_registry.ex for the six supported EVM chains
  # (Ethereum, Optimism, Polygon, Base, Arbitrum, Robinhood Chain). Decimals live
  # in `@addresses`. USDG is Robinhood Chain's native stablecoin (Permit2 pull,
  # no ERC-3009); WETH is also canonical there. RAXOL (Robinhood Chain) is
  # volatile, so it is not a dollar stablecoin. EURe is solver-fillable on
  # Arbitrum but lives in @fx_stables, not here: no fund-moving path spends or
  # delivers a non-USD stablecoin without an FX bound (ADR-0040 decision 6).
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
    "USDG" => %{
      4663 => "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
    },
    "RAXOL" => %{
      4663 => "0xf44702b17d9abd53815f703e772f35e9c71a53af"
    },
    "WETH" => %{
      1 => "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
      10 => "0x4200000000000000000000000000000000000006",
      137 => "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619",
      8453 => "0x4200000000000000000000000000000000000006",
      42_161 => "0x82af49447d8a07e3bd95bd0d56f35241523fbab1",
      4663 => "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
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
                     |> Map.merge(
                       Map.new(@testnet_usdc, fn {chain, addr} -> {chain, %{addr => "USDC"}} end)
                     )

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

    @registered_decimals
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
  The chain ids on which a USDC contract is registered, ascending.

  Single source of truth for the USDC settlement mesh; callers that advertise
  the supported chains (e.g. an offering's requirement schema) derive them from
  here instead of re-declaring the set, so they cannot drift from `usdc?/2`.
  """
  @spec usdc_chains() :: [pos_integer()]
  def usdc_chains, do: @usdc |> Map.keys() |> Enum.sort()

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
    Map.has_key?(Map.get(@registered_decimals, chain, %{}), String.downcase(address))
  end

  def known?(_chain, _address), do: false

  @doc """
  Strict `decimals/2`: `{:ok, decimals}` for a registered `(chain_id, address)`,
  `:error` otherwise. Fund-moving paths use this instead of `decimals/2`, whose
  6-decimal fallback would mis-scale an unregistered token's amount.
  """
  @spec fetch_decimals(integer() | String.t() | nil, String.t() | nil) ::
          {:ok, pos_integer()} | :error
  def fetch_decimals(chain_id, address) when is_binary(address) and address != "" do
    @registered_decimals
    |> Map.get(normalize_chain_id(chain_id), %{})
    |> Map.fetch(String.downcase(address))
  end

  def fetch_decimals(_chain, _address), do: :error

  @doc """
  Resolve a token symbol to its contract address on `chain_id`.

  Covers the solver-fillable set (USDC, USDT, WETH, plus USDG and RAXOL on
  Robinhood Chain) across the six supported EVM chains (1, 10, 137, 8453,
  42161, 4663), and the non-USD stablecoins (EURC, EURe, ZCHF), for which it
  returns the canonical contract and never a legacy one. The symbol is
  case-insensitive (`"EURe"`, `"eure"` and `"EURE"` all resolve); the chain id
  accepts an integer or a CAIP-2 string. Returns `:error` for an unknown
  `(chain, symbol)` pair.
  """
  @spec address(integer() | String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | :error
  def address(chain_id, symbol) when is_binary(symbol) do
    chain = normalize_chain_id(chain_id)
    key = fold_symbol(symbol)
    by_chain = Map.get(@evm_tokens, key) || Map.get(@fx_addresses, key, %{})

    case Map.get(by_chain, chain) do
      nil -> :error
      address -> {:ok, address}
    end
  end

  def address(_chain, _symbol), do: :error

  @doc """
  The solver-fillable token symbols (RAXOL, USDC, USDG, USDT, WETH). The non-USD
  stablecoins resolve through `address/2` too, but are not solver-fillable, so
  they are not listed here.
  """
  @spec symbols() :: [String.t()]
  def symbols, do: Map.keys(@evm_tokens)

  # Human-readable names for the supported EVM chains, matching Riddler's
  # `config/chain_registry.ex` naming.
  @chain_names %{
    1 => "Ethereum",
    10 => "Optimism",
    100 => "Gnosis",
    137 => "Polygon",
    8453 => "Base",
    42_161 => "Arbitrum One",
    4663 => "Robinhood Chain"
  }

  @doc """
  The EVM chain ids covered by the solver-fillable table, ascending. This is
  the static universe `Raxol.Payments.Xochi.Capabilities.fallback/0` derives
  from; live corridor availability comes from the capabilities endpoint.
  """
  @spec supported_chain_ids() :: [pos_integer()]
  def supported_chain_ids do
    @evm_tokens
    |> Enum.flat_map(fn {_symbol, by_chain} -> Map.keys(by_chain) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Every EVM chain id this registry knows: the mainnet `supported_chain_ids/0`
  plus the registered testnets. The set an EVM-only feature (ERC-5564 stealth)
  may target; Tron and unregistered chains are outside it.
  """
  @spec evm_chain_ids() :: [pos_integer()]
  def evm_chain_ids, do: Enum.sort(supported_chain_ids() ++ Map.keys(@testnet_usdc))

  @doc "Human-readable chain name, or `\"Chain <id>\"` when unknown."
  @spec chain_name(integer() | String.t() | nil) :: String.t()
  def chain_name(chain_id) do
    chain = normalize_chain_id(chain_id)
    Map.get(@chain_names, chain, "Chain #{inspect(chain)}")
  end

  @doc """
  The solver-fillable token table: symbol -> chain id -> lowercase address.
  Exposed for fallback derivation; prefer `known?/2` / `address/2` for
  lookups.
  """
  @spec evm_tokens() :: %{String.t() => %{pos_integer() => String.t()}}
  def evm_tokens, do: @evm_tokens

  @doc """
  Resolve a `(chain_id, contract_address)` back to its token symbol: the reverse
  of `address/2`. Covers the solver-fillable set (USDC, USDT, WETH, plus USDG and
  RAXOL on Robinhood Chain) on the six EVM chains, and the non-USD stablecoins,
  where a legacy EURe contract also resolves to `"EURe"`. The returned symbol is
  the exact wire spelling. Case-insensitive; accepts an integer chain id or a
  CAIP-2 string. Returns `nil` for an unregistered pair, so a caller can tell
  "same asset" from "unknown" without guessing.
  """
  @spec symbol_for(integer() | String.t() | nil, String.t() | nil) :: String.t() | nil
  def symbol_for(chain_id, address) when is_binary(address) and address != "" do
    chain = normalize_chain_id(chain_id)
    address = String.downcase(address)

    case @symbol_by_address |> Map.get(chain, %{}) |> Map.get(address) do
      nil -> fx_symbol(chain, address)
      symbol -> symbol
    end
  end

  def symbol_for(_chain, _address), do: nil

  @doc """
  The peg currency of a registered non-USD stablecoin at `(chain_id, address)`:
  `"EUR"` for EURC and either EURe contract, `"CHF"` for ZCHF. `nil` for
  anything else, dollar stablecoins, WETH and unregistered tokens included.
  Case-insensitive; accepts an integer chain id or a CAIP-2 string.

  Fund-moving paths refuse a token with a peg until an FX rate gates the
  conversion (ADR-0040 decision 7). Its decimals are known, so its amount
  scales correctly, but a dollar-denominated spend cap would count it at par.
  """
  @spec fx_peg(integer() | String.t() | nil, String.t() | nil) :: String.t() | nil
  def fx_peg(chain_id, address) when is_binary(address) and address != "" do
    case fx_entry(normalize_chain_id(chain_id), String.downcase(address)) do
      {_symbol, peg, _decimals} -> peg
      nil -> nil
    end
  end

  def fx_peg(_chain, _address), do: nil

  @fx_pegs Map.new(@fx_stables, fn {symbol, spec} -> {symbol, spec.peg} end)

  @doc """
  Every registered non-USD stablecoin's symbol and peg currency:
  `%{"EURC" => "EUR", "EURe" => "EUR", "ZCHF" => "CHF"}`. The set an FX
  `price_fn` answers for, at the rate for this peg and no other (ADR-0040
  decision 6).
  """
  @spec fx_pegs() :: %{String.t() => String.t()}
  def fx_pegs, do: @fx_pegs

  @doc """
  The case-insensitive form of a token symbol: upper-cased in ASCII only, so a
  lookalike such as `uſdc` (long s) or `EURı` (dotless i) stays itself rather
  than folding onto a registered symbol. Every symbol lookup here, and the FX
  `price_fn`, compares in this form.
  """
  @spec fold_symbol(String.t()) :: String.t()
  def fold_symbol(symbol) when is_binary(symbol), do: String.upcase(symbol, :ascii)

  defp fx_symbol(chain, address) do
    case fx_entry(chain, address) do
      {symbol, _peg, _decimals} -> symbol
      nil -> nil
    end
  end

  defp fx_entry(chain, address), do: @fx_by_address |> Map.get(chain, %{}) |> Map.get(address)

  # Native gas token per chain: the asset the solver spends on fills and which the
  # rebalance policy/advisor track and refuel. The symbol distinguishes ETH from
  # POL (Polygon) so gas can be priced; all supported EVM chains use 18-decimal
  # native.
  @native_tokens %{
    1 => {"ETH", 18},
    10 => {"ETH", 18},
    # Gnosis settles gas in xDAI.
    100 => {"XDAI", 18},
    137 => {"POL", 18},
    8453 => {"ETH", 18},
    42_161 => {"ETH", 18},
    # Robinhood Chain (Arbitrum Orbit L2) settles gas in ETH.
    4663 => {"ETH", 18}
  }

  @doc """
  The native gas token symbol for `chain_id` (e.g. `"ETH"`, `"POL"`). Accepts an
  integer chain id or a CAIP-2 string; returns `nil` for an unknown chain.
  """
  @spec native_symbol(integer() | String.t() | nil) :: String.t() | nil
  def native_symbol(chain_id) do
    case Map.get(@native_tokens, normalize_chain_id(chain_id)) do
      {symbol, _decimals} -> symbol
      nil -> nil
    end
  end

  @doc """
  The native gas token decimals for `chain_id`. Every supported EVM chain uses
  18; unknown chains default to 18.
  """
  @spec native_decimals(integer() | String.t() | nil) :: pos_integer()
  def native_decimals(chain_id) do
    case Map.get(@native_tokens, normalize_chain_id(chain_id)) do
      {_symbol, decimals} -> decimals
      nil -> 18
    end
  end

  @doc """
  Look up decimals by ticker symbol. Returns `@default_decimals`
  (`#{@default_decimals}`) when unknown. Case-insensitive.
  """
  @spec decimals(String.t() | nil) :: pos_integer()
  def decimals(ticker) when is_binary(ticker) do
    Map.get(@ticker_decimals, fold_symbol(ticker), @default_decimals)
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

  # The widest on-chain token amount (a uint256, e.g. ERC-3009's `value`), and
  # its length in decimal digits.
  @max_uint256 Integer.pow(2, 256) - 1
  @max_uint256_digits 78

  @doc """
  Parse a positive atomic-unit amount from a payment challenge: a positive
  integer, or a string of digits, no larger than a uint256. Returns
  `{:ok, integer}` or `:error`.

  No wider amount can be signed on-chain. A string longer than 78 bytes is
  refused before it is parsed, so a server cannot make the client parse a
  header-sized number, and an accepted amount always takes `to_decimal/1`'s
  integer route.
  """
  @spec parse_atomic(term()) :: {:ok, pos_integer()} | :error
  def parse_atomic(amount)
      when is_integer(amount) and amount > 0 and amount <= @max_uint256,
      do: {:ok, amount}

  def parse_atomic(amount) when is_binary(amount) and byte_size(amount) <= @max_uint256_digits do
    case Integer.parse(amount) do
      {n, ""} when n > 0 and n <= @max_uint256 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_atomic(_amount), do: :error

  @doc """
  Convert an amount to a `Decimal.t/0`. A `Decimal` passes through, an integer
  converts exactly, and a string goes through `Decimal.new/1`, except a string
  of at most 78 bytes that parses fully as an integer, which converts through
  that integer.

  decimal 3's string parse rejects more than 34 digits, and an atomic amount of
  an 18-decimal token can be wider, so without the integer route a
  server-supplied atomic string would raise where the same integer converts.
  The 78-byte bound (a uint256) keeps a hostile string from becoming a
  `Decimal` too wide to render (`Decimal.to_string/2` stops at 6_178 digits):
  a longer string raises `Decimal.Error`, as a malformed one does.
  """
  @spec to_decimal(integer() | String.t() | Decimal.t()) :: Decimal.t()
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)

  def to_decimal(s) when is_binary(s) and byte_size(s) <= @max_uint256_digits do
    case Integer.parse(s) do
      {n, ""} -> Decimal.new(n)
      _ -> Decimal.new(s)
    end
  end

  def to_decimal(s) when is_binary(s), do: Decimal.new(s)

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
