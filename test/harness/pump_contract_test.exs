defmodule Raxol.Harness.PumpContractTest do
  @moduledoc """
  Round-trip and totality tests for the FROZEN A0 contract
  (`Raxol.Harness.PumpContract`,
  `docs/proposals/in-flight/harness-tea-migration.md` §3/§8 "A0"):

    1. every constructor produces a term the vocabulary recognizes
       (`message?/1`) with the documented ordering class;
    2. the wire-shaped boundaries decode TOTALLY — malformed lane
       replies / editor outcomes normalize to honest errors, never raw
       garbage into the model, never a crash;
    3. batch-item classification is total and `:unknown` stays
       representable (the loud-loss law needs it);
    4. the ordering falsifier is declared as a pending stub the pump
       reshape must make real (never fake-green).
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.PumpContract
  alias Raxol.Harness.StallDetector.Verdict

  # A representative EventBoundary-normalized event (the nine-field
  # fixture wire shape) — what a live forwarder would have produced.
  defp normalized_event do
    %{
      id: 7,
      turn_id: "turn-1",
      ts: 1_000,
      family: :loop,
      type: :turn_started,
      tier: :durable,
      scope: :session,
      provenance: %{source: "primary", trust: :trusted},
      payload: %{"prompt" => "hi"}
    }
  end

  describe "1. round-trip: every constructor is in the vocabulary" do
    test "each constructed message satisfies message?/1 with its documented ordering class" do
      constructed = [
        {PumpContract.batch([{:event, normalized_event()}]), :fifo},
        {PumpContract.reveal(), :fifo},
        {PumpContract.key(%Event{type: :key, data: %{char: "a"}}),
         :input_first},
        {PumpContract.resize(120, 40), :fifo},
        {PumpContract.tick(5_000), :fifo},
        {PumpContract.session_down(:shutdown), :fifo},
        {PumpContract.feed_down(:forwarder, :killed), :fifo},
        {PumpContract.feed_down(:cadence, :killed), :fifo},
        {PumpContract.feed_down(:subscribe, :nxsession), :fifo},
        {PumpContract.submit_result(:ok), :fifo},
        {PumpContract.submit_result({:error, :busy}), :fifo},
        {PumpContract.steer_result({:ok, {:accepted, %{}}}), :fifo},
        {PumpContract.steer_result({:ok, {:duplicate, %{}}}), :fifo},
        {PumpContract.steer_result({:error, {:stale_turn, "a", "b"}}), :fifo},
        {PumpContract.steer_result({:error, :no_live_turn}), :fifo},
        {PumpContract.steer_result({:error, {:timeout, 5_000}}), :fifo},
        {PumpContract.steer_result({:error, {:crashed, :boom}}), :fifo},
        {PumpContract.steer_result({:error, :steer_in_flight}), :fifo},
        {PumpContract.interrupt_result(:ok), :fifo},
        {PumpContract.interrupt_result({:error, :nolane}), :fifo},
        {PumpContract.approval_answer_result(:ok), :fifo},
        {PumpContract.stall_verdict(nil), :fifo},
        {PumpContract.stall_verdict(%Verdict{class: :stalled}), :fifo},
        {PumpContract.editor_result(
           {:ok, %{text: "draft", width: 80, rows: 24, degraded: []}}
         ), :fifo},
        {PumpContract.editor_result(
           {:kept, :editor_nonzero, %{width: 80, rows: 24, degraded: []}}
         ), :fifo},
        {PumpContract.editor_result({:error, {:reader_disable, :enoent}}),
         :fifo},
        {PumpContract.isig_reasserted(), :fifo},
        {PumpContract.lane_notice("» hello"), :fifo},
        {PumpContract.lane_notice(nil), :fifo},
        {PumpContract.debug_highlight(:composer), :fifo},
        {PumpContract.debug_highlight(nil), :fifo},
        {PumpContract.seal_lines(["a", :not_a_binary]), :fifo}
      ]

      for {msg, expected_class} <- constructed do
        assert PumpContract.message?(msg),
               "constructor output not in vocabulary: #{inspect(msg)}"

        assert PumpContract.ordering_class(msg) == expected_class,
               "wrong ordering class for #{inspect(msg)}"
      end
    end

    test "only {:key, _} is input-first — the guarantee names keystrokes and nothing else" do
      assert PumpContract.ordering_class(
               PumpContract.key(%Event{type: :key, data: %{char: "q"}})
             ) == :input_first

      assert PumpContract.ordering_class(PumpContract.batch([])) == :fifo
      assert PumpContract.ordering_class(:anything_else) == :fifo
    end
  end

  describe "2. key/1 totality (the input boundary)" do
    test "a real key Event normalizes to the canonical map" do
      {:key, norm} = PumpContract.key(%Event{type: :key, data: %{char: "a"}})

      assert norm.kind == :char
      assert norm.char == "a"
      assert %{ctrl: false, alt: false, shift: false, meta: false} = norm.mods
    end

    test "garbage input normalizes to kind :other, never raises" do
      {:key, norm} = PumpContract.key(:not_an_event)
      assert norm.kind == :other

      {:key, norm} = PumpContract.key(nil)
      assert norm.kind == :other
    end

    test "ctrl-c survives normalization with mods intact (the quit protocol reads them)" do
      {:key, norm} =
        PumpContract.key(%Event{
          type: :key,
          data: %{char: "c", ctrl: true, alt: false, shift: false, meta: false}
        })

      assert norm.char == "c"
      assert norm.mods.ctrl == true
    end
  end

  describe "3. resize/2 rides the system-event path" do
    test "builds the %Event{type: :resize} shape the Dispatcher's resize handler matches" do
      event = PumpContract.resize(132, 43)

      # The exact pattern from dispatcher.ex handle_resize_event/2 +
      # system_event?/1 — this is what keeps the Engine's size in sync.
      assert %Event{type: :resize, data: %{width: 132, height: 43}} = event
      assert PumpContract.message?(event)
    end
  end

  describe "4. total decode at the lane-reply boundary" do
    test "documented dispatch replies pass through" do
      assert PumpContract.submit_result(:ok) == {:submit_result, :ok}

      assert PumpContract.submit_result({:error, :busy}) ==
               {:submit_result, {:error, :busy}}
    end

    test "a malformed lane reply becomes an honest error, never raw garbage" do
      assert {:submit_result, {:error, {:invalid_lane_reply, _}}} =
               PumpContract.submit_result({:unexpected, self()})

      assert {:interrupt_result, {:error, {:invalid_lane_reply, _}}} =
               PumpContract.interrupt_result(:sent)

      assert {:approval_answer_result, {:error, {:invalid_lane_reply, _}}} =
               PumpContract.approval_answer_result([:ok])

      assert {:steer_result, {:error, {:invalid_lane_reply, _}}} =
               PumpContract.steer_result({:ok, :accepted_without_ref})
    end

    test "a malformed editor outcome becomes an honest error" do
      assert {:editor_result, {:error, {:invalid_editor_outcome, _}}} =
               PumpContract.editor_result(:done)

      assert {:editor_result, {:error, {:invalid_editor_outcome, _}}} =
               PumpContract.editor_result({:ok, %{text: "no geometry"}})
    end
  end

  describe "5. batch-item classification is total (loud-loss law)" do
    test "the three known kinds classify" do
      assert PumpContract.batch_item_kind({:event, normalized_event()}) ==
               :event

      assert PumpContract.batch_item_kind({:cadence_dropped, 3}) ==
               :cadence_dropped

      assert PumpContract.batch_item_kind({:malformed_event}) ==
               :malformed_event
    end

    test "anything else is :unknown — representable so update/2 can seal a marker for it" do
      assert PumpContract.batch_item_kind({:future_reserved_marker, 1}) ==
               :unknown

      assert PumpContract.batch_item_kind(:garbage) == :unknown
      assert PumpContract.batch_item_kind(nil) == :unknown
    end

    test "batch/1 forwards unrecognized items verbatim — the pump never filters" do
      items = [{:event, normalized_event()}, {:future_reserved_marker, 1}]
      assert PumpContract.batch(items) == {:batch, items}
    end
  end

  describe "6. message?/1 is total and rejects near-misses" do
    test "false for non-vocabulary terms, no raise" do
      refute PumpContract.message?(:tick)
      refute PumpContract.message?({:tick, :not_an_integer})
      refute PumpContract.message?({:feed_down, :other_source, :reason})
      refute PumpContract.message?({:lane_notice, 42})
      refute PumpContract.message?({:stall_verdict, :stalled})
      refute PumpContract.message?(%Event{type: :key, data: %{}})
      refute PumpContract.message?(nil)
    end
  end

  describe "7. ordering property (falsifier stub — pump reshape makes it real)" do
    # THE FALSIFIER the pump reshape must satisfy (PumpContract moduledoc
    # §2; spec §3 "honest residual" / §9 risk 1):
    #
    #   Input enters the Dispatcher ahead of any batch that was pending
    #   with it at the pump seam.
    #
    # Shape of the real property, once `Raxol.Harness.SessionPump`
    # exists:
    #
    #   * flood the pump with N `{:render_batch, [...]}` deliveries from
    #     a scripted cadence while simultaneously delivering
    #     `{:inline_input, key_event}`;
    #   * capture the pump→Dispatcher forward order (test Dispatcher =
    #     the test process);
    #   * assert every `{:key, _}` forward precedes every `{:batch, _}`
    #     forward that was pending with it in the pump mailbox at
    #     forward time (`PumpContract.ordering_class/1` is the oracle);
    #   * assert the RESIDUAL bound: a key forwarded behind an
    #     already-forwarded batch waits at most one update fold + one
    #     coalesced paint (input-latency-under-flood measurement, the
    #     §9 risk-1 number V ruled must exist before option (c) is ever
    #     revisited).
    #
    # Marked skip, not fake-green: there is no pump to falsify yet.
    @tag :skip
    test "input enters the Dispatcher ahead of any batch pending with it at the pump seam" do
      flunk("""
      Pending on the pump reshape (A-side of unit A0). This stub is the
      contract's falsifier — implement it against SessionPump per the
      comment above; do not delete it and do not green it without a real
      pump under test. Contract: Raxol.Harness.PumpContract moduledoc §2.
      """)
    end
  end
end
