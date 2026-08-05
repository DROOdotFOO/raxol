## Q1: Session lineage + NC-12

**PICK:** Ratify `parents: [%{session_id, offset, relation}]` with grow-only `relation ∈ :fork | :spawn | :merge | :import`, and name **NC-12** explicitly in the freeze doc.

**REASONING:** Scalar `forked_from` is a one-way door to a forest; under "only grows," merge becomes a second parallel field or a forbidden repurpose. Session-level typed edges keep each journal dense and linear, preserve the derived tip law and I6 continuity, and match how the cohort actually solves parallelism (new session / worktree / fleet), not in-log CRDT. NC-12 is not pessimism: it states that dense offsets, single-writer, and corruption detection are the same invariant bundle; "sync two writers into one log" is a different product. The four relations cover copy-on-fork, Agent.Team spawn, fuse, and transplant without overlapping meanings.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**
- **`offset` meaning is relation-dependent but not frozen**: fork point vs spawn-attach tip vs merge tip vs import boundary. Readers that treat all offsets as "fork point" will reconstruct wrong history without a small per-relation semantics table in the contract.
- **DAG cycles**: nothing in the shape prevents `A → B → A` if producers are sloppy; session creation should validate acyclicity (or at least document that invalid lineage is producer error, reader tolerates).
- **Dual recording**: community evidence pushes both `meta.json.parents` and a spawn meta event; without a rule ("edges authoritative, events observability-only"), fixtures will disagree on which wins for rollup.
- **`:import` vs new `session_id`**: import almost always mints a new id; edge `session_id` must mean "source session at export time," not "same id on new machine," or portability reds lie.
- **Deleted / missing parent**: R2's "resolvable-or-absent" must apply to lineage walks; otherwise cost rollup and UI trees fail closed on partial tarballs.
- **Enum gap that is *not* worth a fifth value yet**: counterfactual replay, benchmarks, and "retry branch" should stay `:fork`; resist `:replay` unless you are willing to never merge it with `:fork` in folds.

Relation enum is right for day-one fixtures. Optional **`detail` map on each edge** (grow-only keys, e.g. `role: :subagent`) is safer than bloating `relation` with spawn subtypes.

---

## Q2: Actor attribution breadth

**PICK:** **Middle shape**, optional `actor` on every **`kind: "event"`** record (not checkpoints); **`bill_to` + `cost_ref` only on spend-bearing records** (`item_completed`, `probe_run`, and whatever record carries the authoritative per-turn spend rollup, frozen `charge` on `turn_completed` / probe terminal per U7/U12).

**REASONING:** Narrow actor on G4/G5 alone fails the moment multi-client attach, sub-agent spawn (R1), or harness-initiated housekeeping matters on `turn_started`, tool/meta, or loop events, exactly when "derivable from session context" breaks. Putting `actor` on every event is cheap on disk (absent keys), gives folds a uniform join key, and still excludes checkpoints (no human/agent "wrote" a pointer record). `bill_to`/`cost_ref` on *every* durable line multiplies garbage and fights F13's existing `charge` shape; spend attribution belongs next to reserves/settlements, not on `idle` or `state_change`. Drift is real for nullable-everywhere **only if** every module invents its own actor; fix at the **producer seam**: EmitBridge/Writer stamps `actor` from the command/attach context for all events in that write generation, default null only for true system emissions.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**
- **Identity model unset**: `%{kind, id}` without a frozen namespace (`:client_uuid` vs `:agent_registry_id` vs opaque string) makes cross-session rollup meaningless even with R1.
- **"Default = session owner" is not on disk**: under only-grows, implicit defaults are not replay-stable; strict ingest should treat omitted actor as `:system` or `%{kind: :system, id: "session"}` only by documented fold rule, not by each reader guessing.
- **Conflict with R5 timing**: if G4/G5 fixtures land without envelope-level actor, you get two conventions; pick one canonical placement (envelope vs payload) now to avoid duplicate actor fields that diverge.
- **`bill_to` without ledger correlation**: `cost_ref` should point at reserve/settle identity (internal, per F4) or folds double-count against `charge`.
- **UI fork at skew**: broad actor encourages dashboards to chart "who did what"; unknown `kind` values must stay tolerant, but partial actor shapes must not crash renders (reader seam).

---

## Q3: Model/params fingerprint breadth

**PICK:** **(a) Every LLM-bound completion**: fingerprint on **`item_completed`** (primary loop) **and** on **`probe_run`** (or nested in its payload when status is terminal), not probe-only.

**REASONING:** R4 already obligates head deviations in `turn_started.payload`, but **what actually hit the wire** is decided at item completion (and per probe call). Codex-style per-turn renegotiation and mixed-model fleets make session-head + turn_started declarations necessary and insufficient; counterfactual "fork at 412, rerun with model X" diffs against **completed** items, not against intent at turn start. `probe_run`-only leaves the hottest path unauditable and breaks parity with P-U12.3 prefix tests (primary prefix identity is meaningless if model/params at that tip are unknown). Use a frozen struct like `%{provider, name, revision, params_hash}`; add **`prompt_cache_key` as optional opaque string, never required for replay correctness**.

**REASONING (granularity):** **`params_hash`** (canonical JSON or stable bag serialization, documented once) beats inline key params: providers add knobs continuously; inline fields become a second registry fighting only-grows. Keep **`name` + `provider` inline** for human audit without hashing. **`prompt_cache_key`** is worth freezing as optional telemetry for cache-riding economics (U12 cached vs uncached split), with an explicit contract note: **provider-defined, best-effort, not part of replay identity**: replay identity is `params_hash` + AD-5/OQ4 wire reconstruction, same as treating cache hits as optimization.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**
- **Triple redundancy**: head FI-2 tag, `turn_started` overrides (R4), and per-item fingerprint can disagree; contract should say **item_completed fingerprint wins for "what produced this content"**, turn_started wins for "what the user asked for," head for defaults only.
- **`params_hash` without a canonicalization spec** is useless across writers: one normative serialization (sorted keys, excluded ephemeral fields) or hashes are incomparable in golden fixtures.
- **`revision` optional and provider-specific**: some APIs lack revision; don't require it at strict seam or ingest will lie with placeholders.
- **Non-LLM `item_completed`**: if an item can complete without a provider call, fingerprint absent vs null must be explicit so replay tools don't assume every item is LLM-bound.
- **Probe fingerprint vs `charge`**: terminal `probe_run` should carry fingerprint of the **last** or **per-call** policy; multi-call probes need either last-wins documented or a grow-only list later: otherwise migration audits under-count param changes mid-probe.

---

## BIG PICTURE (3 lines)

All three rulings share one spine: **linear, dense, single-writer journals** hold facts at offsets; **session-level DAG** holds provenance and convergence (NC-12); **per-offset attribution** (actor, spend refs, model fingerprint) states what actually happened at that offset for audit, billing, and replay-fork tooling.

Q1 and Q3 pull together: counterfactual replay is a **new session with `:fork` edges**, rerunning from a parent offset with a new fingerprint, never a journal rewrite. Q2 middle shape aligns with that: actors explain *who* triggered events on spawned/merged sessions; spend and fingerprint attach where provider work completed, not on every checkpoint line.

The main tension is **surface area vs drift** (Q2b/Q3a); it is manageable if producer-seam stamping and "which field wins" precedence are frozen alongside the fields, not left to fold folklore. No pair of these three rulings forces CRDT, dual id spaces, or tip predicate changes, if implementation does, that is a violation of the ruling set, not a reason to soften it.
