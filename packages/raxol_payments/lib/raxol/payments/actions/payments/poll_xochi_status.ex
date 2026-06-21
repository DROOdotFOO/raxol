defmodule Raxol.Payments.Actions.Payments.PollXochiStatus do
  @moduledoc """
  Agent Action that polls a Xochi intent until it reaches a terminal status.

  Read-only: it does not move funds, so it does not pass through `SpendGate`.

  ## Context keys

  * `:xochi_config` -- `%{base_url:, auth:}` for `Xochi.Client` (e.g.
    `auth: {:mandate, agent_wallet}`; see `Xochi.Client` for all auth modes).
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_poll_xochi_status",
    description:
      "Poll a Xochi intent by id until it reaches a terminal status (completed, failed, expired). Returns the final status and settlement details.",
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
        settlement_speed: [type: :string]
      ]
    ]

  alias Raxol.Payments.{Failure, Poll}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.IntentStatus

  @spec run(map(), map()) :: {:ok, map()} | {:error, Failure.t()}
  @impl true
  def run(%{intent_id: intent_id} = params, context) do
    case Map.fetch(context, :xochi_config) do
      {:ok, config} ->
        opts = poll_opts(params)
        budget = Keyword.get(opts, :budget_ms, Poll.default_budget_ms())

        case Xochi.poll_status_timed(config, intent_id, opts) do
          {:ok, %IntentStatus{status: :completed} = status, elapsed_ms} ->
            {:ok, summary(status, elapsed_ms, budget)}

          {:ok, %IntentStatus{} = status, _elapsed_ms} ->
            # Terminal but not completed (failed/expired/refunded): a failed
            # order must surface as an error, never as {:ok, ...}.
            {:error, Failure.from({:settlement, status.status, status.error})}

          {:error, reason} ->
            {:error, Failure.from(reason)}
        end

      :error ->
        {:error, Failure.from({:missing_context, :xochi_config})}
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

  defp summary(%IntentStatus{} = status, elapsed_ms, budget_ms) do
    %{
      intent_id: status.intent_id,
      status: to_string(status.status),
      terminal: IntentStatus.terminal?(status),
      tx_hash: status.tx_hash,
      settlement_type: status.settlement_type && to_string(status.settlement_type),
      settlement_speed: speed(elapsed_ms, budget_ms)
    }
  end

  # within_budget: settled inside the sub-3s window. slow: settled, but past it.
  defp speed(elapsed_ms, budget_ms) when elapsed_ms <= budget_ms, do: "within_budget"
  defp speed(_elapsed_ms, _budget_ms), do: "slow"
end
