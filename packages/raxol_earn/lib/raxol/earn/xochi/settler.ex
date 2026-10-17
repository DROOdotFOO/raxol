defmodule Raxol.Earn.Xochi.Settler do
  @moduledoc """
  Storefront relay: turns `Raxol.Earn.Xochi.SolverAgent`'s `:settle_fn`
  callback into a `Raxol.Payments.Protocols.Xochi.execute_signed/2` call.

  raxol is a pure storefront. The buyer quoted and signed the Xochi intent
  against Xochi itself; the settler relays that pre-signed bundle WITHOUT
  re-signing and polls it to settlement. raxol never signs the transfer and
  never touches the transferred funds -- Riddler verifies the buyer's signature
  against its own persisted quote, so the amount and route cannot be forged.

  ## Usage

      settle_fn =
        Raxol.Earn.Xochi.Settler.build(
          xochi_config: %{base_url: "https://api.xochi.fi", auth_token: "..."},
          poll_timeout_ms: 120_000
        )

      Raxol.Earn.Xochi.SolverAgent.start_link(
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
        status:             "completed",
        # Present only for a stealth settlement (nil otherwise):
        settlement_type:    "stealth", # the privacy tier that settled
        stealth_address:    "0x...",   # ERC-5564 announcement fields the buyer
        ephemeral_pub_key:  "0x...",   # or evaluator verifies the delivery with
        view_tag:           42
      }}

  On error: `{:error, reason}`. SolverAgent marks the session `:failed` and does
  NOT submit a deliverable on-chain. A completed intent whose status carries no
  settlement tx hash is `{:error, {:settlement_tx_hash_unavailable, intent_id}}`:
  the deliverable schema requires that hash, and the settler never invents one.

  ## Read token

  For a stealth/shielded intent the Xochi worker withholds the tx hashes from a
  caller that does not prove ownership (xochi#563). The relay is the caller that
  executed, so it holds the intent's one-time `read_token` from the execute
  response and presents it on every poll. It never goes into the deliverable, a
  log line or a URL. An execute answered with a non-2xx that carries the token
  (`{:execute_in_doubt, _, _}`: funds may have moved) is polled like a dispatched
  intent, not failed.

  ## Crash recovery

  With a `:checkpoint` store (a `Raxol.Payments.Checkpoint` `{module, handle}`)
  the settler records the intent before relaying it and, once the execute
  answers, records its id, `read_token` and stealth announcement fields. A
  settle re-run for the same intent after a crash resumes polling from that
  record instead of relaying the bundle again, still with the token. A definite
  execute failure drops the record. The record holds a bearer secret: use a
  store you would trust with the intent itself.
  """

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{ExecuteResponse, IntentStatus}

  @doc """
  Build a settle_fn closure.

  ## Required

  - `:xochi_config` -- the Xochi worker config (base_url + auth). The buyer's
    intent is relayed and polled through this endpoint.

  ## Optional

  - `:poll_timeout_ms` -- max time to wait for intent settlement.
    Default 120_000 (2 minutes).
  - `:poll_interval_ms` -- default 2_000 (2 seconds).
  - `:checkpoint` -- a `Raxol.Payments.Checkpoint` store; see "Crash recovery".
    Default nil (no recovery).
  """
  @spec build(keyword()) :: (map() -> {:ok, map()} | {:error, term()})
  def build(opts) do
    xochi_config = Keyword.fetch!(opts, :xochi_config)
    poll_timeout = Keyword.get(opts, :poll_timeout_ms, 120_000)
    poll_interval = Keyword.get(opts, :poll_interval_ms, 2_000)
    store = Keyword.get(opts, :checkpoint)

    fn settle_args ->
      do_settle(settle_args, xochi_config, store,
        timeout_ms: poll_timeout,
        interval_ms: poll_interval
      )
    end
  end

  # -- Internal --

  defp do_settle(args, xochi_config, store, poll_opts) do
    with {:ok, bundle} <- extract_signed_intent(args),
         {:ok, intent_id} <- bundle_intent_id(bundle),
         {:ok, %ExecuteResponse{} = exec} <- dispatch(xochi_config, bundle, intent_id, store),
         {:ok, %IntentStatus{} = status} <-
           Xochi.poll_status(
             xochi_config,
             intent_id,
             Keyword.put(poll_opts, :read_token, exec.read_token)
           ) do
      settle_result(status, exec, args)
    end
  end

  # Resume from the checkpoint when this intent was already relayed; otherwise
  # record it, relay it, and record what the execute answered. A crash between
  # the two puts leaves only the dispatched marker: the outcome is unknown, so
  # the intent is polled (without a token) rather than relayed twice.
  defp dispatch(xochi_config, bundle, intent_id, store) do
    key = Checkpoint.derive_key([:xochi_settler, intent_id])

    case Checkpoint.fetch(store, key) do
      {:ok, record} ->
        {:ok, resumed_exec(record, intent_id)}

      :error ->
        Checkpoint.put(store, key, %{intent_id: intent_id, status: :dispatched})

        case Xochi.as_dispatched(Xochi.execute_signed(xochi_config, bundle), intent_id) do
          {:ok, %ExecuteResponse{} = exec} ->
            Checkpoint.put(store, key, executed_record(exec, intent_id))
            {:ok, exec}

          {:error, _reason} = error ->
            Checkpoint.delete(store, key)
            error
        end
    end
  end

  defp executed_record(%ExecuteResponse{} = exec, intent_id) do
    %{
      intent_id: exec.intent_id || intent_id,
      status: :in_flight,
      read_token: exec.read_token,
      stealth_address: exec.stealth_address,
      ephemeral_pub_key: exec.ephemeral_pub_key,
      view_tag: exec.view_tag
    }
  end

  defp resumed_exec(record, intent_id) do
    %ExecuteResponse{
      intent_id: Map.get(record, :intent_id, intent_id),
      status: :unknown,
      reconciling: true,
      read_token: Map.get(record, :read_token),
      stealth_address: Map.get(record, :stealth_address),
      ephemeral_pub_key: Map.get(record, :ephemeral_pub_key),
      view_tag: Map.get(record, :view_tag)
    }
  end

  # The buyer's pre-signed intent bundle, threaded directly (`:signed_intent`) or
  # carried in the requirement JSON (`requirement["signed_intent"]`). Keys may be
  # atoms or strings; `execute_signed/2` normalizes and deep-validates them.
  defp extract_signed_intent(%{signed_intent: bundle}) when is_map(bundle), do: {:ok, bundle}

  defp extract_signed_intent(%{requirement: %{"signed_intent" => bundle}}) when is_map(bundle),
    do: {:ok, bundle}

  defp extract_signed_intent(_), do: {:error, :missing_signed_intent}

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
  defp settle_result(%IntentStatus{status: :completed} = status, exec, args),
    do: to_deliverable(status, exec, args)

  defp settle_result(%IntentStatus{status: s, intent_id: id, error: err}, _exec, _args)
       when s in [:failed, :expired],
       do: {:error, {:settlement_failed, s, id, err}}

  defp settle_result(%IntentStatus{status: s, intent_id: id}, _exec, _args),
    do: {:error, {:settlement_incomplete, s, id}}

  # `IntentStatus.tx_hash` is the authoritative settlement tx: for an instant fill
  # it is the destination delivery; for a two-leg bridge it is the origin leg,
  # with the destination arrival in `receiving_tx_hash` (nil for instant). Surface
  # both under names that match that meaning, rather than a src/dst pair that
  # mislabels the single instant-fill tx as the source leg. `amount_atomic` is the
  # buyer's declared transfer amount, committed so the deliverable hash pins what
  # was moved rather than only the tx hashes.
  #
  # For a stealth settlement the worker returns the ERC-5564 announcement
  # (`stealth_address`/`ephemeral_pub_key`/`view_tag`) on the execute response and
  # marks the settled intent `settlement_type: :stealth` on poll. These are the
  # public on-chain announcement fields the buyer or evaluator needs to verify the
  # delivery, not the recipient's identity; they are nil for a public settlement,
  # so `TransferOffering.present/1` drops them and a public deliverable is
  # byte-identical.
  #
  # A completed status without `tx_hash` is refused, never filled in. Since
  # xochi#563 the worker omits a stealth/shielded intent's legs unless the
  # caller presents the read token (or owner JWT); the relay presents the token
  # it got from execute, so this fires only when the worker withheld anyway
  # (token absent or rejected) or served none. The Riddler SPEC (§3.4) lets a
  # status omit `txHash`, but the deliverable this builds follows
  # `Offering.deliverable_schema/0,1`, which requires `settlement_tx_hash` (a
  # 32-byte hex hash) in every mode. So the field stays required and the settle
  # fails with the intent id for an operator to reconcile, rather than submit
  # a deliverable that fails its own schema. `receiving_tx_hash` is optional
  # there and is simply dropped when absent.
  defp to_deliverable(%IntentStatus{tx_hash: hash} = status, _exec, _args)
       when not is_binary(hash) or hash == "",
       do: {:error, {:settlement_tx_hash_unavailable, status.intent_id}}

  defp to_deliverable(%IntentStatus{} = status, %ExecuteResponse{} = exec, args) do
    {:ok,
     %{
       intent_id: status.intent_id,
       settlement_tx_hash: status.tx_hash,
       receiving_tx_hash: status.receiving_tx_hash,
       amount_atomic: transfer_amount(args),
       status: to_string(status.status),
       settlement_type: settlement_type(status),
       stealth_address: exec.stealth_address,
       ephemeral_pub_key: exec.ephemeral_pub_key,
       view_tag: exec.view_tag
     }}
  end

  defp settlement_type(%IntentStatus{settlement_type: nil}), do: nil
  defp settlement_type(%IntentStatus{settlement_type: t}), do: to_string(t)

  # The deliverable's amount: the SolverAgent-threaded transfer amount, else the
  # requirement's declared amount. It is display/audit metadata only -- the
  # on-chain amount is fixed by the buyer's signed intent, not by this field.
  defp transfer_amount(%{transfer_amount_atomic: n}) when is_integer(n),
    do: Integer.to_string(n)

  defp transfer_amount(%{requirement: %{"amount_atomic" => a}}), do: a

  defp transfer_amount(_), do: nil
end
