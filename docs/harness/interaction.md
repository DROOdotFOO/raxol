# Harness Interaction — speakers, input, commands, confirmations

Fused from: `../proposals/in-flight/harness-speaker-separation.md` (RATIFIED
+ amended), `harness-composer-commands.md` (PROPOSED), `harness-confirmation-ui.md`
(PROPOSED), the T11/T12/T14/T25 unit specs in `harness-ui-roadmap.md`, and the
V-ratified rulings of 2026-07-17/18. Build-status labels are explicit; nothing
marked PROPOSED is shipped.

---

## 1. Speaker separation (SETTLED LAW — V-ratified 2026-07-17, landed)

Mirrored outer-contour chevrons carry authorship; nothing else does:

- User `❯` at column 0, inside the 1-cell margin, touching the border; user
  text at the 2-cell content indent, wraps hang-aligned at column 2.
- Assistant `❮` at the same outer position; assistant prose at column 2. The
  mirrored pair IS the speaker grammar.
- Both sigils **bold** (structure channel), **zero color** (doctrine §6:
  color encodes state, never speaker). Sigil fade binds to the block's own
  body fade (single-fg rule); sealed bytes must not depend on reveal cadence.
- Capability fallback degrades the pair together: `❯`/`❮` → `>`/`<` under
  `unicode: :none`; all four single-cell (TextMeasure-pinned).
- One sigil source per speaker (`model.sigil` / `model.reply_sigil`), decided
  once from the capability record — the composer's live `❯` shares the
  constant, so echo and prompt can never drift.
- Machinery blocks (tool `⚙`, system glyphs) keep the plain 1-column margin:
  dialogue is marked at the contour, machinery stays inside the frame. Folded
  headers keep the margined header column (`▸ ❯ …` user / `▸ » …` assistant).
- Blank-row rhythm stays the turn separator (the page breathes).

