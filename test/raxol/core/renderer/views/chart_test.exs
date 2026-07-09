
defmodule Raxol.Core.Renderer.Views.ChartTest do
  @moduledoc """
  Tests for the chart module, including creation, features,
  data handling, and axes/labels.
  """
  use ExUnit.Case

  @sample_series [
    %{
      name: "Series A",
      data: [1, 4, 2, 5, 3],
      color: :blue
    },
    %{
      name: "Series B",
      data: [2, 3, 4, 1, 5],
      color: :red
    }
  ]

  describe "new/1" do
    test "creates a basic bar chart" do
      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          series: @sample_series,
          width: 20,
          height: 10
        )

      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view.type == :box
      assert view.children != nil
    end

    test "creates a line chart" do
      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :line,
          series: @sample_series,
          width: 20,
          height: 10
        )

      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view.type == :box
      assert view.children != nil
    end

    test "creates a sparkline" do
      # Sparkline only uses the first series
      spark_series = [@sample_series |> List.first()]

      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :sparkline,
          series: spark_series,
          width: 20,
          show_axes: false,
          show_labels: false,
          show_legend: false
        )

      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view.type == :box

      # The sparkline returns a single text view, not a list
      text_view = view.children
      assert text_view != nil
      assert is_map(text_view)
      assert text_view.type == :text
      assert text_view.content != nil

      # The sparkline should have exactly 20 characters (5 data points + 15 spaces)
      assert String.length(text_view.content) == 20
      # Should end with spaces (padded to full width)
      assert String.ends_with?(text_view.content, "               ")
    end
  end

  # End of describe "new/1"

  describe "bar chart features" do
    test "handles vertical orientation" do
      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          orientation: :vertical,
          series: @sample_series,
          width: 20,
          height: 10
        )

      content = view
      assert is_map(content)
      assert Map.has_key?(content, :type)
      assert content.type == :box
    end

    test "handles horizontal orientation" do
      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          orientation: :horizontal,
          series: @sample_series,
          width: 20,
          height: 10
        )

      content = view
      assert is_map(content)
      assert Map.has_key?(content, :type)
      assert content.type == :box
    end

    # Helper function
    defp find_all_text_children(view) do
      case view do
        %{type: :text} -> [view]
        %{children: children} -> process_children(children)
        _ -> []
      end
    end

    defp process_children(children) when is_list(children) do
      if Enum.all?(children, &is_list/1) do
        children
        |> List.flatten()
        |> Enum.flat_map(&find_all_text_children/1)
      else
        Enum.flat_map(children, &find_all_text_children/1)
      end
    end

    defp process_children(%{} = child_map),
      do: find_all_text_children(child_map)

    defp process_children(_), do: []

    test "applies colors to bars" do
      # Need to re-create the view within the test as setup context is gone
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          series: @sample_series,
          width: 20,
          height: 10
        )

      bars = find_all_text_children(view)
      assert Enum.any?(bars, fn bar -> is_map(bar) and bar.fg == :blue end)
      assert Enum.any?(bars, fn bar -> is_map(bar) and bar.fg == :red end)
    end
  end

  describe "line chart features" do
    # Sample data for line charts - Restructure to match expected series format
    # The chart expects a list of series, each with a :data key containing points.
    @line_data_series [
      %{
        # Added name for consistency
        name: "Series 1",
        # Use the values as data points
        data: [10, 20],
        # Assuming color applies to the series
        color: :blue
      },
      %{
        name: "Series 2",
        # Example data points
        data: [15, 5],
        color: :red
      }
    ]

    test "creates points and lines" do
      # Define two-series data locally for this test
      local_series_data = [
        %{name: "Series 1", data: [10, 20], color: :blue},
        %{name: "Series 2", data: [15, 5], color: :red}
      ]

      # Use the local data
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :line,
          series: local_series_data,
          width: 40,
          height: 10
        )

      # Find points (represented by •)
      content = view
      points = find_all_text_children(content)
      # Check for at least 2 points
      assert Enum.count(points, &(is_map(&1) and &1.content == "•")) >= 2
    end

    test "applies colors to lines" do
      # Define two-series data locally for this test
      local_series_data = [
        %{name: "Series 1", data: [10, 20], color: :blue},
        %{name: "Series 2", data: [15, 5], color: :red}
      ]

      # Use the local data
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :line,
          series: local_series_data,
          width: 40,
          height: 10
        )

      # Find points (represented by •) and check colors
      content = view
      points = find_all_text_children(content)
      assert Enum.any?(points, &(is_map(&1) and &1.fg == :blue))
      assert Enum.any?(points, &(is_map(&1) and &1.fg == :red))
    end
  end

  describe "axes and labels" do
    # Skipped tests removed: axes and legend features not implemented and not planned.
  end

  describe "data handling" do
    test "respects custom min/max" do
      # Use full name
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          series: @sample_series,
          width: 20,
          height: 10,
          min_value: 0,
          max_value: 10
        )

      # Add assertions to verify min/max impact if possible
      assert is_map(view)
      assert Map.has_key?(view, :type)
    end

    test "handles empty data" do
      view =
        Raxol.Core.Renderer.Views.Chart.new(
          type: :bar,
          series: [%{data: []}],
          show_axes: false,
          show_labels: false,
          show_legend: false
        )

      # Verify the structure returned for empty data
      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view.type == :box

      children = view.children

      flex_view =
        cond do
          is_list(children) ->
            assert length(children) == 1
            List.first(children)

          is_map(children) ->
            children
        end

      assert is_map(flex_view)
      assert Map.has_key?(flex_view, :type)
      assert flex_view.type == :flex
      assert flex_view.children == []
    end
  end
end
