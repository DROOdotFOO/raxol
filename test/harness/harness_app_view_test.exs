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

    # the law containers hold their subtree under :content; emulate the
    # gutter glyph so painted-string pins read as on screen
    {gutter_prefix, content} =
      case el do
        %{type: :indication, content: c} ->
          {case Map.get(el, :gutter) do
             {:top, g} when is_binary(g) -> [g]
             {:corners, g, b} -> Enum.filter([g, b], &is_binary/1)
             {:rule, g} when is_binary(g) -> [g]
             _ -> []
           end, List.wrap(c)}

        %{type: :indentation_exception, content: c} ->
          {[], List.wrap(c)}

        _ ->
          {[], []}
      end

    (gutter_prefix ++ flow ++ children ++ content ++ overlays)
    |> Enum.map_join(" ", &flatten_text/1)
  end

  defp flatten_text(g) when is_binary(g), do: g

  defp flatten_text(list) when is_list(list),
    do: Enum.map_join(list, " ", &flatten_text/1)

  defp flatten_text(_), do: ""

  # The root is the frame-inset box wrapping `[transcript, footer]`
  # (View.render/1 `frame/2`); unwrap it, then split the two so a test can
  # assert WHICH region a widget landed in.
  defp unframe(%{type: :box, id: "harness-frame", children: [inner]}),
    do: inner

  defp unframe(view), do: view

  defp unwrap_frame(view), do: unframe(view)

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

      contents = Enum.map(el.children, &row_content/1)
      assert length(el.children) == 5
      assert "line 50" in contents
      refute "line 1" in contents
    end

    test "preserves a scrolled-back position: anchored at record 10 shows it, not the newest (law 7)" do
      records = for i <- 1..50, do: {:marker, "line #{i}"}

      {:ok, state} =
        TranscriptView.init(records: records, height: 3, anchor: 10, width: 40)

      el = TranscriptView.render(state, %{available_width: 40})

      contents = Enum.map(el.children, &row_content/1)
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
      assert row_content(List.last(el.children)) == "only"
      assert row_content(hd(el.children)) == ""
    end
  end

  # a record row under the law is an Indication whose content carries the
  # text node; window PADS stay bare text
  defp row_content(%{type: :indication, content: %{content: c}}), do: c
  defp row_content(%{content: c}) when is_binary(c), do: c
  defp row_content(_), do: nil

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
      |> Enum.map(&row_content/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    assert in_tree != []
    assert length(in_tree) < 40
  end

  # ── the greeting placement (V's one-above-the-chevron ruling) ──────────

  describe "the idle greeting" do
    test "sits on the LAST transcript row and the composer separator yields — one line above the chevron" do
      model = Model.build(width: 80, rows: 24, greeting?: true)
      view = View.render(model)
      [transcript, footer | _] = unframe(view).children

      assert List.last(transcript.children).content ==
               "welcome back, operator"

      # separator suppressed: the footer's first fitted row IS the composer
      # sigil row (a :row), not a blank spacer line
      assert [first | _] = footer.children
      refute match?(%{type: :text, content: ""}, first)
    end

    test "renders at low prominence: dim + a faded fg, never full-weight" do
      model = Model.build(width: 80, rows: 24, greeting?: true)
      view = View.render(model)
      [transcript | _] = unframe(view).children
      greeting = List.last(transcript.children)

      assert greeting.attrs[:style] == [:dim]

      assert is_binary(greeting.attrs[:fg]) and
               String.starts_with?(greeting.attrs[:fg], "#")
    end

    test "the separator returns once history exists" do
      model = %{
        Model.build(width: 80, rows: 24, greeting?: true)
        | transcript_records: [{:marker, "m"}]
      }

      view = View.render(model)
      [_transcript, footer | _] = unframe(view).children

      assert Enum.any?(
               footer.children,
               &match?(%{type: :text, content: ""}, &1)
             )
    end
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

    test "a streaming REASONING delta resolves its type from the tail: bare spinner, never 'responding'" do
      # The end-to-end half of V's ruling: delta payloads carry no
      # item_type; Model.update_status resolves it from the projection
      # tail, so the strip gets a POSITIVE :reasoning and yields the
      # word entirely (the ShadowStream tail shows the live thinking).
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "mid-thought"
          })
        ])

      assert model.status.last_item_type == :reasoning
      assert Raxol.Harness.StatusStrip.phase_value(model.status) == ""

      refute flatten_text(View.render(model)) =~ "responding"
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

      {body, footer} = body_and_footer(View.render(model))
      assert footer =~ "BLOCKTEXT"
      # the live thought now rides the BODY as its ∵ record — only the
      # FOOTER must prefer the pending block over the tail
      refute footer =~ "TAILTEXT"
      assert body =~ "TAILTEXT"
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
      view = View.render(overlaid)

      # the law moved the live thought into the BODY (its ∵ record may
      # render under the overlay backdrop); the suppressed-preview law
      # now guards the FOOTER channel specifically
      %{flow_child: base} = view
      [_transcript, footer | _] = unwrap_frame(base).children
      refute flatten_text(footer) =~ "thinking"
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

      # the ± diff BODY lands in the transcript (the special tool render);
      # its identity line is the bottom `± <verb> <path>` form (V's
      # bottom-identity ruling -- no `⚑ edit_file` header row above it)
      assert body =~ "± edit mix.exs",
             "the ± identity line must render in the body"

      assert body =~ "OLDLINE", "the removed line must render in the body"
      assert body =~ "NEWLINE", "the added line must render in the body"

      # ... and NOT in the footer (no clipped 2-line stub, no double-render)
      refute footer =~ "± edit mix.exs",
             "the diff must NOT render in the footer"

      refute footer =~ "OLDLINE", "the diff body must NOT render in the footer"
    end

    test "the footer becomes the ChoicePrompt: option rows from the REAL names + the free-text way" do
      model = live_approval_model()
      {_body, footer} = body_and_footer(View.render(model))

      # the chevron pair carries the block's real option names + key hints
      assert footer =~ "Allow"
      assert footer =~ "[enter]"
      assert footer =~ "Deny"
      assert footer =~ "[escape]"
      # the third way idles as the quiet placeholder
      assert footer =~ "explain what to do instead"
    end

    test "the strip's redundant `awaiting approval` line yields to the selector (V's ruling)" do
      model = live_approval_model()
      text = flatten_text(View.render(model))

      refute text =~ "awaiting approval",
             "the strip's awaiting-approval phase line is redundant next to the selector"
    end

    test "the body drops its in-body option list when the footer prompt hosts the answer" do
      model = live_approval_model()
      {body, _footer} = body_and_footer(View.render(model))

      # the question stays (the ± diff), the answer affordance moves to the
      # footer ChoicePrompt -- no double render of the option list
      refute body =~ "answer:",
             "the in-body answer hint must yield to the footer prompt"

      refute body =~ "[1] Allow",
             "the in-body numbered options must yield to the footer prompt"
    end

    test "no choice prompt without a live approval — the plain composer chevron returns" do
      model = stream_model([loop_ev(1, "t1", 100, :turn_started, %{})])
      {_body, footer} = body_and_footer(View.render(model))

      refute footer =~ "[enter]"
      refute footer =~ "explain what to do instead"
    end

    defp live_approval_model do
      stream_model([
        loop_ev(1, "t1", 100, :turn_started, %{}),
        loop_ev(2, "t1", 110, :approval_requested, %{
          "request_id" => "appr-2",
          "tool_name" => "edit_file",
          "action" => "edit_file",
          "path" => "mix.exs",
          "old" => "a\n",
          "new" => "b\n",
          "options" => [
            %{
              "option_id" => "allow",
              "name" => "Allow",
              "kind" => "allow_once"
            },
            %{"option_id" => "deny", "name" => "Deny", "kind" => "reject_once"}
          ]
        })
      ])
    end
  end

  # ── THE TRANSCRIPT LAW (V's general rule) ────────────────────────────────

  describe "the indication law: every record is an Indication or a declared exception" do
    defp law_compliant?(%{type: :indication}), do: true
    defp law_compliant?(%{type: :indentation_exception}), do: true

    defp law_compliant?(%{type: type, children: children})
         when type in [:column, :approval_prompt],
         do: Enum.all?(children, &law_compliant?/1)

    defp law_compliant?(_node), do: false

    test "every record kind renders law-compliant: blocks, markers, echoes, live thinking" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 115, :item_completed, %{
            "item_id" => "i1",
            "item_type" => "reasoning",
            "content" => "done thought"
          }),
          loop_ev(4, "t1", 120, :item_started, %{
            "item_id" => "i2",
            "item_type" => "reasoning"
          }),
          loop_ev(5, "t1", 125, :item_delta, %{
            "item_id" => "i2",
            "chunk" => "live thought line"
          })
        ])

      model =
        model
        |> Model.seal_marker("» a machinery notice")
        |> Model.seal_marker("plain marker")

      model = %{
        model
        | transcript_records: [{:echo, "user words"} | model.transcript_records]
      }

      view = View.render(model)
      [transcript | _] = unframe(view).children

      # every non-pad row of the window is law-compliant
      for child <- transcript.children,
          not match?(%{type: :text, content: ""}, child) do
        assert law_compliant?(child),
               "record violated the indication law: #{inspect(child, limit: 8)}"
      end
    end

    test "the ACTIVE thought is a ∵-cornered Indication record in the BODY (live thinking speaks the law)" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "alpha\nbeta\ngamma\ndelta"
          })
        ])

      {body, footer} = body_and_footer(View.render(model))

      # body: the ∵ open bracket + peek (newest 3) — the oldest line is
      # windowed out until a click expands
      assert body =~ "∵"
      assert body =~ "thinking"
      assert body =~ "delta"
      refute body =~ "alpha"

      # footer: no reasoning copy (the body owns the live thought)
      refute footer =~ "thinking"

      # click-to-expand reveals the whole thought
      expanded = Model.click(model, :tail)
      {ebody, _} = body_and_footer(View.render(expanded))
      assert ebody =~ "alpha"
    end

    test "the ACTIVE thought sits in the QUIET register: dim + fade, never white" do
      model =
        stream_model([
          loop_ev(1, "t1", 100, :turn_started, %{}),
          loop_ev(2, "t1", 110, :item_started, %{
            "item_id" => "i1",
            "item_type" => "reasoning"
          }),
          loop_ev(3, "t1", 120, :item_delta, %{
            "item_id" => "i1",
            "chunk" => "quiet line"
          })
        ])

      view = View.render(model)
      [transcript | _] = unframe(view).children

      thinking =
        Enum.find(transcript.children, fn
          %{type: :indication, gutter: {:corners, "∵", nil}} -> true
          _ -> false
        end)

      assert thinking, "no live-thinking record on screen"

      for row <- thinking.content.children do
        assert row.style[:dim] == true

        assert is_binary(row.style[:fg]) and
                 String.starts_with?(row.style[:fg], "#")
      end

      assert is_binary(thinking.gutter_style[:fg])
    end
  end
end