**Decision history (compact):** the `[assistant]`/`[user]` tagline was
rejected (mechanistic, spends a row, role-colored — and mostly constant due
to a role-population gap). Of the three achromatic grammars —
(A) chevron-echo rhythm, (B) achromatic user rail, (C) ruled turn boundary —
A was recommended and ratified; B was the fallback for fast vertical
scanning; C rejected (marks *where*, not *who*, and collides with the unread
divider's vocabulary). V then amended A: instead of "assistant = bare
unmarked prose", the assistant gets the inverse chevron at the outer contour
and all dialogue sits at one uniform indent. Sigils are the only col-0
dwellers (the braille spinner rides the margin cell of a running tool line —
doctrine §7.5).

## 2. The input zone (BUILT)

The composer is the **single truth of the logical draft**: a logical
substrate projected through WrapMap into visual rows — the visual layer is
re-derived on render, never written back. Consequences that bind every
feature touching input:

- Readers read the logical value (`Composer.value/1`); writers are surgical
  logical edits (`apply_continuation/2`-style span replacement, never
  whole-buffer `set_value/2` when a span is known).
- Geometry questions (cursor row, boundary detection) read WrapMap-derived
  facts (`vrow`, `row_count/1`), not re-computed heuristics.
- Multi-line editing, bracketed paste, history recall, queued-steer display
  (steer text visibly parked "for next boundary"), resize survival — T11.
- `$EDITOR` suspend/resume and SIGTSTP/`fg` job control share one
  save/restore path — T25.
- The composer renders its placeholder iff empty and unfocused — a property
  other components (SelectorWithComposer §5) get for free.
- Input is pinned at the screen bottom always (V ruling; chat semantics).

## 3. Keymap and command routing (BUILT)

- **Keymap-first dispatch**: every input path resolves the keymap before the
  composer; `:always` binds (ESC = interrupt, Tab = steer) work mid-typing.
  Component-first wiring is the named dead end (kills ESC-interrupt).
- **Command bifurcation:** `:interrupt`/`:steer` cross the lane boundary as
  `%Command{}`; `:fold_toggle`/`:jump_*` stay UI-local. The wire is the
  frozen codec (grow-only; `:steer` growth signed off cross-lane 2026-07-17).
- **^C always double-press** (node semantics); `q`-on-empty single-press.
- **Fresh session default** — resume is explicit (`--resume`/picker), never
  automatic.
- One overlay at a time; ESC-to-close overlays vs ESC-always resolved by the
  focus model; printable keymap binds are `:not_composing`-guarded — and the
  guard must ask the *real* question (`composing? OR overlay_open?` — the
  #609 CRITICAL; see `process.md` gauntlet item 4).
- One picker shape for every pick-one-of-N (OverlayPicker + ListScorer);
  palette invokes the same code paths as keybinds (invocation-parity).

## 4. Composer commands & completers (PROPOSED — design ready, not built)

Source: `harness-composer-commands.md` (2026-07-18). One pattern: a
slash-command and an inline trigger-completer are the same F2 shape — one
declared identity, one invocation contract, N projections. F2 itself is NOT
built; the design is a harness-local registry **shaped to fold into F2
verbatim** (same `id + run→[effect] + projection` spine).

- `Raxol.Command.Spec` (a named `/command`; effects: `{:draft, _}` |
  `{:ui, _}` | `{:turn, _}` | `{:dispatch, _}`) and `Raxol.Completer.Spec`
  (`{trigger, query, insert}` — `@`-files, `0x`-addresses). Structs in
  raxol_core; catalog ETS in the harness.
- Interception at the composer seam (triggers can't be keymap binds — every
  printable bind is `:not_composing`): pure `completion_context/1` +
  surgical `apply_completion/3` on the logical substrate.
- Three effect classes, three entry points: draft-transform (composer);
  UI-local `/clear /help /model /theme` (`dispatch_command`); prompt-template
  `/review`, `.claude/commands/*.md`, → the **existing submit path**, so a
  templated turn is indistinguishable from a hand-typed one downstream.
- Isomorphism recorded once: widget `{source, fold, view}` (read-only) ≅
  completer `{trigger, query, insert}` (interactive) — same clamps.
- Honest gaps (decision-ready): OverlayPicker owns its own query → needs
  `set_query/2` + passive mode for draft-slaved completion; plugin command
  load-wiring is dead (`do_load_plugin` reads the wrong callback) and no
  completer hook exists; MCP-as-completer blocked on the client's missing
  `resources/read` (G7); Xochi recipients unpersisted (0x completer misses
  cross-chain); poll-vs-emit for the composer→surface context flow (poll
  recommended).

## 5. Confirmation UI (PROPOSED — design ready, not built)

Source: `harness-confirmation-ui.md` (2026-07-18). Three pieces, one thesis:
an approval = a routed tool widget stacked over a mixed-input selector, whose
choice resolves through the existing approval pipeline.

- **Piece 1 — the assembly:** approval header glyph `⚑`, then the tool-widget
  router's expanded representation (diff for edit/write, command+output for
  bash), then three chevron option lines. Prominence tracks focus under the
  zero-sum single-anchor law: focused line requests role `:emphasis`
  (anchor), unfocused `:muted`; a live approval floors at prominence 0.6
  (needs-input starvation floor) so the question never fades away.
- **Piece 2 — the tool-widget router:** see `widgets.md` §3.
- **Piece 3 — `SelectorWithComposer`** (V's named primitive): items are
  `:choice` lines or an embedded real Composer (`placeholder: "Discuss"` —
  placeholder-reveal falls out free). NAV/EDIT state machine with the
  **boundary-escape rule**: the embedded composer swallows Up/Down while the
  cursor is on an interior visual row (WrapMap `vrow` boundary facts);
  top/bottom-row arrows escape to selector focus. The one composer change:
  an `embedded?` flag swapping the two history-recall arms for
  `{:escape, dir}` returns.
- **What Discuss does (the honest wiring):** at the gate the tool loop is
  *parked* on a blocking `await` — a pure steer would deadlock, a new turn
  discards the context under discussion. Discuss = **deny-with-feedback, same
  turn**: a new option kind `:reject_with_feedback` resolving
  `{:deny, "discuss", {:feedback, text}}` through the existing decision path;
  the model reads the operator's message as the denial reason and continues.
  The keep-pending re-prompt loop is flagged as the heavier v2 alternative.
- Yes/No map to the existing `:allow_once`/`:reject_once` kinds — zero new
  code beyond rendering.
- Flagged for V: prominence-follows-focus is a design commitment; "Yes stays
  white while No is focused" would put two claimants on the anchor and is
  recommended against.

## 6. Navigation & honesty chrome (unit-level status in `roadmap.md`)

Overlay picker primitive (T14, merged) · palette/jump/session picker (T15) ·
transcript search on the projection, fold-aware (T16) · full-screen diff
expand from the approval prompt (T24) · unread divider, client-local
last-seen v1 (T17) · restoration diff on reattach — evidence, never a toast
(T18, blocked on U4-green; must render `{:tip_uncertain, reason}`
first-class) · evidence-rendered done (T19) · focus-gated attention
escalation, never escalates while you're looking, sound off by default (T21).
