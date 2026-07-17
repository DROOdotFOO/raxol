# TUI Steal List — Modern Terminal Patterns for Raxol

Status: **draft / in-flight (v2)** · Date: 2026-07-12 · Owner: V + Claude

Sources: a deep-research pass (15 web claims surviving 3-vote adversarial
verification) + a Grok triad (grok-4.5 / grok-composer-2.5-fast / longcat) run
three times — score the candidate list, hunt missed patterns, review this doc.
"Triad consensus" = all three agreed independently, grounded in real files.
v2 folds in the `worktree-cross-terminal-safety-net` branch state and the review.

---

## 1. Thesis (with the honest caveat the review forced)

The winning move is **not** prettier chrome (powerline, gradients, springs).
It is that Raxol's Component tree is a *semantic structure* — feed **one tree**
to many projections:

```
                         ┌─ human keys / command palette / which-key keybar
   Component tree ───────┼─ MCP tools            (agents drive the app)
   (+ Action registry)   ├─ accessibility tree   (screen readers, raxol://a11y)
                         └─ command blocks        (jump / re-run / share output)
```

**Caveat (triad, unanimous):** this coupling does **not exist today**. There are
**five non-interoperable action planes** (see F2). The thesis is *aspirational
until F2 is built*. Two honest readings, and we pick (a):

- (a) Price F2 as a real subsystem (own design doc, effort 5–8) with explicit
  migration paths. The tree story becomes real.
- (b) Admit Phase-1 items are independent wins and "one tree" is marketing.

The Surfaces column below means **"which surfaces get a semantic projection,"
NOT "renders identically."** Input protocol and chrome (toasts, OSC emitters,
which-key) are terminal/LiveView-only — the tree is shared, the chrome is not.
MCP is snapshot/poll (`StructuredScreenshot`), **not** live rendering — it never
"displays a live tail"; it exposes resources an agent polls or subscribes to.

Two foundation pieces gate the moat: **F1** (canonical input event model +
kitty keyboard) and **F2** (the unified Action registry). Neither is cheap.

---

## 0. Already in flight — `worktree-cross-terminal-safety-net`

This branch (not yet on master) is a rendering/layout-hardening pass that
**already shipped much of the substrate** this roadmap assumed as future work.
Verify against the branch before building any item below.

| Item | Branch status | Commit |
|------|---------------|--------|
| **#3 scroll-anchor (follow-tail)** | **DONE (rule, terminal side)** — `Viewport overflow_anchor :auto\|:none`: at-bottom stays pinned as content grows, scrolled-up holds, `:none` freezes. Property-tested (follow/release/none/shrink-clamp). | 44f42315 |
| overflow / clip substrate | **DONE** — style `overflow :visible\|:hidden\|:clip\|:auto\|:scroll`, `:clip_bounds` stamping, generic paint-time clip | 44f42315 |
| **#1 finder** windowing | **DONE** — `Raxol.UI.ScrollWindow`: cursor-follow windowing + proportional thumb, property-tested ±1/step, subtle scrollbar | 4bfeb95b |
| **#7c adaptive colors** | **DONE + beyond** — H-K (Helmholtz-Kohlrausch) salience solver: palettes = (hue,chroma,tier), lightness *solved* vs OSC 11-detected ground; `persistent_term` + `:terminal_background` event | 96c93880, 884d516c |
| **#8 color-ladder** foundation | **DONE** — OSC 11 detection + DA fallback sentinel + canonical 16-color resolution | 96c93880 |
| **#6 toast** substrate | **ridable** — `absolute_layer` overlay + cell-level dim (`CellDim`, H-K contrast compression) built for modals-as-dialogs | ccbf4ea2, e76d861f |
| text ellipsis/clip/wrap | **DONE** — grapheme-safe ellipsis, `text_overflow :clip`, `line_clamp`, `text_wrap :pretty` | 4bfeb95b, 79ff03a6 |
| **#11 splits** (partial) | SplitPane `{:pct,n}` real resize done; zoom-toggle/stacked/floats absent | 79ff03a6 |
| **F1** prereqs | CSI parsing made total (no crash on private markers/intermediates); unmapped-CSI consumed whole (no fake-keystroke leak); OSC 11 query lifecycle hardened | 65bdfa62, 0aa4152d, 9398431b |
| **a11y tree** hook | text elements carry top-level `width/height/id` for accessibility mapping | 0434379d |

Effect: Phase-2 *substrate* is largely done. The true frontier is the
tree-projection items — F1, F2, #1 scorer, #2, #4, a11y — i.e. the moat.

