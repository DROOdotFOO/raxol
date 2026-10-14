defmodule Raxol.Core.TextProcessorTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.TextProcessor

  describe "process_text_element/2" do
    test "returns text, style, width, and height in the result" do
      text_map = %{text: "hello", style: %{bold: true}}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.text == "hello"
      assert result.style == %{bold: true}
      assert result.width == 5
      assert result.height == 1
    end

    test "clamps width to available space when text is wider" do
      text_map = %{text: "a long string that exceeds width"}
      space = %{width: 10}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.width == 10
    end

    test "preserves original width when text fits within space" do
      text_map = %{text: "hi"}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.width == 2
    end

    test "height is always 1" do
      text_map = %{text: "anything"}
      space = %{width: 100}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.height == 1
    end

    test "defaults text to empty string when missing from map" do
      text_map = %{}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.text == ""
      assert result.width == 0
    end

    test "defaults style to empty map when missing from map" do
      text_map = %{text: "hello"}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.style == %{}
    end

    test "preserves extra keys from the original text_map" do
      text_map = %{text: "hello", style: %{}, id: "my_text", custom: :data}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.id == "my_text"
      assert result.custom == :data
    end

    test "handles empty text string" do
      text_map = %{text: ""}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.text == ""
      assert result.width == 0
      assert result.height == 1
    end

    test "handles zero-width space" do
      text_map = %{text: "hello"}
      space = %{width: 0}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.width == 0
    end

    test "handles text exactly matching space width" do
      text_map = %{text: "12345"}
      space = %{width: 5}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.width == 5
    end

    test "handles single character text" do
      text_map = %{text: "x"}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.text == "x"
      assert result.width == 1
      assert result.height == 1
    end

    test "overwrites existing width and height keys in the text_map" do
      text_map = %{text: "abc", style: %{}, width: 999, height: 999}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.width == 3
      assert result.height == 1
    end

    test "handles unicode text" do
      text_map = %{text: "cafe\u0301"}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.text == "cafe\u0301"
      assert result.width == String.length("cafe\u0301")
    end

    test "style map is preserved as-is" do
      style = %{fg: :red, bg: :blue, bold: true, underline: true}
      text_map = %{text: "styled", style: style}
      space = %{width: 80}

      result = TextProcessor.process_text_element(text_map, space)

      assert result.style == style
    end
  end
end
