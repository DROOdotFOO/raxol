defmodule Raxol.Harness.StatusStrip do
  @moduledoc """
  Roadmap unit T10 (`docs/proposals/in-flight/harness-ui-roadmap.md`,
  "Construction -- chrome" section): the pinned status strip, as a pure
  projection `state -> [footer_line]` -- charged-minimum form.

  Per the T2c footer contract (`Raxol.UI.Rendering.PaintAuthority`'s
  `repaint_footer/2` and `keyframe_footer/2` -- both take `iodata()`, no
  width parameter of their own): callers hand the paint authority
  *already width-truncated* text. This module is that seam for the
  strip specifically -- it does no terminal I/O and knows nothing about
  cursor positioning; it only turns a plain state map into a list of
  plain strings, each guaranteed to fit the given display width
  (measured via `Raxol.UI.TextMeasure`, never `String.length` --
  see `truncate_to_width/2`).

  ## The charged minimum (ratified; replaces the `—` slot convention)

  The original T10 form rendered four always-present labelled slots
  (`Input: … | Stage: … | Ctx: … | Cost: …`) with an em dash standing
  in for missing data. Three rulings retired that form after it
  regressed a live session's frame to
  `Input: clear | Stage: item_delta 0s | Ctx: — | Cost: —`:

    1. **Em-dash voids are banned.** A field with nothing true to say
       does not render. `Ctx`/`Cost` while unknown are absent, never
       `—` -- a labelled void claims instrument-hood with no instrument
       behind it. (The "never a silent default" law survives: absence
       IS the honest signal; `0%`/`$0.00` for "we don't know" stay
       banned too.)
    2. **Raw event vocabulary is banned.** `Stage: item_delta` is the
       contract's wire vocabulary, not an operator phase. The strip
       speaks lowercase operator phases (§4.5 voice): streaming renders
       `responding`, a dispatched tool renders `running <tool>`, an
       unanswered approval renders `awaiting approval`, a fault renders
       `failed`, everything else mid-turn renders `thinking`.
    3. **`Input:` is dropped entirely.** The composer shows its own
       state; "Input: clear" was furniture. A needs-input wait is a
       PHASE (the highest-priority one), not a labelled slot.

  The live form is minimal: `<phase> <elapsed>`, then `ctx N%` and
  `$X.YZ` only when real numbers exist. One conditional notice sits
  outside the segment system: an optional `:stall_verdict` entry (the
  stall detector's one integration seam -- see
  `Raxol.Harness.StallDetector` and the private `stall_notice/1`)
  prepends an `ALERT: <evidence>` segment at the very highest priority
  when, and only when, the verdict is `:stalled`/`:looping` with a
  non-empty evidence summary.

  ## Phase derivation

  `phase_value/1` maps the caller-assembled state onto the operator
  vocabulary, in precedence order:

    * `needs_input: true` -> `"awaiting approval"` (safety: an agent
      waiting on a human must never be mislabelled as working);
    * `running_tool` (a tool_use completed, its result not yet in) ->
      `"running <name>"` (`"running tool"` when the producer had no
      name -- a generic word, never a void);
    * the last event type, folded to a phase word: deltas ->
      `"responding"`; brackets/openers/decisions -> `"thinking"`;
      `item_completed` -> `"thinking"` after a tool_result (the model
      is computing its next step) else `"responding"`; `:error` ->
      `"failed"`; `turn_completed`/`turn_canceled`/absent -> `nil`
      (no phase -- the strip yields to silence between turns);
    * a custom (non-vocabulary) stage string passes through as
      sanitized text -- fixtures and embedders may speak their own
      phases, but the wire vocabulary above never leaks raw.

  `running_tool` and `last_item_type` are producer-derived state (the
  Surface's `update_status/3` reads them off the last revealed loop
  event) -- this module stays a pure projection.

  ## `ctx` and the "never a stale %" rule

  `context_pct` renders only when `state.turn_completed === true`; any
  other value renders NOTHING (the charged-minimum absence, replacing
  the old `—`) regardless of whether a `context_pct` number is present.
  A caller that forgets to flip `turn_completed` fails safe (absent,
  never a wrong number) instead of failing silent. The T13a producer
  note from the original form still applies: if the producer ever emits
  a live mid-turn meter, relax this gate to a `context_fresh`-style
  liveness flag -- the "never a stale %" rule stays, only the freshness
  signal changes.

  ## The elapsed ticker and R11 (no wall-clock in the default suite)

  `now` and `last_event_at` are both plain caller-injected integers
  (matching `Raxol.UI.Components.Harness.Block`'s own convention of
  deriving `duration_ms` from event `ts` fields, never a live clock).
  `render/2` never calls `System.monotonic_time/1` or any wall-clock
  function -- elapsed is `now - last_event_at`, a pure subtraction of
  two inputs the caller controls completely. Either value absent
  renders the bare phase with no elapsed suffix.

  Escalation thresholds (`warn_after_ms` default `15_000`,
  `hung_after_ms` default `60_000`, both overridable per-call via
  `state`): under 15s is unremarkable; 15s-60s appends a trailing
  `SLOW` marker; 60s+ prefixes `HUNG` (the P4 concern: something that
  still claims to be working but has gone quiet long enough that a
  human should look). `SLOW`/`HUNG` stay uppercase -- they are alarm
  vocabulary, not phase vocabulary.

  ## Width degradation

  Priority order, highest first (kept longest as width shrinks):
  the ALERT notice, then the phase segment (the core "is it alive"
  signal; needs-input rides it as the highest-precedence phase), then
  `ctx`, then cost (dropped first -- least action-relevant).
  Degradation drops whole segments from the low-priority end; when even
  the single highest-priority segment doesn't fit, that segment itself
  is truncated with an ellipsis (never producing a line wider than the
  requested width).

  ## Glyph width honesty (review fix, T10 FIX-NOW batch)

  Every non-ASCII glyph this module can emit must measure exactly one
  display column per `Raxol.UI.TextMeasure.display_width/1` (`glyphs/0`
  lists them; see the regression test in the test suite). See the
  original T10 U+23F3 ⏳ incident: Emoji_Presentation glyphs below
  0x1F300 measure 1 column but commonly render 2, silently overflowing
  the pinned width guarantee -- which is why the escalation markers are
  the ASCII words `SLOW`/`HUNG`.
  """

  alias Raxol.UI.TextMeasure

  @ellipsis "…"
  @separator " | "
  @default_warn_after_ms 15_000
  @default_hung_after_ms 60_000
  # C0 control characters (0x00-0x1F) plus DEL (0x7F). Covers ESC (0x1B,
  # the lead byte of any ANSI/CSI escape sequence), CR (0x0D), and LF
  # (0x0A) in a single sweep -- see `sanitize/1`.
  @control_chars ~r/[\x00-\x1F\x7F]/

  @type turn_stage :: atom() | String.t()

  @typedoc """
  Turn-in-flight activity, the honest "is the model still thinking?"
  signal (V's architectural ask). Unlike `turn_stage` (derived from the
  last observed EVENT), this is an explicit flag the driver/executor
  raises around a phase, so it stays true through a BLOCKING `complete/2`
  round where zero events arrive: `:generating` (a model request is
  outstanding), `:running_tool` (a tool is executing), `:responding`
  (streaming content), `:idle` (awaiting user/approval -- operator-paced,
  no spinner). Absent (nil) = fixture/replay reveal, which drives the
  spinner from events alone and never animates the strip.
  """
  @type activity :: :generating | :running_tool | :responding | :idle

  @type state :: %{
          optional(:context_pct) => number(),
          optional(:cost) => number(),
          optional(:turn_stage) => turn_stage(),
          optional(:running_tool) => String.t() | nil,
          optional(:last_item_type) => atom() | String.t() | nil,
          optional(:needs_input) => boolean(),
          optional(:now) => integer(),
          optional(:last_event_at) => integer(),
          optional(:turn_completed) => boolean(),
          optional(:warn_after_ms) => pos_integer(),
          optional(:hung_after_ms) => pos_integer(),
          # The turn-in-flight activity flag, and the resolved braille
          # spinner glyph the assembly layer injects each paint (from its
          # tick-advanced frame counter) -- both drive the persistent
          # `<spinner> <phase>` liveness pulse; see `animating?/1`.
          optional(:activity) => activity() | nil,
          optional(:spinner) => String.t() | nil
        }

  @doc """
  Segment priority order, highest (kept longest under width pressure)
  first: the phase (keyed by its main input, `:turn_stage`), then
  `:context_pct`, then `:cost`. Exposed so tests can exercise the
  priority nesting without hardcoding the list a second time.
  """
  @spec field_keys() :: [atom()]
  def field_keys, do: [:turn_stage, :context_pct, :cost]

  # The braille spinner frames the strip can prepend to the phase segment
  # (`with_spinner/2`). The resolved frame arrives via `state.spinner`, but
  # the full frame set is enumerated here so the width-honesty tripwire
  # (`glyphs/0`) sweeps every glyph the strip can emit. Braille dot
  # patterns (U+2800..U+28FF) are text-presentation, one column -- the same
  # frames the transcript's running-tool margin spinner rides.
  @spinner_glyphs ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc """
  The braille spinner frames, in order. Exposed so the assembly layer
  resolves the current frame from a shared source (never a re-declared
  copy) before injecting it into `state.spinner`.
  """
  @spec spinner_glyphs() :: [String.t()]
  def spinner_glyphs, do: @spinner_glyphs

  @doc """
  Every non-ASCII glyph this module can emit into a rendered line: the
  width-degradation ellipsis (the em dash left with the slot convention)
  and the braille spinner frames. Exposed so the width-honesty regression
  test can assert, per character, that
  `Raxol.UI.TextMeasure.display_width/1 == 1`.
  """
  @spec glyphs() :: [String.t()]
  def glyphs, do: [@ellipsis | @spinner_glyphs]

  @doc """
  The default "slow but plausible" threshold for the elapsed ticker, in
  milliseconds. Public so the stall detector's no-progress signal
  formalizes THIS heuristic instead of inventing a parallel constant --
  the strip stays the single source of truth for what "quiet too long"
  means.
  """
  @spec default_warn_after_ms() :: pos_integer()
  def default_warn_after_ms, do: @default_warn_after_ms

  @doc """
  The default "gone quiet long enough that a human should look"
  threshold, in milliseconds. See `default_warn_after_ms/0` for why
  this is public.
  """
  @spec default_hung_after_ms() :: pos_integer()
  def default_hung_after_ms, do: @default_hung_after_ms

  @doc """
  Projects `state` into the status strip's footer lines for a pinned
  region `width` display columns wide. Always returns exactly one line
  (a single-element list) -- the list return type matches the general
  T2c footer-line contract.

  Pure: identical `state` + `width` always produce an identical result.
  Never raises on missing keys -- an absent field renders NOTHING (the
  charged minimum), never a placeholder void or a misleadingly-valid
  default. A state with nothing true to say renders `[""]`; the
  assembly layer's visibility gate (`strip_visible?` in
  `Raxol.Harness.Surface`) normally hides the strip before that case
  is reachable.
  """
  @spec render(state(), non_neg_integer()) :: [String.t()]
  def render(state, width) when is_map(state) and is_integer(width) do
    safe_width = max(width, 0)

    segments =
      [
        phase_segment(state),
        context_value(state),
        cost_value(state)
      ]
      |> Enum.reject(&is_nil/1)

    segments =
      case stall_notice(state) do
        nil -> segments
        notice -> [notice | segments]
      end

    [fit_to_width(segments, safe_width)]
  end

  @doc """
  Whether `state` would render the highest-priority `ALERT:` notice --
  a `:stalled`/`:looping` stall verdict with non-empty evidence (the
  exact condition `render/2`'s own notice uses; one predicate, never a
  re-encoded copy). Public for the assembly layer's strip-visibility
  gate: an alarming strip must render even on an otherwise-idle frame
  where the strip would yield to silence.
  """
  @spec alerting?(state()) :: boolean()
  def alerting?(state) when is_map(state), do: stall_notice(state) != nil

  # -- stall verdict notice -------------------------------------------------

  # The stall detector's one integration seam (see
  # `Raxol.Harness.StallDetector`): an optional `:stall_verdict` state
  # entry -- the detector's verdict struct or any map of the same shape.
  # Only `:stalled` / `:looping` render; `:suspect` is a pre-alarm the
  # detector surfaces for callers that want it, deliberately kept off
  # the strip (the same false-alarm economy behind its honesty floor).
  #
  # When present it takes highest priority -- ahead even of the phase --
  # because a wedged agent is the one condition this instrument exists
  # to make impossible to miss, and unlike an approval wait it arrives
  # with no other on-screen trace.
  #
  # No notice ever renders without evidence text: an alarm the operator
  # cannot act on is noise (the detector's own law, enforced again here
  # defensively). Evidence summaries embed tool names straight from
  # agent events -- the same injection surface as `turn_stage` -- so the
  # summary passes through the same control-character sweep.
  defp stall_notice(state) do
    case Map.get(state, :stall_verdict) do
      %{class: class, evidence: %{summary: summary}}
      when class in [:stalled, :looping] and is_binary(summary) and
             summary != "" ->
        "ALERT: #{sanitize(summary)}"

      _ ->
        nil
    end
  end

  # -- phase ----------------------------------------------------------------

  @doc """
  The operator phase for `state` (see the moduledoc's "Phase
  derivation" section), or `nil` when there is nothing running --
  lowercase §4.5 voice, never the contract's raw event vocabulary.
  Public for the assembly layer and for tests; `render/2` composes it
  with the elapsed ticker.
  """
  @spec phase_value(state()) :: String.t() | nil
  def phase_value(state) when is_map(state) do
    cond do
      Map.get(state, :needs_input) == true ->
        "awaiting approval"

      is_binary(Map.get(state, :running_tool)) and
          Map.get(state, :running_tool) != "" ->
        "running " <> sanitize(Map.get(state, :running_tool))

      true ->
        state
        |> phase_word_from_events()
        |> phase_or_activity(state)
    end
  end

  defp phase_word_from_events(state) do
    phase_word(Map.get(state, :turn_stage), Map.get(state, :last_item_type))
  end

  # When no EVENT names a phase, fall back to the explicit activity flag --
  # this is what surfaces "thinking" through a blocking `complete/2` round
  # (no events, but `:generating` is raised) AND across the inter-round
  # `turn_completed{final: false}` gap (whose `turn_stage` is `:turn_completed`,
  # which `phase_word/2` maps to nil even though the turn is still in
  # flight). The activity flag is the AUTHORITATIVE in-flight signal here --
  # it is `:idle`/absent once the turn truly ends (the driver clears it),
  # so `activity_phase/1` yields nil then and the strip falls silent.
  defp phase_or_activity(nil, state),
    do: activity_phase(Map.get(state, :activity))

  defp phase_or_activity(phase, _state), do: phase

  # `:generating` as the AUTHORITATIVE phase (no turn_stage names one) is the
  # blocking `complete/2` round: the model is actively thinking with NO stream
  # events to reveal it, so the strip is the only "is the model still thinking?"
  # signal and says "thinking" + spinner (V's own charged-minimum test). This
  # is distinct from the STREAMING pre-stream WAIT, where a `:turn_started`
  # event IS present and TAKES PRECEDENCE (`phase_word/2`), rendering the bare
  # spinner V asked for -- so `:generating` never overrides that silent wait.
  defp activity_phase(:generating), do: "thinking"
  defp activity_phase(:running_tool), do: "running tool"
  defp activity_phase(:responding), do: "responding"
  defp activity_phase(_absent_or_idle), do: nil

  @doc """
  Whether the strip should ANIMATE its braille spinner this frame -- the
  "model is still thinking" pulse. True exactly when the turn-in-flight
  `:activity` is an active state (`:generating` / `:running_tool` /
  `:responding`) AND the resolved phase is active work: an `:idle`/absent
  activity, an approval wait (`"awaiting approval"` -- operator-paced, the
  HUNG-suppression ruling), and a fault (`"failed"`) all animate NOTHING.
  Read by the assembly layer to decide whether to inject the spinner glyph,
  and by tests. The activity flag is authoritative over `turn_stage`, so an
  inter-round `turn_completed{final: false}` keeps pulsing while the next
  round's request is outstanding.
  """
  @spec animating?(state()) :: boolean()
  def animating?(state) when is_map(state) do
    Map.get(state, :activity) in [:generating, :running_tool, :responding] and
      active_work_phase?(phase_value(state))
  end

  defp active_work_phase?(nil), do: false
  defp active_work_phase?("awaiting approval"), do: false
  defp active_work_phase?("failed"), do: false
  defp active_work_phase?(_phase), do: true

  defp phase_word(nil, _last_item_type), do: nil
  defp phase_word(:turn_completed, _last_item_type), do: nil
  defp phase_word(:turn_canceled, _last_item_type), do: nil
  defp phase_word(:item_delta, _last_item_type), do: "responding"
  # The pre-stream WAIT (request in flight, nothing streamed yet): a bare
  # braille spinner + elapsed, no "thinking" word -- the live thinking display
  # is the ShadowStream in the tail, not a duplicate label here. (V, 2026-07-18)
  defp phase_word(:turn_started, _last_item_type), do: ""
  defp phase_word(:item_started, _last_item_type), do: "thinking"
  defp phase_word(:approval_requested, _last_item_type), do: "awaiting approval"
  defp phase_word(:approval_decided, _last_item_type), do: "thinking"
  defp phase_word(:state_change, _last_item_type), do: "thinking"
  defp phase_word(:idle, _last_item_type), do: nil
  defp phase_word(:error, _last_item_type), do: "failed"

  defp phase_word(:item_completed, last_item_type) do
    case last_item_type do
      t when t in [:tool_result, "tool_result"] -> "thinking"
      # A tool_use completion whose producer carried no tool name (the
      # `running_tool` branch above owns the named case): a generic
      # word, never a raw event name and never a void.
      t when t in [:tool_use, "tool_use"] -> "running tool"
      _other -> "responding"
    end
  end

  # A custom (non-vocabulary) stage -- fixtures and embedders may speak
  # their own phase words. Sanitized like every injected string.
  defp phase_word(stage, _last_item_type),
    do: stage |> to_string() |> sanitize()

  defp phase_segment(state) do
    case phase_value(state) do
      nil ->
        nil

      phase ->
        phase
        |> with_elapsed(state)
        |> with_spinner(state)
    end
  end

  defp with_elapsed(phase, state) do
    case elapsed_ms(state) do
      nil ->
        phase

      ms ->
        warn_after = Map.get(state, :warn_after_ms, @default_warn_after_ms)
        hung_after = Map.get(state, :hung_after_ms, @default_hung_after_ms)
        render_phase_elapsed(phase, ms, warn_after, hung_after)
    end
  end

  # The braille spinner rides the FRONT of the phase segment (`⠋ thinking
  # 4s`) when the turn is animating and the assembly layer injected a
  # resolved frame glyph. It sits INSIDE the phase segment (not a separate
  # segment) so `fit_to_width/2` clamps it with the phase under width
  # pressure and the pinned-width guarantee still holds. The glyph is a
  # caller-supplied string (a braille dot pattern -- text presentation,
  # one column; see `glyphs/0`), advanced by the SAME tick clock that
  # drives elapsed, so it pulses even through an event-silent blocking
  # round.
  defp with_spinner(text, state) do
    if animating?(state) do
      case Map.get(state, :spinner) do
        glyph when is_binary(glyph) and glyph != "" -> glyph <> " " <> text
        _absent -> text
      end
    else
      text
    end
  end

  # -- ctx / cost segments (charged minimum: nil, never a void) ------------

  @doc false
  @spec context_value(state()) :: String.t() | nil
  def context_value(state) do
    if Map.get(state, :turn_completed) === true do
      case Map.get(state, :context_pct) do
        pct when is_number(pct) -> "ctx #{round(pct)}%"
        _ -> nil
      end
    else
      nil
    end
  end

  @doc false
  @spec cost_value(state()) :: String.t() | nil
  def cost_value(state) do
    case Map.get(state, :cost) do
      cost when is_number(cost) ->
        "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)

      _ ->
        nil
    end
  end

  # -- elapsed --------------------------------------------------------------

  # Strip C0 controls (ESC/CR/LF included -- see `@control_chars`)
  # before interpolation so an injected string carrying e.g.
  # `"plan\e[2J"` (a clear-screen CSI) or an embedded newline can't
  # corrupt the pinned footer or spill onto a second line. This drops
  # only the raw control bytes, not any printable characters that
  # happened to follow them (e.g. `"\e[2J"` becomes the harmless
  # literal text `"[2J"`).
  defp sanitize(text), do: String.replace(text, @control_chars, "")

  defp elapsed_ms(state) do
    with now when is_integer(now) <- Map.get(state, :now),
         last when is_integer(last) <- Map.get(state, :last_event_at) do
      max(now - last, 0)
    else
      _ -> nil
    end
  end

  # Empty phase (the generating "bare spinner" state): no leading space, just
  # the elapsed (+ SLOW/HUNG). Keeps the strip a clean `⠋ 4s`, never `⠋  4s`.
  defp render_phase_elapsed("", ms, _warn_after, hung_after)
       when ms >= hung_after,
       do: "HUNG #{format_elapsed(ms)}"

  defp render_phase_elapsed("", ms, warn_after, _hung_after)
       when ms >= warn_after,
       do: "#{format_elapsed(ms)} SLOW"

  defp render_phase_elapsed("", ms, _warn_after, _hung_after),
    do: format_elapsed(ms)

  defp render_phase_elapsed(phase, ms, _warn_after, hung_after)
       when ms >= hung_after do
    "HUNG #{phase} #{format_elapsed(ms)}"
  end

  defp render_phase_elapsed(phase, ms, warn_after, _hung_after)
       when ms >= warn_after do
    "#{phase} #{format_elapsed(ms)} SLOW"
  end

  defp render_phase_elapsed(phase, ms, _warn_after, _hung_after) do
    "#{phase} #{format_elapsed(ms)}"
  end

  defp format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  defp format_elapsed(ms) do
    total_s = div(ms, 1000)
    minutes = div(total_s, 60)
    seconds = rem(total_s, 60)
    "#{minutes}m#{pad2(seconds)}s"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  # -- width degradation -----------------------------------------------------

  defp fit_to_width([], _width), do: ""

  defp fit_to_width(segments, width) do
    count = length(segments)

    candidate =
      count..1//-1
      |> Enum.map(&Enum.join(Enum.take(segments, &1), @separator))
      |> Enum.find(&(TextMeasure.display_width(&1) <= width))

    case candidate do
      nil -> truncate_to_width(List.first(segments) || "", width)
      fit -> fit
    end
  end

  defp truncate_to_width(_text, width) when width <= 0, do: ""

  defp truncate_to_width(text, width) do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> @ellipsis
    end
  end
end
