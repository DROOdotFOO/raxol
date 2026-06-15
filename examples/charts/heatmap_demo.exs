defmodule HeatmapDemo do
  @moduledoc """
  Scheduler utilization per core over time as a scrolling heatmap. 1s tick.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Charts.{Heatmap, ViewBridge}

  @history_len 40

  @impl true
  def init(_context) do
    :erlang.system_flag(:scheduler_wall_time, true)
    num_schedulers = :erlang.system_info(:schedulers)

    %{
      tick: 0,
      sched_prev: :erlang.statistics(:scheduler_wall_time) |> Enum.sort(),
      history: List.duplicate(List.duplicate(0, num_schedulers), 1),
      num_schedulers: num_schedulers
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        curr = :erlang.statistics(:scheduler_wall_time) |> Enum.sort()

        utils =
          Enum.zip(model.sched_prev, curr)
          |> Enum.map(fn {{_id, a1, t1}, {_id2, a2, t2}} ->
            delta = t2 - t1
            if delta > 0, do: round((a2 - a1) / delta * 100), else: 0
          end)

        history = [utils | model.history] |> Enum.take(@history_len)

        {%{model | tick: model.tick + 1, sched_prev: curr, history: history},
         []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # Transpose: rows = schedulers, columns = time
    history = Enum.reverse(model.history)

    transposed =
      for s <- 0..(model.num_schedulers - 1) do
        Enum.map(history, fn snapshot ->
          Enum.at(snapshot, s, 0)
        end)
      end

    cells =
      Heatmap.render({1, 3, 78, model.num_schedulers * 2}, transposed,
        color_scale: :warm,
        min: 0,
        max: 100
      )

    column style: %{padding: 1} do
      [
        text("Scheduler Heatmap (per core over time)",
          style: [:bold],
          fg: :cyan
        ),
        text(
          "#{model.num_schedulers} schedulers | #{length(model.history)} samples",
          style: [:dim]
        ),
        ViewBridge.cells_to_view(cells),
        row style: %{gap: 2} do
          [
            text("Low", fg: :green),
            text("Med", fg: :yellow),
            text("High", fg: :red),
            text("| Press q to quit", style: [:dim])
          ]
        end
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end
end

Raxol.start_link(HeatmapDemo)
