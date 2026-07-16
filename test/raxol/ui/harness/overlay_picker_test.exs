defmodule Raxol.UI.Harness.OverlayPickerTest do
  @moduledoc """
  Pure-component suite for `Raxol.UI.Harness.OverlayPicker` -- the
  footer-region overlay picker primitive (filter query, selection,
  visible-window math, fixed claimed height). No device, no process, no
  authority: every test drives the pure `new/2` / `handle_key/2` /
  `render/1` / `matches/1` / `height/1` API with events normalized by the
  REAL `Raxol.UI.Harness.InputEvent.normalize/1`, never hand-built maps.

  Footer composition / keymap-priority live in their own suites
  (`test/harness/overlay_picker_surface_test.exs`,
  `test/raxol/ui/harness/keymap_test.exs`).
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface.ViewText
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.Harness.OverlayPicker
  alias Raxol.UI.TextMeasure

  # -- helpers -----------------------------------------------------------

  defp key(picker, key_or_char) do
    OverlayPicker.handle_key(
      picker,
      InputEvent.normalize(Event.key(key_or_char))
    )
  end

  defp continue!(result) do
    assert {:continue, picker} = result
    picker
  end

  defp type(picker, string) do
    string
    |> String.graphemes()
    |> Enum.reduce(picker, fn ch, p -> continue!(key(p, ch)) end)
  end

  # Item rows of the rendered view map: every child after the query row,
  # as `{content, style}` pairs.
  defp rendered_rows(picker) do
    %{type: :column, children: [_query_row | item_rows]} =
      OverlayPicker.render(picker)

    Enum.map(item_rows, fn %{type: :text} = node ->
      {node.content, Map.get(node, :style, %{})}
    end)
  end

  defp query_row(picker) do
    %{type: :column, children: [%{type: :text, content: content} | _rest]} =
      OverlayPicker.render(picker)

    content
  end

  # -- construction and filtering ---------------------------------------

  describe "new/2 and matches/1" do
    test "empty query matches every item, in order" do
      picker = OverlayPicker.new(["alpha", "beta", "gamma"])
      assert OverlayPicker.matches(picker) == ["alpha", "beta", "gamma"]
    end

    test "filtering is case-insensitive substring" do
      picker = OverlayPicker.new(["Alpha", "beta", "alphabet"])
      picker = type(picker, "ALPH")
      assert OverlayPicker.matches(picker) == ["Alpha", "alphabet"]
    end

    test "label_fn derives the search key for non-string items" do
      items = [%{id: 1, name: "session one"}, %{id: 2, name: "run two"}]
      picker = OverlayPicker.new(items, label_fn: & &1.name)
      picker = type(picker, "two")
      assert OverlayPicker.matches(picker) == [%{id: 2, name: "run two"}]
    end

    test "CJK query filters CJK labels (grapheme-safe, no byte matching)" do
      picker = OverlayPicker.new(["日本語セッション", "english session"])
      picker = type(picker, "日本")
      assert OverlayPicker.matches(picker) == ["日本語セッション"]
    end

    test "the filter is a seam: a custom filter_fn replaces substring matching" do
      exact = fn query, items, label_fn ->
        Enum.filter(items, &(label_fn.(&1) == query))
      end

      picker = OverlayPicker.new(["ab", "abc"], filter_fn: exact)
      picker = type(picker, "ab")
      assert OverlayPicker.matches(picker) == ["ab"]
    end
  end

  # -- fixed claimed height ----------------------------------------------

  describe "height/1 -- the rows the overlay claims, fixed at open" do
    test "query row + one row per item, capped at max_visible" do
      assert OverlayPicker.height(OverlayPicker.new(["a", "b", "c"])) == 4

      assert OverlayPicker.height(
               OverlayPicker.new(Enum.map(1..20, &"item #{&1}"))
             ) == 9

      assert OverlayPicker.height(
               OverlayPicker.new(Enum.map(1..20, &"item #{&1}"),
                 max_visible: 3
               )
             ) == 4
    end

    test "zero items still claims a query row plus one (no-matches) row" do
      assert OverlayPicker.height(OverlayPicker.new([])) == 2
    end

    test "narrowing the query does NOT shrink the claimed height (no per-keystroke re-pin churn)" do
      picker = OverlayPicker.new(["alpha", "beta", "gamma"])
      h = OverlayPicker.height(picker)
      picker = type(picker, "alp")
      assert OverlayPicker.matches(picker) == ["alpha"]
      assert OverlayPicker.height(picker) == h
    end
  end

  # -- query editing ------------------------------------------------------

  describe "query editing" do
    test "printable chars append to the query and reset selection/offset" do
      picker =
        OverlayPicker.new(Enum.map(1..10, &"item #{&1}"), max_visible: 3)

      picker =
        Enum.reduce(1..5, picker, fn _n, p -> continue!(key(p, :down)) end)

      assert picker.selected == 5
      assert picker.offset > 0

      picker = type(picker, "1")
      assert picker.query == "1"
      assert picker.selected == 0
      assert picker.offset == 0
    end

    test "backspace removes the last grapheme (whole CJK grapheme, not a byte)" do
      picker = OverlayPicker.new(["日本語"])
      picker = type(picker, "日本")
      picker = continue!(key(picker, :backspace))
      assert picker.query == "日"
      picker = continue!(key(picker, :backspace))
      assert picker.query == ""
      # backspace on an empty query stays open, still empty
      picker = continue!(key(picker, :backspace))
      assert picker.query == ""
    end

    test "modified chars (ctrl/alt/meta) are not text and do not touch the query" do
      picker = OverlayPicker.new(["a"])

      norm =
        InputEvent.normalize(Event.key_event("a", :pressed, [:ctrl]))

      picker = continue!(OverlayPicker.handle_key(picker, norm))
      assert picker.query == ""
    end
  end

  # -- selection and window math -----------------------------------------

  describe "selection + visible-window math" do
    test "down/up move the selection, clamped to the match list" do
      picker = OverlayPicker.new(["a", "b", "c"])
      picker = continue!(key(picker, :up))
      assert picker.selected == 0

      picker =
        Enum.reduce(1..5, picker, fn _n, p -> continue!(key(p, :down)) end)

      assert picker.selected == 2
    end

    test "the window follows the selection past the visible edge" do
      picker =
        OverlayPicker.new(Enum.map(1..10, &"item #{&1}"), max_visible: 3)

      # moving down past the 3-row window scrolls the offset
      picker =
        Enum.reduce(1..4, picker, fn _n, p -> continue!(key(p, :down)) end)

      assert picker.selected == 4
      assert picker.offset == 2

      # moving back up above the window pulls the offset back
      picker =
        Enum.reduce(1..4, picker, fn _n, p -> continue!(key(p, :up)) end)

      assert picker.selected == 0
      assert picker.offset == 0
    end

    test "selection is clamped when the query narrows the matches under it" do
      picker = OverlayPicker.new(["aa", "ab", "b"])

      picker =
        Enum.reduce(1..2, picker, fn _n, p -> continue!(key(p, :down)) end)

      assert picker.selected == 2
      picker = type(picker, "a")
      assert picker.selected == 0
      assert length(OverlayPicker.matches(picker)) == 2
    end
  end

  # -- commit / dismiss ---------------------------------------------------

  describe "Enter commits, ESC dismisses" do
    test "Enter yields {:picked, item} for the current selection" do
      picker = OverlayPicker.new(["alpha", "beta", "gamma"])
      picker = continue!(key(picker, :down))
      assert key(picker, :enter) == {:picked, "beta"}
    end

    test "Enter with the filtered selection, not the raw index" do
      picker = OverlayPicker.new(["alpha", "beta", "gamma"])
      picker = type(picker, "gam")
      assert key(picker, :enter) == {:picked, "gamma"}
    end

    test "Enter on zero matches is a no-op continue, never a crash or a pick" do
      picker = OverlayPicker.new(["alpha"])
      picker = type(picker, "zzz")
      assert OverlayPicker.matches(picker) == []
      assert {:continue, _picker} = key(picker, :enter)
    end

    test "ESC yields :dismissed (host-agnostic; the Surface captures ESC in the keymap first)" do
      picker = OverlayPicker.new(["alpha"])
      assert key(picker, :escape) == :dismissed
    end

    test "unbound special keys are a no-op continue" do
      picker = OverlayPicker.new(["alpha"])
      assert {:continue, _picker} = key(picker, :home)
    end
  end

  # -- render: exact row accounting ---------------------------------------

  describe "render/1 -- fixed row accounting for the footer budget" do
    test "renders exactly height-1 item rows plus the query row, padding with blanks" do
      picker = OverlayPicker.new(["a", "b"], max_visible: 4)
      # height = 1 + 2 = 3 -> two item rows, no padding needed
      assert length(rendered_rows(picker)) == OverlayPicker.height(picker) - 1

      picker = type(picker, "a")
      rows = rendered_rows(picker)
      assert length(rows) == OverlayPicker.height(picker) - 1
      # the second row is blank padding once the filter narrows to one match
      assert {"", _style} = List.last(rows)
    end

    test "the query row shows the typed query" do
      picker = OverlayPicker.new(["alpha"], title: "sessions")
      picker = type(picker, "alp")
      row = query_row(picker)
      assert row =~ "sessions"
      assert row =~ "alp"
    end

    test "the selected row carries the selection marker; others do not" do
      picker = OverlayPicker.new(["a", "b", "c"])
      picker = continue!(key(picker, :down))

      markers =
        picker
        |> rendered_rows()
        |> Enum.map(fn {content, _style} ->
          String.starts_with?(content, "▸")
        end)

      assert markers == [false, true, false]
    end

    test "zero matches renders a visible no-matches row, not silent blanks" do
      picker = OverlayPicker.new(["alpha"])
      picker = type(picker, "zzz")
      [{first, _style} | _rest] = rendered_rows(picker)
      assert first =~ "no matches"
    end

    test "embedded newlines in labels are flattened -- one item is always ONE footer row" do
      picker = OverlayPicker.new(["line one\nline two"])
      rows = rendered_rows(picker)
      assert length(rows) == 1
      {content, _style} = hd(rows)
      refute String.contains?(content, "\n")
      assert content =~ "line one"
      assert content =~ "line two"

      # and through the real ViewText bridge the whole overlay still
      # flattens to exactly height/1 lines -- the row-accounting contract
      # the Surface's footer budget depends on.
      lines = ViewText.lines(OverlayPicker.render(picker), 40, :plain)
      assert length(lines) == OverlayPicker.height(picker)
    end

    test "CJK labels flow through ViewText width truncation -- no line exceeds the display-width budget" do
      width = 12

      picker =
        OverlayPicker.new(["日本語のセッションラベルがとても長い", "short"])

      lines = ViewText.lines(OverlayPicker.render(picker), width, :plain)
      assert length(lines) == OverlayPicker.height(picker)

      for line <- lines do
        assert TextMeasure.display_width(line) <= width,
               "overlay line #{inspect(line)} exceeds #{width} display columns"
      end
    end
  end
end
