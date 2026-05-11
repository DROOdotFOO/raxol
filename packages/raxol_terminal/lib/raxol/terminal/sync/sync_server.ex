defmodule Raxol.Terminal.Sync.SyncServer do
  @moduledoc """
  Unified synchronization system for the Raxol terminal emulator.
  This module provides centralized synchronization mechanisms for:
  - State synchronization between windows
  - Event synchronization
  - Resource synchronization
  """

  use Raxol.Core.Behaviours.BaseManager
  require Logger

  # Types
  @type sync_id :: term()
  @type sync_state :: %{
          id: sync_id(),
          type: :state | :event | :resource,
          data: term(),
          version: non_neg_integer(),
          timestamp: integer(),
          metadata: map()
        }
  @type sync_config :: %{
          consistency: :strong | :eventual,
          conflict_resolution: :last_write_wins | :version_based,
          timeout: non_neg_integer(),
          retry_count: non_neg_integer()
        }

  # Client API

  # Helper function to get the process name
  defp process_name(pid) when is_pid(pid), do: pid
  defp process_name(name) when is_atom(name), do: name
  defp process_name(_), do: __MODULE__

  @doc """
  Creates a new synchronization context.

  ## Parameters
    * `type` - Type of synchronization (:state, :event, or :resource)
    * `opts` - Creation options
      * `:consistency` - Consistency level
      * `:conflict_resolution` - Conflict resolution strategy
      * `:timeout` - Synchronization timeout
      * `:retry_count` - Number of retry attempts
  """
  def create_sync(type, opts \\ [], process \\ __MODULE__) do
    GenServer.call(process_name(process), {:create_sync, type, opts})
  end

  @doc """
  Synchronizes data between windows.

  ## Parameters
    * `sync_id` - The synchronization context ID
    * `data` - The data to synchronize
    * `opts` - Synchronization options
      * `:version` - Current version of the data
      * `:metadata` - Additional metadata
  """
  def sync(sync_id, data, opts \\ [], process \\ __MODULE__) do
    GenServer.call(process_name(process), {:sync, sync_id, data, opts})
  end

  @doc """
  Gets the current state of a synchronization context.

  ## Parameters
    * `sync_id` - The synchronization context ID
  """
  def get_sync_state(sync_id, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:get_sync_state, sync_id})
  end

  @doc """
  Resolves conflicts between synchronized data.

  ## Parameters
    * `sync_id` - The synchronization context ID
    * `conflicts` - List of conflicting versions
    * `opts` - Resolution options
      * `:strategy` - Override the default conflict resolution strategy
  """
  def resolve_conflicts(sync_id, conflicts, opts \\ [], process \\ __MODULE__) do
    GenServer.call(
      process_name(process),
      {:resolve_conflicts, sync_id, conflicts, opts}
    )
  end

  @doc """
  Cleans up a synchronization context.

  ## Parameters
    * `sync_id` - The synchronization context ID
  """
  def cleanup(sync_id, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:cleanup, sync_id})
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    consistency = Keyword.get(opts, :consistency, :strong)

    conflict_resolution =
      Keyword.get(opts, :conflict_resolution, :last_write_wins)

    timeout = Keyword.get(opts, :timeout, 5000)
    retry_count = Keyword.get(opts, :retry_count, 3)

    state = %{
      syncs: %{},
      config: %{
        consistency: consistency,
        conflict_resolution: conflict_resolution,
        timeout: timeout,
        retry_count: retry_count
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:create_sync, type, opts}, _from, state) do
    sync_id = generate_sync_id()
    config = build_sync_config(opts, state.config)

    sync_state = %{
      id: sync_id,
      type: type,
      data: nil,
      version: 0,
      timestamp: System.system_time(:millisecond),
      metadata: %{}
    }

    updated_state = %{
      state
      | syncs: Map.put(state.syncs, sync_id, {sync_state, config})
    }

    {:reply, {:ok, sync_id}, updated_state}
  end

  @impl true
  def handle_manager_call({:sync, sync_id, data, opts}, _from, state) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        {:reply, {:error, :sync_not_found}, state}

      {sync_state, config} ->
        version = Keyword.get(opts, :version, sync_state.version)
        metadata = Keyword.get(opts, :metadata, %{})

        case do_sync(sync_state, data, version, metadata, config) do
          {:ok, updated_sync_state} ->
            updated_state = %{
              state
              | syncs: Map.put(state.syncs, sync_id, {updated_sync_state, config})
            }

            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_manager_call({:get_sync_state, sync_id}, _from, state) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        {:reply, {:error, :sync_not_found}, state}

      {sync_state, _config} ->
        {:reply, {:ok, sync_state}, state}
    end
  end

  @impl true
  def handle_manager_call(
        {:resolve_conflicts, sync_id, conflicts, opts},
        _from,
        state
      ) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        {:reply, {:error, :sync_not_found}, state}

      {sync_state, config} ->
        strategy = Keyword.get(opts, :strategy, config.conflict_resolution)

        case do_resolve_conflicts(conflicts, strategy) do
          {:ok, resolved_data} ->
            updated_sync_state = %{
              sync_state
              | data: resolved_data,
                version: sync_state.version + 1,
                timestamp: System.system_time(:millisecond)
            }

            updated_state = %{
              state
              | syncs: Map.put(state.syncs, sync_id, {updated_sync_state, config})
            }

            {:reply, {:ok, resolved_data}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_manager_call({:cleanup, sync_id}, _from, state) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        {:reply, {:error, :sync_not_found}, state}

      _ ->
        updated_state = %{state | syncs: Map.delete(state.syncs, sync_id)}
        {:reply, :ok, updated_state}
    end
  end

  # Private Functions

  defp generate_sync_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16()
  end

  defp build_sync_config(opts, default_config) do
    %{
      consistency: Keyword.get(opts, :consistency, default_config.consistency),
      conflict_resolution:
        Keyword.get(
          opts,
          :conflict_resolution,
          default_config.conflict_resolution
        ),
      timeout: Keyword.get(opts, :timeout, default_config.timeout),
      retry_count: Keyword.get(opts, :retry_count, default_config.retry_count)
    }
  end

  defp do_sync(sync_state, data, version, metadata, config) do
    case version < sync_state.version do
      true ->
        {:error, :version_conflict}

      false ->
        case config.consistency do
          :strong ->
            do_strong_sync(sync_state, data, version, metadata, config)

          :eventual ->
            do_eventual_sync(sync_state, data, version, metadata, config)
        end
    end
  end

  defp do_strong_sync(sync_state, data, version, metadata, config) do
    # Implement two-phase commit for strong consistency
    case prepare_commit(sync_state, data, version, metadata) do
      {:ok, prepared_state} ->
        case commit(prepared_state, config) do
          {:ok, committed_state} ->
            {:ok, committed_state}

          {:error, reason} ->
            rollback(prepared_state)
            {:error, reason}
        end
    end
  end

  defp do_eventual_sync(sync_state, data, version, metadata, _config) do
    # For eventual consistency, we can update immediately
    updated_state = %{
      sync_state
      | data: data,
        version: version + 1,
        timestamp: System.system_time(:millisecond),
        metadata: Map.merge(sync_state.metadata, metadata)
    }

    {:ok, updated_state}
  end

  defp prepare_commit(sync_state, data, version, metadata) do
    # Simulate prepare phase
    {:ok,
     %{
       sync_state
       | data: data,
         version: version + 1,
         timestamp: System.system_time(:millisecond),
         metadata: Map.merge(sync_state.metadata, metadata)
     }}
  end

  defp commit(state, config) do
    # Simulate commit phase with retries
    do_commit(state, config.retry_count, config.timeout)
  end

  defp do_commit(_state, 0, _timeout), do: {:error, :commit_failed}

  defp do_commit(state, _retries, _timeout) do
    # Simulate commit operation
    # Simulate network delay
    Process.sleep(100)
    {:ok, state}
  end

  defp rollback(_state) do
    # Simulate rollback operation
    :ok
  end

  defp do_resolve_conflicts(conflicts, strategy) do
    case strategy do
      :last_write_wins -> resolve_last_write_wins(conflicts)
      :version_based -> resolve_version_based(conflicts)
    end
  end

  defp resolve_last_write_wins(conflicts) do
    case Enum.max_by(conflicts, fn {_, timestamp, _} -> timestamp end) do
      {data, _, _} -> {:ok, data}
      nil -> {:error, :no_conflicts}
    end
  end

  defp resolve_version_based(conflicts) do
    case Enum.max_by(conflicts, fn {_, _, version} -> version end) do
      {data, _, _} -> {:ok, data}
      nil -> {:error, :no_conflicts}
    end
  end
end
