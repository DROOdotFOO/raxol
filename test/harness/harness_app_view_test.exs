defmodule Raxol.Harness.HarnessAppViewTest do
  @moduledoc """
  U4 view/1: row-aware transcript windowing (the F0-perf lever + law 7
  follow/preserve), the honest-notice fit law (law 3), cursor park (law 6),
  and the full-viewport overlay gap-closer (overlays HOST as layout
  children, never refuse).
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.HarnessApp.{Model, View}
  alias Raxol.UI.Components.Harness.{Picker, TranscriptView}

  # collect every :text content in a tree (walks absolute_layer too)
  defp flatten_text(%{type: :text, content: c}) when is_binary(c), do: c

  defp flatten_text(%{} = el) do
    flow = el |> Map.get(:flow_child) |> List.wrap()
    overlays = el |> Map.get(:overlays, []) |> Enum.map(&Map.get(&1, :element))
    children = el |> Map.get(:children, []) |> List.wrap()
    (flow ++ children ++ overlays) |> Enum.map_join(" ", &flatten_text/1)
  end

  defp flatten_text(list) when is_list(list),
    do: Enum.map_join(list, " ", &flatten_text/1)

  defp flatten_text(_), do: ""

  # ── windowing (law 7 + perf) ────────────────────────────────────────────

  describe "TranscriptView row-aware windowing" do
    test "renders only the visible slice: 50 records at height 5 → 5 rows, newest at the bottom" do
      records = for i <- 1..50, do: {:marker, "line #{i}"}

      {:ok, state} =
        TranscriptView.init(
          records: records,
          height: 5,
          anchor: :tail,
          width: 40
        )

      el = TranscriptView.render(state, %{available_width: 40})

      contents = Enum.map(el.children, &Map.get(&1, :content))
      assert length(el.children) == 5
      assert "line 50" in contents
      refute "line 1" in contents
    end

    test "preserves a scrolled-back position: anchored at record 10 shows it, not the newest (law 7)" do
      records = for i <- 1..50, do: {:marker, "line #{i}"}

      {:ok, state} =
        TranscriptView.init(records: records, height: 3, anchor: 10, width: 40)

      el = TranscriptView.render(state, %{available_width: 40})

      contents = Enum.map(el.children, &Map.get(&1, :content))
      assert "line 10" in contents
      refute "line 50" in contents
    end

    test "pads the top when content is shorter than the height (content hugs the footer)" do
      {:ok, state} =
        TranscriptView.init(
          records: [{:marker, "only"}],
          height: 6,
          anchor: :tail,
          width: 40
        )

      el = TranscriptView.render(state, %{available_width: 40})
      assert length(el.children) == 6
      assert List.last(el.children).content == "only"
      assert hd(el.children).content == ""
    end
  end

  test "View.render puts only the windowed slice into the tree (the F0-perf pin)" do
    records = for i <- 1..40, do: {:marker, "m#{i}"}

    model = %{
      Model.build(width: 60, rows: 10)
      | transcript_records: Enum.reverse(records)
    }

    view = View.render(model)
    transcript = hd(view.children)

    in_tree =
      transcript.children
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&(&1 in [nil, ""]))

    assert in_tree != []
    assert length(in_tree) < 40
  end

  # ── the honest-notice fit law (law 3) ────────────────────────────────────

  test "a stub_notice survives a tight footer budget (protected channel, law 3)" do
    model = %{Model.build(width: 60, rows: 6) | stub_notice: "» heads up"}
    assert flatten_text(View.render(model)) =~ "heads up"
  end

  # ── cursor park (law 6) ──────────────────────────────────────────────────

  test "the composer edit point is declared on the view root, and advances as you type" do
    model = Model.build(width: 80, rows: 24)
    assert {_row, col, true} = View.render(model).cursor

    {typed, _} = Model.handle_key(model, Event.key_event("x", :pressed, []))
    assert {_row2, col2, true} = View.render(typed).cursor
    assert col2 > col
  end

  # ── overlay gap-closer (U3, now end-to-end) ──────────────────────────────

  describe "full-viewport overlays HOST as layout children (never refuse)" do
    test "an open picker wraps the tree in an AbsoluteLayer and withdraws the cursor" do
      {:ok, picker} = Picker.init(id: "p", items: ["a", "b"], key_fn: & &1)
      model = %{Model.build(width: 80, rows: 24) | overlay: {:picker, picker}}
      view = View.render(model)

      assert view.type == :absolute_layer
      refute Map.has_key?(view, :cursor)
    end

    test "an open panel hosts (does not refuse) in full-viewport" do
      model = %{Model.build(width: 80, rows: 24) | overlay: {:panel, :memory}}
      assert View.render(model).type == :absolute_layer
    end

    test "resize closes an overlay the new geometry can no longer host" do
      {:ok, picker} = Picker.init(id: "p", items: ["a"], key_fn: & &1)
      model = %{Model.build(width: 80, rows: 24) | overlay: {:picker, picker}}
      shrunk = Model.resize(model, 10, 3)
      assert shrunk.overlay == nil
    end
  end
end
