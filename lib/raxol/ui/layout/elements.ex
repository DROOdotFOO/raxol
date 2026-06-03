defmodule Raxol.UI.Layout.Elements do
  @moduledoc """
  Handles measurement of basic UI elements like text, labels, boxes, and checkboxes.

  Optionally accepts a `prepared_cache` (built by the Preparer phase) to skip
  re-measuring text whose display width was computed during prepare. The cache
  is owned by `Raxol.UI.Layout.Engine.apply_layout/3` and passed through
  explicitly so the data flow is visible.
  """

  alias Raxol.UI.Layout.Engine, as: LayoutEngine

  @default_height 1
  @default_box_size 1
  # "[x] " prefix before label text
  @checkbox_prefix_width 4

  def measure(type, attrs_map, prepared_cache \\ nil)

  def measure(:text, attrs_map, cache) do
    text = Map.get(attrs_map, :text, "")

    case LayoutEngine.lookup_in_cache(cache, :text, text) do
      {w, h} ->
        %{width: w, height: h}

      nil ->
        %{
          width: Raxol.UI.TextMeasure.display_width(text),
          height: @default_height
        }
    end
  end

  def measure(:label, attrs_map, cache) do
    text = Map.get(attrs_map, :content, "")

    case LayoutEngine.lookup_in_cache(cache, :label, text) do
      {w, _h} ->
        %{width: w, height: @default_height}

      nil ->
        %{
          width: Raxol.UI.TextMeasure.display_width(text),
          height: @default_height
        }
    end
  end

  def measure(:box, attrs_map, _cache) do
    width = Map.get(attrs_map, :width, @default_box_size)
    height = Map.get(attrs_map, :height, @default_box_size)
    %{width: width, height: height}
  end

  def measure(:checkbox, attrs_map, cache) do
    label = Map.get(attrs_map, :label, "")

    case LayoutEngine.lookup_in_cache(cache, :checkbox, label) do
      {w, _h} ->
        %{width: w, height: @default_height}

      nil ->
        %{
          width:
            @checkbox_prefix_width + Raxol.UI.TextMeasure.display_width(label),
          height: @default_height
        }
    end
  end
end
