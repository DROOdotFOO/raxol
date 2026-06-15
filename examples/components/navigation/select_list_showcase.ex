defmodule Raxol.Examples.SelectListShowcase do
  @moduledoc """
  Showcase for a select list with keyboard navigation.

  Demonstrates single selection from a list with arrow keys.
  """

  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @fruits [
    "Apple",
    "Banana",
    "Cherry",
    "Date",
    "Elderberry",
    "Fig",
    "Grape",
    "Honeydew",
    "Imbe",
    "Jackfruit",
    "Kiwi",
    "Lemon",
    "Mango",
    "Nectarine",
    "Orange"
  ]

  @impl true
  def init(_context) do
    %{cursor: 0, selected: nil, scroll: 0, visible: 8}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        new_cursor = min(model.cursor + 1, length(@fruits) - 1)
        scroll = adjust_scroll(new_cursor, model.scroll, model.visible)
        {%{model | cursor: new_cursor, scroll: scroll}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        new_cursor = max(model.cursor - 1, 0)
        scroll = adjust_scroll(new_cursor, model.scroll, model.visible)
        {%{model | cursor: new_cursor, scroll: scroll}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}} ->
        {%{model | selected: Enum.at(@fruits, model.cursor)}, []}

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
    visible_items =
      @fruits
      |> Enum.with_index()
      |> Enum.slice(model.scroll, model.visible)

    column style: %{padding: 1, gap: 1} do
      [
        text("Select List Showcase", style: [:bold]),
        box title: "Pick a fruit (Up/Down + Enter)",
            style: %{border: :single, padding: 1} do
          column do
            Enum.map(visible_items, fn {fruit, idx} ->
              prefix = if idx == model.cursor, do: "> ", else: "  "
              style = if idx == model.cursor, do: [:bold], else: []
              text(prefix <> fruit, style: style)
            end)
          end
        end,
        text("Selected: #{model.selected || "none"}"),
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp adjust_scroll(cursor, scroll, visible) do
    cond do
      cursor < scroll -> cursor
      cursor >= scroll + visible -> cursor - visible + 1
      true -> scroll
    end
  end
end
