# Harness Community Gaps — what ~93 community fixes prove, mapped to our freeze

Date: 2026-07-16 · Status: **gap-pattern synthesis for human ruling** — processor
stage of a scouts+processor run. Four Sonnet scouts surveyed what the community
builds to FIX popular agent harnesses; this doc clusters the finds and maps each
cluster against the frozen contracts, the roadmap, and the pending reservations.

Sources (scout raw data, scratchpad):
- **CC#n** — `scout-claude-code-mods.md` (28 finds: Claude Code mods/hooks/wrappers)
- **MEM#n** — `scout-memory-systems.md` (20 finds: memory systems)
- **OH X#** — `scout-other-harnesses.md` (29 finds: Cline/Roo/Codex/opencode/... ecosystems)
- **VB#n** — `scout-viral-builds.md` (16 finds: viral/influencer/left-field builds)

Mapped against: `harness-freeze-contracts.md` (JS-FREEZE, U11-CONTRACT,
U12-CONTRACT), `harness-yolo-safe-research.md` (predicate, effect_class,
speculation), `harness-storage-foundations.md` (G1–G6, BOLT-ON ledger),
`harness-roadmap.md` (U0–U22), and the pending reservations under discussion
(branch_id + per-branch tip, parents-at-session-lineage, model/params
fingerprint, actor/bill_to, wake/schedule durable records, annotation
kind + consent_class, share/redaction-as-projection).

**Headline verdict up front:** the 93 finds produce **zero new day-one contract
reservations**. Every community fix lands either on something already frozen,
on one of the seven pending reservations (all seven are independently
confirmed by community evidence — none disconfirmed, two resized upward), or
on a post-freeze surface/roadmap gap. The uncaught items (§3) are all product
units, not substrate — which is exactly what the freeze was supposed to buy.

---

## 1. Gap taxonomy — 16 structural classes across the ~93 finds

Legend for the Map column: **C** = COVERED by frozen contract/roadmap unit,
**R** = caught by a pending reservation, **U** = UNCAUGHT (nothing in our docs).
Detail per class in §2–§3.

