defmodule Raxol.Terminal.AdvancedFeaturesTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.AdvancedFeatures

  describe "notify/1" do
    test "emits an OSC 9 notification sequence" do
      assert AdvancedFeatures.notify("Build finished") ==
               "\e]9;Build finished\e\\"
    end
  end

  describe "report_progress/2" do
    test "emits OSC 9;4 with the set state code" do
      assert AdvancedFeatures.report_progress(:set, 42) == "\e]9;4;1;42\e\\"
    end

    test "emits OSC 9;4 for the remove state" do
      assert AdvancedFeatures.report_progress(:remove) == "\e]9;4;0;0\e\\"
    end

    test "emits OSC 9;4 for the error state" do
      assert AdvancedFeatures.report_progress(:error, 100) == "\e]9;4;2;100\e\\"
    end

    test "emits OSC 9;4 for the indeterminate state" do
      assert AdvancedFeatures.report_progress(:indeterminate) ==
               "\e]9;4;3;0\e\\"
    end

    test "emits OSC 9;4 for the warning state" do
      assert AdvancedFeatures.report_progress(:warning, 75) == "\e]9;4;4;75\e\\"
    end
  end

  describe "clear_progress/0" do
    test "emits a remove-state progress sequence" do
      assert AdvancedFeatures.clear_progress() == "\e]9;4;0;0\e\\"
    end
  end

  describe "set_pointer_shape/1" do
    test "emits an OSC 22 sequence for a named shape" do
      assert AdvancedFeatures.set_pointer_shape("pointer") ==
               "\e]22;pointer\e\\"
    end

    test "emits an OSC 22 sequence for the default shape" do
      assert AdvancedFeatures.set_pointer_shape("default") ==
               "\e]22;default\e\\"
    end
  end
end
