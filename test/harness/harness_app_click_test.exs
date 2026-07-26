defmodule Raxol.Harness.HarnessAppClickTest do
  @moduledoc """
  Click-to-fold (V's ruling: thinking blocks expand/collapse on click,
  active and completed), pinned through the REAL mouse path — the SGR
  press event `HarnessApp.update/2` receives from the pump:

    * a click on a SEALED reasoning block toggles its body open/closed
      (render-time lens; the frozen record never mutates — law 1);
    * a second click folds it back; a click on a pad row is a no-op;
    * a click on the streaming reasoning preview toggles peek ⇄ expanded;
    * releases and non-left buttons fold away silently.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.HarnessApp
  alias Raxol.Harness.HarnessApp.{Model, View}

  defp ev(id, type, payload) do
    %{
      id: id,
      turn_id: "t1",
      ts: 100 + id,
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  # A sealed transcript with ONE folded reasoning block (reveal_all seals
  # the completed turn) — the click target.
  defp sealed_reasoning_model do
    Model.build(width: 60, rows: 24)
    |> Model.fold_batch([
      {:event, ev(1, :turn_started, %{})},
      {:event,
       ev(2, :item_started, %{"item_id" => "i1", "item_type" => "reasoning"})},
      {:event,
       ev(3, :item_completed, %{
         "item_id" => "i1",
         "item_type" => "reasoning",
         "content" => "SECRET-THOUGHT-LINE-1\nSECRET-THOUGHT-LINE-2"
       })},
      {:event,
       ev(4, :item_completed, %{
         "item_id" => "i2",
         "item_type" => "message",
         "content" => "the reply"
       })},
      {:event, ev(5, :turn_completed, %{})}
    ])
  end

  # The LIVE wire shape: the pump normalizes every event, so a click
  # arrives as {:key, %{kind: :other, raw: %Event{type: :mouse}}} — the
  # envelope the first live defect hid behind (the bare-struct clause
  # matched fixtures, never the pump). A click is PRESS + RELEASE on the
  # same cell (release-at-same-cell is the acting edge — V's selection
  # ruling: a drag must never toggle).
  defp mouse(model, action, x, y) do
    event = %Event{
      type: :mouse,
      data: %{action: action, button: :left, x: x, y: y}
    }

    {m, []} =
      HarnessApp.update(
        {:key, Raxol.UI.Harness.InputEvent.normalize(event)},
        model
      )

    m
  end

  defp click(model, x, y) do
    model |> mouse(:press, x, y) |> mouse(:release, x, y)
  end

  defp reasoning_row(model) do
    # find the 1-based terminal row the ⁖ header renders on, via the same
    # row map the hit test uses — the test drives REAL coordinates
    cw = Model.content_width(model)

    rows =
      model
      |> View.render()
      |> flatten_rows()

    index = Enum.find_index(rows, &(&1 =~ "thought" or &1 =~ "thinking"))

    assert index != nil,
           "no thought/thinking header on screen:\n#{inspect(rows)}"

    index + 1
  end

  # flatten the rendered tree into physical-ish rows (column children of
  # the transcript + footer, in order) — good enough to locate a header
  defp flatten_rows(view) do
    view
    |> unwrap()
    |> Map.get(:children, [])
    |> Enum.flat_map(fn region -> Map.get(region, :children, []) end)
    |> Enum.map(&row_text/1)
  end

  defp unwrap(%{type: :box, children: [inner]}), do: inner
  defp unwrap(%{type: :absolute_layer, flow_child: inner}), do: unwrap(inner)
  defp unwrap(view), do: view

  defp row_text(%{type: :text, content: c}) when is_binary(c), do: c

  # the Indication container holds its subtree under :content
  defp row_text(%{type: :indication, content: c}) when is_binary(c), do: c
  defp row_text(%{type: :indication, content: c}), do: row_text(c)

  defp row_text(%{children: children}) when is_list(children),
    do: Enum.map_join(children, "", &row_text/1)

  defp row_text(_), do: ""

  defp screen_text(model),
    do: model |> View.render() |> flatten_rows() |> Enum.join("\n")

  test "a click on the sealed ⁖ header expands the thought; a second click folds it" do
    model = sealed_reasoning_model()

    # sealed folded: the body is hidden
    refute screen_text(model) =~ "SECRET-THOUGHT-LINE-1"

    row = reasoning_row(model)
    expanded = click(model, 3, row)

    assert screen_text(expanded) =~ "SECRET-THOUGHT-LINE-1"
    assert screen_text(expanded) =~ "SECRET-THOUGHT-LINE-2"

    # the frozen record itself never mutated (law 1) — only the lens
    assert expanded.transcript_records == model.transcript_records

    folded = click(expanded, 3, reasoning_row(expanded))
    refute screen_text(folded) =~ "SECRET-THOUGHT-LINE-1"
  end

  test "a click on a pad row is a no-op" do
    model = sealed_reasoning_model()
    clicked = click(model, 3, 1)

    assert clicked.record_fold == %{}
    assert screen_text(clicked) == screen_text(model)
  end

  test "a bare release (no press), a press alone, and a right-button press all stay inert" do
    model = sealed_reasoning_model()
    row = reasoning_row(model)

    # release with no armed press: nothing
    m1 = mouse(model, :release, 3, row)
    assert m1.record_fold == %{}

    # press alone arms but toggles nothing (the release is the acting edge)
    m2 = mouse(model, :press, 3, row)
    assert m2.record_fold == %{}
    assert m2.mouse_press == {3, row}

    {m3, []} =
      HarnessApp.update(
        {:key,
         %Event{
           type: :mouse,
           data: %{action: :press, button: :right, x: 3, y: row}
         }},
        model
      )

    assert m3.record_fold == %{}
  end

  test "press-drag-release (a selection attempt) never toggles — and disarms" do
    model = sealed_reasoning_model()
    row = reasoning_row(model)

    dragged = model |> mouse(:press, 3, row) |> mouse(:release, 20, row)
    assert dragged.record_fold == %{}
    assert dragged.mouse_press == nil
    refute screen_text(dragged) =~ "SECRET-THOUGHT-LINE-1"

    # a later clean click still works (the failed drag left no residue)
    clicked = click(dragged, 3, reasoning_row(dragged))
    assert screen_text(clicked) =~ "SECRET-THOUGHT-LINE-1"
  end

  test "a non-left release at the armed cell does not complete the click" do
    model = sealed_reasoning_model()
    row = reasoning_row(model)

    # left press arms the site ...
    armed = mouse(model, :press, 3, row)
    assert armed.mouse_press == {3, row}

    # ... but a RIGHT-button release on that same cell is not the user's
    # click (the arm is left-only), so it must not toggle the block.
    {released, []} =
      HarnessApp.update(
        {:key,
         %Event{
           type: :mouse,
           data: %{action: :release, button: :right, x: 3, y: row}
         }},
        armed
      )

    assert released.record_fold == %{}
    refute screen_text(released) =~ "SECRET-THOUGHT-LINE-1"
  end

  test "an unmodeled-button release is dropped, but the drop is logged" do
    import ExUnit.CaptureLog

    model = sealed_reasoning_model()
    row = reasoning_row(model)
    armed = mouse(model, :press, 3, row)

    # A wheel button-up is a release whose button is outside the completion
    # allowlist. It must not toggle the block -- but unlike the generic
    # catch-all fold, the drop is observable (a breadcrumb for a mystery
    # dead click), so we assert both the no-toggle AND the debug log.
    log =
      capture_log([level: :debug], fn ->
        {released, []} =
          HarnessApp.update(
            {:key,
             %Event{
               type: :mouse,
               data: %{action: :release, button: :wheel_up, x: 3, y: row}
             }},
            armed
          )

        send(self(), {:released, released})
      end)

    assert_received {:released, released}
    assert released.record_fold == %{}
    assert log =~ "dropped unrecognized mouse release"
    assert log =~ "wheel_up"
  end

  test "a resize between press and release cancels the click" do
    model = sealed_reasoning_model()
    row = reasoning_row(model)

    armed = mouse(model, :press, 3, row)
    assert armed.mouse_press == {3, row}

    # geometry moves under the armed cell ...
    {resized, []} =
      HarnessApp.update(
        %Event{type: :resize, data: %{width: 80, height: 30}},
        armed
      )

    assert resized.mouse_press == nil

    # ... so the release on the old coordinates resolves nothing (a stale
    # arm can no longer hit-test against the pre-resize layout).
    {released, []} =
      HarnessApp.update(
        {:key,
         %Event{
           type: :mouse,
           data: %{action: :release, button: :left, x: 3, y: row}
         }},
        resized
      )

    assert released.record_fold == %{}
  end

  test "hit_test/3 resolves the block render paints, off it resolves no block" do
    model = sealed_reasoning_model()
    row = reasoning_row(model)

    # Explicit hit_test/3 coverage (the finding noted it had none): the row
    # the ⁖ header renders on resolves to a block; a pad row does not. Both
    # read the SAME layout_geometry/1 solve render/1 paints from, so a
    # one-sided geometry edit can no longer drift a click off the paint.
    assert {:block, _block} = View.hit_test(model, 3, row)
    refute match?({:block, _}, View.hit_test(model, 3, 1))
  end

  test "a click on the streaming reasoning preview toggles peek ⇄ expanded" do
    lines = Enum.map_join(1..8, "\n", &"active thought line #{&1}")

    model =
      Model.build(width: 60, rows: 24, stream_open: true)
      |> Model.fold_batch([
        {:event, ev(1, :turn_started, %{})},
        {:event,
         ev(2, :item_started, %{"item_id" => "i1", "item_type" => "reasoning"})},
        {:event, ev(3, :item_delta, %{"item_id" => "i1", "chunk" => lines})}
      ])

    # peek: the early lines sit above the 3-line window
    refute screen_text(model) =~ "active thought line 1"
    assert screen_text(model) =~ "active thought line 8"

    # find the preview row and click it
    rows = model |> View.render() |> flatten_rows()
    preview_row = Enum.find_index(rows, &(&1 =~ "active thought line 8"))
    assert preview_row != nil

    expanded = click(model, 3, preview_row + 1)
    assert expanded.tail_expanded?
    assert screen_text(expanded) =~ "active thought line 1"

    collapsed = click(expanded, 3, preview_row + 1)
    refute collapsed.tail_expanded?
  end
end
