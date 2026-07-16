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
    a refund releases that reservation. See `SpendGate`.
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
        ]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Failure, Poll}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.IntentStatus
  alias Raxol.Payments.Xochi.SwapAnnouncer

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(%{intent_id: intent_id} = params, context) do
    case Map.fetch(context, :xochi_config) do
      {:ok, config} ->
        opts = poll_opts(params)
        budget = Keyword.get(opts, :budget_ms, Poll.default_budget_ms())
        result = Xochi.poll_status_timed(config, intent_id, opts)
        handle_result(result, context, intent_id, budget)

      :error ->
        {:error, Failure.from({:missing_context, :xochi_config})}
    end
  end

  defp handle_result(
         {:ok, %IntentStatus{status: :completed} = status, elapsed_ms},
         ctx,
         id,
         budget
       ) do
    # Settled: the spend stands. Drop the reservation tag so the ledger's
    # in-flight set stays bounded; nothing to release.
    SpendGate.forget_reservation(ctx, id)
    announce_terminal(ctx, id, status)
    {:ok, summary(status, elapsed_ms, budget)}
  end

  defp handle_result(
         {:ok, %IntentStatus{status: :refunded} = status, _elapsed_ms},
         ctx,
         id,
         _budget
       ) do
    # The origin funds came back. Release the execute-time budget reservation,
    # idempotently -- a re-poll of an already-refunded intent releases nothing
    # further -- so a refunded payment stops consuming budget. Still surfaced as
    # an error carrying the refund reason.
    SpendGate.release_by_intent(ctx, id)
    announce_terminal(ctx, id, status)
    reason = status.error || status.refund_reason || status.substatus_message
    {:error, Failure.from({:settlement, :refunded, reason})}
  end

  defp handle_result({:ok, %IntentStatus{} = status, _elapsed_ms}, ctx, id, _budget) do
    # Terminal but not completed or refunded (failed/expired): a failed order
    # must surface as an error, never as {:ok, ...}. The origin pull may already
    # have moved funds, so the spend stands -- forget the tag (no release), but
    # keep the reason (an explicit error, then the solver's substatus_message) so
    # why it failed is never lost.
    SpendGate.forget_reservation(ctx, id)
    announce_terminal(ctx, id, status)
    reason = status.error || status.substatus_message
    {:error, Failure.from({:settlement, status.status, reason})}
  end

  defp handle_result({:error, :timeout}, ctx, id, _budget) do
    # A poll that never reached a terminal status is not a clean failure: the
    # origin funds may already have been pulled while delivery stayed
    # unconfirmed, so the intent is stranded, not failed. Emit a distinct signal
    # so operator tooling can reconcile or close THIS intent, and carry the id in
    # the error so the caller does not re-execute it.
    :telemetry.execute([:raxol, :payments, :xochi, :intent_stranded], %{}, %{intent_id: id})
    # Advance the live-feed row off "executing" to a stranded state so it does
    # not sit unresolved. Best-effort; leaves the route in place for a later
    # terminal announce if a re-poll resolves the intent.
    SwapAnnouncer.announce_stranded(ctx, id)
    {:error, Failure.from({:stranded, id})}
  end

  defp handle_result({:error, reason}, _ctx, _id, _budget) do
    {:error, Failure.from(reason)}
  end

  # Best-effort, non-blocking: advance the user's live-feed row to its terminal
  # state. A no-op unless a capability topic_id is configured and the execute
  # stashed this intent's route. Never affects the poll result.
  defp announce_terminal(context, intent_id, status) do
    SwapAnnouncer.announce_terminal(context, intent_id, status)
    :ok
  end

  defp poll_opts(params) do
    []
    |> maybe_put(:timeout_ms, Map.get(params, :timeout_ms))
    |> maybe_put(:slow_interval_ms, Map.get(params, :interval_ms))
    |> maybe_put(:budget_ms, Map.get(params, :budget_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summary(%IntentStatus{} = status, elapsed_ms, budget_ms) do
    %{
      intent_id: status.intent_id,
      status: to_string(status.status),
      terminal: IntentStatus.terminal?(status),
      tx_hash: status.tx_hash,
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
