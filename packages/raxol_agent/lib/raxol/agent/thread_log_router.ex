defmodule Raxol.Agent.ThreadLogRouter do
  @moduledoc """
  Telemetry handler that routes agent-side events
  (`[:raxol, :agent, :policy, :*]` and
  `[:raxol, :agent, :sandbox, :denied]`) into a
  `Raxol.Agent.ThreadLog` adapter as durable audit entries.

  ## How it works

  `attach/3` calls `:telemetry.attach_many/4` for the agent-side
  event family, passing the ThreadLog adapter tuple and the agent's
  `thread_id` in the handler config. Every matching event is
  translated into one `ThreadLog.append/5` call with
  `kind: :policy_result` (for policy events) or
  `kind: :sandbox_deny` (for sandbox denials).

  Detach via `detach/1` (e.g. in the agent's `terminate/2`).

  ## Wiring

  Consumers typically call this at agent startup once
  `agent_module.thread_log/0` resolves to a non-nil adapter:

      adapter = Raxol.Agent.ThreadLog.normalize(MyAgent.thread_log())
      handler_id = "raxol_agent_thread_log_router_\#{agent_id}"
      Raxol.Agent.ThreadLogRouter.attach(handler_id, adapter, agent_id)

      # ... later, on terminate
      Raxol.Agent.ThreadLogRouter.detach(handler_id)

  When `adapter` is `nil`, `attach/3` returns `:ok` without
  attaching, so callers don't need to branch.

  ## Event mapping

  | Telemetry event | ThreadLog kind | Payload |
  | --- | --- | --- |
  | `[:raxol, :agent, :policy, :cache_hit]` | `:policy_result` | `%{policy: :cache, decision: :hit, key, params}` |
  | `[:raxol, :agent, :policy, :cache_miss]` | `:policy_result` | `%{policy: :cache, decision: :miss, key, params}` |
  | `[:raxol, :agent, :policy, :retry_attempt]` | `:policy_result` | `%{policy: :retry, decision: :attempt, attempt, reason, backoff_ms}` |
  | `[:raxol, :agent, :policy, :retry_exhausted]` | `:policy_result` | `%{policy: :retry, decision: :exhausted, attempt, reason}` |
  | `[:raxol, :agent, :policy, :timeout]` | `:policy_result` | `%{policy: :timeout, decision: :fired, wall_ms}` |
  | `[:raxol, :agent, :policy, :applied]` | `:policy_result` | `%{policy: :applied, policy_kinds, outcome}` |
  | `[:raxol, :agent, :sandbox, :denied]` | `:sandbox_deny` | `%{action, reason}` |

  All payloads include a `metadata` map mirroring the telemetry
  event's metadata (minus `agent_id`/`agent_module` which are
  redundant with the thread_id).
  """

  alias Raxol.Agent.ThreadLog

  @policy_events [
    [:raxol, :agent, :policy, :cache_hit],
    [:raxol, :agent, :policy, :cache_miss],
    [:raxol, :agent, :policy, :retry_attempt],
    [:raxol, :agent, :policy, :retry_exhausted],
    [:raxol, :agent, :policy, :timeout],
    [:raxol, :agent, :policy, :applied]
  ]

  @sandbox_events [
    [:raxol, :agent, :sandbox, :denied]
  ]

  @all_events @policy_events ++ @sandbox_events

  @doc """
  Attach a telemetry handler that routes agent-side events to the
  given ThreadLog adapter under `thread_id`.

  `adapter` is the `{module, config}` tuple (or bare module) as
  returned by `Raxol.Agent.ThreadLog.normalize/1`. Pass `nil` to
  no-op (useful when the agent declares no `thread_log/0`).

  Returns `:ok` on success or when adapter is `nil`. Returns
  `{:error, :already_exists}` if `handler_id` is already attached.
  """
  @spec attach(
          binary(),
          ThreadLog.config() | {module(), ThreadLog.config()} | nil,
          binary()
        ) ::
          :ok | {:error, term()}
  def attach(_handler_id, nil, _thread_id), do: :ok

  def attach(handler_id, adapter, thread_id)
      when is_binary(handler_id) and is_binary(thread_id) do
    normalized = ThreadLog.normalize(adapter)

    case :telemetry.attach_many(
           handler_id,
           @all_events,
           &__MODULE__.handle/4,
           %{adapter: normalized, thread_id: thread_id}
         ) do
      :ok -> :ok
      {:error, _reason} = err -> err
    end
  end

  @doc "Detach a previously-attached handler. Idempotent."
  @spec detach(binary()) :: :ok
  def detach(handler_id) when is_binary(handler_id) do
    _ = :telemetry.detach(handler_id)
    :ok
  end

  @doc false
  def handle(event, _measurements, metadata, %{
        adapter: adapter,
        thread_id: thread_id
      }) do
    {kind, payload} = translate(event, metadata)
    audit_metadata = Map.drop(metadata, [:agent_id, :agent_module])

    _ =
      ThreadLog.append(adapter, thread_id, kind, payload,
        metadata: audit_metadata
      )

    :ok
  end

  # --- Per-event translation -----------------------------------------------

  defp translate([:raxol, :agent, :policy, sub], metadata) do
    {:policy_result, build_policy_payload(sub, metadata)}
  end

  defp translate([:raxol, :agent, :sandbox, :denied], metadata) do
    payload = %{
      action: Map.get(metadata, :action),
      reason: Map.get(metadata, :reason)
    }

    {:sandbox_deny, payload}
  end

  defp build_policy_payload(:cache_hit, metadata),
    do: %{
      policy: :cache,
      decision: :hit,
      key: metadata[:key],
      params: metadata[:params]
    }

  defp build_policy_payload(:cache_miss, metadata),
    do: %{
      policy: :cache,
      decision: :miss,
      key: metadata[:key],
      params: metadata[:params]
    }

  defp build_policy_payload(:retry_attempt, metadata),
    do: %{
      policy: :retry,
      decision: :attempt,
      attempt: metadata[:attempt],
      reason: metadata[:reason],
      backoff_ms: metadata[:backoff_ms]
    }

  defp build_policy_payload(:retry_exhausted, metadata),
    do: %{
      policy: :retry,
      decision: :exhausted,
      attempt: metadata[:attempt],
      reason: metadata[:reason]
    }

  defp build_policy_payload(:timeout, metadata),
    do: %{policy: :timeout, decision: :fired, wall_ms: metadata[:wall_ms]}

  defp build_policy_payload(:applied, metadata),
    do: %{
      policy: :applied,
      policy_kinds: metadata[:policy_kinds],
      outcome: metadata[:outcome]
    }

  defp build_policy_payload(other, metadata),
    do: %{policy: other, decision: :unknown, metadata: metadata}
end
