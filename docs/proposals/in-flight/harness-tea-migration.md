# Harness → TEA Migration — architecture proposal

Status: **design v1 (decision-ready)** · Date: 2026-07-18 · Owner: V + Claude (harness-ui lane)
Base: `origin/integration/harness-endgame` @ `edeceb2c0`. Design only; no code changed.
Relates: `harness-confirmation-ui.md`, `harness-gundam-widgets.md`, `harness-composer-commands.md`,
`harness-visual-doctrine.md`, `harness-ui-STATE.md`, ADR-0012 (MCP as rendering target).

## 0. Ruling and thesis

V's ruling: migrate the harness onto TEA — dynamic widgets and overlays make the map-machine
unmaintainable, and every harness part must be playground-representable for autotests.

The original bypass reason is gone. `surface.ex:8-21` names it: the inline substrate is "a
byte-level pinned-region writer, one layer BELOW the Preparer → LayoutEngine → UIRenderer →
ScreenBuffer pipeline… there is no Component tree to mount here." That was true for DECSTBM
seal-once inline rendering. The full-viewport pivot changed the shape of the problem:
`ViewportAuthority` repaints the WHOLE frame of pre-styled SGR strings per event and documents
its own obsolescence — "a row-level diff… is an obvious later optimization… deliberately out of
this v1" (`viewport_authority.ex:23-38`). Meanwhile the normal pipeline became exactly that
engine: fresh ScreenBuffer per frame, row-level grid diff, one CUP vocabulary, DEC-2026 sync
bracket (#534, `backends.ex:59-86`), style batching, and `Preparer.prepare_incremental` content-hash
caching (`preparer.ex:159-203`). The TEA pipeline is now the *better* full-viewport paint engine,
and it brings what the map-machine structurally cannot: LayoutEngine-hosted overlays, component
identity, focus routing, MCP tool derivation, time-travel snapshots of every update.

Both widget proposals already pay the missing-Component-tree tax: gundam §3 ("no Component tree,
so TreeWalker/ToolProvider/FocusLens does not apply") and confirmation-ui gap 2 (wrapper demos
because "the tool-widgets are pure render fns"). This migration deletes that tax.

**Scope guard.** The inline-hybrid substrate stays SHELVED as-is (fixture demo + byte-goldens keep
pinning it; `golden.ex`, 4 fixtures × 3 modes at `test/fixtures/harness/goldens/`, frozen). `:flat`
stays on the map-machine as the degradation floor. The TEA path serves the `:full_viewport` family —
doctrinally the endgame default, though the *code* default is still `surface_mode: :inline_hybrid`
(`surface.ex:1108`; the flip is a one-line Phase-4 act). Note `ViewportAuthority` was never
byte-goldened (only flat/inline_log/tmux_conservative are, `surface/golden.ex:120-121`) — the TEA
path starts with a clean assert slate. The `SessionLane` behaviour and the whole agent lane
(`session_inbox`, `tool_executor`, steer/interrupt semantics) are untouched — render-side only.

## 1. Target shape

```
SessionLane (unchanged) ──subscribe──▶ Forwarder ──▶ EventBoundary ──▶ StreamCadence
                                                                            │ batches
   tty stdin ──▶ InlineDriver ──▶ ┌─────────── SessionPump ────────────┐◀───┘
                                  │ input-first selective receive       │
                                  │ monitors, tick, steer Task+timeout, │──▶ lane calls
                                  │ editor-suspend bracket, teardown    │    (submit/steer/…)
                                  └──── ordered normalized messages ────┘
                                                   │ send_message (sole feeder)
                                                   ▼
              Lifecycle(environment: :harness) ▶ Dispatcher ▶ HarnessApp.update/2 (pure)
                                                   │ :render_needed        │ Directives
                                                   ▼                       ▶ Harness.Directive.Lane → pump
              Engine: view/1 ▶ Preparer ▶ LayoutEngine ▶ UIRenderer ▶ ScreenBuffer diff ▶ tty
```

The pump is to the harness what `Raxol.Terminal.Driver` is to a normal app — the IO boundary that
feeds normalized messages in — plus the lane-protocol client executing commands back out.
`HarnessApp` is a plain `Raxol.Core.Runtime.Application` (the playground demos' exact shape).

## 2. Q1 — the model/update/view cut

The decisive present-tense fact: **view is fused into update.** Nearly every Surface mutator ends
in `paint_footer/1` / `paint_viewport/1` writing bytes *now* (e.g. `advance/2:1432` →
`seal_frame/2:1502`; `handle_input/2:2828` → repaint). The cut is therefore mostly *deletion*:
strip the paint half from ~20 mutators and what remains is `update/2`; the frame-composition half
(`footer_frame`, `paint_viewport/1`'s frame assembly, ViewText) becomes `view/1` emitting elements
instead of SGR rows.

**Model** (`init/1`): today's Surface map minus paint plumbing — `events`, `projection`
(`Projection.project/2` is a deterministic journal fold, `projection.ex:1-80`; ports byte-unchanged),
seal-frontier bookkeeping (`painted_count`, holds), `transcript` seal-records + `scroll_anchor`,
`composer` (logical draft, WrapMap-backed), `overlay`, `expansion`, `status`, `lane_notice`,
`stub_notice`, `stall_verdict`, `pending_submit`, `quit_armed?`, `steer_in_flight?`, `unread`,
recency state, geometry (`width/rows` from resize events), `fold_defaults`, `stream_open`.
Deleted from the model: `authority`, `device`, `mode` ladder, every byte-cursor field.

**Component state doctrine (framework fact, not preference).** On the view path the Bubbler
rebuilds component state from the element map per event and **discards** the returned state,
keeping only commands (`bubbler.ex:239-277`); persistent component-local state exists only in the
separate `ComponentManager` singleton, which the render pipeline does not consult. So harness
components are **controlled**: the TEA model owns ALL state (which the laws, fixture replay, and
time-travel require anyway — shown = provable projection of the model); components are
`render/2 + handle_event/3` modules over props. `ComponentManager` is rejected for anything
law-governed. Ephemera (picker filter, selector focus, scroll_top) live in the model exactly as
they do today (`model.overlay`, `scroll_anchor`).

**Surface → TEA mapping** (line numbers = `surface.ex` unless noted):

| Surface today | TEA home |
|---|---|
| `new/2` :906 (mode select, authority build, boot/greeting) | `init/1`; authority/mode-ladder deleted (pipeline owns paint); boot POST becomes seal-records in init |
| `append_events/2` :1598 · `advance/2` :1432 · `run_advance` :1452 | `update/2` on `{:reveal}` / `{:batch, items}` from pump |
| `seal_frame/2` :1502 (fold + paint + DEC-2026 bracket) | fold half → `update/2`; paint half deleted (Backends owns sync bracket, `backends.ex:31-37`) |
| `flush_held/1` :1889 · `close_stream/1` :1865 · `compact_sealed_turns/1` :1675 | `update/2` on turn-bracket / stream-end messages |
| `tick/2` :1566 | `update/2` on `{:subscription, :tick}` (see §5 law 2) |
| `handle_input/2` :2828 (normalize → Keymap → route) | `update/2` on `{:key, ev}`; `InputEvent`/`Keymap` stay pure helpers; focused-component routing may take printable keys via Bubbler later |
| `dispatch_command/2` :3108 (~30 clauses; `command_sink` pushes) | `update/2` clauses; sink pushes become returned **Directives** (`Harness.Directive.Lane`) — the `%{type, payload}` sink shape is already a Command boundary in disguise |
| `submit_accepted/1` :2070 · `submit_refused/1` :2155 · `resolve_approval_answer/2` :2914 | `update/2` + pure helpers unchanged; submit busy-gate moves from driver belief into the model (`current_turn_id` becomes model state) |
| `put_lane_notice/put_stall_verdict/put_debug_highlight` | `update/2` on pump-normalized lane facts |
| `seal_marker/2` :1995 | `update/2` (loss/malformed/boot markers append seal-records) |
| focus fns, `open_overlay/panel/palette/jump/search/session` :3684+ · `expand_focused_diff` :4309 | `update/2` setting `model.overlay/expansion`; footer-grow calls deleted — overlays become layout children (§4) |
| `scroll_page` :3333 · `clamp_anchor` :4614 · `viewport_window` :4598 | TranscriptView (Viewport) + model scroll state (§5 law 7) |
| `run_editor` :3378 (Ctrl+E bracket) | `Harness.Directive.Editor` executed by pump (sole tty writer); result returns as message |
| `resize/3` :5293 (DECSTBM re-pin + keyframe) | `update/2` on resize event (Dispatcher already forwards it, `dispatcher.ex:319-341`); repaint = pipeline `force_repaint` |
| `paint_footer/paint_viewport` :4465/:4493 · `footer_frame` :4706/:4730 · cursor calc :4996/:4639 | **`view/1`**: FooterStack + TranscriptView + cursor declaration (§5 laws 3/6) |
| `render_block_lines` :2534, sealed-history/echo/sigil group :2574-2685 | block Components (pure bodies reused) |
| `fit_footer_groups/3` :5069 | FooterStack component (§5 law 3) — logic ports verbatim |
| `strip_lines` :4958 | StatusStrip component over `status_strip.ex` pure core |
| `frontier_entries/scan` :2209/:2301, `update_status` :2697, `done?/degenerate?` | pure helpers, unchanged |
| `Surface.ViewText` (`surface/view_text.ex`) | retired on the TEA path (Preparer/UIRenderer/TextMeasure own truncation+styling); survives only for the shelved inline/flat substrate |
| `golden.ex` / `golden_diff.ex` | frozen with the shelved substrate |

## 3. Q2 — driver vs Lifecycle: the pump ruling

**What the cadence contract actually guarantees** (`stream_cadence.ex` §2): two halves — (1)
*mandatory*: the owner's OWN receive handles input before `{:render_batch,…}`; (2) `:input_check`
source-side hold, explicitly "only ever a latency optimization" bounded by
`max_consecutive_yields`. `LiveSessionDriver` exists because a GenServer cannot express half (1)
(`live_session_driver.ex:10-17`, the `receive … after 0` at :428-451).

**Dispatcher fact:** plain FIFO GenServer; BaseManager routes callbacks with no selective receive
(`base_manager.ex:56-69`); input arrives as ordinary casts (`driver/dispatch.ex:16-25`);
`Backpressure` escalates cast→call but never reorders. Option (b) — teaching
Lifecycle/Dispatcher selective input priority — is framework-wide surgery distorting every app
for one consumer, and half (1) is unexpressible in `handle_info` anyway. Rejected.

**Pick: (a) the driver survives as `Raxol.Harness.SessionPump`** — a plain process that is the
**sole feeder** of the Dispatcher. It keeps: the lane subscription forwarder + `EventBoundary`,
StreamCadence ownership (+`input_check` now reading the pump's queue), monitors/trap_exit
(session death, forwarder/cadence crash → normalized messages), the stall ticker, the steer
`Task.async` + timeout + kill mechanics, the editor-suspend bracket, teardown ownership, and —
load-bearing — the input-first selective receive. Because ordering is established in the pump's
mailbox *before* forwarding and the Dispatcher is FIFO, the Dispatcher **preserves** the pump's
chosen order: the contract's guarantee survives end-to-end, restated as "input enters the
Dispatcher ahead of any batch that was pending with it." It sheds ALL model mutation: every
`Surface.*` call in `apply_batch_item`/`apply_lifecycle`/`handle_surface_command`
(`live_session_driver.ex:956-1146`) becomes a normalized message folded by `update/2` — the pump
ends ~400 lines lighter and byte-free.

Commands out: `update/2` returns Directive structs — the Directive **protocol** is the sanctioned
extension point (`dispatcher.ex:1022-1053`, `directive/executor.ex`) — `Harness.Directive.Lane`
(submit/interrupt/steer/approval_answer/halt) and `.Editor`, whose Executor impls `send` to the
pump. Split of steer state: the single-in-flight *belief* lives in the model (it renders the
refusal notice honestly); the Task/timeout *mechanics* live in the pump; outcomes return as
messages. The pump boots the Lifecycle with `environment: :harness` — a new profile: Dispatcher +
Engine + terminal output backend, **no** termbox Driver (the pump owns stdin via `InlineDriver` —
required anyway for the editor bracket and cursor probe), no plugin manager (initializer table:
`initializer.ex:243-323`). Alt-screen ownership moves with it: the pump emits enter
(`\e[?1049h…`) before the first frame and `leave` as the session's LAST byte after InlineDriver
teardown — `ViewportAuthority`'s teardown-ordering law (`viewport_authority.ex:53-70`) transfers
to the pump verbatim.

**Honest residual:** one FIFO segment remains — a keystroke forwarded behind an already-forwarded
batch waits one `update/2` fold + one coalesced paint. Bounded by cadence (≤32 deltas/16ms) and
by the row-diff paint; falsifier: an input-latency-under-flood test in the pump suite. Option (c)
(no pump; trust FIFO + cheap diffs) stays a *possible future simplification* once Phase-4 latency
numbers exist — not the migration bet.

## 4. Q3 — component granularity for the widget future

Correction to the premise, in the harness's favor: the per-kind block modules **already
`use Raxol.UI.Components.Base.Component`** (message/reasoning/tool_call/tool_result/error blocks,
diff_viewer, approval_prompt, composer, status_bar, picker, toast, panels — all of
`lib/raxol/ui/components/harness/` except the routers `block.ex`/`block_body.ex`/`body_provider.ex`
and pure helpers markdown_body/line_diff/word_diff). Today they're mounted *statelessly* outside
the runtime (`BodyProvider.mount_one/3`: `init` → `render`, `body_provider.ex:274-277`) with no-op
`handle_event` stubs, and their view maps get flattened by `ViewText`. Phase 1 is therefore a
**re-hosting**, not a rewrite: same modules, now emitted from `view/1` into the real pipeline, with
`id`/`attrs` stamped (the TreeWalker requirements) and real `handle_event/3` bodies. All stay
**controlled** (§2 doctrine).

| Part | Becomes | Notes |
|---|---|---|
| Block kinds — the real vocabulary is `:message \| :reasoning \| :tool_call \| :diff \| :approval \| :opaque` (`block.ex:180`; tool_result composes inside tool_call, `body_provider.ex:251-272`; ErrorBlock is standalone, wired to no kind today) | one `TranscriptBlock` dispatcher Component + the existing per-kind Components | dispatch = `BodyProvider.@components` (`body_provider.ex:98-104`) generalized; folded fallback `Block.render/2` + total-safety rescue (`block_body.ex:18-30`) unchanged |
| Transcript region | `TranscriptView` = Viewport + `ListScrollContent` over seal-records | §5 law 7 |
| Footer groups: strip / lane / submitting / overlay / divider / preview / composer_sep / composer / notice | `FooterStack` layout Component + `StatusStrip`, `LaneNotice`, `Composer`, `Notice` children | carries the fit law (§5 law 3) |
| Composer | real Component (already `update(msg, state) → {state, cmds}`-shaped, see `Composer.update` use at `live_session_driver.ex:905-910`); WrapMap untouched | draft stays model-owned (quit-preservation law) |
| SelectorWithComposer (confirmation-ui P3) | build **directly** as a Component; its `{:escape, dir}` boundary contract becomes `handle_event` results | registry shape survives verbatim |
| Overlays: picker, panels, diff expansion | Components hosted as `absolute_layer`/`panel` children of `view/1` | **un-gates the full-viewport overlay gap**: today `open_overlay/open_panel/expand_focused_diff` refuse in `:full_viewport` (:3733/:3864/:4329) because they depend on inline footer-grow; under the LayoutEngine they're just layout |
| Tool-widget router (confirmation-ui P2) | `ToolWidget.Spec{match, fold, view}` survives; `view` retargets `[row]` → element tree | router = Component selection; `:compact` fallback law unchanged |
| Gundam `WidgetSpec{source, fold, view}` | survives; `view` emits elements; `op: :grown/:settled` journaling unchanged | gundam §3's direct-Registry MCP workaround becomes optional — TreeWalker now applies |
| Command/Completer catalog (composer-commands §1) | TEA-agnostic; unchanged; `{:dispatch, term}` effect class now literally IS `update/2` | F2 convergence preserved for all three registries |

## 5. Q4 — the laws under TEA

| Law | Enforced today | TEA enforcement point | Falsifier |
|---|---|---|---|
| 1 Sealed-block logical immutability | seal frontier + print-once (inline) / logical (viewport); `seal_frontier.ex`, :2209-2441 | model: frontier bookkeeping unchanged; view: sealed block's elements = pure f(sealed record) — memoizable per block | frontier tests port untouched; new property: any event not touching block k leaves k's buffer rows byte-identical |
| 2 Event-clocked motion | no timers in Surface; driver tick feeds StallDetector only | pipeline default is event-clocked (Engine paints only on `:render_frame` after updates; `Animation.Framework` passive, unused here); `subscribe/1` returns ONLY the stall heartbeat interval, gated on session liveness | headless: advance wall clock sans events → buffer identical except stall/status segments |
| 3 Honest-notice / fit priority | `fit_footer_groups/3` :5069; drop order `[:composer_sep, :preview, :divider, :composer, :overlay, :status]`; `lane`/`submitting`/`notice` never shed; tail-trim per group; notice head-take last resort | LayoutEngine has **no** priority-drop primitive (verified: flex shrink/min/max + clip only) → `FooterStack` computes the identical fit in view-time over measured child heights (all heights model-known today) | "budget-1: notice wins" and drop-order tests port against FooterStack |
| 4 Prominence / salience | role tokens + H-K solver; needs-input floor `block.ex:148-154` | unchanged — components declare roles; solver assigns; theming layer is TEA-orthogonal | no-raw-hex grep gate; solver tests untouched |
| 5 Frame inset | `@fv_frame_inset` :1302, degenerate floor | container padding in `view/1` root | screenshot column assert |
| 6 Cursor park | `footer_frame` returns `{lines, cursor}` → authority `:cursor`; edit-point math :4996 | **framework gap**: renderer cursor hook is a no-op (`renderer.ex:485-486`), Backends emit no CUP-park — Phase-0 unit F0-cursor: honor a model/view-declared cursor `{row, col, visible?}` in `Backends.build_terminal_frame` via `Dialect.cursor_position` after rows | cursor-park byte tests port as buffer-cursor asserts |
| 7 Scroll anchor / owned scrollback | hand-rolled `scroll_anchor`/`viewport_window`/transcript_records; `unread_divider.ex` pure policy | `Viewport overflow_anchor: :auto` has exactly follow-at-bottom / preserve-when-scrolled (`viewport.ex:88-171`); scroll state model-held; UnreadDivider stays the pure policy feeding TranscriptView | follow/preserve/divider tests port |
| 8 Blank-row rhythm | seal-time separators + `composer_sep` group | block Components + FooterStack group | screenshot asserts |

## 6. Q5 — migration path (no stopped world)

**Phase 0 — framework enablers (parallel, small, framework lane):**
- **F0-cursor** (law 6) — blocks Phases 2-3.
- **F0-mcp-headless** — honest finding: playground demos currently derive **zero** MCP tools
  (View-DSL nodes lack `id`/`attrs`) and `Raxol.MCP.Test.start_session` doesn't thread its
  registry through Headless (passing tests hand-build trees). Fix the seam or Q6's autotest story
  is asserted-not-real.
- **F0-env** — `environment: :harness` initializer profile + alt-screen enter/leave ownership (§3).
- **F0-perf spike** — 1k-block fixture at 200×60: per-event frame cost through
  view→Preparer→Layout→cells→diff. Mitigations already in the pipeline: Viewport renders only the
  visible slice; `prepare_incremental` content-hash reuse; row diff bounds tty writes. Budget
  gate before Phase 3.

**Phase 1 — block Components re-hosted + playground demos** (parallel per kind; harness-ui lane).
The modules already exist as Base.Components (§4); the unit = stamp `id`/`attrs`, real
`handle_event`, emit from `view/1`, land the demo + headless asserts (§7).
**Phase 2 — footer + overlays**: FooterStack (fit law port), StatusStrip/LaneNotice/Notice,
Composer-as-Component, overlays as layout children (kills the full-viewport gating).
**Phase 3 — the app + the pump**: `HarnessApp` (init/update/view over the ported model),
`SessionPump` reshaped from `LiveSessionDriver`, `Harness.Directive.*`, fixture mode = same app
fed by a fixture pump. Time-travel comes free (`time_travel: true`).
**Phase 4 — MCP + asserts + assembly**: derivation over the component tree, StructuredScreenshot
vocabulary, full-assembly playground demo, latency falsifier for §3's residual.

**Test strategy** (census: ~1,850 test/property decls — component render-fns ~588, surface/
view_text ~272, projection ~204, driver ~40, goldens ~29, plus authority-by-content suites like
`full_viewport_surface_test`/`surface_cursor_park_test`; 12 agent-side files untouched):
- **Untouched**: projection/fold/recovery (~204), seal-frontier, recency, unread-divider, stall,
  cadence/policy, EventBoundary, Keymap/InputEvent, composer/WrapMap logic — pure cores the
  migration doesn't move. The ~588 component render-fn tests also largely survive: they assert on
  the modules' View-DSL output, which re-hosting doesn't change (only ViewText-flattening asserts
  move).
- **Ported mechanically**: footer-fit/notice/drop-order → FooterStack; scroll/anchor → TranscriptView;
  cursor-park → buffer-cursor asserts; driver contract tests → pump (same scripted fake lane).
- **Frozen**: inline/flat byte-goldens + `golden_diff` emulator oracle — they pin the shelved
  substrate, not the TEA path.
- **New vocabulary**: `Headless.screenshot` (plain text), `get_buffer` cell styles (prominence),
  `StructuredScreenshot` JSON (semantic tree), `MCP.Test` pipes (interaction flows). Full-viewport
  ANSI byte-goldens are **dropped** — bytes now belong to the framework's render path (pinned by
  its own suite); harness laws are buffer-level.

**In-flight proposals — build on the TEA shape, skip double migration:** confirmation-ui P3-1
(SelectorWithComposer) and P2-1 (router) build directly as Components in Phase 1-2 and serve as
the pilot consumers; P1-1 assembles on FooterStack/overlay hosting; A-1 (agent lane) is
unaffected and can proceed now. Composer-commands U-C1 (catalog) is TEA-agnostic — build now;
U-C2/U-C3 seams target the Composer component + `update/2`. Gundam G1-G3 target WidgetSpec with
element-emitting views; G4's direct-Registry wiring remains valid but TreeWalker derivation
becomes the default; G6 (ACP diff producer) is independent — proceed.

## 7. Q6 — playground representation (V's requirement)

Registration: one `@components` row each in `catalog.ex` (`category: :harness`), module = a
self-contained `Raxol.Core.Runtime.Application` demo (shape: `button_demo.ex`; precedents:
`HarnessApprovalDemo` catalog.ex:480, `HarnessDiffDemo` :205). The demo IS the autotest fixture:
driven headlessly (`Headless.start/screenshot/send_key`, precedent
`test/cross_terminal/modal_demo_headless_test.exs`) and via MCP after F0-mcp.

| Demo | Hosts | Fixture | Pins (the per-part contract) |
|---|---|---|---|
| `HarnessMessageBlockDemo` … one per kind (message/reasoning/tool_call+result/diff/approval/opaque; ErrorBlock's demo doubles as the decision point on wiring it to a kind) | the kind Component | canned block content incl. recovered/damaged variants | body rendering, prominence role, fold/expand keys, blank-row rhythm |
| `HarnessApprovalFlowDemo` | approval block + SelectorWithComposer + router output | fixture approval with options + diff payload | anchor-follows-focus, boundary-escape, decision emitted as message, needs-input floor |
| `HarnessComposerDemo` | Composer | seeded draft | WrapMap wrap/edit chords, placeholder, submit/refuse notices, cursor park (buffer cursor) |
| `HarnessStatusStripDemo` | StatusStrip | scripted status sequences | segment priority, charged-minimum absence, alert states |
| `HarnessFooterStackDemo` | FooterStack | oversized groups + shrinking budget stepper | drop order, protected channels never shed, budget-1 notice-wins |
| `HarnessOverlayDemo` | picker/panels/expansion over transcript | fixture session + panel sources | overlay-in-full-viewport, esc/dismiss, suppressed preview law |
| `HarnessTranscriptDemo` | TranscriptView | 1k-block fixture | anchor follow/preserve, unread divider, seal immutability property |
| `HarnessAssembledDemo` | full HarnessApp | replayed fixture session (today's fixture demo, playgrounded) | end-to-end: reveal cadence, echo-on-accept ordering, laws 1-8 smoke |

Assert placement: law-level byte/buffer asserts live in each part's test against its demo;
cross-part ordering laws live against `HarnessAssembledDemo`; wire-level bytes stay with the
framework suite and the frozen inline goldens. This replaces byte-goldens for full-viewport mode.

## 8. Unit DAG (lanes: **F** framework, **U** harness-ui, **A** agent)

```
F0-cursor ─┐                          ┌─ U2 FooterStack+strip/notice ─┐
F0-env ────┼─▶ U1 block Components ───┤                               ├─▶ U4 HarnessApp+fixture mode ─▶ U5 assembly demo
F0-mcp ────┘   (∥ per kind, w/ demos) └─ U3 overlays as layout ───────┘         │
F0-perf spike (gates U4)                                                        ▼
A0 pump reshape (∥ from day 1: LiveSessionDriver → SessionPump message contract)─▶ U6 live wiring ─▶ U7 MCP derivation + latency falsifier
Pilot consumers on the new shape: P3-1 selector (after U1), P2-1 router (after U1), P1-1 (after U2/U3), A-1 discuss-kind (now)
```

Parallelism: F0s are independent; U1 fans out per block kind; U2 ∥ U3; A0's message/directive
contract can be frozen on paper at Phase-0 time so pump and app build concurrently.

## 9. Honest risks

1. **Cadence contract residual** (§3): a FIFO segment exists inside the Dispatcher. Bounded and
   falsifiable, but it is a real weakening of "input strictly first" to "input first at the pump
   seam." If the latency test fails under flood, fallback: pump applies batches itself and feeds
   the Dispatcher pre-folded model deltas (uglier; kept as escape hatch).
2. **Cursor is a framework gap** (law 6): without F0-cursor there is no composer caret at all.
3. **Per-event full-tree cost**: view→layout per batch on big models is unmeasured; the spike
   gates Phase 3. Sealed-block memoization (blocks are immutable by law 1) is the known lever.
4. **MCP/headless seam is broken today** (F0-mcp): the derivation + StructuredScreenshot story is
   currently unwired for real sessions; Q6 is contingent on this unit.
5. **Test-port cost**: the ported buckets (~footer/scroll/cursor/driver) are mechanical but wide;
   budget them per phase rather than as one wave.
6. **Dual substrate during freeze**: Surface stays alive for shelved inline/flat. Acceptable —
   frozen goldens hold it — but no new features land there, ever.
7. **Editor suspend under an external paint engine**: the pump must pause Engine painting for the
   bracket (a `:render_frame` gate or Engine suspend call — small, but new framework surface).
8. **Macro entry**: use `Raxol.Core.Runtime.Application` directly (playground precedent), not
   `use Raxol.UI, framework: :react` — one less indirection in the demos.

## 10. Recommendation

Sequence: F0 units + A0 contract freeze immediately; Phase 1 fans out per block kind with demos
(this is also the moment confirmation-ui P3-1/P2-1 build as the first native Components); Phase 2/3
serialize behind F0-cursor and the perf gate; Phase 4 closes with the latency falsifier and the
assembled demo. Do NOT build confirmation-ui P1-1, composer-commands U-C2/U-C3, or gundam G1
against the map-machine — each would be migrated twice within weeks. The agent lane (A-1, G6)
proceeds now, unaffected. The shelved inline substrate is never migrated; it returns, if ever, as
its own project against the then-stable TEA harness.
