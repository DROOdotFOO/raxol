defmodule Mix.Tasks.RaxolEarn.Rebalance do
  @shortdoc "Run a one-shot rebalance-advisor sweep and print recommendations"

  @moduledoc """
  Reads the solver's live balances (from `config :raxol_payments, :accounting`) and
  prints `Raxol.Payments.RebalanceAdvisor`'s recommendations -- the on-demand
  counterpart of the always-on `Raxol.Payments.RebalanceMonitor`. Recommend-only;
  it moves no funds.

  Requires `RPC_*` and `XOCHI_SOLVER_ADDRESS` (see `config/runtime.exs`).

      mix raxol_earn.rebalance
  """

  use Mix.Task

  alias Raxol.Payments.{ChainReader, RebalanceMonitor, RebalancePolicy, SettlementLedger}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    acc = Application.get_env(:raxol_payments, :accounting, [])
    rpc_urls = Keyword.get(acc, :rpc_urls, %{})
    solver = Keyword.get(acc, :solver_address)

    cond do
      map_size(rpc_urls) == 0 ->
        Mix.shell().error("no rpc_urls configured -- set RPC_* and RAXOL_ACCOUNTING_ENABLED=true")

      is_nil(solver) ->
        Mix.shell().error("no solver_address configured -- set XOCHI_SOLVER_ADDRESS")

      true ->
        sweep(acc, rpc_urls, solver)
    end
  end

  defp sweep(acc, rpc_urls, solver) do
    # A throwaway ledger: the drain only tiebreaks refuel ordering, so an empty one
    # still yields correct balance-driven recommendations for a snapshot.
    ledger =
      case SettlementLedger.start_link(table_name: :raxol_earn_rebalance_task) do
        {:ok, pid} ->
          pid

        # Re-running the sweep in one VM (or an ETS table left by a prior run)
        # is not a failure -- the ledger is a throwaway either way.
        {:error, {:already_started, pid}} ->
          pid

        {:error, reason} ->
          Mix.raise("could not start the throwaway settlement ledger: #{inspect(reason)}")
      end

    RebalanceMonitor.advise_once(
      ledger: ledger,
      reader: ChainReader.JSONRPC.new(chains: rpc_urls),
      solver_address: solver,
      policy: RebalancePolicy.with_demand(RebalancePolicy.default(), acc),
      chains: Map.keys(rpc_urls),
      price_source: Keyword.get(acc, :price_source, :coingecko),
      demand_window_ms: Keyword.get(acc, :demand_window_ms)
    )
    |> print()
  end

  defp print([]), do: Mix.shell().info("no recommendations")
  defp print(recs), do: Enum.each(recs, &Mix.shell().info(format(&1)))

  defp format({:refuel_gas, r}) do
    "refuel_gas #{r.chain_id} #{r.native_symbol}: buy #{dec(r.native_to_buy)} " <>
      "via #{r.source} (funding #{r.funding})"
  end

  defp format({:rebalance_inventory, r}) do
    "rebalance #{r.symbol} #{r.from_chain}->#{r.to_chain} #{dec(r.amount)} via #{r.rail}"
  end

  defp format({:alert, a}) do
    "ALERT #{a.kind} #{a.symbol} chain #{a.chain_id} deficit #{dec(a.deficit)}"
  end

  defp dec(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp dec(other), do: inspect(other)
end
