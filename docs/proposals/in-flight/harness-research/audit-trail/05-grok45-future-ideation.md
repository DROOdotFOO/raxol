# Next-tier reservations (beyond branch / YOLO / blob)

The frozen substrate already encodes the expensive half: **one offset space, derived tip, CAS for bulk, taint lattice, probe cache-riding**. Economics: branching makes journal speculation cheap; byte-identical prefixes make token speculation cheap. Most “killer” features are compositions of those two. What remains are **arity / identity / lineage** doors — the same class as dual-id and linear tip.

Below, rank = `(rewrite severity if missed) × (who will actually want it)`. Already-caught G1–G6 / C1–C3 are not re-scored; this is the tier after them.

---

### Top 8

**1. Session-lineage graph (fuse / transplant / multi-agent tree)**  
*Feature:* Sessions form a directed graph of origins (fork, merge, spawn, transplant), not a flat bag of UUIDs.  
*Who:* Anyone fusing chats, spawning sub-agents, exporting/importing sessions, or explaining “why did this agent do that?” across teams.  
*Reserve now:* In `meta.json` (session-level, not event-level):  
`lineage: [%{rel: "forked_from"|"merged_from"|"spawned_from"|"transplanted_from", session_id, offset, at_ts}]` — **list, grow-only `rel` enum**. Mirror optional `parent_sessions: []` (list, never scalar).  
*Retrofit if skipped:* Scalar `parent_session` freezes a tree; merge and multi-parent spawn become a migration that rewrites every deployed meta + every UI that assumed one parent (OpenHands #4057-class, but at session layer).  
*Composes free:* fork-as-new-session (G2-A) + checkpoint snapshot_ref.  
**Does not compose free:** fuse (N parents → 1 child).

**2. Tip predicate arity + CONVERSATIONAL closure (lock the negative space)**  
*Feature:* Durable rewind, speculation, annotations, GC, schedule wakes never accidentally become “the tip.”  
*Who:* Every reattach surface; YOLO commit; UI fork.  
*Reserve now:* Freeze tip as `tip(journal, branch := :main)` (even if v1 only implements `:main`) and freeze the **exclusion set** explicitly: unknown kinds, all `meta`, `annotation`, `gc`, `schedule`, `speculation` phases, `approval_decided` (if G4) ∉ CONVERSATIONAL. Grow-only membership, never shrink.  
*Retrofit:* Adding a kind that “shouldn’t tip” after reds lock means either false tips in production or rewriting P-JS2/3 + every UI.  
*Note:* This is the cheap half of C1 if you already reserve `branch_id`.

**3. Actor / bill_to / cost_ref per durable record**  
*Feature:* Every journaled fact attributes *who spent and who pays* (human principal, agent id, sub-agent, team, billing account).  
*Who:* Multi-agent teams, SaaS billing, spend gates post-hoc audit, enterprise chargeback.  
*Reserve now:* Optional on every record (default null):  
`actor: %{kind: "human"|"agent"|"system", id}`, `bill_to: string | null`, `cost_ref: string | null` (pointer into a derived ledger, never a second money truth).  
*Retrofit:* Reconstructing attribution from process trees is fiction; historical journals stay unbillable forever.

**4. Model / params fingerprint on every LLM-bound item**  
*Feature:* Counterfactual replay and model-migration: “what would GPT-X have done at offset 412?” requires naming what *did* run.  
*Who:* Eval harnesses, vendors migrating models, regulators, tournament oracles comparing branches.  
*Reserve now:* On `item_completed` (and probe_run): optional  
`model: %{provider, name, revision, params_hash, prompt_cache_key}` — params_hash is content-addressed of the *exact* sampling bag; cache key is the byte-prefix identity the probe runner already depends on.  
*Retrofit:* Without it, counterfactual forks can only guess the original model from HEAD config (wrong after any config change). Replay science dies for old journals.

**5. Wake / schedule as first-class durable records (agent as background worker)**  
*Feature:* Sessions that sleep with no BEAM process and wake on cron, webhook, file-change, or external bus — with the wake reason in the journal.  
*Who:* Long-running agents, CI bots, “watch this PR,” personal automations.  
*Reserve now:* Kind or meta type  
`schedule | %{trigger_id, when: cron|event|once, next_fire, payload_ref, armed}` and loop type `woken %{trigger_id, reason, refs}` **excluded from tip**. Session lifecycle enum grows `:dormant` (not just live/dead).  
*Retrofit:* External cron tables become a second source of truth; after crash you can’t answer “was this wake legitimate?” from the journal alone. Not a schema rewrite of events, but a permanent audit hole and dual-id of *time*.

**6. Annotation / human-label layer as non-tip kind**  
*Feature:* Humans (or oracles) mark spans of history: “good,” “bad,” “PII,” “use as training,” “bookmark.”  
*Who:* RLHF export, training-data pipelines, pair-debugging, compliance review.  
*Reserve now:* `kind: "annotation"` with  
`%{target_offset | target_range, label, body_ref, author, consent_class}` — **must** be excluded from tip now (see #2). Optional `consent_class ∈ {private, shareable, train}` on annotations **and** on originating events.  
*Retrofit:* If labels live only in a UI DB, they desync (cohort horror class). If you later shove them into `event` family, tip reds and golden fixtures rewrite. Consent added late cannot be inferred for past exports.

**7. Share package / redaction view (not in-place rewrite)**  
*Feature:* Export a redacted, portable journal slice for support, multi-device handoff, or peer review.  
*Who:* Cross-device users, enterprise support, open-source bug reports.  
*Reserve now:* (a) Law: redaction is **projection**, never rewrite of historical bytes. (b) Optional `share_class` on records + session. (c) Bundle format: `export_manifest.json` with `schema_version`, `source_session`, `offset_range`, `blob_allowlist`, `redaction_profile`. Reuses G1 blobs by hash.  
*Retrofit:* In-place redaction violates append-only + FI-10 audit; substring redaction already corrupted OpenHands timestamps. Without `share_class`, every share either over-reveals or requires ad-hoc scrubbers that diverge.

**8. Policy / learned-tool records as durable, pre-enforcement facts**  
*Feature:* Learned tool policies, progressive-autonomy thresholds, and human amendments survive compaction and apply only after they are journaled.  
*Who:* U14b/U18 path; YOLO progressive autonomy; any “the agent got better at permissions.”  
*Reserve now:* Extend G4:  
`policy_amended %{scope, rule_id, before, after, source: human|calibrate|oracle, refs}` appended **before** enforcement (same shape as reserve-before-call). Learned policies are just `source: calibrate` rows — not a side file.  
*Retrofit:* OpenClaw class — constraints outside the log die at resume; progressive YOLO becomes non-reproducible theater.

---

### Composes free — reserve nothing (name the non-commitment)

| Feature | Why free |
|---|---|
| **Tournament turns** | N fork sessions (or N `branch_id`s) × shared cached prefix × probe oracle × `speculation` commit of winner. Needs C1/C2 already; no new door. |
| **Counterfactual replay** | Fork at offset + different `model` fingerprint (#4) + same prefix. Fork exists; model field is the only gap. |
| **Memory as MCP** | Global promote store is already ruled bolt-on (derive from `promote` events). MCP resources = projections of journal + promote CAS. **Do not** put cross-session refs in the journal (OQ-U11.1). Reserve only stable URI scheme outside the freeze: `raxol://session/{id}/offset/{n}`, `raxol://memory/{sha}`. |
| **Embedding sidecars** | Derived disposable index (NC-6). Never authoritative for tip/replay. |
| **Journal→training export** | Projection + consent_class (#6). |
| **Multi-device live** | Still one writer per session; multi-device = attach + lease, not multi-writer. Optional meta `writer_lease` is additive later and does not change offset law. |

---

### Conflicts (highest-value findings)

**Conflict A — Record-level DAG vs linear journal forever**  
Fuse-via-`parent_offsets: []` on *events* fights G2-A (“journals stay linear; fork = new session”) and the 0/1-arity tip law.  
**Resolution:** DAG at **session lineage** (#1), never per-event parents. Merge = new session whose first checkpoint names N `{session, offset}` parents. Tournament “merge commit” = append winner’s effects onto main as **new offsets**, not rewrite history into a DAG.

**Conflict B — Cross-session provenance vs OQ-U11.1**  
Multi-agent “shared provenance in the journal” and Memory-as-MCP both want edges across sessions. In-journal cross-session `refs` are permanently forbidden.  
**Resolution:** Session graph in meta/promote store; in-journal `refs` stay session-scoped; multi-agent audit walks the external graph + per-session taint. Two proposals that demand in-journal cross-refs are both wrong under the freeze.

**Conflict C — Annotations/schedules as conversational events**  
If `annotation` or `woken` enter CONVERSATIONAL to “show up in the UI tip,” reattach lands on a label or a cron fire.  
**Resolution:** UI can project them; tip predicate must exclude them from day one (#2). Display ≠ tip.

**Conflict D — Tournament in-journal branches vs copy-on-fork**  
In-journal `branch_id` makes N-way tournament one CAS-friendly log; separate sessions make tip law trivial.  
**Resolution already in YOLO doc:** reserve `branch_id` + `tip(journal, branch)`, implement v1 as sessions. No conflict if both are legal and commit always produces **mainline appends**.

---

### Structural filter (one-way doors only)

| Door | Decision |
|---|---|
| List vs scalar parents | **List at session lineage** |
| Tip arity | **`tip(j, branch)` from day one** |
| One id space | **Keep** (never second numbering for annotations/schedules) |
| Cross-session refs in log | **Never** — graph outside |
| Redaction | **Projection only** |
| Money/model/actor | **Optional fields on records**, not derived guesses |
| Embeddings / MCP views | **Derived** — reserve names, not truth |

The unifying sentence for the freeze appendix: *Log holds small facts and pointers; CAS holds bytes; lineage and tips are pure functions of those; everything billable, learnable, or shareable is either a record field or a disposable projection — never a silent second store.*
