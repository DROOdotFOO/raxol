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

  # The root is the frame-inset box wrapping `[transcript, footer]`
  # (View.render/1 `frame/2`); unwrap it, then split the two so a test can
  # assert WHICH region a widget landed in.
  defp unframe(%{type: :box, id: "harness-frame", children: [inner]}),
    do: inner

  defp unframe(view), do: view

  defp body_and_footer(view) do
    [body, footer | _] = unframe(view).children
    {flatten_text(body), flatten_text(footer)}
  end

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
    transcript = view |> unframe() |> Map.fetch!(:children) |> hd()

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

  # ── the footer preview channel (U6-shadow) ─────────────────────────────

  # Events flow through the REAL fold (Model.fold_batch/2) so the
  # projection builds real blocks/tails -- the preview assertions then
  # cover the same shapes the live pump will deliver.
  defp loop_ev(id, turn_id, ts, type, payload, opts \\ []) do
    %{
      id: id,
      turn_id: turn_id,
      ts: ts,
      family: :loop,
      type: type,
      tier: Keyword.get(opts, :tier, :durable),
      payload: payload
    }
  end

  defp stream_model(items) do
    Model.build(width: 60, rows: 24, stream_open: true)
    |> Model.fold_batch(Enum.map(items, &{:event, &1}))
  end

  describe "the footer preview channel (U6-shadow parity with the shelved surface)" do
    test "streaming reasoning renders as the ShadowStream peek window" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "weighing the tradeoffs"
          })
        ])

      text = flatten_text(View.render(model))
      assert text =~ "thinking"
      assert text =~ "weighing the tradeoffs"
      refute text =~ "❮ …streaming…"
    end

    test "streaming answer text keeps the plain » preview" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "message"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "drafting the reply"
          })
        ])

      assert flatten_text(View.render(model)) =~ "» drafting the reply"
    end

    test "a pending completed block outranks the live tail" do
      # The completed message sits pending (turn still running, stream
      # open -- the frontier holds it), so the preview shows the BLOCK,
      # not the reasoning tail still accumulating behind it.
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "message"
          }),
          loop_ev(3, "t1", 120, :item_completed, %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => "BLOCKTEXT"
          }),
          loop_ev(4, "t1", 130, :item_started, %{
            "item_id" => "i2",
            "item_type" => "reasoning"
          }),
          loop_ev(5, "t1", 140, :item_delta, %{
            "item_id" => "i2",
            "chunk" => "TAILTEXT"
          })
        ])

      text = flatten_text(View.render(model))
      assert text =~ "BLOCKTEXT"
      refute text =~ "TAILTEXT"
    end

    test "an open overlay suppresses the preview entirely (the suppressed-preview law)" do
      model =
        [
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "weighing the tradeoffs"
          })
        ]
        |> stream_model()

      overlaid = %{model | overlay: {:panel, :memory}}
      refute flatten_text(View.render(overlaid)) =~ "thinking"
    end
  end

  describe "a live approval renders its diff INLINE in the body, not the footer" do
    # The canonical layout: the diff is the SPECIAL TOOL RENDER, in the main
    # log (body) -- not a footer preview clipped to 2 rows. A live edit
    # approval carrying old/new must show its full ± Pierre diff in the
    # transcript and NOT in the footer.
    test "the ± diff shows in the transcript body, never the footer" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :approval_requested, %{
            "request_id" => "appr-1",
            "tool_name" => "edit_file",
            "action" => "edit_file",
            "path" => "mix.exs",
            "old" => "keep-a\nOLDLINE\nkeep-b\n",
            "new" => "keep-a\nNEWLINE\nkeep-b\n",
            "language" => "elixir",
            "preview_match" => "exact",
            "diff" => true,
            "options" => [
              %{
                "option_id" => "allow",
                "name" => "Allow",
                "kind" => "allow_once"
              },
              %{
                "option_id" => "deny",
                "name" => "Deny",
                "kind" => "reject_once"
              }
            ]
          })
        ])

      {body, footer} = body_and_footer(View.render(model))

      # the ± diff BODY lands in the transcript (the special tool render)
      assert body =~ "± mix.exs", "the ± diff header must render in the body"
      assert body =~ "OLDLINE", "the removed line must render in the body"
      assert body =~ "NEWLINE", "the added line must render in the body"

      # ... and NOT in the footer (no clipped 2-line stub, no double-render)
      refute footer =~ "± mix.exs", "the diff must NOT render in the footer"
      refute footer =~ "OLDLINE", "the diff body must NOT render in the footer"
    end
  end
end
