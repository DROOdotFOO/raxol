defmodule Raxol.UI.Components.ProgressTest do
  @moduledoc """
  Test suite for the Progress component.
  """
  use ExUnit.Case
  @moduletag :capture_log
  alias Raxol.UI.Components.Progress

  describe "bar/2" do
    test "renders a basic progress bar" do
      result = Progress.bar(0.5)
      assert result != nil
    end

    test "renders a progress bar with custom width" do
      result = Progress.bar(0.75, width: 30)
      assert result != nil
    end

    test "renders a progress bar with custom styles" do
      result =
        Progress.bar(0.25,
          filled_style: %{bg: :green},
          empty_style: %{bg: :black},
          chars: %{filled: "█", empty: "░"}
        )

      assert result != nil
    end
  end

  describe "bar_with_label/3" do
    test "renders a progress bar with label" do
      result = Progress.bar_with_label(0.5, "Loading...")
      assert result != nil
    end

    test "renders a progress bar with label and percentage" do
      result =
        Progress.bar_with_label(0.75, "Processing...", show_percentage: true)

      assert result != nil
    end

    test "renders a progress bar with label in different positions" do
      positions = [:above, :below, :right]

      for position <- positions do
        result = Progress.bar_with_label(0.5, "Loading...", position: position)
        assert result != nil
      end
    end
  end

  describe "spinner/3" do
    test "renders a basic spinner" do
      result = Progress.spinner(nil, 0)
      assert result != nil
    end

    test "renders a spinner with message" do
      result = Progress.spinner("Loading...", 0)
      assert result != nil
    end

    test "renders different spinner types" do
      types = [:dots, :line, :braille, :pulse, :circle]

      for type <- types do
        result = Progress.spinner("Loading...", 0, type: type)
        assert result != nil
      end
    end
  end

  describe "indeterminate/2" do
    test "renders an indeterminate progress bar" do
      result = Progress.indeterminate(0)
      assert result != nil
    end

    test "renders an indeterminate progress bar with custom width" do
      result = Progress.indeterminate(0, width: 30)
      assert result != nil
    end

    test "renders an indeterminate progress bar with custom styles" do
      result =
        Progress.indeterminate(0,
          bar_style: %{bg: :purple},
          background_style: %{bg: :black},
          segment_size: 8
        )

      assert result != nil
    end
  end

  describe "circular/2" do
    test "renders a circular progress indicator" do
      result = Progress.circular(0.5)
      assert result != nil
    end

    test "renders a circular progress indicator with percentage" do
      result = Progress.circular(0.75, show_percentage: true)
      assert result != nil
    end

    test "renders a circular progress indicator with custom style" do
      result = Progress.circular(0.25, style: %{fg: :green})
      assert result != nil
    end
  end
end
