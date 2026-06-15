defmodule SystemMonitor do
  @moduledoc """
  Real-time BEAM system monitor built with Raxol TEA pattern.

  Shows memory usage, process count, scheduler info, and top processes.

  Keys: [q] quit | [r] refresh | [p] processes | [m] memory | [s] overview
  """

  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @spark ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  @impl true
  def init(_context) do
    %{
      view: :overview,
      tick: 0,
      mem_history: List.duplicate(0, 20),
      proc_offset: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        mem = :erlang.memory(:total)
        max_mem = 500_000_000
        pct = min(100, trunc(mem / max_mem * 100))
        history = (tl(model.mem_history) ++ [pct]) |> Enum.take(-20)
        {%{model | tick: model.tick + 1, mem_history: history}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "s"}} ->
        {%{model | view: :overview}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "p"}} ->
        {%{model | view: :processes, proc_offset: 0}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "m"}} ->
        {%{model | view: :memory}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        {%{model | proc_offset: model.proc_offset + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        {%{model | proc_offset: max(0, model.proc_offset - 1)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("System Monitor | [s]overview [p]processes [m]memory [q]quit",
          style: [:bold]
        ),
        case model.view do
          :overview -> render_overview(model)
          :processes -> render_processes(model)
          :memory -> render_memory(model)
        end
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end

  defp render_overview(model) do
    mem = :erlang.memory()
    total = Keyword.get(mem, :total, 0)
    procs = Keyword.get(mem, :processes, 0)
    proc_count = length(Process.list())
    schedulers = :erlang.system_info(:schedulers_online)
    sparkline = Enum.map_join(model.mem_history, "", &spark_char/1)

    box title: "Overview", style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        [
          text(
            "Memory:     #{format_bytes(total)} total | #{format_bytes(procs)} processes"
          ),
          text("Processes:  #{proc_count}"),
          text("Schedulers: #{schedulers}"),
          text("Tick:       #{model.tick}"),
          text(""),
          text("Memory trend: #{sparkline}")
        ]
      end
    end
  end

  defp render_processes(model) do
    procs =
      Process.list()
      |> Enum.map(fn pid ->
        info =
          Process.info(pid, [:registered_name, :memory, :reductions, :status])

        if info do
          name =
            case Keyword.get(info, :registered_name) do
              nil -> inspect(pid)
              n -> inspect(n)
            end

          %{
            name: name,
            memory: Keyword.get(info, :memory, 0),
            reductions: Keyword.get(info, :reductions, 0),
            status: Keyword.get(info, :status, :unknown)
          }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.memory, :desc)
      |> Enum.drop(model.proc_offset)
      |> Enum.take(15)

    box title: "Top Processes (by memory)",
        style: %{border: :single, padding: 1} do
      column do
        [
          text("Name                          Memory       Reds         Status",
            style: [:bold]
          )
        ] ++
          Enum.map(procs, fn p ->
            name = String.pad_trailing(String.slice(p.name, 0..28), 30)
            mem = String.pad_trailing(format_bytes(p.memory), 13)
            reds = String.pad_trailing(Integer.to_string(p.reductions), 13)
            text("#{name}#{mem}#{reds}#{p.status}")
          end)
      end
    end
  end

  defp render_memory(model) do
    mem = :erlang.memory()

    items = [
      {"Total", Keyword.get(mem, :total, 0)},
      {"Processes", Keyword.get(mem, :processes, 0)},
      {"System", Keyword.get(mem, :system, 0)},
      {"Atom", Keyword.get(mem, :atom, 0)},
      {"Binary", Keyword.get(mem, :binary, 0)},
      {"ETS", Keyword.get(mem, :ets, 0)}
    ]

    sparkline = Enum.map_join(model.mem_history, "", &spark_char/1)

    box title: "Memory Breakdown", style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        Enum.map(items, fn {label, bytes} ->
          text("#{String.pad_trailing(label, 12)} #{format_bytes(bytes)}")
        end) ++ [text(""), text("Trend: #{sparkline}")]
      end
    end
  end

  defp spark_char(pct) when pct >= 87, do: Enum.at(@spark, 7)
  defp spark_char(pct) when pct >= 75, do: Enum.at(@spark, 6)
  defp spark_char(pct) when pct >= 62, do: Enum.at(@spark, 5)
  defp spark_char(pct) when pct >= 50, do: Enum.at(@spark, 4)
  defp spark_char(pct) when pct >= 37, do: Enum.at(@spark, 3)
  defp spark_char(pct) when pct >= 25, do: Enum.at(@spark, 2)
  defp spark_char(pct) when pct >= 12, do: Enum.at(@spark, 1)
  defp spark_char(_), do: Enum.at(@spark, 0)

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes), do: "#{bytes} B"
end

Raxol.Core.Runtime.Log.info("SystemMonitor: Starting...")
{:ok, pid} = Raxol.start_link(SystemMonitor, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
