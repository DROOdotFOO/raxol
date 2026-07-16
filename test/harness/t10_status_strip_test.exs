defmodule Raxol.Harness.T10StatusStripTest do
  @moduledoc """
  Roadmap unit T10 (status strip). Exercises the acceptance criteria
  verbatim: "fixture drives all fields", "missing data renders `—`
  with explicit invalidation on absent `turn_completed`", "elapsed
  ticks during a long silent tool call". See the property-test sibling
  file (`t10_status_strip_property_test.exs`) for the missing-data
  subset property, the width-degradation property, and the elapsed
  time-shift-invariance property (R11).
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.StatusStrip

  @full_state %{
    context_pct: 42,
    cost: 1.23,
    turn_stage: :tool_call,
    needs_input: false,
    now: 5_000,
    last_event_at: 1_000,
    turn_completed: true
  }

  describe "render/2 - fixture drives all fields (roadmap acceptance)" do
    test "a full state renders every field with exact strings" do
      assert StatusStrip.render(@full_state, 200) == [
               "Input: clear | Stage: tool_call 4s | Ctx: 42% | Cost: $1.23"
             ]
    end

    test "needs_input: true renders the needs-input slot" do
      state = %{@full_state | needs_input: true}

      assert StatusStrip.render(state, 200) == [
               "Input: needs-input | Stage: tool_call 4s | Ctx: 42% | Cost: $1.23"
             ]
    end
  end

  describe "missing-data honesty" do
    test "an empty state renders every slot as the em dash" do
      assert StatusStrip.render(%{}, 200) == [
               "Input: — | Stage: — | Ctx: — | Cost: —"
             ]
    end

    test "needs_input absent (not false) renders —, distinct from false" do
      absent = Map.delete(@full_state, :needs_input)
      false_state = %{@full_state | needs_input: false}

      assert StatusStrip.input_value(absent) == "—"
      assert StatusStrip.input_value(false_state) == "clear"
    end

    test "cost absent renders — in the Cost slot only" do
      state = Map.delete(@full_state, :cost)

      assert StatusStrip.render(state, 200) == [
               "Input: clear | Stage: tool_call 4s | Ctx: 42% | Cost: —"
             ]
    end

    test "turn_stage absent still renders the elapsed half of Stage" do
      state = Map.delete(@full_state, :turn_stage)

      assert StatusStrip.stage_value(state) == "— 4s"
    end
  end

  describe "Ctx invalidation on absent turn_completed (never a stale %)" do
    test "context_pct present but turn_completed missing renders —" do
      state = Map.delete(@full_state, :turn_completed)

      assert StatusStrip.context_value(state) == "—"
    end

    test "context_pct present but turn_completed: false renders —" do
      state = %{@full_state | turn_completed: false}

      assert StatusStrip.context_value(state) == "—"
    end

    test "context_pct present and turn_completed: true renders the pct" do
      assert StatusStrip.context_value(@full_state) == "42%"
    end

    test "context_pct rounds fractional percentages" do
      state = %{@full_state | context_pct: 41.6}

      assert StatusStrip.context_value(state) == "42%"
    end
  end

  describe "elapsed ticker (R11: injected now/last_event_at, no wall clock)" do
    test "advancing injected now advances the elapsed display deterministically" do
      base = %{turn_stage: :thinking, last_event_at: 0, now: nil}

      assert StatusStrip.stage_value(%{base | now: 0}) == "thinking 0s"
      assert StatusStrip.stage_value(%{base | now: 3_000}) == "thinking 3s"
      assert StatusStrip.stage_value(%{base | now: 9_000}) == "thinking 9s"
    end

    test "crossing warn_after_ms appends the slow marker" do
      base = %{turn_stage: :tool_call, last_event_at: 0, now: nil}

      assert StatusStrip.stage_value(%{base | now: 14_999}) ==
               "tool_call 14s"

      assert StatusStrip.stage_value(%{base | now: 15_000}) ==
               "tool_call 15s ⏳"
    end

    test "crossing hung_after_ms prefixes HUNG (long silent tool call)" do
      base = %{turn_stage: :tool_call, last_event_at: 0, now: nil}

      assert StatusStrip.stage_value(%{base | now: 59_999}) ==
               "tool_call 59s ⏳"

      assert StatusStrip.stage_value(%{base | now: 60_000}) ==
               "HUNG tool_call 1m00s"
    end

    test "thresholds are overridable per-call" do
      state = %{
        turn_stage: :tool_call,
        last_event_at: 0,
        now: 5_000,
        warn_after_ms: 1_000,
        hung_after_ms: 4_000
      }

      assert StatusStrip.stage_value(state) == "HUNG tool_call 5s"
    end

    test "either now or last_event_at absent renders no elapsed" do
      only_now = %{turn_stage: :thinking, now: 5_000}
      only_last = %{turn_stage: :thinking, last_event_at: 0}

      assert StatusStrip.stage_value(only_now) == "thinking"
      assert StatusStrip.stage_value(only_last) == "thinking"
    end

    test "minutes formatting pads seconds to two digits" do
      state = %{turn_stage: :tool_call, last_event_at: 0, now: 65_000}

      assert StatusStrip.stage_value(state) == "HUNG tool_call 1m05s"
    end
  end

  describe "width degradation priority order" do
    @wide_state %{
      context_pct: 42,
      cost: 1.23,
      turn_stage: :tool_call,
      needs_input: true,
      now: 4_000,
      last_event_at: 0,
      turn_completed: true
    }

    test "ample width keeps every field" do
      [line] = StatusStrip.render(@wide_state, 200)
      assert line =~ "Input:"
      assert line =~ "Stage:"
      assert line =~ "Ctx:"
      assert line =~ "Cost:"
    end

    test "a narrower width drops Cost first (lowest priority)" do
      full_width = byte_size(hd(StatusStrip.render(@wide_state, 200)))
      without_cost_width = full_width - 12

      [line] = StatusStrip.render(@wide_state, without_cost_width)

      refute line =~ "Cost:"
      assert line =~ "Ctx:"
      assert line =~ "Stage:"
      assert line =~ "Input:"
    end

    test "a very narrow width keeps only Input (highest priority)" do
      [line] = StatusStrip.render(@wide_state, 14)

      assert line =~ "Input:"
      refute line =~ "Stage:"
      refute line =~ "Ctx:"
      refute line =~ "Cost:"
    end

    test "width 0 renders an empty line, never crashes" do
      assert StatusStrip.render(@wide_state, 0) == [""]
    end

    test "field_keys/0 lists all four in priority order" do
      assert StatusStrip.field_keys() == [
               :needs_input,
               :turn_stage,
               :context_pct,
               :cost
             ]
    end
  end

  describe "red-first proof (R8): the width contract catches an over-wide line" do
    test "every rendered line is within its requested width (TextMeasure-measured)" do
      # This is the assertion that, during development, was DEMONSTRATED RED
      # by temporarily disabling `truncate_to_width/2`'s ellipsis branch
      # (making it return the untruncated segment unconditionally). With
      # that change in place this exact test failed on the narrow-width
      # case below (a single `Input: needs-input` segment, 17 display
      # columns, rendered into width 5) because the untouched fallback
      # returned all 17 columns of text into a 5-column budget. Restoring
      # the real truncation (ellipsis-terminated, `TextMeasure`-measured)
      # made it green again. See the PR body for the captured red run.
      state = %{needs_input: true}

      for width <- [0, 1, 2, 5, 10, 17, 18, 50] do
        [line] = StatusStrip.render(state, width)

        assert Raxol.UI.TextMeasure.display_width(line) <= width,
               "width #{width}: #{inspect(line)} exceeded its budget"
      end
    end
  end
end
