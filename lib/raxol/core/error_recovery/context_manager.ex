defmodule Raxol.Core.ErrorRecovery.ContextManager do
  @moduledoc """
  Manages context preservation across process restarts.

  This module ensures that critical state and context information
  is preserved when processes are restarted, enabling faster
  recovery and reducing the impact of failures.

  ## Features

  - Automatic context capture before process termination
  - Intelligent context merging on restoration
  - TTL-based context cleanup
  - Serializable context storage
  - Performance-optimized retrieval

  ## Usage

      # Store context for a process
      ContextManager.store_context(:my_process, %{
        user_sessions: active_sessions,
        cached_data: important_cache,
        connection_state: conn_info
      })

      # Retrieve context after restart
      context = ContextManager.get_context(:my_process)
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log

  @table_name :raxol_recovery_context
  # 1 minute
  @cleanup_interval Raxol.Core.Defaults.cleanup_interval_ms()
  # 5 minutes
  @default_ttl Raxol.Core.Defaults.cooldown_ms()

  defstruct [
    :table,
    :ttl_ms,
    :last_cleanup
  ]

  @type context_data :: term()
  @type context_key :: term()

  @type context_entry :: %{
          key: context_key(),
          data: context_data(),
          stored_at: DateTime.t(),
          ttl_ms: non_neg_integer(),
          access_count: non_neg_integer(),
          last_accessed: DateTime.t()
        }

  # Public API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Store context data for a process or component.
  """
  def store_context(key, data, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl)
    GenServer.cast(__MODULE__, {:store_context, key, data, ttl_ms})
  end

  @doc """
  Retrieve context data for a process or component.
  """
  def get_context(key) do
    GenServer.call(__MODULE__, {:get_context, key})
  end

  @doc """
  Check if context exists for a key.
  """
  def has_context?(key) do
    GenServer.call(__MODULE__, {:has_context, key})
  end

  @doc """
  Remove context data for a key.
  """
  def remove_context(key) do
    GenServer.cast(__MODULE__, {:remove_context, key})
  end

  @doc """
  Update existing context data by merging with new data.
  """
  def update_context(key, data, merge_fun \\ &Map.merge/2) do
    GenServer.cast(__MODULE__, {:update_context, key, data, merge_fun})
  end

  @doc """
  Get statistics about stored contexts.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Export all contexts for backup or analysis.
  """
  def export_contexts do
    GenServer.call(__MODULE__, :export_contexts)
  end

  @doc """
  Import contexts from backup data.
  """
  def import_contexts(contexts_data) do
    GenServer.cast(__MODULE__, {:import_contexts, contexts_data})
  end

  @doc """
  Manually trigger cleanup of expired contexts.
  """
  def cleanup_expired do
    GenServer.cast(__MODULE__, :cleanup_expired)
  end

  # GenServer implementation

  @impl true
  def init_manager(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl)

    # Generate unique table name for test isolation
    table_name =
      if Application.get_env(:raxol, :env) == :test do
        :"raxol_recovery_context_#{:erlang.unique_integer([:positive])}"
      else
        @table_name
      end

    # Create ETS table for fast context storage
    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true}
          ])

        existing ->
          # In test mode, clean existing table
          if Application.get_env(:raxol, :env) == :test do
            :ets.delete_all_objects(existing)
          end

          existing
      end

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %__MODULE__{
      table: table,
      ttl_ms: ttl_ms,
      last_cleanup: DateTime.utc_now()
    }

    Log.info("ContextManager started with TTL: #{ttl_ms}ms")

    {:ok, state}
  end

  @impl true
  def handle_manager_cast({:store_context, key, data, ttl_ms}, state) do
    entry = %{
      key: key,
      data: data,
      stored_at: DateTime.utc_now(),
      ttl_ms: ttl_ms,
      access_count: 0,
      last_accessed: DateTime.utc_now()
    }

    :ets.insert(state.table, {key, entry})

    Log.debug("Context stored for key: #{inspect(key)}")

    {:noreply, state}
  end

  @impl true
  def handle_manager_cast({:remove_context, key}, state) do
    :ets.delete(state.table, key)

    Log.debug("Context removed for key: #{inspect(key)}")

    {:noreply, state}
  end

  @impl true
  def handle_manager_cast({:update_context, key, new_data, merge_fun}, state) do
    case :ets.lookup(state.table, key) do
      [{^key, entry}] ->
        updated_data = merge_fun.(entry.data, new_data)

        updated_entry = %{
          entry
          | data: updated_data,
            last_accessed: DateTime.utc_now(),
            access_count: entry.access_count + 1
        }

        :ets.insert(state.table, {key, updated_entry})

        Log.debug("Context updated for key: #{inspect(key)}")

      [] ->
        # Context doesn't exist, create new one
        store_context(key, new_data)
    end

    {:noreply, state}
  end

  @impl true
  def handle_manager_cast({:import_contexts, contexts_data}, state) do
    imported_count =
      contexts_data
      |> Enum.map(fn {key, data} ->
        entry = %{
          key: key,
          data: data,
          stored_at: DateTime.utc_now(),
          ttl_ms: state.ttl_ms,
          access_count: 0,
          last_accessed: DateTime.utc_now()
        }

        :ets.insert(state.table, {key, entry})
      end)
      |> length()

    Log.info("Imported #{imported_count} contexts")

    {:noreply, state}
  end

  @impl true
  def handle_manager_cast(:cleanup_expired, state) do
    {expired_count, new_state} = cleanup_expired_contexts(state)

    Log.debug("Cleaned up #{expired_count} expired contexts")

    {:noreply, new_state}
  end

  @impl true
  def handle_manager_call({:get_context, key}, _from, state) do
    context =
      case :ets.lookup(state.table, key) do
        [{^key, entry}] ->
          # Check if expired
          if context_expired?(entry) do
            :ets.delete(state.table, key)
            nil
          else
            # Update access info
            updated_entry = %{
              entry
              | last_accessed: DateTime.utc_now(),
                access_count: entry.access_count + 1
            }

            :ets.insert(state.table, {key, updated_entry})

            entry.data
          end

        [] ->
          nil
      end

    {:reply, context, state}
  end

  @impl true
  def handle_manager_call({:has_context, key}, _from, state) do
    exists =
      case :ets.lookup(state.table, key) do
        [{^key, entry}] -> not context_expired?(entry)
        [] -> false
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_manager_call(:get_stats, _from, state) do
    all_contexts = :ets.tab2list(state.table)

    stats = %{
      total_contexts: length(all_contexts),
      expired_contexts: count_expired_contexts(all_contexts),
      memory_usage_bytes:
        :ets.info(state.table, :memory) * :erlang.system_info(:wordsize),
      last_cleanup: state.last_cleanup,
      average_access_count: calculate_average_access_count(all_contexts),
      contexts_by_age: group_contexts_by_age(all_contexts)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_call(:export_contexts, _from, state) do
    contexts =
      :ets.tab2list(state.table)
      |> Enum.reject(fn {_key, entry} -> context_expired?(entry) end)
      |> Enum.map(fn {key, entry} -> {key, entry.data} end)
      |> Map.new()

    {:reply, contexts, state}
  end

  @impl true
  def handle_manager_info(:cleanup_expired, state) do
    {expired_count, new_state} = cleanup_expired_contexts(state)

    if expired_count > 0 do
      Log.debug("Periodic cleanup removed #{expired_count} expired contexts")
    end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info(_msg, state) do
    {:noreply, state}
  end

  # Private implementation

  defp context_expired?(entry) do
    expires_at = DateTime.add(entry.stored_at, entry.ttl_ms, :millisecond)
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp cleanup_expired_contexts(state) do
    all_contexts = :ets.tab2list(state.table)

    expired_keys =
      all_contexts
      |> Enum.filter(fn {_key, entry} -> context_expired?(entry) end)
      |> Enum.map(fn {key, _entry} -> key end)

    # Remove expired contexts
    Enum.each(expired_keys, fn key ->
      :ets.delete(state.table, key)
    end)

    expired_count = length(expired_keys)

    updated_state = %{state | last_cleanup: DateTime.utc_now()}

    {expired_count, updated_state}
  end

  defp count_expired_contexts(contexts) do
    Enum.count(contexts, fn {_key, entry} -> context_expired?(entry) end)
  end

  defp calculate_average_access_count(contexts) do
    if contexts == [] do
      0
    else
      total_accesses =
        contexts
        |> Enum.map(fn {_key, entry} -> entry.access_count end)
        |> Enum.sum()

      total_accesses / length(contexts)
    end
  end

  defp group_contexts_by_age(contexts) do
    now = DateTime.utc_now()

    contexts
    |> Enum.group_by(fn {_key, entry} ->
      age_seconds = DateTime.diff(now, entry.stored_at)

      cond do
        age_seconds < 60 -> :under_1_min
        age_seconds < 300 -> :under_5_min
        age_seconds < 900 -> :under_15_min
        true -> :over_15_min
      end
    end)
    |> Enum.map(fn {age_group, contexts} -> {age_group, length(contexts)} end)
    |> Map.new()
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval)
  end
end
