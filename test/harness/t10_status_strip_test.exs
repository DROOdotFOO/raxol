defmodule Raxol.Harness.T10StatusStripTest do
  @moduledoc """
  Roadmap unit T10 (status strip), charged-minimum form.

  RED-FIRST (live-session strip regression, V's frame
  `Input: clear | Stage: item_delta 0s | Ctx: — | Cost: —` mid-inference):
  this suite pins the three ratified rulings the old form violated --

    1. **em-dash voids are banned** (charged minimum): a field with
       nothing true to say does not render; `Ctx`/`Cost` while unknown
       are ABSENT, never `—`.
    2. **raw event vocabulary is banned**: the strip speaks operator
       phases (`responding`, `running <tool>`, `awaiting approval`,
       lowercase §4.5 voice), never `item_delta`/`turn_started`/....
    3. **`Input: clear` is dropped entirely** -- the composer shows its
       own state; a needs-input wait is a PHASE, not a labelled slot.

  The live form is minimal: phase + elapsed, then cost/context only when
  real numbers exist. The elapsed ticker (R11: injected `now` /
  `last_event_at`, never wall clock), the SLOW/HUNG escalation markers,
  the ALERT stall notice, width degradation, and control-character
  sanitization all carry over from the original T10 unit unchanged.

  See the property-test sibling (`t10_status_strip_property_test.exs`)
  for the width-degradation and time-shift-invariance properties.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.StatusStrip

  @live_state %{
    turn_stage: :item_delta,
    now: 4_000,
    last_event_at: 0
  }

  describe "ruling 1: charged minimum -- no em-dash voids, absent fields don't render" do
    test "a live streaming turn with unknown ctx/cost renders ONLY the phase + elapsed" do
      assert StatusStrip.render(@live_state, 200) == ["responding 4s"]
    end

    test "no rendered live-turn line ever contains an em dash" do
      for stage <- [
            :turn_started,
            :item_started,
            :item_delta,
            :item_completed,
            :error
          ] do
        [line] =
          StatusStrip.render(
            %{turn_stage: stage, now: 1_000, last_event_at: 0},
            200
          )

        refute line =~ "—",
               "stage #{inspect(stage)} rendered an em-dash void: #{inspect(line)}"
      end
    end

    test "cost renders only when a real number exists" do
      assert StatusStrip.render(Map.put(@live_state, :cost, 1.23), 200) == [
               "responding 4s | $1.23"
             ]

      refute hd(StatusStrip.render(@live_state, 200)) =~ "$"
    end

    test "context renders only when fresh (turn_completed) AND numeric" do
      # Mid-turn (turn_completed absent/false): a stale % must not render.
      state = Map.put(@live_state, :context_pct, 42)
      assert StatusStrip.render(state, 200) == ["responding 4s"]

      # Fresh: renders lowercase, labelled minimally.
      fresh = Map.merge(state, %{turn_completed: true, turn_stage: :error})
      [line] = StatusStrip.render(fresh, 200)
      assert line =~ "ctx 42%"
    end

    test "an empty state renders an empty line, never labelled voids" do
      assert StatusStrip.render(%{}, 200) == [""]
    end
  end

  describe "ruling 2: operator phases, never raw event vocabulary" do
    test "streaming maps to the STREAMING ITEM's phase: message → responding, reasoning → thinking" do
      assert StatusStrip.phase_value(%{turn_stage: :item_delta}) == "responding"

      # V's field report: the word flashed "responding" mid-thought on
      # every reasoning delta — a streaming thought is thinking.
      assert StatusStrip.phase_value(%{
               turn_stage: :item_delta,
               last_item_type: :reasoning
             }) == "thinking"

      assert StatusStrip.phase_value(%{
               turn_stage: :item_delta,
               last_item_type: "reasoning"
             }) == "thinking"
    end

    test "a finished thought stays thinking — only a completed message earns responding" do
      assert StatusStrip.phase_value(%{
               turn_stage: :item_completed,
               last_item_type: :reasoning
             }) == "thinking"

      assert StatusStrip.phase_value(%{
               turn_stage: :item_completed,
               last_item_type: :message
             }) == "responding"
    end

    test "turn_started is the bare-spinner wait; item_started maps to thinking" do
      # The pre-stream wait carries no phase word (a bare spinner + elapsed) --
      # the live thinking display is the ShadowStream in the tail, not a
      # duplicate label here.
      assert StatusStrip.phase_value(%{turn_stage: :turn_started}) == ""
      assert StatusStrip.phase_value(%{turn_stage: :item_started}) == "thinking"
    end

    test "a dispatched tool maps to running + the tool name" do
      state = %{turn_stage: :item_completed, running_tool: "list_dir"}
      assert StatusStrip.phase_value(state) == "running list_dir"
    end

    test "a tool completion without a name still says running tool" do
      state = %{
        turn_stage: :item_completed,
        running_tool: nil,
        last_item_type: :tool_use
      }

      assert StatusStrip.phase_value(state) == "running tool"
    end

    test "a tool_result completion maps back to thinking (model computes next step)" do
      state = %{turn_stage: :item_completed, last_item_type: :tool_result}
      assert StatusStrip.phase_value(state) == "thinking"
    end

    test "a message completion mid-turn maps to responding" do
      state = %{turn_stage: :item_completed, last_item_type: :message}
      assert StatusStrip.phase_value(state) == "responding"
    end

    test "no raw loop-event name ever appears in a rendered line" do
      raw_names = ~w(item_delta item_started item_completed turn_started
                     approval_requested approval_decided state_change)

      for stage <- [
            :turn_started,
            :item_started,
            :item_delta,
            :item_completed,
            :approval_requested,
            :approval_decided,
            :state_change
          ] do
        [line] =
          StatusStrip.render(
            %{turn_stage: stage, now: 1_000, last_event_at: 0},
            200
          )

        for raw <- raw_names do
          refute line =~ raw,
                 "stage #{inspect(stage)} leaked raw vocabulary #{raw}: #{inspect(line)}"
        end
      end
    end

    test "an approval wait is a phase: awaiting approval" do
      state = %{turn_stage: :item_delta, needs_input: true}
      assert StatusStrip.phase_value(state) == "awaiting approval"
    end

    test "an errored turn maps to failed" do
      assert StatusStrip.phase_value(%{turn_stage: :error}) == "failed"
    end

    test "a completed or canceled turn has no phase (strip yields to silence)" do
      assert StatusStrip.phase_value(%{turn_stage: :turn_completed}) == nil
      assert StatusStrip.phase_value(%{turn_stage: :turn_canceled}) == nil
      assert StatusStrip.phase_value(%{}) == nil
    end
  end

  describe "ruling 3: no Input field" do
    test "needs_input never renders as a labelled slot" do
      state = %{
        turn_stage: :item_delta,
        needs_input: true,
        now: 5_000,
        last_event_at: 0
      }

      [line] = StatusStrip.render(state, 200)
      assert line == "awaiting approval 5s"
      refute line =~ "Input"
      refute line =~ "clear"
    end
  end

  describe "elapsed ticker (R11: injected now/last_event_at, no wall clock)" do
    test "advancing injected now advances the elapsed display deterministically" do
      base = %{turn_stage: :item_delta, last_event_at: 0, now: nil}

      assert StatusStrip.render(%{base | now: 0}, 200) == ["responding 0s"]
      assert StatusStrip.render(%{base | now: 3_000}, 200) == ["responding 3s"]
      assert StatusStrip.render(%{base | now: 9_000}, 200) == ["responding 9s"]
    end

    test "crossing warn_after_ms appends the slow marker" do
      base = %{turn_stage: :item_delta, last_event_at: 0, now: nil}

      assert StatusStrip.render(%{base | now: 14_999}, 200) ==
               ["responding 14s"]

      assert StatusStrip.render(%{base | now: 15_000}, 200) ==
               ["responding 15s SLOW"]
    end

    test "crossing hung_after_ms prefixes HUNG (long silent tool call)" do
      base = %{
        turn_stage: :item_completed,
        running_tool: "run_tests",
        last_event_at: 0,
        now: nil
      }

      assert StatusStrip.render(%{base | now: 59_999}, 200) ==
               ["running run_tests 59s SLOW"]

      assert StatusStrip.render(%{base | now: 60_000}, 200) ==
               ["HUNG running run_tests 1m00s"]
    end

    test "thresholds are overridable per-call" do
      state = %{
        turn_stage: :item_delta,
        last_event_at: 0,
        now: 5_000,
        warn_after_ms: 1_000,
        hung_after_ms: 4_000
      }

      assert StatusStrip.render(state, 200) == ["HUNG responding 5s"]
    end

    test "either now or last_event_at absent renders the bare phase" do
      only_now = %{turn_stage: :item_delta, now: 5_000}
      only_last = %{turn_stage: :item_delta, last_event_at: 0}

      assert StatusStrip.render(only_now, 200) == ["responding"]
      assert StatusStrip.render(only_last, 200) == ["responding"]
    end

    test "minutes formatting pads seconds to two digits" do
      state = %{turn_stage: :item_delta, last_event_at: 0, now: 65_000}

      assert StatusStrip.render(state, 200) == ["HUNG responding 1m05s"]
    end
  end

  describe "width degradation priority order (phase > ctx > cost)" do
    @wide_state %{
      turn_stage: :error,
      turn_completed: true,
      context_pct: 42,
      cost: 1.23,
      now: 4_000,
      last_event_at: 0
    }

    test "ample width keeps every present segment" do
      assert StatusStrip.render(@wide_state, 200) == [
               "failed 4s | ctx 42% | $1.23"
             ]
    end

    test "a narrower width drops cost first (lowest priority)" do
      [full_line] = StatusStrip.render(@wide_state, 200)

      cost_and_separator_width =
        Raxol.UI.TextMeasure.display_width("$1.23") +
          Raxol.UI.TextMeasure.display_width(" | ")

      without_cost_width =
        Raxol.UI.TextMeasure.display_width(full_line) - cost_and_separator_width

      [line] = StatusStrip.render(@wide_state, without_cost_width)

      refute line =~ "$"
      assert line =~ "ctx"
      assert line =~ "failed"
    end

    test "a very narrow width keeps only the phase (highest priority)" do
      [line] = StatusStrip.render(@wide_state, 10)

      assert line =~ "failed"
      refute line =~ "ctx"
      refute line =~ "$"
    end

    test "width 0 renders an empty line, never crashes" do
      assert StatusStrip.render(@wide_state, 0) == [""]
    end

    test "field_keys/0 lists the three segments in priority order" do
      assert StatusStrip.field_keys() == [:turn_stage, :context_pct, :cost]
    end
  end

  describe "the width contract catches an over-wide line" do
    test "every rendered line is within its requested width (TextMeasure-measured)" do
      state = %{
        turn_stage: :item_completed,
        running_tool: "a_rather_long_tool_name",
        now: 30_000,
        last_event_at: 0
      }

      for width <- [0, 1, 2, 5, 10, 17, 18, 50] do
        [line] = StatusStrip.render(state, width)

        assert Raxol.UI.TextMeasure.display_width(line) <= width,
               "width #{width}: #{inspect(line)} exceeded its budget"
      end
    end
  end

  describe "glyph width honesty (review fix: U+23F3 ⏳ measured 1 col, rendered 2)" do
    test "every glyph this module can emit measures exactly 1 display column per character" do
      for glyph <- StatusStrip.glyphs(), grapheme <- String.graphemes(glyph) do
        assert Raxol.UI.TextMeasure.display_width(grapheme) == 1,
               "#{inspect(grapheme)} (from #{inspect(glyph)}) must be " <>
                 "single-cell per TextMeasure"
      end
    end
  end

  describe "stall verdict notice (the stall detector's one integration seam)" do
    @looping_verdict %{
      class: :looping,
      evidence: %{
        reason: :repetition,
        tool: "read_file",
        count: 4,
        summary: "possible loop: read_file x4 same args"
      }
    }

    test "a :looping verdict prepends an ALERT segment naming the evidence" do
      state = Map.put(@live_state, :stall_verdict, @looping_verdict)

      assert StatusStrip.render(state, 200) == [
               "ALERT: possible loop: read_file x4 same args | responding 4s"
             ]
    end

    test "a :stalled verdict renders the same needs-attention notice" do
      verdict = %{
        class: :stalled,
        evidence: %{reason: :no_progress, summary: "no output for 1m15s"}
      }

      [line] = StatusStrip.render(%{stall_verdict: verdict}, 200)

      assert line =~ "ALERT: no output for 1m15s"
    end

    test "a :suspect verdict renders NO notice (pre-alarms stay off the strip)" do
      verdict = %{
        class: :suspect,
        evidence: %{
          reason: :repetition,
          summary: "repeated call: x x3 same args"
        }
      }

      state = Map.put(@live_state, :stall_verdict, verdict)

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@live_state, 200)
    end

    test "an :ok verdict and an absent key render identically" do
      ok_verdict = %{class: :ok, evidence: nil}
      state = Map.put(@live_state, :stall_verdict, ok_verdict)

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@live_state, 200)
    end

    test "a verdict without evidence renders NO notice (no unexplained alarms)" do
      state =
        Map.put(@live_state, :stall_verdict, %{class: :stalled, evidence: nil})

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@live_state, 200)
    end

    test "the ALERT segment has highest priority under width pressure" do
      state = Map.put(@live_state, :stall_verdict, @looping_verdict)
      alert = "ALERT: possible loop: read_file x4 same args"

      [line] =
        StatusStrip.render(state, Raxol.UI.TextMeasure.display_width(alert))

      assert line == alert
      refute line =~ "responding"
    end

    test "an ESC-laden evidence summary is sanitized like any footer text" do
      verdict = %{
        class: :looping,
        evidence: %{reason: :repetition, summary: "loop: x\e[2J y\nz"}
      }

      [line] = StatusStrip.render(%{stall_verdict: verdict}, 200)

      refute line =~ "\e"
      refute line =~ "\n"
      assert line =~ "ALERT: loop: x[2J yz"
    end
  end

  describe "shared thresholds (single source of truth for the hung heuristic)" do
    test "the warn/hung defaults are exposed for the stall detector to reuse" do
      assert StatusStrip.default_warn_after_ms() == 15_000
      assert StatusStrip.default_hung_after_ms() == 60_000
    end
  end

  describe "sanitization (injection guard: strip output reaches a byte-level pinned writer)" do
    test "an ESC-laden custom stage is sanitized -- no ESC byte reaches the output" do
      # Custom (non-vocabulary) stages pass through as text; they ride
      # the same sanitize sweep as every other injected string.
      state = %{turn_stage: "plan\e[2J"}

      value = StatusStrip.phase_value(state)

      refute value =~ "\e", "sanitized stage must not carry an ESC byte"
      assert value == "plan[2J"
    end

    test "a newline-laden stage collapses to a single line" do
      state = %{turn_stage: "a\nb"}

      value = StatusStrip.phase_value(state)

      refute value =~ "\n"
      refute value =~ "\r"
      assert value == "ab"
    end

    test "an ESC-laden running_tool name is sanitized" do
      state = %{turn_stage: :item_completed, running_tool: "rm\e[2J"}

      assert StatusStrip.phase_value(state) == "running rm[2J"
    end

    test "a sanitized custom stage still carries its elapsed suffix" do
      state = %{turn_stage: "plan\e[2J", now: 3_000, last_event_at: 0}

      assert StatusStrip.render(state, 200) == ["plan[2J 3s"]
    end
  end

  describe "activity spinner (fix 4: the 'model is still thinking' signal)" do
    # The braille frame the assembly layer resolves and injects; the strip
    # only ever prepends whatever glyph it is given.
    @spin "⠴"

    test "a :generating turn with NO events shows thinking + elapsed -- the blocking-round signal" do
      # No turn_stage at all (a blocking complete/2 round: zero events), only
      # the raised activity flag. This is the model ACTIVELY thinking with no
      # stream events to reveal it, so the strip is the only "still thinking?"
      # signal -- phase "thinking" (V's charged-minimum intent). Distinct from
      # the STREAMING pre-stream WAIT, where a :turn_started EVENT is present
      # and TAKES PRECEDENCE, rendering the bare spinner (see phase_word/2).
      state = %{activity: :generating, now: 5_000, last_event_at: 0}
      assert StatusStrip.phase_value(state) == "thinking"
      assert StatusStrip.render(state, 200) == ["thinking 5s"]
    end

    test "animating? is true while :generating and the injected spinner leads the phase" do
      state = %{
        activity: :generating,
        now: 5_000,
        last_event_at: 0,
        spinner: @spin
      }

      assert StatusStrip.animating?(state)
      assert StatusStrip.render(state, 200) == ["#{@spin} thinking 5s"]
    end

    test "the spinner ADVANCES across frames (a caller ticking the frame glyph)" do
      base = %{activity: :generating, now: 5_000, last_event_at: 0}
      [line_a] = StatusStrip.render(Map.put(base, :spinner, "⠋"), 200)
      [line_b] = StatusStrip.render(Map.put(base, :spinner, "⠙"), 200)
      assert line_a == "⠋ thinking 5s"
      assert line_b == "⠙ thinking 5s"
      refute line_a == line_b
    end

    test ":running_tool animates and names the running tool" do
      state = %{
        activity: :running_tool,
        running_tool: "grep",
        now: 2_000,
        last_event_at: 0,
        spinner: @spin
      }

      assert StatusStrip.animating?(state)
      assert StatusStrip.render(state, 200) == ["#{@spin} running grep 2s"]
    end

    test ":responding animates (streaming content)" do
      state = %{
        activity: :responding,
        now: 1_000,
        last_event_at: 0,
        spinner: @spin
      }

      assert StatusStrip.animating?(state)
      assert StatusStrip.render(state, 200) == ["#{@spin} responding 1s"]
    end

    test ":idle does NOT animate -- no spinner (operator-paced)" do
      state = %{activity: :idle, turn_stage: :turn_started, spinner: @spin}
      refute StatusStrip.animating?(state)
      # A stale spinner glyph in state is never shown when not animating.
      refute hd(StatusStrip.render(state, 200)) =~ @spin
    end

    test "awaiting-approval does NOT animate, even with an active activity flag" do
      state = %{
        activity: :generating,
        needs_input: true,
        now: 30_000,
        last_event_at: 0,
        spinner: @spin
      }

      refute StatusStrip.animating?(state)
      [line] = StatusStrip.render(state, 200)
      assert line =~ "awaiting approval"
      refute line =~ @spin
    end

    test "a fault does NOT animate (phase 'failed' is not active work)" do
      state = %{activity: :generating, turn_stage: :error, spinner: @spin}
      refute StatusStrip.animating?(state)
      refute hd(StatusStrip.render(state, 200)) =~ @spin
    end

    test "the activity flag is authoritative across an inter-round turn_completed" do
      # An inter-round `turn_completed{final: false}` sets turn_stage to
      # :turn_completed (which phase_word maps to nil), but the turn is
      # still in flight -- the driver keeps :generating raised, so the
      # spinner keeps pulsing "thinking".
      state = %{
        activity: :generating,
        turn_stage: :turn_completed,
        now: 4_000,
        last_event_at: 0,
        spinner: @spin
      }

      assert StatusStrip.animating?(state)
      assert StatusStrip.render(state, 200) == ["#{@spin} thinking 4s"]
    end

    test "with no activity flag (fixture/replay) the strip never animates" do
      state = %{
        turn_stage: :item_delta,
        now: 4_000,
        last_event_at: 0,
        spinner: @spin
      }

      refute StatusStrip.animating?(state)
      # Byte-identical to the pre-fix render: phase + elapsed, no spinner.
      assert StatusStrip.render(state, 200) == ["responding 4s"]
    end

    test "the spinner rides INSIDE the phase segment, so width degradation clamps it" do
      state = %{
        activity: :generating,
        now: 5_000,
        last_event_at: 0,
        spinner: @spin
      }

      [line] = StatusStrip.render(state, 6)
      assert Raxol.UI.TextMeasure.display_width(line) <= 6
    end
  end
end
