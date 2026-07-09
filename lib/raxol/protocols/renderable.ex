defprotocol Raxol.Protocols.Renderable do
  @moduledoc """
  Protocol for rendering data structures to terminal output.

  This protocol provides a unified interface for rendering different types
  of data to the terminal. Any data structure that needs to be displayed
  in the terminal can implement this protocol.

  ## Examples

      defimpl Raxol.Protocols.Renderable, for: MyStruct do
        def render(data, opts) do
          # Return rendered string
        end

        def render_metadata(data) do
          %{width: 80, height: 24, colors: true}
        end
      end
  """

  @doc """
  Renders the data structure to terminal output.

  ## Options

    * `:width` - Maximum width for rendering (default: 80)
    * `:height` - Maximum height for rendering (default: 24)
    * `:colors` - Whether to include color codes (default: true)
    * `:style` - Style map to apply during rendering
    * `:theme` - Theme to use for rendering

  ## Returns

  A binary string containing the rendered output with ANSI codes.
  """
  @spec render(t, keyword()) :: binary()
  def render(data, opts)

  @doc """
  Gets rendering metadata for the data structure.

  This helps the renderer understand the requirements and capabilities
  of the data being rendered.

  ## Returns

  A map containing:
    * `:width` - Preferred or required width
    * `:height` - Preferred or required height
    * `:colors` - Whether colors are used
    * `:scrollable` - Whether content is scrollable
    * `:interactive` - Whether content is interactive
  """
  @spec render_metadata(t) :: map()
  def render_metadata(data)
end

# Default implementations for built-in types
defimpl Raxol.Protocols.Renderable, for: BitString do
  def render(string, _opts) do
    string
  end

  def render_metadata(string) do
    lines = String.split(string, "\n")

    %{
      width: lines |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end),
      height: length(lines),
      colors: false,
      scrollable: false,
      interactive: false
    }
  end
end

defimpl Raxol.Protocols.Renderable, for: List do
  def render(list, opts) do
    Enum.map_join(list, "\n", &Raxol.Protocols.Renderable.render(&1, opts))
  end

  def render_metadata(list) do
    %{
      width: 80,
      height: length(list),
      colors: false,
      scrollable: true,
      interactive: false
    }
  end
end

defimpl Raxol.Protocols.Renderable, for: Map do
  def render(map, _opts) do
    max_key_length =
      map
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 0 end)

    map
    |> Enum.map_join("\n", fn {k, v} ->
      key = k |> to_string() |> String.pad_trailing(max_key_length)

      value =
        case v do
          v when is_binary(v) -> v
          v -> inspect(v)
        end

      "#{key}: #{value}"
    end)
  end

  def render_metadata(map) do
    %{
      width: 80,
      height: map_size(map),
      colors: false,
      scrollable: true,
      interactive: false
    }
  end
end

defimpl Raxol.Protocols.Renderable, for: Atom do
  def render(atom, _opts) do
    to_string(atom)
  end

  def render_metadata(atom) do
    %{
      width: atom |> to_string() |> String.length(),
      height: 1,
      colors: false,
      scrollable: false,
      interactive: false
    }
  end
end

defimpl Raxol.Protocols.Renderable, for: Integer do
  def render(integer, _opts) do
    to_string(integer)
  end

  def render_metadata(integer) do
    %{
      width: integer |> to_string() |> String.length(),
      height: 1,
      colors: false,
      scrollable: false,
      interactive: false
    }
  end
end

defimpl Raxol.Protocols.Renderable, for: Float do
  def render(float, _opts) do
    to_string(float)
  end

  def render_metadata(float) do
    %{
      width: float |> to_string() |> String.length(),
      height: 1,
      colors: false,
      scrollable: false,
      interactive: false
    }
  end
end
