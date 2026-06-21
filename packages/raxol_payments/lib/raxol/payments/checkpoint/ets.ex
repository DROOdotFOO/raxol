defmodule Raxol.Payments.Checkpoint.ETS do
  @moduledoc """
  ETS-backed `Raxol.Payments.Checkpoint` store.

  The table is `:public` so any process can read and write it, and it is owned
  by whichever process calls `new/1`. For the recovery this checkpoint exists to
  provide, that owner must outlive the agent it protects: a table owned by the
  crashing agent dies with it. Create it from a supervisor-level process (the
  cockpit, a `DynamicSupervisor`, or the application) so an in-flight record
  survives the agent's restart.

  This survives a process crash, not a VM restart. Back the same behaviour with
  DETS or a database when cross-restart durability is required.
  """

  @behaviour Raxol.Payments.Checkpoint

  @doc """
  Create a table and return the `{module, handle}` store to put in the context.

  Pass a `name` for a named table (convenient to address and assert on in
  tests); omit it for an anonymous table addressed by its returned reference.
  """
  @spec new(atom() | nil) :: Raxol.Payments.Checkpoint.store()
  def new(name \\ nil) do
    table =
      case name do
        nil -> :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
        name when is_atom(name) -> ensure_named(name)
      end

    {__MODULE__, table}
  end

  defp ensure_named(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        name
    end
  end

  @impl true
  def fetch(table, key) do
    case :ets.lookup(table, key) do
      [{^key, record}] -> {:ok, record}
      [] -> :error
    end
  end

  @impl true
  def put(table, key, record) do
    :ets.insert(table, {key, record})
    :ok
  end

  @impl true
  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  end
end
