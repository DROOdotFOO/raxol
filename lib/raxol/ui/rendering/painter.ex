defmodule Raxol.UI.Rendering.Painter do
  @moduledoc """
  Handles painting of UI components to the terminal.
  """


  @doc """
  Paints the render tree into draw commands or buffer updates.
  Currently a stub; in the future, this will convert the render tree into draw commands,
  potentially processing diffs or composition-specific changes.
  """
  @spec paint(
          compose_stage_output :: any(),
          new_tree_for_reference :: map() | nil,
          previous_composed_tree :: any(),
          previous_painted_output :: list(map()) | nil
        ) :: list(map())
  def paint(
        composed_data,
        _new_tree_for_reference,
        previous_composed_tree,
        previous_painted_output
      ) do
    # If composed_data is identical to previous, reuse the previous output
    handle_paint_reuse(
      composed_data === previous_composed_tree &&
        previous_painted_output != nil,
      composed_data,
      previous_composed_tree,
      previous_painted_output
    )
  end

  defp do_paint_node(nil, _parent_x, _parent_y), do: []

  defp do_paint_node(composed_node, _parent_x_offset, _parent_y_offset)
       when not is_map(composed_node) do
    Raxol.Core.Runtime.Log.warning(
      "Paint Stage: Encountered non-map node, expected composed map structure: #{inspect(composed_node)}"
    )

    []
  end

  defp do_paint_node(composed_node, parent_x_offset, parent_y_offset) do
    paint_ops_for_current_node =
      paint_current_node(composed_node, parent_x_offset, parent_y_offset)

    children_paint_ops =
      paint_children(composed_node, parent_x_offset, parent_y_offset)

    paint_ops_for_current_node ++ children_paint_ops
  end

  defp paint_current_node(composed_node, parent_x_offset, parent_y_offset) do
    case composed_node[:composed_type] do
      :composed_element ->
        paint_composed_element(composed_node)

      :primitive ->
        paint_primitive(composed_node, parent_x_offset, parent_y_offset)

      :unprocessed_map_wrapper ->
        []

      unknown_type ->
        Raxol.Core.Runtime.Log.warning(
          "Paint Stage: Unknown composed_type: #{inspect(unknown_type)}"
        )

        []
    end
  end

  defp paint_composed_element(composed_node) do
    attrs = composed_node[:attributes] || %{x: 0, y: 0, width: 0, height: 0}
    original_type = composed_node[:original_type]
    properties = composed_node[:properties] || %{}

    paint_op = %{
      op: :draw_element,
      element_type: original_type,
      x: attrs.x,
      y: attrs.y,
      width: attrs.width,
      height: attrs.height,
      properties: properties,
      text_content:
        properties[:text] || properties[:label] || properties[:value]
    }

    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: Generated draw_element op for #{original_type}: #{inspect(paint_op)}"
    )

    [paint_op]
  end

  defp paint_primitive(composed_node, parent_x_offset, parent_y_offset) do
    value = composed_node[:value]

    paint_op = %{
      op: :draw_primitive,
      value: value,
      x: parent_x_offset,
      y: parent_y_offset,
      primitive_type: get_primitive_type(value)
    }

    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: Generated draw_primitive op: #{inspect(paint_op)}"
    )

    [paint_op]
  end

  defp get_primitive_type(value) do
    determine_primitive_type(value)
  end

  defp paint_children(composed_node, parent_x_offset, parent_y_offset) do
    (composed_node[:children] || [])
    |> Enum.flat_map(fn child_node ->
      {child_parent_x, child_parent_y} =
        get_child_parent_offsets(
          composed_node,
          parent_x_offset,
          parent_y_offset
        )

      do_paint_node(child_node, child_parent_x, child_parent_y)
    end)
  end

  defp get_child_parent_offsets(composed_node, parent_x_offset, parent_y_offset) do
    handle_element_offsets(
      composed_node[:composed_type] == :composed_element,
      composed_node,
      parent_x_offset,
      parent_y_offset
    )
  end

  # Helper functions for if-statement elimination
  defp handle_paint_reuse(
         true,
         _composed_data,
         _previous_composed_tree,
         previous_painted_output
       ) do
    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: Reusing previous_painted_output as composed_data is identical to previous_composed_tree."
    )

    previous_painted_output
  end

  defp handle_paint_reuse(
         false,
         composed_data,
         previous_composed_tree,
         _previous_painted_output
       ) do
    log_repainting_reason(
      composed_data === previous_composed_tree,
      composed_data,
      previous_composed_tree
    )

    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: Starting with composed_stage_output: #{inspect(composed_data)}"
    )

    # Initial parent offsets are 0,0
    do_paint_node(composed_data, 0, 0)
  end

  defp log_repainting_reason(true, _composed_data, _previous_composed_tree) do
    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: composed_data is identical, but no previous_painted_output to reuse. Repainting."
    )
  end

  defp log_repainting_reason(false, composed_data, previous_composed_tree) do
    Raxol.Core.Runtime.Log.debug(
      "Paint Stage: composed_data differs from previous_composed_tree or no previous. Repainting. Details: composed_data: #{inspect(composed_data)}, prev_composed_tree: #{inspect(previous_composed_tree)}"
    )
  end

  defp determine_primitive_type(value) when is_binary(value), do: :text
  defp determine_primitive_type(value) when is_number(value), do: :number
  defp determine_primitive_type(_value), do: :unknown

  defp handle_element_offsets(
         true,
         composed_node,
         _parent_x_offset,
         _parent_y_offset
       ) do
    attrs = composed_node[:attributes] || %{}
    {attrs[:x] || 0, attrs[:y] || 0}
  end

  defp handle_element_offsets(
         false,
         _composed_node,
         parent_x_offset,
         parent_y_offset
       ) do
    {parent_x_offset, parent_y_offset}
  end
end
