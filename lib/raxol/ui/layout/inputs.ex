defmodule Raxol.UI.Layout.Inputs do
  @moduledoc """
  Handles measurement of input elements like buttons and text inputs.
  """

  @button_padding 4
  @button_height 3
  @input_padding 4
  @input_height 3

  def measure(:button, attrs_map, available_space) do
    text = Map.get(attrs_map, :label, "Button")

    width =
      min(
        Raxol.UI.TextMeasure.display_width(text) + @button_padding,
        available_space.width
      )

    %{width: width, height: @button_height}
  end

  def measure(:text_input, attrs_map, available_space) do
    # An unset value or placeholder may arrive as nil.
    value = Map.get(attrs_map, :value) || ""
    placeholder = Map.get(attrs_map, :placeholder) || ""

    display_text =
      case value == "" do
        true -> placeholder
        false -> value
      end

    width =
      min(
        Raxol.UI.TextMeasure.display_width(display_text) + @input_padding,
        available_space.width
      )

    %{width: width, height: @input_height}
  end
end
