defmodule Raxol.Performance.CycleProfiler do
  @moduledoc """
  Profiles TEA update/view/render cycle timings.

  Records per-cycle timing breakdowns in a CircularBuffer, computes rolling
  statistics, and detects slow cycles that exceed the budget threshold.

  ## Usage

      Raxol.start_link(MyApp, profiler: true)
      Raxol.start_link(MyApp, profiler: [max_entries: 2000, slow_threshold_us: 33_333])

      CycleProfiler.stats()        # => %{update: %{...}, render: %{...}}
      CycleProfiler.slow_cycles()  # => [%RenderTiming{...}]
      CycleProfiler.export(path)   # => :ok
      CycleProfiler.reset()        # => :ok

  Zero cost when disabled -- the Dispatcher and Engine check for `nil` pid
  before calling any recording functions.
  """

  use GenServer

  alias Raxol.Performance.CycleProfiler.Stats

  @default_max_entries 1000
  @default_slow_threshold_us 16_667

  defmodule UpdateTiming do
    @moduledoc false
    defstruct [
      :timestamp_us,
      :update_us,
      :message_summary,
      :memory_before,
      :memory_after
    ]
  end

  defmodule RenderTiming do
    @moduledoc false
    defstruct [
      :timestamp_us,
      :view_us,
      :layout_us,
      :render_us,
      :plugin_us,
      :backend_us,
      :total_us,
      :memory_before,
      :memory_after
    ]
  end

  defmodule State do
    @moduledoc false
    defstruct update_buffer: nil,
              render_buffer: nil,
              max_entries: 1000,
              slow_threshold_us: 16_667,
              slow_count: 0,
              total_count: 0,
              subscribers: []
  end

  # -- Client API --

  @doc "Starts the cycle profiler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Records an update cycle timing. Called by the Dispatcher."
  @spec record_update(pid() | atom(), map()) :: :ok
  def record_update(pid \\ __MODULE__, timing) do
    GenServer.cast(pid, {:record_update, timing})
  end

  @doc "Records a render cycle timing. Called by the Engine."
  @spec record_render(pid() | atom(), map()) :: :ok
  def record_render(pid \\ __MODULE__, timing) do
    GenServer.cast(pid, {:record_render, timing})
  end

  @doc "Returns computed statistics for update and render cycles."
  @spec stats(pid() | atom()) :: map()
  def stats(pid \\ __MODULE__) do
    GenServer.call(pid, :stats)
  end

  @doc "Returns render cycles that exceeded the slow threshold."
  @spec slow_cycles(pid() | atom()) :: [map()]
  def slow_cycles(pid \\ __MODULE__) do
    GenServer.call(pid, :slow_cycles)
  end

  @doc "Returns the total and slow cycle counts."
  @spec counts(pid() | atom()) :: %{
          total: non_neg_integer(),
          slow: non_neg_integer()
        }
  def counts(pid \\ __MODULE__) do
    GenServer.call(pid, :counts)
  end

  @doc "Exports profiling data to a file (Erlang term format)."
  @spec export(pid() | atom(), Path.t()) :: :ok | {:error, term()}
  def export(pid \\ __MODULE__, path) do
    GenServer.call(pid, {:export, path})
  end

  @doc "Resets all recorded data."
  @spec reset(pid() | atom()) :: :ok
  def reset(pid \\ __MODULE__) do
    GenServer.cast(pid, :reset)
  end

  @doc "Subscribes the calling process to slow-cycle notifications."
  @spec subscribe(pid() | atom()) :: :ok
  def subscribe(pid \\ __MODULE__) do
    GenServer.cast(pid, {:subscribe, self()})
  end

  # -- Server --

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_entries, @default_max_entries)

    threshold =
      Keyword.get(opts, :slow_threshold_us, @default_slow_threshold_us)

    state = %State{
      update_buffer: CircularBuffer.new(max),
      render_buffer: CircularBuffer.new(max),
      max_entries: max,
      slow_threshold_us: threshold,
      slow_count: 0,
      total_count: 0,
      subscribers: []
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_update, timing}, %State{} = state) do
    entry = %UpdateTiming{
      timestamp_us: System.monotonic_time(:microsecond),
      update_us: Map.get(timing, :update_us, 0),
      message_summary: Map.get(timing, :message_summary),
      memory_before: Map.get(timing, :memory_before, 0),
      memory_after: Map.get(timing, :memory_after, 0)
    }

    buffer = CircularBuffer.insert(state.update_buffer, entry)
    {:noreply, %{state | update_buffer: buffer}}
  end

  @impl true
  def handle_cast({:record_render, timing}, %State{} = state) do
    entry = build_render_entry(timing)
    buffer = CircularBuffer.insert(state.render_buffer, entry)
    slow = maybe_count_slow(entry, state)

    {:noreply,
     %{
       state
       | render_buffer: buffer,
         total_count: state.total_count + 1,
         slow_count: slow
     }}
  end

  @impl true
  def handle_cast(:reset, %State{} = state) do
    {:noreply,
     %{
       state
       | update_buffer: CircularBuffer.new(state.max_entries),
         render_buffer: CircularBuffer.new(state.max_entries),
         slow_count: 0,
         total_count: 0
     }}
  end

  @impl true
  def handle_cast({:subscribe, pid}, %State{} = state) do
    if pid in state.subscribers do
      {:noreply, state}
    else
      _ = Process.monitor(pid)
      {:noreply, %{state | subscribers: [pid | state.subscribers]}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{} = state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, %State{} = state) do
    updates = CircularBuffer.to_list(state.update_buffer)
    renders = CircularBuffer.to_list(state.render_buffer)

    update_stats = Stats.compute_multi(updates, [:update_us])

    render_stats =
      Stats.compute_multi(renders, [
        :view_us,
        :layout_us,
        :render_us,
        :plugin_us,
        :backend_us,
        :total_us
      ])

    result = %{
      update: update_stats,
      render: render_stats,
      total_cycles: state.total_count,
      slow_cycles: state.slow_count,
      slow_threshold_us: state.slow_threshold_us
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(:slow_cycles, _from, %State{} = state) do
    slow =
      state.render_buffer
      |> CircularBuffer.to_list()
      |> Enum.filter(fn entry -> entry.total_us > state.slow_threshold_us end)

    {:reply, slow, state}
  end

  @impl true
  def handle_call(:counts, _from, %State{} = state) do
    {:reply, %{total: state.total_count, slow: state.slow_count}, state}
  end

  @impl true
  def handle_call({:export, path}, _from, %State{} = state) do
    data = %{
      updates: CircularBuffer.to_list(state.update_buffer),
      renders: CircularBuffer.to_list(state.render_buffer),
      slow_threshold_us: state.slow_threshold_us,
      total_count: state.total_count,
      slow_count: state.slow_count
    }

    binary = :erlang.term_to_binary(data)

    case File.write(path, binary) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp build_render_entry(timing) do
    %RenderTiming{
      timestamp_us: System.monotonic_time(:microsecond),
      view_us: Map.get(timing, :view_us, 0),
      layout_us: Map.get(timing, :layout_us, 0),
      render_us: Map.get(timing, :render_us, 0),
      plugin_us: Map.get(timing, :plugin_us, 0),
      backend_us: Map.get(timing, :backend_us, 0),
      total_us: Map.get(timing, :total_us, 0),
      memory_before: Map.get(timing, :memory_before, 0),
      memory_after: Map.get(timing, :memory_after, 0)
    }
  end

  defp maybe_count_slow(entry, state) do
    if entry.total_us > state.slow_threshold_us do
      notify_subscribers(state.subscribers, {:slow_cycle, entry})
      state.slow_count + 1
    else
      state.slow_count
    end
  end

  defp notify_subscribers(subscribers, message) do
    Enum.each(subscribers, fn pid ->
      if Process.alive?(pid), do: send(pid, message)
    end)
  end
end
