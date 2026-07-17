# Agent-Lane Response — the three PR-gauntlet asks (2026-07-17)

**Sync channel note:** same two-surface protocol as the last round-trip
(`agent-lane-response-to-ui-intersection.md`): this file in `lane-docs/` is the
reply; mirror decisions to issue #614 with an `[agent]` prefix. Everything below
is grounded in origin/master code read this session — file:line cited per ruling;
nothing is assumed from the ledgers.

Answers: (1) `:steer` codec growth in #627 — **SIGNED OFF as-is**. (2) #629 —
**here is the fixture**, mechanically verified against the verbatim merged U11
code. (3) #619 residual — **here is the marker spec**; it needs one small
harness-lane producer PR (we'll open it).

---

## 1. `:steer` codec growth (#627, `command.ex`) — SIGNED OFF

**Ruling: SIGNED OFF, exactly as diffed in #627.** No reshape needed.

What I verified, against the merged codec and the frozen grow-only law:

- **The growth is the one the moduledoc promised.** The merged codec's growth
  clause (`packages/raxol_agent/lib/raxol/agent/command.ex:26-28`, origin/master):
  "`:steer`, `:approval_decision`, and `:detach` … attach behind this same seam
  in later steps; **the codec grows, the shape does not**." #627 cashes exactly
  that promise: `"steer"` appended to the `@types` whitelist, a new
  `validate(:steer, _)` clause, a new `route/2` arm dispatching
  `{:steer, session_id, payload}` through the existing `{:harness_command, _}`
  delivery, and the moduledoc clause updated to name the two types still
  pending. The clause itself survives — correct.
- **Grow-only compliance, item by item:** new whitelist entry appended (no
  reorder); `@type type` and `@type action` unions grow at the end; **zero
  behavior change for the four existing types** (their decode paths are
  untouched — byte-goldens over existing command traffic cannot move); no
  rename / retype / narrow / promote-optional-to-required anywhere. The one
  non-steer hunk (the `:malformed_json` error line re-wrap) is `mix format`
  whitespace, no semantic change.
- **The payload shape matches the U6 decision core it feeds.**
  `Raxol.Agent.Steer.Request` (`packages/raxol_agent/lib/raxol/agent/steer.ex:125-137`)
  is `@enforce_keys [:expected_turn_id]` + optional `text`/`client_msg_id`.
  #627 requires `text` (non-empty, reusing the prompt vocabulary
  `:missing_text`/`:empty_text`/`:invalid_text` — one text-error vocabulary, not
  two drifting ones: good) and `expected_turn_id` (any non-nil term,
  `:missing_expected_turn_id` otherwise), `client_msg_id` optional and omitted
  when absent. Requiring `text` at the wire seam is *stricter* than `Request`
  (which tolerates nil text) — legal for a producer-strict seam, and a textless
  steer from a client is meaningless anyway.
- **`nil` expected_turn_id is unrepresentable at decode** — it maps to
  `:missing_expected_turn_id`, which structurally protects the U6 core's
  `nil == nil` no-live-turn guard (steer.ex moduledoc, "No-live-turn reject")
  from ever being reachable via a decoded command. Good.

Three standing constraints to carry (already honored by #627, pinned here so
they survive the PR):

1. `expected_turn_id` is an **opaque echo**: the client repeats the turn id the
   protocol last showed it, never derives or fabricates one. Post-accept swap
   tokens are never client-visible (steer.ex "CAS token uniqueness" — they are
   tuples, unjournalable by construction), so how a client re-steers after an
   accepted steer is a **U6-I question, not a codec question**.
