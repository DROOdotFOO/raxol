defmodule Raxol.Core.Utils.GenServerHelpers do
  @moduledoc """
  Common GenServer patterns and utilities to reduce code duplication.
  Provides standardized handlers for common operations like state retrieval,
  metrics collection, and configuration management.
  """

  @doc """
  Standard handler for getting state information.
  """
  def handle_get_state(state) do
    {:reply, state, state}
  end

  @doc """
  Standard handler for getting specific state fields.
  """
  def handle_get_field(field, state) when is_map(state) do
    {:reply, Map.get(state, field), state}
  end

  def handle_get_field(_field, state) do
    {:reply, nil, state}
  end

  @doc """
  Standard handler for getting metrics from state.
  """
  def handle_get_metrics(state) when is_map(state) do
    metrics = Map.get(state, :metrics, %{})
    {:reply, metrics, state}
  end

  def handle_get_metrics(state) do
    {:reply, %{}, state}
  end

  @doc """
  Standard handler for getting status information.
  """
  def handle_get_status(state) when is_map(state) do
    status = %{
      status: Map.get(state, :status, :running),
      uptime: calculate_uptime(state),
      metrics: Map.get(state, :metrics, %{})
    }

    {:reply, status, state}
  end

  def handle_get_status(state) do
    {:reply, %{status: :unknown}, state}
  end

  @doc """
  Standard handler for updating configuration.
  """
  def handle_update_config(new_config, state)
      when is_map(state) and is_map(new_config) do
    updated_config = Map.merge(Map.get(state, :config, %{}), new_config)
    new_state = Map.put(state, :config, updated_config)
    {:reply, :ok, new_state}
  end

  def handle_update_config(_new_config, state) do
    {:reply, {:error, :invalid_config}, state}
  end

  @doc """
  Standard handler for resetting metrics.
  """
  def handle_reset_metrics(state) when is_map(state) do
    new_state = Map.put(state, :metrics, %{})
    {:reply, :ok, new_state}
  end

  def handle_reset_metrics(state) do
    {:reply, :ok, state}
  end

  @doc """
  Utility to increment a metric counter.
  """
  def increment_metric(state, metric_name, amount \\ 1)

  def increment_metric(state, metric_name, amount) when is_map(state) do
    metrics = Map.get(state, :metrics, %{})
    updated_metrics = Map.update(metrics, metric_name, amount, &(&1 + amount))
    Map.put(state, :metrics, updated_metrics)
  end

  def increment_metric(state, _metric_name, _amount) do
    state
  end

  @doc """
  Utility to update a metric value.
  """
  def update_metric(state, metric_name, value) when is_map(state) do
    metrics = Map.get(state, :metrics, %{})
    updated_metrics = Map.put(metrics, metric_name, value)
    Map.put(state, :metrics, updated_metrics)
  end

  def update_metric(state, _metric_name, _value) do
    state
  end

  defp calculate_uptime(state) when is_map(state) do
    start_time =
      Map.get(state, :start_time, System.monotonic_time(:millisecond))

    System.monotonic_time(:millisecond) - start_time
  end

  @doc """
  Ensures a named process is running. Starts it via `start_fun` if not found.

  `start_fun` is a zero-arity function that starts the process UNLINKED
  (`GenServer.start/3`, `Agent.start/2`) and registers it under `name`. It
  must return `{:ok, pid}` or `{:error, {:already_started, pid}}`.

  The process is started unlinked because the first caller is often a
  rendering process, a session process or an ExUnit test process. With
  `start_link`, that caller's exit took the singleton, and all of its state,
  with it, and a crash in the singleton killed whichever process happened to
  call first.

  Two callers can both find no process and both run `start_fun`. The loser
  gets `{:error, {:already_started, pid}}`, which counts as started.

  ## Examples

      ensure_started(MyServer, fn ->
        GenServer.start(MyServer, [], name: MyServer)
      end)
  """
  @spec ensure_started(
          atom(),
          (-> {:ok, pid()} | {:error, {:already_started, pid()}})
        ) :: :ok
  def ensure_started(name, start_fun)
      when is_atom(name) and is_function(start_fun, 0) do
    case Process.whereis(name) do
      nil ->
        case start_fun.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @server_opt_keys [:name, :timeout, :debug, :spawn_opt]

  @doc """
  Splits a keyword list into GenServer server options and init args.

  Server options (`:name`, `:timeout`, `:debug`, `:spawn_opt`) are
  separated from the remaining application-specific options.

  ## Examples

      iex> split_server_opts(name: MyServer, timeout: 5000, foo: :bar)
      {[name: MyServer, timeout: 5000], [foo: :bar]}

      iex> split_server_opts(%{name: MyServer})
      {[name: MyServer], []}
  """
  @spec split_server_opts(keyword() | map() | term()) ::
          {keyword(), keyword() | term()}
  def split_server_opts(opts) when is_map(opts),
    do: split_server_opts(Map.to_list(opts))

  def split_server_opts(opts) when is_list(opts),
    do: {Keyword.take(opts, @server_opt_keys), Keyword.drop(opts, @server_opt_keys)}

  def split_server_opts(value), do: {[], value}

  @doc """
  Initialize default state with common fields.
  """
  def init_default_state(custom_state \\ %{}) do
    default_state = %{
      status: :running,
      start_time: System.monotonic_time(:millisecond),
      metrics: %{},
      config: %{}
    }

    Map.merge(default_state, custom_state)
  end
end
