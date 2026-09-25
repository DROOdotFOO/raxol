defmodule Raxol.Terminal.Sync.System do
  @moduledoc """
  Unified synchronization system for the terminal emulator.
  Handles synchronization between splits, windows, and tabs with different consistency levels.
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  # Types
  @type sync_id :: String.t()
  @type sync_key :: String.t()
  @type sync_value :: term()
  @type sync_metadata :: %{
          version: non_neg_integer(),
          timestamp: non_neg_integer(),
          source: String.t(),
          consistency: :strong | :eventual | :causal
        }
  @type sync_entry :: %{
          key: sync_key(),
          value: sync_value(),
          metadata: sync_metadata()
        }
  @type sync_stats :: %{
          sync_count: non_neg_integer(),
          conflict_count: non_neg_integer(),
          last_sync: non_neg_integer(),
          consistency_levels: %{atom() => non_neg_integer()}
        }

  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  def sync(sync_id, key, value, opts \\ []) do
    Log.debug(
      "[System] sync called: sync_id=#{sync_id}, key=#{key}, value=#{inspect(value)}, opts=#{inspect(opts)}"
    )

    GenServer.call(__MODULE__, {:sync, sync_id, key, value, opts})
  end

  def get(sync_id, key) do
    GenServer.call(__MODULE__, {:get, sync_id, key})
  end

  def get_all(sync_id) do
    GenServer.call(__MODULE__, {:get_all, sync_id})
  end

  def delete(sync_id, key) do
    GenServer.call(__MODULE__, {:delete, sync_id, key})
  end

  def clear(sync_id) do
    GenServer.call(__MODULE__, {:clear, sync_id})
  end

  def stats(sync_id) do
    GenServer.call(__MODULE__, {:stats, sync_id})
  end

  # Server Callbacks
  @impl true
  def init_manager(opts) do
    # Convert keyword list to map if needed
    opts_map = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    state = %{
      # sync_id => %{key => sync_entry}
      syncs: %{},
      # sync_id => sync_stats
      stats: %{},
      consistency_levels:
        Map.get(opts_map, :consistency_levels, %{
          split: :strong,
          window: :strong,
          tab: :eventual
        })
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:sync, sync_id, key, value, opts}, _from, state) do
    # Convert keyword list to map if needed
    opts_map = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    consistency =
      Map.get(
        opts_map,
        :consistency,
        Map.get(state.consistency_levels, sync_id, :eventual)
      )

    metadata = %{
      version: Map.get(opts_map, :version, System.monotonic_time()),
      timestamp: System.system_time(),
      source: Map.get(opts_map, :source, "unknown"),
      consistency: consistency
    }

    case do_sync(state, sync_id, key, value, metadata) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, :conflict, new_state} ->
        {:reply, {:error, :conflict}, new_state}
    end
  end

  @impl true
  def handle_manager_call({:get, sync_id, key}, _from, state) do
    case get_sync_entry(state, sync_id, key) do
      {:ok, entry} -> {:reply, {:ok, entry.value}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call({:get_all, sync_id}, _from, state) do
    case Map.get(state.syncs, sync_id) do
      nil -> {:reply, {:error, :not_found}, state}
      sync_data -> {:reply, {:ok, sync_data}, state}
    end
  end

  @impl true
  def handle_manager_call({:delete, sync_id, key}, _from, state) do
    new_state = delete_sync_entry(state, sync_id, key)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:clear, sync_id}, _from, state) do
    new_state = clear_sync_entries(state, sync_id)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:stats, sync_id}, _from, state) do
    case Map.get(state.stats, sync_id) do
      nil -> {:reply, {:error, :not_found}, state}
      stats -> {:reply, {:ok, stats}, state}
    end
  end

  # Private Functions
  defp do_sync(state, sync_id, key, value, metadata) do
    case get_sync_entry(state, sync_id, key) do
      {:ok, existing_entry} ->
        handle_existing_sync(
          state,
          sync_id,
          key,
          value,
          metadata,
          existing_entry
        )

      {:error, :not_found} ->
        handle_new_sync(state, sync_id, key, value, metadata)
    end
  end

  defp handle_existing_sync(
         state,
         sync_id,
         key,
         value,
         metadata,
         existing_entry
       ) do
    case resolve_conflict(metadata, existing_entry.metadata) do
      :keep_existing ->
        {:ok, state}

      :use_new ->
        new_state = update_sync_entry(state, sync_id, key, value, metadata)
        {:ok, new_state}

      :conflict ->
        new_state = increment_conflict_count(state, sync_id)
        {:error, :conflict, new_state}
    end
  end

  defp handle_new_sync(state, sync_id, key, value, metadata) do
    new_state = update_sync_entry(state, sync_id, key, value, metadata)
    {:ok, new_state}
  end

  defp resolve_conflict(new_metadata, existing_metadata) do
    case {new_metadata.consistency, existing_metadata.consistency} do
      {:strong, :strong} ->
        case new_metadata.version > existing_metadata.version do
          true -> :use_new
          false -> :keep_existing
        end

      {:strong, _} ->
        :use_new

      {_, :strong} ->
        :keep_existing

      {_, _} ->
        case new_metadata.version > existing_metadata.version do
          true -> :use_new
          false -> :conflict
        end
    end
  end

  defp get_sync_entry(state, sync_id, key) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        {:error, :not_found}

      sync_data ->
        case Map.fetch(sync_data, key) do
          {:ok, entry} -> {:ok, entry}
          :error -> {:error, :not_found}
        end
    end
  end

  defp update_sync_entry(state, sync_id, key, value, metadata) do
    entry = %{key: key, value: value, metadata: metadata}
    sync_data = Map.get(state.syncs, sync_id, %{})
    new_sync_data = Map.put(sync_data, key, entry)
    new_syncs = Map.put(state.syncs, sync_id, new_sync_data)
    new_stats = update_sync_stats(state.stats, sync_id, metadata.consistency)
    %{state | syncs: new_syncs, stats: new_stats}
  end

  defp delete_sync_entry(state, sync_id, key) do
    case Map.get(state.syncs, sync_id) do
      nil ->
        state

      sync_data ->
        new_sync_data = Map.delete(sync_data, key)
        new_syncs = Map.put(state.syncs, sync_id, new_sync_data)
        %{state | syncs: new_syncs}
    end
  end

  defp clear_sync_entries(state, sync_id) do
    new_syncs = Map.delete(state.syncs, sync_id)
    new_stats = Map.delete(state.stats, sync_id)
    %{state | syncs: new_syncs, stats: new_stats}
  end

  defp update_sync_stats(stats, sync_id, consistency) do
    sync_stats =
      Map.get(stats, sync_id, %{
        sync_count: 0,
        conflict_count: 0,
        last_sync: 0,
        consistency_levels: %{strong: 0, eventual: 0, causal: 0}
      })

    new_sync_stats = %{
      sync_stats
      | sync_count: sync_stats.sync_count + 1,
        last_sync: System.monotonic_time(),
        consistency_levels: Map.update(sync_stats.consistency_levels, consistency, 1, &(&1 + 1))
    }

    Map.put(stats, sync_id, new_sync_stats)
  end

  defp increment_conflict_count(state, sync_id) do
    sync_stats = Map.get(state.stats, sync_id)

    new_sync_stats = %{
      sync_stats
      | conflict_count: sync_stats.conflict_count + 1
    }

    %{state | stats: Map.put(state.stats, sync_id, new_sync_stats)}
  end

  @doc """
  Gets the current monotonic time in the specified unit.
  """
  @spec monotonic_time(:millisecond | :microsecond | :nanosecond) :: integer()
  def monotonic_time(unit) do
    System.monotonic_time(unit)
  end

  @doc """
  Gets the current system time in the specified unit.
  """
  @spec system_time(:millisecond | :microsecond | :nanosecond) :: integer()
  def system_time(unit) do
    System.system_time(unit)
  end
end
