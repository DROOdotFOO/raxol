# Cohort Research Round 2: Journal, Storage, Commands

Date: 2026-07-15 · Phases 1-2 (frame + priors, written BEFORE research returns).
Protocol: dappsnap `cohort-research` skill. Round 1 = `../archive/harness-cohort-research.md`
(general features). This round: the durable seams: where U2 (journal), U4
(reattach), U9/U10 (checkpoint/compaction), U3/U5/U6 (commands) commit to shapes
that are painful to retrofit. Mandate: **steal foundations, don't invent**: 
e.g. grok CLI's session storage is reportedly praised; find out exactly why.

---

## Phase 1: The pain frames (JTBD, not features)

1. **"Nothing I did with the agent is ever lost, and I can prove it."**
   Operators return hours/days later and trust that the full run (including
   tool side effects and decisions) is on disk, greppable, reconstructable.
   How does loss/corruption/`"you lost my session"` actually manifest across
   the cohort?
2. **"I can pick a session back up anywhere and it actually continues."**
   Resume/reattach that doesn't start fresh, doesn't hallucinate lost state,
   works from another device/surface. What storage+replay shapes make this
   real vs. fake?
3. **"I (or my tooling) can command a running agent without its cooperation."**
   Stop, steer, approve, query, as a protocol another process can speak, not
   keystrokes into a TUI. What command-channel shapes has the cohort converged
   on, and where do they break?
4. **"Old sessions stay readable as the tool evolves."**
   Format versioning/migration: the quiet pain that only shows at month 6.

## Phase 2: Priors (calibration targets; ✓=confident, ?=guessing)

**Expected decomposition (7 concerns):**
(a) on-disk format (JSONL vs SQLite vs custom) · (b) event schema + versioning ·
(c) resume semantics (full replay vs snapshot+tail) · (d) multi-session
organization/discovery (list, search, naming) · (e) size management (rotation,
GC, compaction of the log itself) · (f) command-channel shape (JSON-RPC vs REST
vs signals) · (g) concurrent access (second attach, two writers).

**Expected findings:**
- ✓ Append-only JSONL is the de-facto storage winner for transcripts (Claude
  Code `~/.claude/projects/*.jsonl`, Codex rollouts); praised for greppability +
  crash-tolerance; SQLite used by a minority, praised for query, hated when it
  corrupts or locks.
- ? grok CLI stores sessions in a notably clean JSON structure. I don't know
  its actual shape; verifying this IS a goal of the round.
- ✓ Command channels: Codex's JSON-RPC-over-stdio is the praised reference;
  opencode's REST+SSE praised for hackability; MCP has no session-control story.
