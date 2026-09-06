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
  | `:cache_hit` | `policy_kind: :cache`, `key` |
  | `:cache_miss` | `policy_kind: :cache`, `key` |
  | `:retry_attempt` | `policy_kind: :retry`, `attempt`, `reason`, `backoff_ms` |
  | `:retry_exhausted` | `policy_kind: :retry`, `attempt`, `reason` |
  | `:timeout` | `policy_kind: :timeout`, `wall_ms` |
  | `:applied` | `policy_kinds`, the final outcome as `:ok | :error` |

  Every event also carries `params_digest` and the caller's `metadata:` option
  (below), with the event's own keys winning on collision.

  ## What never reaches metadata

  The wrapped operation's argument. It is an arbitrary term -- for a cache
  policy keyed on a prompt it IS the prompt -- and `Raxol.Agent.ThreadLogRouter`
  persists what it receives, so emitting it would write content into a
  durable audit log. Instead every event of one `apply/4` call carries the
  same `params_digest`, `Raxol.Agent.Telemetry.digest/1` of the argument,
  computed once per call: the `:cache_*`, `:retry_*`, `:timeout` and
  `:applied` events of one operation can be joined, and nothing about the
  argument can be read back out of it. The digest is keyed per VM run, so
  it joins within a run and deliberately not across runs.

  Two values on these events come from outside this module and are bounded
  before they are emitted, with `Raxol.Agent.Telemetry.bound/1`: `key`, which
  a user's `key_fn` derives from the argument and may therefore be the
  argument, and `reason`, which is whatever the wrapped operation returned
  in `{:error, reason}` -- a provider's error may echo the request, or carry
  a response struct with headers. The shape of a reason survives bounding
  (`{:http_error, 500, ...}`); its content does not. The caller still gets
  the full reason as `apply/4`'s return value, which is not telemetry.

  A caller that needs its own correlation keys on these events passes them
  explicitly:

      PolicyApplier.apply(policies, op, params, metadata: %{turn: 3, issue_id: id})

  `metadata:` is for identifiers, and that is enforced: every key must be an
  atom and every value must satisfy `Raxol.Agent.Telemetry.identifier?/1` (an
  atom, a number, or a binary of at most 64 bytes), or `apply/4` raises before
  the operation runs. The map is merged under the event's own keys and
  persisted by the router, so a prompt, a tool argument, a file body or a
  credential has no shape that fits here; `params_digest` exists so that the
  argument itself never needs to.

  Telemetry is fire-and-forget; consumers attach
  `Raxol.Agent.ThreadLogRouter` to append `:policy_result` ThreadLog entries
  from the events.
  """

  alias Raxol.Agent.Cache
  alias Raxol.Agent.Policy
  alias Raxol.Agent.Telemetry

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

  Options:

    * `:metadata` -- a map of correlation identifiers merged into the
      metadata of every telemetry event this call emits. Atom keys; values
      accepted by `Raxol.Agent.Telemetry.identifier?/1`. Anything else raises
      `ArgumentError`.
  """
  @spec apply([Policy.t()], op(), term(), keyword()) :: result()
  def apply(policies, fun, params, opts \\ [])
      when is_list(policies) and is_function(fun, 1) and is_list(opts) do
    # One digest per call, on the context every event merges, so the events
    # of one operation share it and the argument is serialized exactly once.
    context = opts |> context!() |> Map.put(:params_digest, Telemetry.digest(params))
    result = compose(policies, fun, context).(params)
    emit_applied(policies, result, context)
    result
  end

  # Every refusal names the offender by shape, never by content: an error that
  # echoed a rejected prompt into a crash report would be the leak this check
  # exists to prevent. A struct is matched before the map clause because
  # `%{}` matches structs too, and `Enum.each/2` on one raises
  # `Protocol.UndefinedError` with the whole value inspected into the
  # message -- a request struct's Authorization header included.
  defp context!(opts) do
    case Keyword.get(opts, :metadata, %{}) do
      %_{} = struct ->
        raise ArgumentError,
              "PolicyApplier.apply/4 `:metadata` must be a plain map of correlation " <>
                "identifiers; got #{shape(struct)}"

      %{} = context ->
        Enum.each(context, fn {key, value} -> identifier!(key, value) end)
        context

      other ->
        raise ArgumentError,
              "PolicyApplier.apply/4 `:metadata` must be a map of correlation " <>
                "identifiers; got #{shape(other)}"
    end
  end

  defp identifier!(key, value) when is_atom(key) do
    if Telemetry.identifier?(value) do
      :ok
    else
      raise ArgumentError,
            "PolicyApplier.apply/4 `:metadata` carries correlation identifiers only " <>
              "(atoms, numbers, or binaries of at most " <>
              "#{Telemetry.max_identifier_bytes()} bytes); " <>
              "#{inspect(key)} is #{shape(value)}. The wrapped argument is already " <>
              "represented by :params_digest; content must not be put here."
    end
  end

  defp identifier!(key, _value) do
    raise ArgumentError,
          "PolicyApplier.apply/4 `:metadata` keys must be atoms; got #{shape(key)}"
  end

  defp shape(value) when is_binary(value), do: "a binary of #{byte_size(value)} bytes"
  defp shape(%struct{}), do: "a #{inspect(struct)} struct"
  defp shape(value) when is_map(value), do: "a map of #{map_size(value)} keys"
  defp shape(value) when is_list(value), do: "a list of #{length(value)} elements"
  defp shape(value) when is_tuple(value), do: "a tuple of #{tuple_size(value)} elements"
  defp shape(value) when is_function(value), do: "a function"
  defp shape(value) when is_pid(value), do: "a pid"
  defp shape(value) when is_reference(value), do: "a reference"
  defp shape(_value), do: "not an identifier"

  # Compose the policy list into a single function by wrapping
  # inner-first: head of the list becomes the outermost wrap.
  defp compose([], fun, _context), do: fun

  defp compose([policy | rest], fun, context) do
    inner = compose(rest, fun, context)
    wrap(policy, inner, context)
  end

  # --- Per-policy wrappers --------------------------------------------------

  defp wrap(%Policy.Cache{} = policy, inner, context) do
    fn params ->
      key = policy.key_fn.(params)

      case Cache.get(policy.storage, key) do
        {:ok, value} ->
          emit(:cache_hit, cache_metadata(key), context)
          {:ok, value}

        :miss ->
          emit(:cache_miss, cache_metadata(key), context)

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

  defp wrap(%Policy.Timeout{} = policy, inner, context) do
    fn params ->
      task = Task.async(fn -> inner.(params) end)

      case Task.yield(task, policy.wall_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          emit(:timeout, %{policy_kind: :timeout, wall_ms: policy.wall_ms}, context)
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:exit, reason}}
      end
    end
  end

  defp wrap(%Policy.Retry{} = policy, inner, context) do
    fn params -> retry_loop(policy, inner, params, 1, context) end
  end

  defp retry_loop(
         %Policy.Retry{max_attempts: max} = policy,
         inner,
         params,
         attempt,
         context
       ) do
    case inner.(params) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempt < max and Policy.Retry.retriable?(policy, reason) do
          backoff_ms = Policy.Retry.backoff(policy, attempt)

          emit(
            :retry_attempt,
            %{
              policy_kind: :retry,
              attempt: attempt,
              reason: Telemetry.bound(reason),
              backoff_ms: backoff_ms
            },
            context
          )

          if backoff_ms > 0, do: Process.sleep(backoff_ms)
          retry_loop(policy, inner, params, attempt + 1, context)
        else
          emit(
            :retry_exhausted,
            %{policy_kind: :retry, attempt: attempt, reason: Telemetry.bound(reason)},
            context
          )

          err
        end
    end
  end

  # --- Telemetry helpers ----------------------------------------------------

  defp cache_metadata(key), do: %{policy_kind: :cache, key: Telemetry.bound(key)}

  # The event's own keys win: a caller's `metadata:` may not relabel
  # `policy_kind` or overwrite the digest.
  defp emit(event_name, metadata, context) do
    :telemetry.execute(
      [:raxol, :agent, :policy, event_name],
      %{},
      Map.merge(context, metadata)
    )
  end

  defp emit_applied(policies, result, context) do
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
      Map.merge(context, %{policy_kinds: kinds, outcome: tag})
    )
  end
end