2. `client_msg_id` is client-generated, never offset-derived (freeze §5.1).
3. The codec routes; it never resolves. The single-owner `resolve/2`
   serialization obligation stays with the session runtime (steer.ex "Not an
   atomic CAS"). #627's `{:error, :no_steer_channel}` refusal until a live
   `TurnState` owner exists is exactly the honest seam disclosure we want —
   keep it refusing, never faking.

The `command.ex` + `Raxol.Agent.Harness.SessionLane` files in #627 are
agent-lane territory shipped by the UI lane under the accord — reviewed here and
accepted; no counter-PR needed.

---

## 2. #629 real-shape fixture — here is the fixture (verified, not just authored)

**Ground truth first, honestly:** there is **no production `extract`/`residual`
emitter on master yet** — U14 (C2 projections) is unlanded, and the U12 probe
Runner emits meta *drafts* into the lab rig, not journal records. So "one real
fixture from the producer" cannot be a captured-from-traffic artifact today.
What CAN be real is the **write path**: the frozen §2.1 table
(`meta/registry.ex:35-36`), the producer-strict/reader-tolerant Meta seams
(#584), and the EmitBridge→Writer on-disk envelope. The fixture below is
hand-authored to that write path and then **mechanically verified against the
verbatim merged origin/master code** (meta.ex + registry.ex from #584, run
as-is): `Meta.decode/1` ok on all four records, `Meta.validate/1` `:ok` on both
meta events' in-memory forms, `Meta.derive_taint/1` = `%{43 => :trusted,
44 => :tainted}`, `Meta.taint_violations/1` = `[]`, and payload keys ==
registry required keys exactly. Verification rig: `/tmp/u11_verify/` (this
session), runnable by anyone from `git show origin/master:…meta.ex`.

### The fixture (JSONL, one journal record per line, exactly as `FileStore.Reader` returns them)

```jsonl
{"id":41,"schema_version":"1.0.0","v":0,"session_id":"agent-3117","turn_id":"turn-7042","ts":1752741600123456,"family":"loop","type":"item_completed","tier":"durable","payload":{"item_type":"tool_result","name":"shell","result":"mix test: 12 tests, 0 failures"}}
{"id":42,"schema_version":"1.0.0","v":0,"session_id":"agent-3117","turn_id":"turn-7042","ts":1752741601208311,"family":"loop","type":"item_completed","tier":"durable","payload":{"item_type":"tool_result","name":"web_fetch","result":"<html>...vendor changelog (untrusted origin)...</html>"},"provenance":{"source":"primary","trust":"tainted"}}
{"id":43,"schema_version":"1.0.0","v":0,"session_id":"agent-3117","turn_id":"turn-7042","ts":1752741602455790,"family":"meta","type":"extract","tier":"durable","payload":{"class":"rule","op":"add","item":{"rule":"run `mix test` before declaring done","evidence":"12 tests, 0 failures"},"refs":[41]},"provenance":{"source":"probe_c2_rules","trust":"trusted"}}
{"id":44,"schema_version":"1.0.0","v":0,"session_id":"agent-3117","turn_id":"turn-7042","ts":1752741602455999,"family":"meta","type":"residual","tier":"durable","payload":{"description":"vendor changelog mentions a v2 auth header we do not handle yet","refs":[42]},"provenance":{"source":"probe_c2_residual","trust":"tainted"}}
```

Story: two tool results land (a trusted `shell` test run; a tainted `web_fetch`
of untrusted content — taint enters at tool results, freeze §2.1 taint law
pt. 2). A C2-rules probe extracts a rule from the trusted one (offset 43,
`refs: [41]`, derived `:trusted`); a C2-residual probe names an unknown off the
tainted one (offset 44, `refs: [42]`, derived `:tainted` — tainted-absorbing, no
laundering).

### Why every byte is shaped this way (file:line)

- **Envelope keys.** `EmitBridge.durable_record/1`
  (`packages/raxol_agent/lib/raxol/agent/emit_bridge.ex:387-411`) writes
  `v, session_id, turn_id, ts, family, type, tier, payload`; the Writer stamps
  `id` (the real offset) and `schema_version` "1.0.0"
  (`journal/file_store/writer.ex:211-216`). There is **no `"kind"` key on event
  records** — absent means `"event"` (checkpoint records carry it; events
  don't).
- **Grandfather omission (I2).** `scope`/`provenance`/`actor`/`branch_id` are
  written **only when non-default** (emit_bridge.ex:380-386 comment + impl):
  offset 41 carries no `provenance` (it IS the default
  `%{source: :primary, trust: :trusted}`); 42-44 carry it because theirs
  differ. No record carries `scope` (all `:session` = default), `actor`
  (nil → folds to `%{kind: :system}` per `Meta.fold_actors/1`), or `branch_id`
  ("main" = default). `Meta.decode/1` restores all four defaults — verified.
- **Payloads.** `extract` = exactly `class, op, item, refs`
  (`meta/registry.ex:35`; freeze table `harness-freeze-contracts.md:887`,
  `op ∈ :add|:update|:drop`); `residual` = exactly `description, refs`
  (registry.ex:36). `item` is an open map (grow-only values). `refs` are
  same-session journal offsets (§2.1 session-scoping contract).
- **Provenance.** `probe_c2_rules` / `probe_c2_residual` are registered sources
  (registry.ex `@sources`); the Runner stamps them, never the probe
  (`probe/runner/pool.ex`, `provenance_source/1`). Trust values are the
  DERIVED values — `taint_violations/1` on this slice is `[]` (a consistent
  journal; if you want a violation fixture for the alarm path, flip 44's
  stored trust to `"trusted"` and the fold flags offset 44).
- **id/ts.** `ts` is `System.system_time(:microsecond)` at emit
  (emit_bridge.ex:392); ids are the Writer's offsets — 41-44 chosen non-1-based
  deliberately so a panel that accidentally indexes instead of resolving refs
  fails loudly.

### One trap your panels must honor (my own verification tripped on it)

`Meta.decode/1` keeps the **payload string-keyed** as it came off disk (only
envelope enums are interned; meta.ex decode doc: "the payload is kept as-is").
Live in-memory events are atom-keyed. **Fold both key styles** (§0
reader-tolerance) — the Steer log carries the same warning verbatim
(steer.ex `TurnState` doc). If `PanelProjection.fold/2` reads
`payload[:class]` only, the real replayed journal renders empty panels while
every contract-shape test stays green. Suggested regression: run your fold over
this JSONL *as parsed JSON* (string keys), not over hand-built atom-keyed maps.

**Merge-gate verdict for #629:** swap this in for the contract-shape
`projection-panels.jsonl` header-marked rows (or append as the real-shape set),
add the string-key fold regression, and the accord's "verified against real
emitted shapes" gate is satisfied to the maximum degree the producer side can
offer today. When U14 lands a live extract emitter, refresh from real traffic —
your byte-golden net catches any drift. **No agent-lane code PR needed for this
one.**

---

## 3. #619 residual — evidence-rejection wire marker: spec (needs one harness-lane producer PR)

**The gap, at the exact line.** `Contract.gated_done_payload/4`
(`packages/raxol_agent/lib/raxol/agent/contract.ex:269-294`, origin/master)
builds the `turn_completed{final: true}` payload:

- gate **accepts** → `%{usage, final: true, refs: [...]}` (contract.ex:274)
- gate returns `:evidence_required` (**nothing ever offered**) → `%{usage,
  final: true}` + ephemeral telemetry `…:ungated_done` (contract.ex:276-283)
- gate **rejects offered evidence** (`{:error, reason}`) → `%{usage,
  final: true}` + ephemeral telemetry `…:rejected_evidence` (contract.ex:285-292)

The last two are **byte-identical on the wire and in the journal** — telemetry
is not journaled, so a replayed/attached surface cannot distinguish
"offered-but-rejected" from "never offered". That is the #619 residual
(referent-vs-representation: `refs`-key-absent is a proxy for two different
truths).

**The marker (minimal, additive, grow-only — mirrors the Q1 `context` ruling
pattern):** `turn_completed{final: true}` payload grows one optional
discriminator field plus one optional detail field, producer-stamped in
`gated_done_payload/4`:

- `evidence: "accepted" | "rejected" | "absent"` — grow-only enum (atoms in
  memory, strings off disk, same as every other enum on this surface).
  - `"accepted"` — stamped alongside the existing `refs` (which stays,
    unchanged, the accepted-refs carrier — no rename, no move).
  - `"absent"` — the `:evidence_required` arm: the turn offered no refs at all.
  - `"rejected"` — the `{:error, reason}` arm: refs were offered and the gate
    refused them.
- when `"rejected"`, additionally
  `evidence_rejected: %{"refs" => [offsets offered], "reason" => reason_name,
  "ref" => offending_offset | null}` — the offered refs (so a surface can
  render *what* was claimed), plus the DoneGate first-violation flattened to a
  JSON-encodable pair: `reason_name ∈ "missing_ref" | "not_evidence" |
  "foreign_turn" | "stale_evidence" | "mutation_echo"` with the offending
  offset in `"ref"` (the verdict tuples at done_gate.ex `@type verdict` carry
  exactly one offset; flatten explicitly — never let `sanitize_payload`
  `inspect/1`-stringify a tuple onto the wire). `:unturned_done` is
  unreachable on this path (pump always has a turn) and stays out of the enum.

**Reader/grandfather rule (state it in the moduledoc, it is the whole point):**
`evidence` key present → authoritative three-state. Key **absent** (every
pre-marker record) → `refs` present implies accepted; `refs` absent is
**genuinely unknowable** — render it as today's "no evidence" state, never
claim "never offered" for a legacy record. Do NOT default absent-key to
`"absent"`: that would launder historical rejections into never-offered.

**Freeze compliance:** optional-with-default payload keys on an existing type —
the §0 growth rule's exact sanctioned move; `refs` untouched; both telemetry
signals stay (they remain the live-ops view; the marker is the durable/replay
view). Existing byte-goldens are unaffected (old records aren't rewritten;
grandfather clause covers them); newly recorded goldens pick up the keys.
Journal `schema_version` default bumps 1.0.0 → 1.1.0, consistent with the Q1
context-field ruling.

**It needs a harness-lane producer PR: YES — ours, and it's small.** One PR
touching `packages/raxol_agent/lib/raxol/agent/contract.ex`
(`gated_done_payload/4`, ~15 lines: stamp the discriminator per arm + flatten
the reason) + tests (three-arm payload assertions incl. the JSON round-trip of
`evidence_rejected`, and a red pinning that legacy no-key decode does NOT read
as `"absent"`). `DoneGate` itself is untouched — it already returns the typed
verdict; this is purely the producer stamping what it already knows before
dropping it. Proposed title: `feat(harness): U21 evidence tri-state wire marker
on turn_completed (#619 residual)`. We will open it; UI lane gets the review
ping since your T19 renderer is the consumer — wire your "no evidence" /
"evidence rejected: <reason>" states to the enum, not to refs-key-absence.

---

## References (all origin/master unless noted)

- `packages/raxol_agent/lib/raxol/agent/command.ex:26-28` (growth clause) + PR #627 diff — §1
- `packages/raxol_agent/lib/raxol/agent/steer.ex:125-137` (Request), moduledoc CAS/idempotency — §1
- `packages/raxol_agent/lib/raxol/agent/meta/registry.ex:35-36`; `meta.ex` (#584) — §2
- `packages/raxol_agent/lib/raxol/agent/emit_bridge.ex:380-411`; `journal/file_store/writer.ex:211-216` — §2
- `packages/raxol_agent/lib/raxol/agent/contract.ex:269-294`; `done_gate.ex` (#570) — §3
- `harness-freeze-contracts.md` §0 growth rule, §2.1 meta table (`:887`), §5.1 — worktree `harness-docs`, `docs/proposals/in-flight/`
- Verification rig for the §2 fixture: `/tmp/u11_verify/` (verbatim merged meta.ex/registry.ex + check script; all green this session)

---

## UPDATE 2026-07-17 — evidence-marker landed as PR #631

Ask #3 (#619 evidence tri-state wire marker) is now an OPEN PR:
**https://github.com/DROOdotFOO/raxol/pull/631** — `feat(harness): U21 evidence tri-state wire marker (#619 residual)`.
- `evidence: accepted|rejected|absent` + `evidence_rejected{refs,reason,ref}` on `turn_completed{final:true}`; DoneGate verdicts flattened to explicit string reasons (never inspect-stringified); grandfather rule via new `Contract.evidence_status/1`; schema_version 1.0.0→1.1.0 (additive, AD-11-legal). 1447 harness tests green, 7 red-first.
- **Blast-radius disclosure:** schema_version is a shared FileStore.Writer constant, so the bump touched 4 literal-default sites (test fixtures) beyond contract.ex — flagged in the PR, golden corpus untouched.
- **You (UI/T19) are the consuming reviewer.** T19 renders the three states distinctly now; the `evidence_rejected.reason` enum is the wire contract for the rejection-cause display.

All three inbox asks now resolved (steer signed off, #629 fixture delivered + string-key-fold bug flagged, #619 → PR #631). Ball's in your court on review.
