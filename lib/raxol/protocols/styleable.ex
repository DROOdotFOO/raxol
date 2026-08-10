defprotocol Raxol.Protocols.Styleable do
  @moduledoc """
  Protocol for applying styles to data structures.

  This protocol provides a unified interface for applying visual styles
  (colors, formatting, effects) to different types of data in the terminal.

  ## Style Attributes

  Styles are represented as maps with the following optional keys:
    * `:foreground` - Foreground color (RGB tuple or color name)
    * `:background` - Background color (RGB tuple or color name)
    * `:bold` - Bold text (boolean)
    * `:italic` - Italic text (boolean)
    * `:underline` - Underlined text (boolean)
    * `:blink` - Blinking text (boolean)
    * `:reverse` - Reverse video (boolean)
    * `:hidden` - Hidden/invisible text (boolean)
    * `:strikethrough` - Strikethrough text (boolean)

  ## Examples

      defimpl Raxol.Protocols.Styleable, for: MyComponent do
        def apply_style(component, style) do
          %{component | style: merge_styles(component.style, style)}
        end

        def get_style(component) do
          component.style || %{}
        end

        def merge_styles(component, new_style) do
          %{component | style: Map.merge(get_style(component), new_style)}
        end

        def reset_style(component) do
          %{component | style: %{}}
        end
      end
  """

  # Style can contain standard attributes plus implementation-specific keys
  @type style :: map()

  @doc """
  Applies a style to the data structure.

  ## Parameters
    * `data` - The data structure to style
    * `style` - The style map to apply

  ## Returns
  The data structure with the style applied.
  """
  @spec apply_style(t, style()) :: t
  def apply_style(data, style)

  @doc """
  Gets the current style of the data structure.

  ## Returns
  The current style map, or an empty map if no style is set.
  """
  @spec get_style(t) :: style()
  def get_style(data)

  @doc """
  Merges new styles with existing styles.

  New styles override existing ones for the same keys.

  ## Parameters
    * `data` - The data structure with existing styles
    * `new_style` - The new style map to merge

  ## Returns
  The data structure with merged styles.
  """
  @spec merge_styles(t, style()) :: t
  def merge_styles(data, new_style)

  @doc """
  Resets all styles to default.

  ## Returns
  The data structure with all styles removed.
  """
  @spec reset_style(t) :: t
  def reset_style(data)

  @doc """
  Converts the style to ANSI escape codes.

  ## Returns
  A string containing the ANSI escape codes for the style.
  """
  @spec to_ansi(t) :: binary()
  def to_ansi(data)
end

# The Color implementation lives in `Raxol.Protocols.ThemeImplementations`,
# alongside the other theme-facing ones. It used to be duplicated here, which
# left the winner up to compile order and made the two disagree: this copy
# reported only `:foreground` from `get_style/1` and left `:hex`/`:name` stale
# after `reset_style/1`.

# Implementation for Maps (generic style containers)
defimpl Raxol.Protocols.Styleable, for: Map do
  def apply_style(map, style) do
    merge_styles(map, style)
  end

  def get_style(map) do
    Map.get(map, :style, %{})
  end

  def merge_styles(map, new_style) do
    current_style = get_style(map)
    Map.put(map, :style, Map.merge(current_style, new_style))
  end

  def reset_style(map) do
    Map.delete(map, :style)
  end

  def to_ansi(map) do
    style = get_style(map)
    build_ansi_codes(style)
  end

  @spec build_ansi_codes(map()) :: binary()
  defp build_ansi_codes(style) do
    codes =
      []
      |> maybe_add_attr(style[:bold], "1")
      |> maybe_add_attr(style[:italic], "3")
      |> maybe_add_attr(style[:underline], "4")
      |> maybe_add_attr(style[:blink], "5")
      |> maybe_add_attr(style[:reverse], "7")
      |> maybe_add_attr(style[:hidden], "8")
      |> maybe_add_attr(style[:strikethrough], "9")
      |> add_color_code(style[:foreground], 30)
      |> add_color_code(style[:background], 40)

    case codes do
      [] -> ""
      codes -> "\e[#{Enum.join(codes, ";")}m"
    end
  end

  defp maybe_add_attr(codes, true, code), do: [code | codes]
  defp maybe_add_attr(codes, _, _code), do: codes

  defp add_color_code(codes, {r, g, b}, base) do
    prefix = if base == 30, do: "38;2", else: "48;2"
    ["#{prefix};#{r};#{g};#{b}" | codes]
  end

  defp add_color_code(codes, name, base) when is_atom(name) do
    case color_name_offset(name) do
      nil -> codes
      offset -> ["#{base + offset}" | codes]
    end
  end

  defp add_color_code(codes, _, _base), do: codes

  defp color_name_offset(:black), do: 0
  defp color_name_offset(:red), do: 1
  defp color_name_offset(:green), do: 2
  defp color_name_offset(:yellow), do: 3
  defp color_name_offset(:blue), do: 4
  defp color_name_offset(:magenta), do: 5
  defp color_name_offset(:cyan), do: 6
  defp color_name_offset(:white), do: 7
  defp color_name_offset(_), do: nil
end
