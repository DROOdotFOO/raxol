# Architecture Showcase
#
# Demonstrates the Raxol architecture: TEA pattern, components, theming, layout.
#
# Usage:
#   mix run examples/advanced/architecture/architecture_demo.exs

defmodule ArchitectureDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @tabs [:components, :layout, :theming, :info]

  @impl true
  def init(_context) do
    %{
      active_tab: :components,
      counter: 0,
      input_value: "",
      checkbox: false
    }
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "1"}} ->
        {%{model | active_tab: :components}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "2"}} ->
        {%{model | active_tab: :layout}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "3"}} ->
        {%{model | active_tab: :theming}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "4"}} ->
        {%{model | active_tab: :info}, []}

      :increment ->
        {%{model | counter: model.counter + 1}, []}

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
    column style: %{padding: 1, gap: 1} do
      [
        text("Architecture Showcase", style: [:bold]),
        text("[1] Components  [2] Layout  [3] Theming  [4] Info  [q] Quit"),
        case model.active_tab do
          :components -> render_components(model)
          :layout -> render_layout()
          :theming -> render_theming()
          :info -> render_info()
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp render_components(model) do
    box title: "Components", style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        [
          text("Counter: #{model.counter}"),
          button("Increment", on_click: :increment),
          text("Text input and buttons are native TEA components."),
          text("Checkbox: #{if model.checkbox, do: "[x]", else: "[ ]"}")
        ]
      end
    end
  end

  defp render_layout do
    box title: "Layout", style: %{border: :single, padding: 1} do
      row style: %{gap: 2} do
        [
          box title: "Left", style: %{border: :single, padding: 1} do
            text("Left pane")
          end,
          box title: "Right", style: %{border: :single, padding: 1} do
            text("Right pane")
          end
        ]
      end
    end
  end

  defp render_theming do
    box title: "Theming", style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        [
          text("Themes are configured via TOML."),
          text("Colors, borders, and spacing are themeable."),
          text("See config/raxol.example.toml for options.")
        ]
      end
    end
  end

  defp render_info do
    box title: "Architecture Info", style: %{border: :single, padding: 1} do
      column style: %{gap: 1} do
        [
          text("Raxol uses The Elm Architecture (TEA):"),
          text("  init/1   -> initial model"),
          text("  update/2 -> handle messages"),
          text("  view/1   -> render UI"),
          text("  subscribe/1 -> time subscriptions"),
          text(""),
          text("Built on OTP: GenServers, Supervisors, ETS.")
        ]
      end
    end
  end
end

Raxol.Core.Runtime.Log.info("ArchitectureDemo: Starting...")
{:ok, pid} = Raxol.start_link(ArchitectureDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
