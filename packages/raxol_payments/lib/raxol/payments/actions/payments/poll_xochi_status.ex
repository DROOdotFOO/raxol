defmodule Raxol.Payments.Actions.Payments.PollXochiStatus do
  @moduledoc """
  Agent Action that polls a Xochi intent until it reaches a terminal status.

  It never signs or moves funds, so it does not authorize a spend. It does
  reconcile the execute-time budget reservation at a terminal status: a refund
  releases it (`SpendGate.release_by_intent/2`, idempotent), any other terminal
  status forgets the tag while the spend stands. Pass the same `:ledger` and
  `:agent_id` used for the execute for this to take effect; without them it is a
  no-op and the reservation is left untouched.

  ## Context keys

  * `:xochi_config` -- `%{base_url:, auth:}` for `Xochi.Client` (e.g.
    `auth: {:mandate, agent_wallet}`; see `Xochi.Client` for all auth modes).
  * `:ledger`, `:agent_id` -- optional; the `Ledger` and key from the execute, so
    a refund releases that reservation. Atom and binary `:agent_id` values also
    select the same private ownership principal as the execute. Without one, the
    wallet module or address in `:wallet` supplies the principal. See `SpendGate`.
  * `:checkpoint` -- optional private checkpoint store used by the execute
    Action. It proves that this principal owns the dispatched intent and supplies
    the intent's read token. A terminal summary (never the token) is retained for
    a bounded replay window under the API origin, principal, and intent id.

  The execute Action stores the read token outside its model-visible result, in
  private checkpoint state keyed by the API origin, executing principal, and
  `intent_id`. Pass the same `:checkpoint` store and `:xochi_config` in this
  Action's context and it presents the token automatically in the
  `X-Xochi-Read-Token` header. A checkpointed poll without matching ownership is
  rejected before any request, so a model cannot poll someone else's intent or
  present their token. With no checkpoint configured, polling remains anonymous.

  The token is kept only while the owned intent is non-terminal. Completed,
  failed, expired, and refunded terminal results commit a bounded summary first
  and then delete the token. An anonymous (`legs_withheld`) answer stays
  non-terminal and retains the token for a later owner-view poll.

  A poll that times out on a non-terminal status whose destination fill is
  confirmed (`settlement_confirmed`) returns `{:ok, summary}` with
  `terminal: false` instead of reporting the intent stranded. That marker never
  releases, refunds or re-executes anything; poll again for the terminal status.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_poll_xochi_status",
    description:
      "Poll a Xochi intent by id until it reaches a terminal status (completed, failed, expired, refunded). Returns the final status and settlement details.",
    schema: [
      input: [
        intent_id: [type: :string, required: true],
        timeout_ms: [type: :integer, description: "Max wait (default 120000)"],
        interval_ms: [type: :integer, description: "Poll interval (default 2000)"]
      ],
      output: [
        intent_id: [type: :string],
        status: [type: :string],
        terminal: [type: :boolean],
        tx_hash: [type: :string],
        settlement_type: [type: :string],
        settlement_speed: [type: :string],
        note_commitment: [type: :string],
        nullifier_hash: [type: :string],
        l2_tx_hash: [type: :string],
        substatus: [type: :string],
        substatus_message: [
          type: :string,
          description:
            "Solver-supplied detail on the current/terminal status (e.g. the reconcile reason behind an in-doubt settlement). Present when the worker forwards one."
        ],
        receiving_tx_hash: [type: :string],
        settlement_tx_hash: [type: :string],
        settlement_chain_id: [type: :integer],
        settlement_confirmed: [
          type: :boolean,
          description:
            "The destination fill is confirmed, even if the top-level status is still settling."
        ],
        legs_withheld: [
          type: :boolean,
          description:
            "The worker answered with the anonymous view of a private settlement; tx hashes are withheld."
        ]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Checkpoint, Failure, Poll}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.{ReadTokenStore, SettlementState, SwapAnnouncer}
  alias Raxol.Payments.Xochi.Schemas.IntentStatus

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(%{intent_id: intent_id} = params, context) do
    case Map.fetch(context, :xochi_config) do
      {:ok, config} -> run_authorized(params, context, config, intent_id)
      :error -> {:error, Failure.from({:missing_context, :xochi_config})}
    end
  end

  defp run_authorized(params, context, config, intent_id) do
    principal = SettlementState.principal(context)

    case authorize_poll(context, config, principal, intent_id) do
      {:ok, owner} ->
        poll_or_replay(params, context, config, principal, owner, intent_id)

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp poll_or_replay(params, context, config, principal, owner, intent_id) do
    case committed_terminal(context, config, principal, intent_id) do
      {:ok, terminal} ->
        replay_terminal(context, intent_id, terminal)

      :error ->
        opts = poll_opts(params, context, principal, intent_id)
        budget = Keyword.get(opts, :budget_ms, Poll.default_budget_ms())
        result = Xochi.poll_status_timed(config, intent_id, opts)
        handle_result(result, context, principal, owner, intent_id, budget)
    end
  end

  defp authorize_poll(%{checkpoint: store} = context, config, principal, intent_id)
       when not is_nil(store) do
    case SettlementState.owner(store, config.base_url, principal, intent_id, now(context)) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, Failure.from({:intent_not_owned, intent_id})}
    end
  end

  defp authorize_poll(_context, _config, _principal, _intent_id), do: {:ok, nil}

  defp handle_result(
         {:ok, %IntentStatus{status: :completed} = status, elapsed_ms},
         ctx,
         principal,
         _owner,
         id,
         budget
       ) do
    summary = summary(status, elapsed_ms, budget)
    result = {:ok, summary}
    commit_terminal(ctx, principal, id, status.status, result)
    SpendGate.forget_reservation(ctx, id)
    announce_terminal(ctx, id, status)
    result
  end

  defp handle_result(
         {:ok, %IntentStatus{status: :refunded} = status, _elapsed_ms},
         ctx,
         principal,
         _owner,
         id,
         _budget
       ) do
    reason = status.error || status.refund_reason || status.substatus_message
    result = {:error, Failure.from({:settlement, :refunded, reason})}
    commit_terminal(ctx, principal, id, status.status, result)
    SpendGate.release_by_intent(ctx, id)
    announce_terminal(ctx, id, status)
    result
  end

  defp handle_result(
         {:ok, %IntentStatus{} = status, _elapsed_ms},
         ctx,
         principal,
         _owner,
         id,
         _budget
       ) do
    reason = status.error || status.substatus_message
    result = {:error, Failure.from({:settlement, status.status, reason})}
    commit_terminal(ctx, principal, id, status.status, result)
    SpendGate.forget_reservation(ctx, id)
    announce_terminal(ctx, id, status)
    result
  end

  defp handle_result(
         {:error, {:timeout, %IntentStatus{} = last}},
         ctx,
         _principal,
         _owner,
         id,
         budget
       ) do
    if IntentStatus.settlement_confirmed?(last),
      do: {:ok, %{summary(last, 0, budget) | settlement_speed: nil}},
      else: stranded(ctx, id, last)
  end

  defp handle_result(
         {:error, {:timeout, nil}},
         ctx,
         _principal,
         _owner,
         id,
         _budget
       ),
       do: stranded(ctx, id, nil)

  defp handle_result(
         {:error, {:http, 404, _body}} = error,
         ctx,
         principal,
         owner,
         id,
         _budget
       ) do
    if owner && expired?(owner.deadline, now(ctx)) do
      SpendGate.release_by_intent(ctx, id)
      delete_dispatch_checkpoint(ctx.checkpoint, owner)
      SettlementState.forget(ctx.checkpoint, ctx.xochi_config.base_url, principal, id)
      ReadTokenStore.delete(ctx.checkpoint, ctx.xochi_config.base_url, principal, id)
      {:error, Failure.from({:never_dispatched, id})}
    else
      {:error, Failure.from(elem(error, 1))}
    end
  end

  defp handle_result({:error, reason}, _ctx, _principal, _owner, _id, _budget) do
    {:error, Failure.from(reason)}
  end

  defp delete_dispatch_checkpoint(store, %{dispatch_key: key}) when is_binary(key),
    do: Checkpoint.delete(store, key)

  defp delete_dispatch_checkpoint(_store, _owner), do: :ok

  defp stranded(ctx, id, last) do
    :telemetry.execute([:raxol, :payments, :xochi, :intent_stranded], %{}, %{
      intent_id: id,
      status: last && to_string(last.status),
      settlement_confirmed: false,
      legs_withheld: (last && last.legs_withheld) || false
    })

    SwapAnnouncer.announce_stranded(ctx, id)
    {:error, Failure.from({:stranded, id})}
  end

  defp commit_terminal(ctx, principal, id, status, result) do
    SettlementState.commit_terminal(
      Map.get(ctx, :checkpoint),
      ctx.xochi_config.base_url,
      principal,
      id,
      %{status: status, return: result},
      now(ctx)
    )
  end

  defp committed_terminal(ctx, config, principal, id) do
    SettlementState.terminal(
      Map.get(ctx, :checkpoint),
      config.base_url,
      principal,
      id,
      now(ctx)
    )
  end

  defp replay_terminal(ctx, id, %{status: status, return: result}) do
    reconcile_terminal(ctx, id, status)
    announce_terminal(ctx, id, %IntentStatus{intent_id: id, status: status, terminal: true})
    result
  end

  defp reconcile_terminal(ctx, id, :refunded), do: SpendGate.release_by_intent(ctx, id)
  defp reconcile_terminal(ctx, id, _status), do: SpendGate.forget_reservation(ctx, id)

  defp announce_terminal(context, intent_id, status) do
    SwapAnnouncer.announce_terminal(context, intent_id, status)
    :ok
  end

  defp poll_opts(params, context, principal, intent_id) do
    [last_status_on_timeout: true]
    |> maybe_put(:timeout_ms, Map.get(params, :timeout_ms))
    |> maybe_put(:slow_interval_ms, Map.get(params, :interval_ms))
    |> maybe_put(:budget_ms, Map.get(params, :budget_ms))
    |> maybe_put(
      :read_token,
      ReadTokenStore.fetch(
        Map.get(context, :checkpoint),
        context.xochi_config.base_url,
        principal,
        intent_id,
        now(context)
      )
    )
  end

  defp expired?(deadline, now) when is_integer(deadline), do: now >= deadline
  defp expired?(_deadline, _now), do: false

  defp now(context) do
    context
    |> Map.get(:clock, fn -> System.system_time(:second) end)
    |> then(fn clock -> clock.() end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summary(%IntentStatus{} = status, elapsed_ms, budget_ms) do
    %{
      intent_id: status.intent_id,
      status: to_string(status.status),
      terminal: IntentStatus.terminal?(status),
      tx_hash: status.tx_hash,
      receiving_tx_hash: status.receiving_tx_hash,
      settlement_tx_hash: status.settlement_tx_hash,
      settlement_chain_id: status.settlement_chain_id,
      settlement_confirmed: IntentStatus.settlement_confirmed?(status),
      legs_withheld: status.legs_withheld,
      settlement_type: status.settlement_type && to_string(status.settlement_type),
      settlement_speed: speed(elapsed_ms, budget_ms),
      # Shielded (Aztec) settlements are note-based: the note commitment,
      # nullifier, and L2 tx surface here at terminal status in place of an
      # on-chain stealth address. nil for public/stealth settlements, where a
      # present-nil is treated as absent by the output schema.
      note_commitment: status.note_commitment,
      nullifier_hash: status.nullifier_hash,
      l2_tx_hash: status.l2_tx_hash,
      # Solver-supplied progress detail, when forwarded by the worker. Lets a
      # caller see why a settlement is where it is (e.g. an in-doubt reconcile
      # note) instead of only the coarse status. nil when none is present.
      substatus: status.substatus,
      substatus_message: status.substatus_message
    }
  end

  # within_budget: settled inside the sub-3s window. slow: settled, but past it.
  defp speed(elapsed_ms, budget_ms) when elapsed_ms <= budget_ms, do: "within_budget"
  defp speed(_elapsed_ms, _budget_ms), do: "slow"
end
