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
#   - Sparkline rendering: Unicode block chars normalized over the window
#   - Resize-aware layout: track :resize events in the model and derive
#     every panel width, bar width, and row count from the terminal size
#   - Pinned footer: flex: 1 on the middle band keeps the key bar visible
#   - Panel cycling via module attribute list and index arithmetic
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
#   j/k      = scroll the active panel (Event Log, Top Processes)
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
  @mem_history_size 40
  @max_log_entries 50

  # Content rows inside each top panel (borders and padding excluded).
  # The runtime panel's natural height; the other two pad up to match.
  @top_band 14

  # -- TEA Callbacks --

  @impl true
  def init(context) do
    # Enable BEAM scheduler wall time tracking. This lets us measure
    # how busy each scheduler is by comparing active vs total time
    # between consecutive samples.
    :erlang.system_flag(:scheduler_wall_time, true)

    %{
      tick: 0,
      panel: :runtime,
      paused: false,
      # The driver reports the real size via an initial :resize event,
      # then again on every SIGWINCH; these are just the pre-boot defaults.
      width: Map.get(context, :width, 80),
      height: Map.get(context, :height, 24),
      log: [
        {ts(), "Raxol runtime initialized"},
        {ts(), "TEA lifecycle active"},
        {ts(), "Rendering engine ready"}
      ],
      log_offset: 0,
      mem_history: [],
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

        history =
          (model.mem_history ++ [mem_total_mb()])
          |> Enum.take(-@mem_history_size)

        entry = sampled_entry(model.tick, utils)
        log = [{ts(), entry} | model.log] |> Enum.take(@max_log_entries)

        {%{
           model
           | tick: model.tick + 1,
             sched_prev: curr,
             sched_utils: utils,
             mem_history: history,
             log: log
         }, []}

      # The terminal told us its size (initially and on every window
      # resize); every dimension in view/1 derives from these two numbers.
      %Raxol.Core.Events.Event{type: :resize, data: %{width: w, height: h}} ->
        {%{model | width: w, height: h}, []}

      # Navigation
      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        {%{model | panel: next_panel(model.panel)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "l"}} ->
        {%{model | panel: next_panel(model.panel)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "h"}} ->
        {%{model | panel: prev_panel(model.panel)}, []}

      # j/k scroll whichever panel is active (log and process table).
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}} ->
        {scroll_panel(model, 1), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}} ->
        {scroll_panel(model, -1), []}

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
    geo = geometry(model)

    column style: %{padding: 0, gap: 0} do
      [
        header_bar(model),
        row style: %{gap: 1} do
          [
            runtime_panel(model, geo),
            scheduler_panel(model, geo),
            log_panel(model, geo)
          ]
        end,
        process_table(model, geo),
        key_bar(model)
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end

  # -- Layout --

  # Every size on screen derives from the tracked terminal dimensions:
  # the three top panels split the width 25/35/40 (with floors for small
  # terminals), and the process table gets every row left between the
  # header, the top band, and the key bar.
  defp geometry(model) do
    avail = max(model.width - 2, 76)

    runtime_w = max(round(avail * 0.25), 26)
    sched_w = max(round(avail * 0.35), 28)
    log_w = max(avail - runtime_w - sched_w, 24)

    # header 3 + key bar 1 + top band chrome 4 + table chrome 8
    proc_rows = max(model.height - 4 - (@top_band + 4) - 8, 3)

    %{
      runtime_w: runtime_w,
      sched_w: sched_w,
      log_w: log_w,
      proc_rows: proc_rows
    }
  end

  defp scroll_panel(model, delta) do
    case model.panel do
      :processes ->
        max_offset =
          max(
            :erlang.system_info(:process_count) - geometry(model).proc_rows,
            0
          )

        %{model | proc_offset: clamp(model.proc_offset + delta, 0, max_offset)}

      :log ->
        max_offset = max(length(model.log) - log_capacity(), 0)
        %{model | log_offset: clamp(model.log_offset + delta, 0, max_offset)}

      _ ->
        model
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp log_capacity, do: @top_band - 2

  # -- Header --

  defp header_bar(model) do
    status = if model.paused, do: "PAUSED", else: clock()

    # column stretch already fills width; :fill is not a real size
    box style: %{border: :double, padding: 0} do
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

  defp runtime_panel(model, geo) do
    active = model.panel == :runtime
    uptime = System.monotonic_time(:second) - model.start_time
    proc_pct = proc_mem_pct()
    inner = geo.runtime_w - 4
    gauge_w = max(inner - 10, 8)

    panel =
      box id: "runtime-panel",
          style: %{
            border: panel_border(active),
            width: geo.runtime_w,
            padding: 1
          } do
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
            text("Mem        #{mem_total_mb()} MB"),
            text(spark_bar(model.mem_history, inner), fg: :cyan),
            row id: "mem-bar", style: %{gap: 1} do
              [
                text("Proc", style: [:dim]),
                text(bar(proc_pct, gauge_w), fg: bar_color(proc_pct)),
                text(String.pad_leading("#{proc_pct}%", 4),
                  style: [:bold],
                  fg: bar_color(proc_pct)
                )
              ]
            end
            |> animate(
              property: :fg,
              to: bar_color(proc_pct),
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

  defp scheduler_panel(model, geo) do
    active = model.panel == :schedulers
    utils = model.sched_utils
    inner = geo.sched_w - 4

    # title, two dividers, avg row, and status line frame the bars
    capacity = @top_band - 5
    rows = sched_rows(utils, inner, capacity)

    avg = if utils == [], do: 0, else: round(Enum.sum(utils) / length(utils))
    avg_bar_w = max(inner - 10, 6)

    panel =
      box id: "sched-panel",
          style: %{border: panel_border(active), width: geo.sched_w, padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("Schedulers", active),
              style: [:bold],
              fg: title_color(active)
            ),
            divider(char: "-")
            | rows ++
                [
                  divider(char: "-"),
                  row style: %{gap: 1} do
                    [
                      text("Avg ", style: [:bold]),
                      text(bar(avg, avg_bar_w), fg: bar_color(avg)),
                      text(String.pad_leading("#{avg}%", 4),
                        style: [:bold],
                        fg: bar_color(avg)
                      )
                    ]
                  end,
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

  # One row per scheduler never fits a many-core machine, so bars flow
  # into two columns when the panel is wide enough, and when even that
  # overflows the band, only the busiest schedulers are shown.
  defp sched_rows(utils, inner, capacity) do
    indexed = Enum.with_index(utils, 1)
    cols = if inner >= 31, do: 2, else: 1
    slots = capacity * cols

    {visible, hidden} =
      if length(indexed) <= slots do
        {indexed, 0}
      else
        busiest =
          indexed
          |> Enum.sort_by(fn {pct, _idx} -> -pct end)
          |> Enum.take(slots - cols)
          |> Enum.sort_by(fn {_pct, idx} -> idx end)

        {busiest, length(indexed) - length(busiest)}
      end

    # Pad the index to the widest label so bars align past #9.
    idx_w = String.length("##{length(utils)}")
    cell_w = div(inner - (cols - 1), cols)
    bar_w = max(cell_w - idx_w - 7, 6)

    rows =
      visible
      |> Enum.chunk_every(cols)
      |> Enum.map(fn cells ->
        row style: %{gap: 1} do
          Enum.map(cells, fn {pct, idx} ->
            sched_cell(idx, pct, idx_w, bar_w)
          end)
        end
      end)

    rows =
      if hidden > 0,
        do: rows ++ [text("+#{hidden} more", style: [:dim])],
        else: rows

    rows ++ List.duplicate(text(""), max(capacity - length(rows), 0))
  end

  defp sched_cell(idx, pct, idx_w, bar_w) do
    row style: %{gap: 1} do
      [
        text(String.pad_leading("##{idx}", idx_w), style: [:dim]),
        text(bar(pct, bar_w), fg: bar_color(pct)),
        text(String.pad_leading("#{pct}%", 4), fg: bar_color(pct))
      ]
    end
  end

  # -- Event Log Panel --

  defp log_panel(model, geo) do
    active = model.panel == :log
    inner = geo.log_w - 4
    capacity = log_capacity()

    suffix =
      cond do
        model.paused -> " (paused)"
        model.log_offset > 0 -> " (+#{model.log_offset})"
        true -> ""
      end

    entries =
      model.log
      |> Enum.drop(model.log_offset)
      |> Enum.take(capacity)
      |> Enum.map(fn {time, msg} ->
        row style: %{gap: 1} do
          [
            text(time, style: [:dim]),
            text(String.slice(msg, 0, max(inner - 9, 8)))
          ]
        end
      end)

    entries =
      entries ++ List.duplicate(text(""), max(capacity - length(entries), 0))

    panel =
      box id: "log-panel",
          style: %{border: panel_border(active), width: geo.log_w, padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("Event Log#{suffix}", active),
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

  defp process_table(model, geo) do
    active = model.panel == :processes
    procs = top_processes(model.proc_offset, geo.proc_rows)
    name_w = clamp(model.width - 50, 28, 60)

    suffix = if model.proc_offset > 0, do: " (+#{model.proc_offset})", else: ""

    header =
      row style: %{gap: 1} do
        [
          text(String.pad_trailing("PID", 16), style: [:bold], fg: :yellow),
          text(String.pad_trailing("Name", name_w),
            style: [:bold],
            fg: :yellow
          ),
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
        name = p.name |> String.slice(0, name_w) |> String.pad_trailing(name_w)

        row style: %{gap: 1} do
          [
            text(String.pad_trailing(p.pid, 16), style: [:dim]),
            text(name, fg: name_color(p.name)),
            text(String.pad_leading(fmt_num(p.reds), 12)),
            text(String.pad_leading(fmt_bytes(p.mem), 10))
          ]
        end
      end)

    # flex: 1 makes this band absorb all remaining height, which pins
    # the key bar to the bottom row of any terminal.
    panel =
      box id: "proc-panel",
          style: %{flex: 1, border: panel_border(active), padding: 1} do
        column style: %{gap: 0} do
          [
            text(panel_title("Top Processes#{suffix}", active),
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
        text(" #{panel_label(model.panel)}", style: [:bold], fg: :cyan),
        text("Tab/h/l", style: [:bold], fg: :magenta),
        text("panel", style: [:dim]),
        text("j/k", style: [:bold], fg: :magenta),
        text(scroll_hint(model.panel), style: [:dim]),
        text("Space", style: [:bold], fg: :magenta),
        text(pause_label, style: [:dim]),
        text("q", style: [:bold], fg: :magenta),
        text("quit", style: [:dim])
      ]
    end
  end

  defp panel_label(:runtime), do: "[BEAM Runtime]"
  defp panel_label(:schedulers), do: "[Schedulers]"
  defp panel_label(:log), do: "[Event Log]"
  defp panel_label(:processes), do: "[Top Processes]"

  defp scroll_hint(:log), do: "scroll log"
  defp scroll_hint(:processes), do: "scroll table"
  defp scroll_hint(_), do: "scroll (log/procs)"

  # -- Data Helpers --

  defp top_processes(offset, count) do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :reductions, :memory]) do
        nil ->
          []

        info ->
          [
            %{
              pid: pid,
              registered: info[:registered_name],
              reds: info[:reductions],
              mem: info[:memory]
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.reds, :desc)
    |> Enum.drop(offset)
    |> Enum.take(count)
    |> Enum.map(fn p ->
      %{
        pid: inspect(p.pid),
        name: proc_name(p.pid, p.registered),
        reds: p.reds,
        mem: p.mem
      }
    end)
  end

  # Unnamed processes used to repeat the pid in the name column; the
  # initial call (via proc_lib, so supervisors and GenServers resolve to
  # the module behind them) is what you actually want to see.
  defp proc_name(_pid, name) when is_atom(name), do: inspect(name)

  defp proc_name(pid, _unregistered) do
    case :proc_lib.translate_initial_call(pid) do
      {m, f, a} -> Exception.format_mfa(m, f, a)
      _ -> inspect(pid)
    end
  catch
    _, _ -> inspect(pid)
  end

  defp mem_total_mb, do: Float.round(:erlang.memory(:total) / 1_048_576, 1)

  defp proc_mem_pct do
    m = :erlang.memory()
    round(m[:processes] / m[:total] * 100)
  end

  # A real sampled stat per tick; the Event Log shows the same VM the
  # other panels do, not canned strings.
  defp sampled_entry(tick, utils) do
    case rem(tick, 6) do
      0 ->
        "Memory total: #{mem_total_mb()} MB"

      1 ->
        "Processes: #{:erlang.system_info(:process_count)}"

      2 ->
        {gcs, _reclaimed, _} = :erlang.statistics(:garbage_collection)
        "GC runs: #{fmt_num(gcs)}"

      3 ->
        {_total, since_last} = :erlang.statistics(:reductions)
        "Reductions: +#{fmt_num(since_last)}"

      4 ->
        avg =
          if utils == [], do: 0, else: round(Enum.sum(utils) / length(utils))

        "Scheduler avg: #{avg}%"

      5 ->
        {{:input, i}, {:output, o}} = :erlang.statistics(:io)
        "IO: #{fmt_bytes(i)} in / #{fmt_bytes(o)} out"
    end
  end

  # -- Rendering Helpers --

  # Sparkline: maps each value to a Unicode block character (▁▂▃▄▅▆▇█),
  # normalized min..max over the visible window so a flat series renders
  # flat instead of as a solid slab.
  defp spark_bar([], _width), do: ""

  defp spark_bar(values, width) do
    shown = Enum.take(values, -max(width, 1))
    {mn, mx} = Enum.min_max(shown)
    span = if mx > mn, do: mx - mn, else: 1

    shown
    |> Enum.map(fn v ->
      Enum.at(@spark, min(round((v - mn) / span * 7), 7))
    end)
    |> Enum.join()
  end

  # Bar chart: filled (█) and empty (░) segments from a percentage.
  defp bar(pct, width) do
    filled = round(clamp(pct, 0, 100) / 100 * width)
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
end

Raxol.Core.Runtime.Log.info("RaxolDemo: Starting...")
{:ok, pid} = Raxol.start_link(RaxolDemo, [])
Raxol.Core.Runtime.Log.info("RaxolDemo: Running. Press 'q' to quit.")

ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
