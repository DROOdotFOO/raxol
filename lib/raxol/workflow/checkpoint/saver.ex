defmodule Raxol.Workflow.Checkpoint.Saver do
  @moduledoc """
  Behaviour for `Raxol.Workflow.Checkpoint` persistence.

  Implementations decide the storage medium (ETS, DETS, Postgrex,
  etc.). Three adapters ship with raxol:

    * `Raxol.Workflow.Checkpoint.Saver.Ets` -- in-process, named
      ETS table. Default for tests and short-lived runs.
    * `Raxol.Workflow.Checkpoint.Saver.Dets` -- file-backed
      GenServer. Default for runs that should survive BEAM restarts.
    * `Raxol.Workflow.Checkpoint.Saver.Postgrex` -- Postgres-backed
      via the optional `:postgrex` dependency. Default for runs that
      need to be visible across BEAM nodes.

  ## Append-only contract

  `put/3` must be a no-op (return `:ok`) when called with a
  `(thread_id, step)` pair that already exists. Saver implementations
  do not return errors for duplicate writes; that lets the runtime
  retry a checkpoint write idempotently without special-casing.

  ## Configuration

  Implementations receive a per-call `config` map provided by the
  caller. The caller is responsible for ensuring the config is
  consistent across calls for the same thread; the behaviour does
  not enforce this.

  When a saver is wired into a compiled graph, the configuration is
  carried alongside the module:

      Graph.compile(graph, saver: {Saver.Ets, %{table: :my_table}})
      Graph.compile(graph, saver: {Saver.Dets, %{name: MyDets}})

  The runtime destructures `{module, config}` and forwards `config`
  to every behaviour call. A bare module (no tuple) gets `%{}`.
  """

  alias Raxol.Workflow.Checkpoint

  @typedoc "Per-call configuration map passed to every callback."
  @type config :: map()

  @typedoc "Workflow run identifier; same shape as `Checkpoint.thread_id`."
  @type thread_id :: Checkpoint.thread_id()

  @typedoc """
  Structured row returned by `list_paused/2`. The `state` is the
  workflow state at the moment of the pause; `metadata` is the full
  pause-checkpoint metadata including `node_id`, `interrupt_reason`,
  and `paused_at`.
  """
  @type paused :: %{
          thread_id: thread_id(),
          interrupt_reason: any(),
          paused_at: DateTime.t() | nil,
          state: any(),
          metadata: map()
        }

  @doc """
  Append a checkpoint to the thread. Must be idempotent: writing a
  checkpoint with a `(thread_id, step)` pair that already exists is
  a no-op and returns `:ok`.
  """
  @callback put(config(), thread_id(), Checkpoint.t()) :: :ok | {:error, term()}

  @doc """
  Return the most-recently-written checkpoint for the thread, by step
  number. Returns `{:error, :not_found}` if the thread has no
  checkpoints.
  """
  @callback get_latest(config(), thread_id()) ::
              {:ok, Checkpoint.t()} | {:error, :not_found}

  @doc """
  List checkpoints for the thread in newest-first order, up to `limit`.
  Returns `{:ok, []}` when the thread is unknown.
  """
  @callback list(config(), thread_id(), limit :: pos_integer()) ::
              {:ok, [Checkpoint.t()]}

  @doc """
  Remove all checkpoints for the thread. Returns `:ok` even if the
  thread was unknown.
  """
  @callback delete_thread(config(), thread_id()) :: :ok | {:error, term()}

  @doc """
  Return up to `limit` paused threads, newest-paused-first.

  A thread is "paused" when its latest checkpoint carries
  `:interrupt_reason` in metadata (ADR-0017). Resuming a paused thread
  writes a follow-up checkpoint with no `:interrupt_reason`, which
  implicitly removes the thread from this query's result set.

  Optional callback: adapters that do not implement it inherit a
  default implementation in `Raxol.Workflow.Checkpoint.Saver.list_paused/3`
  that delegates to `list/3` per known thread (a slower path).
  """
  @callback list_paused(config(), limit :: pos_integer()) :: {:ok, [paused()]}

  @optional_callbacks list_paused: 2

  @doc """
  Normalize the saver opt into `{module, config}` form.

  Accepts a bare module, a `{module, config}` tuple, or `nil`.
  Returns `nil` for `nil` input, propagating the "no saver configured"
  case through the runtime without special branches at every call site.
  """
  @spec normalize(module() | {module(), config()} | nil) ::
          {module(), config()} | nil
  def normalize(nil), do: nil

  def normalize({module, config}) when is_atom(module) and is_map(config),
    do: {module, config}

  def normalize(module) when is_atom(module), do: {module, %{}}

  @doc """
  Dispatch `list_paused` to the adapter, falling back to a generic
  per-thread scan for adapters that haven't implemented the optional
  callback.

  Always returns `{:ok, [paused()]}`. The fallback can't enumerate
  threads, so for adapters without `list_paused/2` it returns `{:ok, []}`.
  Bespoke adapters with their own thread index should implement the
  callback directly.
  """
  @spec list_paused({module(), config()}, pos_integer()) :: {:ok, [paused()]}
  def list_paused({module, config}, limit)
      when is_atom(module) and is_integer(limit) and limit > 0 do
    if function_exported?(module, :list_paused, 2) do
      module.list_paused(config, limit)
    else
      {:ok, []}
    end
  end

  @doc """
  Convert a pause checkpoint (one whose metadata carries
  `:interrupt_reason`) into the structured `paused()` row returned by
  `list_paused/2`. Useful for adapters whose underlying scan produces
  `Checkpoint.t()` values.
  """
  @spec to_paused_row(Checkpoint.t()) :: paused()
  def to_paused_row(%Checkpoint{} = checkpoint) do
    metadata = checkpoint.metadata || %{}

    %{
      thread_id: checkpoint.thread_id,
      interrupt_reason: Map.get(metadata, :interrupt_reason),
      paused_at: Map.get(metadata, :paused_at),
      state: checkpoint.state,
      metadata: metadata
    }
  end

  @doc """
  Common post-fold pipeline for ETS and DETS adapters: a map of
  `thread_id -> {step, checkpoint}` (the highest-step checkpoint per
  thread) is filtered to pause checkpoints, sorted newest-paused-first,
  truncated to `limit`, and converted to `paused()` rows.

  Adapter `list_paused/2` implementations build the map via their
  storage-specific fold (`:ets.foldl/3` or `:dets.foldl/4`) and hand
  the result to this helper so the rest of the pipeline stays in one
  place.
  """
  @spec paused_rows_from_latest(
          %{Checkpoint.thread_id() => {non_neg_integer(), Checkpoint.t()}},
          pos_integer()
        ) :: [paused()]
  def paused_rows_from_latest(latest_per_thread, limit)
      when is_map(latest_per_thread) and is_integer(limit) and limit > 0 do
    latest_per_thread
    |> Map.values()
    |> Enum.map(fn {_step, checkpoint} -> checkpoint end)
    |> Enum.filter(&paused?/1)
    |> Enum.sort_by(&paused_at_for_sort/1, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.map(&to_paused_row/1)
  end

  @doc """
  Fold accumulator for ETS/DETS `list_paused/2` implementations.
  Receives a single `{{thread_id, step}, checkpoint}` tuple plus the
  accumulator map and retains the highest-step checkpoint per
  `thread_id`. Shared so both adapter folds use the same comparison
  semantics.
  """
  @spec accumulate_latest_per_thread(
          {{Checkpoint.thread_id(), non_neg_integer()}, Checkpoint.t()},
          %{Checkpoint.thread_id() => {non_neg_integer(), Checkpoint.t()}}
        ) ::
          %{Checkpoint.thread_id() => {non_neg_integer(), Checkpoint.t()}}
  def accumulate_latest_per_thread({{thread_id, step}, checkpoint}, acc) do
    case Map.get(acc, thread_id) do
      nil ->
        Map.put(acc, thread_id, {step, checkpoint})

      {prev_step, _prev} when step > prev_step ->
        Map.put(acc, thread_id, {step, checkpoint})

      _ ->
        acc
    end
  end

  defp paused?(%Checkpoint{metadata: meta}) when is_map(meta),
    do: Map.get(meta, :interrupt_reason) != nil

  defp paused?(_), do: false

  # paused_at can be absent on hand-built checkpoints used in tests;
  # fall back to created_at so ordering stays deterministic.
  defp paused_at_for_sort(%Checkpoint{
         metadata: %{paused_at: %DateTime{} = ts}
       }),
       do: ts

  defp paused_at_for_sort(%Checkpoint{created_at: ts}), do: ts
end
