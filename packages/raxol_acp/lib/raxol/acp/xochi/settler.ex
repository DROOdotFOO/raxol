defmodule Raxol.ACP.Xochi.Settler do
  @moduledoc """
  Adapter that converts `Raxol.ACP.Xochi.SolverAgent`'s `:settle_fn`
  callback into a real `Raxol.Payments.Protocols.Xochi.transfer/4`
  call.

  ## Usage

      settle_fn =
        Raxol.ACP.Xochi.Settler.build(
          wallet_address: "0xfeed...",
          xochi_config: %{base_url: "https://riddler.axol.io", auth_token: "..."},
          xochi_wallet: MyWallet,
          poll_timeout_ms: 120_000
        )

      Raxol.ACP.Xochi.SolverAgent.start_link(
        agent: my_agent,
        provider: my_provider,
        wallet_address: "0xfeed...",
        ...,
        settle_fn: settle_fn
      )

  ## Input shape (from SolverAgent)

      %{
        requirement: %{
          "src_chain_id" => 8453,
          "dst_chain_id" => 10,
          "src_token"    => "0x...",
          "dst_token"    => "0x...",
          "amount_atomic" => "1000000",
          "destination"  => "0x...",
          "slippage_bps" => 50,
          "settlement_preference" => "public"
        },
        transfer_amount_atomic: 1_000_000,
        destination: "0x...",
        xochi_config: %{...},   # passed through; same as settler config
        xochi_wallet: MyWallet  # passed through
      }

  ## Output shape

  On settle success:

      {:ok, %{
        intent_id:        "abc",
        quote_id:         "xyz",
        src_tx_hash:      "0x...",
        dst_tx_hash:      "0x...",
        status:           "settled",
        fee_atomic:       "1000",
        dst_amount_atomic: "999000"
      }}

  On error: `{:error, reason}`. SolverAgent marks the session
  `:failed` and does NOT submit a deliverable on-chain.
  """

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, IntentStatus}

  @doc """
  Build a settle_fn closure.

  ## Required

  - `:wallet_address` -- the solver's EOA on src chain. Used as the
    `wallet` field of the `QuoteRequest` (Xochi pulls funds from this
    address after the FundTransferHook payout lands).
  - `:xochi_config` -- the Riddler/Xochi server config (base_url +
    auth_token).
  - `:xochi_wallet` -- a `Raxol.Payments.Wallet` module that signs the
    XochiIntent.

  ## Optional

  - `:poll_timeout_ms` -- max time to wait for intent settlement.
    Default 120_000 (2 minutes).
  - `:poll_interval_ms` -- default 2_000 (2 seconds).
  """
  @spec build(keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def build(opts) do
    wallet_address = Keyword.fetch!(opts, :wallet_address)
    xochi_config = Keyword.fetch!(opts, :xochi_config)
    xochi_wallet = Keyword.fetch!(opts, :xochi_wallet)
    poll_timeout = Keyword.get(opts, :poll_timeout_ms, 120_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 2_000)

    fn settle_args ->
      do_settle(settle_args, wallet_address, xochi_config, xochi_wallet,
        timeout_ms: poll_timeout,
        interval_ms: poll_interval
      )
    end
  end

  # -- Internal --

  defp do_settle(args, wallet_address, xochi_config, xochi_wallet, poll_opts) do
    with {:ok, request} <- build_quote_request(args, wallet_address),
         {:ok, %IntentStatus{} = status} <-
           Xochi.transfer(xochi_config, request, xochi_wallet, poll_opts) do
      settle_result(status)
    end
  end

  # Only a completed settlement yields a deliverable. A terminal :failed or
  # :expired intent (which poll_status returns as `{:ok, status}`) must surface
  # as an error so SolverAgent does not submit a deliverable for a settlement
  # that never landed.
  defp settle_result(%IntentStatus{status: :completed} = status),
    do: to_deliverable(status)

  defp settle_result(%IntentStatus{status: s, intent_id: id, error: err})
       when s in [:failed, :expired],
       do: {:error, {:settlement_failed, s, id, err}}

  defp settle_result(%IntentStatus{status: s, intent_id: id}),
    do: {:error, {:settlement_incomplete, s, id}}

  defp build_quote_request(args, wallet_address) do
    req = args.requirement

    request = %QuoteRequest{
      wallet: wallet_address,
      from_chain_id: req["src_chain_id"],
      to_chain_id: req["dst_chain_id"],
      from_token: req["src_token"],
      to_token: req["dst_token"],
      from_amount: req["amount_atomic"],
      slippage_bps: req["slippage_bps"] || 50,
      settlement_preference: req["settlement_preference"] || "public"
    }

    case QuoteRequest.validate(request) do
      :ok -> {:ok, request}
      err -> err
    end
  end

  defp to_deliverable(%IntentStatus{} = status) do
    {:ok,
     %{
       intent_id: status.intent_id,
       quote_id: Map.get(status, :quote_id),
       src_tx_hash: Map.get(status, :src_tx_hash),
       dst_tx_hash: Map.get(status, :dst_tx_hash),
       status: to_string(status.status),
       fee_atomic: Map.get(status, :fee_atomic),
       dst_amount_atomic: Map.get(status, :to_amount) || Map.get(status, :dst_amount_atomic)
     }}
  end
end
