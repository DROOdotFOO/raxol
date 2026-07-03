defmodule Raxol.Payments.Accounting do
  @moduledoc """
  Reads the settlement-accounting deployment contract from the environment.

  The accounting sidecar (a read-only container that books each Xochi settlement
  into `Raxol.Payments.SettlementLedger`) is configured entirely through env vars.
  Two deployments read the same contract: the main `raxol` release (root
  `config/runtime.exs`) and the slim `raxol_acp` sidecar release
  (`packages/raxol_acp/config/runtime.exs`). Both call `env_config/0` so the
  contract lives in one place and the two config files cannot drift.

  ## Contract

  | Env var                     | Meaning                                   | Default     |
  | --------------------------- | ----------------------------------------- | ----------- |
  | `RAXOL_ACCOUNTING_ENABLED`  | Start the ledger/accountant/monitor tree  | `false`     |
  | `RPC_ETH` .. `RPC_ROBINHOOD`| Per-chain public RPC URL (read-only)      | (unset)     |
  | `XOCHI_SOLVER_ADDRESS`      | Solver wallet to read balances for        | (unset)     |
  | `RAXOL_REBALANCE_INTERVAL_MS`| RebalanceMonitor sweep interval          | `300000`    |
  | `RAXOL_PRICE_SOURCE`        | USD price source for margin              | `coingecko` |

  Read-only by construction: no wallet key is read here and none of the started
  processes move funds (the Riddler auto-rebalancer executes; the monitor only
  recommends). Omitting `XOCHI_SOLVER_ADDRESS` yields ledger-only mode -- the
  `RebalanceMonitor` is not started (see `Raxol.ACP.Supervisor`).
  """

  # Chain id => env var holding that chain's RPC URL.
  @rpc_env %{
    1 => "RPC_ETH",
    10 => "RPC_OPTIMISM",
    137 => "RPC_POLYGON",
    8453 => "RPC_BASE",
    42_161 => "RPC_ARBITRUM",
    4663 => "RPC_ROBINHOOD"
  }

  @default_rebalance_interval_ms "300000"
  @default_price_source "coingecko"

  @doc """
  Reads the accounting contract into the two config values a deployment sets.

  Returns `{accounting_opts, accounting_enabled?}` where `accounting_opts` is the
  keyword list for `config :raxol_payments, :accounting` and `accounting_enabled?`
  is the boolean for `config :raxol_acp, accounting_enabled:`.
  """
  @spec env_config() :: {keyword(), boolean()}
  def env_config do
    accounting = [
      rpc_urls: rpc_urls(),
      solver_address: System.get_env("XOCHI_SOLVER_ADDRESS"),
      rebalance_interval_ms: rebalance_interval_ms(),
      price_source: price_source()
    ]

    {accounting, enabled?()}
  end

  @doc "True when `RAXOL_ACCOUNTING_ENABLED` is exactly `\"true\"`."
  @spec enabled?() :: boolean()
  def enabled?,
    do: System.get_env("RAXOL_ACCOUNTING_ENABLED", "false") == "true"

  # Only chains with a non-empty RPC URL are included, so a partial deployment
  # (say, Base + Optimism only) reads just those corridors.
  @spec rpc_urls() :: %{optional(pos_integer()) => String.t()}
  defp rpc_urls do
    @rpc_env
    |> Enum.reduce(%{}, fn {chain_id, env_var}, acc ->
      case System.get_env(env_var) do
        url when is_binary(url) and url != "" -> Map.put(acc, chain_id, url)
        _ -> acc
      end
    end)
  end

  @spec rebalance_interval_ms() :: pos_integer()
  defp rebalance_interval_ms do
    String.to_integer(
      System.get_env("RAXOL_REBALANCE_INTERVAL_MS") ||
        @default_rebalance_interval_ms
    )
  end

  @spec price_source() :: atom()
  defp price_source do
    String.to_atom(
      System.get_env("RAXOL_PRICE_SOURCE") || @default_price_source
    )
  end
end
