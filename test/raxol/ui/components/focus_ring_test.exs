defmodule Raxol.UI.Components.FocusRingTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.UI.Components.FocusRing

  describe "init/1" do
    test "returns default config with no options" do
      config = FocusRing.init()
      assert config.enabled == true
      assert config.style == :solid
      assert config.color == :blue
      assert config.width == 1
      assert config.offset == 0
      assert config.components == []
    end

    test "accepts custom options" do
      config = FocusRing.init(enabled: false, style: :double, color: :red, width: 2, offset: 1)
      assert config.enabled == false
      assert config.style == :double
      assert config.color == :red
      assert config.width == 2
      assert config.offset == 1
    end

    test "accepts components list" do
      config = FocusRing.init(components: ["btn1", "btn2"])
      assert config.components == ["btn1", "btn2"]
    end
  end

  describe "render/2" do
    test "returns content unchanged when disabled" do
      config = FocusRing.init(enabled: false)
      assert FocusRing.render("hello", config) == "hello"
    end

    test "wraps content with solid border" do
      config = FocusRing.init(style: :solid, color: :blue)
      result = FocusRing.render("hi", config)
      assert is_binary(result)
      assert result =~ "hi"
      # Solid style uses + corners
      assert result =~ "+"
      assert result =~ "-"
    end

    test "wraps content with double border" do
      config = FocusRing.init(style: :double, color: :red)
      result = FocusRing.render("test", config)
      assert result =~ "#"
      assert result =~ "="
    end

    test "wraps content with rounded border" do
      config = FocusRing.init(style: :rounded, color: :green)
      result = FocusRing.render("ok", config)
      assert result =~ "("
      assert result =~ ")"
    end

    test "wraps content with dots border" do
      config = FocusRing.init(style: :dots, color: :yellow)
      result = FocusRing.render("x", config)
      assert result =~ ":"
    end

    test "does not embed ANSI codes in rendered output" do
      config = FocusRing.init(style: :solid, color: :cyan)
      result = FocusRing.render("text", config)
      refute result =~ "\e["
    end

    test "handles multiline content" do
      config = FocusRing.init(style: :solid, color: :blue)
      result = FocusRing.render("line1\nline2", config)
      lines = String.split(result, "\n")
      # top border + 2 content lines + bottom border = 4 lines
      assert length(lines) == 4
    end

    test "applies offset spacing" do
      config = FocusRing.init(style: :solid, color: :blue, offset: 2)
      result = FocusRing.render("hi", config)
      lines = String.split(result, "\n")
      # Each line should start with offset spaces
      Enum.each(lines, fn line ->
        assert String.starts_with?(line, "  ")
      end)
    end
  end

  describe "should_focus?/2" do
    test "returns true when component is in the list" do
      config = FocusRing.init(components: ["btn1", "btn2"])
      assert FocusRing.should_focus?("btn1", config)
    end

    test "returns false when component is not in the list" do
      config = FocusRing.init(components: ["btn1"])
      refute FocusRing.should_focus?("btn2", config)
    end

    test "returns false for non-config second arg" do
      refute FocusRing.should_focus?("btn1", %{})
    end
  end

  describe "add_component/2" do
    test "adds a component to tracking" do
      config = FocusRing.init()
      updated = FocusRing.add_component(config, "new_btn")
      assert "new_btn" in updated.components
    end

    test "does not duplicate existing component" do
      config = FocusRing.init(components: ["btn1"])
      updated = FocusRing.add_component(config, "btn1")
      assert length(updated.components) == 1
    end
  end

  describe "remove_component/2" do
    test "removes a component from tracking" do
      config = FocusRing.init(components: ["btn1", "btn2"])
      updated = FocusRing.remove_component(config, "btn1")
      refute "btn1" in updated.components
      assert "btn2" in updated.components
    end

    test "is no-op when component not present" do
      config = FocusRing.init(components: ["btn1"])
      updated = FocusRing.remove_component(config, "btn2")
      assert updated.components == ["btn1"]
    end
  end

  describe "set_style/2" do
    test "updates the focus ring style" do
      config = FocusRing.init()
      updated = FocusRing.set_style(config, :double)
      assert updated.style == :double
    end
  end
end
