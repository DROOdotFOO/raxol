defmodule Raxol.Payments.Actions.Payments.PollRelayStatus do
  @moduledoc """
  Agent Action that polls a Relay (Tron) transfer until it reaches a terminal
  status.

  It never signs or moves funds, so it does not authorize a spend. It does
  reconcile the execute-time budget reservation at a terminal status: a refund
  releases it (`SpendGate.release_by_intent/2`, idempotent), any other terminal
  status forgets the tag while the spend stands. Pass the same `:ledger` and
  `:agent_id` used for the execute for this to take effect. A completed transfer
  returns `{:ok, summary}`; a failed or refunded transfer surfaces as
  `{:error, %Failure{}}`, never as `{:ok, ...}`.

  ## Context keys

  * `:relay_config` -- `%{base_url:, auth_token:}` for `Relay.Client`.
  * `:ledger`, `:agent_id` -- optional; the `Ledger` and key from the execute, so
    a refund releases that reservation. See `SpendGate`.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_poll_relay_status",
    description:
      "Poll a Relay (Tron) transfer by id until it reaches a terminal status (completed, failed, or refunded). Returns the final status and tx hash.",
    schema: [
      input: [
        transfer_id: [type: :string, required: true],
        timeout_ms: [type: :integer, description: "Max wait (default 120000)"],
        interval_ms: [type: :integer, description: "Poll interval (default 2000)"]
      ],
      output: [
        transfer_id: [type: :string],
        status: [type: :string],
        terminal: [type: :boolean],
        tx_hash: [type: :string],
        actual_to_amount: [type: :string],
        settlement_speed: [type: :string]
      ]
    ]

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Failure, Poll, Relay}
  alias Raxol.Payments.Relay.Schemas.StatusResponse

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(%{transfer_id: transfer_id} = params, context) do
    case Map.fetch(context, :relay_config) do
      {:ok, config} ->
        opts = poll_opts(params)
        budget = Keyword.get(opts, :budget_ms, Poll.default_budget_ms())

        case Relay.poll_status_timed(config, transfer_id, opts) do
          {:ok, %StatusResponse{status: :completed} = status, elapsed_ms} ->
            # Settled: the spend stands. Drop the reservation tag.
            SpendGate.forget_reservation(context, transfer_id)
            {:ok, summary(status, elapsed_ms, budget)}

          {:ok, %StatusResponse{status: :refunded} = status, _elapsed_ms} ->
            # The origin funds came back: release the execute-time reservation
            # idempotently so a refunded transfer stops consuming budget.
            SpendGate.release_by_intent(context, transfer_id)
            {:error, Failure.from({:settlement, :refunded, status.error || status.refund_reason})}

          {:ok, %StatusResponse{} = status, _elapsed_ms} ->
            # Terminal but not completed or refunded (failed): the spend stands
            # (funds may already have moved) -- forget the tag, keep the reason.
            SpendGate.forget_reservation(context, transfer_id)
            {:error, Failure.from({:settlement, status.status, status.error})}

          {:error, reason} ->
            {:error, Failure.from(reason)}
        end

      :error ->
        {:error, Failure.from({:missing_context, :relay_config})}
    end
  end

  defp poll_opts(params) do
    []
    |> maybe_put(:timeout_ms, Map.get(params, :timeout_ms))
    |> maybe_put(:slow_interval_ms, Map.get(params, :interval_ms))
    |> maybe_put(:budget_ms, Map.get(params, :budget_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summary(%StatusResponse{} = status, elapsed_ms, budget_ms) do
    %{
      transfer_id: status.transfer_id,
      status: to_string(status.status),
      terminal: StatusResponse.terminal?(status),
      tx_hash: status.tx_hash,
      actual_to_amount: status.actual_to_amount,
      settlement_speed: speed(elapsed_ms, budget_ms)
    }
  end

  defp speed(elapsed_ms, budget_ms) when elapsed_ms <= budget_ms, do: "within_budget"
  defp speed(_elapsed_ms, _budget_ms), do: "slow"
end