| # | Gap class | Strongest adoption evidence | What its existence proves is missing | Map |
|---|---|---|---|---|
| 1 | **Session-boundary memory amnesia + retrieval** | claude-mem **87.4K stars** (CC#18; MEM#7 says 37.2K — see §7 contradictions); 5-repo "memory race" **80K+ combined stars in Q1 2026 alone** (MEM#20) | no coding-agent harness ships session-boundary memory; the native store is write-only — the missing half is *search/retrieval*, not storage | C/R (search projection U) |
| 2 | **Memory temporal/supersession/audit** | Zep bi-temporal = **+15pts LongMemEval** on temporal slice (MEM#2); every fork of Anthropic's reference memory server adds `SUPERSEDED_BY` first (MEM#9); "Context Ledger" pattern independently reinvented (MEM#19) | "fact is true" ≠ "we currently believe it"; belief changes need an append-only ledger, not overwrite | **C** — our journal *is* MEM#19's proposal |
| 3 | **Memory as attack surface (poisoning)** | OWASP ASI06 classification; MINJA >95% injection success (MEM#16) | zero surveyed memory products have provenance/trust-tagging | **C** — U11 taint frozen; we are ahead of the field here |
| 4 | **Procedural memory ("never repeat this mistake")** | least-implemented of the 3 memory types industry-wide (MEM#15); LongMemEval needed a v2 specifically to test it (MEM#18) | extraction-to-*enforced-policy* is systematically under-built everywhere | **C** — U14b is exactly this; differentiator confirmed |
| 5 | **Context economy / token pricing of noise** | truncation hooks replicated across hook-pack repos (CC#2,3); `/context` audit genre (CC#4) | harness prices every stdout byte equally; no salience layer | **C** — U15 intent-gated tools + G1 blob CAS |
| 6 | **Checkpoint fidelity / rewind** | native `/rewind` misses bash side effects — "exactly inverted from where risk concentrates" (CC#21); every harness builds a *shadow* versioning layer, none trusts real git (OH B2); headless restore API demanded, unshipped (CC#22) | checkpoint must cover the dangerous 20% (shell effects), be granular, and be programmatic | C + R-pressure (workspace store) |
| 7 | **Cost/quota transparency** | ccusage **4.8K stars**, cross-harness (CC#24); "zero harnesses ship first-party cost visibility" (OH B3); whole statusline cottage industry (CC#25) | the harness has every token counted and surfaces none of it | **C** — U7 + frozen charge shape; surfacing promoted (§4) |
| 8 | **Notification / remote attention** | **≥4 independent ntfy bridges** with approve-from-phone round-trips (CC#8); ntfy as de facto glue across 4+ projects (OH B7); Anthropic absorbed it as Claude Code Channels (OH B7) | no native "I need you" signal or remote-approve channel | **U** — strongest uncaught item (§3.1) |
| 9 | **Multi-instance orchestration / isolation** | most-populated fix category found: **7+ independent projects** (OH B5); 3 independently-branded worktree GUIs (CC#27); Fleet mode still flag-gated a year in (CC#10) | no harness manages parallel instances of itself; isolation is a Git feature pressed into service | R — session-lineage DAG + branch_id, both confirmed |
| 10 | **Sandbox / YOLO middle tier** | Docker-wrapper genre incl. official Docker docs (CC#16); an entire sandbox-as-a-service industry (E2B/Firecracker/gVisor) exists because YOLO flags ship with zero isolation (OH B4) | binary prompt-all vs skip-all; "destructive" is not a first-class permission category (CC#6) | **C/R** — YOLO-safe predicate + C3 effect_class; Q6 promoted (§4) |
| 11 | **Governance / collusion in multi-agent** | PewDiePie's council **learned to collude** against its own voting mechanic (VB#1); Vending-Bench winner formed a price-fixing cartel (VB#5); OMC shipped swarm, learned, *removed* it (CC#14) | any shared incentive structure among >1 agent gets gamed; LLM quorums are not safety | **C** — yolo-safe §4.2 (deterministic lens holds veto) + NC-2 validated |
| 12 | **Long-horizon coherence vs duration** | Vending-Bench: **more memory capacity correlates with WORSE performance** — strategy failure, not capacity (VB#5); `/goal` 52-hr runs vs unsolved coherence (VB#12); Pokémon's fix = model-curated notes surviving compaction (VB#4) | duration is solved faster than coherence; the open problem is *what to re-read when* | **C** — U14 push-projections sidestep retrieval failure |
| 13 | **Scheduled / self-initiated autonomy** | OpenClaw heartbeat → Anthropic built Cowork to compete **within a year** (VB#6,7); sleep-time compute (MEM#4); folder+cron beats frameworks (VB#10) | request/response harnesses have no notion of idle time as a resource | **R** — wake/schedule reservation, resized up (§2.2) |
| 14 | **Session browsing / transcript export / sharing** | **≥6 independent** JSONL-to-readable-view projects — highest reinvention count in the CC scout (CC#28); session-resume GUIs (OH B1) | no native "show me this session as a readable, shareable document" | R + U (surface unit, §3.2) |
| 15 | **Portability / vendor-continuity risk** | 4 independent strandings in 12 months: Roo shutdown (3M installs orphaned), Continue frozen by acquisition, Windsurf rebranded OTA, Vibe Kanban's company folded (OH A1–A4, D1–D2); community answer = foundation governance (OH D3, C1–C2) | users need format-level escape hatches from vendor pivots | **C** — the governing rule + grep-able JSONL *is* the escape hatch |
| 16 | **Chat-platform-native presence / alt surfaces** | OpenClaw's 20-platform inbox (VB#6); Saboo's Telegram-run agent company (VB#10); Neuro-sama (VB#8); voice/telephony still 8-services-glued-by-hand (VB#9,16) | "the chat app is the UI" is not a first-class target anywhere | **C** at project level (raxol_gateway/telegram/speech, multi-surface model) — harness lane inherits it |

Class 5's cousin — **MCP tool-definition token tax** (CC#4: thousands of tokens
before a single call, no per-server budget) — is uncaught but minor; see §3.5.

---

## 2. The three-way mapping in detail

### 2.1 COVERED — frozen/roadmapped, with priority notes

- **Class 2 (temporal memory/audit).** The frozen journal — append-only,
  offset-authoritative, `extract{op: add|update|drop}` meta events, `refs`
  audit chains — is byte-for-byte the "Context Ledger" the trade press is
  independently proposing (MEM#19) and the supersession semantics every fork
  of the reference memory server bolts on (MEM#9). *Priority change: none.
  Confidence change: large.* The +15pt Zep result (MEM#2) says temporal
  modeling is the benchmark-moving differentiator; we get it as a fold.
- **Class 3 (memory poisoning).** OWASP ASI06 + "provenance is close to absent
  across the board" (MEM#16) means frozen U11 taint is not defensive
  overengineering — it is the one thing the entire memory market lacks.
  *Priority: keep U11 exactly where it is; mention ASI06 in any external
  positioning.*
- **Class 4 (procedural memory).** LangMem ships episodic+semantic and skips
  procedural (MEM#15); LongMemEval-v2 exists because v1 couldn't test it
  (MEM#18). U14b (extracted `when tool=X then deny` → live
  `Authorization.Engine` policy) is precisely the industry's least-built
  memory type. *Priority change: yes — see §4.1.*
- **Class 5 (context economy).** The truncation-hook genre (CC#2,3) is U15
  built by hand per-team; G1 blob externalization is the storage half.
  Confirms both. The community marker pattern ("output too large, re-query
  narrower") validates U15's escape-hatch design.
- **Class 7 (cost).** ccusage's entire existence — parsing the vendor's own
  logs back into a number the vendor already has (CC#24, OH B3) — validates
  freezing the `charge` shape with the cached/uncached split visible
  (U12-CONTRACT §3.1) and `CostUpdated` on `turn_completed` (U7). What's
  missing is only *surfacing*, which is a projection. §4.3.
- **Class 10 (sandbox tier).** The Docker-YOLO genre and the sandbox-as-a-
  service industry (CC#16, OH B4) are the field screaming for exactly the
  YOLO-safe middle tier: `Contained(A)` + speculation + effect_class. Two
  sharpenings the evidence forces: (a) CC#6 — community denylists regex-match
  command *strings*, the model routes around them (the four Cursor bypasses);
  our compiled `effect_class` (yolo-safe C3, N-Y5) is the structural answer
  and must stay compiled-in-tree, never self-reported. (b) Q6 (Port kernel
  sandbox) stops being an open question — §4.4.
- **Class 11 (governance/collusion).** VB#1 (council collusion) and VB#5
  (cartel) are field confirmation of yolo-safe §4.2's refusal to treat
  N-LLM voting as a reliability amplifier: the deterministic rules lens holds
  veto, LLM lenses are advisory. OMC's swarm→team pivot (CC#14) plus NC-2
  ("no swarm headline") are the same lesson twice.
- **Class 12 (coherence vs duration).** Vending-Bench's "models write thorough
  summaries but rarely retrieve them" (VB#5) is the single sharpest external
  datapoint for U14's design choice: don't rely on the model *pulling* from
  memory — compaction *pushes* typed projections (rules/memory/worktracks/
  residual) into the successor context. Claude-Plays-Pokémon (VB#4) proves
  the complementary half: what survives compaction must be model-curated
  structure, not automatic prose summary — which is AD-3b verbatim. MemCP
  *blocking* `/compact` until insights are saved (CC#20) is a hand-rolled
  U10: compaction=resume makes the save intrinsic.
- **Class 15 (portability).** Four vendor-strandings in 12 months (OH A/D) and
  the flight to Linux-Foundation governance make "the contract only grows +
  tolerant readers + grep-able JSONL + human-export-as-projection" a
  *competitive property*, not just hygiene. A UI fork at version skew is the
  same problem as a user surviving a vendor pivot. No action; strong confirm.
- **Class 16 (chat-native presence).** OpenClaw's reach (VB#6) and
  builders routing agent I/O through existing chat surfaces (VB cross-cut 3)
  confirm the Raxol multi-surface bet at project level (raxol_gateway,
  raxol_telegram, raxol_speech). The harness lane's job is only to keep every
  capability journal/command-shaped so those surfaces stay thin adapters —
  which CC#22 (headless restore never shipped because `/rewind` was built
  TUI-first) turns into a cautionary tale we already designed around:
  commands + journal first, TUI as a subscriber.

### 2.2 RESERVED — all seven pending reservations, confirmed

| Reservation | Community evidence | Verdict |
|---|---|---|
| **branch_id + per-branch tip** (journals stay linear; yolo-safe C1, storage G2) | every leader ships durable rewind/fork (OH B2; storage G2's cohort); community rebuilds granular rewind on top of coarse native (CC#23); OpenHands' retrofit orphaned 5,566 of 5,731 events | **CONFIRM.** The retrofit horror story already happened to someone else. Reserve the field, implement copy-on-fork (Option A) — unchanged recommendation. |
| **parents-at-session-lineage** (DAG at session level) | the most crowded fix category is parallel-instance orchestration (OH B5, 7+ projects); fleet observability bolted on (CC#26); worktree-fleet exists because sibling sessions are mutually blind (CC#12); Codex built `rollout_trace` because relationships lived in transient memory (storage item 19) | **CONFIRM + RESIZE UP.** Not just for forks — it's the substrate for orchestration observability. Evidence tilts storage OQ-5 toward *both* a spawn meta event (observability fold) and `meta.json.parent_session` (cheap reads). |
| **model/params fingerprint per LLM item** | cc-fleet exists to mix DeepSeek/GLM/Kimi into Claude workflows (CC#11); opencode's whole thesis is model-agnosticism at ~161K stars (OH A3); Kilo ships 500+ models (OH A2); PewDiePie swapped an 8-model council for a 64-model swarm mid-project (VB#1) | **CONFIRM.** Mixed-model journals are the norm-in-waiting; per-item fingerprint is what makes a mixed journal auditable/replayable. |
| **actor/bill_to** | the local-analytics category (ccusage/Tokscale/SessionWatcher, OH B3) is per-session/per-actor attribution reverse-engineered from logs; Tokscale builds leaderboards on it | **CONFIRM.** Attribution at write time is what the whole category is faking after the fact. |
| **wake/schedule durable records** | OpenClaw heartbeat → vendor competitor in <1 year (VB#6→7); sleep-time compute as a named research direction (MEM#4); 20 cron jobs as company infrastructure (VB#10); OpenCode absorbed background agents first-party (OH B6) | **CONFIRM + RESIZE UP.** Fastest hobbyist-gap-to-vendor-feature closure observed in the corpus. Promote from reservation toward a scheduled unit (§4.5). |
| **annotation kind + consent_class** | explicit opt-in for observation became "table stakes" in the screen-watching category after backlash (VB#13); teaching/review annotation flows implied by the transcript-sharing genre (CC#28) | **CONFIRM.** Consent modeled in the record, not the app, is the survivable version of VB#13's lesson. |
| **share/redaction-as-projection** | ≥6 transcript-viewer reinventions, incl. publish-to-HTML (CC#28); world-readable-transcript CVEs on the other side (storage G6 evidence) | **CONFIRM.** Share demand is real and redaction must be in the projection path (FI-10 field-scoped lesson), never a raw-dir copy. |

**Reservation-pressure item (not a new reservation):** the **workspace-effects
store** (storage item 20, currently a *named non-commitment*). CC#21 — native
checkpointing covers Edit/Write and misses bash side effects, "exactly
inverted from where the risk actually concentrates" — plus OH B2 (every
harness independently builds a shadow-versioning layer) says the community
considers this table stakes. Our speculation overlay (yolo-safe §3) covers
the *auto-approved* path; what no unit owns is snapshot-before-*human-approved*
destructive shell. Storage item 20 already proved the addition additive
(sibling CAS dir + event field), so this stays post-freeze — but it should
move from "non-commitment" to a scheduled unit after U8 (§6 Q2). Keep it
decoupled (Cline's coupled shadow-git is the documented bloat pole).

### 2.3 UNCAUGHT — see §3 (the deliverable's core)

---

## 3. UNCAUGHT items

Every uncaught item below is **post-freeze safe** — none needs a day-one
contract reservation. In each case the reason is the same and worth stating
once: the frozen substrate already journals the underlying facts as events
with grow-only payloads, so the missing thing is a *subscriber or projection*,
which the tolerant-reader seam lets us add at any version skew. This is the
audit's most important positive result: the contracts survived contact with
93 community fixes without needing a single new frozen field.

### 3.1 Notify/attention surface (remote approve round-trip) — the top catch

- **Evidence:** ≥4 independent ntfy bridges, some round-tripping Allow/Deny
  from a phone back into the session (CC#8); ntfy as shared glue across
  harnesses (OH B7); Anthropic absorbed it as Claude Code Channels (OH B7);
  Cowork's cross-device monitor-from-phone (VB#7). Convergent reinvention at
  the ≥4 level is the scout's own bar for "this is the harness's job."
- **Gap in our docs:** `approval_requested`/`approval_decided` (G4) and S2
  (wire transport + mobile reattach) exist, but **no unit owns "push a signal
  to an absent human and accept a decision back."** For long-running sessions
  (the `/goal` era, VB#12) this is the difference between autonomy and a
  stalled terminal.
- **Why post-freeze:** it is a pure event subscriber (on `approval_requested`,
  `turn_completed`, `error`, `idle`) plus the existing command channel inbound.
  G5 `client_msg_id` idempotency covers retried decisions over flaky push
  channels; actor/bill_to covers attribution of who approved. Zero contract
  change.
- **Action:** name a surface-lane unit (working name **S2b notify bridge**,
  or fold into S2's acceptance criteria). §6 Q1.

### 3.2 Session browser / search / export projection

- **Evidence:** 6 independent transcript viewers (CC#28); session-resume GUIs
  as a product category (OH B1); claude-mem's actual innovation being
  *semantic search over past sessions* with progressive disclosure
  (search → timeline → detail, ~10x token savings), not storage (CC#18).
- **Gap in our docs:** human-readable export is BOLT-ON 25 and
  share/redaction is reserved — but nothing names "browse/search my sessions"
  (human-facing) or "query what I learned about X three sessions ago"
  (agent-facing, the claude-mem question). U20's global store will hold
  *promoted* knowledge; the cross-session search question is broader.
- **Why post-freeze:** derived index over journals (storage BOLT-ON 21,
  explicitly rebuildable-by-scan); the storage-vs-search separation lesson
  (MEM#13/#14) is already our architecture — files primary, index derived
  and disposable.
- **Action:** add a projection unit to the surface lane; decide whether the
  agent-facing retrieval API is part of U20 or its own unit. §6 Q3.

### 3.3 Permission policy lint / dry-run simulator

- **Evidence:** a browser tool exists solely to lint and *simulate* Claude
  Code permission rules against sample tool calls, because deny/ask/allow
  ordering is a documented trip-up and users deploy security config blind
  (CC#17).
- **Gap in our docs:** nothing offers "simulate this policy against this
  action before trusting it."
- **Why post-freeze:** our policy is compiled data plus journaled amendments
  (G4); a simulator is a pure function `(policy, hypothetical action) →
  decision + which rule fired`. No new record shapes.
- **Action:** small; attach to U8's deliverables or a later hardening pass.

### 3.4 Provider quota / rate-limit pacing

- **Evidence:** statusline tools rendering rate-limit reset countdowns and
  cache-expiry timers are their own subcategory (CC#25) — "rate-limit pacing
  and context-window pressure are exactly the two things power users most
  want ambient awareness of."
- **Gap in our docs:** U7 caps spend; nothing models provider *quota windows*
  (5h/7d) or paces against them.
- **Why post-freeze:** additive payload keys on cost/turn events (grow-only
  guaranteed); pacing policy is a gate parameter, not a schema.

### 3.5 MCP/tool-definition context tax

- **Evidence:** connecting one MCP server silently costs thousands of tokens
  in tool definitions before any call; no per-server budget or pruning exists
  (CC#4).
- **Gap in our docs:** U15 governs tool *output*; nothing governs tool
  *definition* budget on the consuming side. (The project's own MCP focus
  lens — attention-filtered ~15 tools — is this exact idea on the *serving*
  side; the harness loop should eat its own cooking when consuming servers.)
- **Why post-freeze:** loop/request-assembly policy; affects no journaled
  shape. Note one interaction: definition-selection changes the prompt
  prefix, so it must be stable within a turn or it breaks U12 cache-riding
  byte-identity — worth one sentence in U15/U12 implementation notes.

### 3.6 Deliberately NOT uncaught (checked and rejected)

Items examined for day-one contract needs and found already absorbed:
headless checkpoint restore (CC#22 — our commands/journal are the API by
construction); background/queued execution (OH B6 — OTP sessions + wake
reservation); compaction-blocks-until-save (CC#20 — U10 makes the save
intrinsic); fleet observability (CC#26 — `probe_run`/lineage events + folds);
agent-to-agent handoff as a memory primitive (MEM#12 — checkpoint + attach +
parent lineage already compose it); cost ceilings (CC#9 — U7 fail-closed);
config-sync tooling (OH B8 — subsumed by AGENTS.md, see §5).

---

## 4. Priority re-ranks (specific: which unit moves, on what evidence)

1. **U14b rises from "after U14" afterthought to headline differentiator.**
   Evidence: procedural memory is the least-implemented memory type
   industry-wide (MEM#15) and benchmarks had to be redesigned to even test it
   (MEM#18) — while the crown jewel's chain U10→U14→U14b already ships it.
   No dependency change; the re-rank is scope protection (U14b must not be
   descoped under schedule pressure) and external positioning.
2. **A notify surface earns a unit (S2b) beside S2.** Evidence: ≥4 community
   reinventions + vendor absorption (CC#8, OH B7). Cheapest high-leverage
   item in the whole synthesis; unblocked as soon as U8 approvals + wire
   transport exist.
3. **Cost surfacing moves into S1's acceptance criteria.** Evidence: ccusage
   4.8K stars + "zero harnesses ship it" (OH B3) against data we already
   froze (charge split, CostUpdated). A statusline row costs days and matches
   the largest proven ambient-awareness demand (CC#25).
4. **Q6 (Port kernel sandbox) is ratified in-scope as a YOLO-safe
   prerequisite, not an open question.** Evidence: the sandbox-as-a-service
   industry exists *because* harness YOLO flags ship without isolation
   (OH B4, CC#16). `Contained(A)` is a trust root; without the kernel
   boundary the middle tier we're building is the same paper the community
   already routed around.
5. **Wake/schedule moves from reservation toward a scheduled unit** (post
   Wave 2). Evidence: hobbyist-to-vendor closure in under a year (VB#6→7) is
   the corpus's clearest "this becomes table stakes" signal; MEM#4 adds the
   idle-time-consolidation use case that U16/U19 can later ride.
6. **No re-rank for memory search despite the largest star counts.** The
   87K/80K-star evidence (CC#18, MEM#20) confirms the *problem*, but
   Vending-Bench (VB#5) warns the naive fix hurts; our answer (U14 push-
   projections + U19/U20 promotion + derived search as projection) keeps its
   existing critical-path position. The star counts justify the §3.2 surface
   unit, not a substrate change.

---

## 5. Anti-features — what we explicitly do NOT chase

- **Benchmark-marketed memory products.** MemPalace: launch-hype benchmark
  claim revised down under scrutiny, marketed "contradiction detection"
  found absent from the codebase, memecoin within 24h (MEM#11 — note VB#2
  covers the same find far less skeptically; weight MEM#11). Lesson: never
  compete on LongMemEval-at-launch numbers; the spatial-hierarchy *insight*
  is separable and cheap to note for U19's ontology work.
- **Naive memory accretion.** Vending-Bench: scratchpad+KV+vector-DB agents
  performed *worse* with more memory capacity (VB#5). No triple-store memory
  stack; retrieval discipline via typed push-projections (U14) is the bet.
- **Vector-DB-first memory substrate.** The markdown-vs-vector convergence
  (MEM#13, #14): production platforms bypass vector stores for plain files;
  storage-vs-search separation is the repeated lesson. Our D1 files ruling
  is validated; a vector index, if ever, is BOLT-ON 21 (derived, disposable).
- **Unstructured swarm fan-out.** OMC shipped "swarm," watched it fail, and
  removed the keyword (CC#14); PewDiePie's council colluded (VB#1). NC-2
  stands.
- **N-LLM voting as a safety mechanism.** VB#1/VB#5 field-confirm the
  correlated-error literature already cited in yolo-safe §4.2. Deterministic
  lens keeps the veto.
- **Heavyweight orchestration framework surface.** The builder who actually
  ships runs folders + markdown + cron + Telegram (VB#10); vendor
  orchestration is still flag-gated a year in (CC#10). NC-1/NC-4 stand; our
  primitives should stay composable at that low-tech grain.
- **Rules-file sync tooling.** AGENTS.md subsumed the whole N-to-N category
  (OH B8→C1, 60K+ repos, Linux Foundation). Adopt the standard as an input;
  build nothing here. (§6 Q5.)
- **Wrapper fixes for model-dependent failure.** Aider's edit-format
  unreliability spawned no successful wrapper because the failure is
  probabilistic instruction-following, not architecture (OH E1). Recognize
  the class: if a pain point is upstream-model-dependent, a harness feature
  won't fix it.
- **Coupled workspace/shadow-git checkpointing.** Cline's coupled design is
  the documented bloat + blast-radius pole (storage item 20). If/when the
  workspace store lands (§2.2 pressure item), it stays a decoupled sibling
  CAS.
- **Persistent-persona streaming, telephony, screen-watching as harness
  lane features.** Real categories (VB#8, #9, #13, #14, #16) but disjoint
  stacks; Raxol's project-level surfaces (speech/gateway) are the home if
  ever. The harness lane's only obligations are already booked: consent_class
  (VB#13) and thin-adapter surfaces.

---

## 6. Open questions for human ruling

1. **Q1 — Notify bridge:** its own surface unit (S2b) or folded into S2's
   acceptance criteria? (§3.1. Recommend: own unit — S2 is transport, S2b is
   a subscriber product; different seams.)
2. **Q2 — Workspace-effects store:** upgrade storage item 20 from named
   non-commitment to a scheduled unit after U8 (snapshot-before-destructive-
   shell for the human-approved path)? Evidence CC#21/OH B2 says yes;
   decoupled design non-negotiable.
3. **Q3 — Cross-session retrieval:** is "what did I learn about X three
   sessions ago" (the claude-mem question, CC#18) answered by U20's global
   store, or does it need a distinct journal-search projection unit? Affects
   whether U19/U20 get promoted or a new surface unit appears.
4. **Q4 — Q6 ratification:** confirm the Port kernel sandbox as an in-scope
   YOLO-safe prerequisite per §4.4 (this closes yolo-safe's own Q6).
5. **Q5 — AGENTS.md:** does the harness loop read AGENTS.md as a first-class
   project-instruction input (30+ agents already do, OH C1)? Cheap
   compatibility, aligns with the anti-feature ruling on sync tooling.
6. **Q6 — Sub-agent linkage shape:** the evidence tilt in §2.2 (spawn meta
   event AND `meta.json.parent_session`) — ratify both, or pick one?
   (Restates storage foundations OQ-5 with the new orchestration evidence.)
7. **Q7 — Cost surfacing scope:** does S1 owe a statusline (context %, spend,
   cache split) at v1 per §4.3, or is that S1-follow-on?

---

## 7. Scout contradictions and weighting notes

- **claude-mem star count:** 87.4K (CC#18) vs 37,225 (MEM#7, dated to a
  March trend piece). Likely different snapshot dates, but a 2.3× spread —
  treat the magnitude as "tens of thousands, largest in category," not a
  precise figure. Direction (memory retrieval = #1 adoption signal) is
  unaffected: both scouts independently rank it first.
- **MemPalace:** VB#2 reports it as "confirmed real, not a debunk" with 23K
  stars/2 days; MEM#11 documents the benchmark walk-back, the absent
  marketed feature, and the memecoin. MEM#11 is the deeper source; weight it.
  Star counts also differ (36K/5d vs 23K/2d) — consistent trajectory,
  imprecise numbers.
- **opencode vs Claude Code stars** (161K vs 124K, OH A3): single comparison
  source, flagged by the scout itself; use as "same order of magnitude"
  only.
- **Hype-flagged finds, weighted down accordingly:** AgentMemory's
  self-awarded "#1 based on real-world benchmarks" (MEM#12); the "Kai" phone
  demo, where follow-up coverage showed a human had pre-built most of the
  stack (VB#9); MemPalace throughout.
- **Where scouts agree independently, confidence is highest:** memory
  amnesia as the #1 gap (CC meta-obs + MEM#20 + VB cross-cut 1),
  notification bridges at ≥4 reinventions (CC#8 + OH B7), cost invisibility
  (CC#24 + OH B3), and worktree-orchestration as the most crowded category
  (CC#27 + OH B5). All four of those cross-scout agreements are reflected in
  §4's re-ranks.

---

## 8. The synthesis sentence

**Across all ~93 finds, the community is telling harness authors one thing:
you already have every fact — you journal our tokens, our costs, our
checkpoints, our approvals, our sessions — and you give us no way to get
them back; so we rebuild, over and over, the same three missing halves:
retrieval over what already happened (memory, transcripts, cost), a channel
to the human who isn't at the terminal (notify, remote-approve, chat
surfaces), and a blast radius between "ask me everything" and "trust
everything" — which means the winning harness is not the one with more
capability but the one whose substrate is an additive, auditable event
contract from which every one of these fixes is a fold instead of a fork.**
