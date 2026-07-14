defmodule Raxol.ACP.Xochi.CapacityDeriver do
  @moduledoc """
  Reads the Xochi/Riddler solver's on-chain token balances and projects them into
  offering caps. Shared by the `raxol_acp.derive_caps` mix task (one-shot) and
  `Raxol.ACP.Xochi.CapacityRefresher` (periodic, at runtime).

  `derive/1` does the network reads (one `balanceOf` eth_call per `{chain, token}`
  in `Raxol.Payments.Assets.evm_tokens/0`); `capacity_map/1` and `caps_map/1`
  project the rows into `%{{chain, token} => atomic}` maps for
  `Raxol.ACP.Xochi.CapacityLedger.load/2` (aggregate) and the `:destination_caps`
  config (per-order). A corridor worth less than `:min_usd` projects to `0`
  (closed); a chain with no reachable RPC is skipped, never silently zeroed.

  RPC per chain: `DERIVE_RPC_<chain_id>` env var, else a public default (Robinhood
  4663 has none -- set `DERIVE_RPC_4663`).
  """

  @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"
  @balance_of_selector "0x70a08231"

  @default_rpc %{
    1 => "https://eth.llamarpc.com",
    10 => "https://mainnet.optimism.io",
    137 => "https://polygon-rpc.com",
    8453 => "https://mainnet.base.org",
    42_161 => "https://arb1.arbitrum.io/rpc"
  }

  @type row :: %{
          chain: pos_integer(),
          token: String.t(),
          symbol: String.t(),
          raw: non_neg_integer(),
          usd: float()
        }

  @doc "Read `balanceOf(solver)` for every known `{chain, token}`. Network."
  @spec derive(keyword()) :: [row()]
  def derive(opts \\ []) do
    solver = opts |> Keyword.get(:solver, @canonical_solver) |> String.downcase()
    eth_price = Keyword.get(opts, :eth_price, 1877.0)
    warn = Keyword.get(opts, :warn, &default_warn/1)

    for {symbol, by_chain} <- Raxol.Payments.Assets.evm_tokens(),
        {chain, token} <- by_chain,
        row = balance_row(chain, token, symbol, solver, eth_price, warn),
        row != nil do
      row
    end
  end

  @doc "Aggregate-capacity map for `CapacityLedger.load/2` (aggregate frac). Network."
  @spec capacity_map(keyword()) :: %{{pos_integer(), String.t()} => non_neg_integer()}
  def capacity_map(opts \\ []) do
    project(
      derive(opts),
      Keyword.get(opts, :aggregate_frac, 0.9),
      Keyword.get(opts, :min_usd, 50.0)
    )
  end

  @doc "Per-order caps map for the `:destination_caps` config (order frac). Network."
  @spec caps_map(keyword()) :: %{{pos_integer(), String.t()} => non_neg_integer()}
  def caps_map(opts \\ []) do
    project(derive(opts), Keyword.get(opts, :order_frac, 0.2), Keyword.get(opts, :min_usd, 50.0))
  end

  @doc "Pure projection: rows -> `%{{chain, token} => cap}` at `frac`, closing sub-`min_usd`."
  @spec project([row()], float(), float()) :: %{{pos_integer(), String.t()} => non_neg_integer()}
  def project(rows, frac, min_usd) do
    Map.new(rows, fn row -> {{row.chain, row.token}, cap_value(row, frac, min_usd)} end)
  end

  @doc "The cap for one row: `0` when worth less than `min_usd`, else `floor(raw * frac)`."
  @spec cap_value(row(), float(), float()) :: non_neg_integer()
  def cap_value(row, frac, min_usd) do
    if row.usd < min_usd, do: 0, else: trunc(row.raw * frac)
  end

  @doc "RPC endpoint for a chain (`DERIVE_RPC_<chain>` env, else a public default)."
  @spec rpc_url(pos_integer()) :: String.t() | nil
  def rpc_url(chain), do: System.get_env("DERIVE_RPC_#{chain}") || Map.get(@default_rpc, chain)

  # -- Internal --

  defp balance_row(chain, token, symbol, solver, eth_price, warn) do
    case rpc_url(chain) do
      nil ->
        warn.("skip #{symbol} on #{chain}: no RPC (set DERIVE_RPC_#{chain})")
        nil

      url ->
        case balance_of(url, token, solver) do
          {:ok, raw} ->
            decimals = Raxol.Payments.Assets.decimals(chain, token)
            usd = raw / :math.pow(10, decimals) * unit_price(symbol, eth_price)
            %{chain: chain, token: token, symbol: symbol, raw: raw, usd: usd}

          {:error, reason} ->
            warn.("skip #{symbol} on #{chain}: #{inspect(reason)}")
            nil
        end
    end
  end

  defp balance_of(url, token, owner) do
    data = @balance_of_selector <> String.pad_leading(strip0x(owner), 64, "0")

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "eth_call",
      "params" => [%{"to" => token, "data" => data}, "latest"]
    }

    case Req.post(url, json: payload, receive_timeout: 20_000, retry: false) do
      {:ok, %{status: 200, body: %{"result" => "0x" <> hex}}} when hex != "" ->
        {:ok, String.to_integer(hex, 16)}

      {:ok, %{status: 200, body: %{"error" => err}}} ->
        {:error, err}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unit_price("WETH", eth_price), do: eth_price
  defp unit_price(_stable, _eth_price), do: 1.0

  defp strip0x("0x" <> rest), do: rest
  defp strip0x(hex), do: hex

  defp default_warn(msg), do: IO.puts(:stderr, "[capacity_deriver] " <> msg)
end