---

## 2. Baseline (master)

Already shipped — do not rebuild, only expose/polish:

> truecolor (+ `{r,g,b}` tuple SGR on branch) · synchronized output (DEC 2026) ·
> OSC 8 hyperlinks · inline images (kitty + iTerm2 + sixel) · OSC 52 clipboard ·
> bracketed paste · alt-screen · focus manager + keyboard nav · animation hints
> (CSS-mapped for LiveView) · time-travel debugger · charts (braille_canvas,
> bar/line/scatter/heatmap) · spinner + progress (4 variants) · markdown renderer
> · tabs · modal · tree · viewport · `Raxol.Search.Fuzzy` (buffer-text search) ·
> command-palette *plugin example* · notification *plugin*

Confirmed gaps: kitty keyboard (CSI u) · canonical key Event · powerline/Nerd
Font segments · gradient fill · modal/vim editing · zoom/stacked panes ·
terminal-level hover · the unified Action registry.

---

## 3. Foundations (own design docs — do NOT start Phase 1 without these)

### F1 — Canonical input Event model + kitty keyboard protocol

Not "emit `CSI > 1 u` + enrich Event." Two features:

**F1a. Canonical key Event (prerequisite).** Four incompatible key shapes today:
`Event.key_event` → `%{key, state, modifiers: list}`; `InputParser` →
`%{key, char?, ctrl?, shift?, alt?}` (no state/mods); termbox `EventTranslator`
(`event_translator.ex:43`) → booleans + raw keycodes (`65`=Up), press-only;
LiveView `InputAdapter` → keydown only. Components pattern-match
`%Event{data: %{key: key}}` and assume `modifiers || []` the terminal path never
sets. **Define one versioned Event; converge all adapters (incl. io_terminal /
Windows) before adding release/repeat.** Otherwise the change sweeps every
`update/2` and breaks half the input components.

**F1b. Kitty keyboard negotiation.** Emit `CSI > 1 u` at startup, pop on exit
**and on crash** (leaving a shell in CSI-u mode is a stuck state). Handshake is a
state machine: query → ack / no-ack / **timeout** (name the timeout; it races the
existing OSC 11 / DA probe in `BackgroundQuery`). Fall back to legacy encoding on
no-ack. Two sides: driver-as-client (negotiate with host) **and** raxol_terminal
emulator-as-host (understand CSI-u from guest apps) — cost both.

- Effort: **5** (was mis-priced 4). Prereqs done on branch: CSI-parser hardening,
  OSC 11 lifecycle. Frontier: F1a canon + release/repeat + two-sided negotiation.
- Risk (month 2): kitty report-events multiply key traffic — without
  ignore-default for `:released`/`:repeat`, every key spams `update/2`.
- Risk (CI): `SKIP_TERMBOX2_TESTS=true` means negotiation is never regression-
  tested on the Phase-0 path. Need a mock-terminal unit test for no-ack fallback.

### F2 — Unified Action/Command registry ⚠ OWN DESIGN DOC, effort 5–8

The moat. **Five non-interoperable planes exist today** (triad-verified):

1. `Raxol.MCP.ToolProvider` / `TreeWalker` — view-tree projection, namespaces
   `submit_btn.click`; `FocusLens` caps exposure at ~15 tools.
2. `Raxol.Agent.Action` — separate behaviour, own `Schema.validate/2`, own
   `to_tool_definition` (`packages/raxol_agent/lib/raxol/agent/action.ex`).
3. `Raxol.Core.KeyboardShortcuts` — a map *passed into* `check_shortcuts/2`
   with context/priority; not a registry (`.../events/keyboard.ex`).
4. `FocusManager` — tracks a **single** focused ID under `FocusServer`; tab
   order, not actions.
5. `Plugins.CommandRegistry` — plugin handlers, not TEA. (`UxServer` hints only
   fire `set_focus`, not `update/2`.)

The thesis "one decl → four projections" has **zero structural coupling today**.
F2 must define an Action model (id, scope [global/widget/agent], enabled? guard,
message/command, key bindings, MCP inputSchema) and **absorb or bridge all five**
— notably `Agent.Action` (else two tool-derivation paths survive forever;
`vfs.ex`/`memory.ex`/`skills.ex` need migration). Crosses 3 packages
(raxol ↔ raxol_mcp ↔ raxol_agent).

Decisions the design doc must make (open):
- Does the registry **feed** MCP, or is MCP derivation **the** registry (then
  hidden/disabled actions are a bug class)?
