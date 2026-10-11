defmodule Raxol.Core.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for external API calls.

  Prevents cascading failures by monitoring external service calls and
  temporarily blocking requests when a service is experiencing issues.

  ## States

  - **Closed**: Normal operation, requests pass through
  - **Open**: Service is failing, requests are blocked
  - **Half-Open**: Testing if service has recovered

  ## Features

  - Automatic state transitions based on failure rates
  - Configurable thresholds and timeouts
  - Metrics collection and monitoring
  - Fallback strategies
  - Exponential backoff

  ## Usage

      # Define a circuit breaker for an API
      defmodule MyApp.APIBreaker do
        use Raxol.Core.CircuitBreaker,
  alias Raxol.Core.Runtime.Log
          name: :api_breaker,
          failure_threshold: 5,
          open_timeout: 30_000
      end

      # Use the circuit breaker
      CircuitBreaker.call(:api_breaker, fn ->
        HTTPoison.get("https://api.example.com/data")
      end)
  """

  use Raxol.Core.Behaviours.BaseManager

  @default_opts [
    failure_threshold: 5,
    success_threshold: 2,
    open_timeout: Raxol.Core.Defaults.idle_timeout_ms(),
    half_open_timeout: Raxol.Core.Defaults.cb_half_open_timeout_ms(),
    reset_timeout: Raxol.Core.Defaults.cb_reset_timeout_ms(),
    failure_rate_threshold: 0.5,
    volume_threshold: 10
  ]

  defstruct [
    :name,
    :state,
    :failure_count,
    :success_count,
    :failure_threshold,
    :success_threshold,
    :open_timeout,
    :half_open_timeout,
    :reset_timeout,
    :failure_rate_threshold,
    :volume_threshold,
    :last_failure_time,
    :metrics,
    :fallback_fn,
    :on_state_change,
    # Token of the current open period; the half-open timeout armed by an
    # earlier period (since reset or half-opened by a call) carries a stale one.
    :open_token
  ]

  @type state :: :closed | :open | :half_open
  @type breaker_name :: atom()
  @type breaker_opts :: [
          failure_threshold: pos_integer(),
          success_threshold: pos_integer(),
          open_timeout: pos_integer(),
          half_open_timeout: pos_integer(),
          reset_timeout: pos_integer(),
          failure_rate_threshold: float(),
          volume_threshold: pos_integer(),
          fallback_fn: (-> term()),
          on_state_change: (state(), state() -> :ok)
        ]

  # Client API

  @doc """
  Executes a function through the circuit breaker.
  """
  @spec call(breaker_name(), (-> result), timeout()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def call(breaker_name, fun, timeout \\ Raxol.Core.Defaults.timeout_ms()) do
    GenServer.call(breaker_name, {:call, fun}, timeout)
  end

  @doc """
  Executes a function with automatic fallback on circuit open.
  """
  @spec call_with_fallback(breaker_name(), (-> result), (-> result), timeout()) ::
          result
        when result: term()
  def call_with_fallback(
        breaker_name,
        fun,
        fallback_fn,
        timeout \\ Raxol.Core.Defaults.timeout_ms()
      ) do
    case call(breaker_name, fun, timeout) do
      {:ok, result} -> result
      {:error, :circuit_open} -> fallback_fn.()
      {:error, _reason} -> fallback_fn.()
    end
  end

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec state(breaker_name()) :: state()
  def state(breaker_name) do
    GenServer.call(breaker_name, :state)
  end

  @doc """
  Gets circuit breaker statistics.
  """
  @spec stats(breaker_name()) :: map()
  def stats(breaker_name) do
    GenServer.call(breaker_name, :stats)
  end

  @doc """
  Manually resets the circuit breaker to closed state.
  """
  @spec reset(breaker_name()) :: :ok
  def reset(breaker_name) do
    GenServer.cast(breaker_name, :reset)
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    opts = Keyword.merge(@default_opts, opts)

    state = %__MODULE__{
      name: Keyword.get(opts, :name),
      state: :closed,
      failure_count: 0,
      success_count: 0,
      failure_threshold: Keyword.get(opts, :failure_threshold),
      success_threshold: Keyword.get(opts, :success_threshold),
      open_timeout: Keyword.get(opts, :open_timeout),
      half_open_timeout: Keyword.get(opts, :half_open_timeout),
      reset_timeout: Keyword.get(opts, :reset_timeout),
      failure_rate_threshold: Keyword.get(opts, :failure_rate_threshold),
      volume_threshold: Keyword.get(opts, :volume_threshold),
      last_failure_time: nil,
      metrics: %{
        total_calls: 0,
        successful_calls: 0,
        failed_calls: 0,
        rejected_calls: 0,
        timeouts: 0,
        state_changes: []
      },
      fallback_fn: Keyword.get(opts, :fallback_fn),
      on_state_change: Keyword.get(opts, :on_state_change, fn _, _ -> :ok end)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:call, fun}, _from, state) do
    case state.state do
      :closed ->
        handle_closed_call(fun, state)

      :open ->
        handle_open_call(fun, state)

      :half_open ->
        handle_half_open_call(fun, state)
    end
  end

  @impl true
  def handle_manager_call(:state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_manager_call(:stats, _from, state) do
    stats = %{
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_time: state.last_failure_time,
      metrics: state.metrics
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_manager_cast(:reset, state) do
    new_state = transition_to_closed(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_manager_info(
        {:timeout, :half_open, token},
        %{open_token: token} = state
      )
      when is_reference(token) do
    new_state = transition_to_half_open(state)
    {:noreply, new_state}
  end

  def handle_manager_info({:timeout, :half_open, _stale}, state),
    do: {:noreply, state}

  @impl true
  def handle_manager_info({:timeout, :reset}, state) do
    new_state = transition_to_closed(state)
    {:noreply, new_state}
  end

  # Private Functions

  defp handle_closed_call(fun, state) do
    result = execute_function(fun)
    new_metrics = update_metrics(state.metrics, :total_calls)

    case result do
      {:ok, value} ->
        new_state = %{
          state
          | success_count: state.success_count + 1,
            failure_count: 0,
            metrics: update_metrics(new_metrics, :successful_calls)
        }

        {:reply, {:ok, value}, new_state}

      {:error, reason} ->
        new_failure_count = state.failure_count + 1

        new_state = %{
          state
          | failure_count: new_failure_count,
            last_failure_time: :os.timestamp(),
            metrics: update_metrics(new_metrics, :failed_calls)
        }

        # Check if we should open the circuit
        new_state =
          if should_open_circuit?(new_state) do
            transition_to_open(new_state)
          else
            new_state
          end

        {:reply, {:error, reason}, new_state}
    end
  end

  defp handle_open_call(_fun, state) do
    # Check if we should transition to half-open
    if should_attempt_reset?(state) do
      new_state = transition_to_half_open(state)
      {:reply, {:error, :circuit_open}, new_state}
    else
      new_metrics =
        state.metrics
        |> update_metrics(:rejected_calls)
        |> update_metrics(:total_calls)

      {:reply, {:error, :circuit_open}, %{state | metrics: new_metrics}}
    end
  end

  defp handle_half_open_call(fun, state) do
    result = execute_function(fun)
    new_metrics = update_metrics(state.metrics, :total_calls)

    case result do
      {:ok, value} ->
        new_success_count = state.success_count + 1

        new_state =
          if new_success_count >= state.success_threshold do
            # Circuit has recovered
            %{
              state
              | success_count: 0,
                failure_count: 0,
                metrics: update_metrics(new_metrics, :successful_calls)
            }
            |> transition_to_closed()
          else
            %{
              state
              | success_count: new_success_count,
                metrics: update_metrics(new_metrics, :successful_calls)
            }
          end

        {:reply, {:ok, value}, new_state}

      {:error, reason} ->
        # Single failure in half-open state reopens the circuit
        new_state =
          %{
            state
            | failure_count: state.failure_count + 1,
              success_count: 0,
              last_failure_time: :os.timestamp(),
              metrics: update_metrics(new_metrics, :failed_calls)
          }
          |> transition_to_open()

        {:reply, {:error, reason}, new_state}
    end
  end

  defp execute_function(fun) do
    result = fun.()
    {:ok, result}
  rescue
    error ->
      Log.warning("Circuit breaker caught error: #{inspect(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Log.warning("Circuit breaker caught exit: #{inspect(reason)}")
      {:error, {:exit, reason}}

    kind, reason ->
      Log.warning("Circuit breaker caught #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp should_open_circuit?(state) do
    cond do
      # Threshold-based opening
      state.failure_count >= state.failure_threshold ->
        true

      # Rate-based opening (if we have enough volume)
      state.metrics.total_calls >= state.volume_threshold ->
        failure_rate = state.metrics.failed_calls / state.metrics.total_calls
        failure_rate >= state.failure_rate_threshold

      true ->
        false
    end
  end

  defp should_attempt_reset?(state) do
    case state.last_failure_time do
      nil ->
        true

      last_time ->
        time_since_failure = :timer.now_diff(:os.timestamp(), last_time)
        time_since_failure >= state.open_timeout * 1000
    end
  end

  defp transition_to_open(state) do
    Log.info("Circuit breaker #{state.name} transitioning to OPEN")
    state.on_state_change.(state.state, :open)

    # Schedule transition to half-open, for this open period only
    token = make_ref()

    Process.send_after(
      self(),
      {:timeout, :half_open, token},
      state.open_timeout
    )

    %{
      state
      | state: :open,
        open_token: token,
        metrics: add_state_change(state.metrics, :open)
    }
  end

  defp transition_to_half_open(state) do
    Log.info("Circuit breaker #{state.name} transitioning to HALF-OPEN")
    state.on_state_change.(state.state, :half_open)

    %{
      state
      | state: :half_open,
        success_count: 0,
        failure_count: 0,
        open_token: nil,
        metrics: add_state_change(state.metrics, :half_open)
    }
  end

  defp transition_to_closed(state) do
    Log.info("Circuit breaker #{state.name} transitioning to CLOSED")
    state.on_state_change.(state.state, :closed)

    %{
      state
      | state: :closed,
        success_count: 0,
        failure_count: 0,
        last_failure_time: nil,
        open_token: nil,
        metrics: add_state_change(state.metrics, :closed)
    }
  end

  defp update_metrics(metrics, key) do
    Map.update(metrics, key, 1, &(&1 + 1))
  end

  defp add_state_change(metrics, new_state) do
    change = %{
      state: new_state,
      timestamp: :os.timestamp()
    }

    Map.update(metrics, :state_changes, [change], &[change | &1])
  end
end
