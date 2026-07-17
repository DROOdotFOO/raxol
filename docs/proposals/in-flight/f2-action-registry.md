# F2 — Unified Action Registry

Status: **draft / design (v1)** · Date: 2026-07-13 · Owner: V + Claude
Parent: `tui-steal-list.md` §3 F2 (the moat) · Depends on nothing; **gates** #1 finder,
#2 palette, #4 chat-widgets, #5 a11y tree, #7 which-key.

Spine decision (V, 2026-07-13): **Hybrid — two ingestion sources, one registry.**
Tree-walk stays as an Action *source*; app/agent/plugin actions register explicitly;
every surface projection is `filter + map` over one canonical set.

---

## 1. Problem (ground truth, not aspiration)

Five non-interoperable action planes exist today. Verified shapes and anchors:

| Plane | Source of truth | Entry shape | Invocation target |
|-------|-----------------|-------------|-------------------|
| 1. MCP `ToolProvider`/`TreeWalker` | the view tree (walked) | `%{name, description, inputSchema, callback}` (`registry.ex:42`) | **casts `{:dispatch, msg}` → `update/2`** (`tree_walker.ex:162`) |
| 2. `Agent.Action` | `use` macro + `__action_meta__/0` | `%{name, description, input_schema (kw-spec), output_schema, sensitive}` (`action.ex:83`) | pure `run/2` → `{:ok, map, [Directive]}` |
| 3. `Core.KeyboardShortcuts` | `ShortcutsServer` GenServer | `%{name, callback, context, priority, key_combo}` (`shortcuts_server.ex:159`) | direct callback (`fn/0`, `fn/1`, `{m,f,a}`) |
| 4. `FocusManager`/`FocusServer` | GenServer, single global `current_focus` | `%{id, tab_index, opts}` (`focus_server.ex:167`) | mutates focus; **not an action** |
| 5. `Plugins.CommandRegistry` | plain map keyed by plugin module | `{name, {m,f,a}, metadata}` (`command_registry.ex:11`) | plugin-local state; **result discarded** (`command_helper.ex:76`) |

Two facts kill the naïve "unify the struct" instinct:

1. **Invocation diverges harder than data does.** Only Plane 1 reaches `update/2`.
   Planes 2/3/5 each terminate somewhere else (Directive list, bare callback,
   plugin state that gets written back and whose *return value is thrown away*).
   The registry is worth nothing if a palette-invoked action and a
   keyboard-invoked action of the *same id* run different code down different pipes.

2. **The MCP tool-def is already a shared type across 1↔2**, via one bridge:
   `AgentBridge.actions_to_mcp_tools/2` emits Plane 1's exact `tool_def`
   (`agent_bridge.ex:27-53`). But the two `inputSchema` builders are independent
   (`tool_def.ex` vs `agent_bridge.ex:162`), and Plane 2 *also* emits a second,
   string-keyed OpenAI `function` shape (`schema.ex:60-87`). So even the one place
   two planes agree, they agree by coincidence, through duplicated code.

The moat isn't a data model. **The moat is: one action identity, one invocation
semantics, N projections.**

---

## 2. The canonical Action

Lives in `raxol_core` (every package already depends on it; no new dep edges).

```elixir
defmodule Raxol.Action do
  @type scope :: :widget | :app | :agent | :plugin
  @type effect :: {:dispatch, term()}          # → update/2 (the TEA path)
                | {:focus, term()}              # → FocusServer
                | Raxol.Agent.Directive.t()     # → agent effect interpreter
                | {:plugin, module(), term()}   # → plugin-local state write
  defstruct [
    :id,          # atom | binary, unique within {scope, owner}
    :scope,       # :widget | :app | :agent | :plugin
    :owner,       # widget_id | plugin module | nil (app/agent globals)
    :label,       # human text: palette row, which-key hint, tool description
    :params,      # canonical param spec (ONE builder → inputSchema AND json_schema)
    :keys,        # [Raxol.Input.Chord.t()] — abstract chords, [] if none
    :sensitive,   # bool — gates auto-exec + palette dimming (from Agent.Action)
    enabled?: true, # (context -> bool) | bool — evaluated at PROJECTION time, not registration
    run: nil      # (args, context) -> [effect] — the ONE invocation contract
  ]
end
```

Identity is `{scope, owner, id}`. Namespacing (`"submit_btn.click"`,
`"agent.remember"`) becomes a *rendering* of identity for a given projection, not a
baked-in string — Plane 1's current `"#{id}.#{action}"` (`tree_walker.ex:131`) is
derivable, so no MCP client sees a name change.

Two hard commitments in this struct:

- **`enabled?` is evaluated at projection time.** A disabled action still *exists*
  in the registry; each projection filters it. This is what makes "hidden/disabled
  action can't leak to MCP" a structural property instead of a per-callsite check —
  and it's the concrete resolution of open question G-F2 (below).
- **`run` returns `[effect]`, always.** This is the unification. See §4.

---

## 3. Two ingestion sources → one registry

