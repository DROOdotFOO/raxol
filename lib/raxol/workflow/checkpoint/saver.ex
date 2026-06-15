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
end
