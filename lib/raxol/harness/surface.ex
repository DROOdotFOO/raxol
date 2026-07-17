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
    * **`Raxol.Harness.UnreadDivider`** -- the pure attention-boundary
      policy behind the "N new since you looked" footer rule (see "The
      unread divider" section below).

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
  NOT enforced by that function itself.

  ### The honest-notice law (priority fit before repaint's truncation)

  `repaint/2`'s own pad/truncate is POSITION-BLIND (a tail-drop) -- and
  the one-shot stub notice is the LAST footer group, so a composed footer
  that overflows the row budget would silently eat exactly the honest
  refusal/degradation report the notice channel exists to carry (an
  integration finding: the overflow only manifests once sibling footer
  content stacks up). `footer_frame/1` therefore fits the list itself
  BEFORE the handoff (`fit_footer_groups/3`): display order preserved,
  discretionary groups yield first (preview, then divider, then the
  composer's tail, then an overlay's tail, then status -- each trimmed
  from its tail so a group's leading row survives a partial trim), and a
  notice is NEVER the row that silently drops -- at a 1-row budget the
  notice is the row that wins. Pinned by the "honest-notice law under
  footer overflow" describe in `diff_expand_surface_test.exs`. On resize, `resize/2` composes
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

  ## The unread divider (live-region honesty)

  `Raxol.Harness.UnreadDivider` decides, purely from caller-injected
  block-commit offsets (see that module's own moduledoc), whether a
  "N new since you looked" rule should render. This module owns two
  things that policy doesn't: WHEN to feed it an offset (`blur/1` and
  `focus/1`, the explicit mode-1004 seam; `handle_input/2` also feeds
  `UnreadDivider.input_activity/2` on every keystroke as the fallback
  return signal, and `move_focus/2` feeds `UnreadDivider.viewed/2` on
  every jump) and WHERE to render its output: `footer_lines/1` inserts
  `unread_divider_lines/1`'s single dim line between the status strip
  and the pending/live preview, styled through the same `ViewText` seam
  every other footer line uses. The divider is decided at return-time
  and rendered ONLY in the repaintable footer -- sealed history is never
  touched (enforced byte-for-byte by the integration suite's
  sealed-bytes-identical test, not merely asserted in prose), it is
  suppressed under an open overlay exactly like the pending preview, and
  it is absent in `:flat` mode (no footer, no live region, so `blur/1`/
  `focus/1` are safe no-ops there). It clears the instant `move_focus/2`
  reaches or passes the boundary block -- jumps skip the divider itself
  by construction, since `focused_index` ranges only over
  `projection.blocks`. `advance/2` reconciles the policy state against
  every projection rebuild, and the render read is itself reconciled
  (`UnreadDivider.divider/2`), so a shrunken rebuild can neither stick
  the span nor paint it past the live block count.

  DORMANT TODAY: nothing in the production input path calls `blur/1` --
  the terminal side can parse focus bytes but no driver enables mode
  1004 or routes them here (see `UnreadDivider`'s "mode-1004 seam"
  section for the full evidence trail). Until that unit lands, the
  divider never renders outside the test suites; the keystroke fallback
  only ever CLOSES an away state, never opens one.

  ## The DevTools debug highlight (display-only footer tint)

  `put_debug_highlight/2` paints a pale-blue BACKGROUND under every line
  of exactly one footer group (the same group keys `footer_frame/1`
  composes: status/lane/overlay/divider/preview/composer/notice, plus
  `:expansion`) -- the react-devtools bridge's hover/select payoff. It is
  display-only observer state: applied post-fit through
  `ViewText.highlight_bg/3` (row counts and the cursor park are untouched
  by construction), never on any seal path (sealed history hovers render
  the bridge's honest notice instead), cleared by `close_stream/1`, and a
  `nil` highlight is a zero-byte no-op so goldens can never see it. The
  tint itself is a palette ROLE (`Raxol.UI.Theming.Palette`'s
  `:debug_highlight_bg`, capability-tiered) -- no color literal in this
  module. See `put_debug_highlight/2`'s doc for the full law list.

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

  ## Full-screen diff expansion (footer maximization)

  `expand_focused_diff/1` hosts a `Raxol.Harness.DiffExpansion` scrollable
  window over the focused block's diff, by the same GROW-the-footer
  mechanism as the overlay picker above (`InlineAuthority.set_footer_rows/2`)
  -- never a centered modal over history, never the alternate screen. The
  difference from the overlay is the CLAIM shape: an overlay claims a
  small, fixed height (`OverlayPicker.height/1`); an expansion claims the
  LARGEST non-degenerate footer the current geometry can host
  (`max_overlay_rows/2`, the exact same helper, one source of truth --
  history still keeps its 2-row minimum). See `DiffExpansion`'s own
  moduledoc for the full mechanism ruling -- why this grows the footer
  instead of visiting the alternate screen (LC-P-NOALT, the seal oracle's
  unverifiable-vocabulary concern, the missing alt-screen compensation
  machinery) -- this section only covers the assembly-layer half of that
  decision.

  The `e` key (`Raxol.UI.Harness.Keymap`'s `:expand_diff`, a
  `:not_composing` bind, same guard class as fold/jump) expands the
  currently focused block when it is a `:diff` block. It rides the exact
  guard fold/jump already use -- suppressed while composing (plain typed
  text) and while an overlay OR expansion is already open (`context`'s
  `overlay_open?` flag is `model.overlay != nil or model.expansion != nil`
  -- see `handle_input/2`'s moduledoc) -- so `e` can never fire a second,
  nested expansion or steal a keystroke from an open overlay's filter
  query.

  ESC closes the expansion, not the running turn, for the identical
  reason ESC closes an open overlay: `Keymap`'s `:overlay` guard captures
  it as `:overlay_dismiss` whenever `context.overlay_open?` is true, which
  it is for an open expansion too. `dispatch_command/2`'s expansion clause
  for `:overlay_dismiss` precedes the overlay clause (load-bearing order,
  same class of ordering the overlay's own ESC-priority note documents),
  so an open expansion's ESC always closes the EXPANSION -- the two can
  never both be open at once (each refuses while the other is), so this
  is not actually an ambiguous case, just an explicit one. `q` is a second
  dismiss key, routed the same way through `route_passthrough/3`'s
  expansion clause (alongside `j`/`k`/arrow-key scrolling) -- `Enter`,
  other printable characters, and any other special key are inert while
  expanded, matching the overlay's own "only the keys the picker actually
  understands are wired" discipline. Dismissing restores the footer to
  `model.footer_rows` via `set_footer_rows/2`, which latches
  `needs_keyframe` -- the trailing `paint_footer/1` self-promotes to a
  full keyframe, the same byte-identical restore discipline
  `close_overlay/1` already relies on.

  Honest refusals (see `expand_focused_diff/1`'s doc for the full,
  ordered list): no footer to grow (`:flat` mode), no block focused, the
  focused block is not a `:diff` block, the geometry cannot host even the
  2-row minimum, or the focused block's content fails
  `BodyProvider`'s `:diff` schema. Every refusal is zero bytes and an
  unchanged model; the `e` keybind path (`apply_expand/1`) additionally
  surfaces each one as an honest, visibly-labeled one-frame footer notice
  through the existing `stub_notice` channel (precondition #6's stub
  mechanism), never a silent no-op.

  `resize/2` mirrors the overlay's force-close discipline for a geometry
  that can no longer host the expansion at all, but because the
  expansion's claim is "the maximum available," not a fixed height, a
  resize that STILL fits does not merely survive unchanged the way an
  open overlay does -- the claim is RE-DERIVED at the new geometry every
  time, the footer re-grown or re-shrunk to match, and
  `DiffExpansion.resize_view/3` re-renders the same diff content at the
  new width/window, clamping the scroll offset. See `resize/2`'s own doc
  for the exact sequencing.

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
  below as the frontier's `pending_input?` hold on the newest block; the
  seal pass (`paint_pending_blocks/1`) walks it via `commit_walk/5`, and
  the footer's pending preview (`pending_block/1`) shows the first block
  past the walk's own committed cursor (`painted_count`) -- the
  post-commit truth, which equals the pre-commit scan's `tail_start` on
  every successful frame and stays honest (block still visible) when a
  seal write is refused. One classifier decides where the frontier
  stops; the cursor records where it actually got to.

  The preview shows ONE block (two lines of it). Today the two never
  differ: the only frontier hold a shipped producer can create is the
  foldable window on the NEWEST block, so the unsealed suffix past the
  cursor is at most one block long. Two tests in
  `test/harness/surface_frontier_feed_test.exs` guard this together, and
  the split matters: the fixture-REPLAY pin only proves the bound holds
  over today's shipped corpus (it replays `.jsonl`, so it structurally
  cannot observe a runtime producer -- on its own it would pass
  vacuously). Its teeth come from the paired SYNTHETIC test, which builds
  the exact runtime hold the corpus lacks -- a mid-list awaiting-input
  `:approval` holding finalized blocks behind it -- and asserts the
  frontier genuinely stops there, so more than one block sits past the
  cursor. That is the multi-block hold the one-block preview cannot
  honor: the moment a producer wires such a hold into a real advance, the
  bound breaks and the preview under-reports, forcing the multi-block
  tail rendering decision (the live-lane / T13b unit's), never silently
  absorbed here.

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

  ## The pickers (command palette, jump, session, search)

  Four more `OverlayPicker` consumers ride the same footer-overlay
  substrate as the picker described above. Ctrl+P (`Keymap`'s
  `:open_palette`, an `:always` chord) opens the command palette from
  anywhere, including mid-compose -- a chord is never typed text, the same
  reasoning as Ctrl+E. `g` (`:open_jump_picker`), `s`
  (`:open_session_picker`), and `/` (`:open_search_picker`) are plain
  printable letters gated `:not_composing`, the same class as `z`/`j`/`k`:
  they only resolve in transcript-browse mode, never stealing a letter
  out of the composer's typed text. `open_search_picker/1`'s entries are
  labeled from `Block.search_text/1` -- a content-derived search corpus
  (kind, summary, AND body text), not just the summary header
  `open_jump_picker/1`'s labels use -- clamped per block (see that
  function's own doc) before `Raxol.Harness.Surface.ViewText.lines/3`
  ever truncates a rendered row to its display-width budget.

  The palette's entries are `Keymap.palette_binds/0` (the labeled subset
  of the bind table) plus two commands that exist only at THIS assembly
  layer, not in `Keymap.binds/0` -- "focus transcript" and "focus
  composer" (the very transition `focus_transcript/1`/`focus_composer/1`
  already exposes as direct API). Picking any palette entry dispatches
  through the exact same `dispatch_command/2` path a keypress takes --
  there is no second, parallel execution mechanism for a palette-picked
  command. All four pickers (palette, jump, session, search) opt into
  `Raxol.UI.Harness.OverlayPicker.fuzzy_filter/3` as their `filter_fn`
  (the `Raxol.UI.ListScorer` adapter), not the default substring filter --
  a fuzzy-ranked query is what a "type a few letters, find the entry"
  picker needs.

  Session-switch semantics (`s`, `switch_session/2`) are stated plainly:
  the abandoned session's sealed history stays byte-identical above --
  print-once, the substrate cannot rewrite it -- while its not-yet-painted
  PENDING blocks (the one-block foldable window) are DROPPED, never
  sealed late. Replay state (`events`/`revealed`/`projection`/
  `painted_count`/`fold_overrides`/`focused_index`/`status`) resets, the
  new session's events append below whatever is already sealed, and the
  composer draft plus authority/geometry survive the switch untouched.

  ## Projection panels (read-only footer overlays)

  Three more overlays ride the same hosted-overlay footer slot, but are
  `Raxol.UI.Harness.OverlayPanel` instances (never `OverlayPicker`) --
  summonable via the labeled `w`/`m`/`n` panel binds (worktracks/memory/
  plan; `Keymap`'s `:open_panel` command, discriminated by
  `payload.panel`), and therefore via the command palette too, same
  invocation-parity guarantee as every other labeled bind. Content is a
  read-model folded by `Raxol.Harness.PanelProjection` from the
  projection's retained *durable* `extract` meta events, recomputed both
  at summon (`open_panel/3`) and on every footer repaint while open
  (`refresh_panel_overlay/1`, called from `paint_footer/1`) -- a live
  projection, not a one-shot snapshot. Same refusal ladder as
  `open_overlay/3` (`:overlay_already_open`/`:no_footer`/
  `:insufficient_footer_capacity`), surfaced through the same
  `picker_refusal/2` notice path. Dismissal releases the claimed footer
  rows and discards only UI-local panel state (scroll offset); re-summoning
  folds the CURRENT retained events without ever touching the block
  projection itself.

  Merge caveat (see `PanelProjection`'s own moduledoc for the full
  statement): the panels build against the frozen meta-event contract
  shapes and a contract-shape fixture
  (`test/fixtures/harness/sessions/projection-panels.jsonl`); the
  per-class item shapes are ASSUMPTIONS pending verification against real
  agent-emitted `extract` events before this unit's PR merges.

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

  alias Raxol.Harness.DiffExpansion
  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.PanelProjection
  alias Raxol.Harness.Projection
  alias Raxol.Harness.RecencyPolicy
  alias Raxol.Harness.SealFrontier
  alias Raxol.Terminal.ScrollRegionManager
  alias Raxol.Harness.StatusStrip
  alias Raxol.Harness.Surface.ViewText
  alias Raxol.Harness.UnreadDivider
  alias Raxol.UI.Theming.Palette

  alias Raxol.UI.Components.Harness.{Block, BlockBody, Composer}
  alias Raxol.UI.Harness.{InputEvent, Keymap, OverlayPanel, OverlayPicker}

  alias Raxol.UI.Rendering.PaintAuthority.{
    FlatAuthority,
    InlineAuthority,
    ModeSelect,
    ViewportAuthority
  }

  @default_footer_rows 6
  @default_sessions_dir Path.join(["test", "fixtures", "harness", "sessions"])
  # Cap on session-picker ENTRIES (the entry-count axis) -- see
  # `open_session_picker/1`'s "Listing cap" doc section.
  @session_picker_cap 100
  # Cap on the per-label GRAPHEME COUNT of each block's search corpus (the
  # per-label length axis -- a DIFFERENT axis from `@session_picker_cap`'s
  # entry count). This is the canonical per-label bound for the search
  # picker: it is enforced at the source inside `Block.search_text/2`
  # (which never scans past it), so it also bounds `ListScorer`'s own
  # `@max_score_graphemes` (a 400-grapheme label is already under the
  # scorer's 1024 cap). See `open_search_picker/1`'s doc section.
  @search_label_cap 400
  @stub_interrupt_notice "» interrupt requested (stub — no agent lane in fixture mode)"
  @stub_approval_notice "» approval answer (stub — no agent lane in fixture mode)"

  # The footer-group vocabulary `put_debug_highlight/2` accepts -- exactly
  # the group keys `footer_frame/1` composes (both clauses), one highlight
  # at a time, last-writer-wins.
  @debug_highlight_groups [
    :status,
    :lane,
    :overlay,
    :divider,
    :preview,
    :composer,
    :notice,
    :expansion
  ]

  @type mode :: :inline_log | :tmux_conservative | :flat | :full_viewport

  @typedoc """
  A frozen seal record — the owned virtual-scrollback element for
  `:full_viewport` mode (see `paint_viewport/1`). Each record captures a
  committed transcript item at SEAL time so a normal repaint re-renders it
  BYTE-IDENTICALLY (logical immutability — a `:block`'s prominence grade is
  frozen here, never re-graded as later turns arrive), while a resize
  reflows it (the record re-renders at the new width). The three kinds
  mirror the three inline seal paths:

    * `{:block, block, prominence}` — a projection block, `seal_block/2`.
    * `{:marker, text}` — a loss/notice marker, `seal_marker/2`.
    * `{:echo, text}` — a live submit prompt echo, `seal_prompt_echo/2`.
  """
  @type seal_record ::
          {:block, Block.t(), RecencyPolicy.prominence()}
          | {:marker, String.t()}
          | {:echo, String.t()}

  @typedoc """
  The `:full_viewport` scroll window's bottom edge: `:tail` (pinned to the
  newest line, the default) or a 1-based absolute index into the frozen
  transcript naming the line shown at the window's bottom. Held stable
  under bottom-append so new content while scrolled-back never yanks the
  view (the scroll-anchor rule); clamped into range every paint so a
  drop-from-front (compaction) degrades gracefully rather than crashing.
  """
  @type scroll_anchor :: :tail | pos_integer()

  @typedoc """
  A footer group key the DevTools debug highlight can target -- see
  `put_debug_highlight/2`.
  """
  @type debug_highlight_group ::
          :status
          | :lane
          | :overlay
          | :divider
          | :preview
          | :composer
          | :notice
          | :expansion
  @type t :: %{
          mode: mode(),
          authority:
            InlineAuthority.t() | FlatAuthority.t() | ViewportAuthority.t(),
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
          expansion: DiffExpansion.t() | nil,
          editor_session: module() | (String.t(), keyword() -> term()) | nil,
          editor_opts: keyword(),
          unread: UnreadDivider.t(),
          sessions_dir: Path.t(),
          command_sink: (map() -> term()) | nil,
          lane_notice: String.t() | [String.t()] | nil,
          pending_submit: %{text: String.t()} | nil,
          stream_open?: boolean(),
          spinner_frame: non_neg_integer(),
          debug_highlight: debug_highlight_group() | nil,
          debug_highlight_bg: ViewText.bg(),
          sigil: String.t(),
          reply_sigil: String.t(),
          sealed_any?: boolean(),
          greeting_rows: [pos_integer()] | nil,
          # `:full_viewport` only (empty/`nil` in the inline/flat family):
          # the owned virtual scrollback (frozen seal records, oldest
          # first) and the scroll window's bottom edge.
          transcript_records: [seal_record()],
          scroll_anchor: scroll_anchor(),
          greeting?: boolean()
        }

  @typedoc """
  The hosted overlay's state: `mod` names which module owns `picker` (
  `Raxol.UI.Harness.OverlayPicker` for the filterable pickers,
  `Raxol.UI.Harness.OverlayPanel` for the read-only projection panels --
  see `overlay_mod/1`), `picker` holds THAT module's own state (a picker
  or a panel, despite the field name predating panels), and `on_pick` is
  the caller-supplied (or default) commit callback, invoked as
  `on_pick.(model, item)` AFTER `close_overlay/1` has already restored the
  footer to its base row count -- see `handle_input/2`'s `:passthrough`
  routing. A hosted `OverlayPanel` never produces a pick (see
  `open_panel/3`), so its `on_pick` is shape-compatible filler only.

  `mod` is the discriminator: `OverlayPicker` => `picker`/`on_pick` are
  live; `OverlayPanel` => `on_pick` is inert filler and `folded_at` (the
  memoization token, present only for panels) is live. See
  `refresh_panel_overlay/1`.
  """
  @type overlay :: %{
          :mod => module(),
          :picker => OverlayPicker.t() | OverlayPanel.t(),
          :on_pick => (t(), term() -> t()),
          optional(:folded_at) => non_neg_integer()
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
    * `:sessions_dir` (default `#{inspect(@default_sessions_dir)}`, the
      same source `examples/harness_fixture_demo.exs` reads) -- the
      directory `list_fixture_sessions/1` (the session picker, `s`) lists
      `.jsonl` fixtures from.
    * `:command_sink` (default `nil`) -- a 1-arity fun that makes
      `:interrupt`/`:steer` LIVE instead of the fixture-mode stubs (see
      the moduledoc's "Command bifurcation" section). `nil` keeps
      today's honest stubs untouched; a fun receives
      `%{type: :interrupt, payload: %{}}` or `%{type: :steer, payload:
      %{text: composer_text}}` -- see `Raxol.Harness.SessionLane` for the
      seam a live implementation dispatches through on the other side.
    * `:stream_open` (default `false`) -- declares that more events may
      still arrive beyond whatever `append_events/2` has delivered so
      far, so the reveal is never treated as finished merely for being
      momentarily caught up (see `frontier_entries/1`'s fold-before-seal
      note). A live embedder sets this and calls `close_stream/1` when
      the session truly ends; fixture replay keeps the default.
    * `:pin` (default `:immediate`) -- forwarded to
      `InlineAuthority.new/5`. `:immediate` pins the footer at the
      screen bottom from the first byte (today's model, byte-identical
      -- the default keeps every byte-golden suite and fixture valid
      unchanged). `:adaptive` starts the footer FLOATING directly below
      the last content row (the top of the screen on an empty session --
      no first-load void) and pins one-way when content reaches the
      pinned position; see `InlineAuthority`'s "The adaptive pin"
      moduledoc section. Ignored in `:flat` mode (no footer).
    * `:boot` (default `:top`) -- where the surface starts on screen.
      `:top` is today's behavior exactly (callers push the screen blank
      first via `startup_push_up/2`, the footer floats at the top).
      `{:guest, {row, col}}` is GUEST-BOOT: `{row, col}` is the
      DSR-probed cursor position where the user's shell stopped
      (`Raxol.Terminal.InlineDriver.probe_cursor/2` is the prober; the
      probe writes bytes to the device, so it is strictly the caller's
      opt-in), forwarded to `InlineAuthority.new/5` as `:boot_cursor` --
      the surface starts exactly there: floating under the prompt
      mid-screen, or bottom-anchored from the first frame when the
      prompt sits at/near the screen bottom (the scroll-entry path;
      shell history scrolls up honestly, never repainted). Requires
      `pin: :adaptive` (`InlineAuthority.new/5` raises otherwise).
      Ignored in `:flat` mode -- flat output already flows from
      wherever the cursor is (flat IS guest boot by nature). Any other
      value raises `ArgumentError` -- an unrecognized boot must never
      silently become `:top`.
    * `:entry` (default `:fill_down`) -- forwarded to
      `InlineAuthority.new/5`: how a pinned seal enters history.
      `:scroll_entry` is chat semantics (content enters at the region
      bottom, right above the footer, and scrolls upward -- V's
      bottom-anchor ruling); the guest bottom-pin boot sets it by
      itself, so this option matters for the pinned-from-boot paths
      (the demos' probe-failed `:top` fallback). `:fill_down` keeps
      every byte-golden world untouched. Ignored in `:flat` mode.

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

    authority =
      build_authority(
        mode,
        device,
        width,
        rows,
        footer_rows,
        caps,
        Keyword.get(opts, :pin, :immediate),
        validate_boot!(Keyword.get(opts, :boot, :top)),
        Keyword.get(opts, :guest_placement, :bottom_pin),
        Keyword.get(opts, :entry, :fill_down)
      )

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
      expansion: nil,
      editor_session: Keyword.get(opts, :editor_session),
      editor_opts: Keyword.get(opts, :editor_opts, []),
      unread: UnreadDivider.new(),
      sessions_dir: Keyword.get(opts, :sessions_dir, @default_sessions_dir),
      command_sink: Keyword.get(opts, :command_sink),
      lane_notice: nil,
      pending_submit: nil,
      stream_open?: Keyword.get(opts, :stream_open, false),
      # Frame counter for the running-tool margin spinner -- advanced by
      # the EXISTING clocks only (`tick/2` and each `advance/2` reveal;
      # never a timer of this module's own). See `preview_margin_lines/2`.
      spinner_frame: 0,
      debug_highlight: nil,
      # Role token, resolved ONCE per session at the palette layer ("roles,
      # never colors") -- the component only ever names the role; the
      # palette decides what the tint IS per capability tier, including
      # the category-preserving 256/ANSI16 downgrades.
      debug_highlight_bg: Palette.debug_highlight_bg_for(caps),
      # The dialogue sigils (the mirrored chevron pair, V's amendment to
      # the speaker-separation ruling): decided ONCE from the capability
      # record -- `unicode: :none` is the only tier that can't render
      # U+276F/U+276E, so they fall back to plain ">" / "<". `sigil`
      # fronts the composer's live prompt row and every user echo;
      # `reply_sigil` fronts assistant prose. See `chevron_lines/2` and
      # `echo_lines/4`.
      sigil: prompt_sigil(caps),
      reply_sigil: reply_sigil(caps),
      # Whether ANY line has ever been sealed into history -- drives the
      # one-blank-row-between-sealed-blocks rule (see `seal_block/2`).
      # Deliberately NOT reset by `switch_session/2`: sealed history
      # stays on screen across a switch, so the next block still needs
      # its separating blank.
      sealed_any?: false,
      # The boot greeting's on-screen rows (nil = none painted / already
      # erased) -- see `maybe_paint_greeting/2` and `clear_greeting/1`.
      # `:full_viewport` never uses this transient (its greeting is a
      # centered line the repaint clears on first content, not an
      # authority-painted transient).
      greeting_rows: nil,
      # `:full_viewport`'s owned virtual scrollback: frozen seal records
      # (oldest first), windowed bottom-anchored by `paint_viewport/1`.
      # Stays `[]` in every inline/flat tier (they print history into the
      # terminal, never hold it).
      transcript_records: [],
      # The scroll window's bottom edge; `:tail` follows the newest line.
      scroll_anchor: :tail,
      # Whether the boot greeting is enabled. In `:full_viewport` this
      # drives the centered "welcome back, operator" line the repaint
      # shows while the transcript is empty (cleared on first content);
      # the inline family instead paints it as a transient via
      # `maybe_paint_greeting/2`.
      greeting?: Keyword.get(opts, :greeting, false)
    }

    model
    |> apply_mode_notice(mode_notice_text(mode_reason, env))
    |> paint_footer()
    |> maybe_paint_greeting(Keyword.get(opts, :greeting, false))
  end

  # -- the boot greeting (V's ruling with mock: an in-flow intro line) -----
  #
  # One dim `welcome back, operator` line rendered LIKE TRANSCRIPT
  # CONTENT -- margined (the same 1-column left margin every sealed line
  # carries), low prominence (§4.3 dim = supporting), sitting in the
  # transcript position directly above the chevron:
  #
  #      welcome back, operator
  #
  #     ❯
  #
  # (one blank row between it and the footer when the unclaimed span has
  # the room; flush against it when bottom-anchored to a single row).
  # Still an EPHEMERAL region element, not a sealed block -- painted
  # after the construction frame, erased by `clear_greeting/1`
  # immediately before the FIRST seal's bytes (same frame), never part
  # of print-once history. Kept as a transient (rather than an in-flow
  # sealed block) deliberately: sealing it would make it permanent
  # history and scroll it away -- the mock's intro sits at the input,
  # then yields to real content. Opt-in (`greeting: true`, the demos) so
  # byte-golden embedders are untouched; flat mode has no positioning
  # and never paints it.
  @greeting_text "welcome back, operator"

  defp maybe_paint_greeting(model, false), do: model
  defp maybe_paint_greeting(%{mode: :flat} = model, _on), do: model

  # `:full_viewport` has no transient authority paint -- its greeting is a
  # centered line `paint_viewport/1` renders while the transcript is empty
  # (gated on `model.greeting?`, set at construction), cleared the instant
  # the first content lands. Nothing to paint here.
  defp maybe_paint_greeting(%{mode: :full_viewport} = model, _on), do: model

  defp maybe_paint_greeting(model, true) do
    case InlineAuthority.unclaimed_span(model.authority) do
      :none ->
        model

      {:ok, {from, to}} ->
        # Bottom of the unclaimed span, one blank row above the footer
        # when there is room -- the transcript position at a
        # bottom-anchored layout.
        row = max(to - 1, from)

        [styled] =
          ViewText.lines(
            %{type: :text, content: @greeting_text, style: %{dim: true}},
            content_width(model),
            :styled
          )

        # Column 2 = after the 1-column left margin, exactly where every
        # margined transcript line starts.
        authority =
          InlineAuthority.paint_transient(model.authority, row, 2, styled)

        %{model | authority: authority, greeting_rows: [row]}
    end
  end

  # The greeting's exit (the erase half of the ephemeral contract):
  # targeted EL on its rows, called at the head of every seal path so
  # the erase bytes always PRECEDE the first sealed content's bytes in
  # the same frame. Idempotent -- nil rows is a no-op.
  defp clear_greeting(%{greeting_rows: nil} = model), do: model
  defp clear_greeting(%{mode: :flat} = model), do: %{model | greeting_rows: nil}

  defp clear_greeting(model) do
    authority =
      InlineAuthority.erase_transient(model.authority, model.greeting_rows)

    %{model | authority: authority, greeting_rows: nil}
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
        {base_mode, reason} =
          ModeSelect.select_with_reason(caps, env,
            rows: rows,
            footer_rows: footer_rows
          )

        apply_surface_mode(
          Keyword.get(opts, :surface_mode, :inline_hybrid),
          base_mode,
          reason
        )
    end
  end

  # The `:surface_mode` axis (paint FAMILY) resolved on top of the
  # degradation ladder (paint TIER): `:full_viewport` is honored only when
  # the ladder did NOT floor to `:flat`. A headless (`TERM=dumb`/pipe/CI)
  # or degenerate-geometry session still degrades honestly to `:flat` --
  # the alternate screen belongs to neither a pipe nor a footerless
  # terminal, so the request yields to the same floor an inline session
  # would hit. `:inline_hybrid` (the default) keeps whatever tier the
  # ladder picked, unchanged: every byte-golden embedder is untouched.
  defp apply_surface_mode(:full_viewport, base_mode, reason)
       when base_mode != :flat,
       do: {:full_viewport, reason}

  defp apply_surface_mode(_surface_mode, base_mode, reason),
    do: {base_mode, reason}

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
  defp apply_mode_notice(%{mode: :flat} = model, text),
    do: seal_flat_notice(model, text)

  defp apply_mode_notice(model, text), do: %{model | stub_notice: text}

  # Seals one honest, plain-rendered history line through the same
  # `FlatAuthority.seal/2` path every flat-mode notice uses (this
  # function's own `:flat` clause above, and `picker_refusal/2`'s
  # `:no_footer` case below) -- one source of truth for "how flat mode
  # writes an honest one-line notice", never a re-derived copy.
  defp seal_flat_notice(model, text) do
    model = clear_greeting(model)
    lines = marker_lines(model, text, :plain)
    iodata = Enum.map(lines, &(&1 <> "\n"))

    %{
      model
      | authority: FlatAuthority.seal(model.authority, iodata),
        sealed_any?: true
    }
  end

  # `:boot` shape gate (see `new/2`'s option doc): an unrecognized boot
  # value must never silently become `:top` -- raise at the seam instead.
  defp validate_boot!(:top), do: :top

  defp validate_boot!({:guest, {row, col}} = boot)
       when is_integer(row) and row >= 1 and is_integer(col) and col >= 1,
       do: boot

  defp validate_boot!(other) do
    raise ArgumentError,
          "Surface.new/2's :boot must be :top or {:guest, {row, col}} " <>
            "(1-based, the DSR-probed cursor position); got #{inspect(other)}"
  end

  defp build_authority(
         :flat,
         device,
         width,
         rows,
         _footer_rows,
         _caps,
         _pin,
         _boot,
         _guest_placement,
         _entry
       ),
       do: FlatAuthority.new(device, width, rows)

  # `:full_viewport` claims the whole alternate screen and repaints every
  # frame -- no footer pin, no scroll region, no guest-boot cursor, so the
  # inline positioning options (`pin`/`boot`/`entry`/`guest_placement`)
  # simply do not engage (they are the inline substrate's vocabulary).
  # Entering the alternate screen happens at construction, inside
  # `ViewportAuthority.new/3`.
  defp build_authority(
         :full_viewport,
         device,
         width,
         rows,
         _footer_rows,
         _caps,
         _pin,
         _boot,
         _guest_placement,
         _entry
       ),
       do: ViewportAuthority.new(device, width, rows)

  defp build_authority(
         _mode,
         device,
         width,
         rows,
         footer_rows,
         caps,
         pin,
         boot,
         guest_placement,
         entry
       ),
       do:
         InlineAuthority.new(device, width, rows, footer_rows,
           capabilities: caps,
           pin: pin,
           entry: entry,
           boot_cursor: boot_cursor(boot),
           # :bottom_pin default (V ruling: input at the screen bottom
           # from frame one); :float stays reachable for embedders that
           # want the legacy shell-join placement.
           guest_placement: guest_placement
         )

  defp boot_cursor(:top), do: nil
  defp boot_cursor({:guest, pos}), do: pos

  defp events_from(%Session{envelopes: envelopes}),
    do: Enum.map(envelopes, & &1.body)

  defp events_from(events) when is_list(events), do: events

  # -- doctrine layout: margins + the chevron sigil ------------------------
  #
  # V's charged-minimum ruling (harness-visual-doctrine §1.2/§4.2): all
  # sealed-history and footer content sits inside a 1-column margin on
  # both sides; the dialogue chevrons are the ONLY entities that enter
  # that margin -- the OUTER CONTOUR is where the speakers are marked
  # (speaker-separation ruling as V-amended 2026-07-17): the composer's
  # live prompt row (`❯`, the anchor of an idle frame), its sealed twins
  # -- the user-echo first line of an expanded user `:message` block and
  # the live submit echo (`submit_accepted/1`) -- and the mirrored reply
  # sigil (`❮`) fronting expanded assistant `:message` blocks. All read
  # their glyphs from `model.sigil`/`model.reply_sigil`, decided once
  # from the capability record, so echo, prompt, and reply can never
  # drift or mix degradation tiers.
  # Implemented here, at the single seam where lines meet the paint
  # authorities, never as per-component string prefixes. Two documented
  # exemptions: the overlay picker and the diff expansion are FRAMED
  # transient claims pre-rendered at full width by their own modules --
  # margining them here would truncate their right bezels; bringing them
  # inside the margin is their own follow-up, not a string-prefix hack at
  # this seam.

  # Left margin (1 col) + right margin (1 col) around margined content.
  @margin " "
  @margin_cols 2
  # The chevron prefix is "❯ " / "> " -- 2 cells -- so margined content
  # and the composer's first draft column align at column 2 (0-based).
  @sigil_cols 2

  # -- the full-viewport frame inset (V's 2026-07-18 margin ruling) --------
  #
  # In `:full_viewport` the whole surface is framed one cell in: nothing
  # touches the very screen edge on the left, one blank row hugs the
  # bottom, and -- crucially -- the OUTER-CONTOUR markers (dialogue
  # chevrons, the composer chevron, the running-tool spinner cell) leave
  # column 0 and JOIN the machinery margin column, so every marker aligns
  # at ONE framed left column (col 1, 0-based) and every content column
  # aligns one indent past it. Machinery already lived at col 1 (the
  # `@margin` cell), so it does not move; the inset unifies the dialogue
  # sigils onto it. Content width shrinks by the inset (frozen records
  # reflow at the narrower width via the existing resize path).
  #
  # The inset is `:full_viewport`-only and floors to 0 for any other mode
  # AND for a degenerate geometry too narrow/short to afford it -- so
  # `inset_prefix/2` is a byte-identity no-op in every inline/flat frame
  # (the frozen inline goldens never shift). A `:full_viewport` session
  # that survives the degradation ladder always affords it; the floor is
  # defence in depth.
  @fv_frame_inset 1

  defp frame_inset(%{mode: :full_viewport, width: w, rows: r})
       when w - @margin_cols - @fv_frame_inset >= 1 and r - @fv_frame_inset >= 1,
       do: @fv_frame_inset

  defp frame_inset(_model), do: 0

  # Prepend the frame inset to an OUTER-CONTOUR line, shifting its marker
  # from column 0 into the framed marker column. A no-op (byte-identical)
  # whenever the inset is 0 -- inline/flat modes and narrow-floored
  # `:full_viewport` -- and blank-guarded so an empty row stays empty (no
  # phantom whitespace, same rule as `margin_line/1`).
  defp inset_prefix(line, model), do: prepend_cols(line, frame_inset(model))

  defp prepend_cols(line, 0), do: line
  defp prepend_cols("", _n), do: ""
  defp prepend_cols(line, n), do: String.duplicate(@margin, n) <> line

  # The width budget for margined content -- the full width minus both
  # margin columns and (in `:full_viewport`) the extra left frame inset.
  # In inline/flat modes `frame_inset/1` is 0, so this is byte-identical
  # to the pre-frame `width - @margin_cols`.
  defp content_width(model),
    do: max(model.width - @margin_cols - frame_inset(model), 0)

  # A blank line stays blank -- a margin is layout, not trailing/leading
  # whitespace injected into empty rows.
  defp margin_line(""), do: ""
  defp margin_line(line), do: @margin <> line

  defp margin_lines(lines), do: Enum.map(lines, &margin_line/1)

  # `unicode: :none` is the one capability tier that can't render U+276F/
  # U+276E; every other tier (and an absent record -- the probe-off
  # conservative default already renders em dashes and box glyphs
  # elsewhere) gets the real chevrons. Width-honesty: all four sigils
  # measure exactly one display column (pinned by test). The pair
  # degrades TOGETHER -- a tier can never show a real `❯` opposite a
  # fallback `<`, which would break the mirrored-pair speaker grammar.
  defp prompt_sigil(%{unicode: :none}), do: ">"
  defp prompt_sigil(_caps), do: "❯"

  defp reply_sigil(%{unicode: :none}), do: "<"
  defp reply_sigil(_caps), do: "❮"

  # The chevron is the one H-K anchor of an idle frame: bold (structure
  # channel, doctrine §4.3), styled through the SAME ViewText SGR path
  # every other styled line uses -- never a hand-rolled escape.
  defp styled_sigil(model) do
    [line] =
      ViewText.lines(
        %{type: :text, content: model.sigil, style: %{bold: true}},
        @sigil_cols,
        :styled
      )

    line
  end

  @doc """
  Startup discipline: push any existing dirty screen
  content into scrollback via plain newlines, NEVER `\\e[2J` (which would
  wipe native scrollback on wezterm/kitty). Callers write this
  BEFORE the substrate's scroll region is established (i.e. before
  `new/2`), since `InlineAuthority.new/5` only sets the DECSTBM split --
  it never clears or pushes anything on its own.

  This is the `:top` boot's companion only: a GUEST-BOOT caller
  (`boot: {:guest, {row, col}}`, see `new/2`) must NOT call this --
  guest boot starts exactly where the shell's cursor is, and pushing
  the screen up first would move that cursor out from under the probed
  position.
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

  ## Options

    * `:resize` -- `{width, rows}`, the atomic combined-frame form for
      drivers that batch a geometry change with the same advance. When
      given, the resize is ADOPTED (dims + DECSTBM re-set, via the same
      `adopt_resize/3` path `resize/2` itself uses, minus that function's
      own immediate keyframe) BEFORE anything else in this call --
      specifically, before any block seals this frame. `resize/2` remains
      the standalone entry point; calling `resize/2` then `advance/2` is
      equally correct. The `:resize` option exists only for drivers that
      would otherwise have to sequence two separate calls for what is, to
      the terminal, one frame.

  ## FRAME-ORDER LAW

  A resize arriving in the SAME frame as an advance MUST be adopted
  before any seal in that advance: a block sealed at a stale width hard-
  wraps over-wide rows, and that wrap is permanent corruption once the
  row scrolls into native scrollback (this process can never rewrite it).
  This is why the `:resize` option is threaded through
  `adopt_frame_resize/2` first, unconditionally, ahead of `do_advance/2`.

  The footer row COUNT in this substrate is geometry-fixed (a function of
  `rows`/`footer_rows` only, never of post-seal state) -- so the
  reference design's "size the footer to the post-seal state" step is
  satisfied by construction, with nothing further to do here. The footer
  REPAINT itself still runs AFTER the seal (see `seal_frame/3`): the
  trailing `paint_footer/1` self-promotes to a full keyframe via
  `InlineAuthority`'s own `needs_keyframe` latch (set by `adopt_resize/3`
  whenever geometry or width changed), so the footer always ends up
  correct at the newly-adopted geometry without this module needing a
  second, explicit keyframe call here.
  """
  @spec advance(t(), integer() | nil, keyword()) :: {t(), :ok | :done}
  def advance(model, now \\ nil, opts \\ [])

  def advance(model, now, opts) do
    model
    |> adopt_frame_resize(Keyword.get(opts, :resize))
    |> do_advance(now)
  end

  defp adopt_frame_resize(model, nil), do: model

  defp adopt_frame_resize(model, {width, rows}),
    do: adopt_resize(model, width, rows)

  # Done-ness is stated exactly once, in `done?/1` -- this entry check
  # and the post-frame check below both consult it, so "everything
  # revealed and everything sealed" can never mean two different things.
  defp do_advance(model, now) do
    if done?(model), do: {model, :done}, else: run_advance(model, now)
  end

  defp run_advance(model, now) do
    model = heal_sync(model)
    revealed = min(model.revealed + 1, length(model.events))
    events_so_far = Enum.take(model.events, revealed)

    projection =
      Projection.project(events_so_far, fold_defaults: model.fold_defaults)

    model =
      %{model | revealed: revealed, projection: projection}
      # The running-tool margin spinner rides the EXISTING clocks:
      # every reveal advances one frame (tick/2 is the other clock).
      |> Map.update(:spinner_frame, 1, &(&1 + 1))
      # Pure model-state reconciliation (no bytes) -- runs before the
      # seal frame so the divider bookkeeping is settled ahead of any
      # paint, and stays OUTSIDE the sync bracket seal_frame may open.
      |> reconcile_unread()
      |> seal_frame(events_so_far, now)

    {model, if(done?(model), do: :done, else: :ok)}
  end

  # A frame that seals at least one block AND repaints the footer
  # presents atomically: seal + status + footer run between
  # InlineAuthority.sync_open/1 and sync_close/1 -- one DEC 2026
  # synchronized-update bracket, gated on the capability record. The
  # bracket condition is the pre-seal scan's will_commit -- it exactly
  # predicts "this frame seals >= 1 block" except when the first emit
  # fails, in which case an empty bracket is emitted (harmless: a sync
  # frame with no visible change; the balanced-bracket case in
  # test/harness/surface_seal_pipeline_test.exs covers the failure path).
  # A PERSISTENTLY refusing (alive) device therefore emits one empty
  # open/close pair per retry frame -- a few bytes of decoration per
  # frame, deliberately not special-cased: the same frames emit
  # [:raxol, :harness, :seal, :write_failed] telemetry per refused
  # write, so the condition is observable from the first frame and the
  # operator/driver owns the decision to stop advancing.
  # Frames that seal nothing (early reveals, tick, handle_input) never
  # open a bracket -- but every frame entry point calls heal_sync/1
  # first, so a close the device refused in an EARLIER frame (the
  # dangling-open wedge) is re-attempted at the first opportunity of any
  # kind. :flat has no footer and no cursor vocabulary -- never
  # bracketed.
  #
  # If run_seal_frame/3 raises mid-bracket (a logic bug -- device
  # failures are tuples, not raises, on this path), the rescue below
  # makes one best-effort close attempt before re-raising, so a crashing
  # frame does not also leave the terminal synchronized. The authority
  # state update is lost with the crash either way; the byte is what
  # matters to the terminal.
  defp seal_frame(%{mode: :flat} = model, events_so_far, now) do
    run_seal_frame(model, events_so_far, now)
  end

  # `:full_viewport` owns its OWN atomicity: every frame is one full
  # `ViewportAuthority.repaint/3` already wrapped in a DEC 2026 bracket,
  # so there is no per-block inline sync bracket to open here (and the
  # inline `sync_open/1` would not even match a `ViewportAuthority`).
  defp seal_frame(%{mode: :full_viewport} = model, events_so_far, now) do
    run_seal_frame(model, events_so_far, now)
  end

  defp seal_frame(model, events_so_far, now) do
    if frontier_scan(model).will_commit do
      opened = update_authority(model, &InlineAuthority.sync_open/1)

      try do
        opened
        |> run_seal_frame(events_so_far, now)
        |> update_authority(&InlineAuthority.sync_close/1)
      rescue
        e ->
          _ = InlineAuthority.sync_close(opened.authority)
          reraise e, __STACKTRACE__
      end
    else
      run_seal_frame(model, events_so_far, now)
    end
  end

  defp run_seal_frame(model, events_so_far, now) do
    model
    |> paint_pending_blocks()
    |> update_status(events_so_far, now)
    |> paint_footer()
  end

  # Re-attempts a sync close the device refused in an earlier frame (see
  # InlineAuthority.sync_close/1's latch contract) -- a byte-free no-op
  # when nothing is owed, so every frame entry point (do_advance, tick,
  # handle_input, resize) calls it unconditionally: a dangling ?2026h
  # heals at the FIRST frame after the device accepts a byte again,
  # never later.
  defp heal_sync(%{mode: :flat} = model), do: model

  # `:full_viewport` has no dangling inline sync latch to heal -- its sync
  # bracket opens and closes within a single `ViewportAuthority.repaint/3`,
  # never spanning frames.
  defp heal_sync(%{mode: :full_viewport} = model), do: model

  defp heal_sync(model),
    do: update_authority(model, &InlineAuthority.sync_close/1)

  defp update_authority(model, fun),
    do: %{model | authority: fun.(model.authority)}

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
    |> heal_sync()
    |> put_in([:status, :now], now)
    # Same clock the elapsed ticker rides -- the running-tool margin
    # spinner advances here and on each `advance/2` reveal, NEVER via a
    # timer of this module's own (no wall-clock in the default suite).
    |> Map.update(:spinner_frame, 1, &(&1 + 1))
    |> paint_footer()
  end

  # -- live-session seam ----------------------------------------------------

  @doc """
  Appends `events` (event-shaped maps -- the same fixture wire shape
  `advance/2` already consumes) to `model.events`. This is the live-session
  seam: a `Raxol.Harness.SessionLane` subscriber normalizes each incoming
  live event through `Raxol.Harness.EventBoundary.normalize/1` upstream of
  this call, then hands the result here. Appended events are revealed with
  `advance/2` exactly like fixture events -- there is no separate reveal
  path for "live" vs. "fixture" once an event has landed in `model.events`.

  `O(n)` per call (`model.events ++ events`), matching
  `Raxol.Harness.Projection.project/2`'s own per-`advance/2` `O(n)` rebuild
  -- this call changes the constant factor of a growing session's upkeep,
  not its complexity class.

  Raises `ArgumentError` on a non-map element: the boundary normalizer is
  expected to run upstream of this call, so a non-map element reaching here
  is a caller bug, not a value this function silently tolerates.
  """
  @spec append_events(t(), [map()]) :: t()
  def append_events(model, events) when is_list(events) do
    Enum.each(events, fn
      event when is_map(event) ->
        :ok

      other ->
        raise ArgumentError,
              "append_events/2 expects event-shaped maps, got: #{inspect(other)}"
    end)

    %{model | events: model.events ++ events}
  end

  @doc """
  Turn-granularity compaction of the live event list: drops the source
  events of RETIRED turns -- turns whose bracket has folded and whose
  blocks are all already sealed into print-once history -- from
  `model.events`, so an unbounded live session stops paying O(n^2)
  re-projection over turns that can never render another byte.

  ## Why this is byte-safe (and how it proves it)

  Turns project independently (`Projection` buckets by `turn_id`; the
  tool_use/tool_result merge is intra-turn), recency grading is
  `turns_behind`-invariant under dropping older WHOLE turns (both the
  current position and every surviving turn's position shift by the same
  amount), and `Raxol.Harness.Projection.Recovery.filter_ids/1` exempts
  the first surviving id from its forward-gap check (a call "may
  legitimately start mid-stream"), so a dropped prefix never flips the
  `damaged` mark. But this function does not merely TRUST that analysis:
  it re-projects the compacted prefix and commits ONLY when the surviving
  projection is `==`-identical (blocks, tail, damaged mark) to the old
  projection minus the dropped turns' sealed blocks. Any divergence --
  a cross-turn evidence ref into the dropped region, a bookkeeping error,
  a projection change this function's analysis missed -- aborts the whole
  compaction and returns the model UNCHANGED. Fail-safe: the worst
  outcome of a bug here is the old growth characteristic, never a
  corrupted transcript.

  ## What is retired

  A turn is retirable when every one of these holds (each individually
  fail-safe -- when in doubt, keep the events):

    * it carries a turn bracket (`turn_completed` / `turn_canceled`)
      among the revealed events;
    * it is not the NEWEST bracket-carrying turn (the status strip's
      `turn_completed`/`cost` derivation reads the LAST bracket, so the
      most recent completed turn's events always stay);
    * every sealed block consumed only retired events, and no surviving
      block (sealed or not) references a dropped event id;
    * no surviving event's payload cites a dropped id in its `refs`
      (evidence refs are same-turn by `Raxol.Agent.DoneGate`'s own
      contract, but a forged or future cross-turn ref must veto the drop
      rather than dangle).

  Only a contiguous PREFIX of `model.events` is ever dropped, and only
  within the revealed range: the walk stops at the first event that is
  not a `:loop`-family event of a retired turn (meta-family events,
  id-less events, and the live turn all act as hard stops), which
  preserves the interior id/order structure of everything that survives.

  ## Bookkeeping shifted on commit

  `revealed` (an event count from the head) drops by the dropped-event
  count; `painted_count`, `fold_overrides` keys, `focused_index`, and the
  `UnreadDivider` boundary/span (all positions in `projection.blocks`)
  shift down by the dropped-block count. Retention after a compacting
  bracket is O(size of the newest turns), not O(session) -- the growth
  fix the live-session driver's ledger discloses.

  Gated behind the multi-turn live/fixture byte-parity guard in
  `test/harness/live_session_driver_compaction_test.exs` (the emulator
  oracle asserts compacted-live and uncompacted-fixture sealed history
  are byte-identical).
  """
  @spec compact_sealed_turns(t()) :: t()
  def compact_sealed_turns(model) do
    with false <- model.projection.damaged,
         {k, dropped_ids} when k > 0 <- droppable_prefix(model),
         :ok <- refs_clear?(model, k, dropped_ids),
         {:ok, dropped_blocks} <- dropped_block_prefix(model, dropped_ids),
         {:ok, projection} <- reproject_survivors(model, k, dropped_blocks) do
      commit_compaction(model, k, dropped_blocks, projection)
    else
      _keep -> model
    end
  end

  # The longest droppable prefix: `:loop` events with integer ids whose
  # turn_id is retired. Anything else -- meta family, an id-less event, a
  # live/kept turn -- stops the walk (fail-safe: prefix-only, so survivor
  # order and interior gap structure are untouched).
  defp droppable_prefix(model) do
    revealed_events = Enum.take(model.events, model.revealed)
    retired = retired_turn_ids(revealed_events)

    revealed_events
    |> Enum.reduce_while({0, MapSet.new()}, fn event, {k, ids} ->
      id = Map.get(event, :id)

      if Map.get(event, :family) == :loop and is_integer(id) and
           MapSet.member?(retired, Map.get(event, :turn_id)) do
        {:cont, {k + 1, MapSet.put(ids, id)}}
      else
        {:halt, {k, ids}}
      end
    end)
  end

  # Bracket-carrying turns in first-seen order, minus the newest one
  # (kept so the status derivation's "last turn_completed" survives).
  defp retired_turn_ids(revealed_events) do
    {order, bracketed} =
      Enum.reduce(revealed_events, {[], MapSet.new()}, fn event,
                                                          {order, bracketed} ->
        turn_id = Map.get(event, :turn_id)

        if Map.get(event, :family) == :loop and not is_nil(turn_id) do
          order = if turn_id in order, do: order, else: [turn_id | order]

          bracketed =
            if Map.get(event, :type) in [:turn_completed, :turn_canceled],
              do: MapSet.put(bracketed, turn_id),
              else: bracketed

          {order, bracketed}
        else
          {order, bracketed}
        end
      end)

    case order
         |> Enum.reverse()
         |> Enum.filter(&MapSet.member?(bracketed, &1)) do
      [] -> MapSet.new()
      completed -> completed |> List.delete_at(-1) |> MapSet.new()
    end
  end

  # Veto: any surviving event whose payload cites a dropped id in `refs`
  # (either key style) keeps everything -- an evidence ref must never be
  # left dangling into a compacted region.
  defp refs_clear?(model, k, dropped_ids) do
    cited =
      model.events
      |> Enum.drop(k)
      |> Enum.flat_map(fn event ->
        case Map.get(event, :payload) do
          %{} = payload ->
            List.wrap(Map.get(payload, "refs") || Map.get(payload, :refs))

          _other ->
            []
        end
      end)

    if Enum.any?(cited, &MapSet.member?(dropped_ids, &1)),
      do: :veto,
      else: :ok
  end

  # The dropped turns must account for exactly a leading run of SEALED
  # blocks, and no surviving block may reference a dropped event id
  # (a cross-turn evidence fold would show up here as an intersecting
  # `event_refs`).
  defp dropped_block_prefix(model, dropped_ids) do
    {dropped_blocks, rest} =
      Enum.split_while(model.projection.blocks, fn block ->
        Enum.all?(block.event_refs, &MapSet.member?(dropped_ids, &1))
      end)

    survivors_clear? =
      Enum.all?(rest, fn block ->
        not Enum.any?(block.event_refs, &MapSet.member?(dropped_ids, &1))
      end)

    count = length(dropped_blocks)

    if survivors_clear? and count <= model.painted_count,
      do: {:ok, count},
      else: :veto
  end

  # The referent check: the compacted prefix must project to EXACTLY the
  # old projection minus the dropped sealed blocks. `==` on the block
  # structs is a value comparison, so a detached (binary-copied) old
  # block still matches its freshly rebuilt twin.
  defp reproject_survivors(model, k, dropped_blocks) do
    projection =
      model.events
      |> Enum.drop(k)
      |> Enum.take(model.revealed - k)
      |> Projection.project(fold_defaults: model.fold_defaults)

    same? =
      projection.blocks == Enum.drop(model.projection.blocks, dropped_blocks) and
        projection.tail == model.projection.tail and
        projection.damaged == model.projection.damaged

    if same?, do: {:ok, projection}, else: :veto
  end

  defp commit_compaction(model, k, dropped_blocks, projection) do
    %{
      model
      | events: Enum.drop(model.events, k),
        revealed: model.revealed - k,
        projection: projection,
        painted_count: model.painted_count - dropped_blocks,
        fold_overrides:
          shift_fold_overrides(model.fold_overrides, dropped_blocks),
        focused_index: shift_focus(model.focused_index, dropped_blocks),
        unread: shift_unread(model.unread, dropped_blocks)
    }
  end

  defp shift_fold_overrides(overrides, shift) do
    for {index, fold} <- overrides,
        is_integer(index),
        index >= shift,
        into: %{} do
      {index - shift, fold}
    end
  end

  defp shift_focus(nil, _shift), do: nil
  defp shift_focus(index, shift), do: max(index - shift, 0)

  # UnreadDivider positions are block-count offsets; shift them with the
  # blocks. A span partially consumed by the drop keeps only its
  # surviving extent; a fully consumed span retires.
  defp shift_unread(unread, shift) do
    unread
    |> Map.update!(:boundary, fn
      nil -> nil
      boundary -> max(boundary - shift, 0)
    end)
    |> Map.update!(:span, fn
      nil ->
        nil

      %{from: from, count: count} = span ->
        shifted_from = max(from - shift, 0)
        shifted_count = count + min(from - shift, 0)

        if shifted_count > 0,
          do: %{span | from: shifted_from, count: shifted_count},
          else: nil
    end)
  end

  @doc """
  Closes a live stream opened with `new/2`'s `:stream_open` option and
  flushes every still-held completed block to sealed history.

  This is the release end of the fold-before-seal ordering contract (see
  `frontier_entries/1`): while the stream is open, the newest completed
  block is held un-sealed so that later same-turn events -- the turn
  bracket above all -- fold into the projection BEFORE the block is
  irreversibly painted. Once no more events will ever arrive (the session
  ended, the session process died, the event feed is gone), the hold has
  nothing left to wait for; this call drops it and runs the seal pass so
  the trailing block lands in history instead of living forever in the
  footer preview. Idempotent; a no-op on an already-closed model.
  """
  @spec close_stream(t()) :: t()
  def close_stream(model) do
    # `debug_highlight` is display-only observer state -- a closing
    # stream is the teardown boundary, so an active highlight is cleared
    # here rather than surviving into the session's final frames.
    %{model | stream_open?: false, debug_highlight: nil}
    |> paint_pending_blocks()
    |> paint_footer()
  end

  @doc """
  The PER-TURN release of the fold-before-seal hold: seals every
  currently-completed block while LEAVING the stream open for future
  turns.

  Call when a turn bracket (`turn_completed` / `turn_canceled`) has
  folded: nothing more can ever fold into the blocks that bracket
  completed, so holding them any longer serves nothing -- but the session
  lives on (a multi-turn conversation runs one turn per prompt on the
  same session), so this must NOT close the stream. `close_stream/1` is
  the terminal sibling for the process-level end-of-stream facts (session
  death, dead event feed), and the backstop that guarantees a stranded
  tail still lands in history if a session dies mid-turn with no bracket.
  """
  @spec flush_held(t()) :: t()
  def flush_held(model) do
    open? = Map.get(model, :stream_open?, false)

    # The hold is suppressed for exactly one seal pass -- the frontier
    # scan inside `paint_pending_blocks/1` reads `stream_open?`, so this
    # toggle IS the release -- then restored so the next turn's blocks
    # get their own hold.
    model
    |> Map.put(:stream_open?, false)
    |> paint_pending_blocks()
    |> Map.put(:stream_open?, open?)
    |> paint_footer()
  end

  @doc """
  Sets (or clears, with `nil`) a PERSISTENT footer notice line -- rendered
  on every paint until replaced or cleared, unlike `stub_notice` (which
  `paint_footer/1` consumes after one frame). Intended for live-session
  status the embedder wants visible across many frames (e.g. "reconnecting
  to live session"), not a one-shot acknowledgment. Repaints the footer
  before returning.
  """
  @spec put_lane_notice(t(), String.t() | [String.t()] | nil) :: t()
  def put_lane_notice(model, text) do
    %{model | lane_notice: text}
    |> paint_footer()
  end

  @doc """
  Sets (or clears, with `nil`) the DevTools debug highlight: a
  DISPLAY-ONLY pale-blue background painted under every line of one
  footer group (the `t:debug_highlight_group/0` vocabulary -- the exact
  group keys `footer_frame/1` composes). Driven by the react-devtools
  bridge's hover/select events (`highlightHostInstance` /
  `clearHostInstanceHighlight`); one highlight at a time,
  last-writer-wins. Repaints the footer before returning.

  ## Honesty constraints (the laws the test suite pins byte-level)

    * Display-only, footer-only: the bg is applied AFTER the footer fit
      (`fit_footer_groups/3`), through `ViewText.highlight_bg/3` at the
      byte-emission seam -- it can never change a group's row count, move
      the cursor park, or reach the seal path. Sealed history is
      untouched by construction (a hover on a sealed block renders the
      bridge's honest notice instead -- seal-once).
    * Never persisted: cleared by `close_stream/1` (teardown honesty),
      and `nil` on a model that has no highlight is a zero-byte no-op
      (the repaint diff sees no changed rows), so goldens can never be
      perturbed by an idle highlight channel.
    * The tint is a palette ROLE (`Raxol.UI.Theming.Palette`'s
      `:debug_highlight_bg`), resolved per capability tier at `new/2` --
      truecolor / 256-cube / ANSI16-blue, category-preserving. No color
      literal lives here.

  A group outside the vocabulary clears the highlight (fail-safe: never
  paint the wrong region, never keep a stale one for an out-of-process
  caller's typo).
  """
  @spec put_debug_highlight(t(), debug_highlight_group() | nil) :: t()
  def put_debug_highlight(model, group)
      when group in @debug_highlight_groups do
    %{model | debug_highlight: group}
    |> paint_footer()
  end

  def put_debug_highlight(model, _nil_or_unknown) do
    %{model | debug_highlight: nil}
    |> paint_footer()
  end

  @doc """
  Sets (or clears, with `nil`) the status strip's `:stall_verdict` seam
  (`Raxol.Harness.StatusStrip`'s own documented integration point) and
  repaints the footer. The strip already renders the `ALERT: <evidence>`
  segment for a `:stalled`/`:looping` verdict with non-empty evidence; this
  function is only the model-side plumbing that gets a verdict into
  `model.status` in the first place.
  """
  @spec put_stall_verdict(t(), map() | nil) :: t()
  def put_stall_verdict(model, nil) do
    %{model | status: Map.delete(model.status, :stall_verdict)}
    |> paint_footer()
  end

  def put_stall_verdict(model, verdict) do
    %{model | status: Map.put(model.status, :stall_verdict, verdict)}
    |> paint_footer()
  end

  @doc """
  Seals ONE honest, plain marker line into the history region at the
  current append point -- the loss-honesty marker for live streaming (e.g.
  shed deltas, a rejected/dropped event). This instrument never renders a
  gapless lie over lost data: when the live lane cannot deliver every
  event, this is how the transcript says so, instead of silently rendering
  as if nothing had been lost.

  Uses the SAME emit paths `seal_block/2` uses (`FlatAuthority.seal/2` with
  a trailing `"\\n"` in `:flat` mode; `InlineAuthority.seal/2` with a
  trailing `"\\r\\n"` otherwise), through `ViewText.lines/3` exactly like
  every other sealed line. `painted_count` is deliberately NOT advanced --
  a marker is not a block, and this module's fold/jump bookkeeping
  (`frontier_entries/1`, `paint_pending_blocks/1`) only ever reasons about
  `model.projection.blocks`.
  """
  @spec seal_marker(t(), String.t()) :: t()
  def seal_marker(%{mode: :flat} = model, text) do
    model = clear_greeting(model)
    lines = marker_lines(model, text, :plain)
    iodata = Enum.map(lines, &(&1 <> "\n"))

    %{
      model
      | authority: FlatAuthority.seal(model.authority, iodata),
        sealed_any?: true
    }
  end

  def seal_marker(%{mode: :full_viewport} = model, text) do
    %{
      model
      | transcript_records: [{:marker, text} | model.transcript_records],
        sealed_any?: true
    }
  end

  def seal_marker(model, text) do
    model = clear_greeting(model)
    lines = marker_lines(model, text, :styled)
    iodata = Enum.map(lines, &[&1, "\r\n"])

    %{
      model
      | authority: InlineAuthority.seal(model.authority, iodata),
        sealed_any?: true
    }
  end

  defp marker_lines(model, text, mode) do
    %{type: :text, content: text}
    |> ViewText.lines(content_width(model), mode)
    |> margin_lines()
  end

  @doc """
  Commits an in-flight submit's prompt into sealed history -- the
  event-observed accept. Called by the live driver when the lane's
  `:turn_started` event confirms the session opened a turn for the
  prompt this surface has pending (see `apply_composer_command/2`'s
  `:submit` clause and `Raxol.Harness.SessionLane`'s `submit/2` doc). The
  prompt is sealed as a `<sigil> prompt` line through the SAME
  `seal_marker/2` path every loss marker uses, then `pending_submit` is
  cleared (the dim "sending" preview disappears with it).

  Sealing on `:turn_started` -- BEFORE any response `item_*` events reveal
  -- is what puts the user's echo ahead of the first response block in the
  byte stream (the echo-on-accept ordering invariant).

  ## Speaker-separation alignment (V's outer-contour amendment)

  The echo renders with the FULL dialogue-echo geometry the seal seam
  (`echo_lines/4`) gives a replayed user `:message` block: the sigil
  flush left in the margin column (column 0, the outer contour -- NOT
  the margined marker column `seal_marker/2` uses), text at the content
  indent (column 2), wrapped lines hang-aligned with the composer's own
  two-space continuation convention, and the sigil bold through the
  ViewText SGR path. The glyph is `model.sigil` -- the same one-sigil
  source the composer's live draft row and the replayed user echo carry
  (`❯`, degrading to `>` under `unicode: :none`), so a live-submitted
  prompt and a replayed user block are column- and glyph-identical. The
  one styling difference from the block path: no prominence fade (a live
  echo has no projection block behind it yet, so there is nothing to
  grade). It also takes the standard one-blank-row turn separator
  (`block_separator/1`) -- the echo opens a new turn, and the blank-row
  rhythm is the load-bearing separator.

  A no-op when there is no `pending_submit` (a `:turn_started` for a turn
  this surface did not submit -- e.g. an externally-initiated turn -- must
  not fabricate an echo).
  """
  @spec submit_accepted(t()) :: t()
  def submit_accepted(%{pending_submit: %{text: text}} = model) do
    model
    |> seal_prompt_echo(text)
    |> Map.put(:pending_submit, nil)
    |> paint_footer()
  end

  def submit_accepted(model), do: model

  # The live prompt echo's seal: same authority calls as `seal_marker/2`
  # (a marker-class write -- `painted_count` is NOT advanced; the echo is
  # not a projection block), but decorated with the dialogue-echo
  # geometry instead of the plain margin, plus the turn-separator blank
  # row. `sealed_any?` is set, so the first response block that follows
  # is separated from the echo by exactly one blank -- the rhythm law
  # holds between a live echo and its answer just as it does between
  # replayed blocks.
  defp seal_prompt_echo(%{mode: :flat} = model, text) do
    model = clear_greeting(model)
    lines = block_separator(model) ++ prompt_echo_lines(model, text, :plain)
    iodata = Enum.map(lines, &(&1 <> "\n"))

    %{
      model
      | authority: FlatAuthority.seal(model.authority, iodata),
        sealed_any?: true
    }
  end

  defp seal_prompt_echo(%{mode: :full_viewport} = model, text) do
    %{
      model
      | transcript_records: [{:echo, text} | model.transcript_records],
        sealed_any?: true
    }
  end

  defp seal_prompt_echo(model, text) do
    model = clear_greeting(model)
    lines = block_separator(model) ++ prompt_echo_lines(model, text, :styled)
    iodata = Enum.map(lines, &[&1, "\r\n"])

    %{
      model
      | authority: InlineAuthority.seal(model.authority, iodata),
        sealed_any?: true
    }
  end

  defp prompt_echo_lines(model, text, mode) do
    sigil = live_echo_sigil(model, mode)

    lines =
      case ViewText.lines(
             %{type: :text, content: text},
             content_width(model),
             mode
           ) do
        [] -> [sigil]
        ["" | rest] -> [sigil | Enum.map(rest, &hang_line/1)]
        [first | rest] -> [sigil <> " " <> first | Enum.map(rest, &hang_line/1)]
      end

    # Same outer-contour framing as `echo_lines/4`: in `:full_viewport`
    # the live echo's chevron aligns with the machinery margin column; a
    # no-op in the inline/flat seal paths (`inset_prefix/2`).
    Enum.map(lines, &inset_prefix(&1, model))
  end

  defp live_echo_sigil(model, :plain), do: model.sigil
  defp live_echo_sigil(model, :styled), do: styled_sigil(model)

  @doc """
  Restores an in-flight submit's prompt back into the composer -- the
  refusal path. Called by the live driver when a submit cannot open a turn
  (the session is busy with a turn already in flight, or the lane rejected
  the dispatch). The Composer cleared its buffer on Enter, so the draft
  lived only in `pending_submit`; this puts it back (`Composer.set_value/2`)
  so the operator never loses what they typed, and clears `pending_submit`
  (the dim "sending" preview disappears). The driver pairs this with an
  honest `put_lane_notice/2` naming WHY the submit was refused.

  A no-op (composer untouched) when there is no `pending_submit`.
  """
  @spec submit_refused(t()) :: t()
  def submit_refused(%{pending_submit: %{text: text}} = model) do
    %{
      model
      | composer: Composer.set_value(model.composer, text),
        pending_submit: nil
    }
    |> paint_footer()
  end

  def submit_refused(model), do: model

  @doc """
  Builds the seal-frontier entry list (`Raxol.Harness.SealFrontier.entry/0`)
  from the current projection. One entry per completed block, in order;
  the live tail never enters the list (a still-streaming item has no
  committable form until it completes into a block, so it is
  definitionally past the frontier).

  Field mapping (the design decision this assembly makes):

    * `committed?` -- delegated to `block_sealed?/2`, THE single-source
      committed-marker predicate (its doc states the `painted_count`
      comparison exactly once; restating it here is the drift the
      unification exists to prevent).
    * `running?` -- `Block.live?/1`, an honest passthrough. Always false
      for tool/reasoning/message blocks (the block builder only stamps
      unanswered approvals `:live`); a tool's `running…` state is a
      footer-preview concern (see `pending_preview_lines/1`), never a
      held block, so the sealed line is always its final form and the
      live/fixture byte-parity guard holds under any reveal cadence.
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
    # A LIVE stream is never "finished" merely by being momentarily caught
    # up: `revealed == length(events)` is true after every applied live
    # event, so without this gate the one-step hold below would never
    # engage on the live path and every block would seal the instant it
    # materializes -- BEFORE its turn bracket (and anything a later unit
    # folds into the block from it, e.g. a completion/evidence row) lands
    # in the projection. The fixture path and the live path must render
    # the same events identically; `stream_open?` is what makes "finished"
    # mean the same thing on both ("no more events will ever come"), and
    # `close_stream/1` is where a live session finally says so.
    # (`Map.get`, not dot access: hand-assembled frontier-feed test models
    # and models built by an older constructor may not carry the key --
    # absent means the fixture default, a closed stream.)
    reveal_finished? = reveal_finished?(model)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{
        kind: block.kind,
        committed?: block_sealed?(model, index),
        running?: Block.live?(block),
        pending_input?:
          awaiting_input?(block) or
            (not reveal_finished? and index == total - 1)
      }
    end)
  end

  # "No more events will ever come": the stream is closed AND everything
  # already revealed. One meaning on both the fixture and live paths --
  # feeds the frontier's newest-block hold and the footer preview's
  # `pending?` running-tool signal (a resultless tool renders `running…`
  # in the footer only while this is false; once true it seals to its
  # honest `⊘ no result` final form).
  defp reveal_finished?(model) do
    not Map.get(model, :stream_open?, false) and
      model.revealed >= length(model.events)
  end

  # THE committed-marker mapping, stated exactly once: block `index` is
  # sealed (physically painted into print-once history) iff it sits below
  # the `painted_count` high-water mark -- the mark only ever advances a
  # contiguous prefix, so the comparison IS the committed set. Both the
  # frontier feed above (`committed?`) and the fold fill-guard
  # (`apply_fold_toggle/2` -- the one mutation channel aimed at a block)
  # consult this one predicate, so the "what counts as sealed" boundary
  # can never drift between the classifier's view and the guard's
  # (boundary-agreement pinned in
  # test/harness/surface_frontier_feed_test.exs).
  # No `index >= 0` guard on purpose: a degenerate negative index (no
  # producer can build one -- `move_focus/2` clamps at 0 -- but the
  # payload is data) classifies as "sealed" and lands on the honest
  # refusal notice, never a crash mid-input-frame. Fail-closed: the
  # restrictive answer for a nonsense index is "not foldable."
  defp block_sealed?(model, index) when is_integer(index),
    do: index < model.painted_count

  # A live approval block is, per `Block`'s own contract, a question still
  # waiting on the user -- the genuine awaiting-input feed for the
  # frontier's pending-input gate. A sealed approval is an answered
  # question and does not feed the gate. See `frontier_entries/1`'s doc.
  defp awaiting_input?(block),
    do: Block.live?(block) and block.kind == :approval

  @doc """
  The shared PRE-commit frontier consultation: `SealFrontier.scan_frontier/3`
  over `frontier_entries/1`. Two consumers read it, both BEFORE the
  commit pass runs: `paint_pending_blocks/1`'s detach target
  (`tail_start` -- every block at or past "about to seal" gets its
  content detached), and `seal_frame/3`'s per-frame synchronized-output
  bracket decision (`will_commit` predicts "this frame seals >= 1
  block" -- same entries, same classifier, so it can never disagree
  with what the walk actually attempts). `turn_running?` is derived
  from the status snapshot (`turn_completed`); with today's entry
  mapping (no running entries, window hold unconditional) the scan
  result is independent of turn state, so the one-step-stale status at
  seal time is harmless.

  The footer's pending preview (`pending_block/1`) deliberately does
  NOT read this scan: it keys on the committed cursor
  (`painted_count`) instead, because the scan consumes committable
  entries and would therefore hide a block whose seal write was just
  REFUSED (see `pending_block/1`'s comment for the full rationale).
  The two agree on every successful frame (the scan/walk-agreement
  property); they diverge exactly when a write fails, and the cursor
  is the display-honest side of that divergence.
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
    # The emit is write-checked (`InlineAuthority.try_seal/2`): write ->
    # confirm -> mark, where "confirmed" means the device's io server
    # ACCEPTED the write (see try_seal/2's doc for what that does and
    # does not promise). A refused write halts the walk with
    # painted_count (the cursor) strictly before the failed entry, and the
    # next advance retries the same block, so a block can never be marked
    # painted for bytes the device refused (retry-not-vanish; covered by
    # test/harness/surface_seal_pipeline_test.exs).
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

          case seal_block(acc, block) do
            {:ok, _acc} = ok ->
              ok

            {:error, :write_failed, _acc} = error ->
              # The retry loop for a refusing-but-alive device is
              # unbounded BY DESIGN (a bound would strand the block when
              # the device recovers) -- this emit is what keeps it from
              # being unbounded AND invisible: one event per refused
              # write, from the first frame, so a driver/operator can see
              # a persistent refusal and decide. A DEAD device never
              # reaches here (try_seal fail-fasts on a corpse).
              :telemetry.execute(
                [:raxol, :harness, :seal, :write_failed],
                %{},
                %{index: index, kind: block.kind}
              )

              error
          end
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

  # :flat -- the degradation tier's append is a plain stdout/pipe write with
  # no positioning to confirm; a failed pipe write raising out of the frame
  # is the honest flat behavior, so the flat emit stays infallible-shaped.
  defp seal_block(%{mode: :flat} = model, block) do
    model = clear_greeting(model)

    lines =
      block
      |> render_block_lines(model, :plain)
      |> sealed_history_lines(block, model, :plain)

    iodata = Enum.map(block_separator(model) ++ lines, &(&1 <> "\n"))
    authority = FlatAuthority.seal(model.authority, iodata)

    {:ok,
     %{
       model
       | authority: authority,
         painted_count: model.painted_count + 1,
         sealed_any?: true
     }}
  end

  # `:full_viewport` emits NO bytes at seal time -- the whole-frame
  # `ViewportAuthority.repaint/3` at the end of the frame renders the
  # transcript. Sealing FREEZES the block into a `seal_record` with its
  # seal-time prominence grade, so a later repaint (after more turns
  # arrive) re-renders it byte-identically (logical immutability -- the
  # grade never drifts), while a resize reflows it at the new width. The
  # write can never fail (an append to a list), so this always returns
  # `{:ok, _}`.
  defp seal_block(%{mode: :full_viewport} = model, block) do
    record = {:block, block, block_prominence(block, model)}

    {:ok,
     %{
       model
       | transcript_records: [record | model.transcript_records],
         painted_count: model.painted_count + 1,
         sealed_any?: true
     }}
  end

  # No per-line `\e[K` here: `InlineAuthority.try_seal/2` sanitizes CONTENT
  # through `ContentGuard.sanitize_line/1` (its allowlist keeps SGR only),
  # so an EL embedded in content never survived -- the guard stripped the
  # ESC and left a literal `[K` painted at the start of every sealed
  # history row (caught by the byte-golden sidecar; pinned by the
  # ESC-less-residue guard in test/harness/golden_snapshot_test.exs).
  # Erasing is the authority's business, not content's: sealed lines land
  # on rows the DECSTBM scroll already blanked, so no EL is needed.
  defp seal_block(model, block) do
    # The greeting's erase bytes must precede this seal's bytes in the
    # SAME frame (the ephemeral-element law) -- clear first.
    model = clear_greeting(model)

    lines =
      block
      |> render_block_lines(model, :styled)
      |> sealed_history_lines(block, model, :styled)

    iodata = Enum.map(block_separator(model) ++ lines, &[&1, "\r\n"])

    case InlineAuthority.try_seal(model.authority, iodata) do
      {:ok, authority} ->
        {:ok,
         %{
           model
           | authority: authority,
             painted_count: model.painted_count + 1,
             sealed_any?: true
         }}

      {:error, :write_failed, authority} ->
        {:error, :write_failed, %{model | authority: authority}}
    end
  end

  # One blank row between sealed content and the next block (V's margin
  # ruling) -- emitted WITH the block's own seal write (never as a
  # separate authority call), so the write-checked commit stays atomic:
  # a refused write leaves neither separator nor block behind. Gated on
  # `sealed_any?` so the very first sealed line of a session never opens
  # with a blank. Markers (`seal_marker/2`) get no separator of their
  # own -- a loss report attaches tightly to the content it interrupts --
  # but they do SET `sealed_any?`, so the block after one is separated.
  defp block_separator(%{sealed_any?: true}), do: [""]
  defp block_separator(_model), do: []

  # Called from seal_block/2 -- the print-once paint -- so the grade
  # computed here IS the seal-time grade (see RecencyPolicy's moduledoc,
  # "Seal-time grading"): painted history is never re-graded because it
  # is never repainted. The grade trusts source_events' journal order
  # and durable completeness -- both guaranteed upstream
  # (Recovery.filter_ids/1 id-monotonicity; un-windowed durable-only
  # retention); see RecencyPolicy.grade_block/2's input contract.
  defp render_block_lines(block, model, mode) do
    # Rendered at the margined content width -- `seal_block/2` adds the
    # 1-column margin around these lines, and the budget must shrink
    # BEFORE truncation, never after (a full-width line prefixed with a
    # margin would overflow the terminal by exactly the margin). The
    # user-echo prefix is width-honest by the same arithmetic: its 2
    # cells over the SAME budget mirror the composer's chevron rows
    # exactly (`chevron_lines/2`).
    block
    |> BlockBody.render(%{
      width: content_width(model),
      prominence: block_prominence(block, model),
      turn_has_tools?: turn_has_tools?(block, model)
    })
    |> ViewText.lines(content_width(model), mode)
  end

  defp block_prominence(block, model),
    do: RecencyPolicy.grade_block(block, model.projection.source_events)

  # -- the dialogue chevrons (speaker separation, option A as V-amended) ---
  #
  # V's margin ruling, amended 2026-07-17: the chevron pair is the ONLY
  # entity that enters the 1-cell margin area -- dialogue markers live in
  # the OUTER CONTOUR. An EXPANDED `:message` block seals with its
  # speaker's sigil flush left in the margin column (column 0) and its
  # text at the content indent (column 2):
  #
  #   * user      -> `❯ text` -- the composer's `model.sigil` echoed into
  #     history (`unicode: :none` degrades it to `>`; echo and live
  #     prompt can never drift);
  #   * assistant -> `❮ text` -- `model.reply_sigil`, the mirrored
  #     inverse, degrading to `<` on the same tier so the pair always
  #     matches.
  #
  # Remaining lines hang-align to the text column with two spaces, the
  # composer's own continuation-row convention (`chevron_lines/2` is the
  # template). The mirrored pair IS the speaker grammar; machinery blocks
  # (tool/system glyph headers) and FOLDED headers (`▸ ❯ ...` / `▸ » ...`,
  # which keep the ordinary margined header column) take the plain margin.
  defp sealed_history_lines(lines, block, model, mode) do
    if dialogue_block?(block) do
      echo_lines(lines, block, model, mode)
    else
      margin_lines(lines)
    end
  end

  # Only an EXPANDED message speaks with a sigil: a folded one renders as
  # a `▸ ❯/» summary` header line, and prefixing THAT with a second
  # chevron would stutter (`❯ ▸ ❯ ...`) -- the fold guard keeps folded
  # headers at their existing column convention.
  defp dialogue_block?(%Block{kind: :message, fold: :expanded}), do: true
  defp dialogue_block?(_block), do: false

  defp echo_lines([], _block, _model, _mode), do: []

  defp echo_lines([first | rest], block, model, mode) do
    # The sigil + hang lines are the OUTER CONTOUR; in `:full_viewport`
    # they take the frame inset so the chevron aligns with the machinery
    # margin column (a no-op in inline/flat -- `inset_prefix/2`).
    [echo_first_line(first, block, model, mode) | Enum.map(rest, &hang_line/1)]
    |> Enum.map(&inset_prefix(&1, model))
  end

  # A blank first line gets the bare sigil (no trailing space injected --
  # same no-phantom-whitespace rule as `margin_line/1`).
  defp echo_first_line("", block, model, mode),
    do: echo_sigil(block, model, mode)

  defp echo_first_line(line, block, model, mode),
    do: echo_sigil(block, model, mode) <> " " <> line

  defp hang_line(""), do: ""
  defp hang_line(line), do: "  " <> line

  # The speaker's glyph: user turns echo the composer's prompt sigil,
  # assistant turns carry the mirrored reply sigil -- both fields decided
  # once from the capability record in `new/2`, so the pair can never
  # drift apart or mix tiers.
  defp role_sigil(block, model) do
    case Block.role(block) do
      :user -> model.sigil
      :assistant -> model.reply_sigil
    end
  end

  # Bold (structure channel, doctrine §4.3) through the SAME ViewText SGR
  # path as the composer's sigil -- and NO fg of its own (single-fg rule,
  # enforced in the honest direction): a dialogue sigil only ever fronts
  # an EXPANDED message body (the fold guard above), and the mounted
  # expanded body carries no prominence fade today (`BlockBody`'s
  # documented T5 scope cut) -- so the sigil is neutral too. A sigil that
  # faded on its own would (a) split one physical line's block into two
  # salience levels, and (b) make sealed bytes depend on REVEAL CADENCE:
  # seal-time grade differs between the live flush-at-bracket path and
  # the fixture hold-back-one path, and the live/fixture byte-parity
  # guard (live_session_driver_compaction_test.exs) rightly forbids
  # cadence-dependent history. When the mount path later threads
  # prominence into message bodies, this style must take the SAME
  # resolved fg in the same change -- never ahead of it. `:plain` is the
  # flat tier -- zero escape bytes, the bare sigil.
  defp echo_sigil(block, model, :plain), do: role_sigil(block, model)

  defp echo_sigil(block, model, :styled) do
    [line] =
      ViewText.lines(
        %{
          type: :text,
          content: role_sigil(block, model),
          style: %{bold: true}
        },
        @sigil_cols,
        :styled
      )

    line
  end

  # The absence-row suppression referent (V field ruling; policy seat is
  # `Block.completion_rows/3`, layering rationale in `BlockBuilder`'s
  # "Known conflation" section): whether the block's OWN turn carried
  # any tool activity, derived from THIS surface's window
  # (`projection.source_events`) -- a display fact, deliberately outside
  # the offset-law-governed transcript identity. Unknown turn (no source
  # event matches the block's refs) fails toward `true`: over-reporting
  # the absence alarm is the safe direction, suppressing it is not.
  defp turn_has_tools?(block, model) do
    events = model.projection.source_events

    case block_turn_id(block, events) do
      nil ->
        true

      turn_id ->
        Enum.any?(events, fn event ->
          Map.get(event, :turn_id) == turn_id and
            event_item_type(event) in ["tool_use", "tool_result"]
        end)
    end
  end

  defp block_turn_id(block, events) do
    refs = MapSet.new(block.event_refs || [])

    Enum.find_value(events, fn event ->
      if MapSet.member?(refs, Map.get(event, :id)),
        do: Map.get(event, :turn_id)
    end)
  end

  defp event_item_type(event) do
    case Map.get(event, :payload) do
      %{} = payload ->
        Map.get(payload, "item_type") || Map.get(payload, :item_type)

      _other ->
        nil
    end
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

    # PROXY RETIRED (Track D): this was
    #   `last_loop != nil and last_loop.type == :approval_requested`
    # -- a heuristic on the LAST event that diverges from the truth the
    # moment any event follows an unanswered approval (the last event is
    # then no longer `:approval_requested`, yet the question is still live
    # and still holding the frontier). The honest signal is the REFERENT:
    # is a live approval block actually on screen, awaiting an answer? That
    # is exactly what holds the seal frontier, so the status "needs-input"
    # flag and the frontier gate now read from one source and can never
    # disagree. (`model.projection` is already set for this frame -- see
    # `run_advance/2` -- so this reads the current block list, not a stale
    # one.)
    needs_input? = live_approval_block(model) != nil

    cost =
      if last_turn_completed,
        do: payload_field(last_turn_completed, "cost", :cost)

    # The strip's operator-phase inputs (charged-minimum form; see
    # `Raxol.Harness.StatusStrip`'s "Phase derivation"): when the last
    # loop event is a tool_use completion, its result is not in yet --
    # the tool is RUNNING, and the strip names it. `last_item_type`
    # disambiguates the other `item_completed` phases (tool_result ->
    # "thinking", message -> "responding"). Both read the same last
    # event `turn_stage` reads, so the three can never disagree.
    {running_tool, last_item_type} = item_phase_inputs(last_loop)

    status =
      model.status
      |> Map.put(:turn_stage, last_loop && event_field(last_loop, :type))
      |> Map.put(:running_tool, running_tool)
      |> Map.put(:last_item_type, last_item_type)
      |> Map.put(:turn_completed, turn_completed?)
      |> Map.put(:needs_input, needs_input?)
      |> Map.put(:cost, cost)
      |> maybe_put_now(now, last_loop)

    %{model | status: status}
  end

  # Payload values arrive as atoms from in-process producers and as
  # strings off the fixture wire / EventBoundary deep-normalize -- fold
  # both spellings to the atom vocabulary (fixed map, never
  # String.to_atom/1 on wire input).
  @item_type_atoms %{
    "message" => :message,
    "reasoning" => :reasoning,
    "tool_use" => :tool_use,
    "tool_result" => :tool_result
  }

  defp item_phase_inputs(last_loop) do
    if last_loop != nil and event_field(last_loop, :type) == :item_completed do
      item_type =
        case payload_field(last_loop, "item_type", :item_type) do
          type when is_atom(type) and type != nil -> type
          type when is_binary(type) -> Map.get(@item_type_atoms, type, type)
          _other -> nil
        end

      running_tool =
        if item_type == :tool_use do
          case payload_field(last_loop, "name", :name) do
            name when is_binary(name) and name != "" -> name
            _other -> nil
          end
        end

      {running_tool, item_type}
    else
      {nil, nil}
    end
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
  `Composer.handle_event/3` only while `composing?` AND no overlay/
  expansion is open; while an overlay picker is open (`model.overlay !=
  nil`), a `:passthrough` result instead reaches
  `Raxol.UI.Harness.OverlayPicker.handle_key/2` with the SAME normalized
  event this function already computed (never re-normalized) -- see "The
  overlay picker" section above. While a diff expansion is open
  (`model.expansion != nil`), a `:passthrough` result is instead consulted
  for scroll/dismiss keys directly by this module -- see "Full-screen
  diff expansion" below. `overlay_open?` in the `Keymap` context carries
  BOTH transient-footer-view flags (`model.overlay != nil or
  model.expansion != nil`): an open expansion suppresses the same
  `:not_composing` binds (and captures ESC as `:overlay_dismiss`) an open
  overlay would, for the identical reason -- the footer is showing
  something other than the transcript/composer, and typed letters must
  reach THAT, never fire commands at state hidden behind it. Always
  repaints the footer afterward.
  """
  @spec handle_input(t(), term()) :: t()
  def handle_input(model, raw_event) do
    model = heal_sync(model)
    norm = InputEvent.normalize(raw_event)

    # Every keystroke is presence evidence for the unread divider's
    # keystroke fallback (see `UnreadDivider`'s "mode-1004 seam" doc) --
    # this is a no-op unless the policy is currently `:away`.
    model = %{
      model
      | unread: UnreadDivider.input_activity(model.unread, unread_offset(model))
    }

    context = keymap_context(model)

    model =
      case Keymap.resolve(norm, context) do
        :passthrough -> route_passthrough(model, norm, raw_event)
        command -> dispatch_command(model, command)
      end

    paint_footer(model)
  end

  # The one construction of `Keymap.resolve/2`'s mode context -- shared
  # with `palette_command/2`'s `Keymap.command_for/2` invocation below, so
  # the two can never drift apart (a palette-picked bind and a live
  # keypress must see the identical context shape).
  defp keymap_context(model) do
    %{
      composing?: model.composing?,
      streaming?: not Map.get(model.status, :turn_completed, false),
      focused_block_id: model.focused_index,
      # BOTH transient footer views ride this flag (see the moduledoc's
      # "Full-screen diff expansion" section): an open expansion
      # suppresses the same `:not_composing` binds (and captures ESC as
      # `:overlay_dismiss`) an open overlay picker would.
      overlay_open?: model.overlay != nil or model.expansion != nil,
      # Track D: the answer-key guard (`:awaiting_approval`) fires only
      # while a live approval block is genuinely holding the frontier --
      # the SAME referent the frontier's pending-input gate keys on
      # (`live_approval_block/1`), never a proxy for it -- AND only while
      # the composer draft is empty, so `y`/`n`/digits answer a pending
      # question when the operator hasn't typed anything, yet stay plain
      # text the moment there is a draft to protect.
      approval_pending?: live_approval_block(model) != nil,
      composer_empty?: composer_empty?(model)
    }
  end

  # The composer draft is "empty" when it carries no text at all -- the
  # signal that the operator is not mid-thought, so an answer key is safe
  # to consume (see `Keymap`'s `:awaiting_approval` guard). Any typed
  # character makes it non-empty and hands letters back to the composer.
  defp composer_empty?(model), do: Composer.value(model.composer) in [nil, ""]

  # The live approval block currently awaiting an answer (the one holding
  # the seal frontier), or `nil`. THE referent for "is a question on
  # screen" -- reused by `keymap_context/1` (answer-key guard) and
  # `dispatch_command/2` (resolving an answer hint to a concrete option),
  # and the honest replacement for the old last-event-type proxy in
  # `update_status/3`. First live approval by projection order: there is
  # never more than one unanswered at a time (each blocks the turn), but
  # first-match is well-defined regardless.
  @spec live_approval_block(t()) :: Block.t() | nil
  def live_approval_block(model) do
    model.projection.blocks
    |> Enum.find(&awaiting_input?/1)
  end

  # Resolves a keyboard answer HINT against the live approval block's
  # actual options -- the honesty seam between "a key was pressed" and "a
  # concrete decision was sent to the agent." Returns the referent triple
  # `{request_id, option_id, decision}` the agent can act on, or an
  # `{:error, reason}` a caller turns into an honest refusal (never a
  # phantom answer):
  #
  #   * `{:option, i}` -- the Nth option shown, by position; refused when
  #     `i` is past the option list.
  #   * `:allow` / `:deny` -- the first option whose kind is an
  #     allow-/reject-class option (the `y`/`n` aliases); refused when the
  #     producer offered no option of that class.
  #
  # `:no_live_approval` when nothing is awaiting an answer at all.
  @spec resolve_approval_answer(t(), term()) ::
          {:ok, %{request_id: term(), option_id: term(), decision: atom()}}
          | {:error, atom()}
  defp resolve_approval_answer(model, hint) do
    case live_approval_block(model) do
      nil ->
        {:error, :no_live_approval}

      block ->
        content = block.content
        options = Map.get(content, :options, [])

        case answer_option(options, hint) do
          {:ok, option_id, decision} ->
            {:ok,
             %{
               request_id: Map.get(content, :request_id),
               option_id: option_id,
               decision: decision
             }}

          {:error, _reason} = err ->
            err
        end
    end
  end

  defp answer_option(options, {:option, index})
       when is_list(options) and is_integer(index) do
    case Enum.at(options, index) do
      nil -> {:error, :no_such_option}
      option -> {:ok, option_id_of(option), decision_of(option)}
    end
  end

  defp answer_option(options, decision)
       when is_list(options) and decision in [:allow, :deny] do
    case Enum.find(options, &(decision_of(&1) == decision)) do
      nil -> {:error, :no_matching_option}
      option -> {:ok, option_id_of(option), decision}
    end
  end

  defp answer_option(_options, _hint), do: {:error, :unanswerable}

  defp option_id_of(%{option_id: id}), do: id
  defp option_id_of(%{"option_id" => id}), do: id
  defp option_id_of(option) when is_binary(option), do: option
  defp option_id_of(_option), do: nil

  # An option's decision CLASS, from its ACP kind. Unknown/absent kind is
  # fail-closed to `:deny` for the `y`/`n` alias search -- a `y` must never
  # match an option whose safety class we cannot establish. (The `option_id`
  # remains the authoritative thing sent to the agent regardless; the agent
  # re-derives the canonical decision for its own `approval_decided`.)
  defp decision_of(%{kind: kind}), do: decision_from_kind(kind)
  defp decision_of(%{"kind" => kind}), do: decision_from_kind(kind)
  defp decision_of(_option), do: :deny

  defp decision_from_kind(kind)
       when kind in [:allow_once, :allow_always, "allow_once", "allow_always"],
       do: :allow

  defp decision_from_kind(kind)
       when kind in [
              :reject_once,
              :reject_always,
              "reject_once",
              "reject_always"
            ],
       do: :deny

  defp decision_from_kind(_kind), do: :deny

  defp approval_refusal_notice(:no_live_approval),
    do: "» no approval is awaiting an answer"

  defp approval_refusal_notice(:no_such_option),
    do: "» no such approval option"

  defp approval_refusal_notice(:no_matching_option),
    do: "» this approval offers no such choice"

  defp approval_refusal_notice(_reason),
    do: "» cannot answer that approval"

  # The hosted overlay's own module (see the `overlay()` typedoc) --
  # `OverlayPicker` for the filterable pickers, or an explicitly-stamped
  # `mod` (currently only `OverlayPanel`, the read-only projection
  # panels) for anything else. One source of truth for "which module owns
  # this overlay's state," consulted at every dispatch site instead of
  # hardcoding `OverlayPicker`.
  defp overlay_mod(overlay), do: Map.get(overlay, :mod, OverlayPicker)

  # While an overlay is open, EVERY :passthrough event (typed characters,
  # arrows, Enter, an unrecognized special key) is routed to the hosted
  # overlay instead of the Composer -- the composer's buffer is frozen
  # mid-pick (see the moduledoc's command-bifurcation note on `:steer`).
  defp route_passthrough(%{overlay: overlay} = model, norm, _raw_event)
       when overlay != nil do
    case overlay_mod(overlay).handle_key(overlay.picker, norm) do
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

  # While a diff expansion is open, EVERY :passthrough event is consulted
  # for the expansion's own small key vocabulary (scroll/dismiss) instead
  # of reaching the Composer -- mutually exclusive with the overlay clause
  # above (`expand_focused_diff/1` refuses while an overlay is open, and
  # `open_overlay/3` refuses while an expansion is open), so relative
  # clause order between the two is incidental.
  defp route_passthrough(%{expansion: expansion} = model, norm, _raw_event)
       when expansion != nil do
    cond do
      InputEvent.printable_char(norm) == "j" or InputEvent.key(norm) == :down ->
        %{model | expansion: DiffExpansion.scroll(expansion, 1)}

      InputEvent.printable_char(norm) == "k" or InputEvent.key(norm) == :up ->
        %{model | expansion: DiffExpansion.scroll(expansion, -1)}

      InputEvent.printable_char(norm) == "q" ->
        close_expansion(model)

      true ->
        model
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

  # A live `command_sink` makes `:submit` a first-class command: the
  # prompt crosses to the agent lane through the SAME sink `:interrupt`/
  # `:steer` use, and the surface enters an optimistic "sending" state
  # (`pending_submit`, rendered dim -- see `submitting_lines/1`) WITHOUT
  # echoing anything into history. The echo is event-observed: only when
  # the lane's `:turn_started` lands does `submit_accepted/1` seal the
  # `❯ prompt` line (see that function). The Composer already cleared its
  # own buffer on Enter (`Composer.submit/2`), so the draft now lives in
  # `pending_submit` until it is either sealed (accept) or restored
  # (`submit_refused/1`). An empty/whitespace submit is a no-op -- there
  # is no prompt to send and nothing to echo.
  defp apply_composer_command(
         {:component_event, _id, {:submit, text}},
         %{command_sink: sink} = model
       )
       when is_function(sink, 1) do
    if String.trim(text) == "" do
      model
    else
      sink.(%{type: :submit, payload: %{text: text}})
      %{model | pending_submit: %{text: text}}
    end
  end

  # Fixture/stub mode (no live lane): keep the honest, visibly-labeled
  # stub notice -- byte-for-byte unchanged from before the live seam
  # existed (the "stub mode unchanged bytes" invariant).
  defp apply_composer_command({:component_event, _id, {:submit, text}}, model) do
    %{model | stub_notice: "» (stub) would send prompt: #{text}"}
  end

  defp apply_composer_command(_command, model), do: model

  # Must precede the plain :overlay_dismiss clause below: while an
  # expansion is open, ESC (resolved by Keymap's :overlay guard, which
  # reads the SAME overlay_open? context flag an open overlay sets --
  # see handle_input/2's moduledoc) closes the EXPANSION, not a
  # (necessarily absent, since the two refuse each other) overlay.
  defp dispatch_command(%{expansion: expansion} = model, %{
         type: :overlay_dismiss
       })
       when expansion != nil,
       do: close_expansion(model)

  defp dispatch_command(model, %{type: :overlay_dismiss}),
    do: close_overlay(model)

  # The command's own payload is the honored target -- NOT a second read
  # of `model.focused_index` here. Both producers (a live keypress
  # resolved by `Keymap.resolve/2` in `handle_input/2`, and a palette
  # pick via `Keymap.command_for/2` in `palette_command/2`) thread
  # `context.focused_block_id` into `payload.block_id` from the SAME
  # `keymap_context/1` construction, so consuming the payload keeps
  # exactly one producer chain (context -> payload -> here). A second
  # model read at dispatch time was the adversarial review's named
  # decoupling hazard (2026-07-17, MEDIUM): a value the tests pinned but
  # nothing consumed. `:expand_diff` carries the identical payload shape
  # and honors it the same way.
  defp dispatch_command(model, %{type: :expand_diff, payload: payload}),
    do: apply_expand(model, Map.get(payload, :block_id))

  defp dispatch_command(model, %{type: :fold_toggle, payload: payload}) do
    apply_fold_toggle(model, Map.get(payload, :block_id))
  end

  defp dispatch_command(model, %{type: :jump_next}), do: move_focus(model, 1)
  defp dispatch_command(model, %{type: :jump_prev}), do: move_focus(model, -1)

  # Live command_sink: dispatch and leave the model otherwise unchanged --
  # no stub notice (the embedder owns pending/ack rendering via
  # `put_lane_notice/2`; the real acknowledgment is event-observed, see
  # `Raxol.Harness.SessionLane`'s moduledoc). Must precede the plain
  # stub clause below, which stays as the `command_sink == nil` fallback.
  defp dispatch_command(%{command_sink: sink} = model, %{type: :interrupt})
       when is_function(sink, 1) do
    sink.(%{type: :interrupt, payload: %{}})
    model
  end

  defp dispatch_command(model, %{type: :interrupt}) do
    %{model | stub_notice: @stub_interrupt_notice}
  end

  # Live command_sink: answer the pending approval. The keymap emits only
  # an ANSWER HINT (`:allow`/`:deny`/`{:option, i}`) -- this clause
  # resolves it against the live block's ACTUAL options into a concrete
  # `option_id` (the referent the agent parked), then hands
  # `{request_id, option_id, decision}` to the sink. The real seal is
  # event-observed: the agent lane replies to ACP and emits the
  # `approval_decided` event that folds the receipt into this block and
  # releases the frontier (see `Raxol.Harness.Projection.BlockBuilder`).
  # A hint that resolves to nothing (no live question, or an option index
  # past the list) never reaches the sink -- it becomes an honest refusal
  # notice, so a stray key can never fire a phantom decision at the agent.
  defp dispatch_command(%{command_sink: sink} = model, %{
         type: :approval_answer,
         payload: payload
       })
       when is_function(sink, 1) do
    case resolve_approval_answer(model, Map.get(payload, :answer)) do
      {:ok, answer} ->
        # Dispatch and leave the model otherwise unchanged -- the embedder
        # owns the sent/failed notice (driver's `:approval_answer` handler)
        # and the real acknowledgment is event-observed (the
        # `approval_decided` event seals the block), exactly as `:interrupt`
        # above. A surface-side refusal below is the one thing the embedder
        # cannot know, so only that path sets a notice here.
        sink.(%{type: :approval_answer, payload: answer})
        model

      {:error, reason} ->
        put_lane_notice(model, approval_refusal_notice(reason))
    end
  end

  defp dispatch_command(model, %{type: :approval_answer}) do
    %{model | stub_notice: @stub_approval_notice}
  end

  # Only the `:always` Ctrl+P chord can ever fire this clause with an
  # overlay already open -- `g`/`s` are already suppressed by their own
  # `:not_composing` guard's `overlay_open?` check (see `Keymap`'s
  # moduledoc), so they never reach `dispatch_command/2` at all while a
  # picker is open. Clause order load-bearing, same reason as the
  # `:steer`/`:edit_draft` overlay guards below: this must precede the
  # plain `:open_palette` clause.
  defp dispatch_command(%{overlay: overlay} = model, %{type: :open_palette})
       when overlay != nil,
       do: picker_refusal(model, :overlay_already_open)

  # An open diff expansion blocks the palette the same way an open
  # overlay does (Ctrl+P is `:always`, so the keymap guard never
  # suppresses it): the footer is expansion-shaped, and the two transient
  # footer views never coexist -- `open_overlay/3` would refuse with
  # `:expansion_open` anyway; refusing HERE gives the same honest notice
  # channel the overlay-already-open case uses.
  defp dispatch_command(%{expansion: expansion} = model, %{
         type: :open_palette
       })
       when expansion != nil,
       do: picker_refusal(model, :expansion_open)

  defp dispatch_command(model, %{type: :open_palette}),
    do: open_command_palette(model)

  defp dispatch_command(model, %{type: :open_jump_picker}),
    do: open_jump_picker(model)

  defp dispatch_command(model, %{type: :open_session_picker}),
    do: open_session_picker(model)

  # `handle_open_result/2` already routes an `open_panel/3` refusal
  # through `picker_refusal/2` -- panels reuse it verbatim, same honest
  # refusal vocabulary as the pickers above.
  defp dispatch_command(model, %{type: :open_panel, payload: %{panel: kind}}) do
    model |> open_panel(kind) |> handle_open_result(model)
  end

  defp dispatch_command(model, %{type: :open_search_picker}),
    do: open_search_picker(model)

  defp dispatch_command(model, %{type: :focus_transcript}),
    do: focus_transcript(model)

  defp dispatch_command(model, %{type: :focus_composer}),
    do: focus_composer(model)

  # Same freeze rationale as the overlay clauses below, for an open diff
  # expansion: the composer/transcript state behind a full-screen diff is
  # hidden, so queuing a steer built from it would be dishonest UI. These
  # two clauses MUST precede the general `:steer`/`:edit_draft` clauses
  # (function-clause order load-bearing, same as the overlay pair) --
  # relative order between the expansion and overlay freeze clauses is
  # incidental, since the two refuse each other and can never both be
  # open at once.
  defp dispatch_command(%{expansion: expansion} = model, %{type: :steer})
       when expansion != nil,
       do: model

  defp dispatch_command(%{expansion: expansion} = model, %{type: :edit_draft})
       when expansion != nil,
       do: model

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

  # Live command_sink: the SAME queued-steer banner the stub clause below
  # builds (that UI is real and correct on its own) PLUS the sink
  # dispatch. Must come after the overlay-open clause above (overlay
  # freeze wins) but before the plain stub clause, which stays as the
  # `command_sink == nil` fallback.
  defp dispatch_command(%{command_sink: sink} = model, %{type: :steer})
       when is_function(sink, 1) do
    text = Composer.value(model.composer)

    composer =
      Composer.update(
        {:set_queued_steer, %{text: text, queued_at: model.revealed}},
        model.composer
      )
      |> elem(0)

    sink.(%{type: :steer, payload: %{text: text}})
    %{model | composer: composer}
  end

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

  # -- scrollback (the :full_viewport window; inert elsewhere) --------------

  # PgUp/PgDn/End/G drive the owned virtual scrollback in `:full_viewport`.
  # In every inline/flat tier they are inert: those tiers print history
  # into the terminal, so scrollback is the TERMINAL's own (mouse/native),
  # never the harness's to move.
  defp dispatch_command(%{mode: :full_viewport} = model, %{type: :scroll_up}),
    do: scroll_page(model, :up)

  defp dispatch_command(%{mode: :full_viewport} = model, %{type: :scroll_down}),
    do: scroll_page(model, :down)

  defp dispatch_command(%{mode: :full_viewport} = model, %{
         type: :scroll_to_tail
       }),
       do: %{model | scroll_anchor: :tail}

  defp dispatch_command(model, %{type: type})
       when type in [:scroll_up, :scroll_down, :scroll_to_tail],
       do: model

  defp dispatch_command(model, _other), do: model

  # Moves the scroll window one page (`transcript_h - 1` lines) up or down.
  # `:up` off the tail pins a concrete bottom index (the scroll-anchor:
  # new content will not yank it); reaching the tail again normalizes back
  # to `:tail`. A no-op when the whole transcript already fits.
  defp scroll_page(model, dir) do
    {transcript_h, total} = viewport_scroll_geometry(model)

    if total <= transcript_h do
      %{model | scroll_anchor: :tail}
    else
      page = max(transcript_h - 1, 1)

      current =
        case model.scroll_anchor do
          :tail -> total
          n when is_integer(n) -> n |> max(transcript_h) |> min(total)
        end

      new_bottom =
        case dir do
          :up -> max(current - page, transcript_h)
          :down -> min(current + page, total)
        end

      anchor = if new_bottom >= total, do: :tail, else: new_bottom
      %{model | scroll_anchor: anchor}
    end
  end

  # The transcript window height and total line count, recomputed the same
  # way `paint_viewport/1` does (footer fit -> rows above it), so scroll
  # math and paint never disagree about the window.
  defp viewport_scroll_geometry(model) do
    {footer_lines, _cursor} = footer_frame(model)
    transcript_h = max(model.rows - length(footer_lines), 0)
    total = length(viewport_transcript_lines(model))
    {transcript_h, total}
  end

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
    seal_flat_notice(
      model,
      "» external editor requires the footer composer (flat mode)"
    )
  end

  # The external-editor handoff is not wired for `:full_viewport` v1: the
  # `$EDITOR` suspend/resume bracket emits the INLINE substrate's
  # DECSTBM-release bytes (`EditorSuspend`), which would corrupt the
  # alternate screen. Honest stub notice rather than a corrupted frame;
  # bracketing the editor with an alt-screen leave/re-enter is a follow-up.
  defp run_editor(%{mode: :full_viewport} = model) do
    %{model | stub_notice: "» external editor not wired in full-viewport mode"}
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

  # No focused block -- honest refusal, never a silent no-op. Reachable
  # from a keypress (`z` in transcript-browse before any `j`/`k`) and,
  # more prominently, from a palette pick of "toggle fold" mid-compose
  # (the `:always` Ctrl+P chord makes the `:not_composing` binds
  # pickable in states their keypress guard would never allow) -- the
  # adversarial review's silent-no-op finding. Same one-frame notice
  # mechanism as the sealed-block refusal below.
  defp apply_fold_toggle(model, nil) do
    %{model | stub_notice: "» no block focused — jump to a block first (g)"}
  end

  # The sealed?/unsealed? split below goes through `block_sealed?/2` --
  # the SAME predicate that feeds the frontier classifier's `committed?`
  # flag (see `frontier_entries/1`) -- so the fill-guard's boundary and
  # the classifier's can never disagree by construction.
  defp apply_fold_toggle(model, index) when is_integer(index) do
    if block_sealed?(model, index) do
      sealed_fold_refusal(model, index)
    else
      store_fold_override(model, index)
    end
  end

  defp sealed_fold_refusal(model, index) do
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

  defp store_fold_override(model, index) do
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

      # Load-bearing identity: `UnreadDivider`'s boundary is a block
      # COUNT (sampled from `length(projection.blocks)`), while `next`
      # is a 0-based block INDEX -- "count of seen blocks == index of
      # the first unseen block" holds precisely because `focused_index`
      # is 0-based over a densely-indexed block list. A move to 1-based
      # focus or sparse block ids must revisit this comparison.
      %{
        model
        | focused_index: next,
          unread: UnreadDivider.viewed(model.unread, next)
      }
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

  # The offset the unread-divider policy is a pure function of: the
  # count of already-committed blocks (see `UnreadDivider`'s "offsets,
  # not clocks" doc). Blocks, not events -- the divider marks completed
  # content, not raw fixture traffic.
  defp unread_offset(model), do: length(model.projection.blocks)

  # Reconciles the unread-divider state against the just-rebuilt
  # projection (`UnreadDivider.reconcile/2`, retire-only -- counts are
  # clamped at display time by `divider/2`, never into state) --
  # `advance/2` is the only place `projection.blocks` is ever replaced,
  # so threading here means a shrunken rebuild can never leave a stuck
  # span whose boundary no navigation index can reach. A no-op under
  # fixture mode's monotone growth (every existing suite proves that);
  # it exists for the replay/reattach shapes a future producer can hit.
  defp reconcile_unread(model) do
    %{
      model
      | unread: UnreadDivider.reconcile(model.unread, unread_offset(model))
    }
  end

  @doc """
  Records that the operator has looked away, for the unread-divider
  policy (`Raxol.Harness.UnreadDivider.blur/2`). This is the explicit
  attention API a later focus-event unit (a real terminal focus-out
  signal) wires directly -- see `UnreadDivider`'s "mode-1004 seam" doc.
  No production caller exists yet (the divider is dormant at runtime
  until that unit lands); tests and future drivers invoke this
  directly, same as `focus_transcript/1`.
  A no-op in `:flat` mode's own honest sense: `paint_footer/1` never
  repaints there, so nothing visibly changes, but the policy state
  itself still tracks the boundary (harmless, since flat mode has no
  footer for a divider to ever reach).
  """
  @spec blur(t()) :: t()
  def blur(model) do
    %{model | unread: UnreadDivider.blur(model.unread, unread_offset(model))}
    |> paint_footer()
  end

  @doc """
  Records that the operator has returned, for the unread-divider policy
  (`Raxol.Harness.UnreadDivider.focus/2`). See `blur/1`'s doc and
  `UnreadDivider`'s "mode-1004 seam".
  """
  @spec focus(t()) :: t()
  def focus(model) do
    %{model | unread: UnreadDivider.focus(model.unread, unread_offset(model))}
    |> paint_footer()
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

    * `{:error, :expansion_open}` -- a diff expansion (see
      `expand_focused_diff/1`) is already claiming the footer; the two
      transient footer views never coexist.
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
             :expansion_open
             | :overlay_already_open
             | :no_footer
             | :insufficient_footer_capacity}
  def open_overlay(model, items, opts \\ [])

  def open_overlay(%{expansion: expansion}, _items, _opts)
      when expansion != nil,
      do: {:error, :expansion_open}

  def open_overlay(%{overlay: overlay}, _items, _opts) when overlay != nil,
    do: {:error, :overlay_already_open}

  def open_overlay(%{mode: :flat}, _items, _opts), do: {:error, :no_footer}

  # `:full_viewport` v1 gates the footer-GROWING transient claims
  # (overlay pickers, panels, diff expansion): they grow the inline
  # DECSTBM region via `InlineAuthority.set_footer_rows/2`, which the
  # alternate-screen authority does not implement. Honest refusal (routed
  # to `picker_refusal/2`'s notice) rather than a crash; re-homing the
  # claim into the model-owned footer height is a follow-up.
  def open_overlay(%{mode: :full_viewport}, _items, _opts),
    do: {:error, :no_footer}

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
        overlay = %{mod: OverlayPicker, picker: picker, on_pick: on_pick}
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

  # -- projection panels (see the moduledoc's "Projection panels" section) -

  @doc """
  Opens a read-only projection panel (`kind`: `:worktracks`, `:memory`, or
  `:plan`) over the same hosted-overlay footer slot `open_overlay/3` uses --
  growing the footer viewport by `Raxol.UI.Harness.OverlayPanel.height/1`
  rows and repainting immediately. Summon shows the LIVE projection: the
  panel's initial content is `Raxol.Harness.PanelProjection.render_lines/2`
  folded over `model.projection.source_events` (the retained *durable*
  meta events) at the moment of opening, not a stale snapshot.

  Dismissal (`close_overlay/1`, same as any other hosted overlay) discards
  only UI-local state -- scroll offset, claimed footer rows. The fold
  source is the projection's retained events, so re-summoning a panel
  folds current state without ever touching the block projection itself
  (see `PanelProjection`'s moduledoc, "Recompute, not incrementally
  cached").

  ## Options

    * `:max_visible` (default `OverlayPanel.default_max_visible/0`) --
      clamped to the available footer capacity, same narrowing rule
      `open_overlay/3` applies (a taller request is narrowed, never
      refused).

  ## Errors

  Identical refusal ladder to `open_overlay/3`:
  `{:error, :overlay_already_open}`, `{:error, :no_footer}` (`:flat`
  mode), `{:error, :insufficient_footer_capacity}`. Zero bytes written,
  model untouched on every refusal.
  """
  @spec open_panel(t(), PanelProjection.kind(), keyword()) ::
          {:ok, t()}
          | {:error,
             :overlay_already_open | :no_footer | :insufficient_footer_capacity}
  def open_panel(model, kind, opts \\ [])

  def open_panel(%{overlay: overlay}, _kind, _opts) when overlay != nil,
    do: {:error, :overlay_already_open}

  def open_panel(%{mode: :flat}, _kind, _opts), do: {:error, :no_footer}

  # See `open_overlay/3`'s `:full_viewport` clause -- panels grow the same
  # inline region and are gated the same way in this mode.
  def open_panel(%{mode: :full_viewport}, _kind, _opts),
    do: {:error, :no_footer}

  def open_panel(model, kind, opts) do
    max_overlay_rows = max_overlay_rows(model.rows, model.footer_rows)

    if max_overlay_rows < 2 or degenerate?(model) do
      {:error, :insufficient_footer_capacity}
    else
      do_open_panel(model, kind, opts, max_overlay_rows)
    end
  end

  defp do_open_panel(model, kind, opts, max_overlay_rows) do
    max_visible =
      min(
        Keyword.get(opts, :max_visible, OverlayPanel.default_max_visible()),
        # reserve one row for the panel title (OverlayPanel.height/1 is
        # `1 + max_visible`), same idiom as the picker path's own `- 1`.
        max_overlay_rows - 1
      )

    panel =
      OverlayPanel.new(kind: kind, max_visible: max_visible)
      |> OverlayPanel.put_lines(
        PanelProjection.render_lines(kind, model.projection.source_events)
      )

    claimed_rows = OverlayPanel.height(panel)

    case InlineAuthority.set_footer_rows(
           model.authority,
           model.footer_rows + claimed_rows
         ) do
      {:ok, authority} ->
        # A panel never produces {:picked, _} (see OverlayPanel's
        # moduledoc) -- `on_pick` here is shape-compat filler only, never
        # actually invoked.
        #
        # `folded_at` is the memoization token for `refresh_panel_overlay/1`
        # (M2): the count of `source_events` the panel content was last
        # folded over. source_events is append-only within a session (a ref
        # is a journal offset; the journal never mutates or shrinks), so an
        # unchanged count means an identical fold -- a pure scroll key (which
        # never grows the journal) then skips the whole re-fold.
        overlay = %{
          mod: OverlayPanel,
          picker: panel,
          on_pick: fn m, _item -> m end,
          folded_at: length(model.projection.source_events)
        }

        model = %{model | authority: authority, overlay: overlay}
        {:ok, paint_footer(model)}

      # Unreachable given the capacity check above (belt and braces), same
      # reasoning as `do_open_overlay/4`'s own unreachable clause.
      {:error, :degenerate} ->
        {:error, :insufficient_footer_capacity}
    end
  end

  # -- pickers (command palette, jump, session, search) ---------------------
  # See the moduledoc's "The pickers" section.

  @doc """
  Opens the command palette (Ctrl+P): one entry per `Keymap.palette_binds/0`
  label, plus two surface-local commands (`focus transcript`, `focus
  composer`) that exist only at this assembly layer. Picking an entry
  dispatches through the exact same `dispatch_command/2` path a keypress
  takes -- no parallel execution mechanism. Uses
  `OverlayPicker.fuzzy_filter/3` as its `filter_fn`. Refusals (a picker
  already open, insufficient geometry, flat mode) surface as an honest
  notice via `picker_refusal/2`, same as `open_overlay/3`'s other callers.

  Because the Ctrl+P chord is `:always`, entries whose keypress guard is
  `:not_composing` become pickable in states the guard would never allow
  -- an entry that is inapplicable in the current state (e.g. "toggle
  fold" with no focused block) refuses with an honest one-frame notice
  rather than silently doing nothing (see `apply_fold_toggle/2`'s
  nil-target clause and the covering "no focused block" tests in
  `command_palette_surface_test.exs`).
  """
  @spec open_command_palette(t()) :: t()
  def open_command_palette(model) do
    items =
      Enum.map(
        Keymap.palette_binds(),
        &%{label: &1.label, command: {:bind, &1}}
      ) ++
        [
          %{
            label: "focus transcript",
            command: {:command, %{type: :focus_transcript, payload: %{}}}
          },
          %{
            label: "focus composer",
            command: {:command, %{type: :focus_composer, payload: %{}}}
          }
        ]

    model
    |> open_overlay(items,
      label_fn: & &1.label,
      filter_fn: &OverlayPicker.fuzzy_filter/3,
      title: "commands",
      on_pick: fn model, item ->
        dispatch_command(model, palette_command(model, item.command))
      end
    )
    |> handle_open_result(model)
  end

  # A surface-local command (`{:command, cmd}`) is already the command
  # `dispatch_command/2` expects; a bind reference (`{:bind, bind}`) goes
  # through `Keymap.command_for/2` with the SAME context
  # `handle_input/2`'s own keypress path builds (`keymap_context/1`) --
  # one construction, so a palette pick and a live keypress can never
  # resolve a bind differently.
  defp palette_command(_model, {:command, cmd}), do: cmd

  defp palette_command(model, {:bind, bind}),
    do: Keymap.command_for(bind, keymap_context(model))

  @doc """
  Opens the jump-to-block picker (`g`, transcript-browse only): one entry
  per projected block, labeled `"<kind> · <summary>"` (`Block.summary/1`).
  Picking an entry sets `focused_index`. An empty block list is an honest
  no-op notice rather than an empty overlay.
  """
  @spec open_jump_picker(t()) :: t()
  def open_jump_picker(%{projection: %{blocks: []}} = model) do
    %{model | stub_notice: "» no blocks to jump to"}
  end

  def open_jump_picker(model) do
    items =
      model.projection.blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        # No truncation here -- `ViewText.lines/3` is the one truncation
        # trust boundary (see this module's moduledoc); this hands it the
        # full, untruncated label.
        %{index: index, label: "#{block.kind} · #{Block.summary(block)}"}
      end)

    model
    |> open_overlay(items,
      label_fn: & &1.label,
      filter_fn: &OverlayPicker.fuzzy_filter/3,
      title: "jump",
      on_pick: fn model, item -> %{model | focused_index: item.index} end
    )
    |> handle_open_result(model)
  end

  @doc """
  Opens the transcript search picker (`/`, transcript-browse only): one
  entry per projected block, labeled from `Block.search_text/1` (the
  full content-derived search corpus, not just `Block.summary/1`'s
  header line) -- the overlay's fuzzy filter over these labels IS the
  search: it reaches into block BODIES, not just headers. Picking an
  entry sets `focused_index`, exactly like `open_jump_picker/1`. An
  empty block list is an honest no-op notice rather than an empty
  overlay.

  ## The label clamp (bounded WORK on the input path)

  `Raxol.UI.Harness.OverlayPicker`'s fuzzy ranker runs synchronously,
  per keystroke, over every label's `label_fn` output -- this Surface is
  a synchronous pure state machine (fixture mode has no other thread to
  move the work to), and a block body is unbounded, untrusted content
  (a fixture's tool-call output, an LLM's streamed response). So each
  block's search corpus is clamped to #{@search_label_cap} graphemes
  via `Block.search_text/2`, which applies the clamp AT THE SOURCE --
  every body field is bounded to the cap BEFORE it is concatenated,
  joined, or newline-flattened, and `String.slice/3` walks at most that
  many graphemes and stops. So `open_search_picker/1` does O(cap) work
  per block, not O(body-size): the clamp bounds the WORK, not merely the
  label output. (An earlier revision clamped only the flattened result,
  which bounded the output while the concat + flatten still scanned the
  whole untrusted body -- fixed by pushing the clamp into
  `Block.search_text/2`.) This is the per-label GRAPHEME-length axis;
  the entry-COUNT axis is left uncapped here, matching the accepted
  `open_jump_picker/1` precedent (see "No entry cap" below). The named,
  honest consequence: body content past the cap is not searchable.

  ## No entry cap (unlike `open_session_picker/1`)

  `open_search_picker/1` builds one item per block with no ceiling,
  unlike `open_session_picker/1`'s `@session_picker_cap` entry cap. This
  mirrors `open_jump_picker/1` (also uncapped) and is deliberate: an
  entry cap would silently drop blocks OUT of search, making a block
  unfindable -- a correctness regression, not a safety win. With the
  per-item work now bounded (see the label clamp above), a single
  keystroke's ranking is near-linear in `entries x cap`, the same
  envelope the accepted jump picker already runs in.

  ## Why every label is `kind · summary`, not "the matching line"

  `OverlayPicker`'s `label_fn` is static: it is both the search key AND
  the rendered row, and it never sees the live query as the operator
  types -- so a label that shows "the first line that matched" is
  structurally impossible for this primitive (there is no query yet at
  label-construction time, and the query changes every keystroke without
  the labels being rebuilt). Every label is instead `Block.search_text/2`
  itself (kind-prefixed, source-clamped, newline-flattened) -- the visible,
  width-truncated HEAD of each row (`"<kind> · <summary>"`) always
  identifies the block even when the actual match sits deep in an
  unfolded body line, and picking still jumps focus to the real content
  underneath. Display-width truncation (CJK-aware) happens exactly once,
  in `Raxol.Harness.Surface.ViewText.lines/3` -- this function hands the
  picker full (already-clamped) labels, same as `open_jump_picker/1`.
  """
  @spec open_search_picker(t()) :: t()
  def open_search_picker(%{projection: %{blocks: []}} = model) do
    %{model | stub_notice: "» no blocks to search"}
  end

  def open_search_picker(model) do
    items =
      model.projection.blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        %{index: index, label: search_label(block)}
      end)

    model
    |> open_overlay(items,
      label_fn: & &1.label,
      filter_fn: &OverlayPicker.fuzzy_filter/3,
      title: "search",
      on_pick: fn model, item -> %{model | focused_index: item.index} end
    )
    |> handle_open_result(model)
  end

  # `Block.search_text/2` bounds the WORK, not just the output: it clamps
  # every untrusted body field to `@search_label_cap` graphemes at the
  # source, so the corpus it returns is already <= the cap and the
  # newline-flatten below (same reason `OverlayPicker.render/1` flattens
  # every label: one item must always be one footer row) runs over a
  # bounded string, never over the full body. The flatten only shortens
  # (`\r\n` -> one space), so the result stays <= the cap -- no second
  # slice needed here.
  defp search_label(block) do
    block
    |> Block.search_text(@search_label_cap)
    |> String.replace(["\r\n", "\n", "\r"], " ")
  end

  @doc """
  Opens the session picker (`s`, transcript-browse only): one entry per
  `.jsonl` fixture in `model.sessions_dir` (see `list_fixture_sessions/1`).
  Picking a name loads it (`Raxol.Harness.Fixture.load/1`) and switches to
  it via `switch_session/2` -- see the moduledoc's session-switch
  semantics. An empty directory listing is an honest no-op notice rather
  than an empty overlay; a load failure surfaces its `DecodeError` reason
  instead of switching.

  ## Listing cap (bounded work on the input path)

  `sessions_dir` is a public option and both the `File.ls/1` listing and
  the per-keystroke fuzzy ranking run synchronously on the input path --
  this Surface is a synchronous pure state machine by design (fixture
  mode has no other thread to move them to). So the listing is CAPPED at
  #{@session_picker_cap} entries (sorted order, first #{@session_picker_cap}
  kept), and the truncation is named in the picker title
  (`"session — first N of M"`), never silent. `Fixture.load/1` on pick is
  likewise synchronous and whole-file; fixture sessions are small by
  construction, and a pathological file pauses the loop for the load
  rather than crashing anything -- documented, not hidden.
  """
  @spec open_session_picker(t()) :: t()
  def open_session_picker(model) do
    case list_fixture_sessions(model.sessions_dir) do
      [] ->
        %{
          model
          | stub_notice: "» no fixture sessions found in #{model.sessions_dir}"
        }

      names ->
        {names, title} = cap_session_names(names)

        model
        |> open_overlay(names,
          filter_fn: &OverlayPicker.fuzzy_filter/3,
          title: title,
          on_pick: &pick_session/2
        )
        |> handle_open_result(model)
    end
  end

  defp cap_session_names(names) when length(names) > @session_picker_cap do
    {Enum.take(names, @session_picker_cap),
     "session — first #{@session_picker_cap} of #{length(names)}"}
  end

  defp cap_session_names(names), do: {names, "session"}

  defp pick_session(model, name) do
    path = Path.join(model.sessions_dir, name <> ".jsonl")

    case Fixture.load(path) do
      {:ok, session} ->
        model
        |> switch_session(session)
        |> Map.put(
          :stub_notice,
          "» switched to session #{name} — previous history stays sealed above"
        )

      {:error, error} ->
        %{
          model
          | stub_notice:
              "» could not load session #{name}: #{inspect(error.reason)}"
        }
    end
  end

  @doc """
  Lists fixture session names available under `dir` -- the `.jsonl` files
  (suffix stripped, sorted) `open_session_picker/1` reads. `{:error, _}`
  from `File.ls/1` (missing/unreadable directory) yields `[]`, the same
  "nothing to pick" shape an empty directory produces.
  """
  @spec list_fixture_sessions(Path.t()) :: [String.t()]
  def list_fixture_sessions(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&String.replace_suffix(&1, ".jsonl", ""))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Switches the active session to `session_or_events` (see the moduledoc's
  "The pickers" section for the print-once semantics this implements):
  `authority`/`composer`/`mode`/geometry (`width`/`rows`)/`footer_rows`/
  `sessions_dir`/`editor_session`/`editor_opts` are left untouched --
  sealed history above is never touched by this function at all, which is
  the whole point. Replay state resets (`events`, `revealed`,
  `projection`, `painted_count`, `fold_overrides`, `focused_index`,
  `status`) so the new session starts its own fresh reveal. Does NOT paint
  by itself -- the caller's trailing `paint_footer/1` (in
  `handle_input/2`) covers the footer.
  """
  @spec switch_session(t(), Session.t() | [map()]) :: t()
  def switch_session(model, session_or_events) do
    %{
      model
      | events: events_from(session_or_events),
        revealed: 0,
        projection: Projection.project([], fold_defaults: model.fold_defaults),
        painted_count: 0,
        fold_overrides: %{},
        focused_index: nil,
        status: %{}
    }
  end

  # `open_overlay/3`'s `{:ok, model}` / `{:error, reason}` result, uniform
  # across all three pickers above: succeed with the opened model, or
  # route the refusal reason through `picker_refusal/2` against the
  # PRE-open model (the `{:error, _}` branch never touches the authority,
  # so `original_model` and the `open_overlay/3` input are the same value
  # -- named separately only for clarity at each call site).
  defp handle_open_result({:ok, model}, _original_model), do: model

  defp handle_open_result({:error, reason}, original_model),
    do: picker_refusal(original_model, reason)

  # Routes an `open_overlay/3` refusal to an honest, one-frame notice
  # (`:insufficient_footer_capacity`/`:overlay_already_open`) or, for
  # `:no_footer` (flat mode has no footer to grow at all), seals ONE
  # honest history line through the same `FlatAuthority.seal/2` path
  # `apply_mode_notice/2`'s flat clause uses (see `seal_flat_notice/2`).
  defp picker_refusal(model, :insufficient_footer_capacity) do
    %{model | stub_notice: "» picker needs more rows — terminal too small"}
  end

  defp picker_refusal(model, :overlay_already_open) do
    %{model | stub_notice: "» a picker is already open"}
  end

  # A diff expansion claims the footer the same way an open picker does
  # (the two transient footer views never coexist) -- same honest-notice
  # channel, named for what is actually in the way.
  defp picker_refusal(model, :expansion_open) do
    %{model | stub_notice: "» a diff expansion is open — dismiss it first"}
  end

  defp picker_refusal(model, :no_footer) do
    seal_flat_notice(model, "» pickers require the footer (flat mode)")
  end

  # -- diff expansion (see the moduledoc's "Full-screen diff expansion" section) --

  @doc """
  Expands the currently focused block full-screen, when it is a `:diff`
  block, by growing the DECSTBM footer to the largest non-degenerate
  claim (history keeps its 2-row minimum -- `max_overlay_rows/2`, the
  SAME helper `open_overlay/3` uses, one source of truth) and hosting a
  `Raxol.Harness.DiffExpansion` scrollable window inside it. See the
  moduledoc's "Full-screen diff expansion (footer maximization)" section
  for the mechanism ruling.

  Refuses, in order (each refusal: zero bytes written, model untouched):

    * `{:error, :expansion_already_open}` -- `model.expansion` is already
      set.
    * `{:error, :overlay_open}` -- an overlay picker is open (the two
      transient footer views never coexist).
    * `{:error, :no_footer}` -- `model.mode == :flat` (nothing to grow).
    * `{:error, :no_focus}` -- `model.focused_index` is `nil`.
    * `{:error, :not_a_diff}` -- the focused block does not exist, or its
      `kind` is not `:diff`.
    * `{:error, :insufficient_footer_capacity}` -- the current geometry
      cannot keep history's 2-row minimum AND host at least a 2-row
      expansion (one status row and one expansion header row, per the
      moduledoc's arithmetic).
    * `{:error, {:invalid_content, reason}}` -- the focused block's
      content map fails `Raxol.UI.Components.Harness.BodyProvider`'s
      `:diff` schema (`DiffExpansion.new/2`'s own validation, consulted
      BEFORE any row is claimed -- a content error never grows the
      footer).
  """
  @spec expand_focused_diff(t()) ::
          {:ok, t()}
          | {:error,
             :expansion_already_open
             | :overlay_open
             | :no_footer
             | :no_focus
             | :not_a_diff
             | :insufficient_footer_capacity
             | {:invalid_content, String.t()}}
  def expand_focused_diff(model),
    do: expand_block_at(model, model.focused_index)

  # The parameterized ladder both producers share: the public
  # `expand_focused_diff/1` reads `model.focused_index`; the
  # `:expand_diff` command dispatch threads `payload.block_id` instead
  # (the one-producer-chain rule -- see `dispatch_command/2`'s
  # payload-honoring comment). Both values originate from the same
  # `keymap_context/1` construction, so the ladders can never disagree;
  # parameterizing keeps that a structural fact instead of a coincidence.
  defp expand_block_at(%{expansion: expansion}, _index) when expansion != nil,
    do: {:error, :expansion_already_open}

  defp expand_block_at(%{overlay: overlay}, _index) when overlay != nil,
    do: {:error, :overlay_open}

  defp expand_block_at(%{mode: :flat}, _index), do: {:error, :no_footer}

  # See `open_overlay/3`'s `:full_viewport` clause -- the full-screen diff
  # expansion grows the same inline region and is gated the same way here.
  defp expand_block_at(%{mode: :full_viewport}, _index),
    do: {:error, :no_footer}

  defp expand_block_at(_model, nil), do: {:error, :no_focus}

  defp expand_block_at(model, index) do
    case Enum.at(model.projection.blocks, index) do
      %{kind: :diff} = block -> do_expand(model, block)
      _not_a_diff_or_missing -> {:error, :not_a_diff}
    end
  end

  # The grown footer's top two rows are chrome the expansion always
  # reserves: one status row plus one expansion header row (the file
  # path + scroll position line `DiffExpansion.render_lines/1` prepends).
  # Everything below them is scrollable content, so the content viewport
  # is `total_footer - @expansion_chrome_rows`. Named once and derived
  # through `expansion_view_rows/2` so the `build_expansion/3` open path
  # and the `resize_expansion/3` re-grow path can never drift apart.
  # NOTE: distinct from the `claim < 2` gate below (that `2` is a minimum
  # footer GROWTH, not this chrome subtraction -- see `do_expand/2`) and
  # from `DiffExpansion`'s own `@gutter_width 2` (a per-row column count).
  @expansion_chrome_rows 2

  defp expansion_view_rows(footer_rows, claim),
    do: footer_rows + claim - @expansion_chrome_rows

  defp do_expand(model, block) do
    claim = max_overlay_rows(model.rows, model.footer_rows)

    # `claim` is the footer GROWTH beyond the base `model.footer_rows`
    # that still leaves history its 2-row minimum (what
    # `max_overlay_rows/2` maximizes). A growth below 2 cannot host the
    # expansion's own two chrome rows, so refuse with the honest notice
    # rather than open a viewport with no room for content.
    if claim < 2 or degenerate?(model) do
      {:error, :insufficient_footer_capacity}
    else
      build_expansion(model, block, claim)
    end
  end

  # `DiffExpansion.new/2` (pure, no IO) runs BEFORE `set_footer_rows/2`
  # ever touches the authority -- a content-validation error propagates
  # with zero bytes written, exactly like every other refusal above.
  defp build_expansion(model, block, claim) do
    view_rows = expansion_view_rows(model.footer_rows, claim)

    case DiffExpansion.new(block.content,
           width: model.width,
           view_rows: view_rows
         ) do
      {:ok, expansion} ->
        case InlineAuthority.set_footer_rows(
               model.authority,
               model.footer_rows + claim
             ) do
          {:ok, authority} ->
            model = %{model | authority: authority, expansion: expansion}
            {:ok, paint_footer(model)}

          # Unreachable given the capacity check above (belt and braces,
          # same reasoning as `do_open_overlay/4`'s own defensive branch).
          {:error, :degenerate} ->
            {:error, :insufficient_footer_capacity}
        end

      # A sub-gutter-floor width (`DiffExpansion` refuses `width <
      # @gutter_width + 1`, since every body row's fixed gutter would
      # overflow a narrower budget and wrap past the footer region) is a
      # terminal-too-small refusal, mapped to the same honest notice the
      # row-degenerate gate above uses -- never emitted as wrapping bytes.
      {:error, :degenerate_view} ->
        {:error, :insufficient_footer_capacity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Closes the currently-open diff expansion (a no-op when none is open),
  restoring the footer viewport to `model.footer_rows` (the base value)
  and repainting. `InlineAuthority.set_footer_rows/2` latches
  `needs_keyframe` on a shrink, so the trailing `paint_footer/1` call
  self-promotes to a full keyframe -- the byte-identical restore
  discipline the moduledoc documents (mirrors `close_overlay/1`
  verbatim).
  """
  @spec close_expansion(t()) :: t()
  def close_expansion(%{expansion: nil} = model), do: model

  def close_expansion(model) do
    authority =
      case InlineAuthority.set_footer_rows(model.authority, model.footer_rows) do
        {:ok, authority} -> authority
        # Cannot happen for any authority this module itself constructed
        # (the base footer_rows was already valid when the expansion
        # opened) -- kept the authority unchanged rather than crashing if
        # it somehow did.
        {:error, _reason} -> model.authority
      end

    %{model | authority: authority, expansion: nil}
    |> paint_footer()
  end

  # `:expand_diff`'s dispatch target: maps every refusal to an honest,
  # visibly-labeled one-frame footer notice (the SAME `stub_notice`
  # mechanism `:interrupt`/`:steer`/the fold-on-sealed-block no-op use --
  # see the moduledoc's precondition #6), never a silent no-op. `{:ok, _}`
  # passes the already-painted model straight through.
  defp apply_expand(model, block_id) do
    case expand_block_at(model, block_id) do
      {:ok, model} ->
        model

      {:error, :no_focus} ->
        %{model | stub_notice: "» expand: no block focused"}

      {:error, :not_a_diff} ->
        %{model | stub_notice: "» expand: focused block is not a diff"}

      {:error, :insufficient_footer_capacity} ->
        %{
          model
          | stub_notice: "» expand: terminal too small for a full-screen diff"
        }

      {:error, reason} ->
        %{model | stub_notice: "» expand: #{inspect(reason)}"}
    end
  end

  # -- footer paint (precondition #5) --------------------------------------

  defp paint_footer(%{mode: :flat} = model), do: model

  defp paint_footer(%{mode: :full_viewport} = model), do: paint_viewport(model)

  defp paint_footer(model) do
    model = refresh_panel_overlay(model)
    {lines, cursor} = footer_frame(model)
    authority = InlineAuthority.repaint(model.authority, lines, cursor: cursor)
    %{model | authority: authority, stub_notice: nil}
  end

  # -- the full-viewport frame (V's endgame pivot) --------------------------

  # The single emit for `:full_viewport`: compose the WHOLE screen and hand
  # it to `ViewportAuthority.repaint/3`. Two stacked regions:
  #
  #   * TRANSCRIPT (top) -- the owned virtual scrollback (frozen seal
  #     records), windowed bottom-anchored so the newest sealed content
  #     hugs the footer; scrolled by `scroll_anchor`, with an honest
  #     "N below" indicator when scrolled off the tail.
  #   * FOOTER (bottom) -- the SAME `footer_frame/1` the inline path pins
  #     (status, lane, live-tail preview, unread divider, composer,
  #     notice). The streaming tail and input zone stay pinned above the
  #     bottom edge while the transcript scrolls behind them.
  #
  # The footer height is whatever `footer_frame/1` fitted; the transcript
  # fills the rows above it. Same one-frame `stub_notice` clear as the
  # inline `paint_footer/1`.
  defp paint_viewport(model) do
    model = refresh_panel_overlay(model)
    {footer_lines, footer_cursor} = footer_frame(model)
    footer_h = length(footer_lines)

    # The bottom frame inset: the composed frame is `inset` rows short of
    # the physical height, so `ViewportAuthority.repaint/3` pads that many
    # BLANK rows below the footer (the bottom margin). The footer rides one
    # row up with it; `viewport_cursor/2` follows because it is anchored to
    # `transcript_h`. Floors to 0 for a degenerate geometry (`frame_inset/1`).
    bottom_inset = frame_inset(model)
    transcript_h = max(model.rows - footer_h - bottom_inset, 0)

    transcript = viewport_transcript_lines(model)
    window = viewport_window(transcript, transcript_h, model)

    frame_rows = window ++ footer_lines
    cursor = viewport_cursor(footer_cursor, transcript_h)

    # The authority is always a `ViewportAuthority` here (built by
    # `build_authority(:full_viewport, ...)`), but the module-wide
    # `authority`-field type inference collapses to the inline struct, so
    # the direct typed call trips a spurious set-theoretic mismatch.
    # Dynamic dispatch (the same escape `overlay_mod/1` uses for the
    # overlay modules) sidesteps it -- the runtime target is unchanged.
    authority =
      apply(ViewportAuthority, :repaint, [
        model.authority,
        frame_rows,
        [cursor: cursor]
      ])

    %{model | authority: authority, stub_notice: nil}
  end

  # The frozen transcript rendered to styled lines, oldest first. Records
  # are held newest-first (O(1) append at seal time), so reverse once
  # here. Each `:block`/`:echo` record takes the one-blank-row separator
  # when anything precedes it (the same rhythm `block_separator/1` gives
  # the inline path); a `:marker` attaches tightly (loss reports hug the
  # content they interrupt). While the transcript is empty, an enabled
  # greeting renders as one dim centered line, cleared the instant the
  # first record lands.
  defp viewport_transcript_lines(%{transcript_records: []} = model),
    do: viewport_greeting_lines(model)

  defp viewport_transcript_lines(model) do
    model.transcript_records
    |> Enum.reverse()
    |> Enum.reduce({[], false}, fn record, {acc, any?} ->
      sep = if any? and separated_record?(record), do: [""], else: []
      {acc ++ sep ++ render_seal_record(record, model), true}
    end)
    |> elem(0)
  end

  defp separated_record?({:marker, _text}), do: false
  defp separated_record?(_record), do: true

  defp render_seal_record({:block, block, prominence}, model) do
    block
    |> BlockBody.render(%{
      width: content_width(model),
      prominence: prominence,
      turn_has_tools?: turn_has_tools?(block, model)
    })
    |> ViewText.lines(content_width(model), :styled)
    |> sealed_history_lines(block, model, :styled)
  end

  defp render_seal_record({:marker, text}, model),
    do: marker_lines(model, text, :styled)

  defp render_seal_record({:echo, text}, model),
    do: prompt_echo_lines(model, text, :styled)

  defp viewport_greeting_lines(%{greeting?: false}), do: []

  defp viewport_greeting_lines(model) do
    centered =
      @greeting_text
      |> ViewText.truncate(content_width(model))
      |> center(content_width(model))

    ViewText.lines(
      %{type: :text, content: centered, style: %{dim: true}},
      content_width(model),
      :styled
    )
    |> margin_lines()
  end

  defp center(text, width) do
    pad = max(div(width - Raxol.UI.TextMeasure.display_width(text), 2), 0)
    String.duplicate(" ", pad) <> text
  end

  # Windows `transcript` to exactly `height` rows, bottom-anchored. When
  # the transcript is shorter than the window it is padded at the TOP
  # (content hugs the footer); when longer, `scroll_anchor` names the
  # bottom edge (`:tail` = the newest line). Scrolled off the tail
  # (`below > 0`), the window's bottom row becomes an honest "N below"
  # indicator rather than hiding the gap.
  defp viewport_window(_transcript, 0, _model), do: []

  defp viewport_window(transcript, height, model) do
    total = length(transcript)

    if total <= height do
      List.duplicate("", height - total) ++ transcript
    else
      bottom = clamp_anchor(model.scroll_anchor, height, total)
      below = total - bottom
      window = Enum.slice(transcript, (bottom - height)..(bottom - 1)//1)
      apply_below_indicator(window, below, model)
    end
  end

  # `:tail` pins to the newest line; a stored anchor is clamped into
  # `[height, total]` every paint so a drop-from-front (compaction) or a
  # shrunk transcript degrades gracefully instead of slicing out of range.
  defp clamp_anchor(:tail, _height, total), do: total

  defp clamp_anchor(anchor, height, total) when is_integer(anchor),
    do: anchor |> max(height) |> min(total)

  defp apply_below_indicator(window, 0, _model), do: window

  defp apply_below_indicator(window, below, model) do
    label = "  ↓ #{below} more below — End to jump  "

    [indicator] =
      ViewText.lines(
        %{type: :text, content: label, style: %{dim: true}},
        content_width(model),
        :styled
      )

    List.replace_at(window, -1, margin_line(indicator))
  end

  # `footer_frame/1`'s cursor park is `{row_offset, col}` relative to the
  # footer's first row; in `:full_viewport` the footer starts at absolute
  # row `transcript_h + 1`, so shift the offset into an absolute
  # `{row, col}` for `ViewportAuthority.repaint/3` (which parks a visible
  # cursor there, or hides it on `nil`).
  defp viewport_cursor(nil, _transcript_h), do: nil

  defp viewport_cursor({row_offset, col}, transcript_h),
    do: {transcript_h + row_offset + 1, col}

  # This is the whole live-update mechanism for an open projection panel:
  # `advance/2` (fixture reveal) and `handle_input/2` (keystrokes) both
  # end in this module's own `paint_footer/1` call, so an open panel
  # refreshes its content as new `extract` events reveal, without any
  # separate subscription or polling path.
  #
  # M2: memoize the fold against `source_events`'s length. paint_footer/1
  # runs at the end of EVERY handle_input/2 -- including pure scroll keys
  # that touch no projection state -- and an unguarded re-fold there is
  # O(source_events) per keystroke over a monotonically growing journal.
  # source_events is append-only within a session (a ref is a journal
  # offset; existing entries never mutate), so when the count is unchanged
  # since the last fold the result is byte-identical and the whole
  # render_lines/2 fold+format is skipped. Only a reveal that actually grew
  # the journal (advance/2) re-folds. Recompute-not-cached still holds for
  # the content itself -- see `PanelProjection`'s moduledoc; this only
  # elides provably-redundant recomputes.
  defp refresh_panel_overlay(
         %{
           overlay:
             %{mod: OverlayPanel, picker: panel, folded_at: folded_at} =
               overlay
         } = model
       ) do
    case length(model.projection.source_events) do
      ^folded_at ->
        model

      count ->
        lines =
          PanelProjection.render_lines(
            panel.kind,
            model.projection.source_events
          )

        %{
          model
          | overlay: %{
              overlay
              | picker: OverlayPanel.put_lines(panel, lines),
                folded_at: count
            }
        }
    end
  end

  defp refresh_panel_overlay(model), do: model

  # While a diff expansion is open, it claims the WHOLE footer viewport:
  # composer, preview, and overlay lines are all suppressed (there is no
  # overlay to suppress anyway -- the two refuse each other) -- only the
  # status line, a one-frame notice (if any -- e.g. the honest refusal
  # notices `apply_expand/1` sets right before an expansion attempt
  # fails, or a stale notice from just before "e" opened one), and the
  # expansion's own header-plus-window lines. A separate function head
  # (rather than a branch inside the clause below) keeps this diff
  # surgical against the existing footer_lines/1 body.
  # The footer frame: the fitted line list PLUS the terminal-cursor park
  # target (`InlineAuthority`'s `:cursor` option -- `{row_offset, col}`
  # relative to the footer's top row, or `nil` to leave the cursor where
  # the last park put it). Both consumers (`paint_footer/1`'s repaint,
  # `resize/2`'s keyframe composition) thread the same tuple.
  defp footer_frame(%{expansion: expansion} = model) when expansion != nil do
    # Same honest-notice law as the normal clause below: the expansion's
    # body rows are the discretionary tail (its header stays first-in-
    # group so position/dismiss hints survive a trim), status yields
    # next, the notice never. No composer is on screen while expanded,
    # so there is no edit point to park at -- the cursor stays wherever
    # the last composer park left it.
    budget = footer_budget(model)

    lines =
      [
        status: strip_lines(model),
        notice: notice_line(model.stub_notice, content_width(model)),
        expansion: DiffExpansion.render_lines(expansion)
      ]
      |> fit_footer_groups([:expansion, :status], budget)
      |> apply_margins(model)
      |> apply_debug_highlight(model)
      |> Enum.flat_map(fn {_key, lines} -> lines end)
      |> Enum.take(budget)

    {lines, nil}
  end

  defp footer_frame(model) do
    # Both the divider and the pending/live-tail preview are suppressed
    # while an overlay is open -- the overlay claims that space (see the
    # moduledoc's precondition #5 update, "The overlay picker" section,
    # and the "unread divider" section for why it yields the same way).
    divider_lines = if model.overlay, do: [], else: unread_divider_lines(model)
    preview_lines = if model.overlay, do: [], else: pending_preview_lines(model)

    composer_lines =
      ViewText.lines(
        Composer.render(model.composer, %{available_width: content_width(model)}),
        content_width(model),
        :styled
      )

    budget = footer_budget(model)

    # `lane` is the persistent live-session status channel
    # (`put_lane_notice/2`: "interrupt sent", "session process exited —
    # transcript preserved", etc.). Like `notice`, it is an HONEST report
    # channel, so it is deliberately absent from `drop_order` -- never shed
    # to fit the budget (a dropped lane notice would read as "nothing
    # happened", the exact fail-safe inversion the honest-notice law rules
    # out). It sits right after `status` in display order.
    kept =
      [
        status: strip_lines(model),
        lane: notice_line(model.lane_notice, content_width(model)),
        submitting: submitting_lines(model),
        overlay: overlay_lines(model),
        divider: divider_lines,
        preview: preview_lines,
        composer: composer_lines,
        notice: notice_line(model.stub_notice, content_width(model))
      ]
      |> fit_footer_groups(
        [:preview, :divider, :composer, :overlay, :status],
        budget
      )
      |> apply_margins(model)

    lines =
      kept
      |> apply_debug_highlight(model)
      |> Enum.flat_map(fn {_key, lines} -> lines end)
      |> Enum.take(budget)

    # The cursor park reads the PRE-highlight `kept` -- highlight_bg/3
    # never changes a group's line count, so the two agree by
    # construction; reading the un-highlighted list keeps that
    # independence explicit.
    {lines, composer_cursor(model, kept, length(lines))}
  end

  # The DevTools debug highlight (see `put_debug_highlight/2`): wraps the
  # targeted group's already-fitted, already-styled lines in the palette-
  # resolved bg tint via `ViewText.highlight_bg/3` -- applied AFTER the
  # fit AND after the margin/chevron prefixes (row counts and row text
  # already settled; bg style only, never extra rows or cells) and at
  # the same byte-emission seam every other footer SGR comes from. A
  # group absent from this frame's composition (e.g. `:composer` while an
  # expansion claims the footer) is honestly a no-op -- there is nothing
  # of it on screen to tint.
  defp apply_debug_highlight(kept, %{debug_highlight: nil}), do: kept

  defp apply_debug_highlight(kept, model) do
    case List.keyfind(kept, model.debug_highlight, 0) do
      nil ->
        kept

      {key, lines} ->
        highlighted =
          Enum.map(
            lines,
            &ViewText.highlight_bg(&1, model.debug_highlight_bg, model.width)
          )

        List.keyreplace(kept, key, 0, {key, highlighted})
    end
  end

  # -- the margin/chevron seam (see the doctrine-layout section above) ----
  #
  # Applied POST-fit so shed decisions run on the honest row counts, and
  # in ONE place so no group can drift its own margin convention:
  #
  #   * `:composer` -- the chevron rows (see `chevron_lines/2`): the
  #     input's first draft row is prefixed with the flush-left sigil,
  #     continuation rows with two aligning spaces, a queued-steer
  #     banner row with the plain margin.
  #   * `:overlay` / `:expansion` -- exempt (framed transient claims
  #     pre-rendered at full width; see the doctrine-layout note).
  #   * everything else -- the plain 1-column margin.
  defp apply_margins(kept, model) do
    Enum.map(kept, fn
      {:composer, lines} -> {:composer, chevron_lines(lines, model)}
      {:overlay, lines} -> {:overlay, lines}
      {:expansion, lines} -> {:expansion, lines}
      {:preview, lines} -> {:preview, preview_margin_lines(lines, model)}
      {key, lines} -> {key, margin_lines(lines)}
    end)
  end

  # -- the running-tool margin spinner -------------------------------------
  #
  # A RUNNING tool line's col-0 margin cell animates a braille spinner
  # (dim -- machinery register), clocked by the EXISTING tick/advance
  # frames (`spinner_frame`; never a timer of this module's own). Only
  # the preview group's FIRST row, and only while the pending (footer)
  # block is a tool call still awaiting its result (result nil, reveal not
  # finished). The spinner is footer-only: the sealed line is final-form,
  # so a completed tool's margin cell is the plain blank -- the ✓/✗
  # receipt lives in the line itself, and history never animates.
  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  defp preview_margin_lines(lines, model) do
    if spinner_active?(model) do
      spin_first_margin(lines, model)
    else
      margin_lines(lines)
    end
  end

  defp spin_first_margin([], _model), do: []

  defp spin_first_margin([first | rest], model) do
    frame_count = length(@spinner_frames)
    index = rem(Map.get(model, :spinner_frame, 0), frame_count)
    frame = Enum.at(@spinner_frames, index)

    [line] =
      ViewText.lines(
        %{type: :text, content: frame, style: %{dim: true}},
        1,
        :styled
      )

    # The spinner rides the margin cell (col 0 inline). In `:full_viewport`
    # the frame inset shifts that cell -- and the running-tool line with it
    # -- into the framed marker column so the spinner aligns with every
    # other marker. `inset_prefix/2` is a no-op inline/flat.
    [inset_prefix(line <> first, model) | margin_lines(rest)]
  end

  defp spinner_active?(model) do
    not reveal_finished?(model) and
      case pending_block(model) do
        {%Block{kind: :tool_call, content: content}, _index} ->
          is_nil(Map.get(content, :result))

        _other ->
          false
      end
  end

  # The composer group's rows, chevron applied. Row indexing mirrors
  # `Composer.edit_point/2`'s own banner accounting: a queued-steer
  # banner (when present) occupies row 0, the draft's first input row
  # follows it. The footer fit only ever sheds rows from a group's END
  # (`shed_overflow/3` is an `Enum.take/2`), so the row the chevron
  # belongs to keeps its index even under width pressure -- it can only
  # disappear entirely, never slide.
  defp chevron_lines(lines, model) do
    sigil_row = if model.composer.queued_steer, do: 1, else: 0
    sigil = styled_sigil(model)

    # The sigil row and its hang continuations are the composer's OUTER
    # CONTOUR: in `:full_viewport` they take the frame inset so the live
    # chevron aligns with its sealed echoes (and the machinery margin
    # column). The queued-steer banner row already rides `margin_line/1`
    # (the machinery column), so it is left untouched. `inset_prefix/2` is
    # a no-op in inline/flat -- the composer keeps its col-0 chevron there.
    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {line, ^sigil_row} -> inset_prefix(sigil <> " " <> line, model)
      {line, index} when index < sigil_row -> margin_line(line)
      {line, _index} -> inset_prefix("  " <> line, model)
    end)
  end

  # The status strip is a grown instrument (doctrine §1.2): it exists
  # while the session has something TRUE for it to say -- a live turn
  # (stage/elapsed are real), an approval wait (`needs_input`, the
  # safety slot), or a stall alarm (the one condition the strip exists
  # to make unmissable) -- and yields to silence at boot and between
  # turns. An idle frame showing `Stage: — | Ctx: — | Cost: —` was the
  # corpus's "airiness with nothing to say": four labelled voids
  # claiming instrument-hood with no instrument behind them.
  # Event-clocked by construction: every input below is derived from
  # session events (`update_status/3`) or the stall detector, never
  # from wall time.
  defp strip_lines(model) do
    if strip_visible?(model.status) do
      StatusStrip.render(model.status, content_width(model))
    else
      []
    end
  end

  defp strip_visible?(status) do
    StatusStrip.alerting?(status) or
      Map.get(status, :needs_input) == true or
      live_turn?(status)
  end

  # A live turn: loop events have been observed (`turn_stage` is set by
  # `update_status/3` from the last loop event) and the most recent
  # bracket has neither completed nor canceled the turn. A terminal
  # `:error` also ends the live claim -- nothing is running after a
  # fault, the sealed error block is the permanent record, and a strip
  # that kept ticking `failed <elapsed>` toward a HUNG marker would be
  # claiming activity where there is none.
  defp live_turn?(status) do
    case Map.get(status, :turn_stage) do
      nil -> false
      :turn_canceled -> false
      :error -> false
      _stage -> Map.get(status, :turn_completed) != true
    end
  end

  # The park target for the composer's edit point (see
  # `Composer.edit_point/2` -- end of the typed draft, the minimal
  # honest version). `nil` -- leave the cursor at its previous park --
  # whenever the composer is not what typed keys currently reach: an
  # open overlay routes every `:passthrough` keystroke to the picker's
  # filter, so parking at the (frozen) composer would point the native
  # cursor at state the keys never touch. Also `nil` when the footer fit
  # sheded the composer's rows entirely (nothing on screen to park at).
  defp composer_cursor(%{overlay: overlay}, _kept, _line_count)
       when overlay != nil,
       do: nil

  defp composer_cursor(model, kept, line_count) do
    composer_kept = kept |> Keyword.fetch!(:composer) |> length()

    if composer_kept == 0 do
      nil
    else
      offset =
        kept
        |> Enum.take_while(fn {key, _lines} -> key != :composer end)
        |> Enum.map(fn {_key, lines} -> length(lines) end)
        |> Enum.sum()

      # The edit point is computed at the margined content width (the
      # draft re-wraps at that width -- see `footer_frame/1`'s composer
      # render), then shifted right by the chevron prefix's two cells
      # (`chevron_lines/2` prefixes every input row with exactly
      # `@sigil_cols` cells: "❯ " on the first, two aligning spaces on
      # continuations), capped at the physical width. A sub-margin
      # terminal (content width 0 -- e.g. #626's width-2 sub-gutter
      # refusal geometries) has no representable edit point at all, so
      # the park is nil (leave the cursor where the last park put it),
      # matching `edit_point/2`'s own positive-width contract.
      cwidth = content_width(model)

      if cwidth <= 0 do
        nil
      else
        {row_in_composer, col} = Composer.edit_point(model.composer, cwidth)

        row = offset + min(row_in_composer, composer_kept - 1)
        # Shift past the chevron prefix, then past the frame inset: in
        # `:full_viewport` the composer's draft starts one cell further
        # right (the chevron moved into the framed marker column via
        # `chevron_lines/2`), so the park must move with it. `frame_inset/1`
        # is 0 inline/flat, keeping the pinned inline park byte-identical.
        col = min(col + @sigil_cols + frame_inset(model), model.width)

        if row < line_count, do: {row, col}, else: nil
      end
    end
  end

  # -- footer fit: the honest-notice law ------------------------------
  #
  # `InlineAuthority.repaint/2` pads/TRUNCATES the handed list to the
  # footer row count POSITION-BLIND (`pad_rows/2` is an `Enum.take/2` --
  # the tail is the casualty). With the notice as the last footer group,
  # any composed footer that overflows the budget would silently eat the
  # honest refusal/degradation notice first -- the exact fail-safe
  # inversion the notice channel exists to rule out (a notice IS the
  # honest report that something was refused or degraded; a dropped one
  # reads as "nothing happened"). So THIS module owns a priority-aware
  # fit before repaint ever truncates: display order is preserved,
  # `drop_order` names the discretionary groups from most to least
  # droppable (each trimmed from its TAIL, so a group's leading line --
  # the composer's prompt row, the expansion's position header --
  # survives a partial trim), and the notice group is deliberately
  # absent from every drop order: as the last resort (notices alone
  # exceeding the budget) the final head-take (in `footer_frame/1`)
  # keeps the EARLIEST notice lines rather than crashing. Pinned by the
  # "honest-notice law under footer overflow" describe in
  # diff_expand_surface_test.exs.
  #
  # Group-preserving by design: sheds overflow per the drop order but
  # keeps the keyword structure, so `footer_frame/1` can read the
  # composer group's post-fit offset/length for the cursor park,
  # `apply_margins/2` can key its per-group prefix on honest row counts,
  # and `apply_debug_highlight/2` can tint one group's rows post-fit
  # (both clauses flatten + head-take themselves).
  defp fit_footer_groups(groups, drop_order, budget) do
    total =
      groups |> Enum.map(fn {_key, lines} -> length(lines) end) |> Enum.sum()

    shed_overflow(groups, drop_order, total - budget)
  end

  defp shed_overflow(groups, _drop_order, overflow) when overflow <= 0,
    do: groups

  defp shed_overflow(groups, [], _overflow), do: groups

  defp shed_overflow(groups, [key | rest], overflow) do
    lines = Keyword.fetch!(groups, key)
    shed = min(length(lines), overflow)
    kept = Enum.take(lines, length(lines) - shed)

    groups
    |> List.keyreplace(key, 0, {key, kept})
    |> shed_overflow(rest, overflow - shed)
  end

  # The row budget the current pin actually provides -- the authority's
  # own footer range (grown while an overlay/expansion holds a claim),
  # never a hand-maintained constant. #620's frame pipeline keeps this
  # geometry-fixed per frame (never a function of post-seal state), so
  # reading it here is stable within a paint.
  # `:full_viewport` has no DECSTBM footer range to read -- its footer is
  # a fixed `footer_rows`-tall region at the screen bottom, and
  # `paint_viewport/1` gives the transcript whatever rows remain above it.
  # (Overlays/panels/expansion, which grow the inline region, are gated off
  # in this mode -- see `open_overlay/3` etc.)
  defp footer_budget(%{mode: :full_viewport} = model), do: model.footer_rows

  defp footer_budget(model),
    do: InlineAuthority.footer_row_count(model.authority)

  defp overlay_lines(%{overlay: nil}), do: []

  defp overlay_lines(%{overlay: overlay, width: width}),
    do:
      ViewText.lines(
        overlay_mod(overlay).render(overlay.picker),
        width,
        :styled
      )

  # Renders the unread divider (see `UnreadDivider`'s moduledoc) as one
  # dim footer line through the SAME `ViewText` sanitize/truncate seam
  # every other footer line goes through -- the divider is module-built
  # inert text (rule glyphs, digits, a fixed label), but this module
  # takes no shortcuts around that seam for it.
  defp unread_divider_lines(model) do
    # The RECONCILED read (`divider/2`, not `/1`): paints only what the
    # live block count can honestly support, so a stale span can never
    # render past reality even on a paint that precedes the state's own
    # reconciliation (see `UnreadDivider`'s "Defensive boundaries and
    # reconciliation").
    case UnreadDivider.divider(model.unread, unread_offset(model)) do
      nil ->
        []

      span ->
        ViewText.lines(
          %{
            type: :text,
            content: UnreadDivider.line(span, content_width(model)),
            style: %{dim: true}
          },
          content_width(model),
          :styled
        )
    end
  end

  defp notice_line(nil, _width), do: []

  # A LIST of notices renders one footer line each -- each independently
  # width-truncated, so a long first notice can never truncate away a
  # later one (the degraded-resume warning rides this; see
  # `apply_degraded_notice/2`).
  defp notice_line(notices, width) when is_list(notices),
    do: Enum.flat_map(notices, &notice_line(&1, width))

  defp notice_line(text, width),
    do: ViewText.lines(%{type: :text, content: text}, width, :styled)

  # The optimistic "sending" preview: a single DIM line echoing the prompt
  # currently in flight (`pending_submit`), shown between dispatch and the
  # lane's `:turn_started` accept. Dim (not full-weight) is the honesty:
  # nothing is on the record yet -- `submit_accepted/1` seals the real
  # `❯ prompt` history line only when the turn is EVENT-OBSERVED, and this
  # preview clears at the same moment. Suppressed while an overlay claims
  # the footer (same yield as the divider/preview groups). Absent (`[]`)
  # when no submit is in flight, so no existing frame's bytes change.
  defp submitting_lines(%{overlay: overlay}) when overlay != nil, do: []

  defp submitting_lines(%{pending_submit: %{text: text}} = model) do
    ViewText.lines(
      %{type: :text, content: "» sending: " <> text, style: %{dim: true}},
      content_width(model),
      :styled
    )
  end

  defp submitting_lines(_model), do: []

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
        |> BlockBody.render(%{
          width: content_width(model),
          turn_has_tools?: turn_has_tools?(block, model),
          # The footer live tail is the ONE place a resultless tool renders
          # `running…` (seal-on-result-only) -- but only while a result may
          # still arrive. Once the reveal is finished the preview shows the
          # final `⊘ no result` form, matching what will seal.
          pending?: not reveal_finished?(model)
        })
        |> ViewText.lines(content_width(model), :plain)
        |> Enum.take(2)
    end
  end

  defp pending_block(model) do
    # Keyed on the committed CURSOR (`painted_count` -- `commit_walk/5`'s
    # own post-walk cursor), NOT on `frontier_scan/1`'s `tail_start`. The
    # scan is the PRE-commit projection ("what would remain after an
    # ideal commit this frame"): it consumes committable entries, so
    # after a REFUSED seal write (`{:error, :write_failed, _}` -- the
    # walk halts, `painted_count` stays strictly before the failed
    # entry) the two diverge, and the scan-keyed preview would skip the
    # very block that is not yet in history -- invisible on both
    # surfaces at once, exactly the under-reporting the display half of
    # retry-not-vanish forbids (pinned in
    # test/harness/surface_seal_pipeline_test.exs). On every successful
    # frame the walk's cursor and the scan agree (`tail_start ==
    # painted_count`, the scan/walk-agreement property), so this changes
    # nothing there; on a refusal the cursor is the honest one.
    #
    # Named `committed_cursor`, NOT `tail_start`: this PR's whole thesis is
    # that the scan's `tail_start` and the committed cursor are DIFFERENT
    # quantities that diverge exactly on refusal, so the one function whose
    # reason-to-exist is that distinction must not reuse the scan's name.
    committed_cursor = model.painted_count

    case Enum.slice(model.projection.blocks, committed_cursor..-1//1) do
      [] -> nil
      [block | _rest] -> {block, committed_cursor}
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
          content_width(model),
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

  A diff expansion mirrors the same force-close discipline (same
  `max_overlay_rows/2` capacity check, at the OLD geometry, before
  anything else runs), but does NOT simply stay open unchanged when it
  still fits: because the expansion mechanism is "claim the MAXIMUM
  non-degenerate footer," not a fixed height like the overlay's, the claim
  is RE-DERIVED at the new geometry every resize (`max_overlay_rows(rows,
  model.footer_rows)` again), the footer re-grown to match via
  `InlineAuthority.set_footer_rows/2`, and `DiffExpansion.resize_view/3`
  re-renders the SAME content at the new width/window (clamping its
  scroll offset) -- see the moduledoc's "Full-screen diff expansion"
  section. A `resize_view/3` failure (degenerate target geometry) falls
  back to closing the expansion and restoring the base pin, same as the
  too-small force-close path.
  """
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%{mode: :flat} = model, width, rows),
    do: adopt_resize(model, width, rows)

  # `:full_viewport` resize is a FULL REFLOW (the pivot's headline win): a
  # width change re-wraps every frozen record at the new width the next
  # time `paint_viewport/1` renders them. Just adopt the geometry and
  # repaint the whole frame -- no DECSTBM re-set, no footer keyframe.
  def resize(%{mode: :full_viewport} = model, width, rows) do
    model |> adopt_resize(width, rows) |> paint_viewport()
  end

  def resize(model, width, rows) do
    model = model |> heal_sync() |> adopt_resize(width, rows)
    {lines, cursor} = footer_frame(model)
    authority = InlineAuthority.keyframe(model.authority, lines, cursor: cursor)
    %{model | authority: authority, stub_notice: nil}
  end

  # Shared by `resize/2` and `advance/3`'s `:resize` option -- see
  # `advance/3`'s FRAME-ORDER LAW doc for why the two paths must never
  # drift: both need dims + DECSTBM re-set applied identically, and
  # `resize/2` alone additionally keyframes the footer immediately (which
  # `advance/3`'s combined frame instead lets its own trailing
  # `paint_footer/1` self-promote to, via `needs_keyframe`).
  defp adopt_resize(%{mode: :flat} = model, width, rows) do
    %{
      model
      | authority: FlatAuthority.resize(model.authority, width, rows),
        width: width,
        rows: rows
    }
  end

  # `:full_viewport`: adopt geometry + composer width, and close any open
  # overlay/expansion (a full reflow starts the footer clean rather than
  # re-deriving an inline-substrate claim that has no meaning here). The
  # frozen transcript re-wraps for free -- its records re-render at the new
  # `content_width/1` on the next `paint_viewport/1`. `scroll_anchor` is
  # left as-is; `viewport_window/3` re-clamps it into range every paint.
  defp adopt_resize(%{mode: :full_viewport} = model, width, rows) do
    model = if model.overlay, do: close_overlay(model), else: model
    model = if model.expansion, do: close_expansion(model), else: model
    model = %{model | width: width, rows: rows}

    model = %{
      model
      | composer: Composer.set_width(model.composer, content_width(model))
    }

    %{model | authority: ViewportAuthority.resize(model.authority, width, rows)}
  end

  defp adopt_resize(model, width, rows) do
    # A resize invalidates the greeting's absolute placement -- erase it
    # at the OLD geometry (its rows are still where they were painted)
    # rather than leaving a mispositioned line behind.
    model = clear_greeting(model)

    model =
      if force_close_overlay?(model, rows) do
        close_overlay(model)
      else
        model
      end

    model =
      if force_close_expansion?(model, rows) do
        close_expansion(model)
      else
        model
      end

    model = %{model | width: width, rows: rows}

    # Keep the composer's event-time width in step with the rendered
    # width: its visual up/down + history-recall gating project the
    # draft through a wrap map at the STORED substrate width, while
    # `footer_frame/1` renders (and parks) at `content_width/1`. Same
    # value at init (`new/2` passes `width - 2`); this keeps them equal
    # across a resize so the on-screen rows and the navigation rows can
    # never disagree.
    model = %{
      model
      | composer: Composer.set_width(model.composer, content_width(model))
    }

    authority = InlineAuthority.resize(model.authority, width, rows)

    # A still-open expansion re-derives its maximal claim at the new
    # geometry HERE, in the shared adopt path, so both consumers get it:
    # `resize/2`'s trailing keyframe repaints the re-rendered window
    # immediately, and `advance/3`'s combined frame self-promotes via the
    # `needs_keyframe` latch (already set by `InlineAuthority.resize/3`
    # above on any geometry change; `resize_expansion/3`'s own
    # `set_footer_rows/2` latches again whenever the claim changed).
    # Re-rendering before the frame's seals/paints is the same
    # frame-order discipline `advance/3`'s FRAME-ORDER LAW pins for
    # blocks: nothing may paint expansion content at a stale width.
    resize_expansion(%{model | authority: authority}, width, rows)
  end

  defp force_close_overlay?(%{overlay: nil}, _new_rows), do: false

  defp force_close_overlay?(
         %{overlay: overlay, footer_rows: footer_rows},
         new_rows
       ) do
    # Same capacity rule `open_overlay/3` admits with -- one helper, one
    # threshold (routed through `ScrollRegionManager.degenerate?/2`),
    # never a re-encoded literal that could drift.
    overlay_mod(overlay).height(overlay.picker) >
      max_overlay_rows(new_rows, footer_rows)
  end

  # A diff expansion's claim is "the maximum non-degenerate footer
  # GROWTH", not a fixed height -- so unlike the overlay, force-close is
  # the ONLY geometry below which it cannot be hosted at all. When
  # `max_overlay_rows/2` (the maximal growth still leaving history its
  # 2-row minimum) drops below 2, that growth can no longer host the
  # expansion's own two chrome rows (`@expansion_chrome_rows`: one status
  # row, one expansion header row), so the expansion must close. The `2`
  # here is that minimum growth, NOT the chrome subtraction it happens to
  # equal -- see `expansion_view_rows/2` and `do_expand/2`.
  defp force_close_expansion?(%{expansion: nil}, _new_rows), do: false

  defp force_close_expansion?(%{footer_rows: footer_rows}, new_rows),
    do: max_overlay_rows(new_rows, footer_rows) < 2

  # Re-derives the expansion's claim at the NEW geometry and re-renders
  # its content to match -- see `resize/3`'s moduledoc. A no-op when no
  # expansion is open (including the case just force-closed above, since
  # `close_expansion/1` already cleared `model.expansion`).
  defp resize_expansion(%{expansion: nil} = model, _width, _rows), do: model

  defp resize_expansion(model, width, rows) do
    claim = max_overlay_rows(rows, model.footer_rows)

    case InlineAuthority.set_footer_rows(
           model.authority,
           model.footer_rows + claim
         ) do
      {:ok, authority} ->
        view_rows = expansion_view_rows(model.footer_rows, claim)

        case DiffExpansion.resize_view(model.expansion, width, view_rows) do
          {:ok, expansion} ->
            %{model | authority: authority, expansion: expansion}

          {:error, _reason} ->
            close_expansion(%{model | authority: authority})
        end

      # Unreachable given `force_close_expansion?/2` already gated this
      # call on a non-degenerate claim (belt and braces, same reasoning
      # as `build_expansion/3`'s own defensive branch).
      {:error, :degenerate} ->
        close_expansion(model)
    end
  end

  # -- accessors ------------------------------------------------------------

  @spec done?(t()) :: boolean()
  def done?(model),
    do:
      model.revealed >= length(model.events) and
        model.painted_count >= length(model.projection.blocks)

  @spec degenerate?(t()) :: boolean()
  def degenerate?(%{mode: :flat}), do: false

  # `:full_viewport` owns the whole screen and never carves a footer out
  # of a DECSTBM region, so the inline degenerate-geometry notion does not
  # apply (a too-small terminal degrades to `:flat` at construction, in
  # `apply_surface_mode/3`, before this mode is ever entered).
  def degenerate?(%{mode: :full_viewport}), do: false

  def degenerate?(%{authority: authority}),
    do: InlineAuthority.degenerate?(authority)

  @doc """
  Leaves the alternate screen (the `:full_viewport` teardown), restoring
  the primary screen. A no-op in every inline/flat tier (they never
  entered the alternate screen). See `ViewportAuthority`'s teardown-order
  law: an embedder that lets an input driver (`InlineDriver`) tear down
  first should instead emit `ViewportAuthority.leave/0` as its LAST byte.
  """
  @spec teardown(t()) :: t()
  def teardown(%{mode: :full_viewport, authority: authority} = model),
    do: %{model | authority: ViewportAuthority.teardown(authority)}

  def teardown(model), do: model
end
