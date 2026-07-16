defmodule Raxol.Harness.CompletionEvidenceTest do
  @moduledoc """
  Acceptance tests for the harness transcript's completion-evidence row:
  a final `turn_completed` (payload `final: true`) attaches an honesty
  verdict to the turn's last block -- either a bounded, typed, sanitized
  list of evidence entries (when the evidence gate accepted refs) or the
  explicit `%{evidence: :none}` absence marker, NEVER a silent success
  toast (see `docs/proposals/in-flight/` design creed: "a 'done' claim is
  only as good as its evidence").

  Ground truth for the wire shape: `packages/raxol_agent/lib/raxol/agent/
  contract.ex`'s `gated_done_payload/4` -- `final: true` always, `refs:`
  present only when the evidence gate accepts (a list of journal event
  ids). Per the frozen offset law, a ref is a SESSION-scoped journal
  offset, not a turn-scoped one -- it may point at an earlier turn's
  event, and resolution here is exercised against that whole-session
  scope, not just the owning turn's own events.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.Block

  @sessions_dir "test/fixtures/harness/sessions"

  # Mirrors t7_projection_test.exs's own `loop/5` helper: plain
  # event-shaped maps matching the fixture wire shape (string-keyed
  # payload, atom top-level fields) that `Projection.project/2` accepts
  # directly, no fixture file needed for most of these.
  defp loop(id, turn_id, ts, type, payload) do
    %{
      id: id,
      turn_id: turn_id,
      ts: ts,
      family: :loop,
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  defp tool_round_trip(base_id, turn_id, ts, name, result_content) do
    [
      loop(base_id, turn_id, ts, :item_started, %{
        "item_id" => "tu#{base_id}",
        "item_type" => "tool_use"
      }),
      loop(base_id + 1, turn_id, ts + 10, :item_completed, %{
        "item_id" => "tu#{base_id}",
        "item_type" => "tool_use",
        "name" => name,
        "arguments" => %{}
      }),
      loop(base_id + 2, turn_id, ts + 20, :item_started, %{
        "item_id" => "tr#{base_id}",
        "item_type" => "tool_result"
      }),
      loop(base_id + 3, turn_id, ts + 30, :item_completed, %{
        "item_id" => "tr#{base_id}",
        "item_type" => "tool_result",
        "name" => name,
        "content" => result_content
      })
    ]
  end

  defp message(id, turn_id, ts, content) do
    [
      loop(id, turn_id, ts, :item_started, %{
        "item_id" => "m#{id}",
        "item_type" => "message"
      }),
      loop(id + 1, turn_id, ts + 10, :item_completed, %{
        "item_id" => "m#{id}",
        "item_type" => "message",
        "content" => content
      })
    ]
  end

  defp turn_completed(id, turn_id, ts, payload_extra) do
    base = %{
      "iteration" => 1,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "cost" => 0.0001,
      "final" => true
    }

    loop(id, turn_id, ts, :turn_completed, Map.merge(base, payload_extra))
  end

  defp last_block(proj), do: List.last(proj.blocks)

  defp flat_texts(%{type: :text, content: content}), do: [content]
  defp flat_texts(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_node), do: []

  # -- 1. evidence arm ---------------------------------------------------

  describe "projection: evidence arm" do
    test "a turn_completed with final:true and a ref to a real tool_result attaches a typed entry labeled by tool name + result" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "mix_test", "42 tests, 0 failures"),
          message(6, "t1", 300, "All tests passed."),
          turn_completed(8, "t1", 400, %{"refs" => [5]})
        ])

      proj = Projection.project(events)
      last = last_block(proj)

      assert %{
               evidence: [
                 %{ref: 5, type: :tool_result, label: "mix_test — 42 tests, 0 failures"}
               ],
               total: 1,
               type_counts: [%{type: :tool_result, count: 1}]
             } = last.content.completion
    end
  end

  # -- 2. absence arm -----------------------------------------------------

  describe "projection: absence arm" do
    test "final:true with no refs key attaches :none" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{})
        ])

      proj = Projection.project(events)
      assert last_block(proj).content.completion == %{evidence: :none}
    end

    test "final:true with an empty refs list attaches :none" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{"refs" => []})
        ])

      proj = Projection.project(events)
      assert last_block(proj).content.completion == %{evidence: :none}
    end

    test "final:true with a non-list refs value attaches :none" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{"refs" => "not-a-list"})
        ])

      proj = Projection.project(events)
      assert last_block(proj).content.completion == %{evidence: :none}
    end
  end

  # -- 3. non-final turn ---------------------------------------------------

  describe "projection: non-final turn never carries a completion key" do
    test "final:false leaves the last block byte-identical to a projection with no turn_completed at all" do
      base_events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "still working")
        ])

      with_nonfinal =
        base_events ++ [turn_completed(4, "t1", 300, %{"final" => false})]

      proj_without = Projection.project(base_events)
      proj_with = Projection.project(with_nonfinal)

      last_without = last_block(proj_without)
      last_with = last_block(proj_with)

      refute Map.has_key?(last_with.content, :completion)
      assert last_with.content == last_without.content
    end
  end

  # -- 4. session-scoped ref resolution ------------------------------------

  describe "projection: refs are session-scoped, not turn-scoped" do
    test "a ref pointing at an EARLIER turn's tool_result resolves under session scope (cross-turn)" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "mix_test", "42 tests, 0 failures"),
          turn_completed(6, "t1", 300, %{}),
          loop(7, "t2", 400, :turn_started, %{}),
          message(8, "t2", 500, "Thanks, all done."),
          # id 5 is t1's tool_result item_completed -- an EARLIER turn's
          # event, resolved here from t2's own turn_completed. Not
          # reachable via any of t2's own built blocks (there is no
          # :tool_call block in t2 at all) -- this only resolves if
          # resolution is against the whole session, not t2's slice.
          turn_completed(10, "t2", 600, %{"refs" => [5]})
        ])

      proj = Projection.project(events)
      last = last_block(proj)

      assert %{
               evidence: [
                 %{ref: 5, type: :tool_result, label: "mix_test — 42 tests, 0 failures"}
               ],
               total: 1
             } = last.content.completion
    end

    test "a ref pointing at a same-turn message item resolves with type: :message and the message content as its label" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "the message content"),
          turn_completed(4, "t1", 300, %{"refs" => [3]})
        ])

      proj = Projection.project(events)

      assert %{
               evidence: [%{ref: 3, type: :message, label: "the message content"}],
               total: 1,
               type_counts: [%{type: :message, count: 1}]
             } = last_block(proj).content.completion
    end

    test "a ref pointing at a non-existent event id resolves as unresolvable, never raises, and never drops silently" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{"refs" => [999]})
        ])

      proj = Projection.project(events)

      assert %{
               evidence: [
                 %{ref: 999, type: :unresolvable, label: "unresolvable evidence ref"}
               ],
               total: 1,
               type_counts: [%{type: :unresolvable, count: 1}]
             } = last_block(proj).content.completion
    end
  end

  # -- 5. cap ---------------------------------------------------------------

  describe "projection: evidence entries are capped at 3, total and type_counts reflect the full ref count" do
    test "5 refs produce 3 entries and total: 5; render shows +2 more" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "tool_a", "result a"),
          tool_round_trip(10, "t1", 300, "tool_b", "result b"),
          tool_round_trip(18, "t1", 400, "tool_c", "result c"),
          tool_round_trip(26, "t1", 500, "tool_d", "result d"),
          tool_round_trip(34, "t1", 600, "tool_e", "result e"),
          message(42, "t1", 700, "all five ran"),
          turn_completed(44, "t1", 800, %{"refs" => [5, 13, 21, 29, 37]})
        ])

      proj = Projection.project(events)
      completion = last_block(proj).content.completion

      assert completion.total == 5
      assert completion.type_counts == [%{type: :tool_result, count: 5}]
      assert length(completion.evidence) == 3

      assert Enum.map(completion.evidence, & &1.label) == [
               "tool_a — result a",
               "tool_b — result b",
               "tool_c — result c"
             ]

      rendered = Block.render(last_block(proj), %{})
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "+2 more")),
             "expected the render to note the 2 uncapped entries, got: #{inspect(texts)}"

      assert Enum.any?(texts, &(&1 == "5 evidence refs: 5 tool results")),
             "expected the summary line to break down all 5 refs by type, got: #{inspect(texts)}"
    end
  end

  # -- summary line breakdown (accord-example literal strings) -------------

  describe "the summary line breaks down refs by type, descending count, including unresolvable" do
    test "3 refs, mixed types: \"3 evidence refs: 2 tool results, 1 message\"" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "tool_a", "result a"),
          tool_round_trip(10, "t1", 300, "tool_b", "result b"),
          message(18, "t1", 400, "a message"),
          turn_completed(20, "t1", 500, %{"refs" => [5, 13, 19]})
        ])

      proj = Projection.project(events)
      completion = last_block(proj).content.completion

      assert completion.type_counts == [%{type: :tool_result, count: 2}, %{type: :message, count: 1}]

      texts = last_block(proj) |> Block.render(%{}) |> flat_texts()

      assert Enum.any?(texts, &(&1 == "3 evidence refs: 2 tool results, 1 message"))
    end

    test "2 refs, one unresolvable: \"2 evidence refs: 1 tool result, 1 unresolvable\"" do
      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "mix_test", "42 tests, 0 failures"),
          turn_completed(6, "t1", 300, %{"refs" => [5, 999]})
        ])

      proj = Projection.project(events)
      completion = last_block(proj).content.completion

      assert completion.type_counts == [%{type: :tool_result, count: 1}, %{type: :unresolvable, count: 1}]

      texts = last_block(proj) |> Block.render(%{}) |> flat_texts()

      assert Enum.any?(texts, &(&1 == "2 evidence refs: 1 tool result, 1 unresolvable"))
    end
  end

  # -- 6. hostile evidence (untrusted-content law) --------------------------

  describe "projection: hostile tool names/results never leak control bytes or overflow the label budget" do
    test "ESC, BEL, CRLF, and a 500-char line are stripped/clamped in the rendered row" do
      hostile_name = "mix\e[31m_test\x07"
      hostile_result = "line one\r\n" <> String.duplicate("x", 500)

      events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, hostile_name, hostile_result),
          turn_completed(6, "t1", 300, %{"refs" => [5]})
        ])

      proj = Projection.project(events)
      completion = last_block(proj).content.completion
      [%{label: label}] = completion.evidence

      refute label =~ "\e"
      refute label =~ "\x07"
      refute String.contains?(label, <<0x7F>>)

      for <<byte <- label>> do
        assert byte >= 0x20, "label #{inspect(label)} carried a control byte #{inspect(byte)}"
      end

      assert Raxol.UI.TextMeasure.display_width(label) <= 32

      # Isolate to the completion row itself -- Block.render/2's HEADER
      # line for this same tool_call block also shows the raw (unrelated,
      # pre-existing) tool name verbatim, which is out of this feature's
      # scope; `completion_rows/2` is the seam this feature owns.
      completion_texts =
        last_block(proj) |> Block.completion_rows() |> Enum.flat_map(&flat_texts/1)

      for text <- completion_texts do
        refute text =~ "\e", "rendered completion row leaked ESC: #{inspect(text)}"
        refute text =~ "\x07", "rendered completion row leaked BEL: #{inspect(text)}"
        refute String.contains?(text, "\r"), "rendered completion row leaked CR: #{inspect(text)}"
      end
    end
  end

  # -- 7. the honesty pin (non-negotiable) ---------------------------------

  describe "the honesty pin: absence and unresolvable refs must render literal text, never blank or a checkmark" do
    setup do
      absence_events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{})
        ])

      evidence_events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "mix_test", "42 tests, 0 failures"),
          turn_completed(6, "t1", 300, %{"refs" => [5]})
        ])

      unresolvable_events =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          message(2, "t1", 200, "Done."),
          turn_completed(4, "t1", 300, %{"refs" => [999]})
        ])

      %{
        absence_block: last_block(Projection.project(absence_events)),
        evidence_block: last_block(Projection.project(evidence_events)),
        unresolvable_block: last_block(Projection.project(unresolvable_events))
      }
    end

    test "folded render of the absence arm contains the literal text \"no evidence provided\"", %{
      absence_block: block
    } do
      folded = %{block | fold: :folded}
      texts = flat_texts(Block.render(folded, %{}))

      assert Enum.any?(texts, &(&1 == "no evidence provided")),
             "expected the literal absence text in folded render, got: #{inspect(texts)}"
    end

    test "expanded render of the absence arm contains the literal text \"no evidence provided\"", %{
      absence_block: block
    } do
      expanded = %{block | fold: :expanded}
      texts = flat_texts(Block.render(expanded, %{}))

      assert Enum.any?(texts, &(&1 == "no evidence provided")),
             "expected the literal absence text in expanded render, got: #{inspect(texts)}"
    end

    test "folded render of a dangling ref contains the literal text \"unresolvable evidence ref\"", %{
      unresolvable_block: block
    } do
      folded = %{block | fold: :folded}
      texts = flat_texts(Block.render(folded, %{}))

      assert Enum.any?(texts, &(&1 =~ "unresolvable evidence ref")),
             "expected the literal unresolvable text in folded render, got: #{inspect(texts)}"
    end

    test "expanded render of a dangling ref contains the literal text \"unresolvable evidence ref\"", %{
      unresolvable_block: block
    } do
      expanded = %{block | fold: :expanded}
      texts = flat_texts(Block.render(expanded, %{}))

      assert Enum.any?(texts, &(&1 =~ "unresolvable evidence ref")),
             "expected the literal unresolvable text in expanded render, got: #{inspect(texts)}"
    end

    test "the evidence arm and the absence arm render different completion rows", %{
      absence_block: absence_block,
      evidence_block: evidence_block
    } do
      absence_texts = flat_texts(Block.render(absence_block, %{}))
      evidence_texts = flat_texts(Block.render(evidence_block, %{}))

      assert Enum.any?(absence_texts, &(&1 == "no evidence provided"))
      refute Enum.any?(evidence_texts, &(&1 == "no evidence provided")),
             "the evidence arm must never render the absence text"

      assert Enum.any?(evidence_texts, &(&1 =~ "mix_test"))
      refute evidence_texts == absence_texts
    end
  end

  # -- 8. fixture end-to-end ------------------------------------------------

  describe "fixture end-to-end: evidence-done.jsonl" do
    test "t1's last block has a tool_result entry labeled mix_test + result; t2's last block is :none" do
      {:ok, session} =
        Fixture.load(Path.join(@sessions_dir, "evidence-done.jsonl"))

      proj = Projection.project(session)

      # t1: tool_use+tool_result merge into one :tool_call block, then a
      # :message block (the turn's last, carrying the evidence
      # completion). t2: a single :message block (the turn's last,
      # carrying the absence completion).
      assert [_tool_call, t1_last, t2_last] = proj.blocks

      assert %{
               evidence: [
                 %{type: :tool_result, label: "mix_test — 42 tests, 0 failures"}
               ],
               total: 1,
               type_counts: [%{type: :tool_result, count: 1}]
             } = t1_last.content.completion

      assert t2_last.content.completion == %{evidence: :none}
    end

    test "the checked-in evidence-done.t7blocks.json snapshot is current" do
      {:ok, session} =
        Fixture.load(Path.join(@sessions_dir, "evidence-done.jsonl"))

      proj = Projection.project(session)
      {blocks, fold_defaults} = Projection.identity(proj)

      fresh = %{
        schema: "harness-t7blocks/1",
        projector: "Raxol.Harness.Projection",
        fold_defaults: fold_defaults,
        blocks: blocks
      }

      snapshot_path = Path.join(@sessions_dir, "evidence-done.t7blocks.json")
      checked_in = Jason.decode!(File.read!(snapshot_path))

      assert Jason.decode!(Jason.encode!(fresh)) == checked_in
    end
  end

  # -- 9. zero-block final turn ---------------------------------------------

  describe "a final turn_completed with no blocks in the turn diagnoses, never synthesizes a block" do
    test "turn_started immediately followed by turn_completed final:true produces zero blocks and one diagnostic" do
      events = [
        loop(1, "t1", 100, :turn_started, %{}),
        turn_completed(2, "t1", 200, %{})
      ]

      proj = Projection.project(events)

      assert proj.blocks == []

      assert Enum.any?(
               proj.diagnostics,
               &(&1.reason == :final_completion_without_blocks and &1.event_id == 2)
             )
    end
  end

  # -- 10. identity ----------------------------------------------------------

  describe "transcript_identity/1: completion participates, never stripped" do
    test "an evidence-bearing projection and a refs-free projection of an otherwise-identical turn have different transcript identities" do
      shared_prefix =
        List.flatten([
          loop(1, "t1", 100, :turn_started, %{}),
          tool_round_trip(2, "t1", 200, "mix_test", "42 tests, 0 failures")
        ])

      with_refs = shared_prefix ++ [turn_completed(6, "t1", 300, %{"refs" => [5]})]
      without_refs = shared_prefix ++ [turn_completed(6, "t1", 300, %{})]

      identity_with = Projection.transcript_identity(Projection.project(with_refs))
      identity_without = Projection.transcript_identity(Projection.project(without_refs))

      refute identity_with == identity_without
    end
  end
end
