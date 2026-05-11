defmodule Raxol.Core.StateManager do
  @moduledoc """
  Consolidated state management module providing functional, process-based, and ETS-backed state handling.

  This module provides multiple state management strategies with automatic selection:
  - **Functional**: Simple map-based transformations (no processes)
  - **Process-based**: Supervised GenServer state with Agent or GenServer backing
  - **ETS-backed**: High-performance state with ETS storage for large datasets
  - **Domain-specific**: Delegation to specialized domain managers

  ## Configuration

  Set the default strategy in application config:

      config :raxol, :state_manager,
        default_strategy: :functional,  # :functional, :process, :ets
        ets_enabled: true,
        process_supervision: true

  Or control per-call with options:

      StateManager.put(state, :key, value, strategy: :ets)
      StateManager.start_managed(:app_state, %{}, strategy: :process)
  """

  use Agent
  alias Raxol.Core.Runtime.Log
  alias Raxol.Core.StateManager.ETSStrategy
  alias Raxol.Core.StateManager.ProcessStrategy
  use Raxol.Core.Behaviours.BaseManager

  # Types
  @type state_key :: atom() | String.t() | [atom() | String.t()]
  @type state_value :: term()
  @type state_tree :: map()
  @type version :: non_neg_integer()
  @type strategy :: :functional | :process | :ets

  # Configuration

  defp default_strategy do
    Application.get_env(:raxol, :state_manager, [])[:default_strategy] ||
      :functional
  end

  defp strategy_from_opts(opts) do
    Keyword.get(opts, :strategy, default_strategy())
  end

  defp ets_enabled? do
    Application.get_env(:raxol, :state_manager, [])[:ets_enabled] != false
  end

  # Initialization

  @doc "Initializes state manager with default empty state."
  def initialize, do: {:ok, %{}}

  @doc "Initializes state manager with options."
  def initialize(opts) when is_list(opts) do
    initial_state = Keyword.get(opts, :initial_state, %{})
    {:ok, initial_state}
  end

  # Common Functional State Operations

  @doc """
  Gets a value from functional state.

  ## Options
  - `strategy: atom()` - Force specific strategy (:functional, :process, :ets)
  """
  def get(state, key, opts \\ [])

  def get(state, key, opts) when is_map(state) and is_list(opts) do
    Map.get(state, key)
  end

  def get(state, key, default) when is_map(state) and not is_list(default) do
    Map.get(state, key, default)
  end

  @doc "Gets a value from functional state with default."
  def get(state, key, default, opts) when is_map(state) do
    case strategy_from_opts(opts) do
      :functional -> Map.get(state, key, default)
      :ets -> ETSStrategy.get(key, default, opts)
      :process -> get_managed_with_default(key, default, opts)
    end
  end

  @doc "Puts a value into functional state."
  def put(state, key, value, opts \\ [])

  def put(state, key, value, opts) when is_map(state) do
    case strategy_from_opts(opts) do
      :functional -> {:ok, Map.put(state, key, value)}
      :ets -> ETSStrategy.set(key, value, opts)
      :process -> update_managed_key(key, fn _ -> value end, opts)
    end
  end

  @doc "Updates a value in functional state using a function."
  def update(state, key, func, opts \\ [])

  def update(state, key, func, opts)
      when is_map(state) and is_function(func, 1) do
    case strategy_from_opts(opts) do
      :functional -> {:ok, Map.update(state, key, nil, func)}
      :ets -> ETSStrategy.update(key, func, opts)
      :process -> update_managed_key(key, func, opts)
    end
  end

  @doc "Deletes a key from functional state."
  def delete(state, key, opts \\ [])

  def delete(state, key, opts) when is_map(state) do
    case strategy_from_opts(opts) do
      :functional -> {:ok, Map.delete(state, key)}
      :ets -> ETSStrategy.delete(key, opts)
      :process -> delete_managed_key(key, opts)
    end
  end

  @doc "Clears functional state."
  def clear(state, opts \\ [])

  def clear(_state, opts) do
    case strategy_from_opts(opts) do
      :functional -> {:ok, %{}}
      :ets -> ETSStrategy.clear(opts)
      :process -> clear_managed_state(opts)
    end
  end

  @doc "Merges two functional states."
  def merge(state1, state2, opts \\ [])

  def merge(state1, state2, opts) when is_map(state1) and is_map(state2) do
    case strategy_from_opts(opts) do
      :functional -> {:ok, Map.merge(state1, state2)}
      :ets -> ETSStrategy.merge(state1, state2, opts)
      :process -> merge_managed_state(state1, state2, opts)
    end
  end

  @doc "Validates functional state."
  def validate(state, opts \\ [])
  def validate(state, _opts) when is_map(state), do: :ok
  def validate(_state, _opts), do: {:error, :invalid_state_type}

  # Process-based Managed State Operations

  @doc """
  Starts a new managed state with supervision.

  ## Options
  - `strategy: :process | :ets` - Choose the backing strategy
  """
  def start_managed(state_id, initial_state, opts \\ []) do
    case strategy_from_opts(opts) do
      :process -> start_managed_process(state_id, initial_state, opts)
      :ets -> start_managed_ets(state_id, initial_state, opts)
      _ -> start_managed_process(state_id, initial_state, opts)
    end
  end

  @doc "Updates managed state using a function."
  def update_managed(state_id, update_fun, opts \\ [])
      when is_function(update_fun, 1) do
    case strategy_from_opts(opts) do
      :process -> ProcessStrategy.update(state_id, update_fun)
      :ets -> ETSStrategy.update(state_id, update_fun, opts)
      _ -> ProcessStrategy.update(state_id, update_fun)
    end
  end

  @doc "Gets the current managed state."
  def get_managed(state_id, opts \\ []) do
    case strategy_from_opts(opts) do
      :process -> ProcessStrategy.get(state_id)
      :ets -> {:ok, ETSStrategy.get(state_id, %{}, opts)}
      _ -> ProcessStrategy.get(state_id)
    end
  end

  # ETS-backed State Operations

  @doc """
  Gets the current state or a specific key from ETS.
  When called without arguments, returns the entire state as a map.
  """
  def get_state(key \\ nil, opts \\ [])

  def get_state(key, opts) do
    strategy = resolve_ets_default(strategy_from_opts(opts), opts)

    case strategy do
      :ets ->
        _ = ETSStrategy.init_if_needed(opts)

        cond do
          key == nil -> ETSStrategy.get_all(opts)
          is_list(key) -> ETSStrategy.get_nested(key, opts)
          true -> ETSStrategy.get(key, nil, opts)
        end

      :process ->
        get_managed_process_state(key, opts)

      _ ->
        {:error, :strategy_not_supported}
    end
  end

  @doc "Sets a state value atomically in ETS."
  def set_state(key, value, opts \\ []) do
    strategy = resolve_ets_default(strategy_from_opts(opts), opts)

    case strategy do
      :ets ->
        _ = ETSStrategy.init_if_needed(opts)

        if is_list(key) do
          ETSStrategy.set_nested(key, value, opts)
        else
          ETSStrategy.set(key, value, opts)
        end

      :process ->
        set_managed_process_state(key, value, opts)

      _ ->
        {:error, :strategy_not_supported}
    end
  end

  @doc "Updates a state value with a function."
  def update_state(key, update_fn) when is_function(update_fn, 1) do
    update_state(key, update_fn, [])
  end

  def update_state(key, update_fn, opts) when is_function(update_fn, 1) do
    strategy = resolve_ets_default(strategy_from_opts(opts), opts)

    case strategy do
      :ets ->
        _ = ETSStrategy.init_if_needed(opts)
        current = get_state(key, opts)
        new_value = update_fn.(current)
        set_state(key, new_value, opts)

      :process ->
        {:error, :not_implemented}

      _ ->
        {:error, :strategy_not_supported}
    end
  end

  @doc "Deletes a state value."
  def delete_state(key, opts \\ []) do
    strategy = resolve_ets_default(strategy_from_opts(opts), opts)

    case strategy do
      :ets ->
        _ = ETSStrategy.init_if_needed(opts)

        if is_list(key) do
          ETSStrategy.delete_nested(key, opts)
        else
          ETSStrategy.delete(key, opts)
        end

      :process ->
        {:error, :not_implemented}

      _ ->
        {:error, :strategy_not_supported}
    end
  end

  # Domain-Specific State Management

  @state_domains %{
    terminal: Raxol.Terminal.StateManager,
    plugins: Raxol.Core.Runtime.Plugins.StateManager,
    animation: Raxol.Animation.StateManager,
    core: Raxol.Core.StateManager
  }

  @doc "Delegates to domain-specific state manager."
  def delegate_to_domain(domain, function, args) do
    case Map.get(@state_domains, domain) do
      nil -> {:error, {:unknown_domain, domain}}
      module -> apply(module, function, args)
    end
  end

  @doc "Lists all registered state domains."
  def list_domains do
    Map.keys(@state_domains)
  end

  # Child Spec for Supervision

  @doc "Creates a supervised state manager as part of a supervision tree."
  def child_spec(opts) do
    id = Keyword.get(opts, :id, __MODULE__)
    name = Keyword.get(opts, :name)
    initial_state = Keyword.get(opts, :initial_state, %{})

    %{
      id: id,
      start: {__MODULE__, :start_link, [initial_state, [name: name]]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  # Version tracking

  @doc "Gets the current version number."
  def get_version(opts \\ []) do
    _ = ETSStrategy.init_if_needed(opts)
    ETSStrategy.get_version(opts)
  end

  @doc "Increments the version number."
  def increment_version(opts \\ []) do
    _ = ETSStrategy.init_if_needed(opts)
    ETSStrategy.increment_version(opts)
  end

  # Memory usage tracking

  @doc "Gets memory usage statistics."
  def get_memory_usage(opts \\ []) do
    _ = ETSStrategy.init_if_needed(opts)
    table = ETSStrategy.table_name_from_opts(opts)

    case :ets.info(table) do
      :undefined ->
        %{
          table_size: 0,
          memory: 0,
          objects: 0,
          object_count: 0,
          ets_memory_bytes: 0,
          ets_memory_mb: 0.0,
          last_updated: System.system_time(:second)
        }

      info ->
        memory_words = Keyword.get(info, :memory, 0)
        memory_bytes = memory_words * :erlang.system_info(:wordsize)
        memory_mb = memory_bytes / (1024 * 1024)
        object_count = Keyword.get(info, :size, 0)

        %{
          table_size: object_count,
          memory: memory_bytes,
          objects: object_count,
          object_count: object_count,
          ets_memory_bytes: memory_bytes,
          ets_memory_mb: memory_mb,
          last_updated: System.system_time(:second)
        }
    end
  end

  # Cleanup

  @doc "Cleans up state resources."
  def cleanup(state) when is_map(state) do
    table = Map.get(state, :table)

    if table && table != :undefined do
      case :ets.info(table) do
        :undefined ->
          :ok

        _ ->
          :ets.delete(table)
          :ok
      end
    else
      :ok
    end
  end

  def cleanup(_state), do: :ok

  # Transaction support

  @doc "Executes a function within a transaction."
  def transaction(func, _opts \\ []) when is_function(func, 0) do
    result = func.()
    {:ok, result}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # GenServer callbacks (for process strategy)

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    {state_id, initial_state} =
      case opts do
        [{:state_id, id}, {:initial_state, state}] -> {id, state}
        %{state_id: id, initial_state: state} -> {id, state}
        opts when is_tuple(opts) -> opts
        _ -> {nil, %{}}
      end

    Log.info("Starting managed state: #{state_id}")
    {:ok, %{id: state_id, state: initial_state}}
  end

  @impl GenServer
  def handle_call({:update, update_fun}, _from, %{state: state} = manager_state) do
    new_state = update_fun.(state)
    {:reply, {:ok, new_state}, %{manager_state | state: new_state}}
  catch
    kind, reason ->
      {:reply, {:error, {kind, reason}}, manager_state}
  end

  @impl GenServer
  def handle_call(:get, _from, %{state: state} = manager_state) do
    {:reply, {:ok, state}, manager_state}
  end

  # Private helpers

  defp start_managed_ets(state_id, initial_state, opts) do
    if ets_enabled?() do
      _ = ETSStrategy.init_if_needed(opts)
      ETSStrategy.set(state_id, initial_state, opts)
      {:ok, state_id}
    else
      {:error, :ets_disabled}
    end
  end

  defp start_managed_process(state_id, initial_state, opts) do
    ProcessStrategy.start(state_id, initial_state, opts)
  end

  defp resolve_ets_default(:functional, opts) do
    if ets_enabled?() and opts == [], do: :ets, else: :functional
  end

  defp resolve_ets_default(strategy, _opts), do: strategy

  defp get_managed_with_default(_key, default, _opts), do: default
  defp update_managed_key(_key, func, _opts), do: {:ok, func.(nil)}
  defp delete_managed_key(_key, _opts), do: :ok
  defp clear_managed_state(_opts), do: {:ok, %{}}

  defp merge_managed_state(state1, state2, _opts),
    do: {:ok, Map.merge(state1, state2)}

  defp get_managed_process_state(key, _opts), do: ProcessStrategy.get(key)

  defp set_managed_process_state(key, value, _opts) do
    ProcessStrategy.update(key, fn _prior -> value end)
  end
end
