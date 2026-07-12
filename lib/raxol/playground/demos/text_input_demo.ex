defmodule Raxol.Playground.Demos.TextInputDemo do
  @moduledoc "Playground demo: single-line text input with character counting."
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @default_input_box_width 40

  @impl true
  def init(_context) do
    %{value: "", char_count: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:backspace) ->
        new_value = String.slice(model.value, 0..-2//1)
        {%{model | value: new_value, char_count: String.length(new_value)}, []}

      key_match(:char, char: ch)
      when byte_size(ch) == 1 ->
        new_value = model.value <> ch
        {%{model | value: new_value, char_count: String.length(new_value)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    display =
      if model.value == "", do: "(type to enter text)", else: model.value

    column style: %{gap: 1} do
      [
        text("TextInput Demo", style: [:bold]),
        divider(),
        text("Input:"),
        box style: %{
              border: :single,
              padding: {0, 1, 0, 1},
              width: effective_width(model, @default_input_box_width)
            } do
          text(display <> "_")
        end,
        text_input(value: model.value, placeholder: "Type here..."),
        divider(),
        box style: %{
              border: :rounded,
              padding: {0, 1, 0, 1},
              width: effective_width(model, @default_input_box_width)
            } do
          column style: %{gap: 0} do
            [
              text("Value: \"#{model.value}\""),
              text("Length: #{model.char_count} chars")
            ]
          end
        end,
        text("[type] to enter text  [backspace] to delete", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
