# Harness Widgets — blocks, tool rendering, the binding contract, grown instruments

Fused from: `../proposals/in-flight/harness-gundam-widgets.md` (scout +
wiring proposal, 2026-07-17), `harness-confirmation-ui.md` Piece 2,
`harness-visual-doctrine.md` §5, `pierre-diffs-analysis.md` /
`shiki-elixir-analysis.md` (diff rendering lineage), and the V tool-render
rulings of 2026-07-18. Build-status labels are explicit.

---

## 1. The block model (BUILT)

One tool call = one collapsible semantic unit with outcome metadata on the
row (exit, duration, cost). Kinds: `:message | :reasoning | :tool_call |
:diff | :approval`. Blocks derive from durable journal events only
(`item_delta` feeds the live tail, never a durable block); the projection is
deterministic from offset 0; fold state is UI-local. Bodies mount through
`BodyProvider` with schema validation and a rescue-to-error-block fallback
(a schema-valid-but-crashing body must not escape to the render loop — the
T5 lesson). A flat/linear mode is a first-class rendering (the a11y, pipe,
and block-hater answer at once — AD-U2).

**Tool render (V-ruled 2026-07-18, settled):** a tool is **one
low-prominence line updated in place** — `⚙ name (args) · ✓ receipt ·
duration` — with NO separate Tool Result block, foldable to the full body.
Reasoning collapses to one dim `∴` line, peekable. A running tool line
carries the braille spinner (`⠋⠙⠹…`) in its col-0 margin cell, riding the
existing tick machinery (never a new timer), dim, replaced by the final
state glyph on completion. This is the grok-build register with our honesty
wiring: the receipt is the evidence surface (doctrine falsifier 5).

## 2. Widget doctrine (SETTLED — the laws any widget work must honor)

From doctrine §5, restated as the review contract:

1. **v1 widgets are read-only projections** — live statuses of ongoing
   processes; the returned-effect set is empty. Interactive widgets are v2,
   gated on the binding contract + the label-vs-binding falsifier.
2. **The binding contract:** a widget is a pure mapping from a *declared*
   data source to a view built from the primitive vocabulary (flex,
   overflow, markdown, role tokens — expressive enough for any instrument,
   too poor to fabricate). **An unbound widget is unrepresentable** — the
   registry refuses it.
3. **Widget programs are journaled data:** the grown cockpit is itself
   event-sourced (`op: :grown` / `op: :settled` meta events) — respawn
   replays it; the time-travel debugger can scrub to the moment an
   instrument appeared.
4. **Request, never claim:** a widget declares intrinsic content + semantic
   role; flex grants space, H-K grants prominence. Two solvers, one economy.
5. **Lifecycle:** grown → live (breathes with its source, event-clocked) →
   completion blink (single event-driven flash) → settled (dies into the log
   as a fact line + receipt) → optionally pinned. Nothing accretes
   unboundedly.

## 3. Tool-widget router (PROPOSED — confirmation-ui Piece 2)

A registry mapping tool identity → expanded-representation widget, the same
`{source, fold, view}` spine as §4 and F2's `id + run→[effect] + projection`
— defined harness-local, shaped to fold into either verbatim on convergence.

`Raxol.Harness.ToolWidget.Spec` = `{id, match, fold, view}`; first matching
spec wins; **`:compact` is the terminal fallback — unbound → fallback, never
crash**. Built-in specs: `:diff` (edit/write payload → DiffViewer),
`:command` (bash/shell → command line + streamed tail), `:file_excerpt`
(read), `:match_list` (glob/grep, clamped), `:compact` (the `⚙` one-liner).
Every spec ships a playground wrapper demo whose fixture IS the tool payload
the router keys on.

## 4. Gundam widgets — the grown-instrument wiring (PROPOSED, scouted 2026-07-17)

The scout's thesis: the footer panel machinery is already the doctrine's rim
in miniature — `PanelProjection`'s re-fold-only-when-the-journal-grew
memoization *is* the event clock — and almost every candidate widget is
already a pure function. The work:

