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
               "tool_call 15s SLOW"
    end

    test "crossing hung_after_ms prefixes HUNG (long silent tool call)" do
      base = %{turn_stage: :tool_call, last_event_at: 0, now: nil}

      assert StatusStrip.stage_value(%{base | now: 59_999}) ==
               "tool_call 59s SLOW"

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
      [full_line] = StatusStrip.render(@wide_state, 200)

      # Derive the drop-Cost boundary from the actual rendered Cost
      # segment + separator width, rather than a hardcoded magic number
      # that would silently rot if the label, value formatting, or
      # separator ever changed shape.
      cost_segment = "Cost: #{StatusStrip.cost_value(@wide_state)}"

      cost_and_separator_width =
        Raxol.UI.TextMeasure.display_width(cost_segment) +
          Raxol.UI.TextMeasure.display_width(" | ")

      without_cost_width =
        Raxol.UI.TextMeasure.display_width(full_line) - cost_and_separator_width

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

  describe "glyph width honesty (review fix: U+23F3 ⏳ measured 1 col, rendered 2)" do
    test "every glyph this module can emit measures exactly 1 display column per character" do
      # `CharacterHandling.wide_char?/1`'s range table has no entry
      # below the Misc Symbols and Pictographs block (0x1F300+), so
      # Unicode Emoji_Presentation glyphs below that codepoint --
      # including the hourglass U+23F3 this module used to emit for
      # the warn-threshold marker -- measure as width 1 even though
      # real terminals commonly render them 2 columns wide. That
      # mismatch let the strip silently overflow its own pinned-width
      # guarantee for the whole 15s-60s "slow" window. This regression
      # test pins every glyph `StatusStrip.glyphs/0` declares (plus any
      # future addition) to a verified single-cell measurement, so a
      # reintroduced ambiguous/wide-rendering glyph fails loudly here
      # instead of silently in production.
      #
      # The true fix is upstream: Emoji_Presentation coverage in
      # `Raxol.Terminal.CharacterHandling`'s width table (not just East
      # Asian Width ranges). Once that lands and `wide_char?/1`
      # correctly flags emoji-presentation glyphs as 2 columns wide, a
      # fancier glyph may safely return here.
      for glyph <- StatusStrip.glyphs(), grapheme <- String.graphemes(glyph) do
        assert Raxol.UI.TextMeasure.display_width(grapheme) == 1,
               "#{inspect(grapheme)} (from #{inspect(glyph)}) must be " <>
                 "single-cell per TextMeasure"
      end
    end
  end

  describe "stall verdict notice (the stall detector's one integration seam)" do
    # RED-FIRST: these tests were written and run before `render/2` knew
    # the `:stall_verdict` key existed -- every rendering assertion below
    # failed (the key was silently ignored, no ALERT segment appeared)
    # until the wiring landed.

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
      state = Map.put(@full_state, :stall_verdict, @looping_verdict)

      assert StatusStrip.render(state, 200) == [
               "ALERT: possible loop: read_file x4 same args | " <>
                 "Input: clear | Stage: tool_call 4s | Ctx: 42% | Cost: $1.23"
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

      state = Map.put(@full_state, :stall_verdict, verdict)

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@full_state, 200)
    end

    test "an :ok verdict and an absent key render identically" do
      ok_verdict = %{class: :ok, evidence: nil}
      state = Map.put(@full_state, :stall_verdict, ok_verdict)

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@full_state, 200)
    end

    test "a verdict without evidence renders NO notice (no unexplained alarms)" do
      # The detector's honesty floor says no verdict without evidence;
      # the strip enforces the same law defensively -- an alarm the
      # operator can't act on is noise, not information.
      state =
        Map.put(@full_state, :stall_verdict, %{class: :stalled, evidence: nil})

      assert StatusStrip.render(state, 200) ==
               StatusStrip.render(@full_state, 200)
    end

    test "the ALERT segment has highest priority under width pressure" do
      state = Map.put(@full_state, :stall_verdict, @looping_verdict)
      alert = "ALERT: possible loop: read_file x4 same args"

      [line] =
        StatusStrip.render(state, Raxol.UI.TextMeasure.display_width(alert))

      assert line == alert
      refute line =~ "Input:"
    end

    test "an ESC-laden evidence summary is sanitized like any footer text" do
      # Evidence summaries embed tool names, which come straight from
      # agent events -- the same injection surface as `turn_stage`.
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

  describe "stage sanitization (injection guard: turn_stage reaches a byte-level pinned writer unsanitized)" do
    test "an ESC-laden stage is sanitized -- no ESC byte reaches the output" do
      # RED-FIRST: before `sanitize_stage/1` existed, `stage_value/1`
      # interpolated `turn_stage` verbatim. A stage carrying
      # `"plan\e[2J"` (a clear-screen CSI sequence) would put a live
      # ESC byte into the strip's output, which the T2c footer path
      # writes directly to the pinned terminal region -- an operator
      # rendering an attacker- or bug-controlled `turn_stage` could
      # have their screen cleared or cursor relocated by what should
      # be plain status text.
      state = %{turn_stage: "plan\e[2J"}

      value = StatusStrip.stage_value(state)

      refute value =~ "\e", "sanitized stage must not carry an ESC byte"
      assert value == "plan[2J"
    end

    test "a newline-laden stage collapses to a single line" do
      # RED-FIRST: an unsanitized `turn_stage` of `"a\nb"` would split
      # the pinned single-line footer across two terminal rows.
      state = %{turn_stage: "a\nb"}

      value = StatusStrip.stage_value(state)

      refute value =~ "\n"
      refute value =~ "\r"
      assert value == "ab"
    end

    test "a sanitized stage still carries its elapsed suffix" do
      state = %{turn_stage: "plan\e[2J", now: 3_000, last_event_at: 0}

      assert StatusStrip.stage_value(state) == "plan[2J 3s"
    end
  end
end
