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
    width =
      min(
        Raxol.UI.TextMeasure.display_width(text_input_display(attrs_map)) +
          @input_padding,
        available_space.width
      )

    %{width: width, height: @input_height}
  end

  @doc """
  The text a text input shows: its placeholder when the value is empty, its
  value otherwise, and for an input with a `:mask_char` one mask character
  per grapheme of the value (a non-string mask draws `*`), so no surface drawn
  from the layout shows a masked value.
  """
  @spec text_input_display(map()) :: String.t()
  def text_input_display(attrs_map) do
    # An unset value or placeholder may arrive as nil.
    value = Map.get(attrs_map, :value) || ""

    cond do
      value == "" -> Map.get(attrs_map, :placeholder) || ""
      is_nil(Map.get(attrs_map, :mask_char)) -> value
      true -> String.duplicate(mask(attrs_map.mask_char), String.length(value))
    end
  end

  defp mask(mask_char) when is_binary(mask_char), do: mask_char
  defp mask(_other), do: "*"
end
