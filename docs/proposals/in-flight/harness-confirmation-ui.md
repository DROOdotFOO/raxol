# Harness Confirmation UI — three pieces (design scout + proposal)

Status: **design / scout (v1)** · Date: 2026-07-18 · Owner: V + Claude
Base: `origin/integration/harness-endgame` @ `8883c0790` ("tools and reasoning as
low-prominence compact blocks"). Read-only scout; no code changed.
Relates: `harness-gundam-widgets.md` §2 (the `{source, fold, view}` binding contract),
`f2-action-registry.md` (the moat — NOT built), `harness-composer-commands.md`
(WrapMap seams, submit path, catalog-shaped-to-fold-into-F2 pattern),
`pierre-diffs-analysis.md` (the diff widget), `harness-visual-doctrine.md` §1.1 (H-K
one-anchor law), `harness-baseline-features.md` A3/A6 (steer vs approval).

Three pieces, one thesis: **an approval is a widget (PIECE 2's router output) stacked
over a mixed-input selector (PIECE 3's named primitive), and the operator's choice
routes into the approval pipeline that already exists — Yes/No map to real option
kinds, Discuss is one honest new decision kind.**

---

## PIECE 1 — the confirmation UI (the concrete instance)

An approval block renders in two stacked zones:

```
⚑ Edit lib/foo.ex                                     ← approval header (block.ex:622 glyph)
┌─ [PIECE 2 router output: DiffViewer for edit/write] ─────────┐
│ ± lib/foo.ex · +3 -1                                          │
│  12    def run(opts) do                                       │
│  13 -    IO.puts("old")                                       │
│  13 +    Logger.info("new")                                   │
└──────────────────────────────────────────────────────────────┘
 ❯ Yes                     ← focused = ANCHOR (role :emphasis, white)
 ❯ No                      ← unfocused = MUTED (role :muted, dim)
 ❯ ▏                       ← Discuss, focused → composer (label gone, cursor on "D" col)
```

- **TOP** is PIECE 2's router output — the expanded tool representation for
  `content` (diff widget for edit/write, command+output for bash, etc.).
- **BELOW** is a PIECE 3 `SelectorWithComposer`: three chevron lines. Exactly one is
  focused; the focused line is the screen's single anchor.
- The approval already carries `content.options` (a list of `%{option_id, name,
  kind}`) and `content.request_id` on the `:approval` block
  (`lib/raxol/ui/components/harness/block.ex:179-209`). PIECE 1 renders those options
  as the selector's `:choice` items; the Discuss item is injected by the UI (it is a
  UI affordance, not a producer-sent option).

**Prominence (role tokens, never raw color).** Prominence tracks focus, honoring the
doctrine's zero-sum single-anchor law (`harness-visual-doctrine.md:44`). The focused
chevron line requests role **`:emphasis`** (seed tier `:anchor`,
`lib/raxol/ui/theming/salience_theme.ex:31`; apparent-L 0.85, the certified-bright
"white"); unfocused lines request role **`:muted`** (seed tier `:recede`,
`salience_theme.ex:32`; apparent-L 0.55, the "semitransparent" dim). Tiers and scalars
live in `lib/raxol/ui/theming/salience.ex:32-46` (`@tier_deltas`, `tiers/0`). A component
declares a role + salience *request*; the H-K solver assigns the level against the
detected ground — no hand-set brightness, no hex (`harness-visual-doctrine.md:42`,
`:258`). A live `:approval` block additionally floors at prominence 0.6 (needs-input
starvation floor, `block.ex:148-154`, `lib/raxol/ui/harness/prominence.ex`), so even
the dim options never fade below "this is a question."

**Playground registration.** Add one `@components` row (`lib/raxol/playground/catalog.ex:21`)
whose `module:` is a small TEA demo app (`use Raxol.Core.Runtime.Application`,
`init/update/view` — shape per `lib/raxol/playground/demos/button_demo.ex:1-3`) that
mounts the assembled confirmation UI with a fixture approval. `HarnessApprovalDemo`
already exists (`catalog.ex:480`) — extend it to host the router-over-selector layout.

---

## PIECE 2 — the tool-widget router framework

A registry mapping tool identity → an expanded-representation widget, plus an automated
router that picks the widget for any tool_use / approval item. This is the SAME
`{source, fold, view}` binding-contract shape as gundam-widgets §2.1
(`harness-gundam-widgets.md:60-73`) and F2's `id + run→[effect] + projection` spine
(`f2-action-registry.md:50-67`) — reused, not reinvented. Neither F2's `Raxol.Action`
nor gundam's `Raxol.Harness.WidgetSpec` is built yet, so (exactly as
`harness-composer-commands.md:18-22` did) define a **harness-local registry shaped to
fold into them verbatim** on convergence.

```elixir
defmodule Raxol.Harness.ToolWidget.Spec do      # lives in raxol_core (no dep cycle)
  defstruct [
    :id,          # :diff | :command | :file_excerpt | :match_list | :compact
    :match,       # (tool_name, content -> bool) — the router predicate
    :fold,        # (content -> widget_state)  — pure, inherits gundam byte/entry clamps
    :view         # (widget_state, geom -> [row]) — pure ViewText rows
  ]
end
# Router: first spec whose match/2 is true wins; :compact is the terminal fallback.
```

Built-in specs (each an entry in a `@specs` list, mirroring `catalog.ex:@components`):

| id | matches | fold → view | reuses |
|----|---------|-------------|--------|
| `:diff` | `content.diff == true` (edit/write; payload already carries `path/old/new/language`, `tool_executor.ex:337-360`) | Pierre model → `DiffViewer.render/2` | `lib/raxol/ui/components/harness/diff_viewer.ex:140`; `pierre-diffs-analysis.md` |
| `:command` | `tool_name in ~w(bash shell)` | command line + streamed output tail | `block.ex` `tool_line/2:675`, receipt `746-762` |
| `:file_excerpt` | `tool_name == "read"` | path + windowed excerpt | ViewText rows |
| `:match_list` | `tool_name in ~w(glob grep)` | match list, clamped | ViewText rows |
| `:compact` | fallback (always) | the `⚙ name(args) · <receipt>` one-liner | `block.ex tool_line/2:675-686` |

- **Unbound → fallback, never crash:** the router always resolves (`:compact` closes
  the set), mirroring gundam's total-map discipline (`harness-gundam-widgets.md:79`).
- **Playground:** each spec ships a wrapper TEA demo (`Demos.HarnessToolWidget<Id>Demo`)
  registered in `catalog.ex` with `category: :harness`, wired to a fixture of its tool
  type — so every widget is demoable and debuggable in isolation (`HarnessDiffDemo` at
  `catalog.ex:205` is the template). This is what "wired to its tool type" means
  concretely: the demo's fixture IS the tool payload the router keys on.

---

## PIECE 3 — the mixed-input primitive: `SelectorWithComposer`

**Name (V's explicit ask): `Raxol.UI.Components.Harness.SelectorWithComposer`.** A
selector whose items are either a `:choice` (a plain chevron line) or a `:composer` (an
embedded mini-composer). The escaping arrow-key behavior is a *property* of the
composite; the composite is the primitive.

State: `%{items: [item], focus: index}` where `item :: {:choice, %{option_id, label}} |
{:composer, Composer.t()}`. The embedded composer is a real
`Raxol.UI.Components.Harness.Composer` (`composer.ex:148` init, `placeholder: "Discuss"`)
— a mini-composer over the SAME WrapMap logical/visual machinery
(`lib/raxol/ui/components/harness/composer/wrap_map.ex`), single-truth post-`b3fdbe94f`.

**Placeholder-reveal falls out of the composer for free.** The composer already renders
its placeholder iff `value == "" and not focused` (`composer.ex:472-479`). So an
unfocused Discuss shows dim `"Discuss"`; focusing it (cursor parks at col 0, where the
"D" was) blanks the label and shows an empty input — exactly V's spec, zero new code.

### State machine

```
                arrow-down from "No"  (or direct focus)
     ┌──────────────────────────────────────────────────────┐
     │                                                        v
 ┌────────┐   Up/Down move focus among :choice items    ┌──────────────┐
 │  NAV   │◄──────────────────────────────────────────► │     EDIT     │
 │ focus  │   Enter on :choice → pick (Yes/No)           │ focus on the │
 │ = a    │                                              │ :composer    │
 │ :choice│   boundary-escape UP (composer vrow == 0)    │ item; keys → │
 │        │◄──────────────────────────────────────────  │ composer     │
 └────────┘         → focus previous item (No)           └──────────────┘
                                                          │  ▲
                    interior Up/Down (0 < vrow < rows-1)  │  │ swallowed
                    stay in EDIT, move cursor in text ────┘  │ (edit text)
                    Enter → submit Discuss(text)             │
                    Esc   → blur → NAV (focus "Yes")  ───────┘
```

- **Boundary-escape rule** (the subtle one V named): the embedded composer swallows
  up/down *as long as the cursor is not on the top/bottom visual row*. Top/bottom is
  read straight from WrapMap-derived geometry: `visual_geometry.vrow == 0` is the top,
  `vrow == rows - 1` is the bottom (`composer.ex:626-627`, `641-642`; `rows =
  WrapMap.row_count/1`, `wrap_map.ex:81`). Interior → `move_to_visual_row/3`
  (`composer.ex:653`) edits within the text. At a boundary the composer today falls to
  history recall (`composer.ex:630`, `:645`); **the one change** is: in embedded mode
  those two arms return `{:escape, :up}` / `{:escape, :down}` instead, and
  `SelectorWithComposer` catches the escape and moves `focus`.
- **The only composer change needed:** an `embedded?: true` (or `history: false`) flag
  that swaps the two history arms for escape returns. Everything else — WrapMap
  projection, goal-column, placeholder, `edit_point/2` (`composer.ex:230`),
  `set_width/2` (`:250`), `force_submit/1` (`:262`) — is reused unchanged. **WrapMap
  gives everything the escape needs; nothing is missing.**
- **Playground:** `Demos.HarnessSelectorComposerDemo` in `catalog.ex` (`category:
  :harness` / `:input`) mounts a standalone `SelectorWithComposer` so the mode machine
  and the boundary handoff are debuggable without an approval.

---

## What does "Discuss" DO — the honest wiring

At the approval gate the tool loop is **parked**, not generating: `gated_run/4`
(`packages/raxol_agent/lib/raxol/agent/harness/tool_executor.ex:256-304`) emits
`:approval_requested`, then blocks on `await/3` (a `GenServer.call(:infinity)` into
`SessionInbox.await_permission/3`, `session_inbox.ex:100-108`). Therefore:

- A **pure steer** (`Steer.resolve/2`, `steer.ex:231`; lands "at the next safe point",
  `harness-baseline-features.md:31`) would **deadlock**: it does not resolve the parked
  `await`, so the loop never unblocks and the steer's "next safe point" never arrives.
- A **new turn** discards the in-flight turn and its tool context — heavier, and it
  throws away the very context the operator is discussing.

**Honest wiring: Discuss = deny-with-feedback, in the same turn.** Discuss resolves the
parked gate on the **deny** path (so the loop unblocks cleanly, no deadlock) and threads
the operator's message to the model as the denial reason, so generation continues in the
same turn having *read* the discussion. The decision type already accommodates this:
`{:deny, String.t(), term()}` (`tool_executor.ex:71-79`) — the third `term()` slot
carries `{:feedback, text}` instead of `:operator_denied`, and the deny sibling of
`apply_after_allow` already "feeds the model an honest denial" (`tool_executor.ex:256-304`).

Minimal new plumbing (agent lane):
1. One UI option kind `:reject_with_feedback` (deny-class) on the injected Discuss item.
2. `decision_for/2` (`session_inbox.ex:246-252`) gains a clause: `%{kind:
   :reject_with_feedback}` → `{:deny, option_id, {:feedback, text}}`.
3. The `approval_answer` payload gains an optional `:text`; `resolve_approval_answer/2`
   (`lib/raxol/harness/surface.ex:2861-2905`) carries it through; the wire
   (`session_lane.ex:214-227` → `command.ex:251-265` validation) passes it in the
   `approval_decision` payload it already routes.

### How the choice composes with the existing pipeline

| Choice | Option kind | Resolves via | Existing seam |
|--------|-------------|--------------|---------------|
| **Yes** | `:allow_once` (the `@allow_option`) | `decision_for → {:allow, "allow"}` | `tool_executor.ex:71`; `session_inbox.ex:246-249` |
| **No** | `:reject_once` (the `@deny_option`) | `decision_for → {:deny, "deny", :operator_denied}` | `tool_executor.ex:72`; `session_inbox.ex:250-252` |
| **Discuss** | `:reject_with_feedback` (**new**) | `decision_for → {:deny, "discuss", {:feedback, text}}` | new clause; text via `:text` payload |

Full unchanged path for all three: surface `dispatch_command` `%{type:
:approval_answer}` (`surface.ex:3114-3133`) → driver `answer_permission/2`
(`live_session_driver.ex:621-637`) → lane wire `"approval_decision"`
(`session_lane.ex:214-227`) → `Command.route` (`command.ex:180-181`) → inbox
`resolve_decision/2` replies to the parked `from` (`session_inbox.ex:227-245`) → the
loop resumes. Yes/No need zero new code beyond rendering; Discuss needs the three items
above.

---

## Ordered build units, lanes, parallelizability

Lane split per the session accord: **harness-ui** = components/rendering; **agent** =
agentic layer + protocol.

| # | Unit | Lane | Size | Depends |
|---|------|------|------|---------|
| P3-1 | `SelectorWithComposer` primitive + composer `embedded?`/escape mode + playground demo | harness-ui | M | Composer (built), WrapMap (built) |
| P2-1 | `ToolWidget.Spec` + router + 5 built-in specs + per-widget playground demos | harness-ui | M | DiffViewer (built), compact renderers (built) |
| P1-1 | Confirmation UI assembly: router output stacked over `SelectorWithComposer`; role `:emphasis`/`:muted` on focus; extend `HarnessApprovalDemo` | harness-ui | S–M | **P3-1, P2-1** |
| A-1 | Discuss decision kind: `:reject_with_feedback` + `decision_for` clause + `:text` in `approval_answer`/`resolve_approval_answer` + deny-feedback → tool result | agent | S | approval pipeline (built) |

Parallelizability: **P3-1 ∥ P2-1 ∥ A-1** are independent (different files, A-1 in the
agent package). P1-1 is the join, needs P3-1 + P2-1; it coordinates with A-1 only on the
`approval_answer` payload shape (the `:text` field) — freeze that field first and both
lanes proceed.

## Honest gaps

1. **Router needs neither F2 nor gundam built.** It is a harness-local registry shaped
   to fold into `Raxol.Action` / `WidgetSpec` verbatim (same bet as
   `harness-composer-commands.md:18-22`). Zero rework on convergence; some duplication
   until then.
2. **Playground supports these widget types via wrapper demos, not natively.** Demos are
   TEA apps (`init/update/view`); the tool-widgets are pure render fns. Each needs a thin
   demo shell whose fixture is the tool payload — small, `HarnessDiffDemo` is the proof.
3. **Embedded composer needs one thing WrapMap already provides but the composer doesn't
   expose:** boundary detection exists (`vrow == 0` / `vrow == rows-1`), but the boundary
   arms hardcode history recall (`composer.ex:630`, `:645`). Add `embedded?` to return
   `{:escape, dir}` there. No WrapMap change.
4. **Discuss must resolve the gate (deny-with-feedback), not steer.** A pure steer
   deadlocks the parked `await_permission`. If V instead wants Discuss to *keep the
   action pending* and merely inject guidance (a re-prompt loop that re-asks after the
   model responds), that is heavier — a new inbox state, not a deny — and is flagged as
   the v2 alternative. v1 = deny-with-feedback (unblocks cleanly, model reads the message
   same-turn).
5. **`content.options` search corpus** joins only binary entries (`block.ex:893`);
   option maps contribute no search text. Pre-existing, unrelated, not in scope.
6. **Prominence = focus is a design commitment.** V's "Yes white / No dim" reads as
   "the focused option is the anchor." If V wants Yes to stay the visual default even
   when No is focused, that violates the zero-sum single-anchor law (two claimants) —
   flagged; recommend prominence-follows-focus.