`Raxol.Action.Registry` (GenServer + ETS, mirrors the existing `MCP.Registry`
lifecycle so the pattern is familiar).

**Source A — tree-derived (widget actions), automatic.** Keep `ToolProvider` and
`TreeWalker` essentially as-is, but retarget: `TreeWalker.derive_tools` becomes
`derive_actions` and yields `Raxol.Action{scope: :widget, owner: widget_id}`
instead of a bare `tool_def`. The existing `ToolSynchronizer` trigger
(`{:view_tree_updated}` telemetry, `tool_synchronizer.ex:220`) drives a diff-sync
into the registry — no new plumbing, the sync engine already exists. Widgets keep
opting in via the `ToolProvider` behaviour; `@mcp_exclude` still suppresses.

**Source B — explicit registration, for the non-widget scopes.** `app` (quit,
toggle-theme, open-palette), `agent` (`Agent.Action` modules), `plugin`
(`CommandRegistry` entries). `Registry.register(%Action{...})`. This is the home
for actions that never appear in the view tree — the concrete resolution of the
"palette wants app-level commands" open question.

The registry is a *union* keyed by `{scope, owner, id}`. Source A entries are
ephemeral (rebuilt each tree sync, like tools today); Source B entries are durable
until explicitly removed. No entry is authored twice.

---

## 4. One invocation semantics (the hard part)

Every `Action.run` returns `[effect]`. A single `Raxol.Action.Interpreter`
consumes effects; it is the *only* code that knows how each side-effect lands:

```
Interpreter.run(effects, ctx):
  {:dispatch, msg}        -> GenServer.cast(ctx.dispatcher, {:dispatch, msg})   # Plane 1 path, generalized
  {:focus, target}        -> FocusServer.set_focus(target)                       # Plane 4
  %Directive{} = d        -> Agent.Directive.apply(d, ctx)                       # Plane 2 effects
  {:plugin, mod, cmd}     -> CommandHelper.handle_command(...)                   # Plane 5, state write-back
```

This is what makes a palette-invoked action and a key-invoked action of the same id
**run the same code**. It also fixes Plane 5's silent-result bug: a plugin command
that wants to affect the app returns `[{:dispatch, msg}]` instead of a discarded
value.

Migration reality per plane (honest, with the throwaway-work called out):

- **Plane 1:** already effect-shaped in spirit (`handle_tool_call` returns
  `{:ok, result, messages}` and TreeWalker casts each message — `tree_walker.ex:160`).
  Rewrap messages as `{:dispatch, msg}` effects. Low risk.
- **Plane 2:** `run/2` already returns `{:ok, map, [Directive]}`. Directives *are*
  effects. Fold the two tool-def builders into the one `params` builder; keep the
  OpenAI `function` projection as one more projection (§5), delete the duplicate
  MCP builder in `AgentBridge` (`agent_bridge.ex:162`).
- **Plane 3:** convert bare callbacks to effect-returning. `fn/0` callbacks that
  today mutate via closure must become `[{:dispatch, msg}]` — **this is the sweep
  risk**: every currently-registered shortcut callback is rewritten. Budget it.
- **Plane 4:** *not absorbed.* Focus stays its own GenServer. F2 (a) consumes its
  `current_focus` as the shared projection predicate, and (b) wires
  `register_focus_change_handler` (`focus_server.ex:485`) so projections re-filter
  automatically — fixing the "no code link" seam. `{:focus, _}` effects let actions
  drive focus, but focus state is not action state.