- ✓ Horror inventory exists already in round 1: Claude Code startup GC deleted
  ~2,300 transcripts (#62041); resume state-machine 400 poisons a session
  permanently (#63147); `--resume` starts fresh (#26123). Expect more of the
  same shape: silent loss, corrupt-on-crash, format drift.
- ? OpenHands has a genuine event-sourcing design (EventStream), if true it's
  the closest prior art to our journal and worth a deep read.
- ? BEAM-local: DETS has real limits (2GB, repair times); expect the honest
  local-first options to be CubDB / plain file append + fsync / SQLite-via-NIF,
  and expect Mnesia to be a documented trap for this shape.

**Differentiation suspicion:** nobody in the cohort has a *journal*: a versioned,
offset-addressable event log serving multiple populations (loop + meta) with
replay-to-any-offset. Everyone has a *transcript* (chat history for one
consumer). If true, our L4 shape is category-empty and the steal targets are
foundations (framing, fsync discipline, file layout, command verbs) not designs.

**Anticipated failure modes:** crash mid-append corrupting the tail; no version
tag → old sessions unreadable after upgrade; monolithic files that can't be
paged; secrets captured in transcripts; absolute paths breaking cross-machine
resume; two processes appending to one log.

**Confidence marks:** JSONL-wins ✓ · grok specifics ? · JSON-RPC convergence ✓ ·
OpenHands event-sourcing ? · BEAM storage picks ? · journal-is-empty ✓ (medium).

## Phase 3: Cohort (6 briefs, Sonnet horde)

| # | Brief | Tier |
|---|---|---|
| 10 | Leaders' session storage on-disk (Claude Code, Codex, Gemini CLI, **grok CLI**) | close |
| 11 | Challengers' storage (opencode, goose, aider, **OpenHands EventStream**, Cline) | close |
| 12 | State frameworks + ES theory (LangGraph checkpointers, Temporal, EventStore/JetStream, CQRS practice) | adjacent/theory |
| 13 | Command channels (Codex app-server JSON-RPC, ACP, opencode REST, LSP cancel, signals) | close/theory |
| 14 | BEAM local-first storage (DETS/Mnesia/CubDB/SQLite-NIF/file-append) | domain |
| 15 | Storage horror stories + file-format theory (SQLite-as-app-file-format, JSONL conventions, asciinema v2) | cautionary/theory |

Briefs saved to `../archive/harness-research/10..15-*.md`. Phase 5-6 synthesis below.

---

# Phase 5: Synthesis

## Calibration: priors vs findings

| Prior | Verdict |
|---|---|
| ✓ JSONL append-only wins | **Confirmed ×4 independent** (Claude Code, Codex, OpenClaw, pi-agent) **+ a natural experiment**: Gemini CLI's full-JSON-rewrite-per-message was 9,000× slower with OOM crashes and migrated to JSONL after a year (PR #23749). BEAM lore agrees from the other side (rabbit_msg_store, ra_log_wal = framed append + truncate-tail). |
| ? grok's session format is praised | **Wrong: inverted.** No praise exists for either grok tool's storage. The real story is a horror: Grok Build silently uploaded whole repos incl. `.env` secrets to a GCS bucket (`grok-code-session-traces`), 27,800× traffic anomaly, fixed only after press (Jul 2026). The steal is a prohibition, not a foundation. |
| ✓ JSON-RPC command convergence | Confirmed; Codex app-server is the deepest vocabulary (`turn/steer` unique, CAS-guarded). MCP formally out: 2026 RC deleted sessions; "the app server is not MCP" (OpenAI). |
| ? OpenHands is real event-sourcing | **Confirmed.** Immutable event log = sole source of LLM working memory; sidecar is HEAD-pointer+config only, never a snapshot (PR #5946: "always load the event stream, regardless of State"). Sub-50ms replay @1,500 events, benchmarked. Closest prior art to our journal, and it works. |
| ? BEAM storage pick | File-append + Ra/Rabbit WAL discipline. **CubDB eliminated** (no checksums, dormant, compaction crashes on our exact pattern, Electric SQL exited). DETS/Mnesia disqualified with quotes. |
| ✓ journal-as-primitive is category-empty | Confirmed and sharpened: **attach** is the emptiest seam (only opencode has multi-client; Codex dual-continuation bug #25676; four third-party tools exist purely to shim attach); **kill-now interrupt exists nowhere** (all cooperative); **SemVer'd transcript schema demanded everywhere, shipped nowhere** (#53516). |

Prior decomposition (a-g) held; three concerns it missed: **(h) retention/GC
policy** (silent deletion is the #1 horror class, not corruption), **(i)
journal integrity = context integrity** (LangGraph CVE-2025-67644/2026-27794:
corrupt checkpoint → LLM context poisoning on replay), **(j) migration
correctness = "old data stays visible", not "app boots"** (every schema-changer
 (opencode ×3, goose, OpenHands) silently orphaned data at least once).

## Pain clusters (severity × irreversibility)

1. **Silent loss**: retention GC (#62041, ~2,300 transcripts, unfixed) +
   migration orphaning (universal). The cohort's worst class.
2. **Corruption cascade**: non-atomic writes (opencode #7607 0-byte session)
   and, worse, *corruption-triggered deletion*: Cline #7101's recovery logic
   bulk-deletes good history when one file is bad.
3. **Resume poisoning / stale tip**: #63147 permanent poisoning; the
   "Dormammu" bug (#43764): resume attached to an 8-day-stale tip, 593K tokens
   burned; root cause = untyped records defaulting to valid-tip.
4. **Secrets at rest / in flight**: Lovable BOLA (any account read any
   transcript); grok GCS exfiltration.
5. **Size pathology**: LangGraph 85% checkpoint bloat; Claude Code #24207
   disk-full cascade zeroing settings *and auth tokens*.
6. **Control verbs missing**: no attach (4 shims), no kill-now anywhere,
   steer only in Codex.
7. **Schema evolution debt**: versioning demanded, never shipped; Temporal's
   patch-API pain as the anti-pattern; upcast-on-read as the settled cure.

## Surprises (the honesty section)

- grok praise inverted into the cohort's worst secrets horror.
- The #1 storage pain is **deliberate deletion by the vendor's own code**
  (GC/retention/recovery), not crash corruption. Discipline follows: *parse
  failure must never trigger deletion*.
- Durability granularity below turn matters (LangGraph loses mid-tool-call
  work: checkpoint-between-nodes is the gap our item-level events already
  close).
- Our own `recording/asciicast.ex` fails the disciplines this round produced:
  correct v2 wire format but whole-session buffered write (no crash safety)
  and a `Jason.decode!` reader with zero torn-tail tolerance. Do not reuse;
  fix separately.

# Phase 6: Dispositions

## Architectural decisions
- **AD-9 (U2) Journal = framed JSONL, append-only, one segment-set per
  session.** Ra torn-tail recovery (truncate bad *last* record; interior
  corruption = hard alarm). Batched `:file.datasync` with ≤200ms ceiling;
  immediate sync on side-effect events; never `delayed_write`. Size-capped
  ascending segments; any index derived + disposable. *(Resolves D1: files,
  not SQLite, not DETS/CubDB.)*
- **AD-10 (U9) Replay-as-truth + pointer sidecar** (OpenHands): sidecar holds
  HEAD pointer + config only, never model state. Checkpoints are **in-log
  pointer records** (independently reinvented by all four leaders: settled
  shape).
- **AD-11 (U2) Schema: SemVer'd independently of app version + upcast-on-read**
  (pure vN→vN+1 transforms at deserialize; log never rewritten) + a fallback
  reader across format migrations (Gemini precedent). Migration acceptance
  test = *old data visible*, not *app boots*.
- **AD-12 (U5) Interrupt = staged escalation, visible in-protocol:**
  cooperative signal → bounded wait → supervised kill, each stage an event.
  OTP gives us the kill nobody else has; the staging is the cohort's
  convergent UX.
- **AD-13 (U6) Steer carries `expected_turn_id`** (CAS; reject if the turn
  changed) + honest non-steerable turn kinds. *(Codex steal.)*
- **AD-14 (U8) Approval decisions:** `Denied` ≠ `Abort`; `TimedOut`
  first-class; a decision may carry a policy amendment (approval that also
  edits the rule). *(Codex ReviewDecision steal; partially resolves D3.)*
- **AD-15 (U4) Attach:** `attach{from_offset, historyPolicy}` + broadcast
  permission bus so any attached surface can answer approvals. *(ACP draft
  #533 + opencode fusion.)*

## Foundation invariants
- **FI-7 Never delete silently.** No GC/retention/recovery path may delete
  without explicit, logged, user-visible consent. Parse failure never
  triggers deletion.
- **FI-8 Atomic temp+fsync+rename** for every non-append file (sidecars,
  checkpoints, config).
- **FI-9 Validate-on-replay: journal integrity IS context integrity.**
  Malformed/failed-validation records are rejected, never injected into
  model context (the LangGraph poisoning class).
- **FI-10 No session-content telemetry/upload channel, ever** + secret
  redaction at the journal write boundary (grok + Lovable class).
- **FI-11 Disk-full/size behavior defined:** writes fail loudly; failure
  never cascades to unrelated files; segments capped.
- **FI-12 The Dormammu test:** resume tip-finding covered by a regression
  test where non-conversational tail records must not be selectable as tip.

## Non-commitments
- **NC-6 No SQLite as primary store** (every cohort adopter burned:
  WAL/NFS locks, migration startup panics; goose #8638 recurred post-fix).
  Optional *derived index* only, behind a behaviour.
- **NC-7 No DETS / Mnesia / CubDB.**
- **NC-8 MCP is not a control channel** (reaffirms AD-8 with vendor quotes).

## Meta-review: what this round did not cover
- Multi-machine/sync (session portability across hosts), deliberately out;
  revisit with the mobile surface.
- Encryption-at-rest for journals: adjacent to FI-10, unresearched; flag for
  a security pass before any cloud-sync feature.
- goose's `db backup/restore` + pre-migration auto-snapshot is the best
  defensive artifact found: steal shape when U2 gains migrations.

