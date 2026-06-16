defmodule Raxol.Agent.ThreadLog do
  @moduledoc """
  Behaviour for `Raxol.Agent.ThreadEvent` persistence.

  Implementations decide the storage medium. Two adapters ship with
  raxol_agent today:

    * `Raxol.Agent.ThreadLog.Ets` -- in-process, ordered_set on
      `{thread_id, sequence}`; ephemeral, fast, the default for
      single-node agents.
    * `Raxol.Agent.ThreadLog.Postgrex` -- Postgres-backed via the
      optional `:postgrex` dep; for cross-process or multi-node
      durable thread logs.

  A `Raxol.Agent.ThreadLog.Dets` adapter for single-node durable
  logs is a deliberate follow-up; the Ets ↔ Postgrex pair covers the
  two most common shapes (single-node ephemeral, multi-node durable).

  ## Sequence assignment

  The adapter assigns `sequence` atomically per `thread_id` on
  `append/4`. Callers do not pick the number. Within a `thread_id`,
  sequences start at 0 and increase strictly monotonically. The
  `{thread_id, sequence}` pair is the unique key.

  ## Concurrency contract

  Adapters assume **single-writer per thread_id**. The expected
  pattern is one agent process owning one thread_id. Multi-writer
  scenarios (two agents writing to the same thread_id concurrently)
  may produce primary-key conflicts that the Postgrex adapter
  retries internally up to three times; under heavier contention,
  callers should serialize through a single owning process.

  The Ets adapter uses `:ets.update_counter` for sequence
  allocation, which is atomic for arbitrary concurrent writers.
  Sequence ordering is preserved.

  ## Querying

  `list/3` returns events in sequence order (ascending by default,
  override with `:order`). `list_by_kind/4` filters; the kind set
  is open (see `Raxol.Agent.ThreadEvent`). `latest/2` is sugar for
  the highest-sequence event. `truncate/3` removes events with
  `sequence < before`, retaining the tail.

  ## Configuration

  When wired into an agent's `thread_log/0` callback:

      def thread_log do
        {Raxol.Agent.ThreadLog.Postgrex,
         %{conn: MyApp.Postgrex, table: "agent_threads"}}
      end

  Bare modules (no tuple) inherit `%{}`.
  """

  alias Raxol.Agent.ThreadEvent

  @typedoc "Per-call configuration map passed to every callback."
  @type config :: map()

  @typedoc "Thread identifier; arbitrary binary."
  @type thread_id :: binary()

  @typedoc "Monotonic sequence within a thread; starts at 0."
  @type sequence :: non_neg_integer()

  @typedoc """
  Options accepted by `list/3` and `list_by_kind/4`:

    * `:from` -- starting sequence (inclusive). Default: 0.
    * `:to` -- ending sequence (inclusive). Default: no limit.
    * `:limit` -- max events returned. Default: 1000.
    * `:order` -- `:asc` (default) or `:desc`.
  """
  @type list_opts :: keyword()

  @doc """
  Append an event. The adapter assigns the next sequence for the
  given `thread_id` atomically and returns the materialized event.

  `opts`:
    * `:metadata` -- arbitrary map; preserved verbatim.
    * `:recorded_at` -- override the timestamp (default
      `DateTime.utc_now/0`).
  """
  @callback append(
              config(),
              thread_id(),
              ThreadEvent.kind(),
              payload :: term(),
              opts :: keyword()
            ) :: {:ok, ThreadEvent.t()} | {:error, term()}

  @doc "Return all events for `thread_id` matching `opts`."
  @callback list(config(), thread_id(), list_opts()) :: {:ok, [ThreadEvent.t()]}

  @doc "Return events of `kind` for `thread_id`, sequence-ordered per `opts`."
  @callback list_by_kind(
              config(),
              thread_id(),
              ThreadEvent.kind(),
              list_opts()
            ) :: {:ok, [ThreadEvent.t()]}

  @doc "Return the highest-sequence event for `thread_id`."
  @callback latest(config(), thread_id()) ::
              {:ok, ThreadEvent.t()} | {:error, :not_found}

  @doc """
  Remove events with `sequence < before` for `thread_id`. The tail
  (events at or after `before`) is retained. Useful for retention
  policies.
  """
  @callback truncate(config(), thread_id(), before :: sequence()) ::
              :ok | {:error, term()}

  # --- Module-level dispatcher --------------------------------------------

  @doc """
  Normalize the thread-log opt into `{module, config}` form.

  Accepts a bare module, a `{module, config}` tuple, or `nil`.
  Returns `nil` for `nil` input.
  """
  @spec normalize(module() | {module(), config()} | nil) ::
          {module(), config()} | nil
  def normalize(nil), do: nil

  def normalize({module, config}) when is_atom(module) and is_map(config),
    do: {module, config}

  def normalize(module) when is_atom(module), do: {module, %{}}

  @doc """
  Dispatch `append` to the adapter. Returns `{:ok, event}` or
  `{:error, reason}`. Returns `{:ok, :no_log}` when the adapter
  tuple is `nil` so callers can treat "no thread log" as
  "successfully no-op" without branching.
  """
  @spec append(
          {module(), config()} | nil,
          thread_id(),
          ThreadEvent.kind(),
          term(),
          keyword()
        ) :: {:ok, ThreadEvent.t() | :no_log} | {:error, term()}
  def append(adapter, thread_id, kind, payload, opts \\ [])

  def append(nil, _thread_id, _kind, _payload, _opts), do: {:ok, :no_log}

  def append({module, config}, thread_id, kind, payload, opts)
      when is_atom(module) and is_binary(thread_id) and is_atom(kind),
      do: module.append(config, thread_id, kind, payload, opts)

  @doc "Dispatch `list` to the adapter. Returns `{:ok, []}` for `nil` adapter."
  @spec list({module(), config()} | nil, thread_id(), list_opts()) ::
          {:ok, [ThreadEvent.t()]}
  def list(adapter, thread_id, opts \\ [])
  def list(nil, _thread_id, _opts), do: {:ok, []}

  def list({module, config}, thread_id, opts) when is_atom(module),
    do: module.list(config, thread_id, opts)

  @doc "Dispatch `list_by_kind`. Returns `{:ok, []}` for `nil` adapter."
  @spec list_by_kind(
          {module(), config()} | nil,
          thread_id(),
          ThreadEvent.kind(),
          list_opts()
        ) :: {:ok, [ThreadEvent.t()]}
  def list_by_kind(adapter, thread_id, kind, opts \\ [])
  def list_by_kind(nil, _thread_id, _kind, _opts), do: {:ok, []}

  def list_by_kind({module, config}, thread_id, kind, opts)
      when is_atom(module),
      do: module.list_by_kind(config, thread_id, kind, opts)

  @doc "Dispatch `latest`. Returns `{:error, :not_found}` for `nil` adapter."
  @spec latest({module(), config()} | nil, thread_id()) ::
          {:ok, ThreadEvent.t()} | {:error, :not_found}
  def latest(nil, _thread_id), do: {:error, :not_found}

  def latest({module, config}, thread_id) when is_atom(module),
    do: module.latest(config, thread_id)

  @doc "Dispatch `truncate`. No-op for `nil` adapter."
  @spec truncate({module(), config()} | nil, thread_id(), sequence()) ::
          :ok | {:error, term()}
  def truncate(nil, _thread_id, _before), do: :ok

  def truncate({module, config}, thread_id, before)
      when is_atom(module) and is_integer(before) and before >= 0,
      do: module.truncate(config, thread_id, before)
end
