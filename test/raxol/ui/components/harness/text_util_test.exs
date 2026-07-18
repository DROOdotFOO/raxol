defmodule Raxol.UI.Components.Harness.TextUtilTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.TextUtil

  describe "truncate_to_width/2" do
    test "returns text unchanged when width is zero" do
      assert TextUtil.truncate_to_width("abc", 0) == "abc"
    end

    test "returns text unchanged when width is negative" do
      assert TextUtil.truncate_to_width("abc", -5) == "abc"
    end

    test "returns text unchanged when width is not an integer" do
      assert TextUtil.truncate_to_width("abc", "x") == "abc"
    end

    test "truncates and appends an ellipsis when text overflows" do
      assert TextUtil.truncate_to_width("abcdef", 3) == "ab…"
    end

    test "returns text unchanged when it fits within width" do
      assert TextUtil.truncate_to_width("ab", 5) == "ab"
    end
  end
end
