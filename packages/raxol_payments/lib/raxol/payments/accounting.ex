defmodule Raxol.Payments.Accounting do
  @moduledoc """
  Reads the settlement-accounting deployment contract from the environment.

  The accounting sidecar (a read-only container that books each Xochi settlement
  into `Raxol.Payments.SettlementLedger`) is configured entirely through env vars.
  Two deployments read the same contract: the main `raxol` release (root
  `config/runtime.exs`) and the slim `raxol_earn` sidecar release
  (`packages/raxol_earn/config/runtime.exs`). Both call `env_config/0` so the
  contract lives in one place and the two config files cannot drift.

  ## Contract

  | Env var                     | Meaning                                   | Default     |
  | --------------------------- | ----------------------------------------- | ----------- |
  | `RAXOL_ACCOUNTING_ENABLED`  | Start the ledger/accountant/monitor tree  | `false`     |
  | `RPC_ETH` .. `RPC_ROBINHOOD`| Per-chain public RPC URL (read-only)      | (unset)     |
  | `XOCHI_SOLVER_ADDRESS`      | Solver wallet to read balances for        | (unset)     |
  | `RAXOL_REBALANCE_INTERVAL_MS`| RebalanceMonitor sweep interval          | `300000`    |
  | `RAXOL_PRICE_SOURCE`        | USD price source for margin              | `coingecko` |
  | `RAXOL_REBALANCE_DEMAND_MULTIPLIER` | Demand-aware floors: `peak * this` | (unset/off) |
  | `RAXOL_REBALANCE_DEMAND_FLOOR_CAP`  | Ceiling on a demand-widened floor  | (unset)     |
  | `RAXOL_REBALANCE_DEMAND_WINDOW_MS`  | How far back demand is read        | `86400000`  |

  Demand-aware inventory floors are off unless `RAXOL_REBALANCE_DEMAND_MULTIPLIER`
  is set: floors then track the largest recent fill per corridor rather than a
  fixed number (`Raxol.Payments.RebalancePolicy.with_demand/2`). The multiplier and
  the cap are one setting: either alone refuses to boot, because `peak` is sized
  off orders anyone can place and an uncapped floor is unbounded in what it asks
  the auto-rebalancer to move. Those two are the only vars this module does not
  parse: it hands both on raw and unconditionally, because the pair rule can only
  be enforced by something that sees BOTH values on every call.

  SET BUT EMPTY reads as unset everywhere -- `FOO=` is what a fly.toml, a
  docker-compose file, or a cleared secret leaves behind. Every var parsed here
  reads it that way directly; the two demand knobs read it that way one layer
  down, in `with_demand/2`, which normalizes `""` to the same `nil` an unset var
  gives it.

  Beyond that, the vars parsed here refuse a value they do not recognize with a
  message naming themselves, because an operator has to be able to tell "my knob
  did nothing" from "the feature does nothing". Both halves are load-bearing:
  `RAXOL_PRICE_SOURCE=` used to yield the atom `:""`, which falls through
  `RebalanceMonitor`'s price-source catch-all and silently dropped USD pricing
  from the whole sweep, and `RAXOL_REBALANCE_INTERVAL_MS=` used to abort the boot
  with `String.to_integer/1`'s message, which names nothing.

  Two deliberate exceptions to that rule:

  `RAXOL_ACCOUNTING_ENABLED` is the gate, so it cannot refuse. It is read as
  exactly `"true"` and ANY other value -- including `"1"`, `"yes"` and `"TRUE"`
  -- means off. Refusing there would abort a release over a var whose only job
  is to say the subsystem is not running, which is the failure the rest of this
  section exists to prevent. Set it to the literal `"true"`.

  It does WARN on a value that is neither `"true"` nor empty, because otherwise
  "off" and "you typed `yes` and got off" are the same silence -- and telling
  those apart is what this whole section is for.

  And nothing else here is parsed AT ALL while that gate is off: `env_config/0`
  reads it first and returns an empty opts list, so a malformed value for a
  feature that is not running cannot take a boot down. The refusals below
  therefore only ever fire on a deployment that asked for the subsystem.

  Read-only by construction: no wallet key is read here and none of the started
  processes move funds (the Riddler auto-rebalancer executes; the monitor only
  recommends). Omitting `XOCHI_SOLVER_ADDRESS` yields ledger-only mode -- the
  `RebalanceMonitor` is not started (see `Raxol.Earn.Supervisor`).
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

  @default_rebalance_interval_ms 300_000
  @default_price_source :coingecko
  @default_demand_window_ms 86_400_000

  # The only sources `Raxol.Payments.RebalanceMonitor.build_price_fn/1` knows. Its
  # catch-all clause returns a price fn yielding nil, so an unrecognized value
  # here would disable USD pricing rather than fail, which is why this is an
  # allowlist and not `String.to_atom/1` -- that would also mint an atom, which is
  # never collected, from an operator-controlled string.
  @price_sources %{"coingecko" => :coingecko, "none" => :none}

  @typedoc "USD price source the `RebalanceMonitor` prices its margin column with."
  @type price_source :: :coingecko | :none

  @doc """
  Reads the accounting contract into the two config values a deployment sets.

  Returns `{accounting_opts, accounting_enabled?}` where `accounting_opts` is the
  keyword list for `config :raxol_payments, :accounting` and `accounting_enabled?`
  is the boolean for `config :raxol_earn, accounting_enabled:`.
  """
  @spec env_config() :: {keyword(), boolean()}
  def env_config do
    enabled? = enabled?()
    {accounting_opts(enabled?), enabled?}
  end

  # Parsed only when the subsystem is ON, and that ordering is the point.
  #
  # `config/runtime.exs` calls `env_config/0` unconditionally, and the readers
  # below refuse a value they do not recognize. Together those meant a typo in a
  # var belonging to a feature that is NOT RUNNING aborted the whole release
  # boot -- `RAXOL_PRICE_SOURCE=CoinGecko` with accounting off took down a node
  # that would never have priced anything.
  #
  # Nothing is lost by waiting. `Raxol.Earn.Supervisor` gates its entire
  # accounting tree on the second element of this tuple and reads these opts
  # only inside that branch, so an opts list nobody reads is exactly as useful
  # as one that was never built.
  @spec accounting_opts(boolean()) :: keyword()
  defp accounting_opts(false), do: []

  defp accounting_opts(true) do
    [
      rpc_urls: rpc_urls(),
      solver_address: solver_address(),
      rebalance_interval_ms: rebalance_interval_ms(),
      price_source: price_source(),
      demand_multiplier: System.get_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER"),
      demand_floor_cap: System.get_env("RAXOL_REBALANCE_DEMAND_FLOOR_CAP"),
      demand_window_ms: demand_window_ms()
    ]
  end

  @doc """
  True when `RAXOL_ACCOUNTING_ENABLED` is exactly `"true"`.

  A value that is neither `"true"` nor empty is still OFF, and still does not
  raise -- this is the gate, so refusing here would abort a release over a
  variable whose only job is to say the subsystem is not running. But it WARNS,
  because "off" and "you typed `yes` and got off" are the same silence
  otherwise, and this module's whole posture is that an operator must be able to
  tell "my knob did nothing" from "the feature does nothing".
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("RAXOL_ACCOUNTING_ENABLED", "") |> String.trim() do
      "true" -> true
      "" -> false
      other -> warn_unrecognized_gate(other)
    end
  end

  defp warn_unrecognized_gate(value) do
    require Logger

    Logger.warning(
      "RAXOL_ACCOUNTING_ENABLED is #{inspect(value)}, which is not \"true\", so " <>
        "settlement accounting is OFF. It is matched exactly: \"1\", \"yes\" and " <>
        "\"TRUE\" all mean off. Set it to the literal \"true\" to enable."
    )

    false
  end

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

  # A wallet address is opaque to this module, so "unset" is all it can decide;
  # blank has to be one, because `Raxol.Earn.Supervisor` branches on truthiness
  # and `""` is truthy in Elixir. `XOCHI_SOLVER_ADDRESS=` would otherwise start
  # the `RebalanceMonitor` reading balances for the empty address.
  @spec solver_address() :: String.t() | nil
  defp solver_address do
    "XOCHI_SOLVER_ADDRESS"
    |> System.get_env("")
    |> String.trim()
    |> case do
      "" -> nil
      address -> address
    end
  end

  @spec rebalance_interval_ms() :: pos_integer()
  defp rebalance_interval_ms do
    env_milliseconds("RAXOL_REBALANCE_INTERVAL_MS", @default_rebalance_interval_ms)
  end

  # Matched case-INSENSITIVELY. The module this names is spelled
  # `Raxol.Payments.Prices.CoinGecko` and the vendor spells itself CoinGecko, so
  # the mis-cased value is the natural one for an operator to type, and refusing
  # it would fail a boot over the shape of a word rather than its meaning.
  @spec price_source() :: price_source()
  defp price_source do
    "RAXOL_PRICE_SOURCE"
    |> System.get_env("")
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> @default_price_source
      value -> known_price_source(value)
    end
  end

  @spec known_price_source(String.t()) :: price_source()
  defp known_price_source(value) do
    case Map.fetch(@price_sources, value) do
      {:ok, source} ->
        source

      :error ->
        raise ArgumentError,
              "RAXOL_PRICE_SOURCE must be one of #{Enum.join(Map.keys(@price_sources), ", ")}, " <>
                "or empty for the #{@default_price_source} default. An unrecognized source " <>
                "prices nothing, so the sweep would report every corridor without USD " <>
                "notionals. Got: #{inspect(value)}"
    end
  end

  # How far back demand is read. Zero or negative would make the window select
  # nothing (or the whole ledger), which the pos_integer() spec already says is
  # not a value.
  @spec demand_window_ms() :: pos_integer()
  defp demand_window_ms do
    env_milliseconds("RAXOL_REBALANCE_DEMAND_WINDOW_MS", @default_demand_window_ms)
  end

  # Blank means unset (the same reading `rpc_urls/0` gives `FOO=`), and anything
  # that is not a positive integer of milliseconds fails NAMING the variable: both
  # of these are documented as optional, so `String.to_integer/1`'s "not a textual
  # representation of an integer" would crash a boot without saying which knob did
  # it.
  @spec env_milliseconds(String.t(), pos_integer()) :: pos_integer()
  defp env_milliseconds(var, default) when is_integer(default) and default > 0 do
    var
    |> System.get_env("")
    |> String.trim()
    |> case do
      "" -> default
      value -> positive_integer(value, var, default)
    end
  end

  @spec positive_integer(String.t(), String.t(), pos_integer()) :: pos_integer()
  defp positive_integer(value, var, default) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 ->
        ms

      _ ->
        raise ArgumentError,
              "#{var} must be a positive whole number of milliseconds " <>
                "(e.g. \"#{default}\"), or empty for the #{default} default. " <>
                "Got: #{inspect(value)}"
    end
  end
end
