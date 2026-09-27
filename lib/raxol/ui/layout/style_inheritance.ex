defmodule Raxol.UI.Layout.StyleInheritance do
  @moduledoc """
  Shared style inheritance logic for layout containers.

  Text styling properties cascade from parent to child elements.
  Layout properties (padding, border, width, height, gap) do NOT inherit.
  """

  @inheritable_keys [
    :fg,
    :bg,
    :foreground,
    :background,
    :fg_color,
    :bg_color,
    :bold,
    :italic,
    :underline,
    :strikethrough,
    :reverse,
    :dim
  ]

  @doc """
  Propagates inheritable style properties from a parent element
  into each child's style map. Child values take precedence.
  """
  @spec inherit_styles(map(), [map()]) :: [map()]
  def inherit_styles(parent, children) do
    parent_style = ensure_style_map(Map.get(parent, :style, %{}))
    inheritable = Map.take(parent_style, @inheritable_keys)

    if map_size(inheritable) == 0 do
      children
    else
      Enum.map(children, fn child ->
        child_style = ensure_style_map(Map.get(child, :style, %{}))
        merged = Map.merge(inheritable, child_style)
        Map.put(child, :style, merged)
      end)
    end
  end

  @doc """
  Converts style values to a map. Handles maps, keyword-like lists, and atoms.

  List entries that are neither `{key, value}` pairs nor atoms are skipped,
  so one malformed entry cannot fail the layout of the whole frame.
  """
  @spec ensure_style_map(term()) :: map()
  def ensure_style_map(style) when is_map(style), do: style

  def ensure_style_map(style) when is_list(style) do
    Enum.reduce(style, %{}, fn
      {k, v}, acc -> Map.put(acc, k, v)
      atom, acc when is_atom(atom) -> Map.put(acc, atom, true)
      _other, acc -> acc
    end)
  end

  def ensure_style_map(_), do: %{}
end
