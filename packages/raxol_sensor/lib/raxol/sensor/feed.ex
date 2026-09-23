defmodule Raxol.Sensor.Feed do
  @moduledoc """
  GenServer managing a single sensor's polling lifecycle.

  Connects to a sensor module, polls at the configured sample rate,
  buffers readings in a CircularBuffer, and forwards each reading
  to the fusion process.
  """

  use GenServer

  require Logger

  @default_buffer_size 1000
  @default_max_errors 10
  @backoff_ms 5_000
  @max_backoff_ms 300_000
  @jitter 0.2

  # Reasons meaning "the endpoint is not answering", as opposed to "the
  # endpoint answered with something unusable". Matched bare and unwrapped
  # from any struct carrying a :reason -- Mint and Req transport errors
  # included -- without taking a dependency on either package.
  @unreachable [
    :timeout,
    :etimedout,
    :connect_timeout,
    :econnrefused,
    :econnreset,
    :closed,
    :ehostunreach,
    :enetunreach,
    :ehostdown,
    :nxdomain,
    :eai_noname
  ]

  @type status :: :connecting | :running | :error | :stopped

  @type t :: %__MODULE__{
          sensor_id: atom(),
          module: module(),
          sensor_state: term(),
          sample_rate_ms: pos_integer(),
          buffer: CircularBuffer.t(),
          buffer_size: pos_integer(),
          status: status(),
          fusion_pid: pid() | nil,
          connect_opts: keyword(),
          error_count: non_neg_integer(),
          max_errors: pos_integer(),
          poll_ref: reference() | nil,
          backoff_ref: reference() | nil,
          budget_ms: timeout(),
          backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer()
        }

  defstruct sensor_id: nil,
            module: nil,
            sensor_state: nil,
            sample_rate_ms: 100,
            buffer: nil,
            buffer_size: @default_buffer_size,
            status: :connecting,
            fusion_pid: nil,
            connect_opts: [],
            error_count: 0,
            max_errors: @default_max_errors,
            poll_ref: nil,
            backoff_ref: nil,
            budget_ms: :infinity,
            backoff_ms: @backoff_ms,
            max_backoff_ms: @max_backoff_ms

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_latest(GenServer.server()) :: {:ok, map()} | {:error, :empty}
  def get_latest(server) do
    GenServer.call(server, :get_latest)
  end

  @spec get_history(GenServer.server(), pos_integer()) :: [map()]
  def get_history(server, count \\ 10) do
    GenServer.call(server, {:get_history, count})
  end

  @spec get_status(GenServer.server()) :: status()
  def get_status(server) do
    GenServer.call(server, :get_status)
  end

  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server) do
    GenServer.cast(server, :reconnect)
  end

  @spec backoff_delay(non_neg_integer(), keyword()) :: pos_integer()
  def backoff_delay(attempt, opts \\ [])
      when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :backoff_ms, @backoff_ms)
    ceiling = Keyword.get(opts, :max_backoff_ms, @max_backoff_ms)

    # Cap the exponent before the multiply: 2 ** attempt on a long-dead
    # endpoint would otherwise build a bignum to immediately throw away.
    target = min(base * Integer.pow(2, min(attempt, 32)), ceiling)
    jittered = target + target * @jitter * (:rand.uniform() * 2 - 1)

    # Clamp after jittering too, or the ceiling leaks by the jitter width.
    jittered |> round() |> max(1) |> min(ceiling)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    sensor_id = Keyword.fetch!(opts, :sensor_id)
    module = Keyword.fetch!(opts, :module)
    fusion_pid = Keyword.get(opts, :fusion_pid)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    max_errors = Keyword.get(opts, :max_errors, @default_max_errors)
    sample_rate = Keyword.get(opts, :sample_rate_ms, 100)
    connect_opts = Keyword.get(opts, :connect_opts, [])

    state = %__MODULE__{
      sensor_id: sensor_id,
      module: module,
      fusion_pid: fusion_pid,
      buffer_size: buffer_size,
      buffer: CircularBuffer.new(buffer_size),
      max_errors: max_errors,
      sample_rate_ms: sample_rate,
      connect_opts: connect_opts,
      budget_ms: Keyword.get(opts, :budget_ms, :infinity),
      backoff_ms: Keyword.get(opts, :backoff_ms, @backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @max_backoff_ms)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %__MODULE__{} = state) do
    connect_opts = [sensor_id: state.sensor_id] ++ state.connect_opts

    case with_budget(state, fn -> state.module.connect(connect_opts) end) do
      {:ok, sensor_state} ->
        state = %__MODULE__{
          state
          | sensor_state: sensor_state,
            status: :running,
            error_count: 0
        }

        {:noreply, schedule_poll(state)}

      {:error, reason} ->
        Logger.warning("Sensor #{state.sensor_id} connect failed: #{inspect(reason)}")

        state = %__MODULE__{state | status: :error}
        {:noreply, schedule_backoff(state)}
    end
  end

  @impl true
  def handle_call(:get_latest, _from, %__MODULE__{} = state) do
    case Enum.take(state.buffer, 1) do
      [reading] -> {:reply, {:ok, reading}, state}
      [] -> {:reply, {:error, :empty}, state}
    end
  end

  @impl true
  def handle_call({:get_history, count}, _from, %__MODULE__{} = state) do
    {:reply, Enum.take(state.buffer, count), state}
  end

  @impl true
  def handle_call(:get_status, _from, %__MODULE__{} = state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info(:poll, %__MODULE__{status: :running} = state) do
    case with_budget(state, fn -> state.module.read(state.sensor_state) end) do
      {:ok, reading, new_sensor_state} ->
        record_reading(state, reading, new_sensor_state)

      {:error, reason} ->
        handle_read_error(state, reason)
    end
  end

  @impl true
  def handle_info(:poll, %__MODULE__{} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:backoff_reconnect, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | backoff_ref: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reconnect, %__MODULE__{} = state) do
    state = cancel_timers(state)
    disconnect_sensor(state.module, state.sensor_state)

    state = %__MODULE__{
      state
      | sensor_state: nil,
        status: :connecting,
        error_count: 0
    }

    {:noreply, state, {:continue, :connect}}
  end

  # -- Private --

  defp record_reading(%__MODULE__{} = state, reading, new_sensor_state) do
    buffer = CircularBuffer.insert(state.buffer, reading)
    notify_fusion(state.fusion_pid, reading)

    state = %__MODULE__{
      state
      | sensor_state: new_sensor_state,
        buffer: buffer,
        error_count: 0
    }

    {:noreply, schedule_poll(state)}
  end

  defp handle_read_error(%__MODULE__{} = state, reason) do
    error_count = state.error_count + 1
    class = classify(reason)

    Logger.warning(
      "Sensor #{state.sensor_id} read error " <>
        "(#{class}, #{error_count}/#{state.max_errors}): " <>
        inspect(reason)
    )

    # An unreachable endpoint does not get the error ladder: every
    # remaining rung costs a full connect timeout to learn nothing new.
    if class == :unreachable or error_count >= state.max_errors do
      disconnect_sensor(state.module, state.sensor_state)

      state = %__MODULE__{
        state
        | error_count: error_count,
          status: :error,
          sensor_state: nil
      }

      {:noreply, schedule_backoff(state)}
    else
      {:noreply, schedule_poll(%__MODULE__{state | error_count: error_count})}
    end
  end

  defp with_budget(%__MODULE__{budget_ms: :infinity}, fun), do: fun.()

  defp with_budget(%__MODULE__{budget_ms: budget}, fun) do
    task = Task.async(fun)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp classify(reason) when reason in @unreachable, do: :unreachable
  defp classify({:timeout, _}), do: :unreachable
  defp classify(%{reason: reason}), do: classify(reason)
  defp classify(_reason), do: :transient

  defp notify_fusion(nil, _reading), do: :ok
  defp notify_fusion(pid, reading), do: send(pid, {:sensor_reading, reading})

  defp disconnect_sensor(_module, nil), do: :ok

  defp disconnect_sensor(module, sensor_state),
    do: module.disconnect(sensor_state)

  defp schedule_poll(%__MODULE__{} = state) do
    _ = cancel_timer(state.poll_ref)
    ref = Process.send_after(self(), :poll, state.sample_rate_ms)
    %__MODULE__{state | poll_ref: ref}
  end

  defp schedule_backoff(%__MODULE__{} = state) do
    _ = cancel_timer(state.backoff_ref)

    delay =
      backoff_delay(0,
        backoff_ms: state.backoff_ms,
        max_backoff_ms: state.max_backoff_ms
      )

    ref = Process.send_after(self(), :backoff_reconnect, delay)
    %__MODULE__{state | backoff_ref: ref}
  end

  defp cancel_timers(%__MODULE__{} = state) do
    _ = cancel_timer(state.poll_ref)
    _ = cancel_timer(state.backoff_ref)
    %__MODULE__{state | poll_ref: nil, backoff_ref: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
