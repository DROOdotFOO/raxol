defmodule Raxol.Playground.Demos.FocusRingDemo do
  @moduledoc "Playground demo: accessibility focus ring indicators."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  alias Raxol.UI.Components.FocusRing

  @items ["Save File", "Open Project", "Run Tests", "Deploy", "Settings"]
  @styles [:solid, :double, :rounded, :dots]

  @impl true
  def init(_context) do
    %{
      focused: 0,
      style: :solid,
      ring_config: FocusRing.init(style: :solid, color: :cyan)
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("k") ->
        new_focused = DemoHelpers.cursor_up(model.focused)
        {%{model | focused: new_focused}, []}

      key_match(:up) ->
        new_focused = DemoHelpers.cursor_up(model.focused)
        {%{model | focused: new_focused}, []}

      key_match("j") ->
        new_focused = DemoHelpers.cursor_down(model.focused, length(@items) - 1)
        {%{model | focused: new_focused}, []}

      key_match(:down) ->
        new_focused = DemoHelpers.cursor_down(model.focused, length(@items) - 1)
        {%{model | focused: new_focused}, []}

      key_match("s") ->
        {cycle_style(model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    style_label = model.style |> to_string() |> String.upcase()

    column style: %{gap: 1} do
      [
        text("Focus Ring Demo", style: [:bold]),
        text("Style: #{style_label}", fg: :cyan),
        text(""),
        render_items(model),
        text(""),
        text("[j/k/arrows] navigate  [s] cycle style", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp render_items(model) do
    # snippet:start
    items =
      @items
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        if idx == model.focused do
          rendered = FocusRing.render(label, model.ring_config)
          text(rendered, fg: :cyan)
        else
          text("  #{label}  ", style: [:dim])
        end
      end)

    # snippet:end

    column style: %{gap: 0} do
      items
    end
  end

  defp cycle_style(model) do
    current_idx = Enum.find_index(@styles, &(&1 == model.style))
    next_idx = DemoHelpers.cycle_next(current_idx, length(@styles))
    new_style = Enum.at(@styles, next_idx)
    new_config = FocusRing.set_style(model.ring_config, new_style)
    %{model | style: new_style, ring_config: new_config}
  end
end
