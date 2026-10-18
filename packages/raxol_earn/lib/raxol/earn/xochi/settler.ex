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

  For a stealth/shielded intent the Xochi worker withholds tx hashes from an
  anonymous caller. The relay presents the execute-time read token while polling
  but never returns, logs, or stores it in a replayable settlement record. With
  a checkpoint store, the token is wrapped in a separate private record keyed by
  the API origin and the non-secret intent id; without it the poll remains
  anonymous. The token is deleted only after the terminal result is committed,
  and kept when the worker answered with the anonymous view (`legs_withheld`).

  ## Crash recovery

  With a `:checkpoint` store (a `Raxol.Payments.Checkpoint` `{module, handle}`)
  the settler records the intent before relaying it and records only non-secret
  execute metadata in the replay checkpoint. A settle re-run for the same intent
  resumes polling instead of relaying the bundle again. Once submission starts,
  transport failures, malformed responses, 5xx responses, and refusals because
  the intent is already executing or past `quoted` remain in doubt and keep that
  checkpoint even without a token. Only local validation failure or a
  structurally valid clean rejection drops it.

  At a terminal status the in-flight record is replaced by a terminal record
  holding the settle result (public deliverable fields or the error, never the
  token), and only then is the token deleted. A re-run that finds the terminal
  record returns that result without polling.
  """

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.ReadTokenStore
  alias Raxol.Payments.Xochi.Schemas.{ExecuteRequest, ExecuteResponse, IntentStatus}

  @doc """
  Build a settle_fn closure.

  ## Required

  - `:xochi_config` -- the Xochi worker config (base_url + auth). The buyer's
    intent is relayed and polled through this endpoint.

  ## Optional

  - `:poll_timeout_ms` -- max time to wait for intent settlement.
    Default 120_000 (2 minutes).
  - `:poll_interval_ms` -- default 2_000 (2 seconds).
  - `:checkpoint` -- a trusted `Raxol.Payments.Checkpoint` store for replay
    recovery and separate `Secret`-wrapped read-token state. Default nil.
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
         {:ok, request} <- Xochi.prepare_signed_execute(bundle) do
      key = Checkpoint.derive_key([:xochi_settler, intent_id])

      case dispatch(xochi_config, request, intent_id, store, key) do
        {:terminal, result} -> result
        {:ok, %ExecuteResponse{} = exec} -> poll(xochi_config, exec, args, store, key, poll_opts)
        {:error, _reason} = error -> error
      end
    end
  end

  defp poll(xochi_config, exec, args, store, key, poll_opts) do
    # A writer that lost the execute race holds no token of its own; the
    # winner's, if already stored for this origin, still opens the owner view.
    token = exec.read_token || ReadTokenStore.fetch(store, xochi_config.base_url, exec.intent_id)

    with {:ok, %IntentStatus{} = status} <-
           Xochi.poll_status(
             xochi_config,
             exec.intent_id,
             Keyword.put(poll_opts, :read_token, token)
           ) do
      status
      |> settle_result(exec, args)
      |> commit_terminal(status, exec.intent_id, xochi_config, store, key)
    end
  end

  # The terminal record replaces the in-flight one in a single put, and the
  # token is dropped only after it lands: a crash before the put leaves the
  # token for the re-run's owner-view poll, a crash after it leaves the stored
  # result. An anonymous answer (`legs_withheld`) means the token was absent or
  # refused, so neither is committed and a re-run polls again. A terminal
  # record another writer already committed wins.
  defp commit_terminal(result, %IntentStatus{legs_withheld: true}, _id, _config, _store, _key),
    do: result

  defp commit_terminal(result, %IntentStatus{}, intent_id, xochi_config, store, key) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{status: :terminal} = record} ->
        {:terminal, committed} = replay_terminal(record, intent_id, xochi_config, store)
        committed

      _ ->
        Checkpoint.put(store, key, %{intent_id: intent_id, status: :terminal, result: result})
        ReadTokenStore.delete(store, xochi_config.base_url, intent_id)
        result
    end
  end

  # Every path that returns a committed terminal record comes through here. A
  # crash between the commit and the token delete, or a concurrent writer that
  # stored its own token after the commit, leaves a token behind; delete it
  # (idempotent) before replaying the stored result.
  defp replay_terminal(%{result: result} = record, intent_id, xochi_config, store) do
    ReadTokenStore.delete(store, xochi_config.base_url, Map.get(record, :intent_id, intent_id))
    {:terminal, result}
  end

  # Resume from the checkpoint when this intent was already relayed; otherwise
  # record it before the POST. A crash between the two records leaves only the
  # dispatched marker: the outcome is unknown, so the intent is polled
  # anonymously rather than relayed twice.
  defp dispatch(xochi_config, request, intent_id, store, key) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{status: :terminal} = record} ->
        replay_terminal(record, intent_id, xochi_config, store)

      {:ok, record} ->
        {:ok, resumed_exec(record, intent_id, xochi_config, store)}

      :error ->
        Checkpoint.put(store, key, %{intent_id: intent_id, status: :dispatched})

        case safe_dispatch(xochi_config, request, intent_id) do
          {:ok, %ExecuteResponse{} = exec} ->
            ReadTokenStore.put(
              store,
              xochi_config.base_url,
              exec.intent_id || intent_id,
              exec.read_token
            )

            record_executed(store, key, exec, intent_id, xochi_config)

          # A clean rejection carries no token, so any stored for this intent
          # was issued to another writer and is left alone.
          {:error, _reason} = error ->
            Checkpoint.delete(store, key)
            error
        end
    end
  end

  # A concurrent writer for the same intent shares this key. Never overwrite a
  # terminal record it committed, and keep the announcement fields it recorded
  # when this (in-doubt) response carries none.
  defp record_executed(store, key, exec, intent_id, xochi_config) do
    case Checkpoint.fetch(store, key) do
      {:ok, %{status: :terminal} = record} ->
        replay_terminal(record, intent_id, xochi_config, store)

      {:ok, existing} ->
        put_executed(
          store,
          key,
          exec,
          Map.merge(existing, executed_record(exec, intent_id), &keep_known/3)
        )

      :error ->
        put_executed(store, key, exec, executed_record(exec, intent_id))
    end
  end

  defp keep_known(_field, old, nil), do: old
  defp keep_known(_field, _old, new), do: new

  defp put_executed(store, key, exec, record) do
    Checkpoint.put(store, key, record)
    {:ok, announced_exec(exec, record)}
  end

  defp announced_exec(%ExecuteResponse{} = exec, record) do
    %{
      exec
      | stealth_address: record.stealth_address,
        ephemeral_pub_key: record.ephemeral_pub_key,
        view_tag: record.view_tag
    }
  end

  defp safe_dispatch(xochi_config, %ExecuteRequest{} = request, intent_id) do
    Xochi.execute_prepared(xochi_config, request)
  rescue
    _exception -> {:ok, in_doubt(intent_id)}
  catch
    _kind, _reason -> {:ok, in_doubt(intent_id)}
  end

  defp in_doubt(intent_id) do
    %ExecuteResponse{
      intent_id: intent_id,
      status: :unknown,
      error: "response_exception",
      reconciling: true
    }
  end

  defp executed_record(%ExecuteResponse{} = exec, intent_id) do
    %{
      intent_id: exec.intent_id || intent_id,
      status: :in_flight,
      stealth_address: exec.stealth_address,
      ephemeral_pub_key: exec.ephemeral_pub_key,
      view_tag: exec.view_tag
    }
  end

  defp resumed_exec(record, intent_id, xochi_config, store) do
    resolved_id = Map.get(record, :intent_id, intent_id)

    %ExecuteResponse{
      intent_id: resolved_id,
      status: :unknown,
      reconciling: true,
      read_token: ReadTokenStore.fetch(store, xochi_config.base_url, resolved_id),
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
