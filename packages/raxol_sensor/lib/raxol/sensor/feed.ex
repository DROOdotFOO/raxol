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
          backoff_ref: reference() | nil
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
            backoff_ref: nil

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
      connect_opts: connect_opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %__MODULE__{} = state) do
    case state.module.connect([sensor_id: state.sensor_id] ++ state.connect_opts) do
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
    case state.module.read(state.sensor_state) do
      {:ok, reading, new_sensor_state} ->
        buffer = CircularBuffer.insert(state.buffer, reading)
        notify_fusion(state.fusion_pid, reading)

        state = %__MODULE__{
          state
          | sensor_state: new_sensor_state,
            buffer: buffer,
            error_count: 0
        }

        {:noreply, schedule_poll(state)}

      {:error, reason} ->
        error_count = state.error_count + 1

        Logger.warning(
          "Sensor #{state.sensor_id} read error (#{error_count}/#{state.max_errors}): #{inspect(reason)}"
        )

        if error_count >= state.max_errors do
          disconnect_sensor(state.module, state.sensor_state)

          state = %__MODULE__{
            state
            | error_count: error_count,
              status: :error,
              sensor_state: nil
          }

          {:noreply, schedule_backoff(state)}
        else
          state = %__MODULE__{state | error_count: error_count}
          {:noreply, schedule_poll(state)}
        end
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
    ref = Process.send_after(self(), :backoff_reconnect, @backoff_ms)
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