- **Plane 5:** `CommandRegistry` entries register as `scope: :plugin` actions whose
  `run` emits `{:plugin, mod, cmd}` (preserving today's state write-back) and
  optionally `{:dispatch, msg}` (the new capability — plugin commands can finally
  reach `update/2`).

---

## 5. Projections (all `filter + map`, shared focus predicate)

One predicate, `in_focus_scope?(action, focus_state)`, is shared by every
projection. FocusLens and palette stop being opposite implementations and become
two filters over the same set — the concrete resolution of the "one filter or
three" open question:

| Projection | Filter | Map |
|-----------|--------|-----|
| MCP tools | `enabled?(ctx) and params != nil`, then `FocusLens` cap (≤15, `focus_lens.ex:36`) | → `tool_def` (namespaced name, `inputSchema` from `params`) |
| OpenAI/Anthropic (agent backends) | `scope == :agent and enabled?` | → `function` json-schema (`schema.ex:60`) |
| Command palette | `enabled?(ctx)`, **reveal all** (no cap), dim `sensitive` | → `%{label, keys, id}` rows, fuzzy-ranked (#1 scorer) |
| which-key keybar | `enabled?(ctx) and in_focus_scope?` | → `%{keys, label}` grouped by chord prefix |
| Key dispatch | `match_chord(event, action.keys)` | → `Interpreter.run(action.run.(%{}, ctx))` |
| a11y tree (#5) | `enabled?` + role metadata | → `raxol://a11y` role/name/value |

FocusLens *caps* (agent attention budget); palette *reveals all* (human
discoverability) — opposite intents, same registry, same `enabled?` gate, different
final filter. That's the design working.

Chord tokens are **abstract from day one** (`Raxol.Input.Chord`, not raw byte
encodings) — resolves the fourth open question and avoids the double-work of
rebuilding keybindings when F1b (kitty keyboard) lands. F2 does not depend on F1b;
it depends only on the *token type* existing, which is cheap to define now.

---

## 6. Open questions resolved vs still-open

Resolved by the spine + this design:

- **G-F2** (registry-feeds-MCP vs MCP-is-registry): registry feeds MCP; tree-walk is
  a *source* into the registry, not replaced. `enabled?`-at-projection makes
  hidden/disabled actions structurally non-leaking. ✔
- **non-widget actions**: `scope: :app`, explicit `register`. ✔
- **shared focus filter**: one `in_focus_scope?` predicate; FocusLens = predicate +
  cap, palette = predicate-less reveal-all. ✔
- **chord tokens**: abstract `Raxol.Input.Chord` from day one. ✔

Still open — need V:

- **G-focus-scope**: `FocusServer` is a *single global* `current_focus`
  (`focus_server.ex:16`), but `TEALive` runs a separate Lifecycle → two surfaces,
  two focuses, one global server = collision. Does F2 assume single-focus (correct
  for terminal, wrong for multi-surface), or does focus become per-surface *before*
  which-key (#7) ships? which-key is unbuildable-correct without this answer.
- **G-effect-boundary**: should `{:plugin, ...}` effects be allowed to also emit
  `{:dispatch, ...}` (plugins reach `update/2`), or is that a sandbox violation we
  want to forbid? Security call — plugin code driving arbitrary app messages.
- **G-sensitive-semantics**: `sensitive` today only tags agent actions
  (`action.ex:83`). In a unified registry, does `sensitive` gate auto-exec in the
  HITL↔YOLO autonomy dial (tui-steal-list §5), require confirm in palette, or both?

---

## 7. Test strategy (name the property before building)

- **Functor-law property test** (mirrors the existing MCP tool-derivation functor
  tests): for any registry state, `project_to_mcp(registry)` on a tree must equal
  the pre-F2 `TreeWalker.derive_tools` output — i.e. the migration is
  *behavior-preserving* for existing MCP clients. Name: `action_registry_functor_test`.
- **Invocation-parity property**: for any action reachable by ≥2 projections
  (e.g. palette + key), invoking via each projection produces the *same effect list*.
  This is the property that justifies the whole subsystem; if it can't be stated,
  the registry is cosmetic.
- **Projection-isolation**: a `sensitive` or `enabled? == false` action never
  appears in the MCP projection (regression guard for G-F2).

---

## 8. Effort, sequencing, risk

Effort **6** (within the doc's 5–8 band). Crosses raxol ↔ raxol_mcp ↔ raxol_agent
↔ raxol_core; the integration *is* the cost.

Sequence:

1. `Raxol.Action` struct + `Raxol.Input.Chord` token type + `Action.Registry`
   (ETS/GenServer, cloned from `MCP.Registry`). No behavior change yet.
2. `Action.Interpreter` + the effect contract. Prove invocation-parity property on a
   single hand-built action.
3. **Source A**: retarget `TreeWalker` → `derive_actions`; MCP projection reads the
   registry. Functor test must stay green (behavior-preserving for MCP clients).
4. **Source B**: absorb `Agent.Action` (delete the duplicate `AgentBridge` builder),
   then `CommandRegistry`, then `KeyboardShortcuts` (the callback-rewrite sweep — the
   riskiest step; do it last, behind the parity property).
5. Wire `FocusServer` change-handler into projection re-filter. Resolve G-focus-scope
   *before* this if multi-surface which-key is in scope.

Risks:

- **The KeyboardShortcuts callback sweep** (step 4c) touches every registered
  shortcut. Gate it behind the invocation-parity property or it regresses input
  silently.
- **Ordering vs F1**: `Action.keys` uses abstract chords now; if F1b (kitty) lands
  *after* F2 ships keybindings, the chord *matcher* changes but the tokens don't —
  no rewrite, provided chords are abstract from step 1. Do not ship raw-encoding
  keybindings "temporarily."
- **`raxol_agent` depends on `raxol`, not the reverse** (CLAUDE.md dep graph). The
  `Action` struct must live in `raxol_core` so `raxol_agent` can produce it without
  a cycle. `Agent.Directive` interpretation, however, can't live in core — the
  interpreter's Directive clause dispatches through a behaviour so core stays
  dependency-clean.

---

## 9. What this unlocks (why it's the moat)

With F2 landed, every headline item in `tui-steal-list.md` becomes a projection, not
a subsystem: #2 palette (filter+map+fuzzy), #7 which-key (filter+map), #4 chat
widgets (each auto-derives its MCP tool because it's a widget-scope action source),
#5 a11y tree (one more projection of the same set). One declaration, N surfaces —
and now that's structural, not marketing.
