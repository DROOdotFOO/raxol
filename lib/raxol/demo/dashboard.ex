defmodule Raxol.Demo.Dashboard do
  @moduledoc """
  Live BEAM dashboard demo for `mix raxol.demo dashboard`.

  Showcases real-time terminal UI: scheduler utilization bars, memory sparklines,
  process table with sorting, event log, and keyboard-driven panel navigation.

  Palette: Synthwave '84 Soft (cyan accents, magenta hints, yellow headers).

  Controls: Tab/h/l to switch panels, j/k to scroll processes,
  Space to pause/resume, q/Ctrl+C to quit.
  """

  use Raxol.Core.Runtime.Application

  import Raxol.Animation.Helpers

  @panels [:runtime, :schedulers, :log, :processes]
  @next_panel Map.new(Enum.zip(@panels, tl(@panels) ++ [hd(@panels)]))
  @prev_panel Map.new(
                Enum.zip(@panels, [List.last(@panels) | Enum.drop(@panels, -1)])
              )
  @spark ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  @bar_fill "█"
  @bar_empty "░"
  @mem_history_size 20
  @max_log_entries 12

  @impl true
  def init(_context) do
    :erlang.system_flag(:scheduler_wall_time, true)

    %{
      tick: 0,
      panel: :runtime,
      paused: false,
      log: [
        {ts(), "Raxol runtime initialized"},
        {ts(), "TEA lifecycle active"},
        {ts(), "Rendering engine ready"}
      ],
      mem_history: List.duplicate(0, @mem_history_size),
      proc_offset: 0,
      start_time: System.monotonic_time(:second),
      sched_prev: :erlang.statistics(:scheduler_wall_time) |> Enum.sort(),
      sched_utils: []
    }
  end

  @impl true
  def update(:tick, model), do: do_tick(model)
  def update(message, model), do: handle_key(message, model)

  defp handle_key(message, model) do
    case message do
      key_match(:tab) -> handle_next_panel(model)
      key_match("l") -> handle_next_panel(model)
      key_match("h") -> handle_prev_panel(model)
      key_match("j") -> handle_scroll_down(model)
      key_match("k") -> handle_scroll_up(model)
      _ -> handle_action(message, model)
    end
  end

  defp handle_action(message, model) do
    case message do
      key_match(" ") -> handle_pause_toggle(model)
      key_match("q") -> {model, [command(:quit)]}
      key_match("c", ctrl: true) -> {model, [command(:quit)]}
      _ -> {model, []}
    end
  end

  defp do_tick(%{paused: true} = model), do: {model, []}

  defp do_tick(model) do
    curr = :erlang.statistics(:scheduler_wall_time) |> Enum.sort()

    utils =
      Enum.zip(model.sched_prev, curr)
      |> Enum.map(fn {{_id, a1, t1}, {_id2, a2, t2}} ->
        sched_utilization(a2 - a1, t2 - t1)
      end)

    mem_pct = mem_percent()

    history =
      Enum.concat(model.mem_history, [mem_pct])
      |> Enum.take(-@mem_history_size)

    entry = tick_entry(model.tick)
    log = [{ts(), entry} | model.log] |> Enum.take(@max_log_entries)

    {%{
       model
       | tick: model.tick + 1,
         sched_prev: curr,
         sched_utils: utils,
         mem_history: history,
         log: log
     }, []}
  end

  defp handle_next_panel(model),
    do: {%{model | panel: next_panel(model.panel)}, []}

  defp handle_prev_panel(model),
    do: {%{model | panel: prev_panel(model.panel)}, []}

  defp handle_scroll_down(model),
    do: {%{model | proc_offset: min(model.proc_offset + 1, 20)}, []}

  defp handle_scroll_up(model),
    do: {%{model | proc_offset: max(model.proc_offset - 1, 0)}, []}

  defp handle_pause_toggle(model) do
    log_msg = if model.paused, do: "Resumed", else: "Paused"
    log = [{ts(), log_msg} | model.log] |> Enum.take(@max_log_entries)
    {%{model | paused: !model.paused, log: log}, []}
  end

  @impl true
  def view(model) do
    column style: %{padding: 0, gap: 0} do
      [
        header_bar(model),
        spacer(size: 1),
        row style: %{gap: 1} do
          [
            runtime_panel(model),
            scheduler_panel(model),
            log_panel(model)
          ]
        end,
        spacer(size: 1),
        process_table(model),
        key_bar(model)
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end

  # -- Header --

  defp header_bar(model) do
    status = if model.paused, do: "PAUSED", else: clock()

    box style: %{border: :double, width: :fill, padding: 0} do
      row style: %{gap: 1, justify_content: :space_between} do
        [
          text("  R A X O L", style: [:bold], fg: :cyan),
          text("Terminal UI Framework for Elixir", style: [:dim]),
          text(status,
            style: [:bold],
            fg: if(model.paused, do: :yellow, else: :cyan)
          )
        ]
      end
    end
  end

  # -- BEAM Runtime Panel --

  defp runtime_panel(model) do
    active = model.panel == :runtime

    box id: "runtime-panel",
        style: %{border: panel_border(active), width: 30, padding: 1} do
      column style: %{gap: 0} do
        [
          text(panel_title("BEAM Runtime", active),
            style: [:bold],
            fg: title_color(active)
          ),
          divider(char: "-")
          | runtime_version_rows(model) ++
              [spacer(size: 1)] ++
              runtime_process_rows() ++
              [spacer(size: 1)] ++
              runtime_memory_rows(model)
        ]
      end
    end
    |> maybe_animate_active(active)
  end

  defp runtime_version_rows(model) do
    uptime = System.monotonic_time(:second) - model.start_time

    [
      text("Elixir     #{System.version()}"),
      text("OTP        #{:erlang.system_info(:otp_release)}"),
      text("Uptime     #{fmt_uptime(uptime)}")
    ]
  end

  defp runtime_process_rows do
    [
      text("Processes  #{:erlang.system_info(:process_count)}"),
      text("Ports      #{length(:erlang.ports())}"),
      text("Atoms      #{fmt_num(:erlang.system_info(:atom_count))}"),
      text("ETS        #{length(:ets.all())}")
    ]
  end

  defp runtime_memory_rows(model) do
    mem = mem_stats()
    pct = mem_percent()

    [
      text("Memory", style: [:bold], fg: :cyan),
      text("  Total    #{mem.total} MB"),
      text("  Used     #{mem.used} MB"),
      text("  Binary   #{mem.binary} MB"),
      spacer(size: 1),
      text("  #{spark_bar(model.mem_history)}", fg: :cyan),
      spacer(size: 1),
      row id: "mem-bar", style: %{gap: 1} do
        [
          text(bar(pct, 14), fg: bar_color(pct)),
          text("#{pct}%", style: [:bold], fg: bar_color(pct))
        ]
      end
      |> animate(
        property: :fg,
        to: bar_color(pct),
        duration: 500,
        easing: :ease_out_sine
      )
    ]
  end

  # -- Scheduler Panel --

  defp scheduler_panel(model) do
    active = model.panel == :schedulers

    box id: "sched-panel",
        style: %{border: panel_border(active), width: 28, padding: 1} do
      column style: %{gap: 0} do
        [
          text(panel_title("Schedulers", active),
            style: [:bold],
            fg: title_color(active)
          ),
          divider(char: "-")
          | sched_util_rows(model.sched_utils) ++
              sched_summary_rows(model.sched_utils)
        ]
      end
    end
    |> maybe_animate_active(active)
  end

  defp sched_util_rows(sched_utils) do
    sched_utils
    |> Enum.with_index(1)
    |> Enum.map(fn {pct, idx} ->
      row style: %{gap: 1} do
        [
          text("##{idx}", style: [:dim]),
          text(bar(pct, 12), fg: bar_color(pct)),
          text("#{String.pad_leading("#{pct}", 3)}%", fg: bar_color(pct))
        ]
      end
    end)
  end

  defp sched_summary_rows(sched_utils) do
    avg = avg_utilization(sched_utils)

    [
      spacer(size: 1),
      divider(char: "-"),
      row style: %{gap: 1} do
        [
          text("Avg", style: [:bold]),
          text(bar(avg, 12), fg: bar_color(avg)),
          text("#{String.pad_leading("#{avg}", 3)}%",
            style: [:bold],
            fg: bar_color(avg)
          )
        ]
      end,
      spacer(size: 1),
      text("#{status_dot(avg)} #{sched_status(avg)}", fg: bar_color(avg))
    ]
  end

  # -- Event Log Panel --

  defp log_panel(model) do
    active = model.panel == :log
    tick_label = if model.paused, do: " (paused)", else: ""

    entries =
      Enum.map(model.log, fn {time, msg} ->
        row style: %{gap: 1} do
          [text(time, style: [:dim]), text(msg)]
        end
      end)

    box id: "log-panel",
        style: %{border: panel_border(active), width: 36, padding: 1} do
      column style: %{gap: 0} do
        [
          text(panel_title("Event Log#{tick_label}", active),
            style: [:bold],
            fg: title_color(active)
          ),
          divider(char: "-")
          | entries
        ]
      end
    end
    |> maybe_animate_active(active)
  end

  # -- Process Table --

  defp process_table(model) do
    active = model.panel == :processes

    box id: "proc-panel",
        style: %{border: panel_border(active), width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [
          text(panel_title("Top Processes", active),
            style: [:bold],
            fg: title_color(active)
          ),
          divider(char: "-"),
          proc_table_header(),
          divider(char: "-")
          | proc_table_rows(model.proc_offset)
        ]
      end
    end
    |> maybe_animate_active(active)
  end

  defp proc_table_header do
    row style: %{gap: 1} do
      [
        text(String.pad_trailing("PID", 16), style: [:bold], fg: :yellow),
        text(String.pad_trailing("Name", 28), style: [:bold], fg: :yellow),
        text(String.pad_leading("Reductions", 12), style: [:bold], fg: :yellow),
        text(String.pad_leading("Memory", 10), style: [:bold], fg: :yellow)
      ]
    end
  end

  defp proc_table_rows(offset) do
    offset
    |> top_processes()
    |> Enum.map(fn p ->
      row style: %{gap: 1} do
        [
          text(String.pad_trailing(p.pid, 16), style: [:dim]),
          text(String.pad_trailing(p.name, 28), fg: name_color(p.name)),
          text(String.pad_leading(fmt_num(p.reds), 12)),
          text(String.pad_leading(fmt_bytes(p.mem), 10))
        ]
      end
    end)
  end

  # -- Key Hints Bar --

  defp key_bar(model) do
    pause_label = if model.paused, do: "Resume", else: "Pause"

    row style: %{gap: 2} do
      [
        text(" Tab/h/l", style: [:bold], fg: :magenta),
        text("panel", style: [:dim]),
        text("j/k", style: [:bold], fg: :magenta),
        text("scroll", style: [:dim]),
        text("Space", style: [:bold], fg: :magenta),
        text(pause_label, style: [:dim]),
        text("q", style: [:bold], fg: :magenta),
        text("quit", style: [:dim])
      ]
    end
  end

  # -- Data Helpers --

  defp top_processes(offset) do
    Process.list()
    |> Enum.flat_map(&process_info_entry/1)
    |> Enum.sort_by(& &1.reds, :desc)
    |> Enum.drop(offset)
    |> Enum.take(6)
  end

  defp process_info_entry(pid) do
    case Process.info(pid, [:registered_name, :reductions, :memory]) do
      nil ->
        []

      info ->
        [
          %{
            pid: inspect(pid),
            name: process_display_name(pid, info[:registered_name]),
            reds: info[:reductions],
            mem: info[:memory]
          }
        ]
    end
  end

  defp process_display_name(pid, []), do: inspect(pid)
  defp process_display_name(_pid, name), do: inspect(name)

  defp mem_stats do
    m = :erlang.memory()

    %{
      total: Float.round(m[:total] / 1_048_576, 1),
      used: Float.round((m[:total] - m[:binary]) / 1_048_576, 1),
      binary: Float.round(m[:binary] / 1_048_576, 1)
    }
  end

  defp mem_percent do
    m = :erlang.memory()
    round((m[:total] - m[:binary]) / m[:total] * 100)
  end

  # -- Rendering Helpers --

  defp spark_bar(values) do
    max_val = Enum.max([1 | values])

    values
    |> Enum.map_join(fn v ->
      idx = if max_val > 0, do: round(v / max_val * 7), else: 0
      Enum.at(@spark, min(idx, 7))
    end)
  end

  defp bar(pct, width) do
    filled = round(pct / 100 * width)
    empty = width - filled
    String.duplicate(@bar_fill, filled) <> String.duplicate(@bar_empty, empty)
  end

  defp sched_utilization(_active, delta_total) when delta_total <= 0, do: 0

  defp sched_utilization(active, delta_total),
    do: round(active / delta_total * 100)

  defp avg_utilization([]), do: 0
  defp avg_utilization(utils), do: round(Enum.sum(utils) / length(utils))

  defp bar_color(pct) when pct >= 80, do: :red
  defp bar_color(pct) when pct >= 60, do: :yellow
  defp bar_color(_pct), do: :green

  defp status_dot(pct) when pct >= 80, do: "!"
  defp status_dot(pct) when pct >= 60, do: "~"
  defp status_dot(_pct), do: "*"

  defp sched_status(pct) when pct >= 80, do: "High load"
  defp sched_status(pct) when pct >= 60, do: "Moderate"
  defp sched_status(_pct), do: "Healthy"

  defp name_color(name) do
    if String.contains?(name, "Raxol") or String.contains?(name, "Demo"),
      do: :magenta,
      else: :white
  end

  defp maybe_animate_active(element, true),
    do:
      element |> animate(property: :opacity, from: 0.8, to: 1.0, duration: 200)

  defp maybe_animate_active(element, false), do: element

  defp panel_border(true), do: :double
  defp panel_border(false), do: :single

  defp title_color(true), do: :cyan
  defp title_color(false), do: :white

  defp panel_title(title, true), do: ">> #{title} <<"
  defp panel_title(title, false), do: "   #{title}   "

  # -- Navigation --

  defp next_panel(current), do: Map.fetch!(@next_panel, current)
  defp prev_panel(current), do: Map.fetch!(@prev_panel, current)

  # -- Formatting --

  defp ts, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")

  defp clock, do: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S UTC")

  defp fmt_uptime(s) do
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    sec = rem(s, 60)

    cond do
      h > 0 -> "#{h}h #{m}m #{sec}s"
      m > 0 -> "#{m}m #{sec}s"
      true -> "#{sec}s"
    end
  end

  defp fmt_num(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_num(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_num(n), do: "#{n}"

  defp fmt_bytes(b) when b >= 1_048_576,
    do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp fmt_bytes(b) when b >= 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp fmt_bytes(b), do: "#{b} B"

  defp tick_entry(count) do
    entries = [
      "Memory stats sampled",
      "Process tree scanned",
      "Frame #{count} rendered",
      "Scheduler util sampled",
      "GC minor collection",
      "IO: #{:rand.uniform(500) + 100} KB/s",
      "ETS tables: #{length(:ets.all())}",
      "Reductions sampled",
      "Port status checked",
      "Uptime checkpoint"
    ]

    Enum.at(entries, rem(count, length(entries)))
  end
end