- Palette wants app-level commands (quit, toggle-theme) that never appear in the
  tree — how do non-widget actions register?
- One focus-scope filter shared by FocusLens (≤15) + which-key + palette, or three
  re-implementations? (FocusLens *caps*; palette *reveals-all* — opposite intents.)
- Key matching must be abstract `:chord` tokens from day one, or F2 keybindings
  ship on legacy encoding and get rewritten when F1b lands (double work).

---

## 4. Roadmap (Phase 1 = the frontier; substrate mostly done on branch)

Effort 1 (hours) … 5 (weeks). Surfaces = semantic-projection reach.

### Phase 1 — tree-projection frontier (the demo story)

| # | Item | Benefit (visible) | Effort | Deps | Surfaces |
|---|------|-------------------|--------|------|----------|
| 1 | **Fuzzy finder primitive** | Prompt + streamed candidates + preview. `ScrollWindow` (branch) is the windowing substrate. **New list-scorer module** `(list, query, key_fn) → ranked` — do **not** fold `Search.Fuzzy` (that's buffer-cell search; category error). Kill the plugin's `fuzzy-search` dep. | 3 | F2 | term, LV, SSH |
| 2 | **Command palette** | `ctrl+p` fuzzy over registered actions from F2. **Retire the existing GenServer emulator-overlay plugin** (hardcoded `load_commands/0`) or you ship two palettes / two fuzzy stacks. LiveView already binds palette keys in `app.js` — F2 must own that keymap too. | 3 | 1, F2 | term, LV, SSH |
| 3 | **Scroll-anchor finish** ⭐ | Core rule **DONE on branch** (`overflow_anchor`). Remaining: emit `overflow-anchor: auto` in LiveView TerminalBridge CSS (browser-native, free); add an MCP tail **resource** (poll/subscribe, not a tool). Terminal/SSH parity already tested. | 1–2 | §0 | term, LV, SSH; MCP=resource |
| 4 | **Agent chat widgets** (MCP-derived) | streaming-markdown + collapsible tool-call + inline-diff + queued-input — each auto-derives an MCP tool. **These components don't exist yet**; each = build + `ToolProvider` impl. Moat = derivation, but only after F2 + the widgets exist. | 4–5 | 3, F2 | term, LV, MCP |
| 5 | **A11y semantic tree** | `raxol://a11y` role/name/value/live-region tree; screen readers stop scraping cells. Needs `@mcp_role`/`@aria_label`/live-region **added to the component contract** (`ContextTree.sanitize_tree` drops non-semantic today). Branch added `id` on elements = starting hook. **Not** "small once F2 exists" — its own cross-cutting metadata pass. | 4 | F2-ish | term, LV, MCP |

⭐ = was the triad's #1 reorder; now a finishing task thanks to the branch.

### Phase 2 — discoverability + polish (substrate mostly on branch)

| # | Item | Benefit | Effort | Deps | Surfaces |
|---|------|---------|--------|------|----------|
| 6 | **Toast component** | Corner-stacked, auto-dismiss, severity. **Rides `absolute_layer` + `CellDim`** (branch). Route the same event to OSC 9 desktop-notify + Telegram + Watch. | 1 | §0 | term, LV (not MCP chrome) |
| 7 | **Which-key keybar** | Focused-pane keys; `?` cheatsheet; partial `g…` chord popup. Projection of F2 — needs **shared cross-surface focus** (today `FocusServer` is single-ID; `TEALive` runs a separate Lifecycle → collision/divergence risk). | 3 | F2, F1b | term, SSH, LV |
| 8 | **Styling slices** | adaptive colors **DONE (H-K, branch)**. Remaining: border presets `:rounded/:double/:heavy`; per-cell **gradient fill** — trivial on truecolor, but 256-color needs downsample-with-banding or reject branch (that's where the effort is). | 2 | §0 | term, SSH |

### Phase 3 — deferred / needs a forcing app

| # | Item | Note | Effort |
|---|------|------|--------|
| 9 | **Powerline/Nerd Font segments** | Cosmetic, unblocks nothing. Demoted from T1. ASCII fallback on capability detect. | 2 |
| 10 | **Keymap modes** (helix-style) | Optional modal layer over MultiLineInput. Ship the *layer*, not an editor. | 4 |
| 11 | **Zoom + stacked/floating panes** | SplitPane ratios done (branch). But `terminal/split/split_manager.ex` is a **terminal-IO multiplexer, not TEA layout** — zoom/stack needs the split state relocated into TEA model (a *different* dep than F1). | 5 |

### Cut (triad consensus — traps)

| Item | Why |
|------|-----|
| **Spring animation** | Wrong layer; CSS path exists on LiveView. 3/3. |
| **Notcurses inversion as a *project*** | Surfaces diverge on rendering truth (termbox2/DOM/byte-stream/MCP). Keep only as per-feature fallback *policy* (folded into #8). 3/3. |
| **Unicode-placeholder image cells** | 3 image protocols already ship; correctness sink under scroll/select. Revisit only if the layout engine needs stable cell occupancy for non-sixel protocols. 2/3. |
| **"Operation-log undo ≈ free beside time-travel"** | Wrong. TimeTravel = full-model snapshots per `update/2`; undo needs `{op, inverse}` with *external* side effects (payments/ACP). Inverse of "paid $0.40 via Xochi" is not a model rewind. Different subsystem. |

---

## 5. New finds from the research triad (backlog, not Phase 1)

Bold = both research models named it independently.

Feed-the-tree: **a11y side-channel** (now Phase-1 #5) · **command blocks** (Warp/
Wave; needs OSC 133 emulator support — Phase-3-sized, don't dress as filler) ·
**Television "channels"** (pluggable fuzzy sources incl. MCP tools — upgrades #1).

Cheap emitters (~hours each, terminal-only): **OSC 9;4** host progress · **OSC 9**
desktop notify (route to #6) · **OSC 22** pointer shape · colored/dotted underlines
(SGR 4:3-5) · sub-cell fractional block gauges (`▏▎▍▌▋▊▉`) · dual-layer charts
(half-block fill + braille edge — composites two passes already present).

Structural: session resurrection (Zellij; serialize Lifecycle tree → ETS) · async
task manager (Yazi; `Task.Supervisor`) · HITL↔YOLO autonomy dial (generalizes
`raxol_payments` SpendingPolicy to all agent actions) · presenterm slides ·
hardware-cursor-as-a11y-focus. **Dual-face pipe mode** — deferred: Lifecycle
renders every `update/2`; per-session render toggle is a Lifecycle behavior change,
not "a flag."

---

## 6. Dependency graph + sequencing

```
F1a event-canon ─► F1b kitty-kbd ─► 10 keymap-modes
                              └────► 7 which-key chords

F2 registry (absorbs Agent.Action + KeyboardShortcuts + ToolProvider + CommandRegistry)
     ├─► 1 finder ─► 2 palette ─► 7 keybar     (one focus-scope filter, shared)
     ├─► 4 chat-widgets   ├─► 5 a11y tree (+ component-role metadata pass)
     └─► command blocks (Phase 3)

§0 branch ─► 3 scroll-anchor finish (LV emit + MCP resource)
         ─► 6 toast (absolute_layer/CellDim)
         ─► 8 styling (adaptive colors done; add borders+gradient)

11 splits: relocate split_manager IO→TEA state  (NOT an F1 dep)
```

**Order:**
1. **Land the branch** — it unblocks #3/#6/#8 substrate and F1 prereqs.
2. **Write the F2 design doc** (effort 5–8; the moat stands or falls here).
3. **F1a canonical Event**, then **F1b kitty** — before any keybinding work, so
   chords aren't built twice. Use abstract `:chord` tokens from day one.
4. **#3 scroll-anchor finish** — fastest visible win, mostly done.
5. **#1 finder → #2 palette → #7 keybar** — one source, one focus filter.
6. **#5 a11y tree** — unique win, but budget the component-role metadata pass.
7. **#4 chat widgets** — the multi-surface headline, after F2 + widgets exist.
8. Phase 2/3 + cheap OSC emitters on demand.

**Do not** trust the old effort-3 on F2, effort-4 on F1, or any "all surfaces"
claim — all corrected above. Every F2-projection item crosses ≥2 package
boundaries; effort estimates include that integration or they lie.

---

## 7. Open gaps needing author input

- G-F2: registry-feeds-MCP vs MCP-is-registry (§3 F2). Gates hidden/disabled-action semantics.
- G-a11y: is the component-role metadata pass Phase-0 foundation or Phase-1 feature? (§4 #5)
- G-focus: single shared `FocusServer` across surfaces vs per-surface focus — which-key needs the former (§4 #7).
- G-test: F2 "one action → N identical projections" wants a **property test** mirroring the existing MCP functor-law tests. Name it before building F2.
