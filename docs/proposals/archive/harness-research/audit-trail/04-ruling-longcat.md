## Q1: Session lineage shape

**PICK: Ratify the typed-edge list + NC-12, exactly as proposed.**

**REASONING:** Scalar `forked_from` petrifies as a tree the moment fork fixtures land: merge then requires either a forbidden type change or a parallel `merged_from`/`spawned_by` field per relation, which is the dual-id landmine's genealogy-shaped cousin (and the OpenHands #4057 horror of 5,566 orphaned events retrofitting branching after lock). The list-of-edges shape is the only representation that stays additive-only under merge/spawn/import simultaneously. The journal stays strictly linear; the DAG lives at the session level only. The tip law survives merge untouched because `tip(journal, branch)` selects highest conversational offset per branch: parents affect folds (history reconstruction), never tips (resume points). A merge creates a new session whose lineage names N parents; the winner's effects append to mainline as new offsets, history is never rewritten into a DAG, and the Dormammu fixtures stay valid verbatim. NC-12 (no CRDT journal, ever) is the negative constraint that makes the positive rule load-bearing: Figma-style convergence breaks the dense-offset law, I5 corruption detection, and the single-writer name simultaneously. The same user value (converge later) is delivered by fork+merge with a human/oracle at the merge: git's answer.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**

- **`relation` enum vocabulary boundary for `:resume`.** Reattaching to a compacted journal is NOT a lineage edge: it's a read-side operation on the same session, and lineage edges are about session *origin*, not read attachment. Make the ruling explicit that `:resume`/reattach is never a relation, or a future author will add it and conflate provenance with read attachment. The four relations (`:fork | :spawn | :merge | :import`) are the minimal complete set covering every documented case.

- **"Winner's effects append to mainline" is underspecified journal-side.** The lineage edge names parents; the merge session's first event naming the merge reason is sufficient journal-side. The ruling should explicitly scope *how* the winner is chosen and how the merge session is constituted as a consuming-store/orchestrator concern, not a journal concern, or a future author will try to journal the merge decision inside the journal and create a second truth.

- **Dangling parent refs and reader health.** A `:merge` edge's parent may be absent from the tar (export/import of one branch). The ruling must freeze a sentence: "a reader with a missing parent still reads THIS journal healthy (lineage is provenance, not replay input)", or a naive reader marks merged journals damaged. R2 in the future-foundations doc addresses this, but it's not in the converged shape itself.

---

## Q2: Actor attribution breadth

**PICK: NARROW: optional `actor` only on approval-decision records (G4) and command records (G5 `prompt`/`steer`, mirrored to `turn_started.payload`). Defer `bill_to` and `cost_ref` entirely.**

**REASONING:** The genuinely load-bearing records are decisions (who approved/denied) and command origins (who sent this prompt). These are the audit/compliance holes. For every other record, actor is derivable from session context (session owner) or backward `refs` chain until you hit a command or approval. The "derivable fails in interesting cases" argument is true for sub-agent spawns and multi-client attach, but those are captured by *other* frozen mechanisms (sub-agent `:spawn` parent edge, multi-client `client_msg_id` + G5 actor on the command). Broad `actor` on every record looks free but isn't: different writers (loop, probe runner, system) populate it inconsistently, the field becomes unreliable garbage, and the only-grows law means you can't later constrain it. `bill_to`/`cost_ref` on every record duplicate and potentially *contradict* the Ledger's authoritative accounting (the dual-source-of-truth horror class); billing is a derived fold over the Ledger + R1 lineage subtrees, not a per-record field.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**

- **Multi-client attach + approval race.** If Client A's prompt is in flight when Client B's `approval_decided` arrives, the approval's `actor` alone doesn't capture *which prompt* it corresponds to. This is already handled by `refs` (approval names the specific `approval_requested` offset) + G5 `client_msg_id`, but the converged sources didn't state this interaction explicitly. The ruling must confirm `refs` + `client_msg_id` is sufficient, or the narrow actor scope has a real multi-client hole.

- **Sub-agent `:spawn` and the actor of the sub-agent's first loop event.** Under narrow scope, the sub-agent's loop events don't carry `actor`: they're derivable from the session, which was spawned by the parent. The sources arguing for broad attribution worried about "multi-agent chargeback needs per-record attribution"; the answer is R1 lineage + per-subtree fold over charge records (F13 composes-free). Don't put `bill_to` on loop events.

- **Trigger-woken (F9) actor.** A turn fired by `:surface_cron` whose actor is "the trigger configuration, not an immediate human" is fine for audit. The chain is reconstructible via provenance source + G5. The broad-scope sources didn't trace this case, and narrow actor doesn't break it.

---

## Q3: Model/params fingerprint breadth

**PICK: probe_run only. R4's replay-fidelity law handles per-turn overrides via `turn_started.payload`.**

**REASONING:** The per-turn override case is real but belongs at turn granularity, not item granularity. A turn is the atomic unit of negotiation (`turn_started`/`turn_completed` brackets), and every item in a turn shares the turn's model unless item-level override exists (the rare case). R4's law ("any per-turn override of a head-tagged parameter MUST be journaled in that turn's `turn_started.payload`") is the natural home. probe_run is the replay-science surface and genuinely needs the fingerprint: counterfactual replay ("rerun probe P under model X, diff") is the load-bearing use case. For `params_hash`, freeze *both* the content-addressed hash of the full bag AND a capped inline subset (`temperature`, `top_p/top_k`, `max_tokens`, `seed`): hash alone is opaque, inline alone is unbounded; this mirrors the frozen `charge` shape discipline (split is the type; function over it is policy). **`prompt_cache_key` is NOT worth freezing**: providers change cache-keying semantics without notice, and freezing the field invites false confidence; the real cache contract is the byte-identical prefix (P-U12.3), which IS the provider-agnostic cache promise.

**RISKS THE CONVERGED SOURCES MAY HAVE MISSED:**

- **The "primary loop rarely varies" argument is a local minimum.** Today's harnesses rarely vary model mid-session, but multi-model journals are the *corpus norm* (cc-fleet mixing DeepSeek/GLM/Kimi, Kilo 500+ models, PewDiePie swapping 8→64 models mid-project). R4 + probe_run fingerprint covers both cases without putting a fingerprint on every `item_completed`. The converged sources analyzed current practice, not the multi-model norm-in-waiting.

- **`params_hash` semantic stability across schema additions.** A future redefinition of what's in the "bag" makes old hashes non-comparable. The ruling should state: `params_hash` covers the keys present at write time; additive bag keys are a schema_version minor bump (old hashes bag-over-old-keys, new hashes bag-over-new-keys). The sources didn't state this versioning implication.

- **probe_run fingerprint cost is real and bounded.** Full fingerprint (~200 bytes/run) on every probe_run is overhead, but probes are bounded by the parking cap (F5) and the science demand wins. Don't trim the fingerprint to save bytes; under-instrumenting the replay surface defeats its purpose.

---

## BIG PICTURE

All three rulings cohere as one design: **a linear, dense-offset session journal with attribution at injection points and derivation only at turn/probe boundaries.** Narrow actor (G4/G5) + per-turn override journaling (R4) + probe-only fingerprint + list-of-edges lineage (R1) + NC-12 no-CRDT together express "the session directory is the portable, auditable, replayable unit; everything else is a derived fold or a subscriber projection." None pull in different directions: the narrow scopes prevent the semantic drift broad fields would introduce, R1 handles cross-session expressiveness without breaking the linear-journal law, and the fingerprint discipline keeps the replay-science surface exact without bloating the hottest event type.
