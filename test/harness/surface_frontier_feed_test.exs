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

  # -- real-model helpers (Surface.new over a replayed session) ------------

  defp two_block_events do
    [
      %{
        id: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{prompt: "go"}
      },
      %{
        id: 2,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{item_id: "i1", item_type: "message"}
      },
      %{
        id: 3,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{item_id: "i1", item_type: "message", content: "first"}
      },
      %{
        id: 4,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{item_id: "i2", item_type: "message"}
      },
      %{
        id: 5,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{item_id: "i2", item_type: "message", content: "second"}
      },
      %{
        id: 6,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{final: true}
      }
    ]
  end

  defp real_model(events) do
    {:ok, device} = StringIO.open("")

    Surface.new(events,
      device: device,
      width: 80,
      rows: 24,
      footer_rows: 6,
      mode: :inline_log,
      capabilities: nil
    )
  end

  defp advance_times(model, n) do
    Enum.reduce(1..n, model, fn _i, m ->
      {m, _} = Surface.advance(m)
      m
    end)
  end

  describe "the sealed? boundary (fill-guard vs classifier feed agreement)" do
    test "the fold fill-guard refuses exactly the indices the frontier feed marks committed?" do
      # 5 of 6 events revealed: both blocks exist, block 0 sealed, block 1
      # held by the foldable window -- painted_count sits exactly on the
      # boundary this test pins.
      model = two_block_events() |> real_model() |> advance_times(5)
      assert model.painted_count == 1

      committed_flags =
        model |> Surface.frontier_entries() |> Enum.map(& &1.committed?)

      assert committed_flags == [true, false]

      # Drive the ONLY mutation channel aimed at a block (the fold
      # toggle) at each index, through the public input path. The
      # refusal boundary must be the SAME boundary the classifier feed
      # reports -- both sides now read one predicate, and this test is
      # the tripwire if that ever un-unifies.
      browsing = Surface.focus_transcript(model)

      on_sealed =
        browsing
        |> Surface.handle_input(Raxol.Core.Events.Event.key("j"))
        |> Surface.handle_input(Raxol.Core.Events.Event.key("z"))

      assert on_sealed.fold_overrides == %{},
             "index 0 is committed? in the frontier feed -- the fill-guard " <>
               "must refuse it identically"

      on_pending =
        on_sealed
        |> Surface.handle_input(Raxol.Core.Events.Event.key("j"))
        |> Surface.handle_input(Raxol.Core.Events.Event.key("z"))

      assert Map.has_key?(on_pending.fold_overrides, 1),
             "index 1 is NOT committed? in the frontier feed -- the " <>
               "fill-guard must accept the fold identically"
    end
  end

  describe "the one-block tail bound (what keeps the single-block preview honest)" do
    test "after every advance over every shipped fixture, at most ONE block sits past the committed cursor" do
      # The footer's pending preview renders exactly one block. That is
      # honest only while the unsealed suffix past `painted_count` is at
      # most one block long -- true today because the only frontier hold
      # a shipped producer can create is the foldable window on the
      # NEWEST block. The moment a producer emits live blocks (a
      # mid-list awaiting-input approval holding finalized blocks behind
      # it), this bound breaks: this test then fails LOUDLY, forcing the
      # multi-block tail rendering decision (the live-lane follow-up)
      # instead of letting held blocks silently vanish from view.
      sessions_dir = Path.join(["test", "fixtures", "harness", "sessions"])
      names = Surface.list_fixture_sessions(sessions_dir)
      assert names != [], "no shipped fixtures found -- the pin needs corpus"

      for name <- names do
        {:ok, session} =
          Raxol.Harness.Fixture.load(Path.join(sessions_dir, name <> ".jsonl"))

        model = real_model(session)
        cap = length(model.events) * 2 + 10

        Enum.reduce_while(1..cap, model, fn _i, m ->
          {m, outcome} = Surface.advance(m)

          unsealed = length(m.projection.blocks) - m.painted_count

          assert unsealed <= 1,
                 "fixture #{name}: #{unsealed} blocks past the committed " <>
                   "cursor -- the one-block pending preview would hide " <>
                   "#{unsealed - 1} of them (multi-block tail rendering " <>
                   "is the live-lane follow-up this pin exists to force)"

          if outcome == :done, do: {:halt, m}, else: {:cont, m}
        end)
      end
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
