defmodule Raxol.Agent.PolicyApplier do
  @moduledoc """
  Runtime that wraps an operation in a list of
  `Raxol.Agent.Policy` structs.

  Policies are evaluated outermost-first. The order documented in
  `Raxol.Agent.Policy`:

  1. Cache (short-circuit on hit)
  2. RateLimit (deferred; not yet implemented)
  3. Timeout (wrap in a `Task`, abort on wall-clock)
  4. Retry (loop on retriable errors)
  5. The wrapped operation runs

  ## Telemetry

  Emits events under `[:raxol, :agent, :policy, :*]`:

  | Event | Metadata |
  | --- | --- |
  | `:cache_hit` | `policy_kind: :cache`, `key`, `params` |
  | `:cache_miss` | `policy_kind: :cache`, `key`, `params` |
  | `:retry_attempt` | `policy_kind: :retry`, `attempt`, `reason`, `backoff_ms` |
  | `:retry_exhausted` | `policy_kind: :retry`, `attempt`, `reason` |
  | `:timeout` | `policy_kind: :timeout`, `wall_ms` |
  | `:applied` | the final outcome with `:ok | :error` tag |

  Telemetry is fire-and-forget; consumers attach
  `Raxol.Agent.PolicyApplier.ThreadLogHandler` (a separate
  follow-up) to append `:policy_result` ThreadLog entries from
  the events.
  """

  alias Raxol.Agent.Cache
  alias Raxol.Agent.Policy

  @typedoc "Either an ok-or-error tuple or :ok."
  @type result :: {:ok, term()} | {:error, term()}

  @typedoc "The wrapped operation. Receives `params` and returns a `result()`."
  @type op :: (term() -> result())

  @doc """
  Apply a list of policies to `fun`, threading `params` through.

  Returns the unwrapped result tuple. On success, the value comes
  from the cache (if a cache policy hit), from a successful
  invocation, or from a retry's final attempt. On error, the most
  recent reason is returned.

  An empty `policies` list invokes `fun.(params)` directly.
  """
  @spec apply([Policy.t()], op(), term()) :: result()
  def apply(policies, fun, params)
      when is_list(policies) and is_function(fun, 1) do
    result = compose(policies, fun).(params)
    emit_applied(policies, params, result)
    result
  end

  # Compose the policy list into a single function by wrapping
  # inner-first: head of the list becomes the outermost wrap.
  defp compose([], fun), do: fun

  defp compose([policy | rest], fun) do
    inner = compose(rest, fun)
    wrap(policy, inner)
  end

  # --- Per-policy wrappers --------------------------------------------------

  defp wrap(%Policy.Cache{} = policy, inner) do
    fn params ->
      key = policy.key_fn.(params)

      case Cache.get(policy.storage, key) do
        {:ok, value} ->
          emit(:cache_hit, %{policy_kind: :cache, key: key, params: params})
          {:ok, value}

        :miss ->
          emit(:cache_miss, %{policy_kind: :cache, key: key, params: params})

          case inner.(params) do
            {:ok, value} = ok ->
              :ok = Cache.put(policy.storage, key, value, policy.ttl_ms)
              ok

            {:error, _} = err ->
              err
          end
      end
    end
  end

  defp wrap(%Policy.Timeout{} = policy, inner) do
    fn params ->
      task = Task.async(fn -> inner.(params) end)

      case Task.yield(task, policy.wall_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          emit(:timeout, %{policy_kind: :timeout, wall_ms: policy.wall_ms})
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:exit, reason}}
      end
    end
  end

  defp wrap(%Policy.Retry{} = policy, inner) do
    fn params -> retry_loop(policy, inner, params, 1) end
  end

  defp retry_loop(
         %Policy.Retry{max_attempts: max} = policy,
         inner,
         params,
         attempt
       ) do
    case inner.(params) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempt < max and Policy.Retry.retriable?(policy, reason) do
          backoff_ms = Policy.Retry.backoff(policy, attempt)

          emit(:retry_attempt, %{
            policy_kind: :retry,
            attempt: attempt,
            reason: reason,
            backoff_ms: backoff_ms
          })

          if backoff_ms > 0, do: Process.sleep(backoff_ms)
          retry_loop(policy, inner, params, attempt + 1)
        else
          emit(:retry_exhausted, %{
            policy_kind: :retry,
            attempt: attempt,
            reason: reason
          })

          err
        end
    end
  end

  # --- Telemetry helpers ----------------------------------------------------

  defp emit(event_name, metadata) do
    :telemetry.execute([:raxol, :agent, :policy, event_name], %{}, metadata)
  end

  defp emit_applied(policies, params, result) do
    kinds =
      Enum.map(policies, fn p ->
        p.__struct__ |> Module.split() |> List.last()
      end)

    tag =
      case result do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end

    :telemetry.execute(
      [:raxol, :agent, :policy, :applied],
      %{},
      %{policy_kinds: kinds, params: params, outcome: tag}
    )
  end
end
