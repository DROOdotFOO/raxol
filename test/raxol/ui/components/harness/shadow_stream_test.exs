defmodule Raxol.UI.Components.Harness.ShadowStreamTest do
  @moduledoc """
  The shadow-stream primitive: a labeled, height-bounded, age-faded window
  over a live text stream, where the dominating primitive shares the
  faintest row. Pins the three states, the fade curves, the per-char
  shadow, and the click cycle.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.ShadowStream
  alias Raxol.Core.Runtime.Events.Bubbler
  alias Raxol.Core.Events.Event

  defp props(overrides) do
    Map.merge(
      %{primitive: "thinking", width: 40, id: "rs", on_click: {:cycle, "rs"}},
      Map.new(overrides)
    )
  end

  # Flatten every text node's {content, fg}. Descends both :children
  # (containers) and :content (the indication node's body is a map there).
  defp leaves(%{type: :text} = n), do: [{n.content, n[:fg]}]

  defp leaves(node) when is_map(node) do
    from_content =
      case node[:content] do
        c when is_map(c) -> leaves(c)
        _ -> []
      end

    from_children =
      case node[:children] do
        kids when is_list(kids) -> Enum.flat_map(kids, &leaves/1)
        _ -> []
      end

    from_content ++ from_children
  end

  defp leaves(_), do: []

  defp texts(node), do: node |> leaves() |> Enum.map(&elem(&1, 0))
  defp gray(nil), do: nil
  defp gray("#" <> hex), do: hex |> String.slice(0, 2) |> String.to_integer(16)

  describe "the dominating primitive is the through-line" do
    for state <- [:fully_collapsed, :peek, :expanded] do
      test "#{state}: the primitive is always rendered" do
        view =
          ShadowStream.render(props(%{lines: ["a", "b", "c"], state: unquote(state)}))

        assert Enum.any?(texts(view), &String.contains?(&1, "thinking"))
      end
    end

    test "the primitive is translatable / word-agnostic" do
      view = ShadowStream.render(props(%{primitive: "searching", lines: ["x"], state: :peek}))
      assert Enum.any?(texts(view), &String.contains?(&1, "searching"))
      refute Enum.any?(texts(view), &String.contains?(&1, "thinking"))
    end
  end

  describe ":fully_collapsed — only the primitive" do
    test "renders exactly the collapsed icon + primitive, nothing else" do
      view = ShadowStream.render(props(%{lines: ["a", "b", "c"], state: :fully_collapsed}))
      assert texts(view) == ["▸ thinking"]
    end
  end

  describe ":peek build-up (< height lines) — age gradient, primitive owns a row" do
    test "primitive at base, older line dimmer, newest at base (0.6 / 0.4 / 0.6)" do
      view = ShadowStream.render(props(%{lines: ["first", "second"], state: :peek}))
      [{"thinking", label_fg}, {"first", old_fg}, {"second", new_fg}] = leaves(view)

      # newest line matches the primitive's base prominence; older is dimmer.
      assert new_fg == label_fg
      assert gray(old_fg) < gray(new_fg)
    end
  end

  describe ":peek squeeze (>= height) — the shadow row" do
    test "row 0 folds the primitive with the oldest line; rows below fade by age" do
      lines = ["oldest one", "middle one", "newest one"]
      view = ShadowStream.render(props(%{lines: lines, state: :peek}))
      [shadow, mid, new] = view.children

      # shadow row is a :row whose first child is the primitive at base.
      assert %{type: :row} = shadow
      assert [%{type: :text, content: "thinking"} | _] = shadow.children

      # the two lower rows: middle dimmer than newest; newest == base.
      assert %{content: "middle one", fg: mid_fg} = mid
      assert %{content: "newest one", fg: new_fg} = new
      assert gray(mid_fg) < gray(new_fg)
    end

    test "the oldest line's tail fades in left->right, prefix consumed to …" do
      # a line far longer than the region so the prefix must be consumed.
      long = String.duplicate("word ", 30)
      view = ShadowStream.render(props(%{lines: [long, "b", "c"], state: :peek, width: 30}))
      shadow = hd(view.children)
      # drop primitive + gap; the rest are the faded tail spans.
      tail = Enum.drop(shadow.children, 2)

      # prefix consumed marker present and faintest.
      assert [%{content: "…", fg: first_fg} | _] = tail
      last_fg = tail |> List.last() |> Map.get(:fg)

      # monotonic fade-in: the tail brightens toward the right.
      assert gray(first_fg) < gray(last_fg)

      # the fade never exceeds the shadow cap (~0.4), staying below the
      # newest line's base prominence.
      base_fg = view.children |> List.last() |> Map.get(:fg)
      assert gray(last_fg) <= gray(base_fg)
    end
  end

  describe ":expanded — full contents, bracketed via the indication primitive" do
    test "a header row plus a ∵…∴ indication bracket over every line" do
      lines = ["l1", "l2", "l3"]
      view = ShadowStream.render(props(%{lines: lines, state: :expanded}))
      [header, bracket] = view.children

      assert %{type: :text, content: "▾ thinking"} = header
      assert %{type: :indication, gutter: {:corners, "∵", "∴"}} = bracket
      # the full contents are present (not windowed).
      assert Enum.all?(lines, fn l -> Enum.any?(texts(view), &(&1 == l)) end)
    end
  end

  describe "clicks cycle the state (the Bubbler seam)" do
    test "a click at the root resolves to the on_click message" do
      view = ShadowStream.render(props(%{lines: ["a", "b", "c"], state: :peek}))
      event = %Event{type: :click, data: %{}}

      assert {:handled, {:message, {:cycle, "rs"}}} =
               Bubbler.bubble(event, view, "rs", %{})
    end

    test "the root carries the id + on_click so the click is routable" do
      view = ShadowStream.render(props(%{lines: ["a"], state: :peek}))
      assert view.id == "rs"
      assert view.on_click == {:cycle, "rs"}
    end
  end
end
