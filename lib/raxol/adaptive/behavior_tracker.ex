defmodule Raxol.Adaptive.BehaviorTracker do
  @moduledoc """
  Records pilot interactions as time-series events.

  Captures pane focus dwell times, command frequency, alert response
  latency, and layout overrides. Computes windowed aggregates and
  notifies subscribers for downstream recommendation.

  Focus events use `:pane_focus` with a `:pane_id`; the next command is
  annotated with that identifier as `:focused_pane`. `:widget_hover` events are
  recorded independently and never replace the current focus.
  """

  use GenServer

  require Logger

  @default_buffer_size 10_000
  @default_window_size_ms 60_000
  @max_aggregates 100

  @type pane_id :: atom() | String.t()

  @type event_type ::
          :pane_focus
          | :widget_hover
          | :pane_dwell
          | :command_issued
          | :alert_response
          | :scroll_pattern
          | :takeover_start
          | :takeover_end
          | :layout_override
  @type behavior_event :: %{
          timestamp: integer(),
          type: event_type(),
          data: map()
        }

  @type aggregate :: %{
          window_start: integer(),
          pane_dwell_times: %{pane_id() => float()},
          command_frequency: %{String.t() => non_neg_integer()},
          avg_alert_response_ms: float(),
          most_used_panes: [pane_id()],
          least_used_panes: [pane_id()],
          scroll_frequency: %{pane_id() => non_neg_integer()},
          scroll_velocity: %{pane_id() => float()},
          takeover_duration_ms: %{pane_id() => float()},
          layout_override_count: non_neg_integer(),
          command_concentration: %{pane_id() => non_neg_integer()}
        }

  @type t :: %__MODULE__{
          session_id: binary() | nil,
          events: CircularBuffer.t(),
          buffer_size: pos_integer(),
          aggregates: %{integer() => aggregate()},
          window_size_ms: pos_integer(),
          tracking_enabled: boolean(),
          subscribers: MapSet.t(pid()),
          aggregate_ref: reference() | nil,
          current_focus: pane_id() | nil
        }

  defstruct session_id: nil,
            events: nil,
            buffer_size: @default_buffer_size,
            aggregates: %{},
            window_size_ms: @default_window_size_ms,
            tracking_enabled: true,
            subscribers: MapSet.new(),
            aggregate_ref: nil,
            current_focus: nil

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record(GenServer.server(), event_type(), map()) :: :ok
  def record(server \\ __MODULE__, event_type, data) do
    GenServer.cast(server, {:record, event_type, data})
  end

  @spec get_aggregates(GenServer.server(), pos_integer()) :: [aggregate()]
  def get_aggregates(server \\ __MODULE__, window_count \\ 5) do
    GenServer.call(server, {:get_aggregates, window_count})
  end

  @spec get_recent_events(GenServer.server(), pos_integer()) :: [
          behavior_event()
        ]
  def get_recent_events(server \\ __MODULE__, count \\ 20) do
    GenServer.call(server, {:get_recent_events, count})
  end

  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__) do
    GenServer.call(server, :enable)
  end

  @spec disable(GenServer.server()) :: :ok
  def disable(server \\ __MODULE__) do
    GenServer.call(server, :disable)
  end

  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    window_size_ms = Keyword.get(opts, :window_size_ms, @default_window_size_ms)
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    state = %__MODULE__{
      session_id: session_id,
      events: CircularBuffer.new(buffer_size),
      buffer_size: buffer_size,
      window_size_ms: window_size_ms
    }

    {:ok, schedule_aggregate(state)}
  end

  @impl true
  def handle_call({:get_aggregates, window_count}, _from, %__MODULE__{} = state) do
    recent =
      state.aggregates
      |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
      |> Enum.take(window_count)
      |> Enum.map(fn {_ts, agg} -> agg end)

    {:reply, recent, state}
  end

  @impl true
  def handle_call({:get_recent_events, count}, _from, %__MODULE__{} = state) do
    {:reply, Enum.take(state.events, count), state}
  end

  @impl true
  def handle_call(:enable, _from, %__MODULE__{} = state) do
    state = %__MODULE__{state | tracking_enabled: true}
    {:reply, :ok, schedule_aggregate(state)}
  end

  @impl true
  def handle_call(:disable, _from, %__MODULE__{} = state) do
    _ = if state.aggregate_ref, do: Process.cancel_timer(state.aggregate_ref)

    {:reply, :ok,
     %__MODULE__{state | tracking_enabled: false, aggregate_ref: nil}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)

    {:reply, :ok,
     %__MODULE__{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_cast(
        {:record, _type, _data},
        %__MODULE__{tracking_enabled: false} = state
      ) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record, event_type, data}, %__MODULE__{} = state) do
    # Annotate command events with current focus pane for concentration tracking
    data =
      if event_type == :command_issued and state.current_focus != nil do
        Map.put_new(data, :focused_pane, state.current_focus)
      else
        data
      end

    event = %{
      timestamp: System.monotonic_time(:millisecond),
      type: event_type,
      data: data
    }

    events = CircularBuffer.insert(state.events, event)

    # Track focus changes
    current_focus =
      case event_type do
        :pane_focus -> Map.get(data, :pane_id, state.current_focus)
        _ -> state.current_focus
      end

    {:noreply,
     %__MODULE__{state | events: events, current_focus: current_focus}}
  end

  @impl true
  def handle_info(
        :aggregate_window,
        %__MODULE__{tracking_enabled: false} = state
      ) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:aggregate_window, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    window_start = now - state.window_size_ms

    # Use all buffered events -- the CircularBuffer's fixed size
    # already bounds the data. Adding a small margin to the timestamp
    # filter avoids off-by-one at window boundaries.
    window_events =
      state.events
      |> Enum.filter(fn e -> e.timestamp >= window_start - 100 end)

    aggregate = compute_aggregate(window_start, window_events)

    aggregates =
      state.aggregates
      |> Map.put(window_start, aggregate)
      |> cap_aggregates()

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:behavior_aggregate, aggregate})
    end)

    state = %__MODULE__{state | aggregates: aggregates}
    {:noreply, schedule_aggregate(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply,
     %__MODULE__{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info(msg, %__MODULE__{} = state) do
    Logger.debug("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # -- Private --

  defp compute_aggregate(window_start, events) do
    pane_dwell_times = compute_pane_dwell_times(events)
    command_frequency = compute_command_frequency(events)
    avg_alert_response = compute_avg_alert_response(events)
    {scroll_frequency, scroll_velocity} = compute_scroll_metrics(events)
    takeover_duration_ms = compute_takeover_duration(events)
    layout_override_count = compute_layout_overrides(events)
    command_concentration = compute_command_concentration(events)

    sorted_panes =
      pane_dwell_times
      |> Enum.sort_by(fn {_k, v} -> v end, :desc)
      |> Enum.map(fn {k, _v} -> k end)

    %{
      window_start: window_start,
      pane_dwell_times: pane_dwell_times,
      command_frequency: command_frequency,
      avg_alert_response_ms: avg_alert_response,
      most_used_panes: Enum.take(sorted_panes, 3),
      least_used_panes: sorted_panes |> Enum.reverse() |> Enum.take(3),
      scroll_frequency: scroll_frequency,
      scroll_velocity: scroll_velocity,
      takeover_duration_ms: takeover_duration_ms,
      layout_override_count: layout_override_count,
      command_concentration: command_concentration
    }
  end

  defp compute_pane_dwell_times(events) do
    events
    |> Enum.filter(fn e -> e.type == :pane_dwell end)
    |> Enum.group_by(fn e -> Map.get(e.data, :pane_id) end)
    |> Map.new(fn {pane_id, pane_events} ->
      total_ms =
        pane_events
        |> Enum.map(fn e -> Map.get(e.data, :dwell_ms, 0) end)
        |> Enum.sum()

      {pane_id, total_ms / 1000.0}
    end)
  end

  defp compute_command_frequency(events) do
    events
    |> Enum.filter(fn e -> e.type == :command_issued end)
    |> Enum.group_by(fn e -> Map.get(e.data, :command, "unknown") end)
    |> Map.new(fn {cmd, cmd_events} -> {cmd, length(cmd_events)} end)
  end

  defp compute_avg_alert_response(events) do
    responses =
      events
      |> Enum.filter(fn e -> e.type == :alert_response end)
      |> Enum.map(fn e -> Map.get(e.data, :response_ms, 0) end)

    case responses do
      [] -> 0.0
      list -> Enum.sum(list) / length(list)
    end
  end

  defp compute_scroll_metrics(events) do
    scroll_events =
      Enum.filter(events, fn e -> e.type == :scroll_pattern end)

    by_pane =
      Enum.group_by(scroll_events, fn e -> Map.get(e.data, :pane_id) end)

    frequency =
      Map.new(by_pane, fn {pane_id, pane_events} ->
        {pane_id, length(pane_events)}
      end)

    velocity =
      Map.new(by_pane, fn {pane_id, pane_events} ->
        deltas =
          Enum.map(pane_events, fn e ->
            abs(Map.get(e.data, :delta, 0))
          end)

        avg = if deltas == [], do: 0.0, else: Enum.sum(deltas) / length(deltas)
        {pane_id, avg * 1.0}
      end)

    {frequency, velocity}
  end

  defp compute_takeover_duration(events) do
    # Pair takeover_start/end events per pane and sum durations
    events
    |> Enum.filter(fn e -> e.type in [:takeover_start, :takeover_end] end)
    |> Enum.group_by(fn e -> Map.get(e.data, :pane_id) end)
    |> Map.new(fn {pane_id, pane_events} ->
      sorted = Enum.sort_by(pane_events, & &1.timestamp)
      duration = sum_takeover_pairs(sorted, 0)
      {pane_id, duration * 1.0}
    end)
  end

  defp sum_takeover_pairs([], acc), do: acc

  defp sum_takeover_pairs([start, stop | rest], acc)
       when start.type == :takeover_start and stop.type == :takeover_end do
    sum_takeover_pairs(rest, acc + (stop.timestamp - start.timestamp))
  end

  defp sum_takeover_pairs([_ | rest], acc), do: sum_takeover_pairs(rest, acc)

  defp compute_layout_overrides(events) do
    Enum.count(events, fn e -> e.type == :layout_override end)
  end

  defp compute_command_concentration(events) do
    events
    |> Enum.filter(fn e -> e.type == :command_issued end)
    |> Enum.group_by(fn e -> Map.get(e.data, :focused_pane) end)
    |> Map.delete(nil)
    |> Map.new(fn {pane_id, pane_events} -> {pane_id, length(pane_events)} end)
  end

  defp cap_aggregates(aggregates)
       when map_size(aggregates) <= @max_aggregates do
    aggregates
  end

  defp cap_aggregates(aggregates) do
    aggregates
    |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
    |> Enum.take(@max_aggregates)
    |> Map.new()
  end

  defp schedule_aggregate(%__MODULE__{} = state) do
    _ = if state.aggregate_ref, do: Process.cancel_timer(state.aggregate_ref)
    ref = Process.send_after(self(), :aggregate_window, state.window_size_ms)
    %__MODULE__{state | aggregate_ref: ref}
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
