defmodule Raxol.UI.Layout.MinContentTest do
  @moduledoc "Contract tests for min-content measurement."
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.MinContent

  describe "text: longest unbreakable segment" do
    test "longest word wins" do
      assert MinContent.width(%{type: :text, text: "a bb characterization dd"}) ==
               16
    end

    test "hyphens are break opportunities" do
      # segments: "cross-" (6) and "terminal" (8)
      assert MinContent.width(%{type: :text, text: "cross-terminal"}) == 8
    end

    test "CJK breaks between ideographs: min is one double-width cell pair" do
      assert MinContent.width(%{type: :text, text: "你好世界"}) == 2
    end

    test "mixed latin + CJK" do
      assert MinContent.width(%{type: :text, text: "abc 你好 defgh"}) == 5
    end

    test "empty and nil" do
      assert MinContent.width(%{type: :text, text: ""}) == 0
      assert MinContent.width(%{type: :text}) == 0
    end
  end

  describe "L6 root cause" do
    test "divider min-content is 1 cell, not container width" do
      assert MinContent.width(%{type: :divider}) == 1
    end
  end

  describe "boxes" do
    test "explicit width wins" do
      assert MinContent.width(%{type: :box, style: %{width: 28}, children: []}) ==
               28
    end

    test "auto box: max child + border + horizontal padding" do
      box = %{
        type: :box,
        style: %{border: :single, padding: 1},
        children: [%{type: :text, text: "hello world"}]
      }

      # longest word 5 + border 2 + padding 2
      assert MinContent.width(box) == 9
    end
  end

  describe "flex containers" do
    test "row: sum of children mins plus gaps" do
      flex = %{
        type: :flex,
        direction: :row,
        gap: 2,
        children: [
          %{type: :text, text: "ab cd"},
          %{type: :divider},
          %{type: :text, text: "xyz"}
        ]
      }

      # 2 + 1 + 3 + 2 gaps * 2
      assert MinContent.width(flex) == 10
    end

    test "column: max of children mins" do
      flex = %{
        type: :flex,
        direction: :column,
        children: [%{type: :text, text: "looooooong"}, %{type: :divider}]
      }

      assert MinContent.width(flex) == 10
    end

    test "literal :row/:column types route like flex" do
      assert MinContent.width(%{
               type: :column,
               children: [%{type: :text, text: "abcde"}]
             }) == 5
    end
  end

  test "unknown types impose no minimum" do
    assert MinContent.width(%{type: :mystery_widget}) == 0
  end

  test "button chrome" do
    assert MinContent.width(%{type: :button, text: "OK"}) == 6
  end
end
