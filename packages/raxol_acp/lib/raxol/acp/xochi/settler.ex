defmodule Raxol.ACP.Xochi.Settler do
  @moduledoc """
  Storefront relay: turns `Raxol.ACP.Xochi.SolverAgent`'s `:settle_fn`
  callback into a `Raxol.Payments.Protocols.Xochi.execute_signed/2` call.

  raxol is a pure storefront. The buyer quoted and signed the Xochi intent
  against Xochi itself; the settler relays that pre-signed bundle WITHOUT
  re-signing and polls it to settlement. raxol never signs the transfer and
  never touches the transferred funds -- Riddler verifies the buyer's signature
  against its own persisted quote, so the amount and route cannot be forged.

  ## Usage

      settle_fn =
        Raxol.ACP.Xochi.Settler.build(
          xochi_config: %{base_url: "https://api.xochi.fi", auth_token: "..."},
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
          "amount_atomic" => "1000000",
          "signed_intent" => %{
            "intent_id"      => "xi_...",
            "quote_id"       => "xq_...",
            "signature"      => "0x...",
            "nonce"          => 7,
            "pull_signature" => "0x..."    # optional
          }
        },
        # threaded by SolverAgent (either is accepted):
        signed_intent: %{...},             # the bundle, extracted from the requirement
        transfer_amount_atomic: 1_000_000  # for the deliverable amount
      }

  ## Output shape

  On settle success:

      {:ok, %{
        intent_id:          "abc",
        settlement_tx_hash: "0x...",
        receiving_tx_hash:  "0x...",   # nil for an instant single-tx fill
        amount_atomic:      "1000000",
        status:             "completed"
      }}

  On error: `{:error, reason}`. SolverAgent marks the session `:failed` and does
  NOT submit a deliverable on-chain.
  """

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.IntentStatus

  @doc """
  Build a settle_fn closure.

  ## Required

  - `:xochi_config` -- the Xochi worker config (base_url + auth). The buyer's
    intent is relayed and polled through this endpoint.

  ## Optional

  - `:poll_timeout_ms` -- max time to wait for intent settlement.
    Default 120_000 (2 minutes).
  - `:poll_interval_ms` -- default 2_000 (2 seconds).
  """
  @spec build(keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def build(opts) do
    xochi_config = Keyword.fetch!(opts, :xochi_config)
    poll_timeout = Keyword.get(opts, :poll_timeout_ms, 120_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 2_000)

    fn settle_args ->
      do_settle(settle_args, xochi_config,
        timeout_ms: poll_timeout,
        interval_ms: poll_interval
      )
    end
  end

  # -- Internal --

  defp do_settle(args, xochi_config, poll_opts) do
    with {:ok, bundle} <- extract_signed_intent(args),
         {:ok, intent_id} <- bundle_intent_id(bundle),
         {:ok, _exec} <- Xochi.execute_signed(xochi_config, bundle),
         {:ok, %IntentStatus{} = status} <-
           Xochi.poll_status(xochi_config, intent_id, poll_opts) do
      settle_result(status, args)
    end
  end

  # The buyer's pre-signed intent bundle, threaded directly (`:signed_intent`) or
  # carried in the requirement (`requirement["signed_intent"]`). It may be a map
  # (a nested object) or a JSON string (a flat marketplace schema); both normalize
  # to a map. Keys may be atoms or strings; `execute_signed/2` deep-validates them.
  defp extract_signed_intent(%{signed_intent: bundle}) when not is_nil(bundle),
    do: normalize_bundle(bundle)

  defp extract_signed_intent(%{requirement: %{"signed_intent" => bundle}}),
    do: normalize_bundle(bundle)

  defp extract_signed_intent(_), do: {:error, :missing_signed_intent}

  defp normalize_bundle(bundle) do
    case Raxol.ACP.Xochi.Offering.decode_signed_intent(bundle) do
      {:ok, map} -> {:ok, map}
      :error -> {:error, :missing_signed_intent}
    end
  end

  # The status is polled by the intent id the buyer signed (present under either
  # key). `execute_signed/2` re-validates it, so an absent/blank id also fails
  # there; checking here lets a malformed bundle fail before the relay POST.
  defp bundle_intent_id(bundle) do
    case bundle[:intent_id] || bundle["intent_id"] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:invalid_signed_intent, :intent_id}}
    end
  end

  # Only a completed settlement yields a deliverable. A terminal :failed or
  # :expired intent (which poll_status returns as `{:ok, status}`) must surface
  # as an error so SolverAgent does not submit a deliverable for a settlement
  # that never landed.
  defp settle_result(%IntentStatus{status: :completed} = status, args),
    do: to_deliverable(status, args)

  defp settle_result(%IntentStatus{status: s, intent_id: id, error: err}, _args)
       when s in [:failed, :expired],
       do: {:error, {:settlement_failed, s, id, err}}

  defp settle_result(%IntentStatus{status: s, intent_id: id}, _args),
    do: {:error, {:settlement_incomplete, s, id}}

  # `IntentStatus.tx_hash` is the authoritative settlement tx: for an instant fill
  # it is the destination delivery; for a two-leg bridge it is the origin leg,
  # with the destination arrival in `receiving_tx_hash` (nil for instant). Surface
  # both under names that match that meaning, rather than a src/dst pair that
  # mislabels the single instant-fill tx as the source leg. `amount_atomic` is the
  # buyer's declared transfer amount, committed so the deliverable hash pins what
  # was moved rather than only the tx hashes.
  defp to_deliverable(%IntentStatus{} = status, args) do
    {:ok,
     %{
       intent_id: status.intent_id,
       settlement_tx_hash: status.tx_hash,
       receiving_tx_hash: status.receiving_tx_hash,
       amount_atomic: transfer_amount(args),
       status: to_string(status.status)
     }}
  end

  # The deliverable's amount: the SolverAgent-threaded transfer amount, else the
  # requirement's declared amount. It is display/audit metadata only -- the
  # on-chain amount is fixed by the buyer's signed intent, not by this field.
  defp transfer_amount(%{transfer_amount_atomic: n}) when is_integer(n),
    do: Integer.to_string(n)

  defp transfer_amount(%{requirement: %{"amount_atomic" => a}}), do: a

  defp transfer_amount(_), do: nil
end
