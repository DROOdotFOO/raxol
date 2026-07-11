defmodule Raxol.UI.Layout.LayoutUtilsTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.{Engine, LayoutUtils, PreparedElement}

  describe "apply_padding/2 key preservation (N3 cache-drop fix)" do
    test "preserves arbitrary extra keys (e.g. :prepared_cache) on the space map" do
      space = %{
        x: 10,
        y: 10,
        width: 100,
        height: 50,
        prepared_cache: %{{:text, 123} => {5, 1}},
        some_other_key: :untouched
      }

      padding = %{top: 5, right: 10, bottom: 5, left: 10}

      result = LayoutUtils.apply_padding(space, padding)

      # Geometry is still adjusted correctly.
      assert result.x == 20
      assert result.y == 15
      assert result.width == 80
      assert result.height == 40

      # Every other key on the incoming space map survives untouched -- this
      # is the actual bug: the old implementation returned a fresh literal
      # map containing only x/y/width/height and silently dropped
      # everything else, notably :prepared_cache (the Preparer
      # text-measurement cache threaded through layout by
      # Engine.apply_layout).
      assert result.prepared_cache == %{{:text, 123} => {5, 1}}
      assert result.some_other_key == :untouched
    end

    test "matches the documented example with only geometry keys present" do
      space = %{x: 10, y: 10, width: 100, height: 50}
      padding = %{top: 5, right: 10, bottom: 5, left: 10}

      assert LayoutUtils.apply_padding(space, padding) == %{
               x: 20,
               y: 15,
               width: 80,
               height: 40
             }
    end

    test "clamps width/height at zero when padding exceeds available space" do
      space = %{x: 0, y: 0, width: 4, height: 4, prepared_cache: %{}}
      padding = %{top: 10, right: 10, bottom: 10, left: 10}

      result = LayoutUtils.apply_padding(space, padding)

      assert result.width == 0
      assert result.height == 0
      assert result.prepared_cache == %{}
    end
  end

  describe "prepared_cache propagation through the Flexbox path (regression for the key-drop bug)" do
    # A row-direction flex container with two plain text children. "AB"
    # really measures to width 2 (ASCII, single-width glyphs), but we seed
    # the prepared cache with a deliberately wrong width (50) for "AB".
    #
    # Before the fix, `Flexbox.apply_padding/2` -> `LayoutUtils.apply_padding/2`
    # dropped :prepared_cache from the content space handed to
    # `measure_flex_child/3`, so `Engine.measure_element/2` would always miss
    # the cache lookup (engine.ex:689) and fall back to real
    # `TextMeasure.display_width/1`, producing width 2 for "AB" regardless
    # of what the cache said.
    #
    # After the fix, the (deliberately wrong) cached width of 50 survives
    # `apply_padding` and is read back inside the flex measurement path,
    # which is directly observable in the resulting x position of the
    # second child.
    defp two_text_flex_view do
      %{
        type: :flex,
        direction: :row,
        gap: 0,
        padding: 0,
        children: [
          %{type: :text, content: "AB"},
          %{type: :text, content: "CD"}
        ]
      }
    end

    test "a wrong-but-cached width for a flex child is consulted during flex sizing" do
      dimensions = %{width: 200, height: 10}

      prepared = %PreparedElement{
        type: :text,
        content_hash: :erlang.phash2("AB"),
        measured_width: 50,
        measured_height: 1,
        children: nil
      }

      positioned =
        Engine.apply_layout(two_text_flex_view(), dimensions, prepared)

      ab = Enum.find(positioned, &(&1.text == "AB"))
      cd = Enum.find(positioned, &(&1.text == "CD"))

      refute is_nil(ab)
      refute is_nil(cd)

      assert ab.x == 0
      # CD is placed immediately after AB on the main axis with no gap. Its
      # x therefore equals AB's (cached) measured width -- 50, not the real
      # width of 2 -- proving the cache reached Engine.measure_element
      # through the flex measurement path.
      assert cd.x == 50
    end

    test "geometry is unchanged whether or not a prepared cache is supplied, when the cache matches reality (behavior-neutral)" do
      dimensions = %{width: 200, height: 10}

      real_width = Raxol.UI.TextMeasure.display_width("AB")

      without_cache = Engine.apply_layout(two_text_flex_view(), dimensions, nil)

      with_correct_cache =
        Engine.apply_layout(two_text_flex_view(), dimensions, %PreparedElement{
          type: :text,
          content_hash: :erlang.phash2("AB"),
          measured_width: real_width,
          measured_height: 1,
          children: nil
        })

      # No crash in either mode, and identical output: whether the cache is
      # absent (falls back to real measurement) or present-and-correct
      # (reads the cache), the observable layout is the same. This is the
      # behavior-neutrality guarantee for what is otherwise a pure caching
      # optimization.
      assert without_cache == with_correct_cache

      ab = Enum.find(with_correct_cache, &(&1.text == "AB"))
      cd = Enum.find(with_correct_cache, &(&1.text == "CD"))

      # Pinned geometry values -- verified identical before and after the
      # apply_padding fix (confirmed manually by toggling the Map.merge in
      # lib/raxol/ui/layout/layout_utils.ex off and re-running this test).
      assert ab.x == 0
      assert ab.y == 0
      assert cd.x == real_width
    end
  end
end
