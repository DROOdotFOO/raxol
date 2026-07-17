# Harness Composer Commands — slash-commands & at/trigger-completers

Status: **design / scout (v1)** · Date: 2026-07-18 · Owner: V + Claude
Base: `integration/harness-endgame` @ `c23d8fbe8` (WrapMap input zone landed)
Relates: `f2-action-registry.md` (the moat — NOT built yet), `harness-gundam-widgets.md` §2
(binding contract), `harness-baseline-features.md` A11, `harness-research/13-command-channels.md`

---

## 0. Thesis (the one pattern)

A slash-command and an inline completer are **the same shape F2 already named**: one
declared identity, one invocation contract, N projections. The command palette is already
that pattern in miniature — `Keymap.palette_binds/0` filtered/mapped into `OverlayPicker`
(`surface.ex:2478-2517`). Slash-commands are **the palette reached through the text channel**;
completers are a **new interactive projection** of the same `{source, fold, insert}` the
widget doctrine (`harness-gundam-widgets.md:52-115`) leaves read-only. F2's `Raxol.Action`
would be the ideal host, but it is **unbuilt** (verified: no `Raxol.Action`, `Action.Registry`,
`Action.Interpreter`, or `Input.Chord` in the tree). So we define a harness-local registry
**shaped to fold into F2 verbatim** when it lands: same `id + run→[effect] + projection` spine,
scoped to the composer today.

## 1. The registry contract (two specs, one catalog)

Structs live in **`raxol_core`** (mirrors F2's rationale — `raxol_agent`/`raxol_payments`
must produce them without a dep cycle). The catalog (ETS+GenServer, cloned from `MCP.Registry`)
lives in the harness.

```elixir
defmodule Raxol.Command.Spec do        # a named /command
  @type effect ::
      {:draft, {:set, String.t()} | {:replace_span, span, String.t()}}  # draft-transform
    | {:ui, term()}          # → Surface.dispatch_command/2 (UI-local: /clear /model)
    | {:turn, String.t()}    # → submit path (prompt-template / expanded turn)
    | {:dispatch, term()}    # → TEA update/2 (F2-compatible escape hatch)
  defstruct [:name,          # "review"  → invoked as /review
             :aliases,       # ["r"]
             :scope,         # :builtin | :plugin | :mcp   (F2 Action.scope minus :widget)
             :summary,       # palette row + /help text
             :args,          # [%{name, required?, completer: completer_id | nil}]
             :run]           # (args :: [String.t()], ctx) -> [effect]
end

defmodule Raxol.Completer.Spec do      # an inline trigger-completer
  @type trigger :: {:prefix, String.t()}      # "@", "0x"  (token starts with)
                 | {:regex, Regex.t()}
  @type candidate :: %{insert: String.t(),     # what lands in the draft
                       label: String.t(),       # picker row (fuzzy key)
                       detail: String.t() | nil}# right-column context
  defstruct [:id, :trigger, :scope,
             :query]         # (query :: String.t(), ctx) -> [candidate]   ── the fold
end
```

Identity is `{scope, name}` / `{scope, id}` — F2's `{scope, owner, id}` with `owner` elided
(single owner: the harness). `run → [effect]` is F2's exact unification: a palette-picked and
a `/`-typed invocation of one spec run the same code. Both structs map 1:1 onto
`Raxol.Action` (`Command.Spec` = an Action; `Completer.Spec` = an Action source whose effect
is `{:draft, {:replace_span, …}}`) — F2, when built, absorbs the catalog as two more sources.

**Isomorphism (state it, don't re-derive it):** widget `{source, fold, view}` (read-only,
`{:picked,_}` dark) ≅ completer `{trigger, query, insert}` (interactive, lights `{:picked,_}`).
Same clamps apply (`@max_entries`, byte caps, `harness-gundam-widgets.md:79-81`).

## 2. The interception point (composer owns the draft; Surface owns overlays)

Input is **keymap-first, then composer** (`surface.ex:2605-2627` → `Keymap.resolve/2` →
`:passthrough` → `maybe_forward_to_composer/2`). A `/`|`@`|`0x` trigger must fire **while
composing**, but every printable keymap bind is `:not_composing` and fails when
`composing? == true` (`keymap.ex:600-604`). So the trigger **cannot be a keymap bind** — it
lives at the composer seam. Respecting single-truth (the completer reads the logical draft,
never re-derives it), the composer gains one pure reader and one surgical writer:

- `Composer.completion_context/1 :: nil | {:command, query} | {:completer, trigger, query, span}`
  — pure fn of `state.mli.value` + `cursor_pos` (`composer.ex:132-144`, `value/1` :198-200).
  `/` at line head ⇒ command; token-under-cursor matching a registered trigger ⇒ completer.
  `span` is the logical `{from, to}` of the token to replace.
