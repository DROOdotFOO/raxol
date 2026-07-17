# Harness Gundam Widgets — wiring proposal

Scouted at `origin/integration/harness-endgame` (`716354375`), 2026-07-17. Read-only pass;
no code changed. Companion to `harness-visual-doctrine.md` (§2 zone ontology, §3 clocking
law, §5.3 binding contract, §5.5 lifecycle) and the #629 panel machinery
(`lib/raxol/harness/panel_projection.ex`, `surface.ex` `open_panel`).

The one-line thesis: **the footer panel machinery is already the doctrine's rim in
miniature** — recompute-per-paint memoized on journal length *is* the event clock — and
almost every gundam widget is already a pure function. The work is (a) generalizing
PanelProjection's closed 3-kind enum into a declared-binding widget registry, (b) one small
cells→rows adapter so the cell-emitting widget corpus can ride ViewText, and (c) two thin
MCP seams that both go through `Raxol.MCP.Registry` / `Raxol.MCP.Client` directly, because
the harness has no Component tree for the TreeWalker to walk.

---

## 1. Widget inventory (what exists, what feeds it, what it can ride)

Rendering primitive legend: **cells** = `{x, y, char, fg, bg, attrs}` tuples; **view** =
View-DSL maps (`%{type: :column/:row/:text}`); **Component** = `Base.Component` behaviour.

| Widget | Where | Feed today | Purity | Emits | Harness-fit |
|---|---|---|---|---|---|
| Sensor gauge / sparkline / threat / minimap | `packages/raxol_sensor/.../hud.ex` | args (region, value/data, opts) | pure | cells | **cheap** via cells→rows adapter; gauge/sparkline/threat are 1-row native |
| HUDOverlay | `packages/raxol_sensor/.../hud_overlay.ex` | Fusion `{:fused_update,...}` sub | GenServer glue | writes cells to a buffer pid | **not portable as-is** (direct-buffer); its layout→HUD mapping is the part worth stealing |
| Swarm wingmate summary / comms bars | `lib/raxol/swarm/overlay_renderer.ex` | overlay-state map arg | pure | cells | **cheap** via adapter; 1-row-per-node, staleness dimming already matches doctrine |
| Swarm tactical grid | same module `render_overlay/2` | TacticalOverlay entities | pure | cells | fits at reduced height (footer slot ≈ 6–10 rows); needs height parametrization |
| TacticalOverlay | `lib/raxol/swarm/tactical_overlay.ex` | CRDT + peer sync | GenServer (data owner, not visual) | — | stays outside; it is a *source*, never a widget |
| LineChart / ScatterChart / BarChart / Heatmap | `lib/raxol/ui/charts/*.ex` | args (region, series, opts) | pure (stateless) | cells (braille/blocks) | rides adapter; heatmap color fidelity degrades (ViewText `:bg` is a tint vocabulary, not arbitrary 24-bit bg) |
| BrailleCanvas | `lib/raxol/ui/charts/braille_canvas.ex` | struct accumulator | pure | cells | substrate, not a widget |
| ViewBridge | `lib/raxol/ui/charts/view_bridge.ex` | cells | pure | view (absolute-positioned) | **wrong bridge for panels** — ViewText flattens one line per leaf and ignores positioning; hence the new adapter below |
| View-DSL chart facade + `sparkline/1` | `lib/raxol/view/components.ex:434-585` | opts | pure | view | sparkline-as-text-row ports trivially via `Sensor.HUD.render_sparkline` instead |
| ZERO cockpit: boot self-check | `examples/agents/zero_system.exs:545-584` | `model.checks` (real `Code.ensure_loaded?` probes) | pure projection | view | maps to the doctrine's POST boot beat — a *log* ceremony, not a rim widget |
| ZERO cockpit: funnel/tactical pane | `zero_system.exs:688-719` | TacticalOverlay entities polled per tick | pure projection | view (hand-rolled grid) | superseded by OverlayRenderer port; don't port the hand-rolled grid |
| ZERO cockpit: spend ledger pane | `zero_system.exs:721-757` | in-demo ledger mirror | pure projection | view | port = rebind to real `Payments.Ledger` / journal spend receipts; text rows, cheap |
| ZERO cockpit: LLM reasoning pane | `zero_system.exs:655-671` + LLM Agent | `ZeroSystem.LLM` Agent buffer (SSE) | view is pure; feed is a process | view | **do not port** — the harness log already renders reasoning blocks; a rim copy would be register bleed (doctrine §2) |
| Harness meters (Drift/Context/Spend) | `lib/raxol/ui/components/harness/*_meter.ex` | props | Component (inert events) | view via Progress.Bar | moderate — needs calling `render/2` as a pure fn outside the Component runtime, or re-expressing as 1-row text meters |
| DiffViewer / DiffExpansion | `lib/raxol/ui/components/harness/diff_viewer.ex`, `lib/raxol/harness/diff_expansion.ex` | `:diff` block content (`%{path, old, new}`) | pure | view / styled rows | already has its own dedicated expansion path; not a panel widget (see §6 adjacent finding) |

