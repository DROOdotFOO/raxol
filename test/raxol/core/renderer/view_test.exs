defmodule Raxol.Core.Renderer.ViewTest do
  @moduledoc """
  Tests for the view module: creation, spacing normalization, and
  construction-time validation. `View.layout/2` and the layout-geometry
  tests it backed were deleted in N15 (flex rework Phase D) along with
  the production-dead legacy layout stack it delegated to.
  """
  use ExUnit.Case, async: true
  alias Raxol.Core.Renderer.View
  require Raxol.Core.Renderer.View

  describe "new/2" do
    test "creates a basic view" do
      view = View.new(:text, content: "Hello")
      assert is_map(view)
      assert Map.has_key?(view, :type)
      assert view.type == :text
      assert view.content == "Hello"
      assert view.style == %{}
      assert view.border == nil
    end

    test "applies all options" do
      view =
        View.new(:box,
          position: {0, 0},
          size: {10, 5},
          style: [:bold],
          fg: :red,
          bg: :blue,
          border: :single,
          padding: 1,
          margin: {2, 2}
        )

      assert view.position == {0, 0}
      assert view.size == {10, 5}
      assert view.style == [:bold]
      assert view.fg == :red
      assert view.bg == :blue
      assert view.border == :single
      assert view.padding == {1, 1, 1, 1}
      assert view.margin == {2, 2, 2, 2}
    end

    test "handles invalid view type" do
      assert_raise ArgumentError, "Invalid view type: :invalid_type", fn ->
        View.new(:invalid_type, content: "Hello")
      end
    end

    test "handles invalid position values" do
      assert_raise ArgumentError,
                   "Position must be a tuple of two integers",
                   fn ->
                     View.new(:text, position: "invalid")
                   end

      assert_raise ArgumentError,
                   "Position must be a tuple of two integers",
                   fn ->
                     View.new(:text, position: {1, 2, 3})
                   end
    end

    test "handles invalid size values" do
      assert_raise ArgumentError,
                   "Size must be a tuple of two positive integers",
                   fn ->
                     View.new(:text, size: "invalid")
                   end

      assert_raise ArgumentError,
                   "Size must be a tuple of two positive integers",
                   fn ->
                     View.new(:text, size: {-1, 1})
                   end
    end
  end

  # N15 (flex rework Phase D): the `describe "layout/2"` and
  # `describe "flex layout features"` blocks that used to live here
  # exercised `View.layout/2`, which delegated to the now-deleted
  # `Raxol.Core.Renderer.Layout` coordinator (D5's "third stack",
  # production-dead -- see docs/proposals/in-flight/flex-spec-convergence.md).
  # Tests that pinned that dead pipeline's geometry were deleted along
  # with it. The four tests below exercised construction-time validation
  # (`Flex.container/1`'s direction check, `Border.wrap/2`, `Scroll.new/2`,
  # `View.shadow/1`) rather than layout math, so they survive, relocated
  # out of the deleted describe blocks. "handles invalid grid columns"
  # was deleted along with it: it exercised `View.grid`/`Grid.new`, which
  # were also production-dead (zero callers besides this test) and
  # deleted in the same pass.
  describe "construction-time validation" do
    test "handles invalid flex direction" do
      assert_raise ArgumentError, "Invalid flex direction: :invalid", fn ->
        View.flex direction: :invalid, size: {2, 1} do
          [View.text("A")]
        end
      end
    end

    test "handles invalid border style" do
      assert_raise ArgumentError, "Invalid border style: :invalid", fn ->
        View.border :invalid, size: {2, 1} do
          View.text("A")
        end
      end
    end

    test "handles invalid scroll offset" do
      assert_raise ArgumentError,
                   "errors were found at the given arguments:\n\n  * 1st argument: not a tuple\n",
                   fn ->
                     View.scroll_wrap offset: "invalid" do
                       View.text("A")
                     end
                   end
    end

    test "handles invalid shadow offset" do
      # View.shadow/1 returns a shadow map, it doesn't raise an error for invalid offset
      # The invalid offset gets converted to a default value
      shadow = View.shadow(offset: "invalid")
      # Default fallback value
      assert shadow.offset == {1, 1}
    end
  end

  describe "spacing normalization" do
    test "spacing normalization single integer becomes uniform spacing" do
      view = View.new(:box, padding: 2, margin: 1)
      assert view.padding == {2, 2, 2, 2}
      assert view.margin == {1, 1, 1, 1}
    end

    test "spacing normalization horizontal/vertical pair expands correctly" do
      view = View.new(:box, padding: {1, 2}, margin: {3, 4})
      assert view.padding == {1, 2, 1, 2}
      assert view.margin == {3, 4, 3, 4}
    end

    test "spacing normalization four-tuple remains unchanged" do
      view = View.new(:box, padding: {1, 2, 3, 4})
      assert view.padding == {1, 2, 3, 4}
    end

    test "handles invalid padding values" do
      assert_raise ArgumentError,
                   "Padding must be a positive integer or tuple",
                   fn ->
                     View.new(:box, padding: -1)
                   end

      assert_raise ArgumentError, "Invalid padding tuple length", fn ->
        View.new(:box, padding: {1, 2, 3})
      end
    end

    test "handles invalid margin values" do
      assert_raise ArgumentError,
                   "Margin must be a positive integer or tuple",
                   fn ->
                     View.new(:box, margin: -1)
                   end

      assert_raise ArgumentError, "Invalid margin tuple length", fn ->
        View.new(:box, margin: {1, 2, 3})
      end
    end
  end

end
