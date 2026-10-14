defmodule Raxol.UI.Components.Progress.BarTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.UI.Components.Progress.Bar

  describe "bar/2" do
    test "creates a basic progress bar with default options" do
      result = Bar.bar(50)
      assert result == "[==========          ] 50%"
    end

    test "creates a progress bar without percentage" do
      result = Bar.bar(50, show_percentage: false)
      assert result == "[==========          ]"
    end

    test "creates a progress bar with custom width" do
      result = Bar.bar(50, width: 10)
      assert result == "[=====     ] 50%"
    end

    test "creates a progress bar with custom max value" do
      result = Bar.bar(25, max: 50)
      assert result == "[==========          ] 50%"
    end

    test "clamps value to 100% when exceeding max" do
      result = Bar.bar(150, max: 100)
      assert result == "[====================] 100%"
    end

    test "handles zero progress" do
      result = Bar.bar(0)
      assert result == "[                    ] 0%"
    end

    test "handles full progress" do
      result = Bar.bar(100)
      assert result == "[====================] 100%"
    end

    test "supports different bar styles" do
      # Solid style (default)
      result = Bar.bar(50, style: :solid, width: 10, show_percentage: false)
      assert result == "[=====     ]"

      # ASCII style
      result = Bar.bar(50, style: :ascii, width: 10, show_percentage: false)
      assert result == "[#####-----]"

      # Blocks style
      result = Bar.bar(50, style: :blocks, width: 10, show_percentage: false)
      assert result == "[█████░░░░░]"

      # Dots style
      result = Bar.bar(50, style: :dots, width: 10, show_percentage: false)
      assert result == "[●●●●●○○○○○]"
    end
  end

  describe "bar_with_label/3" do
    test "creates a progress bar with a label" do
      result = Bar.bar_with_label(50, "Loading")
      assert result == "Loading: [==========          ] 50%"
    end

    test "creates a progress bar with label and custom options" do
      result = Bar.bar_with_label(75, "Progress", width: 10, max: 100)
      assert result == "Progress: [========  ] 75%"
    end

    test "label with custom max value" do
      result = Bar.bar_with_label(30, "Download", max: 60, width: 10)
      assert result == "Download: [=====     ] 50%"
    end

    test "label with full progress" do
      result = Bar.bar_with_label(100, "Complete")
      assert result == "Complete: [====================] 100%"
    end
  end
end
