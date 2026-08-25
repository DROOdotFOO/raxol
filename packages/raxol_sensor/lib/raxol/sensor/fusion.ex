defmodule Raxol.Sensor.Fusion do
  @moduledoc """
  Batches sensor readings and produces fused state.

  Receives `{:sensor_reading, reading}` messages from Feed processes,
  accumulates them in a batch, and on a configurable timer flushes
  the batch through a pure fusion function. Subscribers receive
  `{:fused_update, fused_state}` on each flush.
  """

  use GenServer

  require Logger

  alias Raxol.Sensor.Reading

  @default_batch_window_ms 100

  @type t :: %__MODULE__{
          feeds: %{atom() => pid()},
          batch: [Reading.t()],
          batch_window_ms: pos_integer(),
          fused_state: map(),
          subscribers: MapSet.t(pid()),
          batch_ref: reference() | nil,
          thresholds: map()
        }

  defstruct feeds: %{},
            batch: [],
            batch_window_ms: @default_batch_window_ms,
            fused_state: %{},
            subscribers: MapSet.new(),
            batch_ref: nil,
            thresholds: %{}

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec register_feed(GenServer.server(), atom(), pid()) :: :ok
  def register_feed(server \\ __MODULE__, sensor_id, feed_pid) do
    GenServer.cast(server, {:register_feed, sensor_id, feed_pid})
  end

  @spec unregister_feed(GenServer.server(), atom()) :: :ok
  def unregister_feed(server \\ __MODULE__, sensor_id) do
    GenServer.cast(server, {:unregister_feed, sensor_id})
  end

  @spec get_fused_state(GenServer.server()) :: map()
  def get_fused_state(server \\ __MODULE__) do
    GenServer.call(server, :get_fused_state)
  end

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    batch_window = Keyword.get(opts, :batch_window_ms, @default_batch_window_ms)
    thresholds = Keyword.get(opts, :thresholds, %{})

    state = %__MODULE__{
      batch_window_ms: batch_window,
      thresholds: thresholds
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_call(:get_fused_state, _from, %__MODULE__{} = state) do
    {:reply, state.fused_state, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)

    {:reply, :ok, %__MODULE__{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast({:register_feed, sensor_id, feed_pid}, %__MODULE__{} = state) do
    Process.monitor(feed_pid)

    {:noreply, %__MODULE__{state | feeds: Map.put(state.feeds, sensor_id, feed_pid)}}
  end

  @impl true
  def handle_cast({:unregister_feed, sensor_id}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | feeds: Map.delete(state.feeds, sensor_id)}}
  end

  @impl true
  def handle_info({:sensor_reading, reading}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | batch: [reading | state.batch]}}
  end

  @impl true
  def handle_info(:flush_batch, %__MODULE__{batch: []} = state) do
    {:noreply, schedule_flush(state)}
  end

  @impl true
  def handle_info(:flush_batch, %__MODULE__{} = state) do
    fused = fuse_batch(Enum.reverse(state.batch), state.thresholds)

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:fused_update, fused})
    end)

    state = %__MODULE__{state | batch: [], fused_state: fused}
    {:noreply, schedule_flush(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    subscribers = MapSet.delete(state.subscribers, pid)

    feeds =
      state.feeds
      |> Enum.reject(fn {_id, fpid} -> fpid == pid end)
      |> Map.new()

    {:noreply, %__MODULE__{state | subscribers: subscribers, feeds: feeds}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private --

  defp fuse_batch(readings, thresholds) do
    grouped = Enum.group_by(readings, & &1.sensor_id)

    sensors =
      Map.new(grouped, fn {sensor_id, sensor_readings} ->
        values = Enum.map(sensor_readings, & &1.values)
        qualities = Enum.map(sensor_readings, & &1.quality)
        latest = List.last(sensor_readings)

        fused_values = do_weighted_average(values, qualities)

        alerts =
          check_thresholds(
            fused_values,
            Map.get(thresholds, sensor_id, %{})
          )

        {sensor_id,
         %{
           values: fused_values,
           quality: Enum.sum(qualities) / length(qualities),
           latest_timestamp: latest.timestamp,
           reading_count: length(sensor_readings),
           alerts: alerts
         }}
      end)

    %{sensors: sensors, fused_at: System.monotonic_time(:millisecond)}
  end

  @compile {:no_warn_undefined, Raxol.Sensor.Fusion.NxBackend}

  defp do_weighted_average(values_list, qualities) do
    if Code.ensure_loaded?(Raxol.Sensor.Fusion.NxBackend) do
      Raxol.Sensor.Fusion.NxBackend.weighted_average(values_list, qualities)
    else
      weighted_average(values_list, qualities)
    end
  end

  @epsilon 1.0e-10

  defp weighted_average(values_list, qualities) do
    total_quality = Enum.sum(qualities)

    if abs(total_quality) < @epsilon do
      hd(values_list)
    else
      all_keys =
        values_list
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      Map.new(all_keys, fn key ->
        weighted_sum =
          values_list
          |> Enum.zip(qualities)
          |> Enum.reduce(0.0, fn {vals, q}, acc ->
            case Map.get(vals, key) do
              v when is_number(v) -> acc + v * q
              _ -> acc
            end
          end)

        {key, weighted_sum / total_quality}
      end)
    end
  end

  defp check_thresholds(_values, thresholds) when map_size(thresholds) == 0 do
    []
  end

  defp check_thresholds(values, thresholds) do
    Enum.flat_map(thresholds, fn {key, {op, threshold}} ->
      case Map.get(values, key) do
        v when is_number(v) ->
          if threshold_violated?(v, op, threshold) do
            [%{key: key, value: v, op: op, threshold: threshold}]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp threshold_violated?(v, :gt, t), do: v > t
  defp threshold_violated?(v, :lt, t), do: v < t
  defp threshold_violated?(v, :gte, t), do: v >= t
  defp threshold_violated?(v, :lte, t), do: v <= t
  defp threshold_violated?(_v, _op, _t), do: false

  defp schedule_flush(%__MODULE__{} = state) do
    _ = cancel_timer(state.batch_ref)
    ref = Process.send_after(self(), :flush_batch, state.batch_window_ms)
    %__MODULE__{state | batch_ref: ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
