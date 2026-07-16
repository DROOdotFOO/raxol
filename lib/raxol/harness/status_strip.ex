defmodule Raxol.Harness.StatusStrip do
  @moduledoc """
  Roadmap unit T10 (`docs/proposals/in-flight/harness-ui-roadmap.md`,
  "Construction -- chrome" section): the pinned status strip, as a pure
  projection `state -> [footer_line]`.

  Per the T2c footer contract (`Raxol.UI.Rendering.PaintAuthority`'s
  `repaint_footer/2` and `keyframe_footer/2` -- both take `iodata()`, no
  width parameter of their own): callers hand the paint authority
  *already width-truncated* text. This module is that seam for the
  strip specifically -- it does no terminal I/O and knows nothing about
  cursor positioning; it only turns a plain state map into a list of
  plain strings, each guaranteed to fit the given display width
  (measured via `Raxol.UI.TextMeasure`, never `String.length` --
  see `truncate_to_width/2`).

  ## Why this isn't built on the existing Component tree

  `Raxol.UI.Components.Harness.StatusBar` (merged #540) and
  `Raxol.UI.Components.Display.StatusBar` it delegates to both return
  view maps (`%{type: :row, children: [...]}`) for the normal
  Preparer -> LayoutEngine -> UIRenderer pipeline. The T2c footer path
  bypasses that pipeline entirely (byte-level pinned-region writes), so
  running those components just to string-scrape their `children` would
  add a dependency on internal view-map shape for no benefit. This
  module reuses their *formatting conventions* instead (the `"Label:
  value"` slot idiom, `"\#{round(pct)}%"`, `"$" <> float_to_binary(...,
  decimals: 2)`), so a strip fixture and a `Harness.StatusBar` fixture
  read the same way, without sharing a render path that serves a
  different contract.

  It deliberately does NOT reuse `Harness.ActivityIndicator`'s
  `:working` display either: that branch renders a bare animated
  spinner glyph with no elapsed number, which is exactly what roadmap
  pain point P4 rules out ("stage + elapsed, never a bare spinner").
  This module borrows ActivityIndicator's *shape* -- a caller-accumulated
  elapsed value, never `System.monotonic_time/1` inside render (see
  below) -- but always renders the numeric elapsed alongside the stage.

  ## Why this doesn't consume `Raxol.Harness.Projection` directly

  T7's `Projection.t()` struct (`blocks`, `tail`, `fold_defaults`,
  `diagnostics`, `source_events`, `damaged`) carries none of this unit's
  fields today: no `context_pct`, no running session `cost`, no
  `turn_stage`, no `needs_input`. The closest thing is
  `Raxol.UI.Components.Harness.Block`'s `outcome.cost` (per-block, not
  session-total) and `kind`/`seal` (block-level, not turn-level). Per
  methodology R10 (scope fence): a pre-existing gap only becomes an
  owned unit when a mapped acceptance criterion depends on it, and T10's
  acceptance is "fixture drives all fields" -- it does not require a
  `Projection`-derivation helper. So this module takes a plain,
  caller-assembled state map; wiring a real `Projection` (plus
  agent-runtime cost/context signals that don't exist in code yet) into
  that shape is T13a's (assembly) job, not this unit's.

  ## Fields, priority, and the `—` convention

  Every field always occupies its labelled slot; a field with no data
  renders the em dash `—` in that slot instead of a coerced default
  (never `0%`, never `$0.00` for "we don't know") -- silent defaults
  would be indistinguishable from a real zero, which is exactly the
  "explicit meaning" the roadmap acceptance calls for.

  | slot    | key            | source field(s)                      |
  |---------|----------------|---------------------------------------|
  | `Input` | `needs_input`  | `needs_input` (`true`/`false`/absent)  |
  | `Stage` | turn stage     | `turn_stage` + `now`/`last_event_at`   |
  | `Ctx`   | context %      | `context_pct` gated by `turn_completed`|
  | `Cost`  | session cost   | `cost`                                 |

  One conditional notice sits outside the slot system: an optional
  `:stall_verdict` entry (the stall detector's one integration seam --
  see `Raxol.Harness.StallDetector` and the private `stall_notice/1`)
  prepends an `ALERT: <evidence>` segment at the very highest priority
  when, and only when, the verdict is `:stalled`/`:looping` with a
  non-empty evidence summary.

  Priority order, highest first (kept longest as width shrinks; see
  `field_keys/0` and `render/2`): `needs_input` (safety: an agent
  waiting on approval must never silently disappear from a narrow
  terminal), then `turn_stage` (the core "is it alive" signal), then
  `context_pct`, then `cost` (dropped first -- least action-relevant of
  the four). Degradation drops whole `"Label: value"` segments from the
  low-priority end; when even the single highest-priority segment
  doesn't fit, that segment itself is truncated with an ellipsis (never
  producing a line wider than the requested width).

  ## `Ctx` and the "never a stale %" rule

  The roadmap acceptance calls out one failure mode by name: "missing
  data renders `—`... never a stale % from the prior turn." Rather than
  trust every caller to remember to clear `context_pct` between turns,
  this module gates it structurally: `context_pct` renders only when
  `state.turn_completed === true`; any other value (`false`, `nil`, or
  the key simply absent) renders `—` regardless of whether a
  `context_pct` number is also present in state. A caller that forgets
  to flip `turn_completed` fails safe (shows `—`, never a wrong number)
  instead of failing silent.

  **OPEN QUESTION for T13a (the producer decides, not this module):**
  this gate assumes `context_pct` is a *turn-boundary snapshot* (usage
  as of the last completed turn). If T13a's producer turns out to emit a
  *live* mid-turn meter — arguably the more valuable semantic ("am I
  about to hit compaction?" matters most DURING a long turn) — then
  gating on `turn_completed` inverts the operator's need (`Ctx: —` for
  the whole active turn, a number only in the dead gap between turns).
  In that case relax this gate to a `context_fresh`-style liveness flag
  supplied by the producer; the "never a stale %" rule stays, only the
  freshness signal changes. Do NOT work around it by setting
  `turn_completed: true` mid-turn — that lies to the `Ctx` slot's
  documented meaning.

  ## The elapsed ticker and R11 (no wall-clock in the default suite)

  `now` and `last_event_at` are both plain caller-injected integers
  (matching `Raxol.UI.Components.Harness.Block`'s own convention of
  deriving `duration_ms` from event `ts` fields, never a live clock).
  `render/2` never calls `System.monotonic_time/1` or any wall-clock
  function -- elapsed is `now - last_event_at`, a pure subtraction of
  two inputs the caller controls completely, which is what makes the
  ticker deterministically testable (advance `now` in a test, the
  display advances predictably) without a single sleep or timer.
  Either value absent yields a `nil` elapsed (renders `—` for the
  ticker half of `Stage`, independent of whether `turn_stage` itself is
  present).

  Escalation thresholds (`warn_after_ms` default `15_000`, `hung_after_ms`
  default `60_000`, both overridable per-call via `state`): under 15s is
  unremarkable ("still thinking"); 15s-60s is flagged with a trailing
  `SLOW` marker (an agent turn commonly runs a compile/test tool call in
  this range -- "slow but plausible"); 60s+ prefixes `HUNG` (the P4
  concern: something that still *claims* to be working but has gone
  quiet long enough that a human should look). These are starting
  defaults, not derived from a measurement; adjust per-deployment via
  `state.warn_after_ms` / `state.hung_after_ms`.

  ## Glyph width honesty (review fix, T10 FIX-NOW batch)

  Every non-ASCII glyph this module can emit must measure exactly one
  display column per `Raxol.UI.TextMeasure.display_width/1` (`glyphs/0`
  lists them; see the regression test in the test suite). The original
  warn-threshold marker was the hourglass emoji U+23F3 (⏳): it carries
  Unicode `Emoji_Presentation` and real terminals commonly render it 2
  columns wide, but `Raxol.Terminal.CharacterHandling.wide_char?/1`'s
  range table has no entry below the Misc Symbols and Pictographs block
  (0x1F300+), so it measures U+23F3 as width 1 -- a pinned strip built
  on that measurement would silently overflow its own width guarantee
  for the entire 15s-60s "slow" window. Replaced with the ASCII word
  `SLOW`, which is width-honest by construction (every ASCII byte is
  single-cell). The true fix belongs upstream in
  `Raxol.Terminal.CharacterHandling`'s width table (Emoji_Presentation
  coverage, not just East Asian Width); once that lands and
  `wide_char?/1` correctly flags emoji-presentation glyphs as 2 columns,
  a fancier glyph may safely return here.
  """

  alias Raxol.UI.TextMeasure

  @missing "—"
  @ellipsis "…"
  @separator " | "
  @default_warn_after_ms 15_000
  @default_hung_after_ms 60_000
  # C0 control characters (0x00-0x1F) plus DEL (0x7F). Covers ESC (0x1B,
  # the lead byte of any ANSI/CSI escape sequence), CR (0x0D), and LF
  # (0x0A) in a single sweep -- see `sanitize_stage/1`.
  @control_chars ~r/[\x00-\x1F\x7F]/

  @type turn_stage :: atom() | String.t()

  @type state :: %{
          optional(:context_pct) => number(),
          optional(:cost) => number(),
          optional(:turn_stage) => turn_stage(),
          optional(:needs_input) => boolean(),
          optional(:now) => integer(),
          optional(:last_event_at) => integer(),
          optional(:turn_completed) => boolean(),
          optional(:warn_after_ms) => pos_integer(),
          optional(:hung_after_ms) => pos_integer()
        }

  @field_specs [
    {:needs_input, "Input", &__MODULE__.input_value/1},
    {:turn_stage, "Stage", &__MODULE__.stage_value/1},
    {:context_pct, "Ctx", &__MODULE__.context_value/1},
    {:cost, "Cost", &__MODULE__.cost_value/1}
  ]

  # `@field_specs` captures the four slot formatters below by fully-
  # qualified `Module.function/arity` (rather than a bare local
  # `&function/1`) because module attributes are evaluated top-down at
  # compile time -- a bare local capture would try to resolve against
  # the (not-yet-fully-compiled) current module and fail; the qualified
  # form defers resolution the same way any other remote call would.
  # The formatters stay `@doc false` public functions (not private)
  # for exactly this reason, and so `field_keys/0` + the value
  # functions can be exercised independently in tests without going
  # through `render/2`'s width-degradation path.

  @doc """
  Canonical field order, highest priority (kept longest under width
  pressure) first. Exposed so tests can exercise every field by name
  without hardcoding the list a second time and risking drift.
  """
  @spec field_keys() :: [atom()]
  def field_keys, do: Enum.map(@field_specs, fn {key, _label, _fn} -> key end)

  @doc """
  Every non-ASCII glyph this module can emit into a rendered line
  (currently the missing-data em dash and the width-degradation
  ellipsis). Exposed so the width-honesty regression test can assert,
  per character, that `Raxol.UI.TextMeasure.display_width/1 == 1` --
  see the "Glyph width honesty" moduledoc section for why this matters
  (U+23F3 ⏳ measured 1 col but rendered 2 in real terminals).
  """
  @spec glyphs() :: [String.t()]
  def glyphs, do: [@missing, @ellipsis]

  @doc """
  The default "slow but plausible" threshold for the Stage elapsed
  ticker, in milliseconds. Public so the stall detector's no-progress
  signal formalizes THIS heuristic instead of inventing a parallel
  constant -- the strip stays the single source of truth for what
  "quiet too long" means.
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
  T2c footer-line contract (other chrome units may contribute more than
  one line to the pinned footer), not because this unit ever produces
  more than one.

  Pure: identical `state` + `width` always produce an identical result.
  Never raises on missing keys -- every field independently degrades to
  `#{inspect(@missing)}` in its slot rather than crashing or defaulting
  to a misleadingly-valid-looking value.
  """
  @spec render(state(), non_neg_integer()) :: [String.t()]
  def render(state, width) when is_map(state) and is_integer(width) do
    safe_width = max(width, 0)

    segments =
      Enum.map(@field_specs, fn {_key, label, value_fn} ->
        "#{label}: #{value_fn.(state)}"
      end)

    segments =
      case stall_notice(state) do
        nil -> segments
        notice -> [notice | segments]
      end

    [fit_to_width(segments, safe_width)]
  end

  # -- stall verdict notice -------------------------------------------------

  # The stall detector's one integration seam (see
  # `Raxol.Harness.StallDetector`): an optional `:stall_verdict` state
  # entry -- the detector's verdict struct or any map of the same shape.
  # Only `:stalled` / `:looping` render; `:suspect` is a pre-alarm the
  # detector surfaces for callers that want it, deliberately kept off
  # the strip (the same false-alarm economy behind its honesty floor).
  #
  # This is a conditional NOTICE, not a fifth labelled slot: the
  # always-render-`—` convention exists so missing *data* is visibly
  # missing, but "no alarm" is the healthy state, and a permanent
  # `Alert: —` slot would be pure noise. When present it takes highest
  # priority -- ahead even of `needs_input` -- because a wedged agent is
  # the one condition this instrument exists to make impossible to miss,
  # and unlike needs-input it arrives with no other on-screen trace.
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
        "ALERT: #{sanitize_stage(summary)}"

      _ ->
        nil
    end
  end

  # -- per-field slot formatting ----------------------------------------

  @doc false
  @spec input_value(state()) :: String.t()
  def input_value(state) do
    case Map.get(state, :needs_input) do
      true -> "needs-input"
      false -> "clear"
      _ -> @missing
    end
  end

  @doc false
  @spec stage_value(state()) :: String.t()
  def stage_value(state) do
    stage_str = stage_label(Map.get(state, :turn_stage))

    case elapsed_ms(state) do
      nil ->
        stage_str

      ms ->
        warn_after = Map.get(state, :warn_after_ms, @default_warn_after_ms)
        hung_after = Map.get(state, :hung_after_ms, @default_hung_after_ms)
        render_stage_elapsed(stage_str, ms, warn_after, hung_after)
    end
  end

  @doc false
  @spec context_value(state()) :: String.t()
  def context_value(state) do
    if Map.get(state, :turn_completed) === true do
      case Map.get(state, :context_pct) do
        pct when is_number(pct) -> "#{round(pct)}%"
        _ -> @missing
      end
    else
      @missing
    end
  end

  @doc false
  @spec cost_value(state()) :: String.t()
  def cost_value(state) do
    case Map.get(state, :cost) do
      cost when is_number(cost) ->
        "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)

      _ ->
        @missing
    end
  end

  # -- stage + elapsed -----------------------------------------------------

  defp stage_label(nil), do: @missing
  defp stage_label(stage), do: stage |> to_string() |> sanitize_stage()

  # `turn_stage` is plain caller-assembled state (see moduledoc) that
  # lands, unescaped, in the byte-level pinned-region writer this
  # module's output feeds. Strip C0 controls (ESC/CR/LF included --
  # see `@control_chars`) before interpolation so a stage string
  # carrying e.g. `"plan\e[2J"` (a clear-screen CSI) or an embedded
  # newline can't corrupt the pinned footer or spill onto a second
  # line. This drops only the raw control bytes, not any printable
  # characters that happened to follow them (e.g. `"\e[2J"` becomes
  # the harmless literal text `"[2J"`).
  defp sanitize_stage(text), do: String.replace(text, @control_chars, "")

  defp elapsed_ms(state) do
    with now when is_integer(now) <- Map.get(state, :now),
         last when is_integer(last) <- Map.get(state, :last_event_at) do
      max(now - last, 0)
    else
      _ -> nil
    end
  end

  defp render_stage_elapsed(stage_str, ms, _warn_after, hung_after)
       when ms >= hung_after do
    "HUNG #{stage_str} #{format_elapsed(ms)}"
  end

  defp render_stage_elapsed(stage_str, ms, warn_after, _hung_after)
       when ms >= warn_after do
    "#{stage_str} #{format_elapsed(ms)} SLOW"
  end

  defp render_stage_elapsed(stage_str, ms, _warn_after, _hung_after) do
    "#{stage_str} #{format_elapsed(ms)}"
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
