defmodule Raxol.UI.Layout.Preparer do
  @moduledoc """
  Walks an element tree and produces PreparedElements with cached text measurements.

  This is the "prepare" phase of the two-phase prepare/layout architecture
  inspired by Pretext. The prepare phase measures all text nodes and caches
  the results. The layout phase (LayoutEngine) then uses these cached
  measurements for pure arithmetic position calculations.

  On terminal resize, only the layout phase needs to re-run if text content
  hasn't changed, since measurements are cached in the PreparedElement tree.
  """

  alias Raxol.UI.Layout.PreparedElement
  alias Raxol.UI.TextMeasure

  @doc """
  Prepares an element tree by pre-computing text measurements.

  Returns a `PreparedElement` tree with cached `measured_width` and
  `measured_height` values for all text-bearing nodes.
  """
  @spec prepare(map() | nil) :: PreparedElement.t() | nil
  def prepare(nil), do: nil

  def prepare(%{type: :text} = element) do
    text = Map.get(element, :text) || Map.get(element, :content, "")
    lines = String.split(text, "\n")

    width =
      lines |> Enum.map(&TextMeasure.display_width/1) |> Enum.max(fn -> 0 end)

    height = length(lines)

    %PreparedElement{
      type: :text,
      element: element,
      measured_width: width,
      measured_height: height,
      content_hash: :erlang.phash2(text),
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(%{type: :label} = element) do
    text = Map.get(element, :content) || Map.get(element, :text, "")
    width = TextMeasure.display_width(text)

    %PreparedElement{
      type: :label,
      element: element,
      measured_width: width,
      measured_height: 1,
      content_hash: :erlang.phash2(text),
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(%{type: :button} = element) do
    text = Map.get(element, :text) || Map.get(element, :label, "Button")
    width = TextMeasure.display_width(text)

    %PreparedElement{
      type: :button,
      element: element,
      measured_width: width,
      measured_height: 1,
      content_hash: :erlang.phash2(text),
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(%{type: :checkbox} = element) do
    label = Map.get(element, :label, "")
    # "[x] " prefix = 4 chars
    width = 4 + TextMeasure.display_width(label)

    %PreparedElement{
      type: :checkbox,
      element: element,
      measured_width: width,
      measured_height: 1,
      content_hash: :erlang.phash2(label),
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(%{type: type, children: children} = element)
      when is_list(children) do
    prepared_children = Enum.map(children, &prepare/1)

    %PreparedElement{
      type: type,
      element: element,
      measured_width: 0,
      measured_height: 0,
      children: prepared_children,
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  # Absolute layer: prepare the flow child and each overlay element. Both
  # contribute to the measurement cache so symbolic widths in overlays still
  # benefit from the prepare pass.
  def prepare(%{type: :absolute_layer} = element) do
    flow_child = Map.get(element, :flow_child)
    overlays = Map.get(element, :overlays, [])

    prepared_flow = if flow_child, do: prepare(flow_child), else: nil

    prepared_overlays =
      overlays
      |> Enum.map(fn
        %{element: el} -> prepare(el)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    children =
      [prepared_flow | prepared_overlays] |> Enum.reject(&is_nil/1)

    %PreparedElement{
      type: :absolute_layer,
      element: element,
      measured_width: 0,
      measured_height: 0,
      children: children,
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(%{type: type} = element) do
    %PreparedElement{
      type: type,
      element: element,
      measured_width: Map.get(element, :width, 0),
      measured_height: Map.get(element, :height, 0),
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare(other) when is_map(other) do
    %PreparedElement{
      type: :unknown,
      element: other,
      measured_width: 0,
      measured_height: 0,
      animation_hints: Map.get(other, :animation_hints, [])
    }
  end

  def prepare(_other), do: nil

  @doc """
  Re-prepares only elements whose content has changed.

  Compares content hashes between old and new trees. Returns a new
  PreparedElement tree reusing measurements from `old_prepared` where
  content hasn't changed.
  """
  @spec prepare_incremental(map() | nil, PreparedElement.t() | nil) ::
          PreparedElement.t() | nil
  def prepare_incremental(nil, _old), do: nil
  def prepare_incremental(element, nil), do: prepare(element)

  def prepare_incremental(
        %{type: type, children: new_children} = element,
        %PreparedElement{type: type, children: old_children} = _old
      )
      when is_list(new_children) and is_list(old_children) do
    # Container node: recursively diff children
    prepared_children =
      zip_longest(new_children, old_children)
      |> Enum.map(fn
        {new_child, nil} -> prepare(new_child)
        {nil, _old_child} -> nil
        {new_child, old_child} -> prepare_incremental(new_child, old_child)
      end)
      |> Enum.reject(&is_nil/1)

    %PreparedElement{
      type: type,
      element: element,
      measured_width: 0,
      measured_height: 0,
      children: prepared_children,
      animation_hints: Map.get(element, :animation_hints, [])
    }
  end

  def prepare_incremental(
        %{type: type} = element,
        %PreparedElement{type: type} = old
      ) do
    new_hash = content_hash_for(element)

    if new_hash == old.content_hash do
      # Content unchanged -- reuse cached measurements, update element ref
      %{old | element: element}
    else
      prepare(element)
    end
  end

  def prepare_incremental(element, _old), do: prepare(element)

  defp zip_longest(a, b), do: Raxol.Core.Utils.List.zip_longest(a, b)

  defp content_hash_for(%{type: :text} = el) do
    text = Map.get(el, :text) || Map.get(el, :content, "")
    :erlang.phash2(text)
  end

  defp content_hash_for(%{type: :label} = el) do
    text = Map.get(el, :content) || Map.get(el, :text, "")
    :erlang.phash2(text)
  end

  defp content_hash_for(%{type: :button} = el) do
    text = Map.get(el, :text) || Map.get(el, :label, "Button")
    :erlang.phash2(text)
  end

  defp content_hash_for(%{type: :checkbox} = el) do
    :erlang.phash2(Map.get(el, :label, ""))
  end

  defp content_hash_for(_), do: nil
end
