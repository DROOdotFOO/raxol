defmodule Raxol.Harness.SealFrontierTest do
  @moduledoc """
  The seal-frontier corpus: pure classifier/state-machine tests ported
  from the reference pager's commit-pipeline suite, plus this port's two
  net-new cases (the scan/walk agreement property, and the noted-only
  resize-during-commit case at the bottom of this file).

  Every test here drives `Raxol.Harness.SealFrontier` directly over
  plain entry maps -- no renderer, no paint authority, no fixture
  session. The renderer-level half of the reference suite (height
  exactness, native-color lock, commit capping) belongs to the later
  frame-order unit, not this module.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.SealFrontier

  # -- entry builders --------------------------------------------------------

  # The default kind is deliberately one with NO mid-turn relaxation
  # (mirroring the reference suite's stub blocks, which are "not an
  # AgentMessage"): a running tool may still update its result, so it
  # gets the strict running gate.
  defp finalized(kind \\ :tool_call),
    do: %{kind: kind, committed?: false, running?: false, pending_input?: false}

  defp running(kind \\ :tool_call), do: %{finalized(kind) | running?: true}

  defp pending(entry), do: %{entry | pending_input?: true}

  defp committed_flags(entries), do: Enum.map(entries, & &1.committed?)

  # Run a commit pass, collecting the emitted indices.
  # Returns {emitted_indices, updated_entries, cursor}.
  defp commit_collect(entries, turn_running?, opts \\ []) do
    result =
      SealFrontier.commit_walk(
        entries,
        turn_running?,
        [],
        fn seen, index -> {:ok, [index | seen]} end,
        opts
      )

    {Enum.reverse(result.acc), result.entries, result.cursor}
  end

  # -- the ported corpus -----------------------------------------------------

  describe "frontier walk" do
    test "commits the leading finalized run and stops at a running entry" do
      entries = [finalized(), finalized(), running(), finalized()]

      # The entry AFTER the running blocker must NOT commit yet.
      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == [0, 1]
      assert cursor == 2
      assert committed_flags(entries) == [true, true, false, false]

      # Finalizing the blocker releases it and everything after it.
      entries = List.update_at(entries, 2, &%{&1 | running?: false})

      {emitted, _entries, cursor} =
        commit_collect(entries, true, cursor: cursor)

      assert emitted == [2, 3]
      assert cursor == 4
    end

    test "pending user input holds the frontier" do
      # Finalized but awaiting a permission answer: stops the walk even
      # though it (and the entry after it) are finalized.
      entries = [finalized(), pending(finalized()), finalized()]

      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == [0]

      # Resolving the prompt releases the rest of the run.
      entries = List.update_at(entries, 1, &%{&1 | pending_input?: false})

      {emitted, _entries, _cursor} =
        commit_collect(entries, true, cursor: cursor)

      assert emitted == [1, 2]
    end

    test "a running message commits once a later block exists" do
      # A tracker can leave a message's running flag set until turn end.
      # While it is the LAST entry it may still be streaming -> stays live.
      entries = [running(:message)]
      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == []
      assert cursor == 0

      # A later block proves the message is complete (the producer moved
      # past it) -> it commits mid-turn despite the lingering flag. The
      # new last/running entry stays live.
      entries = entries ++ [running(:tool_call)]

      {emitted, entries, _cursor} =
        commit_collect(entries, true, cursor: cursor)

      assert emitted == [0]
      assert committed_flags(entries) == [true, false]
    end

    test "a running tool still holds the frontier even with a later block" do
      # The message relaxation must NOT extend to tools: a running tool
      # can still update its result, so committing it (print-once) would
      # lose the update. It holds regardless of later blocks.
      entries = [finalized(), running(:tool_call), finalized()]

      {emitted, _entries, cursor} = commit_collect(entries, true)
      assert emitted == [0]
      assert cursor == 1
    end

    test "a background-task start commits while running and does not wedge the frontier" do
      # A background-task lifecycle entry's running flag drives animation
      # only -- its content never changes (completion arrives as a
      # SEPARATE block). Gating it on the flag would wedge the frontier
      # for the rest of the turn.
      entries = [finalized(), running(:background_task), running(:tool_call)]

      {emitted, entries, _cursor} = commit_collect(entries, true)
      assert emitted == [0, 1]
      assert committed_flags(entries) == [true, true, false]
    end

    test "a background-task start commits as the last running entry" do
      # Even as the last entry of a still-running turn: a lifecycle block
      # never streams more content.
      entries = [finalized(), running(:background_task)]

      {emitted, _entries, _cursor} = commit_collect(entries, true)
      assert emitted == [0, 1]
    end

    test "no double commit after a mid-list shift remove" do
      entries = [finalized(), finalized(), finalized()]
      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == [0, 1, 2]
      assert cursor == 3

      # Remove an already-committed entry below the cursor (the remaining
      # indices shift down). The committed flags travel with the shifted
      # entries, so neither survivor is re-emitted.
      entries = List.delete_at(entries, 0)
      cursor = SealFrontier.cursor_after_removal(cursor, 0)
      entries = entries ++ [finalized()]

      {emitted, entries, _cursor} =
        commit_collect(entries, true, cursor: cursor)

      assert emitted == [2]
      assert committed_flags(entries) == [true, true, true]
    end

    test "mid-list removal below the cursor does not strand uncommitted entries" do
      # A committed placeholder is removed AFTER new uncommitted entries
      # were appended past the cursor. Without the cursor decrement the
      # first appended entry slides below the cursor and is never
      # committed NOR shown in the live tail (silently missing).
      entries = [finalized(), finalized()]
      {emitted, entries, cursor} = commit_collect(entries, false)
      assert emitted == [0, 1]
      assert cursor == 2

      entries = entries ++ [finalized(), finalized()]
      entries = List.delete_at(entries, 1)
      cursor = SealFrontier.cursor_after_removal(cursor, 1)
      assert cursor == 1

      {emitted, entries, _cursor} =
        commit_collect(entries, false, cursor: cursor)

      assert emitted == [1, 2]
      assert committed_flags(entries) == [true, true, true]
    end

    test "pending user input holds the frontier even when idle" do
      # The idle relaxation applies ONLY to stale running flags, never to
      # a pending-input mark: the pending entry's rendered form still
      # changes when the prompt resolves, and a committed copy is frozen.
      entries = [finalized(), pending(finalized())]

      {emitted, entries, cursor} = commit_collect(entries, false)
      assert emitted == [0], "pending entry must hold the frontier"
      refute Enum.at(entries, 1).committed?

      entries = List.update_at(entries, 1, &%{&1 | pending_input?: false})

      {emitted, _entries, _cursor} =
        commit_collect(entries, false, cursor: cursor)

      assert emitted == [1]
    end

    test "a failed emit leaves the entry uncommitted for retry" do
      # Print-once invariant: a write failure must NOT mark the entry
      # committed -- a marked-but-unprinted block can never be emitted
      # again and would silently vanish. The walk halts with the cursor
      # strictly before the failed entry; the next pass retries.
      entries = [finalized(), finalized()]

      result =
        SealFrontier.commit_walk(entries, false, 0, fn calls, _index ->
          {:error, :write_failed, calls + 1}
        end)

      assert result.committed == 0, "nothing committed on failure"
      assert result.acc == 1, "walk stops at the first failure"
      assert committed_flags(result.entries) == [false, false]
      assert result.cursor == 0, "cursor holds strictly before the failure"

      # The retry pass succeeds and commits both.
      result =
        SealFrontier.commit_walk(result.entries, false, nil, fn acc, _index ->
          {:ok, acc}
        end)

      assert result.committed == 2
      assert committed_flags(result.entries) == [true, true]
    end

    test "scan_frontier mirrors the mutating walk in every phase" do
      entries = [finalized(), finalized(), running(), finalized()]

      # Pre-commit: the pass would commit two entries and stop at the
      # running one.
      scan = SealFrontier.scan_frontier(entries, true)
      assert scan.will_commit
      assert scan.tail_start == 2

      result =
        SealFrontier.commit_walk(entries, true, nil, fn acc, _index ->
          {:ok, acc}
        end)

      assert result.committed == 2
      assert result.cursor == scan.tail_start

      # Post-commit: nothing left to commit; the tail starts at the cursor.
      scan =
        SealFrontier.scan_frontier(result.entries, true, cursor: result.cursor)

      refute scan.will_commit
      assert scan.tail_start == 2

      # Idle with nothing pending: everything is committable.
      scan =
        SealFrontier.scan_frontier(result.entries, false, cursor: result.cursor)

      assert scan.will_commit
      assert scan.tail_start == 4
    end

    test "removing from below the frontier then pushing still commits" do
      entries = [finalized(), finalized(), finalized()]
      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == [0, 1, 2]

      # Rewind: drop everything from index 1. Without the cursor clamp
      # the cursor would strand at 3 and silently skip the next pushes.
      entries = Enum.take(entries, 1)
      cursor = SealFrontier.cursor_after_truncate(cursor, length(entries))
      assert cursor == 1

      entries = entries ++ [finalized()]

      {emitted, _entries, _cursor} =
        commit_collect(entries, true, cursor: cursor)

      assert emitted == [1]
    end

    test "the walk advances the frontier and marks committed exactly once" do
      entries = [finalized(), finalized(), finalized()]

      {emitted, entries, cursor} = commit_collect(entries, false)
      assert emitted == [0, 1, 2]
      assert cursor == 3
      assert committed_flags(entries) == [true, true, true]

      # A second pass commits nothing: already-committed entries skip.
      {emitted, _entries, _cursor} =
        commit_collect(entries, false, cursor: cursor)

      assert emitted == []
    end

    test "an idle turn commits past a stale running entry" do
      # Stuck-spinner regression: a producer can leave a running flag set
      # after the turn ends (a finalize missed at a transition). While
      # the turn runs that entry correctly holds the frontier; once the
      # turn is idle the frontier must advance past it.
      entries = [finalized(), running(), finalized()]

      {emitted, entries, cursor} = commit_collect(entries, true)
      assert emitted == [0]
      assert cursor == 1

      {emitted, _entries, cursor} =
        commit_collect(entries, false, cursor: cursor)

      assert emitted == [1, 2]
      assert cursor == 3
    end

    test "clearing the entry list resets the frontier" do
      entries = [finalized()]
      {_emitted, _entries, cursor} = commit_collect(entries, true)
      assert cursor == 1

      cursor = SealFrontier.cursor_after_truncate(cursor, 0)
      assert cursor == 0

      assert SealFrontier.scan_frontier([], true) == %{
               tail_start: 0,
               will_commit: false
             }
    end
  end

  describe "classify/3 (the single-step primitive)" do
    test "step order: committed skips, committable commits, blocker stops, out of bounds stops" do
      entries = [
        %{finalized() | committed?: true},
        finalized(),
        running(),
        finalized()
      ]

      assert SealFrontier.classify(entries, 0, true) == :skip
      assert SealFrontier.classify(entries, 1, true) == :commit
      assert SealFrontier.classify(entries, 2, true) == :stop
      assert SealFrontier.classify(entries, 4, true) == :stop
      assert SealFrontier.classify([], 0, true) == :stop
    end

    test "an already-committed entry skips even when it is also pending input" do
      # The committed check precedes committability: the committed flags
      # are authoritative, and a committed entry is history whatever its
      # other marks say.
      entries = [pending(%{finalized() | committed?: true}), finalized()]
      assert SealFrontier.classify(entries, 0, false) == :skip
    end

    test "is_last is computed against the full entry list" do
      # A running message: held while last, released by a later entry.
      assert SealFrontier.classify([running(:message)], 0, true) == :stop

      assert SealFrontier.classify([running(:message), running()], 0, true) ==
               :commit
    end
  end

  describe "seal display mode policy" do
    test "per-kind print-once fidelity" do
      # Committed scrollback cannot be re-folded (static terminal text),
      # so the per-kind fidelity policy lives in one place: reasoning
      # collapses to its marker, tool output truncates, diffs (the key
      # artifact of an edit) and messages stay full.
      assert SealFrontier.seal_display_mode(:reasoning) == :collapsed
      assert SealFrontier.seal_display_mode(:tool_call) == :truncated
      assert SealFrontier.seal_display_mode(:diff) == :expanded
      assert SealFrontier.seal_display_mode(:message) == :expanded
      assert SealFrontier.seal_display_mode(:approval) == :expanded
      assert SealFrontier.seal_display_mode(:opaque) == :expanded
      assert SealFrontier.seal_display_mode(:never_seen_kind) == :expanded
    end
  end

  # -- net-new case #1: the agreement property -------------------------------

  describe "scan/walk agreement (property)" do
    defp entry_gen do
      gen all(
            kind <-
              StreamData.member_of([
                :message,
                :reasoning,
                :tool_call,
                :diff,
                :approval,
                :background_task,
                :opaque
              ]),
            committed? <- StreamData.boolean(),
            running? <- StreamData.boolean(),
            pending_input? <- StreamData.boolean()
          ) do
        %{
          kind: kind,
          committed?: committed?,
          running?: running?,
          pending_input?: pending_input?
        }
      end
    end

    property "scan_frontier agrees with the mutating walk for arbitrary states" do
      check all(
              entries <- StreamData.list_of(entry_gen(), max_length: 12),
              turn_running? <- StreamData.boolean()
            ) do
        scan = SealFrontier.scan_frontier(entries, turn_running?)

        result =
          SealFrontier.commit_walk(entries, turn_running?, 0, fn count,
                                                                 _index ->
            {:ok, count + 1}
          end)

        # The read-only projection and the mutating walk agree on where
        # the live tail starts and on whether anything commits.
        assert result.cursor == scan.tail_start
        assert result.committed == result.acc
        assert result.committed > 0 == scan.will_commit

        # After the walk, a re-scan converges: nothing further to commit
        # this frame, and the tail start is exactly the persisted cursor.
        post =
          SealFrontier.scan_frontier(result.entries, turn_running?,
            cursor: result.cursor
          )

        refute post.will_commit
        assert post.tail_start == result.cursor
      end
    end

    property "both walks agree with a reference walk of repeated classify/3 calls" do
      # classify/3 is the public single-step primitive; the two walks are
      # implemented as suffix walks for performance and are SPECIFIED to
      # produce results identical to calling classify/3 in a loop. This
      # property is that specification, closed over arbitrary states --
      # without it, classify/3 would be a third, independent copy of the
      # step order, free to drift from the walks undetected.
      check all(
              entries <- StreamData.list_of(entry_gen(), max_length: 12),
              turn_running? <- StreamData.boolean()
            ) do
        {ref_tail, ref_committed} =
          classify_reference_walk(entries, turn_running?)

        scan = SealFrontier.scan_frontier(entries, turn_running?)

        assert scan == %{
                 tail_start: ref_tail,
                 will_commit: ref_committed != []
               }

        result =
          SealFrontier.commit_walk(entries, turn_running?, [], fn seen, index ->
            {:ok, [index | seen]}
          end)

        assert result.cursor == ref_tail
        assert Enum.reverse(result.acc) == ref_committed
      end
    end

    # The naive reference walk: literally call classify/3 per index from 0,
    # collecting the indices it says to commit, until it says :stop.
    defp classify_reference_walk(entries, turn_running?, index \\ 0, acc \\ []) do
      case SealFrontier.classify(entries, index, turn_running?) do
        :stop ->
          {index, Enum.reverse(acc)}

        :skip ->
          classify_reference_walk(entries, turn_running?, index + 1, acc)

        :commit ->
          classify_reference_walk(entries, turn_running?, index + 1, [
            index | acc
          ])
      end
    end
  end

  # -- net-new case #2: resize-during-commit (IMPLEMENTED) -------------------
  #
  # The frame-order unit proved the adopt-size-BEFORE-commit ordering: a
  # block finalizing on a shrink frame is laid out at the freshly adopted
  # width, never the stale one -- a stale-width commit hard-wraps
  # over-wide rows and permanently garbles the print-once copy in native
  # scrollback. That case needed the paint pipeline (width adoption + the
  # seal write), which this pure classifier deliberately has no access
  # to, so it does NOT live here as a new test -- it lived in the
  # retired `test/harness/surface_seal_pipeline_test.exs` (describe "2.
  # frame-order law"), driven end-to-end through the retired
  # `Raxol.Harness.Surface.advance/3`'s `:resize` option:
  #
  #   test "a block finalizing on a shrink frame commits at the adopted
  #         width, not the stale one"
end
