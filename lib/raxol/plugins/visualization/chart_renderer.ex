defmodule Raxol.Plugins.Visualization.ChartRenderer do
  @moduledoc """
  Handles rendering logic for chart visualizations within the VisualizationPlugin.
  """

  alias Raxol.Plugins.Visualization.DrawingUtils
  alias Raxol.Style
  alias Raxol.Terminal.Cell

  # Define module attributes for thresholds previously in the plugin
  @max_chart_data_points 100

  @doc """
  Public entry point for rendering chart content.
  Handles bounds checking, error handling, and calls the internal drawing logic.
  Expects bounds to be a map like %{width: w, height: h}.
  """
  def render_chart_content(
        data,
        opts,
        %{width: width, height: height} = bounds,
        _state
      ) do
    title = Map.get(opts, :title, "Chart")
    handle_bounds_check(width >= 5 and height >= 3, data, title, bounds)
  end

  # --- Private Helper Functions ---

  # Pattern matching for bounds check instead of if statement
  defp handle_bounds_check(false, _data, _title, bounds) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "[ChartRenderer] Bounds too small for chart rendering: #{inspect(bounds)}",
      %{}
    )

    DrawingUtils.draw_box_with_text("!", bounds)
  end

  defp handle_bounds_check(true, data, title, bounds) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           # First, sample the data if it's too large
           sampled_data = sample_chart_data(data)
           # Log if sampling occurred
           log_sampling(data, sampled_data)

           # Draw the chart with sampled data
           draw_tui_bar_chart(sampled_data, title, bounds)
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[ChartRenderer] Error rendering chart: #{inspect(reason)}"
        )

        DrawingUtils.draw_box_with_text("[Render Error]", bounds)
    end
  end

  # Pattern matching for chart validation instead of if statement
  defp handle_chart_validation(
         {true, true, true},
         data,
         title,
         _bounds,
         width,
         height
       ) do
    {max_value, min_value} = calculate_value_bounds(data)
    {chart_height, chart_width} = calculate_chart_dimensions(width, height)
    grid = initialize_grid(width, height, title, max_value, min_value)

    _draw_chart_content(
      grid,
      data,
      max_value,
      min_value,
      chart_height,
      chart_width,
      height,
      width
    )
  end

  defp handle_chart_validation(
         _validation,
         data,
         _title,
         bounds,
         _width,
         _height
       ) do
    message = get_chart_error_message(data)
    DrawingUtils.draw_box_with_text(message, bounds)
  end

  defp get_chart_error_message([]), do: "[No Data]"
  defp get_chart_error_message(_), do: "!"

  # Pattern matching for max value check instead of if statement
  defp _handle_max_value_check(
         true,
         _value,
         _max_value,
         _min_value,
         _chart_height
       ),
       do: 0

  defp _handle_max_value_check(false, value, max_value, min_value, chart_height) do
    round(chart_height * (value - min_value) / max(1, max_value - min_value))
  end

  # Pattern matching for sampling decision instead of if statement
  defp handle_sampling_decision(true, data, _data_length) do
    # No sampling needed
    data
  end

  defp handle_sampling_decision(false, data, data_length) do
    # Calculate sampling interval
    interval = ceil(data_length / @max_chart_data_points)
    # Take every nth element
    data
    |> Enum.with_index()
    |> Enum.filter(fn {_item, index} -> rem(index, interval) == 0 end)
    |> Enum.map(fn {item, _index} -> item end)
  end

  # Pattern matching for sampling log instead of if statement
  defp handle_sampling_log({true, true}, data_length, sampled_length) do
    Raxol.Core.Runtime.Log.debug(
      "[ChartRenderer] Data sampled for chart: #{data_length} -> #{sampled_length} points"
    )
  end

  defp handle_sampling_log(_condition, _data_length, _sampled_length), do: :ok

  # --- Private Chart Drawing Logic ---

  @doc false
  # Draws a simple text-based bar chart within the given bounds.
  # Assumes data is a list of {label, value} tuples or maps with :label and :value keys.
  defp draw_tui_bar_chart(data, title, %{width: width, height: height} = bounds) do
    handle_chart_validation(
      {is_list(data), width > 4, height > 4},
      data,
      title,
      bounds,
      width,
      height
    )
  end

  defp calculate_value_bounds(data) do
    values =
      Enum.map(data, fn
        {_label, value} -> value
        %{value: value} -> value
        _ -> 0
      end)

    max_value = Enum.max_by(data, &elem(&1, 1), fn -> {nil, 0} end) |> elem(1)
    min_value = Enum.min([0 | values])
    {max_value, min_value}
  end

  defp calculate_chart_dimensions(width, height) do
    chart_height = max(1, height - 2)
    chart_width = max(1, width - 4)
    {chart_height, chart_width}
  end

  defp initialize_grid(width, height, title, max_value, min_value) do
    grid = List.duplicate(List.duplicate(Cell.new(" "), width), height)
    grid = DrawingUtils.draw_text_centered(grid, 0, title)
    grid = DrawingUtils.draw_text(grid, 1, 0, Integer.to_string(max_value))

    grid =
      DrawingUtils.draw_text(grid, height - 2, 0, Integer.to_string(min_value))

    _draw_y_axis(grid, height)
  end

  defp _draw_y_axis(grid, height) do
    Enum.reduce(1..(height - 2), grid, fn y, acc_grid ->
      axis_style = Style.new(fg: :dark_gray)

      DrawingUtils.put_cell(acc_grid, y, 3, %{Cell.new("|") | style: axis_style})
    end)
  end

  defp _draw_chart_content(
         grid,
         data,
         max_value,
         min_value,
         chart_height,
         chart_width,
         height,
         _width
       ) do
    num_bars = Enum.count(data)
    total_bar_area_width = max(1, chart_width - (num_bars - 1))
    bar_width = max(1, div(total_bar_area_width, num_bars))

    spacing =
      case num_bars > 1 do
        true -> 1
        false -> 0
      end

    Enum.reduce(Enum.with_index(data), {grid, 4}, fn {{label, value}, _index},
                                                     {acc_grid, current_x} ->
      bar_height =
        _calculate_bar_height(value, max_value, min_value, chart_height)

      bar_start_y = height - 2 - bar_height
      new_grid = _draw_bar(acc_grid, bar_width, bar_start_y, height, current_x)

      _draw_label_and_advance(
        new_grid,
        label,
        bar_width,
        height,
        current_x,
        spacing
      )
    end)
    |> elem(0)
  end

  defp _calculate_bar_height(value, max_value, min_value, chart_height) do
    _handle_max_value_check(
      max_value == 0,
      value,
      max_value,
      min_value,
      chart_height
    )
  end

  defp _draw_bar(grid, bar_width, bar_start_y, height, current_x) do
    Enum.reduce(0..(bar_width - 1), grid, fn w_offset, inner_grid ->
      _draw_bar_column(inner_grid, bar_start_y, height, current_x + w_offset)
    end)
  end

  defp _draw_bar_column(grid, bar_start_y, height, x) do
    Enum.reduce(bar_start_y..(height - 2), grid, fn y, acc_grid ->
      style = Style.new(bg: :blue, fg: :blue)
      cell = %{Cell.new("█") | style: style}
      DrawingUtils.put_cell(acc_grid, y, x, cell)
    end)
  end

  defp _draw_label_and_advance(
         grid,
         label,
         bar_width,
         height,
         current_x,
         spacing
       ) do
    label_str = _format_label(label, bar_width)
    final_grid = DrawingUtils.draw_text(grid, height - 1, current_x, label_str)
    next_x = current_x + bar_width + spacing
    {final_grid, next_x}
  end

  defp _format_label(label, bar_width) do
    case label do
      l when is_binary(l) -> l
      l -> inspect(l)
    end
    |> String.slice(0, bar_width)
  end

  # --- Private Data Handling ---

  @doc false
  # Sample data if it exceeds the threshold using simple interval sampling.
  defp sample_chart_data(data) when is_list(data) do
    data_length = length(data)

    handle_sampling_decision(
      data_length <= @max_chart_data_points,
      data,
      data_length
    )
  end

  # Return non-lists as is
  defp sample_chart_data(other), do: other

  defp log_sampling(original_data, sampled_data) do
    data_length =
      case original_data do
        data when is_list(data) -> length(data)
        _ -> 0
      end

    sampled_length =
      case sampled_data do
        data when is_list(data) -> length(data)
        _ -> 0
      end

    handle_sampling_log(
      {data_length != sampled_length, data_length > 0},
      data_length,
      sampled_length
    )
  end
end
