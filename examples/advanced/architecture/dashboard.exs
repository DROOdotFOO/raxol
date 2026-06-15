# Dashboard Layout
#
# Demonstrates a multi-panel dashboard layout with header, sidebar, and content.
#
# Usage:
#   mix run examples/advanced/architecture/dashboard.exs

defmodule DashboardExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{selected: :overview, tick: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        {%{model | tick: model.tick + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "1"}} ->
        {%{model | selected: :overview}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "2"}} ->
        {%{model | selected: :stats}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "3"}} ->
        {%{model | selected: :logs}, []}

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
    column do
      [
        box title: "Dashboard", style: %{padding: 0} do
          text(" [1] Overview  [2] Stats  [3] Logs  [q] Quit")
        end,
        row do
          [
            box title: "Nav",
                style: %{border: :single, width: 15, padding: 1} do
              column style: %{gap: 1} do
                [
                  text(indicator(:overview, model) <> "Overview"),
                  text(indicator(:stats, model) <> "Stats"),
                  text(indicator(:logs, model) <> "Logs")
                ]
              end
            end,
            box title: panel_title(model.selected),
                style: %{border: :single, padding: 1} do
              case model.selected do
                :overview ->
                  column style: %{gap: 1} do
                    [
                      text("System is running normally."),
                      text("Uptime ticks: #{model.tick}"),
                      text("Processes: #{length(Process.list())}")
                    ]
                  end

                :stats ->
                  mem = :erlang.memory(:total)

                  column style: %{gap: 1} do
                    [
                      text("Memory: #{div(mem, 1_048_576)} MB"),
                      text(
                        "Schedulers: #{:erlang.system_info(:schedulers_online)}"
                      ),
                      text("Tick: #{model.tick}")
                    ]
                  end

                :logs ->
                  column do
                    [
                      text("[#{model.tick}] Dashboard refreshed"),
                      text("[#{max(0, model.tick - 1)}] User navigated"),
                      text("[0] Dashboard started")
                    ]
                  end
              end
            end
          ]
        end
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end

  defp indicator(tab, %{selected: selected}) do
    if tab == selected, do: "> ", else: "  "
  end

  defp panel_title(:overview), do: "Overview"
  defp panel_title(:stats), do: "Statistics"
  defp panel_title(:logs), do: "Recent Logs"
end

Raxol.Core.Runtime.Log.info("DashboardExample: Starting...")
{:ok, pid} = Raxol.start_link(DashboardExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
