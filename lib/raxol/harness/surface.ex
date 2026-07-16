defmodule Raxol.Harness.Surface do
  @moduledoc """
  The assembled harness (golden-fixture assembly): the `HarnessSurface`
  app composed end-to-end against a **replayed fixture session**. This is
  the first assembled, visually-demoable harness -- no agent lane, fixture
  events only.

  This module is the pure(-ish) core: an `init`/`update`/`render`-shaped
  state machine over a plain map "model", built entirely from already-
  merged units. It never depends on `raxol_agent` (this module's own
  acceptance: "No agent lane required" -- see the "Command bifurcation"
  section below). It is deliberately NOT wired through `Raxol.start_link/2`
  / the normal TEA `Lifecycle` -- the append-path/footer-viewport
  substrate this app renders through
  (`Raxol.UI.Rendering.PaintAuthority.InlineAuthority`/`FlatAuthority`) is
  a byte-level pinned-region writer, one layer BELOW the
  `Preparer -> LayoutEngine -> UIRenderer -> ScreenBuffer` pipeline the
  normal TEA runtime drives; there is no Component tree to mount here, so
  there is nothing for `Lifecycle` to add. `examples/harness_fixture_demo.exs`
  is the process-level driver (real tty, `Raxol.Terminal.InlineDriver` for
  raw input) built on top of this module's pure functions.

  ## Glossary (the substrate vocabulary, one line each)

  New to this lane? These terms recur, undefended, across this module,
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority`, and
  `Raxol.Terminal.ScrollRegionManager` -- this is the one anchor:

    * **DECSTBM** -- the ANSI "set top/bottom margins" control
      (`CSI top;bottom r`): confines terminal scrolling to a row range.
      The harness uses it to split the screen into scrolling history
      (top) and a pinned footer (bottom).
    * **The pin / pinned footer** -- the bottom N rows placed OUTSIDE the
      DECSTBM scroll region, so history scrolling never moves them; the
      only surface the harness ever repaints.
    * **Seal / seal-once** -- writing a finished block into the history
      region exactly once, never repainted afterward; sealed rows
      eventually scroll into the terminal's own native scrollback, which
      this process cannot rewrite.
    * **Index-at-region-boundary** -- a line feed on the scroll region's
      bottom row scrolls the region up one row (the top row is evicted
      toward scrollback) instead of moving the cursor; how both sealing
      and the overlay's footer-grow preserve content.
    * **Keyframe vs. repaint** -- `repaint/2` rewrites only footer rows
      whose content changed (a diff); `keyframe/2` rewrites every footer
      row (the recovery / post-geometry-change path).
    * **Degenerate geometry** -- a terminal too short to hold the footer
      plus a 2-row-minimum history region: DECSTBM cannot pin, and the
      harness degrades (or, for overlays, refuses) instead of pretending.

  ## Composition (what this module assembles)

    * The append path / footer viewport (`InlineAuthority`) or the
      degradation ladder (`FlatAuthority`, picked by `ModeSelect.select/3`)
      -- the paint substrate. `:tmux_conservative` routes through the same
      `InlineAuthority` as `:inline_log` (per `ModeSelect`'s own moduledoc:
      there is no separate `TmuxConservativeAuthority`), so this module
      only branches on `:flat` vs. everything else.
    * The block builder (`Raxol.Harness.Projection`) -- journal-fold:
      durable events become `Block`s, `item_delta` traffic becomes the
      live tail.
    * The block bodies (`Raxol.UI.Components.Harness.BlockBody`) --
      fold-aware per-kind body rendering for expanded blocks.
    * The status strip (`Raxol.Harness.StatusStrip`) -- the pinned status
      line.
    * The composer (`Raxol.UI.Components.Harness.Composer`) -- the prompt.
    * The keybind layer (`Raxol.UI.Harness.Keymap`) -- canonical event ->
      command.
    * The input normalizer (`Raxol.UI.Harness.InputEvent`) -- canonical
      event normalization, the shim every input path goes through first.
    * **`Raxol.Harness.Surface.ViewText`** -- this unit's own bridge from
      the Component tree's view maps to the paint authority's flat
      `iodata()` rows (see that module's doc for why truncation precedes
      styling).

  ## Precondition #2 -- keymap-first dispatch (binding, load-bearing)

  `handle_input/2` normalizes the raw event exactly once
  (`InputEvent.normalize/1`) and calls `Keymap.resolve/2` **before ever
  touching the Composer**. Only a `:passthrough` result reaches
  `Composer.handle_event/3`. This is the fix for the named failure mode
  (the composer's catch-all previously delegated every unhandled key into
  MultiLineInput -- component-first wiring killed ESC-interrupt AND
  Tab-steer dead): ESC/Tab are `:always` binds in `Keymap.binds/0`, so
  they are intercepted here unconditionally, regardless of `composing?`.

  ## Precondition #3 -- the focus model

  `composing?` defaults `true` (the composer starts focused -- matching
  the spec's own default). ESC (`:interrupt`) and Tab (`:steer`) are the
  documented exceptions: both are `:always` Keymap binds, firing
  regardless of `composing?`, and neither is a focus transition (ESC must
  never be swallowed as a focus operation, per `Keymap`'s own moduledoc).

  `Keymap`'s `:not_composing` guard (`z`/`j`/`k`) means block-navigation
  commands only ever resolve once focus has ALREADY left the composer --
  Keymap itself has no bind that performs that transition (there is no
  dedicated "focus transcript" key in `Keymap.binds/0` today; a v1 scope
  note, not a missing precondition -- no keybind spec covers one). This
  module therefore owns the transition as explicit, directly-callable
  API: `focus_transcript/1` (composing? false, enables jump/fold) and
  `focus_composer/1` (composing? true, the default). A future key or
  mouse binding (a command palette, a focus-lens hover per ADR-0012)
  wires one of these directly; today's fixture-only assembly exposes them
  for a caller (or a test) to invoke. `focused_block_id` is threaded to
  `Keymap.resolve/2`'s context from `focused_index` (see "Fold/jump"
  below).

  ## Precondition #4 -- context_pct producer semantics

  None of the shipped golden fixtures (`test/fixtures/harness/sessions/`)
  carry a context-window-size field alongside `turn_completed`'s
  `usage`/`cost` payload -- there is no honest way to derive a percentage
  from token counts alone without a denominator this producer does not
  have. So `context_pct` is **never populated** by this assembler; the
  status strip's own `—` convention (gated on `turn_completed`) renders
  exactly that every frame. This is a producer decision (the status
  strip's moduledoc explicitly reserves it: "the producer decides, not
  this module"), not a bug -- fabricating a percentage from unrelated
  data would be the dishonest choice this design deliberately rules out.
  `turn_stage` and `turn_completed` ARE derived (from the last revealed
  loop event's `type` and whether a `turn_completed` event is the most
  recent one), matching the turn-boundary-snapshot semantics the status
  strip assumes by default.

  ## Precondition #5 -- the footer contract

  Every frame's footer is built as a plain list of lines (status ++
  optional live/pending preview ++ Composer's own rendered lines ++
  optional one-shot stub notice), run through `ViewText.lines/3` for
  Composer's tree (status/notice lines are already plain strings), then
  handed to `InlineAuthority.repaint/2` -- which pads/truncates the LIST
  to the current footer row count itself (see that function's doc). This
  module truncates every individual LINE to `width` via `ViewText.lines/3`
  (which uses `TextMeasure`, never `String.length`) before that call --
  the caller contract `InlineAuthority.repaint/2`'s moduledoc documents as
  NOT enforced by that function itself. On resize, `resize/2` composes
  `InlineAuthority.resize/3 |> InlineAuthority.keyframe/2` explicitly (the
  documented composition -- `resize/3` alone never repaints the footer).
  `degenerate?/1` is checked before assuming a pin: a degenerate geometry
  still calls `repaint/2`/`keyframe/2` (they never crash), just over
  whatever footer capacity `footer_range/1` reports for that geometry.

  While an overlay picker is open (see "The overlay picker" section
  below), the layout is instead status ++ overlay lines
  (`ViewText.lines(OverlayPicker.render(picker), width, :styled)`) ++
  Composer's lines ++ notice -- the pending/live-tail preview lines are
  SUPPRESSED for exactly as long as the overlay is open (the space they'd
  occupy is now claimed by the overlay), and return the moment it closes.

  ## The overlay picker (footer-region overlay)

  `open_overlay/3` hosts a `Raxol.UI.Harness.OverlayPicker` by GROWING the
  DECSTBM footer viewport (`InlineAuthority.set_footer_rows/2`) -- never a
  centered modal painted over history, never the alternate screen. The
  overlay's rows live entirely inside the (now larger) pinned footer, the
  same substrate the composer/status/preview lines already share.

  ESC closes the overlay, not the running turn: `Keymap`'s `:overlay`
  guard (see that module's moduledoc) captures ESC as `:overlay_dismiss`
  BEFORE the global `:always` ESC-interrupt bind ever sees it, as long as
  `handle_input/2`'s context carries `overlay_open?: true` -- which it
  does whenever `model.overlay` is non-`nil`. Enter, printable characters,
  and the arrow keys are deliberately NOT added to `Keymap.binds/0` for
  the overlay; they stay `:passthrough`, and THIS module is what routes a
  `:passthrough` event to `OverlayPicker.handle_key/2` instead of the
  Composer while an overlay is open (see `handle_input/2`'s routing,
  below) -- Enter commits the overlay's current selection instead of
  submitting the composer's buffer.

  `open_overlay/3` refuses rather than degrading silently whenever the
  current geometry cannot safely host even a minimal overlay: history
  must keep at least 2 rows, and the overlay itself needs at least 2 rows
  (a query row plus one item row) -- `{:error,
  :insufficient_footer_capacity}`, zero bytes, model untouched. A taller
  item list than the available capacity is CLAMPED to fit (via
  `OverlayPicker`'s own `:max_visible` option), not refused -- only a
  geometry too small for even the 2-row minimum is a hard refusal.
  `model.footer_rows` always stays the BASE value the caller originally
  configured; the grown row count lives only in `model.authority` for as
  long as the overlay is open, and `close_overlay/1` restores the
  authority back to exactly that base value on dismiss or commit.

  ## Precondition #6 -- command bifurcation (fixture mode = honest UI stubs)

  `:interrupt`/`:steer` are the two commands that cross to the agent lane
  in the future agent-lane surface (`%Command{}`, `raxol_agent`'s
  channel). This module has no agent lane by design, so both are
  rendered as honest, visibly-labeled stubs instead of silently doing
  nothing OR pretending to act:

    * `:interrupt` -- sets a one-frame footer notice ("interrupt requested
      (stub -- no agent lane in fixture mode)"), consumed (cleared) after
      the next paint so it never lingers as a stale claim.
    * `:steer` -- reuses Composer's OWN already-built queued-steer banner
      (`Composer.update({:set_queued_steer, ...}, composer)`) with the
      composer's current buffer text, mirroring exactly what a real steer
      would queue (per `Keymap`'s own moduledoc: "the assembly layer that
      already has the composer's buffer fills `payload.text` in before
      dispatch") -- without an agent lane to actually deliver it to. This
      is the more honest stub of the two: it is real, shipped UI, not an
      invented notice line.

  `:fold_toggle`/`:jump_next`/`:jump_prev` never leave this module -- they
  are pure UI-local state per Keymap's own documented bifurcation.

  While an overlay picker is open (`model.overlay != nil`), `:steer` is a
  documented no-op instead of queuing the composer's buffer: the composer
  is frozen mid-pick (its buffer is not what the operator is currently
  interacting with), so queuing a steer built from THAT hidden state
  would be dishonest UI -- it would claim to queue "what you were about
  to send" when what's actually on screen is a filter query, not a
  prompt. `:interrupt` is unaffected (an overlay is transient UI-local
  state, not a reason to block the honest interrupt stub).

  ## Fold/jump and the seal-time-only gate -- a translation, not a reuse

  The "which blocks may seal" decision itself now lives in
  `Raxol.Harness.SealFrontier` (a shared classifier, not restated per
  consumer). `frontier_entries/1` expresses the foldable window described
  below as the frontier's `pending_input?` hold on the newest block, and
  both the seal pass (`paint_pending_blocks/1`) and the footer's pending
  preview (`pending_block/1`) consult `frontier_scan/1` -- the same
  entries, the same classifier -- so they can never disagree on where the
  frontier stops.

  `Raxol.UI.Components.Harness.Block.seal` is an item-LIFECYCLE field:
  `BlockBuilder` only ever constructs a block once its source item(s)
  complete, always with `seal: :sealed` (see `BlockBuilder.build_block/2`).
  That means every block the block builder hands this assembler already
  reads `:sealed` by the time it exists at all -- `Block.fold_allowed?/2`'s
  own post-seal gate would therefore deny EVERY fold toggle,
  unconditionally, which is not what "fold state flips pre-seal" (this
  unit's own acceptance criterion) asks for.

  The seal-time-only gate this unit actually needs is a DIFFERENT axis:
  has this block been PHYSICALLY PAINTED to the terminal's history region
  yet (via `InlineAuthority.seal/2`/`FlatAuthority.seal/2`)? That is this
  module's own `painted_count` high-water mark, not `Block.seal`. So every
  fold toggle here calls `Block.toggle_fold(block, fold_after_seal:
  :allow)` -- deliberately overriding Block's own (inapplicable) default
  -- and this module enforces "no fold after physical paint" itself, by
  construction: `advance/2` always leaves the newest completed block
  un-painted for exactly one more `advance/2` call (see
  `paint_pending_blocks/1`), so there is a real, multi-step window in
  which the trailing block is visible (via the footer's pending-preview
  line), foldable, and NOT yet irreversibly on-screen. Once painted, its
  fold state is frozen (assigning further overrides for an
  already-painted block index is a no-op here, independent of whatever
  `Block.fold_allowed?/2` would say) -- exactly because the substrate
  cannot repaint sealed history (seal-time-only).

  ### The foldable-before-seal window is honest only for one-block-per-advance

  The guarantee above -- "the trailing block is visible, foldable, and NOT
  yet irreversibly on-screen for at least one `advance/2` call" -- holds
  precisely because `paint_pending_blocks/1` always holds back exactly the
  single NEWEST completed block. If one `advance/2` call ever materializes
  **two or more** newly-completed blocks in the same step (the block
  builder's projection batching more than one durable item into a single
  re-project), every block except the last of that batch seals
  IMMEDIATELY, in the same step it first appears -- there is no foldable
  window for those, because `paint_pending_blocks/1` has no notion of
  "the newest N blocks," only "all but the newest one." This is not a
  defect in this module's own bookkeeping; it is a real limit of the
  design, worth naming honestly rather than leaving implied by the
  single-block phrasing above. The actual fix belongs one layer down, in
  the block builder: a `:completed_but_unsealed` phase distinguishing
  "this block is done" from "this block has been offered a foldable
  window," which the block builder does not currently model (tracked as a
  follow-up, not part of this unit's scope).

  ## The live tail (delta streaming) has no history-region home

  Per the substrate's actual shipped contract, `InlineAuthority` supports
  exactly two things: seal-once history (`seal/2`, never repainted) and a
  repaintable FOOTER viewport (`repaint/2`/`keyframe/2`). There is no
  third "live, still-mutating history row" primitive in any merged unit --
  inventing one is out of this unit's scope (a new substrate primitive,
  not an assembly). So both `projection.tail` (in-progress items, still
  accumulating `item_delta` chunks) and the one pending-not-yet-painted
  completed block are rendered as a single preview line INSIDE the
  footer, which IS a legitimately repaintable surface every frame --
  never in history. This keeps every live/mutable thing inside the one
  viewport built for repainting, and everything sealed forever immutable,
  which is the seal-time-only contract honestly extended one layer up
  rather than worked around.

  ## The sub-binary pinning footgun -- `:binary.copy/1` at seal

  Research feedback on comparable TUI harnesses (Ink's erase-redraw
  pathology, external audit 2026-07) flagged a BEAM-specific memory
  footgun this module's own `painted_count` design is exposed to: a
  binary produced by pattern-matching, `binary_part/3`, or a JSON
  decoder's own unescaped-string fast path (Jason does this) is a
  SUB-BINARY -- a small header referencing the WHOLE original buffer, not
  a copy of just its own bytes (`:binary.referenced_byte_size/1` reveals
  the difference; `byte_size/1` does not). A `Block.content` string that
  is secretly one of these (a stream delta arriving as a slice of one
  large network-chunk binary is the shape a live, agent-streamed session
  would hit; a multi-KB `.jsonl` line decoded by a substring-slicing
  parser is today's fixture-mode shape) pins the ENTIRE originating
  buffer in memory for as long as anything holds the slice -- and this
  module's own blocks, once sealed, are retained in `projection.blocks`
  for the life of the session (see "memory residency" in this module's
  test suite, the companion regression guard this fix exists for).

  `paint_pending_blocks/1` is where a block permanently transitions from
  "still mutable, still small in count" to "sealed, retained forever,
  never touched again" (seal-time-only) -- the boundary this fix cares
  about. `detach_content/1` walks a block's `content` map (recursing into
  nested maps/lists -- `:args`, `:options`, `:blast_radius` can all nest)
  and replaces every binary with `:binary.copy/1`'s independent copy.

  One subtlety this module's own full-rebuild-every-`advance/2`-call
  architecture forces: `Projection.project/2` rebuilds `blocks` from
  `source_events` FROM SCRATCH on every single call (there is no
  per-block memoization anywhere in the block builder's pipeline), so a
  detached copy stored into `projection.blocks` on one call is GONE -- silently
  replaced by a fresh, un-detached rebuild -- the moment the NEXT
  `advance/2` runs, unless something re-applies the detach every time.
  `detach_up_to/2` is that something: it re-detaches every already-sealed
  index (not just the ones newly crossing into "about to seal" this
  step) on EVERY `paint_pending_blocks/1` call. This is real, repeated
  work -- same order as `Projection.project/2`'s own already-O(n)
  per-call rebuild, so it changes the constant factor, not the
  complexity class -- but it is what makes the fix actually STICK: a
  one-shot copy that only touches the newly-sealing block would be
  silently undone by the very next `advance/2`'s fresh projection for
  every block sealed in an EARLIER call, which defeats the whole point.

  The more foundational fix belongs one layer down, in
  `Raxol.Harness.Projection.BlockBuilder` -- copying at first extraction,
  before a sub-binary content string is ever assigned to a `Block` struct
  at all, rather than after the fact here. That module is already merged
  on master; this Surface-side copy is the surgical stopgap until a
  block-builder follow-up lands the earlier, more foundational fix.
  Tracked, not forgotten.

  A related, NOT-implemented-here option for a future agent-lane surface
  (long-running, intermittently-idle sessions): `:erlang.hibernate`/`Process.hibernate`
  between turns compacts the process heap and frees any transient
  fragmentation the streaming path accumulated while a turn was running --
  independent of this fix (hibernation compacts what's ALREADY garbage;
  it cannot un-pin a buffer still referenced by a live sub-binary), and
  out of scope for a fixture-replay module that has no live idle period to
  hibernate during. Noted here as the next thing to reach for, not
  implemented.

  ## External editor handoff (the `:edit_draft` command, Ctrl+E)

  Long prompts don't belong in a 6-row footer composer. The Ctrl+E chord
  (`Raxol.UI.Harness.Keymap`'s `:edit_draft`, an `:always` bind) hands
  the composer draft to `$VISUAL`/`$EDITOR` via the injected
  `:editor_session` (see `new/2`'s options): the session suspends the
  terminal claim (the canonical suspend bytes release the DECSTBM
  region, cooked modes come back, the BEAM stdin reader is gated off),
  runs the editor synchronously attached to the tty, and resumes (raw
  mode, reader, init bytes). What the session deliberately does NOT do
  is re-pin the region -- region bytes are owned by THIS model's
  authority, so every return branch here composes
  `InlineAuthority.resize/3 |> InlineAuthority.reassert/1`
  (`resize/3` alone is geometry-gated: a terminal NOT resized while
  suspended would get zero region bytes and stay silently un-pinned),
  and `reassert/1`'s `needs_keyframe` latch turns the next
  `paint_footer/1` into a full keyframe. On editor exit 0 the edited
  draft replaces the composer's value (`Composer.set_value/2`); any
  other outcome keeps the original draft and surfaces a one-frame
  footer notice through the existing `stub_notice` channel.

  Sealed history above the footer survives the whole bracket untouched
  by construction -- no code path here or in the session addresses a
  history row, and the suspend bytes contain no `\\e[2J`/`\\e[3J`. The
  one documented residual: an editor that does NOT use the alternate
  screen may scribble over the not-yet-scrolled on-screen portion of
  history (cosmetic; content already in native scrollback is unreachable
  to us and to it). `:flat` mode has no footer composer to hand a draft
  back to, so `:edit_draft` there seals one honest history line saying
  so instead of pretending.

  ## Precondition #7 -- teardown ownership (this module owns NONE)

  `new/2` sets the DECSTBM history/footer split via
  `InlineAuthority.new/5` (a `CSI 1;(H-N) r` write), but this module never
  releases it -- there is no `Surface.stop/1`/`terminate/2` here, and
  none of the functions above ever emit `CSI r` (the full-screen scroll-
  region release). In the demo (`examples/harness_fixture_demo.exs`), that
  release happens for free because the driver embedding this module is
  `Raxol.Terminal.InlineDriver`, whose own `terminate/2` calls
  `emit_teardown/2` -> `Raxol.Terminal.InlineDriver.Sequences.teardown_bytes/1`,
  which writes `release_region/0` (`"\\e[r"`) -- among the other canonical
  teardown steps -- before the process exits.

  A caller that embeds THIS module directly, without `InlineDriver` (or
  any equivalent that already owns scroll-region teardown), inherits no
  such cleanup: the terminal is left with a permanent DECSTBM split after
  the process exits, which strands the shell prompt inside the old
  history/footer region. Such a caller MUST emit the release itself --
  at minimum `IO.write(device, "\\e[r")` (`CSI r`, reset the scroll region
  to the full screen), or, for the full canonical teardown order (modes
  off, then region release, then autowrap+cursor restore, then move-to-
  bottom), call `Raxol.Terminal.InlineDriver.Sequences.teardown_bytes/1`
  directly. This module deliberately exposes no `teardown_bytes/1` of its
  own: it would either duplicate that module's pinned byte order or drift
  from it, and there is exactly one canonical teardown sequence already
  shipped for callers to reuse.
  """

  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.Projection
  alias Raxol.Harness.RecencyPolicy
  alias Raxol.Harness.SealFrontier
  alias Raxol.Terminal.ScrollRegionManager
  alias Raxol.Harness.StatusStrip
  alias Raxol.Harness.Surface.ViewText

  alias Raxol.UI.Components.Harness.{Block, BlockBody, Composer}
  alias Raxol.UI.Harness.{InputEvent, Keymap, OverlayPicker}

  alias Raxol.UI.Rendering.PaintAuthority.{
    FlatAuthority,
    InlineAuthority,
    ModeSelect
  }

  @default_footer_rows 6
  @stub_interrupt_notice "» interrupt requested (stub — no agent lane in fixture mode)"

  @type mode :: :inline_log | :tmux_conservative | :flat
  @type t :: %{
          mode: mode(),
          authority: InlineAuthority.t() | FlatAuthority.t(),
          events: [map()],
          revealed: non_neg_integer(),
          projection: Projection.t(),
          fold_defaults: map(),
          painted_count: non_neg_integer(),
          fold_overrides: %{optional([term()]) => Block.fold_state()},
          focused_index: non_neg_integer() | nil,
          composer: map(),
          composing?: boolean(),
          width: pos_integer(),
          rows: pos_integer(),
          footer_rows: pos_integer(),
          status: map(),
          stub_notice: String.t() | [String.t()] | nil,
          overlay: overlay() | nil,
          editor_session: module() | (String.t(), keyword() -> term()) | nil,
          editor_opts: keyword()
        }

  @typedoc """
  The hosted overlay picker's state: the pure `OverlayPicker.t()` plus the
  caller-supplied (or default) commit callback. `on_pick` is invoked as
  `on_pick.(model, item)` AFTER `close_overlay/1` has already restored the
  footer to its base row count -- see `handle_input/2`'s `:passthrough`
  routing.
  """
  @type overlay :: %{
          picker: OverlayPicker.t(),
          on_pick: (t(), term() -> t())
        }

  # -- construction -------------------------------------------------------

  @doc """
  Builds the initial model. Does not reveal any fixture events yet (call
  `advance/2` to step through the session) but DOES paint the initial
  footer (empty status + composer prompt) so `render/1`-equivalent state
  is always consistent immediately after construction.

  ## Options

    * `:device` (required) -- the output `IO.device()`.
    * `:width`, `:rows` (required) -- terminal geometry.
    * `:footer_rows` (default #{@default_footer_rows}).
    * `:env` (default `System.get_env/0`) -- fed to
      `ModeSelect.select_with_reason/3`.
    * `:tty?` -- merged into `:env` as `:tty?` (default `true`).
    * `:capabilities` -- a `%Raxol.Terminal.Capabilities{}` or `nil`.
    * `:fold_defaults` -- forwarded to `Projection.project/2`.
    * `:mode` -- explicit override bypassing `ModeSelect.select_with_reason/3`
      entirely (test seam). Bypasses the startup mode notice below too --
      an explicit `:mode` is a test/caller decision, not a pick this
      module made, so there is no `reason()` to explain.
    * `:editor_session` -- `nil` (default), a module implementing
      `Raxol.Harness.EditorSession`'s `run(draft, opts)` contract, or a
      2-arity fun with the same contract. Enables the Ctrl+E external-
      editor handoff (see the moduledoc's "External editor handoff"
      section); `nil` renders an honest stub notice instead. Embedders
      with a real tty pass `Raxol.Harness.EditorSession`; tests inject a
      fun returning canned outcomes.
    * `:editor_opts` -- extra options merged into every editor-session
      call (e.g. `editor_timeout_ms: 60_000`, or an explicit vetted
      `:env` -- see `Raxol.Harness.EditorSession`'s trust-boundary
      section). Model-owned `device`/`rows`/`width` always win over
      entries here.

  ## Startup mode notice (the degradation ladder's `select_with_reason/3` seam)

  When mode-pick is NOT explicitly overridden, this uses
  `ModeSelect.select_with_reason/3` and surfaces a one-line, visible
  notice whenever the reason is `:degenerate_clamp` (the terminal is too
  short for a footer, silently clamped to `:flat`) or
  `:override_unrecognized` (`RAXOL_HARNESS_MODE` was set to something
  other than `flat`/`tmux`/`inline` and got ignored) -- both cases where
  the session is running in a DIFFERENT mode than an operator watching
  the startup env might expect, and silence would read as "it just
  picked `:inline_log` as always" rather than "it downgraded and here's
  why." Every other reason (`:override`, `:headless`, `:tmux`, `:default`)
  is an unsurprising, correctly-resolved pick -- no notice.

  The notice reaches the screen through whichever channel the RESOLVED
  mode actually has available: for `:flat` (the only mode
  `:degenerate_clamp` ever resolves to; `:override_unrecognized` can also
  auto-detect into `:flat` via the headless rule), `paint_footer/1` is a
  documented no-op -- flat has no footer -- so the notice is instead
  SEALED as the session's first history line, through the exact same
  `FlatAuthority.seal/2` append path every other flat-mode block uses.
  For any other resolved mode, the footer's existing one-shot
  `stub_notice` mechanism (`notice_line/2`, already consumed by the next
  `paint_footer/1` call) carries it -- set here, before this function's
  own trailing `paint_footer/1` call, so the very first rendered frame
  shows it.
  """
  @spec new(Session.t() | [map()], keyword()) :: t()
  def new(session_or_events, opts) do
    device = Keyword.fetch!(opts, :device)
    width = Keyword.fetch!(opts, :width)
    rows = Keyword.fetch!(opts, :rows)
    footer_rows = Keyword.get(opts, :footer_rows, @default_footer_rows)
    fold_defaults = Keyword.get(opts, :fold_defaults, %{})
    caps = Keyword.get(opts, :capabilities)

    env =
      opts
      |> Keyword.get(:env, System.get_env())
      |> Map.put(:tty?, Keyword.get(opts, :tty?, true))

    {mode, mode_reason} = resolve_mode(opts, caps, env, rows, footer_rows)

    authority = build_authority(mode, device, width, rows, footer_rows, caps)

    {:ok, composer} =
      Composer.init(%{id: "surface-composer", width: width - 2, focused: true})

    model = %{
      mode: mode,
      authority: authority,
      events: events_from(session_or_events),
      revealed: 0,
      projection: Projection.project([], fold_defaults: fold_defaults),
      fold_defaults: fold_defaults,
      painted_count: 0,
      fold_overrides: %{},
      focused_index: nil,
      composer: composer,
      composing?: true,
      width: width,
      rows: rows,
      footer_rows: footer_rows,
      status: %{},
      stub_notice: nil,
      overlay: nil,
      editor_session: Keyword.get(opts, :editor_session),
      editor_opts: Keyword.get(opts, :editor_opts, [])
    }

    model
    |> apply_mode_notice(mode_notice_text(mode_reason, env))
    |> paint_footer()
  end

  # `:mode` (test seam) bypasses `ModeSelect.select_with_reason/3` entirely
  # -- and has no `reason()` to report, since it was never picked by this
  # module at all. Split out of `new/2` to keep that function's own ABC
  # complexity within budget.
  defp resolve_mode(opts, caps, env, rows, footer_rows) do
    case Keyword.fetch(opts, :mode) do
      {:ok, explicit_mode} ->
        {explicit_mode, nil}

      :error ->
        ModeSelect.select_with_reason(caps, env,
          rows: rows,
          footer_rows: footer_rows
        )
    end
  end

  # -- startup mode notice (see `new/2`'s moduledoc section) ---------------

  defp mode_notice_text(:degenerate_clamp, _env) do
    "» terminal too small for a footer — falling back to flat/plain output"
  end

  defp mode_notice_text(:override_unrecognized, env) do
    raw = Map.get(env, "RAXOL_HARNESS_MODE")

    "» RAXOL_HARNESS_MODE=#{raw} not recognized (flat|tmux|inline) — " <>
      "auto-detecting instead"
  end

  defp mode_notice_text(_other_reason, _env), do: nil

  defp apply_mode_notice(model, nil), do: model

  # `:flat` has no footer for `stub_notice`/`paint_footer/1` to ever reach
  # (`paint_footer(%{mode: :flat} = model), do: model` below is a total
  # no-op) -- seal the notice as the first history line instead, through
  # the same `FlatAuthority.seal/2` path `seal_block/2`'s `:flat` clause
  # uses for every other line.
  defp apply_mode_notice(%{mode: :flat} = model, text) do
    lines = ViewText.lines(%{type: :text, content: text}, model.width, :plain)
    iodata = Enum.map(lines, &(&1 <> "\n"))
    %{model | authority: FlatAuthority.seal(model.authority, iodata)}
  end

  defp apply_mode_notice(model, text), do: %{model | stub_notice: text}

  defp build_authority(:flat, device, width, rows, _footer_rows, _caps),
    do: FlatAuthority.new(device, width, rows)

  defp build_authority(_mode, device, width, rows, footer_rows, caps),
    do:
      InlineAuthority.new(device, width, rows, footer_rows, capabilities: caps)

  defp events_from(%Session{envelopes: envelopes}),
    do: Enum.map(envelopes, & &1.body)

  defp events_from(events) when is_list(events), do: events

  @doc """
  Startup discipline: push any existing dirty screen
  content into scrollback via plain newlines, NEVER `\\e[2J` (which would
  wipe native scrollback on wezterm/kitty). Callers write this
  BEFORE the substrate's scroll region is established (i.e. before
  `new/2`), since `InlineAuthority.new/5` only sets the DECSTBM split --
  it never clears or pushes anything on its own.
  """
  @spec startup_push_up(IO.device(), pos_integer()) :: :ok
  def startup_push_up(device, rows) when is_integer(rows) and rows > 0 do
    IO.write(device, String.duplicate("\n", rows))
    :ok
  end

  # -- fixture replay -------------------------------------------------------

  @doc """
  Reveals exactly one more fixture event, re-projects (`Projection.project/2`
  is pure and cheap over a growing prefix -- see the moduledoc), paints any
  block that fell out of the "trailing pending" slot as a result (see
  `paint_pending_blocks/1`), refreshes turn/status derivation, and repaints
  the footer. `now`, when given, stamps `status.now`/`status.last_event_at`
  (the status strip's own no-wall-clock contract: both are plain
  caller-supplied integers, never read from a live clock inside this
  module).

  Returns `{model, :ok}` while events remain, `{model, :done}` once every
  fixture event has been revealed AND the final pending block (if any) has
  been flushed to paint.
  """
  @spec advance(t(), integer() | nil) :: {t(), :ok | :done}
  def advance(model, now \\ nil)

  def advance(
        %{revealed: revealed, events: events, painted_count: painted} = model,
        _now
      )
      when revealed >= length(events) and
             painted >= length(model.projection.blocks) do
    {model, :done}
  end

  def advance(model, now) do
    revealed = min(model.revealed + 1, length(model.events))
    events_so_far = Enum.take(model.events, revealed)

    projection =
      Projection.project(events_so_far, fold_defaults: model.fold_defaults)

    model =
      %{model | revealed: revealed, projection: projection}
      |> paint_pending_blocks()
      |> update_status(events_so_far, now)
      |> paint_footer()

    finished? =
      model.revealed >= length(model.events) and
        model.painted_count >= length(model.projection.blocks)

    {model, if(finished?, do: :done, else: :ok)}
  end

  @doc """
  Advances the elapsed-since-last-event ticker (the status strip's
  `Stage` slot) without revealing a new fixture event -- elapsed ticks
  during a long silent tool call (the status strip's own acceptance).
  Plain caller-supplied `now`, same no-wall-clock discipline as
  `advance/2`.
  """
  @spec tick(t(), integer()) :: t()
  def tick(model, now) when is_integer(now) do
    model
    |> put_in([:status, :now], now)
    |> paint_footer()
  end

  @doc """
  Builds the seal-frontier entry list (`Raxol.Harness.SealFrontier.entry/0`)
  from the current projection. One entry per completed block, in order;
  the live tail never enters the list (a still-streaming item has no
  committable form until it completes into a block, so it is
  definitionally past the frontier).

  Field mapping (the design decision this assembly makes):

    * `committed?` -- `index < painted_count`: physical paint is this
      module's commit marker, and it only ever advances a contiguous
      prefix, so the high-water mark IS the committed set.
    * `running?` -- `Block.live?/1`, an honest passthrough. Always false
      today (the block builder only constructs completed, sealed blocks),
      which leaves the classifier's mid-turn running exceptions dormant
      until a producer emits still-running entries.
    * `pending_input?` -- the frontier gate's invariant is "the rendered
      form can still change on user interaction; print-once must not
      freeze it," and this feed derives BOTH instances of it:

        1. A LIVE `:approval` block (`Block.live?/1` with
           `kind: :approval`) is, per `Block`'s own contract, a question
           still waiting on the user -- the genuine awaiting-input
           lifecycle, held in EVERY turn state and at any position (the
           gate exists precisely so the idle relaxation can never seal an
           unanswered prompt past a stale running flag). Dormant today --
           the block builder only constructs sealed blocks -- but the
           gate's contract holds the moment a producer emits live
           approval blocks.
        2. The NEWEST block while the fixture reveal is unfinished: the
           one-advance foldable window (see the moduledoc's "Fold/jump
           and the seal-time-only gate"), expressed in frontier terms --
           a fold toggle is the pending interaction. The hold is
           unconditional on turn state (matching the window's own
           semantics: it releases on reveal completion, not on turn
           boundaries). When the block builder later grows a
           completed-but-unsealed phase, this derivation moves down a
           layer.
  """
  @spec frontier_entries(t()) :: [SealFrontier.entry()]
  def frontier_entries(model) do
    blocks = model.projection.blocks
    total = length(blocks)
    reveal_finished? = model.revealed >= length(model.events)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{
        kind: block.kind,
        committed?: index < model.painted_count,
        running?: Block.live?(block),
        pending_input?:
          awaiting_input?(block) or
            (not reveal_finished? and index == total - 1)
      }
    end)
  end

  # A live approval block is, per `Block`'s own contract, a question still
  # waiting on the user -- the genuine awaiting-input feed for the
  # frontier's pending-input gate. A sealed approval is an answered
  # question and does not feed the gate. See `frontier_entries/1`'s doc.
  defp awaiting_input?(block),
    do: Block.live?(block) and block.kind == :approval

  @doc """
  The shared frontier consultation every consumer in this module goes
  through: `SealFrontier.scan_frontier/3` over `frontier_entries/1`.
  `tail_start` is both the seal pass's paint target and the first block
  the footer's pending preview may show -- one number, so the two can
  never disagree. `turn_running?` is derived from the status snapshot
  (`turn_completed`); with today's entry mapping (no running entries,
  window hold unconditional) the scan result is independent of turn
  state, so the one-step-stale status at seal time is harmless.
  """
  @spec frontier_scan(t()) :: SealFrontier.scan()
  def frontier_scan(model) do
    SealFrontier.scan_frontier(frontier_entries(model), turn_running?(model))
  end

  defp turn_running?(model),
    do: not Map.get(model.status, :turn_completed, false)

  # Leaves the newest completed block un-painted for exactly one more
  # `advance/2` call (see moduledoc, "Fold/jump and the seal-time-only gate") --
  # UNLESS the fixture has finished revealing, in which case every
  # remaining block is flushed (nothing will ever arrive to make the last
  # block "not newest" otherwise, and it would never get painted). The
  # hold now lives in `frontier_entries/1`'s pending-input mapping;
  # `SealFrontier`'s shared classifier decides where the frontier stops
  # from there.
  defp paint_pending_blocks(model) do
    entries = frontier_entries(model)
    turn_running? = turn_running?(model)
    scan = SealFrontier.scan_frontier(entries, turn_running?)

    # `model.projection` was just rebuilt FRESH by `Projection.project/2`
    # (`advance/2`, the caller) -- EVERY block, including ones already
    # physically painted in an EARLIER `advance/2` call, comes back as a
    # brand-new struct. Its `content` strings are whatever
    # `extract_content/2` re-derives from `source_events` -- the SAME
    # (still potentially sub-binary-referencing) reference every time,
    # since re-extracting an already-binary payload is a pure passthrough
    # (`Block.to_display_text/1`), never a copy. Detaching every index
    # `< target` here -- the already-sealed prefix from earlier calls AND
    # the ones newly crossing into "about to be sealed" this step alike
    # -- is what makes `detach_content/1`'s fix actually STICK across
    # calls: skipping the already-sealed prefix would let the very next
    # `advance/2` silently hand back an un-detached reference for every
    # block this module already committed to never holding once sealed
    # (see the moduledoc's "sub-binary pinning footgun" section).
    model = detach_up_to(model, scan.tail_start)

    # The ONE mutating frontier walk (SealFrontier's moduledoc): emit
    # each newly-committable block via seal_block/2, which advances
    # painted_count -- the committed marker frontier_entries/1 reads.
    # The emit is infallible today (InlineAuthority.seal/2 has no error
    # path), so the walk's write-failure branch stays corpus-only until
    # a write-confirming substrate lands (the two-phase seal follow-up).
    result =
      SealFrontier.commit_walk(
        entries,
        turn_running?,
        model,
        fn acc, index ->
          block =
            acc.projection.blocks
            |> Enum.at(index)
            |> apply_fold_override(index, acc.fold_overrides)

          {:ok, seal_block(acc, block)}
        end,
        cursor: model.painted_count
      )

    result.acc
  end

  # Detaches (see `detach_content/1`) every block at index `< target` and
  # persists the result back into `projection.blocks`. Re-touches the
  # ALREADY-sealed prefix on every call (not just the slice newly sealing
  # this step) -- see `paint_pending_blocks/1`'s comment for why that
  # repetition is required, not wasted: the fresh rebuild above hands
  # back un-detached content for the whole list every single call.
  defp detach_up_to(model, target) do
    updated_blocks =
      model.projection.blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        if index < target, do: detach_content(block), else: block
      end)

    %{model | projection: %{model.projection | blocks: updated_blocks}}
  end

  # Deep-copies every binary in `block.content` (recursing into nested
  # maps/lists -- `:args`, `:options`, `:blast_radius` can all nest) via
  # `:binary.copy/1`, breaking any sub-binary reference to a larger
  # originating buffer (a stream chunk, a decoded `.jsonl` line -- see the
  # moduledoc). Non-binary content (atoms, numbers, `nil`, the
  # `:tainted` boolean) passes through unchanged.
  defp detach_content(%Block{content: content} = block),
    do: %{block | content: detach_binaries(content)}

  defp detach_binaries(bin) when is_binary(bin), do: :binary.copy(bin)

  defp detach_binaries(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, detach_binaries(v)} end)

  defp detach_binaries(list) when is_list(list),
    do: Enum.map(list, &detach_binaries/1)

  defp detach_binaries(other), do: other

  defp apply_fold_override(block, index, overrides) do
    case Map.get(overrides, index) do
      nil -> block
      # `fold_after_seal: :allow` deliberately overrides `Block`'s own
      # (inapplicable here) default -- see the moduledoc's "Fold/jump and
      # the seal-time-only gate" section: `block.seal` is always `:sealed`
      # by construction (`BlockBuilder` always seals at construction), so
      # this module's OWN `painted_count` gate (in `apply_fold_toggle/2`)
      # is what actually enforces "no fold after physical paint," not
      # `Block`'s.
      :folded -> Block.fold(block, fold_after_seal: :allow)
      :expanded -> Block.unfold(block, fold_after_seal: :allow)
    end
  end

  defp seal_block(%{mode: :flat} = model, block) do
    lines = render_block_lines(block, model, :plain)
    iodata = Enum.map(lines, &(&1 <> "\n"))
    authority = FlatAuthority.seal(model.authority, iodata)
    %{model | authority: authority, painted_count: model.painted_count + 1}
  end

  # No per-line `\e[K` here: `InlineAuthority.seal/2` sanitizes CONTENT
  # through `ContentGuard.sanitize_line/1` (its allowlist keeps SGR only),
  # so an EL embedded in content never survived -- the guard stripped the
  # ESC and left a literal `[K` painted at the start of every sealed
  # history row (caught by the byte-golden sidecar; pinned by the
  # ESC-less-residue guard in test/harness/golden_snapshot_test.exs).
  # Erasing is the authority's business, not content's: sealed lines land
  # on rows the DECSTBM scroll already blanked, so no EL is needed.
  defp seal_block(model, block) do
    lines = render_block_lines(block, model, :styled)
    iodata = Enum.map(lines, &[&1, "\r\n"])
    authority = InlineAuthority.seal(model.authority, iodata)
    %{model | authority: authority, painted_count: model.painted_count + 1}
  end

  # Called from seal_block/2 -- the print-once paint -- so the grade
  # computed here IS the seal-time grade (see RecencyPolicy's moduledoc,
  # "Seal-time grading"): painted history is never re-graded because it
  # is never repainted. The grade trusts source_events' journal order
  # and durable completeness -- both guaranteed upstream
  # (Recovery.filter_ids/1 id-monotonicity; un-windowed durable-only
  # retention); see RecencyPolicy.grade_block/2's input contract.
  defp render_block_lines(block, model, mode) do
    prominence =
      RecencyPolicy.grade_block(block, model.projection.source_events)

    block
    |> BlockBody.render(%{width: model.width, prominence: prominence})
    |> ViewText.lines(model.width, mode)
  end

  # -- status/turn derivation (precondition #4) ----------------------------

  defp update_status(model, events_so_far, now) do
    loop_events =
      Enum.filter(events_so_far, &(event_field(&1, :family) == :loop))

    last_loop = List.last(loop_events)

    last_turn_completed =
      loop_events
      |> Enum.filter(&(event_field(&1, :type) == :turn_completed))
      |> List.last()

    turn_completed? = last_loop != nil and last_loop == last_turn_completed

    needs_input? =
      last_loop != nil and event_field(last_loop, :type) == :approval_requested

    cost =
      if last_turn_completed,
        do: payload_field(last_turn_completed, "cost", :cost)

    status =
      model.status
      |> Map.put(:turn_stage, last_loop && event_field(last_loop, :type))
      |> Map.put(:turn_completed, turn_completed?)
      |> Map.put(:needs_input, needs_input?)
      |> Map.put(:cost, cost)
      |> maybe_put_now(now, last_loop)

    %{model | status: status}
  end

  defp maybe_put_now(status, nil, _last_loop), do: status

  defp maybe_put_now(status, now, last_loop) when is_integer(now) do
    status
    |> Map.put(:now, now)
    |> Map.put(
      :last_event_at,
      if(last_loop, do: now, else: Map.get(status, :last_event_at))
    )
  end

  defp event_field(event, key), do: Map.get(event, key)

  defp payload_field(event, string_key, atom_key) do
    case Map.get(event, :payload) do
      %{} = payload -> Map.get(payload, string_key, Map.get(payload, atom_key))
      _other -> nil
    end
  end

  # -- input dispatch (precondition #2: keymap-first) ----------------------

  @doc """
  Normalizes `raw_event` (`InputEvent.normalize/1`) and resolves it via
  `Keymap.resolve/2` BEFORE the Composer ever sees it -- see the
  moduledoc's precondition #2. A `:passthrough` result reaches
  `Composer.handle_event/3` only while `composing?` AND no overlay is
  open; while an overlay picker is open (`model.overlay != nil`), a
  `:passthrough` result instead reaches
  `Raxol.UI.Harness.OverlayPicker.handle_key/2` with the SAME normalized
  event this function already computed (never re-normalized) -- see "The
  overlay picker" section above. Always repaints the footer afterward.
  """
  @spec handle_input(t(), term()) :: t()
  def handle_input(model, raw_event) do
    norm = InputEvent.normalize(raw_event)

    context = %{
      composing?: model.composing?,
      streaming?: not Map.get(model.status, :turn_completed, false),
      focused_block_id: model.focused_index,
      overlay_open?: model.overlay != nil
    }

    model =
      case Keymap.resolve(norm, context) do
        :passthrough -> route_passthrough(model, norm, raw_event)
        command -> dispatch_command(model, command)
      end

    paint_footer(model)
  end

  # While an overlay is open, EVERY :passthrough event (typed characters,
  # arrows, Enter, an unrecognized special key) is routed to the overlay
  # picker instead of the Composer -- the composer's buffer is frozen
  # mid-pick (see the moduledoc's command-bifurcation note on `:steer`).
  defp route_passthrough(%{overlay: overlay} = model, norm, _raw_event)
       when overlay != nil do
    case OverlayPicker.handle_key(overlay.picker, norm) do
      {:continue, picker} ->
        %{model | overlay: %{overlay | picker: picker}}

      {:picked, item} ->
        # Close FIRST so on_pick sees the already-restored (base) footer
        # -- the trailing paint_footer/1 in handle_input/2 then paints
        # whatever notice on_pick set, at the correct row count.
        model
        |> close_overlay()
        |> then(&overlay.on_pick.(&1, item))

      :dismissed ->
        # Defensive only: with the overlay open, the Keymap's :overlay
        # guard captures ESC as :overlay_dismiss before it ever reaches
        # :passthrough (see Keymap's moduledoc), so this clause is not
        # expected to fire in practice.
        close_overlay(model)
    end
  end

  defp route_passthrough(model, _norm, raw_event),
    do: maybe_forward_to_composer(model, raw_event)

  defp maybe_forward_to_composer(%{composing?: true} = model, raw_event) do
    {composer, commands} = Composer.handle_event(raw_event, model.composer, %{})

    Enum.reduce(
      commands,
      %{model | composer: composer},
      &apply_composer_command/2
    )
  end

  defp maybe_forward_to_composer(model, _raw_event), do: model

  defp apply_composer_command({:component_event, _id, {:submit, text}}, model) do
    %{model | stub_notice: "» (stub) would send prompt: #{text}"}
  end

  defp apply_composer_command(_command, model), do: model

  defp dispatch_command(model, %{type: :overlay_dismiss}),
    do: close_overlay(model)

  defp dispatch_command(model, %{type: :fold_toggle}) do
    apply_fold_toggle(model, model.focused_index)
  end

  defp dispatch_command(model, %{type: :jump_next}), do: move_focus(model, 1)
  defp dispatch_command(model, %{type: :jump_prev}), do: move_focus(model, -1)

  defp dispatch_command(model, %{type: :interrupt}) do
    %{model | stub_notice: @stub_interrupt_notice}
  end

  # An open overlay freezes the composer buffer mid-pick (see the
  # moduledoc's command-bifurcation note) -- queuing a steer built from
  # that hidden state would be dishonest UI. This clause MUST precede the
  # general `:steer` clause below (function-clause order is load-bearing
  # here, same as `Keymap.binds/0`'s own ESC-priority note).
  defp dispatch_command(%{overlay: overlay} = model, %{type: :steer})
       when overlay != nil,
       do: model

  # Same freeze rationale for the editor handoff: an open overlay hides
  # the composer buffer mid-pick, and suspending the terminal to edit
  # that hidden state (while the footer is overlay-shaped and would be
  # keyframed back at the WRONG row split on resume) would be the same
  # dishonest UI. Clause order load-bearing, as above.
  defp dispatch_command(%{overlay: overlay} = model, %{type: :edit_draft})
       when overlay != nil,
       do: model

  defp dispatch_command(model, %{type: :edit_draft}), do: run_editor(model)

  defp dispatch_command(model, %{type: :steer}) do
    text = Composer.value(model.composer)

    composer =
      Composer.update(
        {:set_queued_steer, %{text: text, queued_at: model.revealed}},
        model.composer
      )
      |> elem(0)

    %{model | composer: composer}
  end

  defp dispatch_command(model, _other), do: model

  # -- external editor handoff (the :edit_draft command) -------------------
  #
  # Ordering of the clauses is load-bearing: flat mode first (there is no
  # footer composer to hand a draft back to, whatever session is wired),
  # then the no-session stub, then the real handoff.

  # `:flat` has no footer and never renders the composer, so there is no
  # surface for the edited draft (or a footer notice) to come back to --
  # seal one honest history line instead, through the same
  # `FlatAuthority.seal/2` path `apply_mode_notice/2` uses.
  defp run_editor(%{mode: :flat} = model) do
    lines =
      ViewText.lines(
        %{
          type: :text,
          content: "» external editor requires the footer composer (flat mode)"
        },
        model.width,
        :plain
      )

    iodata = Enum.map(lines, &(&1 <> "\n"))
    %{model | authority: FlatAuthority.seal(model.authority, iodata)}
  end

  defp run_editor(%{editor_session: nil} = model) do
    %{model | stub_notice: "» external editor not wired in this embedding"}
  end

  defp run_editor(model) do
    draft = Composer.value(model.composer)

    # `:editor_opts` is the embedder seam (timeout, vetted env, ...);
    # model-owned device/geometry always win.
    opts =
      Keyword.merge(model.editor_opts,
        device: authority_device(model.authority),
        rows: model.rows,
        width: model.width
      )

    # The session returns with the tty raw again and the reader re-enabled,
    # but WITHOUT the DECSTBM pin (region bytes are owned by this model's
    # authority -- see `Raxol.Harness.EditorSession`'s moduledoc). Every
    # branch below therefore runs `resume_geometry/3`: `resize/3` absorbs a
    # mid-suspend terminal resize, `reassert/1` guarantees the pin when
    # geometry did NOT change (resize alone is geometry-gated and would
    # write zero region bytes), and its `needs_keyframe` latch makes
    # `handle_input/2`'s trailing `paint_footer/1` self-promote to a full
    # keyframe. Belt-and-braces on the `{:error, _}` branch too: the
    # session's compensation already restored what it could, and one
    # redundant, idempotent DECSTBM re-emit is cheaper than reasoning about
    # exactly which failure points left the region released.
    case call_editor_session(model.editor_session, draft, opts) do
      {:ok, %{text: text, width: width, rows: rows} = result} ->
        model = resume_geometry(model, width, rows)
        model = %{model | composer: Composer.set_value(model.composer, text)}
        apply_degraded_notice(model, Map.get(result, :degraded, []))

      {:kept, reason, %{width: width, rows: rows} = geo} ->
        model = resume_geometry(model, width, rows)
        model = %{model | stub_notice: kept_notice(reason)}
        apply_degraded_notice(model, Map.get(geo, :degraded, []))

      {:error, reason} ->
        model = resume_geometry(model, model.width, model.rows)

        %{
          model
          | stub_notice: "» editor suspend aborted: #{inspect(reason)}"
        }
    end
  end

  # A non-empty degradation list means the session resumed but a
  # terminal resource could not be restored -- today, the stdin reader
  # after the editor. This MUST be visible (the review's critical
  # finding was exactly this warning being swallowed): the operator is
  # about to discover their keyboard is dead, and a silent success frame
  # would read as "everything is fine".
  #
  # The warning gets its OWN notice line, never appended to a kept
  # notice: `ViewText.lines/3` end-truncates each line to the width
  # budget, so a same-line append made the warning the first casualty of
  # a long kept notice (e.g. a long `{:editor_not_found, cmd}`) on an
  # 80-column terminal -- the round-2 review's finding. Per-line, both
  # messages survive truncation independently.
  defp apply_degraded_notice(model, []), do: model

  defp apply_degraded_notice(model, [_ | _]) do
    warning =
      "» warning: input reader failed to re-enable — keyboard may be dead"

    notice =
      case model.stub_notice do
        nil -> warning
        kept -> [kept, warning]
      end

    %{model | stub_notice: notice}
  end

  # The session's contract propagates exceptions AFTER running its
  # compensation (see `Raxol.Harness.EditorSession`) -- the terminal is
  # already restored by the time one reaches here, so this UI loop
  # degrades to the same notice path as any other session error instead
  # of crashing mid-frame.
  defp call_editor_session(session, draft, opts) do
    invoke_editor_session(session, draft, opts)
  rescue
    error -> {:error, {:editor_session, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:editor_session, {kind, reason}}}
  end

  defp invoke_editor_session(session, draft, opts) when is_atom(session),
    do: session.run(draft, opts)

  defp invoke_editor_session(session, draft, opts)
       when is_function(session, 2),
       do: session.(draft, opts)

  defp authority_device(%{region: %{device: device}}), do: device

  # Mirrors `resize/2`'s inline-mode shape but composes
  # `InlineAuthority.resize/3 |> InlineAuthority.reassert/1` -- the
  # documented resume composition (see `InlineAuthority.reassert/1`'s doc
  # for why resize alone cannot re-pin an unchanged geometry). No explicit
  # keyframe call here: `reassert/1` latches `needs_keyframe`, and the
  # caller's trailing `paint_footer/1` self-promotes to a full keyframe.
  defp resume_geometry(model, width, rows) do
    authority =
      model.authority
      |> InlineAuthority.resize(width, rows)
      |> InlineAuthority.reassert()

    %{model | authority: authority, width: width, rows: rows}
  end

  defp kept_notice(:editor_nonzero),
    do: "» editor exited nonzero — draft kept"

  defp kept_notice({:editor_not_found, cmd}),
    do: "» editor not found: #{cmd} — draft kept"

  defp kept_notice(:editor_crashed), do: "» editor crashed — draft kept"

  defp kept_notice(:editor_timeout), do: "» editor timed out — draft kept"

  defp kept_notice(:reload_failed),
    do: "» could not reload edited draft — draft kept"

  defp kept_notice(other), do: "» editor: #{inspect(other)} — draft kept"

  # -- fold / jump (precondition-adjacent: the seal-time-only translation) --

  defp apply_fold_toggle(model, nil), do: model

  defp apply_fold_toggle(model, index)
       when is_integer(index) and index < model.painted_count do
    # Already physically painted -- seal-time-only: sealed history is
    # never repainted, so a fold toggle on it is a documented no-op,
    # exactly like `Block.fold_allowed?/2`'s post-seal gate (enforced
    # here on the PAINT axis, not `Block.seal`, which is always :sealed
    # by the time a block exists at all -- see the moduledoc). The no-op
    # is byte-honest (history is never touched again), but a bare no-op is
    # operator-opaque: unlike the `:interrupt`/`:steer` stubs (precondition
    # #6), which always surface a footer notice, silently swallowing this
    # keypress gives no feedback that anything happened at all. So this
    # sets the SAME one-frame `stub_notice` mechanism those stubs use --
    # consumed (cleared) by the very next `paint_footer/1`, same as
    # `@stub_interrupt_notice` -- rather than inventing a second notice
    # channel. The notice lives in the footer only; it is never appended to
    # history.
    %{model | stub_notice: "» block #{index} sealed — fold unavailable"}
  end

  defp apply_fold_toggle(model, index) do
    case Enum.at(model.projection.blocks, index) do
      nil ->
        model

      block ->
        current = Map.get(model.fold_overrides, index, block.fold)
        next = toggle(current)
        %{model | fold_overrides: Map.put(model.fold_overrides, index, next)}
    end
  end

  defp toggle(:folded), do: :expanded
  defp toggle(:expanded), do: :folded

  defp move_focus(model, delta) do
    total = length(model.projection.blocks)

    if total == 0 do
      model
    else
      current = model.focused_index || if delta > 0, do: -1, else: total
      next = (current + delta) |> max(0) |> min(total - 1)
      %{model | focused_index: next}
    end
  end

  @doc """
  Moves focus off the composer onto the transcript (browsing mode) --
  this is what enables `Keymap`'s `:not_composing` binds
  (`fold_toggle`/`jump_next`/`jump_prev`) to resolve at all; see the
  moduledoc's precondition #3. No dedicated keybind performs this
  transition in `Keymap.binds/0` today -- callers (tests, or a future
  key/mouse binding) invoke this directly.
  """
  @spec focus_transcript(t()) :: t()
  def focus_transcript(model) do
    {composer, _cmds} = Composer.update(%{focused: false}, model.composer)
    %{model | composing?: false, composer: composer}
  end

  @doc "Returns focus to the composer (the default -- see the moduledoc's precondition #3 note)."
  @spec focus_composer(t()) :: t()
  def focus_composer(model) do
    {composer, _cmds} = Composer.update(%{focused: true}, model.composer)
    %{model | composing?: true, composer: composer}
  end

  # -- overlay picker (see the moduledoc's "The overlay picker" section) ---

  @doc """
  Opens an overlay picker over `items`, growing the footer viewport
  (`InlineAuthority.set_footer_rows/2`) by exactly `OverlayPicker.height/1`
  rows and repainting immediately. See the moduledoc's "The overlay
  picker" section for the full contract.

  ## Options

  Forwarded to `Raxol.UI.Harness.OverlayPicker.new/2` (`:label_fn`,
  `:filter_fn`, `:title`), except `:max_visible`, which this function
  CLAMPS to the available footer capacity before forwarding (a taller
  request is narrowed, never refused -- see below), plus:

    * `:on_pick` -- `(t(), item -> t())`, invoked after the overlay has
      already closed (see `handle_input/2`'s `:passthrough` routing).
      Defaults to an honest one-frame footer notice
      (`"» picked <label>"`), the same stub mechanism `:interrupt`/`:steer`
      use.

  ## Errors

    * `{:error, :overlay_already_open}` -- `model.overlay` is already set.
    * `{:error, :no_footer}` -- `model.mode == :flat` (nothing to grow).
    * `{:error, :insufficient_footer_capacity}` -- the current geometry
      cannot keep history's 2-row minimum AND host at least a 2-row
      overlay (query + one item row). Zero bytes written, model
      untouched.
  """
  @spec open_overlay(t(), [term()], keyword()) ::
          {:ok, t()}
          | {:error,
             :overlay_already_open | :no_footer | :insufficient_footer_capacity}
  def open_overlay(model, items, opts \\ [])

  def open_overlay(%{overlay: overlay}, _items, _opts) when overlay != nil,
    do: {:error, :overlay_already_open}

  def open_overlay(%{mode: :flat}, _items, _opts), do: {:error, :no_footer}

  def open_overlay(model, items, opts) do
    max_overlay_rows = max_overlay_rows(model.rows, model.footer_rows)

    if max_overlay_rows < 2 or degenerate?(model) do
      {:error, :insufficient_footer_capacity}
    else
      do_open_overlay(model, items, opts, max_overlay_rows)
    end
  end

  # The largest overlay row claim the given geometry can host: the
  # biggest `h` for which the grown split (`footer_rows + h`) is still
  # non-degenerate by `ScrollRegionManager.degenerate?/2`'s OWN
  # definition (history keeps its 2-row minimum). Derived by asking that
  # predicate directly rather than re-encoding its `< 2` literal here --
  # this substrate-capacity guard is exactly where a silently-drifted
  # copy of the threshold would be most dangerous. Shared by
  # `open_overlay/3` and `force_close_overlay?/2` (one source of truth).
  defp max_overlay_rows(rows, footer_rows) do
    Enum.find((rows - footer_rows)..0//-1, 0, fn h ->
      not ScrollRegionManager.degenerate?(rows, footer_rows + h)
    end)
  end

  defp do_open_overlay(model, items, opts, max_overlay_rows) do
    effective_max_visible =
      min(
        Keyword.get(opts, :max_visible, OverlayPicker.default_max_visible()),
        max_overlay_rows - 1
      )

    picker_opts = Keyword.put(opts, :max_visible, effective_max_visible)
    picker = OverlayPicker.new(items, picker_opts)
    claimed_rows = OverlayPicker.height(picker)

    case InlineAuthority.set_footer_rows(
           model.authority,
           model.footer_rows + claimed_rows
         ) do
      {:ok, authority} ->
        on_pick = Keyword.get(opts, :on_pick, default_on_pick(picker))
        overlay = %{picker: picker, on_pick: on_pick}
        model = %{model | authority: authority, overlay: overlay}
        {:ok, paint_footer(model)}

      # Unreachable given the capacity check above (belt and braces): a
      # geometry that already passed `degenerate?/1` and the 2-row
      # minimum check can never make `set_footer_rows/2` itself see a
      # degenerate target.
      {:error, :degenerate} ->
        {:error, :insufficient_footer_capacity}
    end
  end

  defp default_on_pick(picker) do
    fn model, item ->
      %{model | stub_notice: "» picked #{picker.label_fn.(item)}"}
    end
  end

  @doc """
  Closes the currently-open overlay picker (a no-op when none is open),
  restoring the footer viewport to `model.footer_rows` (the base value)
  and repainting. See the moduledoc's "The overlay picker" section.
  """
  @spec close_overlay(t()) :: t()
  def close_overlay(%{overlay: nil} = model), do: model

  def close_overlay(model) do
    authority =
      case InlineAuthority.set_footer_rows(model.authority, model.footer_rows) do
        {:ok, authority} -> authority
        # Cannot happen for any authority this module itself constructed
        # (the base footer_rows was already valid when the overlay
        # opened) -- kept the authority unchanged rather than crashing if
        # it somehow did.
        {:error, _reason} -> model.authority
      end

    %{model | authority: authority, overlay: nil}
    |> paint_footer()
  end

  # -- footer paint (precondition #5) --------------------------------------

  defp paint_footer(%{mode: :flat} = model), do: model

  defp paint_footer(model) do
    lines = footer_lines(model)
    authority = InlineAuthority.repaint(model.authority, lines)
    %{model | authority: authority, stub_notice: nil}
  end

  defp footer_lines(model) do
    status_line = StatusStrip.render(model.status, model.width)
    overlay_lines = overlay_lines(model)

    # The pending/live-tail preview is suppressed while an overlay is
    # open -- the overlay claims that space (see the moduledoc's
    # precondition #5 update, "The overlay picker" section).
    preview_lines = if model.overlay, do: [], else: pending_preview_lines(model)

    composer_lines =
      ViewText.lines(
        Composer.render(model.composer, %{available_width: model.width}),
        model.width,
        :styled
      )

    notice_lines = notice_line(model.stub_notice, model.width)

    status_line ++
      overlay_lines ++ preview_lines ++ composer_lines ++ notice_lines
  end

  defp overlay_lines(%{overlay: nil}), do: []

  defp overlay_lines(%{overlay: %{picker: picker}, width: width}),
    do: ViewText.lines(OverlayPicker.render(picker), width, :styled)

  defp notice_line(nil, _width), do: []

  # A LIST of notices renders one footer line each -- each independently
  # width-truncated, so a long first notice can never truncate away a
  # later one (the degraded-resume warning rides this; see
  # `apply_degraded_notice/2`).
  defp notice_line(notices, width) when is_list(notices),
    do: Enum.flat_map(notices, &notice_line(&1, width))

  defp notice_line(text, width),
    do: ViewText.lines(%{type: :text, content: text}, width, :styled)

  # The pending (not-yet-painted) trailing completed block, if any,
  # rendered with its current fold override applied (so a fold toggle
  # on it is visible here -- "assert re-rendered footer/tail reflects
  # it", this unit's own acceptance). Falls back to the live tail (an
  # in-progress, still-accumulating item) when there is no pending block.
  defp pending_preview_lines(model) do
    case pending_block(model) do
      nil ->
        live_tail_preview_lines(model)

      {block, index} ->
        block
        |> apply_fold_override(index, model.fold_overrides)
        |> BlockBody.render(%{width: model.width})
        |> ViewText.lines(model.width, :plain)
        |> Enum.take(2)
    end
  end

  defp pending_block(model) do
    # Post-seal, `tail_start == painted_count` always -- the committed
    # prefix skips to the high-water mark and the walk already consumed
    # everything committable -- so this is the same block as before, now
    # DERIVED from the shared classifier instead of restated.
    tail_start = frontier_scan(model).tail_start

    case Enum.slice(model.projection.blocks, tail_start..-1//1) do
      [] -> nil
      [block | _rest] -> {block, tail_start}
    end
  end

  defp live_tail_preview_lines(%{projection: %{tail: tail}})
       when map_size(tail) == 0,
       do: []

  defp live_tail_preview_lines(%{projection: %{tail: tail}} = model) do
    case tail |> Map.values() |> List.first() do
      nil ->
        []

      %{chunks: chunks} ->
        ViewText.lines(
          %{type: :text, content: "» " <> Enum.join(chunks, "")},
          model.width,
          :plain
        )
    end
  end

  # -- resize (precondition #5) ---------------------------------------------

  @doc """
  Resizes the geometry. Composes `InlineAuthority.resize/3 |>
  InlineAuthority.keyframe/2` explicitly (the documented composition --
  `resize/3` alone never repaints the footer) in inline/tmux modes;
  `FlatAuthority.resize/3` writes zero bytes either way.

  If an overlay is open and the NEW geometry can no longer host it
  (`new_rows - 2 - model.footer_rows < OverlayPicker.height(picker)`), the
  overlay is force-closed FIRST, at the OLD geometry (restoring the base
  footer pin), before the resize itself runs -- see the moduledoc's "The
  overlay picker" section. If it still fits, it stays open: the grown
  footer row count survives the resize (`ScrollRegionManager.resize/2`
  holds `footer_rows` constant, and the overlay's grown claim IS the
  current `footer_rows` as far as the authority is concerned), and the
  keyframe below repaints it at the new position.
  """
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%{mode: :flat} = model, width, rows) do
    %{
      model
      | authority: FlatAuthority.resize(model.authority, width, rows),
        width: width,
        rows: rows
    }
  end

  def resize(model, width, rows) do
    model =
      if force_close_overlay?(model, rows) do
        close_overlay(model)
      else
        model
      end

    model = %{model | width: width, rows: rows}
    authority = InlineAuthority.resize(model.authority, width, rows)
    lines = footer_lines(%{model | authority: authority})
    authority = InlineAuthority.keyframe(authority, lines)
    %{model | authority: authority, stub_notice: nil}
  end

  defp force_close_overlay?(%{overlay: nil}, _new_rows), do: false

  defp force_close_overlay?(
         %{overlay: overlay, footer_rows: footer_rows},
         new_rows
       ) do
    # Same capacity rule `open_overlay/3` admits with -- one helper, one
    # threshold (routed through `ScrollRegionManager.degenerate?/2`),
    # never a re-encoded literal that could drift.
    OverlayPicker.height(overlay.picker) >
      max_overlay_rows(new_rows, footer_rows)
  end

  # -- accessors ------------------------------------------------------------

  @spec done?(t()) :: boolean()
  def done?(model),
    do:
      model.revealed >= length(model.events) and
        model.painted_count >= length(model.projection.blocks)

  @spec degenerate?(t()) :: boolean()
  def degenerate?(%{mode: :flat}), do: false

  def degenerate?(%{authority: authority}),
    do: InlineAuthority.degenerate?(authority)
end