- `Composer.apply_completion/3(state, span, insert)` — replaces `span` on the **logical**
  substrate (like `apply_continuation/2`, `composer.ex:579-594`; NOT `set_value/2` which is
  whole-buffer). Re-projected through WrapMap on next render — never written back.

Seam: after `maybe_forward_to_composer/2` updates the composer (`surface.ex:2823-2834`, right
after the `insert_char/2` append at `composer.ex:384-396`), the Surface calls
`completion_context/1`. Non-nil + no overlay open (`overlay_open?`, `surface.ex:2642`) ⇒ open
the picker; nil ⇒ close any completer overlay. The composer stays the single source of truth;
the Surface is the pure overlay/dispatch owner it already is.

## 3. Picker reuse (OverlayPicker + ListScorer host both)

`open_overlay/3` (`surface.ex:2261`) already takes `items + label_fn + filter_fn + on_pick`;
`OverlayPicker.handle_key/2` returns `{:picked, item}` with the **item term itself**
(`overlay_picker.ex:192-210`); `ListScorer.rank/4` is the fuzzy engine (`list_scorer.ex:140`).
- **Command picker:** items = `Command.Spec` rows ∪ `Keymap.palette_binds/0` (unified palette),
  `on_pick` → run the spec's `[effect]`. This is `open_command_palette/1` extended.
- **Completer picker:** items = `spec.query.(q, ctx)` candidates, `on_pick` →
  `Composer.apply_completion(span, item.insert)`.

**Two gaps to decide (both small):** (a) the existing `/`-search picker owns its OWN query —
keystrokes go into the picker (`route_passthrough/3`, `surface.ex:2777`). The inline completer
V wants ("typing 0x surfaces hints") needs keystrokes to stay in the **draft** with the picker
slaved to the draft token — add `OverlayPicker.set_query/2` + a "passive" mode where only
Tab/Enter/Esc are captured and text falls through to the composer. (b) `fuzzy_filter/3`
discards `ListScorer`'s `positions` (`overlay_picker.ex:159-162`), so no match-highlight — a
nice-to-have, not blocking.

## 4. Execution routing — three effect classes, three entry points

| Class | Example | Effect | Enters at |
|-------|---------|--------|-----------|
| draft-transform | completer insert; `/template` expand-in-place | `{:draft, …}` | `Composer.apply_completion/set_value` before submit |
| UI-local | `/clear` `/help` `/model` `/theme` | `{:ui, msg}` | `Surface.dispatch_command/2` (`surface.ex:2865+`) |
| prompt-template / turn | `/review <pr>`, `.claude/commands/*.md`, `!shell`, `/diff` | `{:turn, text}` | the submit path: `command_sink.(%{type: :submit, …})` (`surface.ex:2849-2860`) |

