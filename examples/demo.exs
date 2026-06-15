# Raxol Demo
#
# A live BEAM dashboard showcasing Raxol's terminal UI capabilities:
# real-time scheduler utilization, memory sparklines, process table,
# color theming, and keyboard-driven navigation.
#
# What you'll learn:
#   - BEAM introspection: :erlang.system_flag, :erlang.statistics,
#     :erlang.memory, Process.info
#   - Scheduler utilization: delta active/total wall time between samples
#   - Sparkline rendering: Unicode block chars normalized to max value
#   - Panel cycling via module attribute list and index arithmetic
#   - Multi-panel layouts with active/inactive border styling
#
# Palette: Synthwave '84 Soft (mapped to ANSI)
#   cyan    -> accents, active titles
#   magenta -> highlights, key hints
#   yellow  -> warnings, table headers
#   green   -> healthy status
#   red     -> critical status
#
# Usage:
#   mix run examples/demo.exs
#
# Controls:
#   Tab/h/l  = switch panels
#   j/k      = scroll process table
#   Space    = pause/resume
#   q        = quit

defmodule RaxolDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log
  import Raxol.Animation.Helpers

  @panels [:runtime, :schedulers, :log, :processes]
  @spark ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  @bar_fill "█"
  @bar_empty "░"
  @mem_history_size 20
  @max_log_entries 12
  @max_proc_offset 20

  # -- TEA Callbacks --

  @impl true
  def init(_context) do
    # Enable BEAM scheduler wall time tracking. This lets us measure
    # how busy each scheduler is by comparing active vs total time
    # between consecutive samples.
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
  def update(message, model) do
    case message do
      :tick when model.paused ->
        {model, []}

      :tick ->
        # Sample scheduler wall time: each entry is {id, active, total}.
        # By comparing with the previous sample, we get utilization as
        # delta_active / delta_total * 100 for each scheduler.
        curr = :erlang.statistics(:scheduler_wall_time) |> Enum.sort()

        utils =
          Enum.zip(model.sched_prev, curr)
          |> Enum.map(fn {{_id, a1, t1}, {_id2, a2, t2}} ->
            delta_total = t2 - t1

            if delta_total > 0,
              do: round((a2 - a1) / delta_total * 100),
              else: 0
          end)

        mem_pct = mem_percent()

        history =
          (model.mem_history ++ [mem_pct]) |> Enum.take(-@mem_history_size)

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

      # Navigation
      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        {%{model | panel: next_panel(model.panel)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "l"}} ->
        {%{model | panel: next_panel(model.panel)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "h"}} ->
        {%{model | panel: prev_panel(model.panel)}, []}

      # Process table scroll
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}} ->
        {%{model | proc_offset: min(model.proc_offset + 1, @max_proc_offset)},
         []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}} ->
        {%{model | proc_offset: max(model.proc_offset - 1, 0)}, []}

      # Pause / Resume
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: " "}} ->
        log_msg = if model.paused, do: "Resumed", else: "Paused"
        log = [{ts(), log_msg} | model.log] |> Enum.take(@max_log_entries)
        {%{model | paused: !model.paused, log: log}, []}

      # Quit
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
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
    mem = mem_stats()
    uptime = System.monotonic_time(:second) - model.start_time
    pct = mem_percent()

    panel =
      box id: "runtime-panel",
          style: %{border: panel_border(active), width: 30, padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("BEAM Runtime", active),
              style: [:bold],
              fg: title_color(active)
            ),
            divider(char: "-"),
            text("Elixir     #{System.version()}"),
            text("OTP        #{:erlang.system_info(:otp_release)}"),
            text("Uptime     #{fmt_uptime(uptime)}"),
            spacer(size: 1),
            text("Processes  #{:erlang.system_info(:process_count)}"),
            text("Ports      #{length(:erlang.ports())}"),
            text("Atoms      #{fmt_num(:erlang.system_info(:atom_count))}"),
            text("ETS        #{length(:ets.all())}"),
            spacer(size: 1),
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
      end

    if active do
      panel |> animate(property: :opacity, from: 0.8, to: 1.0, duration: 200)
    else
      panel
    end
  end

  # -- Scheduler Panel --

  defp scheduler_panel(model) do
    active = model.panel == :schedulers
    utils = model.sched_utils

    sched_rows =
      utils
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

    avg = if utils == [], do: 0, else: round(Enum.sum(utils) / length(utils))

    panel =
      box id: "sched-panel",
          style: %{border: panel_border(active), width: 28, padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("Schedulers", active),
              style: [:bold],
              fg: title_color(active)
            ),
            divider(char: "-")
            | sched_rows ++
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
                  text("#{status_dot(avg)} #{sched_status(avg)}",
                    fg: bar_color(avg)
                  )
                ]
          ]
        end
      end

    if active do
      panel |> animate(property: :opacity, from: 0.8, to: 1.0, duration: 200)
    else
      panel
    end
  end

  # -- Event Log Panel --

  defp log_panel(model) do
    active = model.panel == :log
    tick_label = if model.paused, do: " (paused)", else: ""

    entries =
      model.log
      |> Enum.map(fn {time, msg} ->
        row style: %{gap: 1} do
          [
            text(time, style: [:dim]),
            text(msg)
          ]
        end
      end)

    panel =
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

    if active do
      panel |> animate(property: :opacity, from: 0.8, to: 1.0, duration: 200)
    else
      panel
    end
  end

  # -- Process Table --

  defp process_table(model) do
    active = model.panel == :processes
    procs = top_processes(model.proc_offset)

    header =
      row style: %{gap: 1} do
        [
          text(String.pad_trailing("PID", 16), style: [:bold], fg: :yellow),
          text(String.pad_trailing("Name", 28), style: [:bold], fg: :yellow),
          text(String.pad_leading("Reductions", 12),
            style: [:bold],
            fg: :yellow
          ),
          text(String.pad_leading("Memory", 10), style: [:bold], fg: :yellow)
        ]
      end

    rows =
      procs
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

    panel =
      box id: "proc-panel",
          style: %{border: panel_border(active), width: :fill, padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("Top Processes", active),
              style: [:bold],
              fg: title_color(active)
            ),
            divider(char: "-"),
            header,
            divider(char: "-")
            | rows
          ]
        end
      end

    if active do
      panel |> animate(property: :opacity, from: 0.8, to: 1.0, duration: 200)
    else
      panel
    end
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
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :reductions, :memory]) do
        nil ->
          []

        info ->
          name =
            case info[:registered_name] do
              [] -> inspect(pid)
              n -> inspect(n)
            end

          [
            %{
              pid: inspect(pid),
              name: name,
              reds: info[:reductions],
              mem: info[:memory]
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.reds, :desc)
    |> Enum.drop(offset)
    |> Enum.take(6)
  end

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

  # Sparkline: maps each value to a Unicode block character (▁▂▃▄▅▆▇█).
  # Values are normalized to the max in the window so the tallest bar
  # always uses the full-height character.
  defp spark_bar(values) do
    max_val = Enum.max(values ++ [1])

    values
    |> Enum.map(fn v ->
      idx = if max_val > 0, do: round(v / max_val * 7), else: 0
      Enum.at(@spark, min(idx, 7))
    end)
    |> Enum.join()
  end

  # Bar chart: filled (█) and empty (░) segments from a percentage.
  defp bar(pct, width) do
    filled = round(pct / 100 * width)
    empty = width - filled
    String.duplicate(@bar_fill, filled) <> String.duplicate(@bar_empty, empty)
  end

  defp bar_color(pct) when pct >= 80, do: :red
  defp bar_color(pct) when pct >= 60, do: :yellow
  defp bar_color(_pct), do: :green

  defp status_dot(pct) when pct >= 80, do: "●"
  defp status_dot(pct) when pct >= 60, do: "●"
  defp status_dot(_pct), do: "●"

  defp sched_status(pct) when pct >= 80, do: "High load"
  defp sched_status(pct) when pct >= 60, do: "Moderate"
  defp sched_status(_pct), do: "Healthy"

  defp name_color(name) do
    if String.contains?(name, "Raxol") or String.contains?(name, "Demo"),
      do: :magenta,
      else: :white
  end

  defp panel_border(true), do: :double
  defp panel_border(false), do: :single

  defp title_color(true), do: :cyan
  defp title_color(false), do: :white

  defp panel_title(title, true), do: ">> #{title} <<"
  defp panel_title(title, false), do: "   #{title}   "

  # -- Navigation --
  # Cycle through @panels using modular arithmetic on the index.

  defp next_panel(current) do
    idx = Enum.find_index(@panels, &(&1 == current))
    Enum.at(@panels, rem(idx + 1, length(@panels)))
  end

  defp prev_panel(current) do
    idx = Enum.find_index(@panels, &(&1 == current))
    Enum.at(@panels, rem(idx - 1 + length(@panels), length(@panels)))
  end

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
      "Scheduler util: #{70 + :rand.uniform(25)}%",
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

Raxol.Core.Runtime.Log.info("RaxolDemo: Starting...")
{:ok, pid} = Raxol.start_link(RaxolDemo, [])
Raxol.Core.Runtime.Log.info("RaxolDemo: Running. Press 'q' to quit.")

ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
