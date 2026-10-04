defmodule Raxol.Web3.MCP.FXTools do
  @moduledoc """
  The served FX surface: three read tools over a `Raxol.Web3.FX` handle
  (ADR-0040 decision 5).

  `web3_fx_stables`, `web3_fx_stable` and `web3_fx_corridors` keep the
  package's `web3_` prefix, which does real work: `Raxol.MCP.Registry`
  overwrites a duplicate name silently.

  Every asset in a result carries OUR verdict (`quality`), judged against
  Chainlink, beside Sleuth's own figures under `sleuth_` names. Figures are
  strings, not JSON numbers (`Raxol.Web3.Serialize.result/1`), so nothing
  downstream gets a float.

  Like `Raxol.Web3.MCP.Tools`, every tool is `readOnlyHint: true` and
  `sensitive: true`: it spends an operator's Sleuth key and RPC budget, so
  `Raxol.MCP.Server` refuses to serve it without an authorizer. Errors are
  `Raxol.Web3.Serialize.error/1` codes and carry no upstream text.
  """

  alias Raxol.MCP.Registry
  alias Raxol.Web3.FX
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Serialize

  @tools [
    {"web3_fx_stables",
     "A page of fiat-pegged stablecoins with price, supply, volume and a peg verdict " <>
       "(ok, suspect, no_rate, yield_bearing) judged against Chainlink FX rates.",
     [
       {"corridor", "string", "Peg currency, e.g. \"EUR\", \"USD\", \"CHF\"."},
       {"partner_only", "boolean", "Only USDT, USDC, EURC, EURe and ZCHF."},
       {"exclude_yield_bearing", "boolean", "Drop yield-bearing tokens."},
       {"sort", "string",
        "One of supplyUsd, volume24hUsd, deviationBps, partnerLiquidityUsd, marketCapUsd."},
       {"limit", "integer", "1 to 300, default 100."},
       {"offset", "integer", "Page offset, default 0."}
     ], []},
    {"web3_fx_stable", "One stablecoin with its top pools and a peg verdict.",
     [{"symbol", "string", "Ticker, e.g. \"EURC\" or \"EURe\"."}], ["symbol"]},
    {"web3_fx_corridors", "Supply, volume and liquidity totals per peg currency.",
     [{"include_assets", "boolean", "Include each corridor's largest assets."}], []}
  ]

  @doc "The names of every tool this module serves."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, &elem(&1, 0))

  @doc "Tool definitions bound to an FX handle."
  @spec tool_defs(FX.t()) :: [Registry.tool_def()]
  def tool_defs(%FX{} = fx) do
    Enum.map(@tools, fn {name, description, args, required} ->
      %{
        name: name,
        description: description,
        inputSchema: %{
          "type" => "object",
          "properties" =>
            Map.new(args, fn {n, t, d} -> {n, %{"type" => t, "description" => d}} end),
          "required" => required
        },
        annotations: %{readOnlyHint: true, sensitive: true},
        fault?: &Tools.fault?/1,
        callback: fn arguments -> dispatch(fx, name, arguments) end
      }
    end)
  end

  @doc "Register every tool with a `Raxol.MCP.Registry`, all or nothing."
  @spec register(GenServer.server(), FX.t()) :: :ok | {:error, term()}
  def register(registry, %FX{} = fx), do: Registry.register_all(registry, tools: tool_defs(fx))

  @doc false
  # Shared with `Raxol.Agent.Actions.FX`, which serves the same three reads.
  @spec dispatch(FX.t(), String.t(), map()) :: {:ok, term()} | {:error, map()}
  def dispatch(fx, name, arguments) do
    case run(fx, name, arguments || %{}) do
      {:ok, result} -> {:ok, Serialize.result(result)}
      {:error, reason} -> {:error, Serialize.error(reason)}
    end
  end

  defp run(fx, "web3_fx_stables", arguments) do
    with {:ok, opts} <- stables_opts(arguments), do: FX.stables(fx, opts)
  end

  defp run(fx, "web3_fx_stable", arguments) do
    case get(arguments, "symbol") do
      symbol when is_binary(symbol) -> FX.stable(fx, symbol)
      nil -> {:error, {:missing_argument, "symbol"}}
      _other -> {:error, {:invalid_argument, "symbol"}}
    end
  end

  defp run(fx, "web3_fx_corridors", arguments) do
    case get(arguments, "include_assets") do
      value when value in [nil, false] -> FX.corridors(fx)
      true -> FX.corridors(fx, include_assets: true)
      _other -> {:error, {:invalid_argument, "include_assets"}}
    end
  end

  @stables_args [
    {"corridor", :corridor},
    {"partner_only", :partner_only},
    {"exclude_yield_bearing", :exclude_yield_bearing},
    {"sort", :sort},
    {"limit", :limit},
    {"offset", :offset}
  ]

  # Types are left to `Raxol.Web3.FX.Sleuth`, which refuses anything outside
  # its accepted set as `{:invalid_argument, name}` before building a request.
  defp stables_opts(arguments) do
    {:ok,
     for {name, key} <- @stables_args, value = get(arguments, name), value != nil do
       {key, value}
     end}
  end

  # Arguments arrive JSON-decoded (string keys); a local Elixir caller writes
  # atoms. A compile-time table, so an absent argument can never raise.
  @atom_keys Map.new(
               ~w(corridor partner_only exclude_yield_bearing sort limit offset symbol include_assets),
               &{&1, String.to_atom(&1)}
             )

  defp get(arguments, name) when is_map(arguments),
    do: Map.get(arguments, name, Map.get(arguments, Map.fetch!(@atom_keys, name)))

  defp get(_arguments, _name), do: nil
end
