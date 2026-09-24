defmodule Raxol.Core.ConnectionPool do
  @moduledoc """
  Generic connection pooling implementation for external services.

  Provides connection pooling, health checking, and automatic retry capabilities
  for any external service connections (HTTP, SSH, Database, etc).

  ## Features
  - Configurable pool size limits
  - Connection health checking
  - Automatic reconnection on failure
  - Connection timeout management
  - Metrics and monitoring

  ## Usage

      # Define a pool for an HTTP service
      defmodule MyApp.APIPool do
        use Raxol.Core.ConnectionPool,
  alias Raxol.Core.Runtime.Log
          name: :api_pool,
          pool_size: 10,
          max_overflow: 5
      end

      # Use the pool
      ConnectionPool.transaction(:api_pool, fn conn ->
        # Use connection
      end)
  """

  use Raxol.Core.Behaviours.BaseManager

  @default_opts [
    pool_size: 5,
    max_overflow: 10,
    timeout: Raxol.Core.Defaults.timeout_ms(),
    idle_timeout: Raxol.Core.Defaults.idle_timeout_ms(),
    health_check_interval: Raxol.Core.Defaults.health_check_interval_ms()
  ]

  defstruct [
    :name,
    :pool_size,
    :max_overflow,
    :timeout,
    :idle_timeout,
    :health_check_interval,
    :connections,
    :waiting,
    :metrics,
    :connect_fn,
    :disconnect_fn,
    :health_check_fn
  ]

  @type connection :: term()
  @type pool_name :: atom()
  @type pool_opts :: [
          pool_size: pos_integer(),
          max_overflow: non_neg_integer(),
          timeout: pos_integer(),
          idle_timeout: pos_integer(),
          health_check_interval: pos_integer(),
          connect_fn: (-> {:ok, connection()} | {:error, term()}),
          disconnect_fn: (connection() -> :ok),
          health_check_fn: (connection() -> boolean())
        ]

  # Client API

  @doc """
  Executes a function with a connection from the pool.

  The function runs in the calling process, never inside the pool, so a slow
  or hung callback holds only its own connection. The connection is checked
  back in when the function returns or raises; if the caller dies instead,
  the pool reclaims it through its monitor on the caller.
  """
  @spec transaction(pool_name(), (connection() -> result), timeout()) ::
          result | {:error, term()}
        when result: term()
  def transaction(pool_name, fun, timeout \\ Raxol.Core.Defaults.timeout_ms())
      when is_function(fun, 1) do
    case checkout(pool_name, timeout) do
      {:ok, conn} ->
        try do
          fun.(conn)
        rescue
          error ->
            Log.error("Error in pool transaction: #{inspect(error)}")
            {:error, error}
        after
          checkin(pool_name, conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks out a connection from the pool.

  The connection belongs to the calling process until `checkin/2`; if that
  process exits first, the pool takes the connection back.
  """
  @spec checkout(pool_name(), timeout()) ::
          {:ok, connection()} | {:error, term()}
  def checkout(pool_name, timeout \\ Raxol.Core.Defaults.timeout_ms()) do
    GenServer.call(pool_name, {:checkout, timeout}, timeout + 100)
  end

  @doc """
  Returns a connection to the pool.
  """
  @spec checkin(pool_name(), connection()) :: :ok
  def checkin(pool_name, conn) do
    GenServer.cast(pool_name, {:checkin, conn})
  end

  @doc """
  Gets pool statistics.
  """
  @spec stats(pool_name()) :: map()
  def stats(pool_name) do
    GenServer.call(pool_name, :stats)
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    opts = Keyword.merge(@default_opts, opts)

    state = %__MODULE__{
      name: Keyword.get(opts, :name),
      pool_size: Keyword.get(opts, :pool_size),
      max_overflow: Keyword.get(opts, :max_overflow),
      timeout: Keyword.get(opts, :timeout),
      idle_timeout: Keyword.get(opts, :idle_timeout),
      health_check_interval: Keyword.get(opts, :health_check_interval),
      connections: %{available: [], busy: %{}, overflow: []},
      waiting: :queue.new(),
      metrics: %{
        checkouts: 0,
        checkins: 0,
        timeouts: 0,
        errors: 0,
        health_checks: 0
      },
      connect_fn: Keyword.get(opts, :connect_fn, &default_connect/0),
      disconnect_fn: Keyword.get(opts, :disconnect_fn, &default_disconnect/1),
      health_check_fn:
        Keyword.get(opts, :health_check_fn, &default_health_check/1)
    }

    # Initialize pool with connections
    state = initialize_pool(state)

    # Schedule health checks
    schedule_health_check(state.health_check_interval)

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:checkout, timeout}, {owner, _tag}, state) do
    case do_checkout(state, owner, timeout) do
      {:ok, conn, new_state} ->
        {:reply, {:ok, conn}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_manager_call(:stats, _from, state) do
    stats = %{
      pool_size: state.pool_size,
      available: length(state.connections.available),
      busy: map_size(state.connections.busy),
      overflow: length(state.connections.overflow),
      waiting: :queue.len(state.waiting),
      metrics: state.metrics
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_cast({:checkin, conn}, state) do
    {:noreply, do_checkin(state, conn)}
  end

  @impl true
  def handle_manager_info(:health_check, state) do
    state = perform_health_checks(state)
    schedule_health_check(state.health_check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:idle_timeout, conn}, state) do
    state = handle_idle_timeout(state, conn)
    {:noreply, state}
  end

  # A checked-out connection's owner exited without checking it in.
  def handle_manager_info({:DOWN, ref, :process, _owner, _reason}, state) do
    owned =
      Enum.find_value(state.connections.busy, fn
        {conn, {_owner, ^ref, _checked_out_at}} -> conn
        _other -> nil
      end)

    case owned do
      nil -> {:noreply, state}
      conn -> {:noreply, do_checkin(state, conn)}
    end
  end

  # Private Functions

  defp initialize_pool(state) do
    connections =
      Enum.reduce(1..state.pool_size, [], fn _, acc ->
        case state.connect_fn.() do
          {:ok, conn} ->
            [conn | acc]

          {:error, reason} ->
            Log.warning(
              "Failed to create initial connection: #{inspect(reason)}"
            )

            acc
        end
      end)

    put_in(state.connections.available, connections)
  end

  @spec do_checkout(map(), pid(), timeout()) ::
          {:ok, connection(), map()} | {:error, term(), map()}
  defp do_checkout(state, owner, timeout) do
    %{connections: conns, metrics: metrics} = state

    case conns.available do
      [conn | rest] ->
        # Use available connection
        new_conns = %{
          conns
          | available: rest,
            busy: Map.put(conns.busy, conn, claim(owner))
        }

        new_metrics = Map.update(metrics, :checkouts, 1, &(&1 + 1))

        {:ok, conn, %{state | connections: new_conns, metrics: new_metrics}}

      [] ->
        # No available connections, try overflow
        if length(conns.overflow) < state.max_overflow do
          create_overflow_connection(state, owner)
        else
          # Add to waiting queue
          add_to_waiting_queue(state, timeout)
        end
    end
  end

  defp do_checkin(state, conn) do
    %{connections: conns, metrics: metrics} = state

    case Map.pop(conns.busy, conn) do
      {nil, _busy} ->
        state

      {{_owner, ref, _checked_out_at}, new_busy} ->
        Process.demonitor(ref, [:flush])

        hand_back(
          state,
          conn,
          new_busy,
          Map.update(metrics, :checkins, 1, &(&1 + 1))
        )
    end
  end

  defp hand_back(state, conn, new_busy, new_metrics) do
    %{connections: conns} = state

    # Check if anyone is waiting
    case :queue.out(state.waiting) do
      {{:value, {waiter, _tag} = waiting_from}, new_queue} ->
        # Give connection to waiting process
        GenServer.reply(waiting_from, {:ok, conn})

        %{
          state
          | connections: %{
              conns
              | busy: Map.put(new_busy, conn, claim(waiter))
            },
            waiting: new_queue,
            metrics: new_metrics
        }

      {:empty, _} ->
        # Return to available pool
        %{
          state
          | connections: %{
              conns
              | available: [conn | conns.available],
                busy: new_busy
            },
            metrics: new_metrics
        }
    end
  end

  # A busy connection records who holds it and the monitor that reclaims it
  # if the holder exits before checking it in.
  defp claim(owner), do: {owner, Process.monitor(owner), :os.timestamp()}

  defp create_overflow_connection(state, owner) do
    case state.connect_fn.() do
      {:ok, conn} ->
        new_conns = %{
          state.connections
          | overflow: [conn | state.connections.overflow],
            busy: Map.put(state.connections.busy, conn, claim(owner))
        }

        {:ok, conn, %{state | connections: new_conns}}

      {:error, reason} ->
        new_metrics = Map.update(state.metrics, :errors, 1, &(&1 + 1))
        {:error, reason, %{state | metrics: new_metrics}}
    end
  end

  defp add_to_waiting_queue(state, _timeout) do
    # This would need proper implementation with timeout handling
    new_metrics = Map.update(state.metrics, :timeouts, 1, &(&1 + 1))
    {:error, :timeout, %{state | metrics: new_metrics}}
  end

  defp perform_health_checks(state) do
    %{connections: conns} = state

    # Check available connections
    healthy_available =
      Enum.filter(conns.available, fn conn ->
        state.health_check_fn.(conn)
      end)

    new_metrics = Map.update(state.metrics, :health_checks, 1, &(&1 + 1))

    %{
      state
      | connections: %{conns | available: healthy_available},
        metrics: new_metrics
    }
  end

  defp handle_idle_timeout(state, conn) do
    %{connections: conns} = state

    if conn in conns.available do
      # Remove idle connection
      state.disconnect_fn.(conn)
      new_available = List.delete(conns.available, conn)
      put_in(state.connections.available, new_available)
    else
      state
    end
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  # Default implementations

  defp default_connect do
    {:ok, make_ref()}
  end

  defp default_disconnect(_conn) do
    :ok
  end

  defp default_health_check(_conn) do
    true
  end
end
