defmodule Raxol.Payments.SettlementRecorder do
  @moduledoc """
  Turns a completed cross-chain fill into a `Raxol.Payments.SettlementLedger` entry:
  resolves the fee token, fetches the destination fill receipt via a
  `Raxol.Payments.ChainReader` to price the native gas burned, and records it.

  Called from the execute-then-poll orchestrator -- the only seam that holds the
  quote's fee together with the settled destination `tx_hash`. `PollXochiStatus`
  has no fee; `ExecuteXochiIntent` has no terminal receipt. It is opt-in and
  additive: the production Riddler execution path is never forced through it, and
  it never blocks a poll loop (a not-yet-mined receipt returns `:receipt_pending`
  or records `:pending` for later `amend_gas/4`).

  ## Gas attribution caveat

  `gas_native` is the destination fill tx's full gas cost -- the money-losing leg
  for micro-notional L1 fills. The origin pull is ERC-3009/Permit2 gasless
  (agent-side), so it is not attributed here. A solver that batches multiple fills
  into one destination tx would over-attribute gas to a single intent; treat the
  number as an upper bound in that case.
  """

  alias Raxol.Payments.{Assets, ChainReader, SettlementLedger}

  @typedoc """
  Recorder input, assembled by the orchestrator from the quote + poll result.
  `fee_collected` is the quote's fee in atomic units (e.g. `quote.xochi_fee`);
  `tx_hash` is the destination settlement tx (`status.tx_hash`).
  """
  @type input :: %{
          required(:intent_id) => String.t(),
          required(:from_chain_id) => pos_integer(),
          required(:to_chain_id) => pos_integer(),
          optional(:token_symbol) => String.t() | nil,
          optional(:token_address) => String.t() | nil,
          optional(:to_token) => String.t() | nil,
          optional(:from_amount) => String.t() | integer() | Decimal.t() | nil,
          optional(:to_amount) => String.t() | integer() | Decimal.t() | nil,
          optional(:fee_collected) => String.t() | integer() | Decimal.t(),
          optional(:fee_currency) => String.t() | nil,
          optional(:estimated_gas_cost) => String.t() | nil,
          optional(:tx_hash) => String.t() | nil,
          optional(:settlement_type) => atom() | nil,
          optional(:metadata) => map()
        }

  @doc """
  Record one completed fill.

  Options:
    * `:record_pending` -- when the receipt is not yet mined, record the entry with
      `gas_status: :pending` (backfill later via `SettlementLedger.amend_gas/4`)
      instead of returning `{:error, :receipt_pending}`. Default `false`.
    * `:strict` -- bubble a receipt-fetch error instead of recording
      `gas_status: :error`. Default `false`.
  """
  @spec record(GenServer.server(), ChainReader.reader(), input(), keyword()) ::
          {:ok, :recorded | :duplicate} | {:error, term()}
  def record(ledger, reader, input, opts \\ []) do
    to_chain = Map.get(input, :to_chain_id)
    tx_hash = Map.get(input, :tx_hash)
    settlement_type = Map.get(input, :settlement_type)

    case resolve_gas(reader, to_chain, tx_hash, settlement_type, opts) do
      {:ok, {gas_native, gas_status}} ->
        SettlementLedger.record_settlement(ledger, ledger_input(input, gas_native, gas_status))

      {:error, _reason} = err ->
        err
    end
  end

  # Shielded settlements are note-based -- no destination public tx to price.
  defp resolve_gas(_reader, _chain, _tx, :shielded, _opts), do: {:ok, {nil, :no_public_tx}}

  defp resolve_gas(reader, chain, tx_hash, _type, opts)
       when is_binary(tx_hash) and tx_hash != "" do
    case ChainReader.get_receipt(reader, chain, tx_hash) do
      {:ok, %{gas_used: gas_used, effective_gas_price: price}} ->
        {:ok, {gas_used * price, :confirmed}}

      {:ok, :pending} ->
        if Keyword.get(opts, :record_pending, false),
          do: {:ok, {nil, :pending}},
          else: {:error, :receipt_pending}

      {:error, reason} ->
        if Keyword.get(opts, :strict, false),
          do: {:error, reason},
          else: {:ok, {nil, :error}}
    end
  end

  # No tx hash and not shielded: fee is recorded, gas is unknown.
  defp resolve_gas(_reader, _chain, _tx, _type, _opts), do: {:ok, {nil, :no_public_tx}}

  defp ledger_input(input, gas_native, gas_status) do
    fee_currency = fee_currency(input)
    from_chain = Map.get(input, :from_chain_id)
    to_chain = Map.get(input, :to_chain_id)
    from_token = Map.get(input, :token_address)
    to_token = Map.get(input, :to_token)

    %{
      intent_id: Map.fetch!(input, :intent_id),
      from_chain_id: from_chain,
      to_chain_id: to_chain,
      token_symbol: Map.get(input, :token_symbol),
      token_address: from_token,
      fee_collected: Map.get(input, :fee_collected, 0),
      fee_currency: fee_currency,
      fee_decimals: fee_decimals(input, fee_currency),
      # Revenue legs for the multi-asset margin (usd(from) - usd(to)). Symbols and
      # decimals resolve from the token contracts so WETH (18) and stables (6) are
      # scaled correctly.
      from_amount: Map.get(input, :from_amount),
      from_symbol: Assets.symbol_for(from_chain, from_token) || Map.get(input, :token_symbol),
      from_decimals: token_decimals(from_chain, from_token),
      to_amount: Map.get(input, :to_amount),
      to_symbol: Assets.symbol_for(to_chain, to_token),
      to_decimals: token_decimals(to_chain, to_token),
      gas_native: gas_native,
      gas_chain_id: to_chain,
      gas_status: gas_status,
      estimated_gas_cost: Map.get(input, :estimated_gas_cost),
      tx_hash: Map.get(input, :tx_hash),
      settlement_type: Map.get(input, :settlement_type),
      metadata: Map.get(input, :metadata, %{})
    }
  end

  defp token_decimals(_chain, nil), do: nil
  defp token_decimals(_chain, ""), do: nil
  defp token_decimals(chain, token) when is_binary(token), do: Assets.decimals(chain, token)

  defp fee_currency(input) do
    Map.get(input, :fee_currency) || Map.get(input, :token_symbol) || "USDC"
  end

  # Resolve fee decimals from the token contract when present (authoritative),
  # else from the currency ticker. Never assume 6 blindly for a non-stable token.
  defp fee_decimals(input, fee_currency) do
    case Map.get(input, :token_address) do
      addr when is_binary(addr) and addr != "" ->
        Assets.decimals(Map.get(input, :from_chain_id), addr)

      _ ->
        Assets.decimals(fee_currency)
    end
  end
end
