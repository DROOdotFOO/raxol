defmodule Raxol.Core.CompilerState do
  @moduledoc """
  Thread-safe ETS table management for Raxol's plugin command registry.

  Atomic ETS operations are guarded with `try/rescue ArgumentError` to cover
  the race window where another process deletes the table between the
  existence check and the operation. ETS lookup/insert/delete are atomic and
  microsecond-scale; no process isolation is needed.
  """

  @default_opts [:named_table, :public, :set, {:read_concurrency, true}]

  @doc """
  Ensures an ETS table exists, creating it if missing.

  Idempotent. Returns `:ok` if the table already exists or was created.
  """
  @spec ensure_table(atom() | :ets.tid(), list()) ::
          :ok | {:error, term()}
  def ensure_table(name, opts \\ @default_opts) do
    case :ets.info(name) do
      :undefined -> create_table(name, opts)
      _ -> :ok
    end
  end

  @doc """
  Safe ETS lookup. Returns `{:ok, rows}` or `{:error, :table_not_found}`.
  """
  @spec safe_lookup(atom() | :ets.tid(), term()) ::
          {:ok, list()} | {:error, :table_not_found}
  def safe_lookup(table, key) do
    {:ok, :ets.lookup(table, key)}
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Safe ETS insert. Returns `:ok` or `{:error, :table_not_found}`.
  """
  @spec safe_insert(atom() | :ets.tid(), tuple() | [tuple()]) ::
          :ok | {:error, :table_not_found}
  def safe_insert(table, data) do
    _ = :ets.insert(table, data)
    :ok
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Safe ETS delete by key. Returns `:ok` or `{:error, :table_not_found}`.
  """
  @spec safe_delete(atom() | :ets.tid(), term()) ::
          :ok | {:error, :table_not_found}
  def safe_delete(table, key) do
    _ = :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  @doc """
  Safe ETS table deletion. Returns `:ok` or `{:error, :table_not_found}`.
  """
  @spec safe_delete_table(atom() | :ets.tid()) ::
          :ok | {:error, :table_not_found}
  def safe_delete_table(table) do
    _ = :ets.delete(table)
    :ok
  rescue
    ArgumentError -> {:error, :table_not_found}
  end

  defp create_table(name, opts) do
    _ = :ets.new(name, opts)
    :ok
  rescue
    ArgumentError ->
      # Another process created the table between our check and ours
      if :ets.info(name) != :undefined,
        do: :ok,
        else: {:error, :creation_failed}
  end
end