"gundam" literally appears only in `README.md:157` (origin story) and ADR-0012:147; the
ZERO System cockpit (`G.U.N.D.A.M.` backronym, `zero_system.exs:554`) is the actual gundam
dashboard, and all five of its panes are pure projections of a TEA model — the porting
question is purely *rebinding their sources*, never rewriting render logic.

**The one honest rewrite class:** anything that *writes* to a buffer/IO directly
(`HUDOverlay`, `sensor_hud_demo.exs`'s `IO.puts` loop) cannot ride ViewText and should not
be ported — their pure cores (`Sensor.HUD.*`) ride instead.

---

## 2. Binding contract v1 — `{source, fold, view}` on the PanelProjection chassis

Doctrine §5.3: widget = pure mapping from a declared source to the primitive vocabulary;
unbound = unrepresentable; widget programs journaled. The smallest honest v1, given what
exists:

### 2.1 The spec

```elixir
%Raxol.Harness.WidgetSpec{
  id: "swarm_wingmates",              # kind; unique, journaled
  title: "WINGMATES",                  # rim register: UPPERCASE instrument label
  source: source(),                    # DECLARED — see below
  fold: (source_data -> widget_state), # pure, bounded (byte + entry clamps)
  view: (widget_state, geom -> [row])  # pure, rows = ViewText view-maps
}

source ::
    {:journal, filter}          # fold over Projection.source_events — the native case
  | {:model, path}              # pure read of a harness model path
  | {:mcp_tool, server, tool, args}   # last-sample cache in model (see §3b)
```

- **Unbound unrepresentable:** `WidgetSpec.validate/1` refuses a spec whose source doesn't
  resolve (unknown journal class, dead model path, unregistered MCP server) — same shape as
  `BodyProvider.validate/2` refusing malformed `:diff` content, and `open_widget` returns
  `{:error, :unbound_widget}` exactly like `open_panel`'s `{:error, :no_footer}` family.
- **Pure + bounded:** fold inherits PanelProjection's hostile-content clamps
  (`@max_field_bytes 512`, `@max_entries 500`, `panel_projection.ex:71-72`) as a shared
  helper, not per-widget discipline.
- **Journaled:** opening a widget appends a `%{family: :meta, type: :widget, op: :grown,
  spec_ref: ...}` event *before* the panel opens; closing/settling appends `op: :settled`
  with the receipt. The grown cockpit is then itself a journal fold — respawn replays it,
  and the time-travel debugger can scrub to the moment an instrument appeared (§5.3's
  requirement, and it falls out of machinery the harness already trusts).
- **Returned-effect set is empty** in v1 (doctrine §5.1): `OverlayPanel.handle_key/2`
  already structurally guarantees this — it can only return `{:continue, t}` or
  `:dismissed`, never `{:picked, _}` (`overlay_panel.ex:144`). v1 changes nothing there.

### 2.2 What changes in existing modules (all small)

- `PanelProjection.kinds/0` (`:75`, closed `[:worktracks, :memory, :plan]`) generalizes to
  a spec registry; the three existing kinds become the first three built-in WidgetSpecs
  with `{:journal, class: ...}` sources — zero behavior change, pure re-plumbing.
- `Surface.refresh_panel_overlay/1` (`surface.ex:3865`) keeps its `folded_at` memoization
  for `{:journal, _}` sources (re-fold only when the journal grew — **this is the event
  clock**); `{:model, _}` and `{:mcp_tool, _}` sources memoize on their cached sample's
  `received_at` instead.
- `OverlayPanel` stays the host unchanged: title row + `max_visible` text rows, scroll +
  esc, footer-grow via `InlineAuthority.set_footer_rows/2`, one overlay at a time.

### 2.3 Honest distance from the full doctrine

- §5.3 says widget programs are *Arrival scheme fragments* — agent-composable data. v1
  specs are Elixir-defined (fold/view are compiled closures), so they are journaled by
  *reference* (spec id + source args), not as interpretable programs. Agent-*authored*
  widgets need the interpreter and are v2; v1 must only avoid painting us out (the spec
  boundary is already program-shaped: `{source, fold, view}` is exactly what a scheme
  fragment would compile to).
- Glass walls (§4.4): the panel title row gains an inspect affordance later; v1 minimum is
  that the `op: :grown` journal event carries the full source declaration, so provenance is
  *queryable* even before it's *displayed*.

---

## 3. MCP wiring

Ground truth first: `grep -rin mcp lib/raxol/harness/` → **zero hits**. The harness is a
pure `new/update/render` map machine below the TEA pipeline (`surface.ex:14-21`) — there is
no Component tree, so `Raxol.MCP.TreeWalker`/`ToolProvider`/`ToolSynchronizer` (the whole
derive-from-view-tree stack, including the FocusLens) **does not apply**. Both directions
instead use the direct APIs, which exist and need no behaviour:

### 3a. Inbound — panel state as derived tools (agent lane)

`Raxol.MCP.Registry.register_tools/2` (`registry.ex:74`) takes plain
`%{name, description, inputSchema, callback}` maps — anything can register. Wiring:

- On `op: :grown` for widget `w`, register `harness.panel.{w.id}.read` whose callback runs
  the *same fold* the paint path runs and returns `%{state: fold_output, lines:
  render rows, binding: source declaration, folded_at: offset}` — the tool and the screen
  are provably the same projection (glass walls for free), and "read the swarm topology"
  is exactly this tool against the wingmates/tactical widget.
- Register one resource `raxol://harness/panels` (`register_resources/2`, `:167`) listing
  open widgets + bindings.
- On `op: :settled`, `unregister_tools/2`. Tool lifecycle = widget lifecycle = journal
  events; an MCP client's `tools/list_changed` view of the cockpit is event-sourced too.
- **v1 tools are read-only** — matches doctrine §5.1 (representation only). Action tools
  ("acknowledge threat") are v2, gated on the interactive binding contract and the
  label-vs-binding falsifier; the OverlayPanel `{:picked, _}` return channel is where they
  would land.
- Guard: raxol_mcp presence via `Code.ensure_loaded?(Raxol.MCP.Registry)` +
  `@compile {:no_warn_undefined, ...}` per package convention; the harness must run
  identically with no MCP registry process (registration is best-effort, never load-bearing
  for the paint path).

### 3b. Outbound — MCP tool output as a widget source (agent lane)

Honest capability audit of `Raxol.MCP.Client` (`client.ex`): **stdio transport only**,
speaks `initialize`/`tools/list`/`tools/call` only — **no `resources/read`, no
`resources/subscribe`**. The ADR-0012 "context tree streamed as diffs" direction is
implemented only on the *server* side (`ToolSynchronizer.sync_model_resources/2` +
`Server` `resources/subscribe`); nothing today consumes a remote MCP resource into a TEA
model. So "widget subscribes to an MCP resource" is **not buildable in v1** without client
work — declare it, don't fake it.

What IS buildable honestly: `{:mcp_tool, server, tool, args}` as a *sampled* source.

- A small `Harness.McpSource` process (agent lane) owns the `MCP.Client` sessions. It
  calls `Client.call_tool/4` and delivers `{:mcp_sample, widget_id, result, received_at}`
  into the surface's normal input path; `update` caches the sample in the model and
  repaints. The arrival **is a real event**, so the repaint is doctrine-legal motion
  (§3: "spinners/meters tick on event arrival"); the widget renders the sample dim/italic
  with its age (`via mcp:{server}.{tool} · 3s ago`) — the waiting state stays evidential.
- Refresh policy, in doctrine order of preference: (1) event-clocked — re-sample when the
  journal grows past the widget's `folded_at`, piggybacking the existing memoization; (2)
  explicit user poke (panel refresh key); (3) timer cadence as a last resort, and if used,
  the *sample arrival* is still the only thing that moves pixels. The widget spec is
  journaled; the samples are **not** appended to the durable journal (they are model state,
  which §5.3 explicitly permits as a source) — keeps telemetry out of the transcript's
  event-sourced history while every rendered value stays traceable to a declared binding.
- Client gap to file for later (not v1): `resources/read` + `resources/subscribe` on
  `MCP.Client`, which would upgrade sampled sources to pushed ones and let a Raxol harness
  watch *another* Raxol session's model resources (`raxol://session/{id}/model/*`) — the
  ADR-0012 remote-viewport story, currently server-half only.

---

## 4. Rim lifecycle (§5.5) vs. what the footer hosts today

What exists: `footer_frame/1` composes ordered honest-fit groups (`status`, `lane`,
`submitting`, `overlay`, `divider`, `preview`, `composer`, `notice`); **one** overlay slot
(panel XOR picker); StatusStrip is the only always-on rim lane. **No rim, blink, breathe,
or event-clock machinery exists by those names** — but the substance of "breathes
event-clocked" already does.

| Doctrine phase | Footer today | v1 mapping | Absent / deferred |
|---|---|---|---|
| **grown** (work exists → instrument appears, program journaled) | `open_panel` via keys/palette only | `op: :grown` journal event + open; opened by user key in v1, by fold-detected work (e.g. first `:tool_call` block of a class) in v1.5 | auto-grow policy; the pin/accretion engine (doctrine §9 defers it to `adaptive/`) |
| **live, breathes with its source** | `refresh_panel_overlay/1` re-folds **only when `length(source_events)` grew** (`surface.ex:3872-3891`) | nothing to build — this memoization *is* event-clocking; tempo = journal event rate by construction | multi-instrument rim: only ONE overlay at a time. Cheapest honest extension when needed: a new `rim` footer group of 1-row instruments inside `fit_footer_groups/3`, distinct from the overlay slot |
| **completion blink** (single event-driven flash) | no one-shot flash machinery; paints happen on input/`advance` only | v1 substitute: the paint that carries the completion event renders the panel title reversed/emphasized once; a true decaying flash needs a follow-up repaint tick | defer real blink until it can ride the existing `stream_cadence`/`cadence_policy` path — do **not** add a timer for it (falsifier #2) |
| **settled** (dies into the log as fact line + receipt) | `close_overlay/1` restores footer; nothing lands in the log | `op: :settled` meta event carrying the receipt (counts, duration, source); BlockBuilder gains one small clause to render widget receipts as fact lines | BlockBuilder today emits only `:message/:reasoning/:tool_call/:approval`; the receipt-line clause is a real (small) extension, listed as its own unit |
| **pinned** | n/a | out of scope | doctrine §9 open decision |

Also honest: `status.now`/`last_event_at` are caller-supplied integers — the harness keeps
no wall clock internally, which is exactly the right substrate for the clocking law.

---

## 5. Build units, ordered

Lane split per the session accord: **harness-ui** = components/rendering/panel machinery;
**agent** = agentic layer + protocol (MCP, ACP, adapters).

| # | Unit | Lane | Size | Contents / dependencies |
|---|---|---|---|---|
| G1 | **WidgetSpec + registry generalization** | harness-ui | M | `WidgetSpec` struct + validate (unbound-refusal); `PanelProjection` kinds → registry with the 3 existing kinds as built-in specs (zero behavior change, golden-tested); `op: :grown/:settled` meta events; `refresh_panel_overlay` source-aware memoization. No new host — OverlayPanel unchanged. |
| G2 | **CellRows adapter + first ports** | harness-ui | S–M | `cells → [styled row view-maps]` (group by y, merge runs, clamp to ViewText's `:fg`/`:dim`/`:bg`-tint vocabulary — NOT ViewBridge, which targets the positioned pipeline). Port the cheap trio: `Sensor.HUD.render_sparkline` + `render_gauge`, `OverlayRenderer.render_wingmate_summary`. Depends G1. |
| G3 | **Settlement fact line** | harness-ui | S | BlockBuilder clause rendering `op: :settled` receipts as log fact lines; completion-paint emphasis (no timer blink). Depends G1. |
| G4 | **MCP inbound: panel tools** | agent | S–M | `Registry.register_tools/unregister` on grown/settled; `harness.panel.{id}.read` + `raxol://harness/panels` resource; `Code.ensure_loaded?` guards. Depends G1; independent of G2/G3. |
| G5 | **MCP outbound: sampled tool source** | agent | M | `Harness.McpSource` (owns `MCP.Client` stdio sessions), `{:mcp_sample, ...}` delivery into surface update, model-cached last sample + age rendering, event-clocked resample policy. Depends G1. |
| G6 | **ACP diff producer** (adjacent, found during scout) | agent | S | `AcpStreamAdapter` currently `inspect/1`s away ACP's first-class `{:diff, %Diff{path, old_text, new_text}}` tool-call content (`acp_stream_adapter.ex:398`); destructure it into a `:diff` contract event so `Block.extract_diff_content/1` → DiffViewer/DiffExpansion light up. The `:diff` kind exists end-to-end in render with **no wire producer** (`block.ex:1246-1253`). Independent of G1–G5; separate PR. |
| G7 | **MCP.Client resources** (deferred) | agent | M | `resources/read` + `resources/subscribe` on the client → pushed widget sources, cross-session remote viewports (ADR-0012's missing client half). Not v1. |
| — | v2: interactive bindings, agent-authored widget programs (Arrival), multi-instrument rim group, pins | both | — | gated on doctrine §9 decisions; v1 records the seams (spec boundary is program-shaped; `{:picked,_}` channel reserved; `rim` group sketched). |

Port-cost verdicts: **cheap** — sparkline, gauge, threat line, wingmate summary, comms
bars, ledger/receipt pane (text rows); **moderate** — tactical grid (height
parametrization), charts (adapter + color degradation), harness meters (Component render
outside the runtime); **do not port** — HUDOverlay and anything writing bytes/buffers
directly, ZERO's reasoning pane (register bleed with the log), ZERO's hand-rolled grid
(superseded by OverlayRenderer).

---

## 6. Consolidated honest absences

1. Harness has **no MCP surface at all** today; TreeWalker/FocusLens/ToolSynchronizer are
   Component-tree machinery and structurally inapplicable — both seams go through the
   direct Registry/Client APIs.
2. `MCP.Client` cannot read or subscribe to resources (stdio + tools only); "widget
   subscribes to MCP resource" is unbuildable until G7. ADR-0012 diff-streaming exists
   server-side only.
3. Only **one** overlay at a time; there is no multi-instrument rim. StatusStrip is the
   sole persistent rim lane.
4. No blink/flash machinery; a true completion blink needs the cadence path, deferred.
5. Widget programs are compiled Elixir in v1, journaled by reference — not yet the
   agent-composable Arrival fragments of §5.3.
6. Panels are structurally read-only (`OverlayPanel` has no `{:picked,_}` return);
   interactive affordances and action tools are v2.
7. ViewText's style vocabulary (`:fg` 24-bit, `:dim`, `:bg` tint set) degrades heatmap /
   full-color chart fidelity; charts port with reduced palettes.
8. No producer emits `:diff` blocks anywhere today (G6 closes it); ACP's `old_text` is
   optional on the wire — absent means new-file, not "diff unavailable".
9. `PanelProjection` folds only `%{family: :meta, type: :extract}` events; G1's
   generalization is a prerequisite for every journal-sourced widget.
