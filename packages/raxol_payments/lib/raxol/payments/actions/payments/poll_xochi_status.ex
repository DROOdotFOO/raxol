defmodule Raxol.Payments.Actions.Payments.PollXochiStatus do
  @moduledoc """
  Agent Action that polls a Xochi intent until it reaches a terminal status.

  Read-only: it does not move funds, so it does not pass through `SpendGate`.

  ## Context keys

  * `:xochi_config` -- `%{base_url:, auth_token:}` for `Xochi.Client`.
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
        settlement_type: [type: :string]
      ]
    ]

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.IntentStatus

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(%{intent_id: intent_id} = params, context) do
    case Map.fetch(context, :xochi_config) do
      {:ok, config} ->
        opts = poll_opts(params)

        case Xochi.poll_status(config, intent_id, opts) do
          {:ok, %IntentStatus{} = status} -> {:ok, summary(status)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, {:missing_context, :xochi_config}}
    end
  end

  defp poll_opts(params) do
    []
    |> maybe_put(:timeout_ms, Map.get(params, :timeout_ms))
    |> maybe_put(:interval_ms, Map.get(params, :interval_ms))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summary(%IntentStatus{} = status) do
    %{
      intent_id: status.intent_id,
      status: to_string(status.status),
      terminal: IntentStatus.terminal?(status),
      tx_hash: status.tx_hash,
      settlement_type: status.settlement_type && to_string(status.settlement_type)
    }
  end
end
