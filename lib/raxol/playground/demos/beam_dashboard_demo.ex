defmodule Raxol.Playground.Demos.BeamDashboardDemo do
  @moduledoc """
  Playground demo: live dashboard of the BEAM VM rendering it.

  Scheduler utilization, memory trend, and a sampled event feed, all
  read from the running VM each second. Sized for the 80x24 demo
  viewport, so it also serves as the raxol.io landing hero.
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @tick_interval_ms 1000
  @mem_history_size 36
  @max_events 5
  @sched_slots 8
  @bar_fill "█"
  @bar_empty "░"

  @impl true
  def init(_context) do
    # Track scheduler wall time so busy/total deltas between samples
    # give per-scheduler utilization. Idempotent across demo instances.
    :erlang.system_flag(:scheduler_wall_time, true)

    %{
      tick: 0,
      paused: false,
      start_time: System.monotonic_time(:second),
      sched_prev: :erlang.statistics(:scheduler_wall_time) |> Enum.sort(),
      sched_utils: [],
      mem_history: [],
      events: [{ts(), "Dashboard attached to this VM"}]
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick when model.paused ->
        {model, []}

      :tick ->
        curr = :erlang.statistics(:scheduler_wall_time) |> Enum.sort()

        utils =
          Enum.zip(model.sched_prev, curr)
          |> Enum.map(fn {{_id, a1, t1}, {_id2, a2, t2}} ->
            dt = t2 - t1
            if dt > 0, do: round((a2 - a1) / dt * 100), else: 0
          end)

        history =
          (model.mem_history ++ [mem_total_mb()])
          |> Enum.take(-@mem_history_size)

        events =
          [{ts(), sampled_event(model.tick, utils)} | model.events]
          |> Enum.take(@max_events)

        {%{
           model
           | tick: model.tick + 1,
             sched_prev: curr,
             sched_utils: utils,
             mem_history: history,
             events: events
         }, []}

      key_match(" ") ->
        {%{model | paused: !model.paused}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    uptime = System.monotonic_time(:second) - model.start_time

    status =
      if model.paused,
        do: text("paused", style: [:bold], fg: :yellow),
        else: text("live · up #{fmt_uptime(uptime)}", fg: :cyan)

    column style: %{padding: 1, gap: 0} do
      [
        row style: %{gap: 1, justify_content: :space_between} do
          [
            text("BEAM VM Dashboard", style: [:bold], fg: :cyan),
            status
          ]
        end,
        divider(char: "-"),
        row style: %{gap: 2} do
          [
            scheduler_column(model),
            runtime_column(model)
          ]
        end,
        divider(char: "-")
        | event_rows(model.events) ++
            [
              divider(char: "-"),
              row style: %{gap: 2} do
                [
                  text("[space] pause", style: [:bold], fg: :magenta),
                  text("live data from this page's BEAM VM", style: [:dim])
                ]
              end
            ]
      ]
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_interval_ms, :tick)]

  # -- Schedulers (left column) --

  defp scheduler_column(model) do
    utils = model.sched_utils
    avg = if utils == [], do: 0, else: round(Enum.sum(utils) / length(utils))

    column style: %{width: 38, gap: 0} do
      [
        text("Schedulers", style: [:dim])
        | sched_rows(utils) ++
            [
              row style: %{gap: 1} do
                [
                  text("Avg", style: [:bold]),
                  text(bar(avg, 24), fg: bar_color(avg)),
                  text(String.pad_leading("#{avg}%", 4),
                    style: [:bold],
                    fg: bar_color(avg)
                  )
                ]
              end
            ]
      ]
    end
  end

  # One bar per scheduler, the busiest first when there are more
  # schedulers than rows; indexes pad so bars align past #9.
  defp sched_rows(utils) do
    indexed = Enum.with_index(utils, 1)

    {visible, hidden} =
      if length(indexed) <= @sched_slots do
        {indexed, 0}
      else
        busiest =
          indexed
          |> Enum.sort_by(fn {pct, _idx} -> -pct end)
          |> Enum.take(@sched_slots - 1)
          |> Enum.sort_by(fn {_pct, idx} -> idx end)

        {busiest, length(indexed) - length(busiest)}
      end

    idx_w = String.length("##{length(utils)}")

    rows =
      Enum.map(visible, fn {pct, idx} ->
        row style: %{gap: 1} do
          [
            text(String.pad_leading("##{idx}", idx_w), style: [:dim]),
            text(bar(pct, 24), fg: bar_color(pct)),
            text(String.pad_leading("#{pct}%", 4), fg: bar_color(pct))
          ]
        end
      end)

    rows =
      if hidden > 0,
        do: rows ++ [text("+#{hidden} more", style: [:dim])],
        else: rows

    rows ++ List.duplicate(text(""), max(@sched_slots - length(rows), 0))
  end

  # -- Runtime facts (right column) --

  defp runtime_column(model) do
    proc_pct = proc_mem_pct()

    column style: %{width: 38, gap: 0} do
      [
        text("Runtime", style: [:dim]),
        text(
          "Elixir #{System.version()} / OTP #{:erlang.system_info(:otp_release)}"
        ),
        text(
          "Processes  #{String.pad_trailing("#{:erlang.system_info(:process_count)}", 7)}" <>
            "Ports  #{length(:erlang.ports())}"
        ),
        text(
          "Atoms      #{String.pad_trailing(fmt_num(:erlang.system_info(:atom_count)), 7)}" <>
            "ETS    #{length(:ets.all())}"
        ),
        text("Memory     #{mem_total_mb()} MB"),
        sparkline(
          data: spark_data(model.mem_history),
          width: effective_width(model, 36),
          height: 4,
          color: :cyan
        ),
        row style: %{gap: 1} do
          [
            text("Proc", style: [:dim]),
            text(bar(proc_pct, 24), fg: bar_color(proc_pct)),
            text(String.pad_leading("#{proc_pct}%", 4),
              style: [:bold],
              fg: bar_color(proc_pct)
            )
          ]
        end
      ]
    end
  end

  # -- Event feed --

  defp event_rows(events) do
    rows =
      Enum.map(events, fn {time, msg} ->
        row style: %{gap: 1} do
          [text(time, style: [:dim]), text(msg)]
        end
      end)

    rows ++ List.duplicate(text(""), max(@max_events - length(rows), 0))
  end

  # A real sampled stat per tick, so the feed shows the same VM the
  # bars do.
  defp sampled_event(tick, utils) do
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

  # -- Sampling helpers --

  defp mem_total_mb, do: Float.round(:erlang.memory(:total) / 1_048_576, 1)

  defp proc_mem_pct do
    m = :erlang.memory()
    round(m[:processes] / m[:total] * 100)
  end

  # The sparkline Component normalizes over its input, so a flat memory
  # series would fill the whole height; anchor the window to its own
  # min so the trend reads flat instead.
  defp spark_data([]), do: [0]

  defp spark_data(history) do
    mn = Enum.min(history)
    Enum.map(history, fn v -> round((v - mn) * 10) end)
  end

  # -- Formatting --

  defp bar(pct, width) do
    filled = round(min(max(pct, 0), 100) / 100 * width)

    String.duplicate(@bar_fill, filled) <>
      String.duplicate(@bar_empty, width - filled)
  end

  defp bar_color(pct) when pct >= 80, do: :red
  defp bar_color(pct) when pct >= 60, do: :yellow
  defp bar_color(_pct), do: :green

  defp ts, do: Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")

  defp fmt_uptime(s) do
    m = div(s, 60)
    if m > 0, do: "#{m}m #{rem(s, 60)}s", else: "#{s}s"
  end

  defp fmt_num(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp fmt_num(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp fmt_num(n), do: "#{n}"

  defp fmt_bytes(b) when b >= 1_048_576,
    do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp fmt_bytes(b) when b >= 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp fmt_bytes(b), do: "#{b} B"
end
