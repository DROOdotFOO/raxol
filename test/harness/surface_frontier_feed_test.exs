defmodule Raxol.Harness.SurfaceFrontierFeedTest do
  @moduledoc """
  The pending-input feed contract of `Raxol.Harness.Surface.frontier_entries/1`:
  the seal frontier's pending-input gate documents "an entry whose rendered
  form can still change on user interaction must never seal," and this suite
  pins the feed to that meaning for BOTH of its instances -- a genuinely
  awaiting-input block (a live `:approval`, per `Block`'s own contract "a
  live approval block is, by definition, waiting on the user") and the
  surface's one-advance foldable window on the newest block.

  These tests drive `frontier_entries/1` / `frontier_scan/1` over hand-built
  model maps (both functions are pure over plain maps), because today's
  block builder only ever constructs sealed blocks -- the live-approval
  lifecycle is dormant in fixture mode, and the whole point here is that the
  feed must honor the gate's contract the moment a producer emits it.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.UI.Components.Harness.Block

  defp block(kind, seal) do
    Block.from_events(kind, [%{id: 1, payload: %{content: "x"}}], seal: seal)
  end

  # A minimal model map carrying exactly the fields frontier_entries/1 and
  # frontier_scan/1 read: projection blocks, the painted high-water mark,
  # reveal progress, and the status snapshot (turn_running? derivation).
  defp model(blocks, opts) do
    revealed = Keyword.get(opts, :revealed, 0)
    total_events = Keyword.get(opts, :total_events, revealed)

    %{
      projection: %{blocks: blocks},
      painted_count: Keyword.get(opts, :painted, 0),
      revealed: revealed,
      events: List.duplicate(%{}, total_events),
      status: Keyword.get(opts, :status, %{})
    }
  end

  describe "the genuine awaiting-input feed (live approval blocks)" do
    test "a live approval block is pending input even when it is NOT the newest entry" do
      # The reveal-window mapping alone would give this block
      # pending_input?: false (it is not the newest block), letting it
      # seal mid-question the moment the frontier reaches it.
      blocks = [block(:approval, :live), block(:message, :sealed)]

      entries =
        Surface.frontier_entries(model(blocks, revealed: 1, total_events: 3))

      assert Enum.at(entries, 0).pending_input?,
             "a live approval block must feed the frontier's pending-input gate " <>
               "regardless of its position"
    end

    test "a live approval block stays pending after the reveal finishes, even on an idle turn" do
      # Reveal finished (window closed) AND turn idle: the idle relaxation
      # forgives stale running flags, so without a pending-input feed the
      # live approval would seal into print-once scrollback while still
      # waiting on the user -- the exact failure the gate exists to prevent.
      blocks = [block(:message, :sealed), block(:approval, :live)]

      model =
        model(blocks,
          revealed: 2,
          total_events: 2,
          painted: 1,
          status: %{turn_completed: true}
        )

      entries = Surface.frontier_entries(model)
      assert Enum.at(entries, 1).pending_input?

      scan = Surface.frontier_scan(model)

      assert scan.tail_start == 1,
             "the frontier must hold at the live approval block in every turn state"

      refute scan.will_commit
    end

    test "a SEALED approval block is an answered question and does not feed the gate" do
      blocks = [block(:approval, :sealed), block(:message, :sealed)]

      entries =
        Surface.frontier_entries(model(blocks, revealed: 2, total_events: 2))

      refute Enum.at(entries, 0).pending_input?
      refute Enum.at(entries, 1).pending_input?
    end
  end

  describe "the foldable-window feed (unchanged)" do
    test "the newest block holds the window while the reveal is unfinished, and releases at reveal end" do
      blocks = [block(:message, :sealed), block(:message, :sealed)]

      during =
        Surface.frontier_entries(model(blocks, revealed: 1, total_events: 3))

      refute Enum.at(during, 0).pending_input?

      assert Enum.at(during, 1).pending_input?,
             "newest block sits in the foldable window"

      finished =
        Surface.frontier_entries(model(blocks, revealed: 3, total_events: 3))

      refute Enum.at(finished, 1).pending_input?,
             "the window releases on reveal completion"
    end
  end
end