- **G1 `WidgetSpec` + registry:** `%WidgetSpec{id, title, source, fold,
  view}` with `source :: {:journal, filter} | {:model, path} |
  {:mcp_tool, server, tool, args}`; `validate/1` refuses unresolvable
  sources (unbound unrepresentable); folds inherit the shared hostile-content
  clamps (byte + entry caps). `PanelProjection`'s closed kind enum
  generalizes to the registry with the three existing kinds
  (worktracks/memory/plan) as built-in specs — zero behavior change.
- **G2 cells→rows adapter:** the cell-emitting corpus (sensor gauge/
  sparkline/threat line, swarm wingmate summary/comms bars, charts at
  reduced fidelity) rides ViewText through one small adapter. Port verdicts:
  **cheap** — sparkline, gauge, threat, wingmates, comms, ledger pane;
  **moderate** — tactical grid, charts, harness meters; **do not port** —
  anything writing bytes/buffers directly (HUDOverlay), ZERO's reasoning
  pane (register bleed with the log), hand-rolled grids.
- **G3 settlement fact line:** BlockBuilder clause rendering `op: :settled`
  receipts as log fact lines; completion emphasis on the paint that carries
  the event (a true decaying blink waits for the cadence path — no timers,
  falsifier 2).
- **G4 MCP inbound:** on grown, register `harness.panel.{id}.read` whose
  callback runs the SAME fold the paint path runs (tool and screen provably
  the same projection — glass walls for free) + a `raxol://harness/panels`
  resource; unregister on settled. Best-effort, never load-bearing for the
  paint path. v1 tools read-only.
- **G5 MCP outbound (sampled source):** `Harness.McpSource` owns stdio
  client sessions; `{:mcp_sample, id, result, received_at}` arrives as a
  real event (doctrine-legal motion); widgets render the sample dim with its
  age (`via mcp:server.tool · 3s ago`); samples cached in the model, NOT
  journaled.
- **G6 ACP diff producer (adjacent find):** the `:diff` block kind exists
  end-to-end in render with **no wire producer** — the stream adapter
  `inspect/1`'d away ACP's first-class diff content (as scouted at
  `716354375`). Destructure it into the `:diff` contract event so
  DiffViewer/DiffExpansion light up. Small, independent PR.
- **G7 MCP.Client resources (deferred):** the client is stdio+tools only —
  **no `resources/read`/`resources/subscribe`**; "widget subscribes to an MCP
  resource" is unbuildable until G7, which also unlocks the ADR-0012
  remote-viewport story (currently server-half only). Declared, not faked.

**Honest absences (as scouted):** the harness has no MCP surface at all;
TreeWalker/FocusLens/ToolSynchronizer are Component-tree machinery and
structurally inapplicable (the harness is a pure map machine below the TEA
pipeline) — both seams go through the direct Registry/Client APIs. Only one
overlay at a time; StatusStrip is the sole persistent rim lane (a
multi-instrument `rim` footer group is the cheapest honest extension when
needed). v1 widget programs are compiled Elixir journaled by reference — the
agent-composable Arrival fragments of doctrine §5.3 are v2; the
`{source, fold, view}` boundary is already program-shaped so v1 doesn't
paint us out.

## 5. Diff rendering (BUILT; producer gap open)

DiffViewer/DiffExpansion implement the Pierre-lineage model (see
`pierre-diffs-analysis.md`, `shiki-elixir-analysis.md`): syntax-under-diff,
full policy set, long lines never silently truncate, expandable toward
full-screen review from the approval prompt (T24 — the highest-reaction pain
cluster in the cohort given a deliverer). The known end-to-end gap is G6
above: no producer emits `:diff` blocks on the wire (ACP `old_text` is
optional — absent means new-file, never "diff unavailable"). Salience note:
the light-ground fade inversion (F1) and the legibility clamp (F2) found by
the T8 suite design are T8-owned requirements.

## 6. The convergence rule (bind on all three registries)

Three PROPOSED registries share one spine and must stay foldable into each
other and into F2 when it lands:

| registry | shape | interactivity |
|---|---|---|
| WidgetSpec (§4) | `{source, fold, view}` | read-only, `{:picked,_}` dark |
| ToolWidget.Spec (§3) | `{match, fold, view}` | read-only representation |
| Completer.Spec (interaction §4) | `{trigger, query, insert}` | lights `{:picked,_}` |

Same clamps, same unbound-refusal discipline, same journaling posture.
Anyone adding a fourth registration surface must either reuse one of these
or state why the isomorphism breaks.
