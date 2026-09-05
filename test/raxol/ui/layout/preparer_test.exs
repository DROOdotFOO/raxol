defmodule Raxol.UI.Layout.PreparerTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.{PreparedElement, Preparer}

  describe "prepare/1" do
    test "prepares text element with correct display width" do
      element = %{type: :text, content: "hello"}
      prepared = Preparer.prepare(element)

      assert %PreparedElement{} = prepared
      assert prepared.type == :text
      assert prepared.measured_width == 5
      assert prepared.measured_height == 1
      assert prepared.content_hash == :erlang.phash2("hello")
    end

    test "prepares CJK text with correct display width" do
      element = %{type: :text, content: "中文"}
      prepared = Preparer.prepare(element)

      assert prepared.measured_width == 4
      assert prepared.measured_height == 1
    end

    test "prepares multiline text" do
      element = %{type: :text, content: "line1\nline2longer"}
      prepared = Preparer.prepare(element)

      assert prepared.measured_width == 11
      assert prepared.measured_height == 2
    end

    test "prepares label element" do
      element = %{type: :label, content: "Name:"}
      prepared = Preparer.prepare(element)

      assert prepared.type == :label
      assert prepared.measured_width == 5
      assert prepared.measured_height == 1
    end

    test "prepares button element" do
      element = %{type: :button, text: "Submit"}
      prepared = Preparer.prepare(element)

      assert prepared.type == :button
      assert prepared.measured_width == 6
    end

    test "prepares checkbox with label" do
      element = %{type: :checkbox, label: "Enable"}
      prepared = Preparer.prepare(element)

      assert prepared.type == :checkbox
      # 4 (prefix) + 6 (label)
      assert prepared.measured_width == 10
    end

    test "prepares container with children recursively" do
      element = %{
        type: :row,
        children: [
          %{type: :text, content: "hello"},
          %{type: :text, content: "中文"}
        ]
      }

      prepared = Preparer.prepare(element)

      assert prepared.type == :row
      assert length(prepared.children) == 2
      [child1, child2] = prepared.children
      assert child1.measured_width == 5
      assert child2.measured_width == 4
    end

    test "prepares nil as nil" do
      assert Preparer.prepare(nil) == nil
    end

    test "non-map views do not crash prepare" do
      assert Preparer.prepare(:ok) == nil
      assert Preparer.prepare("nope") == nil
    end
  end

  describe "prepare_incremental/2" do
    test "reuses measurements when content unchanged" do
      element = %{type: :text, content: "hello"}
      old_prepared = Preparer.prepare(element)

      # Same content, different style -- should reuse measurement
      new_element = %{type: :text, content: "hello", style: %{bold: true}}
      result = Preparer.prepare_incremental(new_element, old_prepared)

      assert result.measured_width == 5
      assert result.content_hash == old_prepared.content_hash
      # Element reference updated to new element
      assert result.element == new_element
    end

    test "re-measures when content changes" do
      old_element = %{type: :text, content: "hello"}
      old_prepared = Preparer.prepare(old_element)

      new_element = %{type: :text, content: "中文test"}
      result = Preparer.prepare_incremental(new_element, old_prepared)

      # "中文" = 4 + "test" = 4 = 8
      assert result.measured_width == 8
      assert result.content_hash != old_prepared.content_hash
    end

    test "prepares fresh when old is nil" do
      element = %{type: :text, content: "hello"}
      result = Preparer.prepare_incremental(element, nil)

      assert %PreparedElement{} = result
      assert result.measured_width == 5
    end

    test "prepares fresh when type changes" do
      old = Preparer.prepare(%{type: :text, content: "hello"})

      result =
        Preparer.prepare_incremental(%{type: :button, text: "hello"}, old)

      assert result.type == :button
    end
  end
end
