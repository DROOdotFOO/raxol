defmodule Raxol.UI.Layout.LayoutUtilsTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.{Engine, LayoutUtils, PreparedElement}

  describe "apply_padding/2 key preservation" do
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

      # apply_padding/2 must not drop extra keys like :prepared_cache.
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

  describe "prepared_cache propagation through the Flexbox path" do
    # Row-flex container with two text children. "AB" really measures to
    # width 2, but the prepared cache is seeded with a deliberately wrong
    # width (50) for "AB", so a correct cache-read is directly observable
    # in CD's x position.
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
      # CD's x equals AB's cached width (50), not the real width (2),
      # proving the cache reached the flex measurement path.
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

      # Cache absent or present-and-correct produce identical output
      # (behavior-neutral).
      assert without_cache == with_correct_cache

      ab = Enum.find(with_correct_cache, &(&1.text == "AB"))
      cd = Enum.find(with_correct_cache, &(&1.text == "CD"))

      assert ab.x == 0
      assert ab.y == 0
      assert cd.x == real_width
    end
  end
end