A `:turn` effect re-enters at the **exact** just-built submit seam — `command_sink` →
`live_session_driver.ex:302` → `SessionLane.submit` (`session_lane.ex:131`) →
`SessionInbox {:start_turn}` (`session_inbox.ex:113`) → `ToolExecutor.stream` — so a
prompt-template turn and a hand-typed turn are indistinguishable downstream (tool loop reuse
free). A tiny `Raxol.Command.Interpreter` (F2's `Interpreter` in miniature) is the only code
that maps each effect to its entry — parity is structural.

## 5. Worked example — the `0x` accounts completer

`%Raxol.Completer.Spec{id: :eth_address, trigger: {:prefix, "0x"}, scope: :builtin, query: &addresses_seen/2}`.
No single source exists — compose three real stores (all `packages/raxol_payments/…`):

```elixir
def addresses_seen(q, ctx) do
  own   = [%{insert: ctx.wallet.address(), label: ctx.wallet.address(), detail: "self"}]        # wallet.ex:45
  sent  = for e <- Ledger.get_history(ctx.ledger, ctx.agent_id, []),                            # ledger.ex:174
              a = e.metadata[:to], is_binary(a),                                                 # transfer.ex:59  (:to is the only address column)
              do: %{insert: a, label: short(a), detail: "transfer · #{e.metadata[:currency]} · #{ago(e.timestamp_ms)}"}
  mand  = for m <- Mandate.Store.list_all(),                                                     # store.ex:123 / mandate.ex:56
              do: %{insert: m.human_wallet, label: short(m.human_wallet), detail: "mandate"}
  (own ++ sent ++ mand) |> ListScorer.rank(q, & &1.label) |> Enum.map(& &1.item)
end
```

Validate with `Xochi.Schemas.validate_eth_address/1` (`xochi/schemas.ex:13`) or
`Xochi.Capabilities.valid_address?/3` for Tron. **Honest gap:** Xochi intent recipients are
never persisted — the ledger records only `%{protocol: :xochi}` (`execute_xochi_intent.ex:447`)
— so cross-chain destinations won't surface until `recipient_address` is added there.
`@file` mirrors this against the VFS: `trigger: {:prefix, "@"}`, `query` = `FileSystem.ls/2`
(`file_system.ex:159`) under the resolved dir / `tree/3` (`:200`), keyed by absolute path (`:41-52`).

## 6. The plugin path (user-plugged extensions)

`use Raxol.Plugin` already injects overridable `get_commands/0` + `handle_command/3`
(`packages/raxol_plugin/lib/raxol/plugin.ex:50-61`), and `CommandRegistry` already carries a
rich `{name, {m,f,a}, metadata}` shape (`command_registry.ex:18-20`). Two honest defects:
1. **Command load-wiring is broken:** `do_load_plugin` reads `commands/0` (not `get_commands/0`)
   and builds only a name→plugin lookup (`plugin_lifecycle.ex:415-438`), never invoking
   `CommandHelper.register_plugin_commands/3`. A plugin command is declared but not dispatchable.
2. **No completer hook exists** anywhere in the plugin system — `filter_event/2` is an event
   mutator, not a provider.

Proposed: extend the behaviour with two optional callbacks —
`harness_commands/0 :: [Command.Spec.t()]`, `harness_completers/0 :: [Completer.Spec.t()]` —
gathered by a `PluginCatalogBridge` at load (fixes defect 1 by routing through the new catalog,
not the dead `commands/0` path). `scope: :plugin` on every spec. `.claude/commands/*.md`
prompt-templates load through the **same** `register/1` with `scope: :builtin`, `run` =
expand-template → `[{:turn, text}]` — user Markdown commands and Elixir plugin commands are one
registry, N authors.

## 7. Ordered build units

**U-C (core, enabling — one lane, serial, touches `composer.ex` = T11 territory):**
- `U-C1` `Raxol.Command.Spec` + `Raxol.Completer.Spec` (raxol_core) + `Harness.Composer.Catalog`
  (ETS, cloned from `MCP.Registry`) + `Command.Interpreter`.
- `U-C2` `Composer.completion_context/1` + `apply_completion/3` (the input-zone change).
- `U-C3` Surface glue: open command/completer overlay from context; `OverlayPicker.set_query/2`
  + passive/slave mode; unify palette to include `Catalog.commands ∪ palette_binds`.

**Parallel once U-C lands (each a small registration against the frozen contract):**
| Unit | Lane | Notes |
|------|------|-------|
| `/clear /help /model /theme` (UI-local) | harness-ui | pure `{:ui,_}` specs |
| `/review`, `.claude/commands/*.md` (turn) | harness-ui | template→`{:turn,_}` |
| `@file` completer (VFS) | harness-ui / core | `FileSystem.ls/tree` |
| `0x` completer (payments) | **payments lane** | §5; needs `ctx.wallet`/`ledger` in composer ctx |
| `@mcp` tool-ref completer | mcp | **blocked**: client has no `resources/read` (deferred G7, `harness-gundam-widgets.md:214`); tool-**sample** source works today |
| plugin bridge + wiring fix | plugin/core | §6; new callbacks + `do_load_plugin` fix |

All parallel units are independent registrations — the contract (§1) is the coordination
point; N build simultaneously the moment U-C3 is green.

## 8. Honest gaps (decision-ready list)

1. **F2 not built.** Ship the harness-local catalog now (F2-convergent) vs. block on F2 (effort-6,
   cross-package). Recommend: ship now; the specs are F2 sources, zero rework on convergence.
2. **OverlayPicker owns its query** — inline completer needs `set_query/2` + passive mode (§3a).
3. **Plugin SDK** — command load-wiring dead (`commands/0`), no completer hook (§6). New callbacks.
4. **MCP-as-completer** deferred — client is tools-only, no `resources/read` (§7).
5. **Composer needs 2 new primitives** — `completion_context/1`, `apply_completion/3` (§2). Both
   read/write the logical substrate only; WrapMap invariants untouched.
6. **Xochi recipients unpersisted** — `0x` completer misses cross-chain until
   `execute_xochi_intent.ex:447` records the address.
7. **Composer→Surface context flow** — `completion_context/1` must be polled per edit at the
   `maybe_forward_to_composer/2` seam (or the composer emits a `{:trigger, ctx}` component event
   alongside `{:submit,_}`, mirroring the existing reducer). Decide poll vs. emit; poll is simpler.
