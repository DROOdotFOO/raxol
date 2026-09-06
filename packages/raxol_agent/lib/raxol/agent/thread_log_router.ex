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
  | `[:raxol, :agent, :policy, :cache_hit]` | `:policy_result` | `%{policy: :cache, decision: :hit, key, params_digest}` |
  | `[:raxol, :agent, :policy, :cache_miss]` | `:policy_result` | `%{policy: :cache, decision: :miss, key, params_digest}` |
  | `[:raxol, :agent, :policy, :retry_attempt]` | `:policy_result` | `%{policy: :retry, decision: :attempt, attempt, reason, backoff_ms}` |
  | `[:raxol, :agent, :policy, :retry_exhausted]` | `:policy_result` | `%{policy: :retry, decision: :exhausted, attempt, reason}` |
  | `[:raxol, :agent, :policy, :timeout]` | `:policy_result` | `%{policy: :timeout, decision: :fired, wall_ms}` |
  | `[:raxol, :agent, :policy, :applied]` | `:policy_result` | `%{policy: :applied, policy_kinds, outcome, params_digest}` |
  | `[:raxol, :agent, :sandbox, :denied]` | `:sandbox_deny` | `%{action, reason, command_digest}` |

  Every payload is accompanied by a `metadata` map, but it is not a mirror of
  the event's metadata: it carries correlation identifiers only. The keys are
  the tier-4 core (`session_id`, `turn_id`), the trace context
  `Raxol.Core.Telemetry.TraceContext` attaches upstream (`trace_id`,
  `span_id`, `parent_span_id`, `causation_id`), and whatever the attaching
  host names in `attach/4`'s `:metadata_keys`; and a listed key is persisted
  only when its value satisfies `Raxol.Agent.Telemetry.identifier?/1`. Every
  other key is dropped. The payload builders above already pick each event's
  own fields, so nothing informative is lost, and the audit log no longer
  depends on every emitter keeping content out of metadata (ADR-0036). A
  value that fails the check is dropped rather than raised on, because
  `:telemetry` detaches a handler that raises, and a lost audit trail is the
  worse failure.
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

  # Keys the persisted `metadata` may carry without the host naming them.
  # `agent_id` and `agent_module` are deliberately absent: both are redundant
  # with the `thread_id` every entry is filed under.
  @correlation_keys [:session_id, :turn_id, :trace_id, :span_id, :parent_span_id, :causation_id]

  @doc """
  Attach a telemetry handler that routes agent-side events to the
  given ThreadLog adapter under `thread_id`.

  `adapter` is the `{module, config}` tuple (or bare module) as
  returned by `Raxol.Agent.ThreadLog.normalize/1`. Pass `nil` to
  no-op (useful when the agent declares no `thread_log/0`).

  Options:

    * `:metadata_keys` -- additional metadata keys (atoms) to persist beside
      the built-in correlation keys, for a host whose events carry its own
      identifiers (a Symphony runner's `turn` and `issue_id`, say). Values
      are still subject to `Raxol.Agent.Telemetry.identifier?/1`.

  Returns `:ok` on success or when adapter is `nil`. Returns
  `{:error, :already_exists}` if `handler_id` is already attached.
  """
  @spec attach(
          binary(),
          ThreadLog.config() | {module(), ThreadLog.config()} | nil,
          binary(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def attach(handler_id, adapter, thread_id, opts \\ [])

  def attach(_handler_id, nil, _thread_id, _opts), do: :ok

  def attach(handler_id, adapter, thread_id, opts)
      when is_binary(handler_id) and is_binary(thread_id) and is_list(opts) do
    normalized = ThreadLog.normalize(adapter)
    keys = metadata_keys!(Keyword.get(opts, :metadata_keys, []))

    case :telemetry.attach_many(
           handler_id,
           @all_events,
           &__MODULE__.handle/4,
           %{adapter: normalized, thread_id: thread_id, metadata_keys: keys}
         ) do
      :ok -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp metadata_keys!(keys) when is_list(keys) do
    if Enum.all?(keys, &is_atom/1) do
      @correlation_keys ++ keys
    else
      raise ArgumentError,
            "ThreadLogRouter.attach/4 `:metadata_keys` must be a list of atoms; " <>
              "got #{inspect(keys)}"
    end
  end

  defp metadata_keys!(other) do
    raise ArgumentError,
          "ThreadLogRouter.attach/4 `:metadata_keys` must be a list of atoms; " <>
            "got #{inspect(other)}"
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
        thread_id: thread_id,
        metadata_keys: keys
      }) do
    {kind, payload} = translate(event, metadata)

    # The builders below pick each event's fields, and the emitters bound the
    # values they did not build themselves; this is the backstop for an
    # emitter that forgets, so the audit log never holds an unbounded term.
    _ =
      ThreadLog.append(adapter, thread_id, kind, Raxol.Agent.Telemetry.bound(payload),
        metadata: correlation_metadata(metadata, keys)
      )

    :ok
  end

  defp correlation_metadata(metadata, keys) do
    metadata
    |> Map.take(keys)
    |> Map.filter(fn {_key, value} -> Raxol.Agent.Telemetry.identifier?(value) end)
  end

  # --- Per-event translation -----------------------------------------------

  defp translate([:raxol, :agent, :policy, sub], metadata) do
    {:policy_result, build_policy_payload(sub, metadata)}
  end

  defp translate([:raxol, :agent, :sandbox, :denied], metadata) do
    payload = %{
      action: Map.get(metadata, :action),
      reason: Map.get(metadata, :reason),
      command_digest: Map.get(metadata, :command_digest)
    }

    {:sandbox_deny, payload}
  end

  defp build_policy_payload(:cache_hit, metadata),
    do: %{
      policy: :cache,
      decision: :hit,
      key: metadata[:key],
      params_digest: metadata[:params_digest]
    }

  defp build_policy_payload(:cache_miss, metadata),
    do: %{
      policy: :cache,
      decision: :miss,
      key: metadata[:key],
      params_digest: metadata[:params_digest]
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
      outcome: metadata[:outcome],
      params_digest: metadata[:params_digest]
    }

  defp build_policy_payload(other, metadata),
    do: %{policy: other, decision: :unknown, metadata: metadata}
end
