if Code.ensure_loaded?(Raxol.Web3.FX) do
  defmodule Raxol.Agent.Actions.FX do
    @moduledoc """
    The `fx` tool: fiat-pegged stablecoin market data with a peg verdict
    (ADR-0040 decision 5).

    One tool with an `operation` enum, for the reason `Raxol.Agent.Actions.Web3`
    gives: an Action sits in the toolset for the whole session. The three reads
    are the ones `Raxol.Web3.MCP.FXTools` serves, through the same dispatch, so
    the two surfaces cannot drift.

    The handle comes from `context[:fx_source]` (a `Raxol.Web3.FX`); without it
    the tool answers `{:error, :fx_not_configured}`. A jailed session refuses
    it unless the context says `network: true`, because it spends the
    operator's Sleuth key and RPC budget. `sensitive: true`, as every read that
    discloses to a third party what a session is looking at.
    """

    use Raxol.Agent.Action,
      name: "fx",
      sensitive: true,
      description:
        "Fiat-pegged stablecoin market data (USD, EUR, CHF...): price, supply, volume, " <>
          "corridor totals, and a peg verdict judged against Chainlink FX rates " <>
          "(ok, suspect, no_rate, yield_bearing). Read-only.",
      schema: [
        input: [
          operation: [
            type: :string,
            required: true,
            enum: ["stables", "stable", "corridors"],
            description: "stables: a page of assets; stable: one asset; corridors: totals."
          ],
          symbol: [type: :string, description: "Ticker for `stable`, e.g. \"EURC\"."],
          corridor: [type: :string, description: "Peg currency filter for `stables`."],
          partner_only: [type: :boolean, description: "Only USDT, USDC, EURC, EURe, ZCHF."],
          exclude_yield_bearing: [type: :boolean, description: "Drop yield-bearing tokens."],
          sort: [type: :string, description: "e.g. supplyUsd, deviationBps."],
          limit: [type: :integer, description: "1 to 300."],
          offset: [type: :integer, description: "Page offset."],
          include_assets: [type: :boolean, description: "For `corridors`."]
        ],
        output: [operation: [type: :string], result: [type: :map]]
      ]

    alias Raxol.Web3.FX
    alias Raxol.Web3.MCP.FXTools

    @tools %{
      "stables" => "web3_fx_stables",
      "stable" => "web3_fx_stable",
      "corridors" => "web3_fx_corridors"
    }

    @impl true
    def run(%{operation: operation} = params, context) do
      with :ok <- Raxol.Agent.Actions.Code.network_allow(context),
           {:ok, fx} <- source(context),
           {:ok, tool} <- tool(operation),
           {:ok, result} <- FXTools.dispatch(fx, tool, Map.delete(params, :operation)) do
        {:ok, %{operation: operation, result: result}}
      end
    end

    defp source(context) do
      case Map.fetch(context, :fx_source) do
        {:ok, %FX{} = fx} -> {:ok, fx}
        _absent -> {:error, :fx_not_configured}
      end
    end

    defp tool(operation) do
      case Map.fetch(@tools, operation) do
        {:ok, tool} -> {:ok, tool}
        :error -> {:error, {:unknown_operation, operation}}
      end
    end
  end
end
