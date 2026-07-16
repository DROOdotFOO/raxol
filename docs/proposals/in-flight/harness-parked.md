# Harness — Parked Items Backlog

Date: 2026-07-16 · Status: living backlog, sync as items resolve.

Single tracked home for every deferred/flagged item accumulated during the
red-first fan-out (PRs #570–#587). These were previously scattered across PR
review comments and ephemeral scratchpad output — both at risk of being lost
once the PRs merge. Do not silently drop an item from this list; either move
it to "resolved" with the PR/commit that closed it, or leave it open.

See `harness-roadmap.md` for the unit DAG these items bind to, and
`harness-freeze-contracts.md` for the frozen contract vocabulary they
reference.

---

## Restore-path hardening (post-U9, security)

Source: scratchpad followup during the U9 red-first pass. Owner: fold into
U9-I (the U9 implementation unit) or a dedicated load-path-hardening unit.

| What | What unblocks it |
|---|---|
| Decode recursion depth-bound — adversarial nesting on load is a crash vector (unbounded stack growth decoding a hostile/corrupt journal or checkpoint payload) | A depth-bound (or iterative decode) added to the U9/U2 decode path before it's trusted with untrusted input |
| Unvalidated `$s` struct-module gadget — `String.to_existing_atom \|> struct/2` on a decoded module name is an integrity/type-confusion risk if the atom table already contains an attacker-chosen struct module | A whitelist of decodable struct modules, or a safer decode primitive that doesn't call `struct/2` on caller-controlled atoms |
| Unknown-tag pass-through survives as literal maps — an unrecognized encoded tag silently decodes to a raw map instead of erroring or being clearly marked opaque | A decision: fail closed on unknown tags, or mark them opaque/non-authoritative explicitly so downstream folds don't mistake them for typed records |
| `$s` module decode not falling back to raw string — contradicts the documented fallback behavior (spec says unknown/unloadable modules should decode to the raw string, current code does not) | A fix aligning the implementation with the documented contract, or a doc correction if the fallback was never actually intended |
| Coerce trusts caller module arg — the coercion helper trusts a module name passed by the caller rather than validating it against a known-safe set | Same fix class as the `$s` gadget above — validate before trusting |

---

## Contract gaps needing a freeze addendum before their impl

### U4 (from PR #586)

| What | What unblocks it |
|---|---|
| Live-delivery reattach transport unspecified | Ties to S2 (UI-lane wire transport) — needs a joint decision with the UI lane session before U4-I can pick a transport |
| Tar'd-dir resolution mechanism | The test suite currently pins `RAXOL_SESSIONS_DIR`; a real resolution mechanism (env var vs config vs discovery) needs to be frozen before U4-I |
| AD-15 broadcast permission bus has no frozen shape | JS-FREEZE §1 doesn't define the permission-bus shape that AD-15 (broadcast) depends on — needs a freeze addendum |

### U7 (from PR #571)

| What | What unblocks it |
|---|---|
| Reserve/spend wire record encoding not frozen | Fold semantics (reserve-before-call, settle-after) are frozen; the actual wire record *shape* for a reserve/spend pair is not — binds at U7-I |

### U8 (from PR #587)

| What | What unblocks it |
|---|---|
| `:root` approval scope needs route/spawn-tree plumbing | C5 (background research) covers `:session` scope only today; `:root` needs routing through the spawn tree, which doesn't exist yet |
| C6 rebuild input shape derefs refs into the journal at impl time | Needs to be nailed down when C6 (cross-family consensus) is actually implemented — not yet frozen |

### U12 (from PR #583)

| What | What unblocks it |
|---|---|
| Budget-conservation contour — session reservation RELEASED on run-level refusal, plus a budget-conservation red | This froze in the Drew-review round *after* #583 was authored, so #583 doesn't carry it. Fold into a U12-R follow-up commit or roll it into U12-I directly |

---

## Policy questions (need a human/Drew ruling)

### U21 (PR #570)

| What | What unblocks it |
|---|---|
| Gating strength mismatch — the roadmap's U21 text reads weaker ("`turn_completed` carries evidence") than the suite's enforcement ("claim-without-evidence is rejected") | A ruling on which text governs: does U21 merely *attach* evidence, or *reject* an undocumented "done" claim? Also open: may a pure-reasoning zero-tool turn ever be "done" at all? |

---

## Wiring debt (must land with the impls)

| What | What unblocks it |
|---|---|
| Emit vocabulary `approval_requested` / `item_started` / `woken` frozen-but-not-wired into EmitBridge | The freeze reserves these types; EmitBridge's neutral→contract mapping doesn't emit them yet. Wire at the relevant impl unit (U8 for `approval_requested`, U1.5/loop vocab for `item_started`, the schedule/wake unit for `woken`) |
| `branch_id` not yet stamped by Writer | The freeze reserves `branch_id` (defaults to `"main"`); the Writer doesn't stamp it yet. Wire when branching (C1/tournament) lands, or earlier if grandfather-safety needs proving sooner |
| U11 envelope carry-through — `scope`/`provenance`/`actor` through `durable_record/1` AND `map_event/3` + Reader decode | Both the journal path (`durable_record/1`) and the live path (`map_event/3`) currently build their maps from a hardcoded key list that omits these fields; extending both plus the Reader decode is required before any of the three fields can actually flow end-to-end. Binds at U11-I |
| `effect_class`/`egress` on the Action contract | F2 draft, unlanded. `@tag :action_surface` reds are pending until the F2 draft lands |
| `Raxol.Agent.Fingerprint.canonical_json/1` named-but-unimplemented | The model/params fingerprint ruling (see audit-trail) names this function as the single normative serializer for `params_hash`; it needs an actual implementation before any fingerprint red can be authored non-vacuously |

---

## Deferred test tags

| What | What unblocks it |
|---|---|
| P-JS11 / N-JS11 — `@tag :gc` | These properties are only exercisable once `low_watermark > 1` exists, which requires GC (deferred by design, OQ-JS2 ruling: "defer entirely"). Neither a generator nor an injector can exercise them until then |
| `:standalone` probe reds — `@tag`-pending until U17 | C6 cross-family consensus (U17) is the only `:standalone` consumer; the interface is frozen (additive, zero risk) but the reds have no implementation surface to validate against until U17 (Wave 4) lands |

---

## Cross-doc cleanup

| What | Where to chase it |
|---|---|
| Stale claim: "the command-result path emits nothing" | `harness-roadmap.md` / `harness-spec-backend.md` — Drew flagged this live as stale (U1 closed this in PR #546); not a freeze-doc issue, chase in the roadmap/spec-backend siblings |
| Stale claim: "SessionStreamer unplumbed" | Same siblings as above — chase there, not in the freeze doc |
| Issue #566 — `CommandRegistryTable` keyed by `app_module` | Separate issue: concurrent sessions of the same app module currently share/delete one ETS table. Not part of the freeze fold; tracked standalone at #566 |

---

## Resolved

*(none yet — move items here with their closing PR/commit as they land)*
