defmodule Raxol.Payments.SettlementAccountant do
  @moduledoc """
  Subscribes to `[:raxol, :payments, :xochi, :settled]` and books each completed
  settlement into a `Raxol.Payments.SettlementLedger`.

  The telemetry handler runs in the settling process, so it does **no** IO -- it
  casts to this GenServer, which does the receipt fetch (via `ChainReader`) and the
  ledger write off the settlement hot path. A not-yet-mined receipt is recorded as
  `:pending` (`record_pending: true`) and backfilled later by
  `SettlementLedger.amend_gas/4`.

  Started by a host supervisor (e.g. `Raxol.ACP.Supervisor`), like `Ledger` --
  `raxol_payments` has no supervision tree of its own.

  ## Options

    * `:ledger` -- the `SettlementLedger` server (name or pid). Required.
    * `:reader` -- a `ChainReader.reader`. Defaults to a `ChainReader.JSONRPC` built
      from `:rpc_urls` or `config :raxol_payments, :accounting, rpc_urls:`.
    * `:name`, `:handler_id`, `:record_opts` (default `[record_pending: true]`).
  """

  use GenServer

  require Logger

  alias Raxol.Payments.{Assets, ChainReader, SettlementRecorder}

  @settled_event [:raxol, :payments, :xochi, :settled]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    ledger = Keyword.fetch!(opts, :ledger)
    reader = Keyword.get(opts, :reader) || build_reader(opts)
    handler_id = Keyword.get(opts, :handler_id, "raxol-settlement-accountant:#{inspect(name)}")
    record_opts = Keyword.get(opts, :record_opts, record_pending: true)

    :ok =
      :telemetry.attach(handler_id, @settled_event, &__MODULE__.handle_settled/4, %{
        accountant: self()
      })

    {:ok, %{ledger: ledger, reader: reader, handler_id: handler_id, record_opts: record_opts}}
  end

  # Telemetry callback -- runs in the emitting process. Hand off only; no IO here.
  @doc false
  def handle_settled(_event, measurements, metadata, %{accountant: accountant}) do
    GenServer.cast(accountant, {:settled, measurements, metadata})
  end

  @impl true
  def handle_cast({:settled, _measurements, metadata}, state) do
    input = build_input(metadata)

    case SettlementRecorder.record(state.ledger, state.reader, input, state.record_opts) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "settlement accounting failed for #{inspect(metadata[:intent_id])}: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  # Map the `:settled` event metadata onto a recorder input. The from/to legs drive
  # the solver-spread revenue (usd(from) - usd(to)); the venue `xochi_fee` rides in
  # metadata and as fee_collected for reference.
  defp build_input(md) do
    from_chain = md[:from_chain_id]

    %{
      intent_id: md[:intent_id],
      from_chain_id: from_chain,
      to_chain_id: md[:to_chain_id],
      token_symbol: Assets.symbol_for(from_chain, md[:from_token]),
      token_address: md[:from_token],
      to_token: md[:to_token],
      from_amount: md[:from_amount],
      to_amount: md[:to_amount],
      fee_collected: md[:xochi_fee] || 0,
      tx_hash: md[:tx_hash],
      settlement_type: settlement_atom(md[:settlement_type]),
      metadata: %{xochi_fee: md[:xochi_fee]}
    }
  end

  defp settlement_atom(type) when type in [:public, :stealth, :shielded], do: type
  defp settlement_atom("public"), do: :public
  defp settlement_atom("stealth"), do: :stealth
  defp settlement_atom("shielded"), do: :shielded
  defp settlement_atom(_), do: nil

  defp build_reader(opts) do
    chains = Keyword.get(opts, :rpc_urls) || config_rpc_urls()
    ChainReader.JSONRPC.new(chains: chains)
  end

  defp config_rpc_urls do
    :raxol_payments
    |> Application.get_env(:accounting, [])
    |> Keyword.get(:rpc_urls, %{})
  end
end
