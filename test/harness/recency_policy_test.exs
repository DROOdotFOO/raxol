defmodule Raxol.Harness.RecencyPolicyTest do
  @moduledoc """
  Acceptance tests for `Raxol.Harness.RecencyPolicy` (turn recency ->
  per-block prominence) and its one wiring point in
  `Raxol.Harness.Surface.render_block_lines/3`.

  Written RED-FIRST: this file was run against the codebase BEFORE
  `lib/raxol/harness/recency_policy.ex` existed and before
  `render_block_lines/3` was wired -- see the task's final report for the
  captured failing-run evidence. Every test below anchors on a concrete
  documented guarantee (the ladder, the unknown-turn fallback, the
  seal-time grading contract, the needs-input composition), never a bare
  presence assert.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Projection
  alias Raxol.Harness.RecencyPolicy
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Surface.ViewText
  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.Harness.Prominence

  # ---------------------------------------------------------------------
  # A. prominence/1 -- the documented ladder
  # ---------------------------------------------------------------------

  describe "prominence/1 steps the documented ladder and floors at 0.4" do
    test "the table: 0/1/2/3/4/10/nil/-1" do
      table = [
        {0, 1.0},
        {1, 0.8},
        {2, 0.6},
        {3, 0.4},
        {4, 0.4},
        {10, 0.4},
        {nil, 1.0},
        {-1, 1.0}
      ]

      for {turns_behind, expected} <- table do
        assert RecencyPolicy.prominence(turns_behind) == expected,
               "turns_behind #{inspect(turns_behind)}: expected #{expected}, " <>
                 "got #{RecencyPolicy.prominence(turns_behind)}"
      end
    end

    test "floor/0 is the single source of the ladder's floor value" do
      assert RecencyPolicy.floor() == 0.4
      assert RecencyPolicy.prominence(3) == RecencyPolicy.floor()
    end
  end

  # ---------------------------------------------------------------------
  # B. grade/2 -- the pure core, a five-turn transcript
  # ---------------------------------------------------------------------

  describe "grade/2 grades a five-turn transcript down the ladder from the current turn" do
    test "five distinct turns, current = newest" do
      turn_ids = [:t1, :t2, :t3, :t4, :t5]
      assert RecencyPolicy.grade(turn_ids, :t5) == [0.4, 0.4, 0.6, 0.8, 1.0]
    end

    test "a repeated turn id grades identically at every occurrence" do
      assert RecencyPolicy.grade([:t1, :t1, :t2], :t2) == [0.8, 0.8, 1.0]
    end
  end

  # ---------------------------------------------------------------------
  # C. grade/2 -- unknown-turn fallback: never darker than 1.0
  # ---------------------------------------------------------------------

  describe "grade/2 unknown-turn fallback is 1.0, never darker" do
    test "a nil current turn grades every block 1.0" do
      assert RecencyPolicy.grade([:t1, :t2, :t3], nil) == [1.0, 1.0, 1.0]
    end

    test "a nil turn id inside the list grades that block 1.0, others graded normally" do
      assert RecencyPolicy.grade([:t1, nil, :t2], :t2) == [0.8, 1.0, 1.0]
    end

    test "a current turn absent from the list grades everything one tier deeper" do
      assert RecencyPolicy.grade([:t1, :t2], :t3) == [0.6, 0.8]
    end
  end

  # ---------------------------------------------------------------------
  # D. grade_block/2 -- deriving turn identity from event_refs + source events
  # ---------------------------------------------------------------------

  describe "grade_block/2 derives turn identity from event refs and source events" do
    defp two_turn_events do
      [
        %{
          id: 1,
          turn_id: "t1",
          ts: 100,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 110,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 120,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => "turn 1 reply"
          }
        },
        %{
          id: 4,
          turn_id: "t2",
          ts: 200,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 5,
          turn_id: "t2",
          ts: 210,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i2", "item_type" => "message"}
        },
        %{
          id: 6,
          turn_id: "t2",
          ts: 220,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i2",
            "item_type" => "message",
            "content" => "turn 2 reply"
          }
        }
      ]
    end

    test "the older-turn block grades 0.8, the current-turn block grades 1.0" do
      events = two_turn_events()
      projection = Projection.project(events)
      assert [block1, block2] = projection.blocks

      assert RecencyPolicy.grade_block(block1, projection.source_events) == 0.8
      assert RecencyPolicy.grade_block(block2, projection.source_events) == 1.0
    end

    test "a block whose event_refs match nothing in events grades 1.0" do
      events = two_turn_events()

      unmatched_block =
        Block.from_events(:message, [
          %{id: 999, type: :item_completed, content: "orphan"}
        ])

      assert RecencyPolicy.grade_block(unmatched_block, events) == 1.0
    end

    test "empty events grades 1.0" do
      block =
        Block.from_events(:message, [
          %{id: 1, type: :item_completed, content: "hi"}
        ])

      assert RecencyPolicy.grade_block(block, []) == 1.0
    end

    test "a non-map entry inside events does not raise, and is simply skipped" do
      projection = Projection.project(two_turn_events())
      assert [block1 | _] = projection.blocks

      polluted_events = two_turn_events() ++ ["not a map", 42, nil]

      assert RecencyPolicy.grade_block(block1, polluted_events) == 0.8
    end
  end

  # ---------------------------------------------------------------------
  # D2. grade_blocks/2 -- the batch path: one event walk for a whole
  #     projection (the bulk-paint / reattach-rebuild consumer)
  # ---------------------------------------------------------------------

  describe "grade_blocks/2 batch-grades a projection in one event walk" do
    defp five_turn_projection do
      events =
        Enum.flat_map(1..5, fn n ->
          base = (n - 1) * 3

          [
            %{
              id: base + 1,
              turn_id: "t#{n}",
              ts: n * 1000,
              family: :loop,
              type: :turn_started,
              tier: :durable,
              payload: %{}
            },
            %{
              id: base + 2,
              turn_id: "t#{n}",
              ts: n * 1000 + 10,
              family: :loop,
              type: :item_started,
              tier: :durable,
              payload: %{"item_id" => "i#{n}", "item_type" => "message"}
            },
            %{
              id: base + 3,
              turn_id: "t#{n}",
              ts: n * 1000 + 20,
              family: :loop,
              type: :item_completed,
              tier: :durable,
              payload: %{
                "item_id" => "i#{n}",
                "item_type" => "message",
                "content" => "turn #{n} reply"
              }
            }
          ]
        end)

      Projection.project(events)
    end

    test "matches per-block grade_block/2 exactly (the equivalence law)" do
      projection = five_turn_projection()

      batch =
        RecencyPolicy.grade_blocks(projection.blocks, projection.source_events)

      singles =
        Enum.map(
          projection.blocks,
          &RecencyPolicy.grade_block(&1, projection.source_events)
        )

      assert batch == singles
      assert batch == [0.4, 0.4, 0.6, 0.8, 1.0]
    end

    test "empty blocks and empty events degrade safely" do
      projection = five_turn_projection()

      assert RecencyPolicy.grade_blocks([], projection.source_events) == []

      assert RecencyPolicy.grade_blocks(projection.blocks, []) ==
               [1.0, 1.0, 1.0, 1.0, 1.0]
    end

    test "a block with unresolvable refs grades 1.0 in the batch too" do
      projection = five_turn_projection()

      orphan =
        Block.from_events(:message, [
          %{id: 9_991, type: :item_completed, content: "orphan"}
        ])

      grades =
        RecencyPolicy.grade_blocks(
          projection.blocks ++ [orphan],
          projection.source_events
        )

      assert List.last(grades) == 1.0
      assert Enum.take(grades, 5) == [0.4, 0.4, 0.6, 0.8, 1.0]
    end
  end

  # ---------------------------------------------------------------------
  # D3. The anti-inversion invariant, made self-defending: every block a
  #     projection builds resolves its turn against that projection's own
  #     source_events. This is the tripwire for the retention decision at
  #     Raxol.Harness.Projection (source_events = every durable event,
  #     un-windowed; ephemeral item_delta traffic never enters a block's
  #     event_refs). The day someone bounds source_events for memory, THIS
  #     test goes red before old scrollback can silently grade loud.
  # ---------------------------------------------------------------------

  describe "the anti-inversion invariant (blocks always resolve against source_events)" do
    @session_fixtures ~w(simple-chat long-folds multi-tool-turn markdown-stream
                         taint-propagation unicode-heavy adversarial)

    test "every shipped fixture's blocks resolve their event_refs in source_events" do
      for name <- @session_fixtures do
        path = "test/fixtures/harness/sessions/#{name}.jsonl"
        {:ok, session} = Raxol.Harness.Fixture.load(path)
        projection = Projection.project(session)

        source_ids =
          projection.source_events
          |> Enum.map(&Map.get(&1, :id))
          |> MapSet.new()

        for block <- projection.blocks do
          resolvable =
            Enum.any?(block.event_refs, &MapSet.member?(source_ids, &1))

          assert resolvable,
                 "#{name}: block #{inspect(block.event_refs)} resolves no " <>
                   "ref in source_events -- the un-windowed durable " <>
                   "retention invariant broke (see Projection's " <>
                   "source_events construction); recency grading would " <>
                   "silently return 1.0 (loud) for this block"
        end
      end
    end

    test "negative control: a windowed source_events degrades old blocks to 1.0 (loud), the documented failure mode" do
      # This is the exact behavior the invariant above protects against
      # becoming reachable: grading against a WINDOWED tail of events
      # (here: only the newest turn retained) resolves an old block's
      # turn to nothing, and the ratified never-darker rule grades it
      # 1.0. Correct per the unknown-turn spec; wrong as an attention
      # signal -- which is why retention must stay un-windowed while
      # this policy feeds on source_events.
      projection = five_turn_projection()
      [oldest_block | _] = projection.blocks

      windowed_tail = Enum.take(projection.source_events, -3)

      assert RecencyPolicy.grade_block(oldest_block, windowed_tail) == 1.0

      assert RecencyPolicy.grade_block(
               oldest_block,
               projection.source_events
             ) == 0.4
    end
  end

  # ---------------------------------------------------------------------
  # E. a five-turn fixture renders the documented ladder byte-exact
  # ---------------------------------------------------------------------

  describe "a five-turn fixture renders the documented ladder byte-exact" do
    defp turn_events(n) do
      base = (n - 1) * 3

      [
        %{
          id: base + 1,
          turn_id: "t#{n}",
          ts: n * 1000,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: base + 2,
          turn_id: "t#{n}",
          ts: n * 1000 + 10,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i#{n}", "item_type" => "message"}
        },
        %{
          id: base + 3,
          turn_id: "t#{n}",
          ts: n * 1000 + 20,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i#{n}",
            "item_type" => "message",
            "content" => "turn #{n} reply"
          }
        }
      ]
    end

    test "grades 1..5 down the ladder and the header fg matches Prominence.resolve/3 byte-exact" do
      events = Enum.flat_map(1..5, &turn_events/1)
      projection = Projection.project(events)
      assert length(projection.blocks) == 5

      grades =
        Enum.map(
          projection.blocks,
          &RecencyPolicy.grade_block(&1, projection.source_events)
        )

      assert grades == [0.4, 0.4, 0.6, 0.8, 1.0]

      for {block, grade} <- Enum.zip(projection.blocks, grades) do
        %{children: [header | _]} =
          Block.render(block, %{width: 80, prominence: grade, ground: 0.2})

        if grade >= 1.0 do
          refute Map.has_key?(header.style, :fg),
                 "newest (current-turn) block must render neutral (no :fg)"
        else
          expected_fg = Prominence.resolve("#B4B4B4", grade, ground: 0.2)

          assert header.style.fg == expected_fg,
                 "grade #{grade}: expected fg #{expected_fg}, got #{header.style.fg}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # F. a live approval outranks its ladder tier via the needs-input floor
  # ---------------------------------------------------------------------

  describe "a live approval block outranks its ladder tier via the needs-input floor" do
    test "the approval's header floors at the context tier, brighter than a plain 0.4 grade" do
      block =
        Block.from_events(
          :approval,
          [
            %{
              id: 99,
              type: :approval_requested,
              payload: %{action: "rm -rf /tmp/x"}
            }
          ],
          seal: :live
        )

      assert Block.live?(block)

      %{children: [header | _]} =
        Block.render(block, %{width: 80, prominence: 0.4, ground: 0.2})

      floored_fg =
        Prominence.resolve("#B4B4B4", 0.4, needs_input: true, ground: 0.2)

      context_tier_fg = Prominence.resolve("#B4B4B4", 0.6, ground: 0.2)
      plain_fg = Prominence.resolve("#B4B4B4", 0.4, ground: 0.2)

      assert floored_fg == context_tier_fg
      assert header.style.fg == floored_fg
      refute header.style.fg == plain_fg
    end
  end

  # ---------------------------------------------------------------------
  # G. the wiring: surface seals blocks at their seal-time grade
  # ---------------------------------------------------------------------

  describe "surface seals blocks at their seal-time grade" do
    defp two_turn_wire_events do
      [
        %{
          id: 1,
          turn_id: "t1",
          ts: 100,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 2,
          turn_id: "t1",
          ts: 110,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i1", "item_type" => "message"}
        },
        %{
          id: 3,
          turn_id: "t1",
          ts: 120,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i1",
            "item_type" => "message",
            "content" => "turn 1 reply"
          }
        },
        %{
          id: 4,
          turn_id: "t2",
          ts: 200,
          family: :loop,
          type: :turn_started,
          tier: :durable,
          payload: %{}
        },
        %{
          id: 5,
          turn_id: "t2",
          ts: 210,
          family: :loop,
          type: :item_started,
          tier: :durable,
          payload: %{"item_id" => "i2", "item_type" => "message"}
        },
        %{
          id: 6,
          turn_id: "t2",
          ts: 220,
          family: :loop,
          type: :item_completed,
          tier: :durable,
          payload: %{
            "item_id" => "i2",
            "item_type" => "message",
            "content" => "turn 2 reply"
          }
        }
      ]
    end

    defp advance_until_done(model) do
      case Surface.advance(model) do
        {advanced, :done} -> advanced
        {advanced, :ok} -> advance_until_done(advanced)
      end
    end

    # "#rrggbb" -> "38;2;R;G;B" (decimal), the 24-bit truecolor SGR
    # fragment `Raxol.Harness.Surface.ViewText`'s `maybe_fg/2` emits.
    defp hex_to_sgr_fragment("#" <> hex) do
      {value, ""} = Integer.parse(hex, 16)
      r = value |> Bitwise.bsr(16) |> Bitwise.band(0xFF)
      g = value |> Bitwise.bsr(8) |> Bitwise.band(0xFF)
      b = Bitwise.band(value, 0xFF)
      "38;2;#{r};#{g};#{b}"
    end

    test "turn-1's block seals at its seal-time grade; the newest block stays neutral" do
      events = two_turn_wire_events()
      {:ok, device} = StringIO.open("")

      # message defaults to :expanded fold (Block.default_fold/1), which
      # routes through BlockBody -> BodyProvider -> MessageBlock -- a rich
      # T5 body component that does not (yet) thread context[:prominence]
      # at all (out of scope for this unit; only Block.render/2 honors
      # prominence today). Forcing message blocks :folded routes
      # BlockBody.render/2 through its `:folded` clause, which delegates
      # straight to Block.render/2 -- the path this policy actually feeds.
      _final_model =
        events
        |> Surface.new(
          device: device,
          width: 80,
          rows: 24,
          mode: :inline_log,
          fold_defaults: %{message: :folded}
        )
        |> advance_until_done()

      {_in, out} = StringIO.contents(device)

      # Seal timing (see Surface.frontier_entries/1): turn-1's block
      # completes on event 3, but paint_pending_blocks/1 holds the newest
      # completed block back for exactly one more advance/2 call unless
      # the fixture reveal has finished. Turn-2's own item_completed
      # (event 6) is simultaneously the event that both completes turn-2's
      # block AND finishes the reveal (revealed == length(events)) -- so
      # `reveal_finished?` flips true in the SAME advance/2 step that
      # produces the second block, and both blocks clear the frontier's
      # hold-back-one-block gate together, sealing in the same
      # paint_pending_blocks/1 pass. At that moment
      # model.projection.source_events already contains both turns'
      # events; current turn = "t2" (the last event's turn_id), and
      # turn-1's block is exactly one turn behind -> ladder step 0.8.
      expected_grade = 0.8
      expected_hex = Prominence.resolve("#B4B4B4", expected_grade, [])
      expected_fragment = hex_to_sgr_fragment(expected_hex)

      assert out =~ expected_fragment,
             "expected the seal-time-graded fragment #{expected_fragment} " <>
               "(from #{expected_hex}) in sealed output, got:\n#{out}"

      # The last (current-turn) block seals at grade 1.0 -- neutral, no
      # :fg touched. Reconstruct its own bare (unstyled) header line via
      # the SAME Block.render + ViewText.lines path seal_block/2 uses, and
      # confirm it appears in the sealed output immediately followed by
      # "\r\n" with no "\e[0m" reset in between -- which is only possible
      # if no SGR wrapping was ever added (a styled line always inserts
      # "\e[0m" between content and the "\r\n" seal_block/2 appends).
      final_projection =
        Projection.project(events, fold_defaults: %{message: :folded})

      last_block = List.last(final_projection.blocks)

      neutral_line =
        last_block
        |> Block.render(%{width: 80, prominence: 1.0})
        |> ViewText.lines(80, :styled)
        |> hd()

      refute neutral_line =~ "38;2",
             "the newest block's own reconstructed neutral line must carry no fg"

      assert out =~ neutral_line <> "\r\n",
             "expected the newest block's bare, unstyled header line in sealed output"
    end
  end
end
