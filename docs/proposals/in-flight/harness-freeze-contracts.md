# Harness Freeze Contracts — three surfaces, frozen for parallel red suites

Date: 2026-07-16 · Status: **freeze proposal** — once ratified, red suites are
authored against these shapes in parallel, before any implementation exists.
Sources: `harness-roadmap.md` (v3 chart, U4∥U9 false-parallel warning §1),
`harness-invariants.md` (I1–I10 + meta-invariants), `harness-spec-protocol.md`
(§3 event envelope, §3-meta table), `harness-storage-research.md` (AD-9..15,
FI-7..12), landed code: `Raxol.Agent.Contract.Event`, `Raxol.Agent.EmitBridge`,
`Raxol.Agent.Journal{,.FileStore,.FileStore.Writer,.FileStore.Reader}`.

This doc freezes **on top of what landed** — it renames nothing that exists in
`contract.ex` / `emit_bridge.ex` / the journal modules, and it changes zero
bytes of the Reader's framing logic.

**Fold-before-reds revision (2026-07-16, ratified).** This is the final pre-red
revision; permanent red suites are authored against these shapes next. It folds
in the ratified reservations from `harness-yolo-safe-research.md`,
`harness-storage-foundations.md`, `harness-future-foundations-ideation.md`, and
`harness-community-gaps.md` — every addition is additive under the §0 only-grows
law. Governing principle of the revision (the event-sourcing spine): **every
offset states the complete fact of what happened there; folds derive, never
reconstruct.** Doc-hygiene note: `harness-spec-backend.md` §4's "foldable Ecto
event table (or DETS)" + "Oban = probe scheduler" is **superseded** — D1 ruled
files (NC-6/NC-7), D2 ruled an in-BEAM supervised pool (roadmap §3.2); read this
doc, not that section, for storage/runner shape.

---

## 0. The governing rule (applies to every schema below)

**The contract only grows.** No field, record kind, event type, enum value, or
callback frozen here is ever renamed, repurposed, type-narrowed, or flipped
optional→required. A separate UI fork consumes these contracts and must NEVER
need a lockstep update. Concretely:

1. **Additive-only evolution.** New fields are optional-with-default. New
   kinds/types/statuses extend a registry; existing entries are immutable.
   (This is I9 stated as a design rule, not just a test.)
2. **Two seams, two strictnesses** — this is how "loud validation" (protocol
   §6) coexists with "readers tolerate unknown":
   - **Producer/ingest seam (strict):** a producer inside this codebase may
     only emit kinds/types present in its compiled registry; a command asking
     the core to *act* on an unknown type is a loud typed reject. Never emit
     what you don't know.
   - **Reader/subscriber seam (tolerant):** journal replay, folds, and any
     surface (including the UI fork at version skew) MUST tolerate unknown
     kinds, types, statuses, and extra fields: preserve them in raw views,
     skip them in typed folds, never error, never mark damaged. Tolerate
     everything you don't know.
3. **Versioning:** `schema_version` (journal, SemVer, AD-11 upcast-on-read)
   and `Event.v` (envelope) are the only version switches. A minor bump =
   additive growth; readers built against `1.x` read all later `1.y`.
4. **Golden fixtures:** every freeze below adds checked-in golden fixtures to
   the I9 corpus the day its red suite lands — the freeze is enforced by CI,
   not by this document.
5. **Self-containment (portability) law.** The session directory is the unit of
   portability. Every reference a record carries resolves inside its own session
   directory — journal offsets, relative CAS paths (`snapshots/<sha>`,
   `blobs/<sha>`) — never an absolute path, never another session's interior.
   The sole cross-session pointers are session-lineage edges (§1.1-lineage), and
   they are resolvable-or-absent: a reader with a missing parent still reads THIS
   journal healthy (lineage is provenance, not replay input). No absolute paths
   anywhere in golden fixtures (a lint-grade fixture scan enforces it).
6. **One legal rewrite of history.** Append-only admits exactly one in-place
   mutation class: replacing a payload *value* with the `$redacted` marker
   (§1.1-redaction) for secret/PII scrubbing. Everything else stays strictly
   append-only. Record framing, `id`, `kind`, and envelope fields are never
   rewritten; a `$redacted` value never disturbs the framing, offsets, or hashes
   of any other record.

---

## 1. JS-FREEZE — journal record-kind schema

**Governs:** U4 (reattach/replay, AD-15/FI-12), U9 (checkpoint, AD-10/AD-3a),
U10 (compaction=resume, AD-3b). Kills the U4∥U9 false parallel: both units
consume this one schema; neither invents record kinds or tip semantics.

### 1.1 Frozen shape

#### Framing (unchanged from landed AD-9)

One record = one complete, newline-terminated JSON object per line, in
size-capped ascending `NNNNNN.jsonl` segments. The Writer stamps `"id"` and
`"schema_version"` exactly as today. **One new stamped field:** `"kind"`,
defaulted by the Writer via `Map.put_new("kind", "event")`.

```
record := {
  "id":             integer,     # the journal offset — dense, 1-based
  "schema_version": string,      # SemVer (AD-11)
  "kind":           string,      # "event" | "checkpoint" | future kinds
  "branch_id":      string,      # optional, default "main" (§1.1-branch)
  ... kind-specific fields ...
}
```

#### `branch_id` (new stamped field, optional, default `"main"`)

The Writer defaults it via `Map.put_new("branch_id", "main")`, exactly as it
defaults `"kind"`. It carves logical branches over the one linear journal without
a second id space: every record still consumes one offset from the single Writer
counter (the offset law below is untouched), and every existing/grandfathered
record reads as `branch_id: "main"`. Speculation/tournament branches (yolo-safe
§3) and durable rewind live here; v1 MAY still implement branching as
copy-on-fork separate sessions (yolo-safe §8 C1 Option A) — the field is reserved
so the tip predicate is branch-aware from day one and no red is rewritten later.

#### The offset law (the anti-dual-id decision)

**Every record — regardless of kind — consumes exactly one offset from the
single Writer counter.** There is one id space, period.

*Justification:* dense `prev + 1` continuity is the Reader's corruption
detector (I6 missing-middle detection depends on it) and requires zero Reader
changes. A second numbering track for pointer records is the dual-id landmine
reincarnated — two ids for one position was the exact class U1.5 killed.
Consequence accepted and frozen: **live durable *event* ids are a strictly
increasing subsequence of `1..n`, no longer necessarily dense.** I1 is
restated at the record layer (see positive contour); the record layer keeps
`1..n` dense exactly as today.

Ephemeral events (never journaled) keep their landed semantics: id = last
durable **record** offset, sentinel `0` pre-durable. A checkpoint append
advances that watermark; it still names a real journal position.

#### The GC low-watermark (density restated for legal prefix truncation)

The journal header/HEAD grows one key: `low_watermark` (default `1`, forever
until GC ships). The density law is restated parameterized: record ids are dense
across `[low_watermark, n]`. A missing prefix **below** the watermark is legal
GC, not corruption — a future `gc` record (kind already reserved) appended at the
tail names the truncated range + the covering checkpoint, and HEAD may mirror
`low_watermark` (allowlist grows one key, additive under I8). I5/I6 damage
semantics (missing-middle ⇒ damaged) apply only **at or above** the watermark:
leading segments missing *iff* a surviving `gc` record or HEAD watermark attests
them ⇒ healthy, missing without attestation ⇒ damaged exactly as today.
`fold(0..x)` reads as `fold(low_watermark..x) ⊕ covering checkpoint` — P-JS4's
restore formula already. No behavior change while `low_watermark = 1`.

#### The complete kind set (v1 — minimal, each justified)

| kind | who appends | payload | why it exists |
|---|---|---|---|
| `event` | EmitBridge (durable tier) | the contract Event fields as landed (`v, session_id, turn_id, ts, family, type, tier, payload`) | the existing corpus; `"kind"` absent ⇒ `"event"` (grandfather clause — every landed journal stays valid, byte-for-byte) |
| `checkpoint` | checkpoint writer (U9/U10), via the same single Writer | §1.1-checkpoint below | AD-10: checkpoints are **in-log pointer records** — all four cohort leaders independently converged here; HEAD sidecar stays offset+config only, never model state |
| `annotation` | any writer (reopen the single Writer) | `%{target_offset \| target_range, label, body_ref, author, consent_class}`; `consent_class ∈ private \| shareable \| train` (grow-only) | human/agent notes on history (F14, community-gaps VB#13); **tip-excluded by the closure rule**; sharing/export honors `consent_class` |
| `schedule` | scheduler writer (durable trigger store) | `%{trigger_id, when: cron\|event\|once, next_fire, payload_ref, armed}` | wake / self-initiated autonomy (F9, community-gaps class 13); the journal is the authoritative trigger store — external cron tables are projections; **tip-excluded**; the session lifecycle enum grows `:dormant` (a session parked between wakes) |

**Deliberately NOT kinds:**

- **`compaction` marker — rejected as a separate kind.** AD-3b's whole thesis
  is compaction=resume=*one artifact*. A compaction is a `checkpoint` record
  with `"reason": "compaction"`. Two kinds would fork the artifact U10 exists
  to unify.
- **`attach`/`reattach` marker — rejected as a kind (and as a requirement).**
  Reattach (U4) is a *read-side* operation and MUST work against a writerless
  session (dead BEAM, replay-only, `tar`'d directory). A record kind would
  couple reads to the single-writer append path. If attach auditing is wanted,
  it is a `kind: "event"`, `family: "meta"` event (type `:attach`, U11
  registry) written **best-effort only when a live Writer exists**; no reader,
  fold, or tip rule may ever depend on its presence.
- **`gc`/`truncation` marker — reserved, not frozen.** FI-7 explicit-consent
  GC will need one; the kind registry is forward-only, so it can be added
  later without touching this freeze.

#### `checkpoint` record — frozen fields

```elixir
# JSON on disk (string keys); Elixir-side struct sketch:
defmodule Raxol.Agent.Journal.Records.Checkpoint do
  @type t :: %{
    id:              non_neg_integer(),   # stamped by Writer, = offset
    schema_version:  String.t(),
    kind:            String.t(),          # "checkpoint"
    session_id:      String.t(),
    ts:              integer(),           # microseconds
    tip_offset:      pos_integer(),       # the conversational tip AT WRITE TIME (§1.1-tip)
    snapshot_ref:    String.t() | nil,    # "snapshots/<sha256-hex>.json" — nil = tip-only pointer
    snapshot_hash:   String.t() | nil,    # lowercase hex sha256 of the snapshot file bytes
    reason:          String.t()           # "manual" | "compaction" | "auto" (grow-only enum)
  }
end
```

- **Snapshot payload is content-addressed and out-of-line:** written to
  `<session>/snapshots/<sha256>.json` (dir already exists in the landed
  layout) via FI-8 atomic temp+fsync+rename, **before** the checkpoint record
  is appended. Rationale: the record can't be named by its own offset before
  append (chicken-egg); content addressing gives integrity-check + dedupe for
  free; a crash between file-write and record-append leaves a harmless orphan
  file (FI-7: never deleted implicitly).
- Snapshot **content** is the MS-defined JSON-safe `@persist` slice — MS owns
  what's in it; JS-FREEZE owns only the pointer discipline.
- **Turn-boundary rule:** a checkpoint record MUST NOT be appended between a
  `turn_started` and its closing `turn_completed`/`turn_canceled`/`error`,
  and never between a spend-gate reserve and its terminal (Tier-2 U9
  invariant, restated as a write rule).

#### The conversational tip (frozen definition)

**The tip is a derived position, never a stored field.** Nobody writes "the
tip"; storing it would be a second source of truth — the HEAD-lag bug class.

```
conversational?(record) :=
  record.kind == "event"
  ∧ record.family == "loop"
  ∧ record.type ∈ CONVERSATIONAL

CONVERSATIONAL := { turn_started, item_started, item_completed,
                    turn_completed, turn_canceled, error,
                    approval_requested }          # grow-only set

tip(journal, branch := "main") :=
    the record with the highest offset satisfying
    (record.branch_id == branch ∧ conversational?(record))
    (undefined on an empty/no-conversational branch → :no_tip)

# tip(journal) is shorthand for tip(journal, "main"). Every pre-branch_id
# journal reads as branch "main", so this is grandfather-safe and the 0-arity
# form stays valid — the branch filter is applied BEFORE the existing predicate,
# which is otherwise unchanged.
```

**The closure rule (frozen).** CONVERSATIONAL is a whitelist and the whitelist
is the ONLY door: every new record kind and every new event type introduced in
the future is tip-excluded **unless explicitly added to CONVERSATIONAL**. Adding
a member is a `schema_version` minor bump; nothing becomes a tip by default. This
protects every future kind (`annotation`, `schedule`, the reserved `gc`) and
every future `family:loop` type from silently moving historical tips.

Excluded by decision: `state_change`, `idle`, every `family: "meta"` event,
every non-`event` kind. Also excluded by decision though it is `family: "loop"`:
`woken` (§1.1-schedule) — a cron/trigger fire is not where a resumed conversation
lands, so it is deliberately kept out of CONVERSATIONAL (the closure rule keeps
it out by default; this records the exclusion is intentional, not an oversight).
That exclusion **is** the Dormammu test (FI-12): a trailing checkpoint, meta
event, idle marker, or `woken` must never be selected as tip.
`approval_requested` is included — a pending approval is exactly where a
resumed conversation must land. **Ratified (was implicit, F3):**
`approval_requested` is emitted `family:loop` (a turn-bracket signal), never
`family:meta`, so it passes the tip predicate — this is a frozen decision,
not an accident of which module happens to emit it (`BlastRadiusGate`/U8
must emit it as `family:loop`).

`item_started`'s membership above is ratified, not tentative (OQ-JS3 — see
§1.5): it stays in CONVERSATIONAL from day one. EmitBridge must wire its
emit mapping for `item_started` before U4-R/U9-R reds are authored.

- **U4 locates the tip** by backward scan under this predicate (over the
  tolerant Reader output — unknown kinds/types encountered on the way are
  skipped, not fatal).
- **U9 references the tip** via `tip_offset`, frozen at write time and
  validated at write time: the record at `tip_offset` MUST satisfy
  `conversational?` or the append is rejected (see negative contour). With
  `branch_id`, `tip_offset` MUST name a conversational record on the
  checkpoint's own `branch_id` (same-branch tip).

#### Reader tolerance (frozen behavior)

- Unknown `kind` ⇒ the record **participates in offset continuity** (it has a
  stamped dense id), is **excluded from event folds and the tip scan**, and is
  **preserved** in raw reads. Never `{:damaged}`, never dropped, never crashes.
- Missing `kind` ⇒ `"event"` (grandfather clause).
- `Journal.read/2` grows one additive option: `:kinds` (list of kind strings;
  default: all kinds). `:from_offset` unchanged.
- **`last_offset` semantics (F6, ratify-before-impl):** `Reader.last_offset`
  names the last **record** of any kind (event or checkpoint), not the last
  event — unchanged code, but a semantic shift once checkpoints exist.
  `EmitBridge`'s ephemeral-id use is correct as-is (offset law, above). A
  future consumer that needs "last event specifically" gets
  `last_event_offset` (filters `kind == "event"`) as an additive read
  option; until then, treat `last_offset` explicitly as
  last-record-of-any-kind, not last-event, so it isn't misread as a
  trailing checkpoint's offset.
- Torn-tail / interior-corruption / id-gap policies: **unchanged, verbatim**,
  at the record layer (I5/I6 as landed).
- **`$blob` value marker (externalized payloads):** a payload value MAY be
  `{"$blob": "blobs/<sha256-hex>"}` (optionally with `"bytes"`/`"media"` keys).
  Bulk bytes live at `<session>/blobs/<sha256>` — content-addressed, FI-8 atomic
  write, **written before** the referencing record (same discipline as checkpoint
  snapshots). Records stay small facts + pointers. Readers built against v1 MUST
  deref-or-render-opaque a `$blob` value (a reader-seam tolerance rule); a
  missing/altered blob file degrades under N-JS3 semantics (deref-fail ⇒
  tombstone, journal stays `:ok`, nothing deleted implicitly per FI-7). The
  Writer externalizes payloads over a per-record byte ceiling (the threshold is
  policy; the ceiling's *existence* is the law); redaction runs before hashing.
- **`$redacted` value marker (the one legal rewrite):** a payload value MAY be
  replaced in-place with `{"$redacted": %{reason, at_ts}}` — the sole legal
  rewrite of history (§0 clause 6), for secret/PII scrubbing. It never disturbs
  the framing, offsets, or hashes of other records; readers render it as an
  opaque tombstone, folds treat it as an ordinary value. **Snapshot files
  referenced by hash:** redaction of a snapshot produces a NEW snapshot file;
  checkpoint records are **not** rewritten — the referencing checkpoint's hash
  then names the pre-redaction file, which may be deleted under FI-7 consent, so
  the pointer may dangle and restore surfaces `:snapshot_missing` (N-JS3). That
  dangling pointer is the accepted cost.

#### FI-10 at the new kind

- The `checkpoint` **record** carries no model content — pointer + hash only.
  The redaction surface is the snapshot file: its content passes the same
  write-boundary discipline as event payloads (`Contract.sanitize_payload`-
  class sanitization + MS secret exclusion) before hashing/writing.
- Telemetry about checkpoints (`[:raxol, :agent, :journal, :checkpoint]` etc.)
  may carry offsets, hashes, counts, reasons — **never** snapshot content.
  No new record kind may introduce a content-telemetry channel.
- **On-disk permissions (impl note, not contract):** session dirs are created
  `0700`, all files `0600` (Codex #21660 world-readable-rollout class). Asserted
  by a fixture-level I-suite property; this is a write-discipline implementation
  note, not a schema field.

#### Session lineage (meta.json — session-level, NOT per-record)

Sessions form a DAG at the lineage level; each journal stays strictly linear
forever. Lineage lives in session metadata (`meta.json`), never on a record:

```
parents: [ %{session_id, offset, relation} ]     # list, possibly empty
relation ∈ :fork | :spawn | :merge | :import      # grow-only enum
```

A **list of typed edges** — never a scalar `forked_from` (scalar→list would be a
forbidden repurpose the day fork fixtures land; every relation would otherwise
need its own parallel field, the dual-id landmine's genealogy-shaped cousin).

- **Per-relation offset semantics (frozen):**
  - `:fork` — the parent offset the child's history is copied/derived up to
    (counterfactual/retry/benchmark replay is `:fork`; there is **no `:replay`
    relation, ever**).
  - `:spawn` — the parent offset at which the sub-agent was spawned.
  - `:merge` — the parent branch tip incorporated.
  - `:import` — the source-session offset boundary at export time; the edge's
    `session_id` = the source id **at export**, not a reused id on the new host.
- `:resume`/reattach is **NEVER a relation** — it is a read-side operation on the
  same session, not an origin. (Frozen sentence.)
- A dangling/absent parent leaves THIS journal healthy — lineage is provenance,
  not replay input (self-containment law, §0 clause 5).
- Acyclicity is a **producer obligation**; readers tolerate (a naive reader never
  marks a session damaged for a cyclic or missing edge).
- Lineage edges are **authoritative for provenance**. Any `spawn`/`attach` meta
  events (§2.1) are observability-only — nothing may depend on them for
  provenance rollup.
- Each edge MAY carry an optional grow-only `detail` map (e.g. `role: :subagent`)
  instead of bloating the `relation` enum with spawn subtypes.

**NC-12 (frozen negative constraint): no multi-writer / CRDT journal, ever.**
Dense offsets + single-writer + corruption detection are one invariant bundle;
convergent multi-master editing of one journal would break all three at once.
Cross-device / concurrent divergence converges by **lineage merge** (`:fork`
then `:merge`, with a human or oracle at the merge) — Git's answer, never
concurrent-editing convergence. Swarm stays "more sessions, not more writers per
log."

### 1.2 Positive contour (what green guarantees)

Governing dispositions: AD-9, AD-10, AD-11, AD-15, AD-3a/3b, FI-7/8/9/10/12.

- **P-JS1 (I1 restated at the record layer):** under the full I1 fault
  schedule, journal **record** ids are dense `1..n`; live durable **event**
  ids are exactly the ids of `kind: "event"` records, in order, as a strictly
  increasing subsequence. `HEAD.offset ≤ n` always.
- **P-JS2 tip determinism — relabeled PROPERTY (F9), not a must-fail red:**
  for any journal, two independent implementations of the tip predicate
  (raw-file decoder vs Reader path — oracle independence, meta-inv 6) select
  the same offset or both return `:no_tip`. Determinism is naturally an
  oracle-agreement property, not a single-mutation red — there is no dead
  injector beyond N-JS1/N-JS5's predicate mutations, so this runs as a
  property decided by dual-oracle agreement.
- **P-JS3 tip validity (Dormammu, FI-12):** append `[…loop events…,
  checkpoint, meta event, idle]` → tip = the last CONVERSATIONAL loop event,
  never the checkpoint/meta/idle tail. Required generator pattern: every
  tip-test journal MUST end in ≥1 non-conversational record (meta-inv 5 —
  otherwise the property is vacuous).
- **P-JS4 checkpoint round-trip:** `snapshot file exists ∧ sha256(bytes) ==
  snapshot_hash` for every checkpoint record in a healthy journal; restore =
  `fold(0..tip_offset) ⊕ snapshot == fold(0..now-at-write)` on the persistent
  slice (Tier-2 U9 invariant, unchanged).
- **P-JS5 replay closure (U4, grok top-2):** ∀ offset o:
  `read(0..o−1) ++ attach_live(o..) ==` full durable **record** stream, as
  sequence; a late subscriber never receives an earlier durable delivered as
  live.
- **P-JS6 tolerance:** a journal containing a future-kind record replays
  `{:ok, _}`; folds and tip agree with the same journal minus that record.
- **P-JS7 grandfather — relabeled CORPUS TEST (F9), not a must-fail red:**
  every pre-freeze golden journal (no `"kind"` field) replays identically
  before and after this freeze — same folds, same tip. "Old journals still
  decode" has no natural must-fail mutation; this runs as a pure-decode
  corpus check against the I9 golden fixtures, not a red.
- **P-JS8 branch tip determinism — relabeled PROPERTY (fold), not a must-fail
  red:** for any journal and any branch `b`, `tip(journal, b)` selects the
  highest conversational offset whose `branch_id == b`, or `:no_tip`;
  `tip(journal)` == `tip(journal, "main")`. Dual-oracle agreement (raw-file
  decoder vs Reader path), same class as P-JS2. **Closure-rule corollary:** a
  record of any kind or type not in CONVERSATIONAL is never selected, on any
  branch.
- **P-JS9 lineage is provenance, not replay input:** a journal whose `meta.json`
  names an absent/dangling parent still replays `{:ok, _}` and folds identically
  to the same journal with the edge removed; a cyclic edge set never marks the
  session damaged (readers tolerate; acyclicity is a producer obligation).
  Generator MUST include a missing-parent and a cyclic-edge case (vacuous
  otherwise).
- **P-JS10 blob round-trip — relabeled PROPERTY (F9):** for every `$blob` value
  in a healthy journal, the referenced `blobs/<sha256>` file exists and
  `sha256(bytes)` matches the pointer; deref-then-fold equals the same fold with
  the bytes inlined. A missing blob leaves the journal `:ok` (tombstone), never
  `{:damaged}`.
- **P-JS11 low-watermark density:** under the full I1 fault schedule, record ids
  are dense across `[low_watermark, n]`; with `low_watermark = 1` this is exactly
  P-JS1. A prefix missing below an attesting `gc`/HEAD watermark reads healthy;
  missing without attestation reads damaged.
- **P-JS12 redaction preserves framing:** replacing a payload value with
  `$redacted` leaves every other record's framing, `id`, `kind`, and hash
  byte-identical; the journal folds `{:ok, _}` before and after. Generator MUST
  place a redacted record between two hash/offset-checked records (vacuous
  otherwise).
- **P-JS13 self-containment — relabeled CORPUS/lint TEST (F9):** no golden
  fixture record carries an absolute path or a cross-session interior pointer;
  the only cross-session references are `meta.json` lineage edges. Runs as a
  fixture scan, not a must-fail red.

### 1.3 Negative contour (what MUST fail, and how)

| # | violation | exact required failure | dead injector (negative control) |
|---|---|---|---|
| N-JS1 | append a checkpoint whose `tip_offset` fails `conversational?` (points at a meta event, another checkpoint, or a hole) | `{:error, :invalid_tip}` from the checkpoint constructor/append seam; **no record appended, offset counter untouched** | constructor that accepts any positive integer as tip → P-JS3 and this red must go green-on-broken → suite fails |
| N-JS2 | append a checkpoint mid-turn (between `turn_started` and its close) or mid-reserve | `{:error, :mid_turn}` (resp. `{:error, :mid_reserve}`); nothing appended | writer that skips the turn-boundary check |
| N-JS3 | checkpoint record whose snapshot file is missing or hash-mismatched, at **restore** time | restore returns `{:error, :snapshot_missing}` / `{:error, :snapshot_corrupt}`; the **journal stays `:ok`** (checkpoint-level damage ≠ journal damage); nothing deleted (FI-7) | restorer that silently falls back to full replay without surfacing the error |
| N-JS4 | reader treats an unknown `kind` as corruption | tolerance red asserts `{:ok, _}`; a reader returning `{:damaged, _}` on unknown kind is the injected breakage | patched Reader that damages-on-unknown-kind |
| N-JS5 | tip scan selects a non-conversational record | Dormammu red (FI-12) fails; injector: tip predicate patched to `kind == "event"` only (drops the family/type clauses) | that patched predicate |
| N-JS6 | two id spaces reintroduced (a pointer record stamped from a side counter) | P-JS1 density check fails on the record layer | Writer variant stamping checkpoints from a second counter |
| N-JS7 | live/ephemeral id surfaces before its durable record is readable (emit-ahead-of-journal, I13) | P-JS5 replay-closure red fails: a late subscriber's `attach_live` stream includes an id not yet present in `read(0..o-1)` | EmitBridge variant that publishes the live id before the Writer append/ack returns |
| N-JS8 | tip scan ignores `branch_id` (selects a record from another branch), or a closure-rule tip predicate patched to accept a non-whitelisted kind/type | P-JS8 fails: `tip(journal, b)` returns an offset with `branch_id ≠ b`, or selects a non-CONVERSATIONAL record | predicate variant dropping the `branch_id == b` clause, or one admitting any `family:loop` type regardless of CONVERSATIONAL membership |
| N-JS9 | reader marks a session damaged for a missing/dangling or cyclic lineage parent | P-JS9 fails; tolerance red asserts `{:ok, _}` and identical fold | reader that resolves lineage as replay input and damages-on-missing-parent |
| N-JS10 | `$blob` deref failure treated as journal corruption, or blob written AFTER the referencing record | P-JS10 fails: reader returns `{:damaged, _}` on a missing blob (must be tombstone + `:ok`), or a crash between record-append and blob-write leaves a referenced-but-absent blob | reader that damages-on-missing-blob; Writer that appends the record before the blob file |
| N-JS11 | a GC'd leading prefix (missing below `low_watermark`) reported as damaged, or a real missing-middle at/above the watermark reported healthy | P-JS11 fails on either side | reader with the density check hardcoded to `1..n` (ignores `low_watermark`), or one treating any missing segment as attested |
| N-JS12 | a "redaction" that rewrites framing/`id`/`kind`/hash, or scrubs a value by any means other than the `$redacted` marker | P-JS12 fails: a neighboring record's hash/offset changes, or the scrub reads as interior corruption (I5/I6) | redactor that re-serializes the record (OpenHands PR #9793 timestamp-corruption class), or one that substring-scrubs across framing |
| N-JS13 | a second concurrent writer / CRDT merge admitted into one journal (NC-12 violation) | P-JS1/P-JS11 density fails: two writers collide on offsets, or a merge produces a non-dense id set | Writer variant accepting appends from a second live writer, or a "converge" path that offset-unions two divergent logs |

Every fault site above carries a fired-counter (meta-inv 1); schedules are
seed-reproducible (meta-inv 2). **N-JS6 is the load-bearing single-Writer
lockstep test (F7, ratify-before-impl):** the one-offset-law (§1.1) holds
only if every kind routes through the single `Writer.append` counter — the
Writer trusts the producer's `kind` and cannot enforce single-counter
routing at compile time, so N-JS6 is the sole guard against a silent
second-counter bypass. Its fired-counter must be wired as a visible
meta-invariant, not just a pass/fail assertion, so a regression that
reintroduces a side counter fails CI loudly, not silently.

### 1.4 Forward-compat note

- Grows by: new `kind` strings (e.g. `"gc"`; `annotation`/`schedule` land in
  this revision), new fields on any record (optional, defaulted), new
  CONVERSATIONAL members, new `reason` values, new `branch_id` values (branches
  over the linear journal), `$blob`/`$redacted` payload markers, `low_watermark`
  prefix truncation, session-lineage `relation` values and edge `detail` keys.
- Never: renaming `"kind"`/`"id"`/`"tip_offset"`/`"snapshot_ref"`/`"branch_id"`,
  reusing a kind string for different semantics, making a today-optional field
  required, removing a CONVERSATIONAL member (removal would silently move
  historical tips), adding a record kind or event type to the tip **without** a
  CONVERSATIONAL whitelist entry (the closure rule — the whitelist is the only
  door), a multi-writer/CRDT journal (NC-12), a scalar lineage field (must stay a
  list of typed edges), an absolute path or cross-session interior pointer in any
  record (self-containment law).
- A UI-fork reader ignores safely: any unknown kind (skip in folds, keep in
  raw), any unknown field on known kinds, any unknown `reason`, an unknown
  `branch_id` (skip in a main-only fold, keep in raw), `$blob` (deref-or-opaque),
  `$redacted` (opaque tombstone), a missing lineage parent (still healthy). It
  must never ignore: `id` continuity, the tip predicate as frozen (additions to
  CONVERSATIONAL ship as schema_version minor bumps it can read forward).

### 1.5 Ruled (was: open questions — now decided, binding)

- **OQ-JS1 — RULED: LEGAL.** `checkpoint` with `snapshot_ref: nil` (tip-only
  pointer) is legal in v1. Reason: `snapshot_ref` is optional-with-default
  and the governing rule forbids optional→required, so tip-only is
  *permanently* legal regardless of when U9/U10 start using full snapshots;
  the restore-from-tip-only red validates the `(0..tip_offset)` full-fold
  path rather than a nil-reject.
- **OQ-JS2 — RULED: DEFER.** GC is deferred entirely; the `gc` kind stays
  reserved (§1.1) and is added later with zero freeze change. Reason:
  retention policy (N checkpoints, explicit consent per FI-7) is a product
  decision, not derivable from invariants — baking it in now risks locking a
  wrong retention semantics under the "only grows" rule.
- **OQ-JS3 — RULED: INCLUDE day one.** `item_started` stays in CONVERSATIONAL
  from day one (already reflected in §1.1). Reason: it's in protocol §3 and
  the set is grow-only; omitting it now and adding it later would silently
  move historical tips (§1.4), and it's exactly the U4/U9 divergence vector
  the false-parallel analysis flags. EmitBridge must wire its emit mapping
  for `item_started` before U4-R/U9-R reds are authored.

---

## 2. U11-CONTRACT — meta event family + provenance/taint (FI-5)

**Governs:** U11; consumed by U12–U18, U20, S3.

### 2.1 Frozen shape

#### Envelope growth (additive on the landed `Contract.Event`)

```elixir
defstruct v: 0,
          id: 0,
          session_id: nil,
          turn_id: nil,
          ts: 0,
          family: :loop,
          type: nil,
          tier: :durable,
          payload: %{},
          # --- U11 growth (all defaulted; v0 events decode unchanged) ---
          scope: :session,                                    # :session | :global
          provenance: %{source: :primary, trust: :trusted},   # FI-5
          # --- fold-before-reds growth (all defaulted) ---
          actor: nil                                          # %{kind, id} | nil (kind:"event" only)

@type provenance :: %{
        required(:source) => atom(),   # registry §2.1-sources
        required(:trust)  => :trusted | :tainted
        # grow-only: later keys (e.g. :model_family) are additive
      }
```

Defaults are load-bearing: every landed v0 event and every journal record
without these keys decodes as `scope: :session`,
`provenance: %{source: :primary, trust: :trusted}` — the grandfather clause.
I9 rule honored: new fields optional-with-default, never required.

#### `actor` — who emitted the event (envelope growth, producer-seam stamped)

`actor: %{kind: :human | :agent | :system, id: String.t()} | nil`, optional,
default `nil`, on `kind: "event"` records **only**. Checkpoint and `schedule`
records carry **no** actor — no actor fact exists for a pointer record, so the
field is absent by design, not defaulted to a guess.

- **Stamped at the producer seam:** EmitBridge stamps `actor` from the
  command/attach context for every event in a write generation. Individual
  modules never invent it — this is what keeps a nullable-everywhere field from
  becoming inconsistent garbage.
- **Frozen fold rule:** absent `actor` = system emission (`%{kind: :system}`) **by
  documented rule, not reader guess**. Readers never infer a human/agent from
  absence.
- **Identity namespace:** `id` is an opaque string. A grow-only `detail`-style
  qualification can come later; cross-session actor identity is a
  **consuming-store concern** (same boundary as `refs` — the journal never
  resolves it).
- `approval_decided` additionally names `actor` in its payload (its G4 shape);
  when both are present they agree by producer-seam stamping — the envelope actor
  is the uniform mechanism, the payload actor is the decision-scoped copy.

#### `cost_ref` — spend correlation (spend-bearing records only)

Optional `cost_ref` appears **only** on spend-bearing records — `item_completed`,
the `probe_run` terminal (§3), and the `turn_completed` rollup — pointing into
the Ledger's reserve/settle identity. **Negative decision (frozen): no `bill_to`
per record.** The Ledger is the single money truth; billing is a **derived fold**
over Ledger + lineage subtrees (walk the R1 edges), never a per-record
attribution field that could drift from or double-count the Ledger.

#### Model/params fingerprint (frozen struct)

```
%{
  provider:         String.t(),          # inline, human-auditable
  name:             String.t(),          # inline
  revision:         String.t() | nil,    # OPTIONAL — some APIs lack it; strict seam must not require it
  params_hash:      String.t(),          # sha256 over ONE normative canonicalization
  params_inline:    %{...},              # capped subset, grow-only keys
  prompt_cache_key: String.t() | nil     # OPTIONAL provider telemetry, NOT replay identity
}
```

- **`params_hash` canonicalization spec (normative, written once):** sha256 over
  the JSON of the params object with **sorted keys** and a **documented
  excluded-ephemeral list** (request ids, timestamps, and other per-call noise
  are excluded); one serialization or hashes are incomparable across writers in
  golden fixtures.
- **`params_inline`** is the capped subset `%{temperature, top_p, max_tokens,
  seed}` (grow-only keys) — the human/audit split, mirroring the frozen `charge`
  shape discipline (the split is the type; the cost/compare *function* is policy).
- **`prompt_cache_key`** is opaque provider telemetry, explicitly **NOT part of
  replay identity** — the byte-identical prefix (P-U12.3) is the cache contract.
- **Versioning rule:** `params_hash` covers the keys present at write time;
  additive bag keys = `schema_version` minor bump; old and new hashes are each
  valid over their own key sets.
- **Attachment:** required on `probe_run` terminal events (§3); stamped on every
  LLM-bound `item_completed`. Absence on an `item_completed` explicitly means
  **"no provider call in this item"** — non-LLM items carry no fingerprint, and
  that absence is meaningful, not sloppy.
- **Precedence law (frozen):** the `item_completed` fingerprint wins for *"what
  produced this content"*; the `turn_started` override (below) wins for *"what
  was asked for"*; the session head config is **defaults only**.

#### Replay-fidelity law (frozen)

Any per-turn override of a head-tagged parameter (model, effort, policy) MUST be
journaled in that turn's `turn_started.payload` (optional keys; absent = head
values apply). This extends the frozen `gate_decision.seed` principle (replayable
dice) from dice to provider params: the head tag states session defaults, the
journal states deviations, and a journal written while overrides existed but went
unrecorded is permanently unattributable (unbackfillable — hence a law, not a
later add).

#### Meta type registry (v1, grow-only — from protocol §3-meta)

| type | payload (required keys) | scope | notes |
|---|---|---|---|
| `gate_decision` | `%{gate, score, threshold, choice, seed, refs}` | session | `seed` = replayable dice (U13) |
| `extract` | `%{class, op, item, refs}` — `op ∈ :add\|:update\|:drop` | session | U14 tracks |
| `residual` | `%{description, refs}` | session | the named unknown; U19's promotion signal |
| `calibrate` | `%{gate, observed_score, quantile, new_threshold, refs}` | session | U18; `refs` may be `[]` |
| `verdict` | `%{family, drift_score, advice, refs}` | session | U17 cross-family |
| `research` | `%{conclusion, refs}` | session | U16; advisory, never an interrupt |
| `promote` | `%{item, justification, refs}` | **global** | the only `:global` type; requires human `approval_decision` before commit |
| `probe_run` | `%{probe, run_id, status, charge, refs}` | session | probe lifecycle (§3); `status` grow-only enum |
| `attach` | `%{from_offset, history_policy, surface, refs}` | session | best-effort audit (§1.1); nothing may depend on it |
| `speculation` | `%{phase, branch_ref, outcome, refs}` — `phase ∈ :begin\|:commit\|:rollback` (grow-only); `outcome ∈ :cleared\|:rejected\|:disagreed\|:timeout\|nil` | session | YOLO/tournament branch lifecycle (yolo-safe C2); at `:begin`, `refs` names the parent tip **offset(s)** — plural by construction (a merge-commit speculation names N parents) |
| `approval_decided` | `%{request_ref, decision, actor, refs}` | session | AD-14 decision record (G4); journaled so U8's "after deny, no later success" is a fold, not an honor system; tip-excluded (a trailing deny is not a resume point) |
| `policy_amended` | `%{scope, rule_id, before, after, source, refs}` — `source ∈ :human\|:calibrate\|:oracle` (grow-only) | session | journaled **BEFORE enforcement** (reserve-before-call applied to policy); U18-servo learned policies are `source: :calibrate` **rows, never a side file** |

**`refs` is frozen as the uniform annotation mechanism:** a required payload
key on every meta type — a list of journal offsets (`[non_neg_integer()]`,
may be empty) naming the loop event(s)/record(s) this meta event annotates or
derives from. (The protocol draft's `promote.journal_refs` unifies to `refs`;
that draft field never landed in code, so this is a pre-freeze naming
decision, not a rename.) `promote` additionally requires `refs != []` —
provenance-mandatory (protocol §3).

**Session-scoping contract (F1/OQ-U11.1 — permanent, load-bearing):** `refs`
are interpreted relative to the enclosing record's `id`'s `session_id`;
cross-session references are a consuming-store concern (global store / ADR),
never a journal event field. This is a **permanent commitment** — a future
need for in-journal cross-session refs would repurpose `refs` and break
every decoder, and is therefore **forbidden**. `promote`'s refs name
source-session records only; cross-session qualification at the global store
is the store's job, not the journal's.

Meta events are journaled as `kind: "event"` records, durable tier, same
Writer, same offset space — "both populations write the same journal"
(protocol §1) needs no new machinery.

#### Provenance source registry (grow-only)

`:primary` (the loop), `:surface` (a UI/command origin),
`:probe_<name>` (e.g. `:probe_c1_gate`, `:probe_c2_rules`,
`:probe_c2_residual`, `:probe_c6_verdict`, `:probe_c7`, `:probe_c5`,
`:probe_meta_adr`). New sources are additive; readers render unknown sources
as opaque labels.

#### Taint algebra (frozen semantics, FI-5)

1. **Two-point lattice, tainted-absorbing:**
   `derive(e₁..eₙ).trust = :tainted iff ∃ i: eᵢ.trust == :tainted`, else
   `:trusted`. No third value in v1 (a future value extends the lattice;
   readers treat unknown trust values as `:tainted` — fail-closed).
2. **Entry rule:** taint enters at tool results. *Which* sources are
   untrusted is policy (tool metadata / U8), NOT frozen here; frozen is only
   that the classification happens at the `tool_result` producer and the
   algebra thereafter is mechanical.
3. **No laundering in v1:** trust never upgrades `:tainted → :trusted`. C3's
   intent-filtering reduces *volume*, not taint — filtered output stays
   tainted (the Willison boundary: what changes is the privilege of the
   consumer, not the trust of the data). An explicit sanitization/launder
   mechanism, if ever wanted, is a NEW meta type with its own human ruling —
   reserved, unfrozen.
4. **Checkable via `refs`:** if any event named in `refs` is tainted, the
   meta event MUST be tainted. This makes taint propagation a journal-foldable
   property, not an honor system.
5. **Gates read taint:** a tool call whose args derive from tainted content
   takes a distinct confirmation path (FI-5 verbatim) — the *enforcement* is
   U8/U15's job; the *marker semantics* are frozen here.

#### Decode/validation seam

- Producer seam (strict): emitting a `family: :meta` event whose `type` is
  not in the compiled registry, or whose payload misses a required key, is a
  loud reject at emit — `{:error, {:unknown_meta_type, t}}` /
  `{:error, {:invalid_meta_payload, t, missing}}`.
- Reader seam (tolerant): an unknown meta `type` (or unknown provenance
  source / unknown status) replayed from a journal or received by a fork at
  version skew is skipped by typed folds, preserved raw, never an error.

### 2.2 Positive contour

Governing dispositions: FI-5, FI-2, AD-11, I9.

- **P-U11.1 codec round-trip — relabeled PROPERTY (F9), not a must-fail
  red:** every registry meta type round-trips through the JSON codec
  byte-stable (post-sanitize), including `scope`, `provenance`, `refs`.
  Round-tripping is naturally a property/oracle-independence test (encode
  then decode then compare), not a single-mutation red.
- **P-U11.2 grandfather decode — relabeled CORPUS TEST (F9), not a
  must-fail red:** a v0 event (no scope/provenance) decodes to the frozen
  defaults; the I9 corpus stays green with the grown struct. Runs as a
  pure-decode corpus check, same class as P-JS7.
- **P-U11.3 taint monotonicity (fold property):** over any generated journal,
  for every meta event `m`: `m.provenance.trust == :tainted` iff some record
  named in `m.payload.refs` is tainted or `m`'s producer input was tainted.
  Generator MUST include chains ≥3 deep (tainted tool_result → extract →
  promote-draft) — shallow chains make absorption vacuous (meta-inv 5).
- **P-U11.4 scope discipline:** `scope: :global` appears only on `promote`;
  every `promote` has `refs != []` and each ref resolves to an existing
  journal record.
- **P-U11.5 two-populations fold independence:** a loop-only projection
  folded over a journal with interleaved meta events equals the same fold
  over the meta-stripped journal (meta events never perturb loop folds), and
  vice versa — oracle: independent raw-file decoder (meta-inv 6). Negative
  contour: N-U11.7 (F9).
- **P-U11.6 actor producer-seam consistency — relabeled PROPERTY (fold):** over
  any generated journal, every `kind: "event"` record's `actor` equals the
  write-generation's command/attach-context actor; absent `actor` folds as
  `%{kind: :system}` by rule. Oracle independence: recomputed from the raw
  producer context, not a module-local value. Non-event records
  (checkpoint/schedule) carry no actor.
- **P-U11.7 fingerprint precedence:** for any LLM-bound `item_completed` the
  attached fingerprint is authoritative for "what produced this content"; where a
  `turn_started` override is present it governs "what was asked for", and the head
  config governs neither where either is present. `params_hash` is byte-stable
  under the normative canonicalization across two independent encoders (property,
  same class as P-U11.1).
- **P-U11.8 speculation refs are plural-capable:** a `speculation{phase: :begin}`
  MAY name N parent tip offsets in `refs`; a merge-commit speculation naming ≥2
  parents round-trips and folds without any singular-parent assumption. Generator
  MUST include a ≥2-parent case (vacuous otherwise).

### 2.3 Negative contour

| # | violation | exact required failure | dead injector |
|---|---|---|---|
| N-U11.1 | emit unregistered meta type | `{:error, {:unknown_meta_type, t}}` at the emit seam; nothing journaled, nothing on the bus | emit seam patched to pass-through unknown types |
| N-U11.2 | emit meta event missing a required payload key (e.g. `gate_decision` without `seed`, any type without `refs`) | `{:error, {:invalid_meta_payload, type, [missing_keys]}}` | validator with the required-key sets emptied |
| N-U11.3 | derived event stamped `:trusted` from tainted inputs | P-U11.3 fold red fails naming the offending offset pair `{meta_id, tainted_ref_id}` | producer that hardcodes `trust: :trusted` |
| N-U11.4 | `promote` with `refs: []`, or `scope: :global` on any other type | `{:error, :provenance_required}` / `{:error, {:scope_violation, type}}` | scope check deleted |
| N-U11.5 | trust upgrade (`:tainted` input, `:trusted` output via any "sanitizing" path) | same red as N-U11.3 — there is no legal upgrade path in v1, so ANY upgrade is a failure | a "launder" branch added to the algebra |
| N-U11.6 | reader errors on unknown meta type from a future-version journal | tolerance red asserts skip-and-preserve; erroring reader is the breakage | decode seam applying producer-strictness at the reader seam |
| N-U11.7 | a meta event injected into an otherwise loop-only journal changes the loop-only fold's result (or vice versa) | P-U11.5 fold-independence red fails, naming the offset where the two folds diverge | fold implementation that doesn't filter on `family` before applying loop-typed logic |
| N-U11.8 | a module invents `actor` locally instead of the producer seam, or a reader infers human/agent from absent `actor` | P-U11.6 fails: two records in one write generation disagree on actor, or absence decodes as non-system | module-local actor stamping; reader that guesses actor from context on absence |
| N-U11.9 | head / `turn_started` / `item_completed` fingerprints disagree and the fold picks the wrong precedence (e.g. head wins over `item_completed`) | P-U11.7 fails naming the offset whose content is mis-attributed | fold that reads session-head model as "what produced this content" instead of the `item_completed` fingerprint |
| N-U11.10 | `speculation{:begin}` validator hardcodes a single parent (refs treated as scalar) | P-U11.8 fails: a 2-parent begin is rejected or truncated to one | validator asserting `length(refs) == 1` at `:begin` |

### 2.4 Forward-compat note

- Grows by: new meta types (registry append), new provenance sources, new
  provenance keys, new trust lattice points (readers fail-closed to
  `:tainted` on unknown), new statuses inside `probe_run`, new `scope`
  values (F2, ratify-before-impl — readers render unknown scopes opaquely).
  Note: U8 already uses three approval scopes (`:once`/`:session`/`:root`,
  policy.ex:36); capping the meta-event `scope` enum at two
  (`:session`/`:global`) was a latent repurpose risk, now closed by making
  `scope` grow-only like everything else.
  Fold-before-reds growth: the `speculation`/`approval_decided`/`policy_amended`
  meta types, envelope `actor`, `cost_ref` on spend-bearing records, and the
  model/params fingerprint keys (each additive, defaulted, or grow-only over its
  own key set).
- Never: renaming `refs`/`scope`/`provenance`/`source`/`trust`, repurposing a
  registered type, weakening `promote`'s human-confirm or `refs != []`, putting
  `bill_to` on records (the Ledger is the single money truth — billing is a
  derived fold), moving `actor` onto pointer records (checkpoint/schedule),
  inverting the fingerprint precedence law, or treating `prompt_cache_key` as
  replay identity.
- UI-fork reader ignores safely: unknown meta types (raw view only), unknown
  sources, unknown payload keys, unknown `actor.kind` (render opaque, never as a
  trusted human), unknown fingerprint/`params_inline` keys, `$blob`/`$redacted`
  markers in meta payloads. It must respect: the trust field on everything it
  renders (tainted content is visually attributable — C3 boundary), and must not
  render unknown-trust as trusted.

### 2.5 Ruled (was: open questions — now decided, binding)

- **OQ-U11.1 — RULED: offsets-only, WITH a permanent session-scoping
  contract.** `refs` stays `[non_neg_integer()]` (see §2.1). Reason: every
  journal event lives in a session-scoped journal, so its refs resolve
  within that session for U11-U18 and U20 alike — `promote`'s refs name
  source-session records; cross-session qualification is the global
  store/ADR's job, never the journal's. This is a **forever** commitment: a
  future need for in-journal cross-session refs would repurpose `refs` and
  break every decoder, and is therefore forbidden.
- **OQ-U11.2 — RULED: per-surface atoms** (`:surface_tui`, `:surface_cli`,
  …), grow-only registry. Reason: one `:surface` atom collapses distinct
  trust/audit origins (interactive keystroke vs. automated pipe) into one
  label, forcing a later split (rename pressure) and weakening
  blast-radius/audit fidelity. Affects the U4 attach-audit red only.
- **OQ-U11.3 — RULED: ALARM + `:taint_violation` marker, NOT a hard
  reject.** Reason: a hard validate-on-replay reject would retroactively
  corrupt historical journals on any taint miscount and turn taint into a
  decode-time gate — this violates the Reader's "never mark damaged on
  semantic grounds" contract. Replay tolerance stays intact; emit telemetry
  and fold a `:taint_violation` marker so P-U11.3 stays an observable fold
  property.

---

## 3. U12-CONTRACT — probe runner interface

**Governs:** U12; unblocks U13–U18 reds. Interface only — no implementation
is implied beyond the frozen observables. Per roadmap D2: in-BEAM supervised
pool (no Oban/Postgres — D1 stayed on files).

### 3.1 Frozen shape

#### The probe behaviour

```elixir
defmodule Raxol.Agent.Probe do
  @type context :: %{
          session_id: String.t(),
          tip_offset: non_neg_integer(),   # durable watermark the probe sees (JS-FREEZE tip)
          prefix_ref: term(),              # OPAQUE handle to the primary conversation prefix
          taint: :trusted | :tainted,      # meet of the context the probe reads (U11 algebra)
          budget_scope: term()             # opaque; runner resolves to the SpendGate scope
        }

  @type request :: %{
          suffix: [map()],                       # messages appended AFTER the shared prefix
          output: :structured | :text,
          max_output_tokens: pos_integer()
        }

  @callback spec() :: %{
              id: atom(),                        # registry key, e.g. :c1_gate → provenance :probe_c1_gate
              mode: :cache_riding | :standalone, # standalone = no prefix (rare; C6 cross-family)
              max_calls: pos_integer(),          # hard non-LLM termination (per run)
              timeout_ms: pos_integer(),         #   "        "        "
              default_budget: pos_integer(),     # tokens (see Budget)
              max_parked: pos_integer(),         # pool-level cap on parked runs (F5); probe may override the pool default
              park_timeout_ms: pos_integer()     # TTL a parked run may wait before terminating :exhausted (F5)
            }
  @callback build(context) :: {:ok, request} | :skip
  @callback interpret(response :: map(), context) ::
              {:ok, [meta_event_draft :: map()]} | {:error, term()}
end
```

Probes are **pure interpreters**: `build/1` and `interpret/2` receive
read-only data and return data. A probe never touches the journal, the bus,
the session process, or the provider — the Runner does all four. That is the
isolation guarantee *by construction*, not by convention.

#### The runner API (frozen observables)

```elixir
defmodule Raxol.Agent.Probe.Runner do
  @spec submit(session_id :: String.t(), probe :: module(), opts :: keyword()) ::
          {:ok, run_id :: String.t()} | {:error, :unknown_probe}
  # NEVER blocks the caller. NEVER returns results inline — results are
  # meta events on the bus/journal; injection into primary context is a
  # SEPARATE, EXPLICIT step owned by the caller (roadmap U12, verbatim).
  # Saturation/exhaustion do NOT fail submit: the run is accepted and parked
  # (observable via probe_run{status: :parked}). Only an unregistered probe
  # module fails submit. Parking is BOUNDED (F5) — see max_parked/
  # park_timeout_ms in spec() and the Bounded parking note under Budget.

  @spec kill(run_id :: String.t()) :: :ok | {:error, :not_found}
  @spec status(run_id :: String.t()) ::
          {:ok, :queued | :parked | :running | :completed | :killed |
                :exhausted | :timeout | :error} | {:error, :not_found}
end
```

#### Probe lifecycle = `probe_run` meta events (U11 registry)

Every run emits `probe_run` meta events with
`payload: %{probe, run_id, status, charge, refs}`;
`status ∈ :started | :parked | :completed | :killed | :exhausted | :timeout |
:error` (grow-only enum). Terminal statuses are exclusive and final — exactly
one terminal `probe_run` per run. `refs` names the loop events the probe read
(≥ the tip at submit). Result meta events drafted by `interpret/2` are
emitted by the **Runner**, which stamps `provenance.source = :probe_<id>` and
computes `trust` from `context.taint` ⊓ drafted refs (U11 algebra) — a probe
cannot stamp its own provenance.

**Fingerprint + cost_ref on the terminal (fold-before-reds):** the terminal
`probe_run` event carries the model/params fingerprint (§2.1, **required** on
probe terminals — the replay-science surface must be exact) and MAY carry
`cost_ref` into the Ledger. A multi-call probe's terminal fingerprint is
last-wins unless a future grow-only per-call list supersedes it.

#### Budget (the accounting unit + exhaustion)

- **Unit: tokens**, reserve-before-call via the SpendGate/`Ledger.try_spend`
  shape (AD-6a): reserve `estimate = max_output_tokens +
  uncached_prompt_estimate` **before** each provider call; settle actuals
  after. Fail-closed: no reserve ⇒ no call, ever.
- **Settlement is internal, not part of the probe interface (F4,
  ratify-before-impl):** reserve→settle/refund (`estimate − actual`) is a
  Runner↔Ledger-internal step; no `reservation_id` is exposed to probes or
  callers by design. The frozen `charge` shape (below) is the
  **post-settlement, authoritative** report, not a running reservation
  ledger. (Considered and rejected for v1: exposing a
  `reservation_id`/`settle` primitive on the Runner API — deferred as
  unneeded surface area; revisit only if a caller needs to observe in-flight
  reservations.)
- **Charge shape (frozen):**

```elixir
@type charge :: %{
        prompt_tokens: non_neg_integer(),
        cached_prompt_tokens: non_neg_integer(),   # the cache-riding dividend, visible
        completion_tokens: non_neg_integer(),
        calls: non_neg_integer()
      }
```

  The cost *function* over a charge (how cached tokens are weighted) is
  policy, not frozen — the shape guarantees the UI fork and U18 can always
  see the split.
- **Exhaustion signals (all three frozen):**
  1. reserve refused at submit-time budget check → run **parked**
     (`probe_run{status: :parked}`), not dropped, not an exception;
  2. reserve refused mid-run (multi-call probe) → run terminates
     `probe_run{status: :exhausted}`; partial drafted events are NOT emitted
     (a probe's output is atomic: all interpret-events or none);
  3. `max_calls`/`timeout_ms` tripped by the Runner → `:exhausted` / `:timeout`
     terminal event. Non-LLM termination is the Runner's job — a probe cannot
     extend its own leash.
- **Bounded parking (F5 fix, load-bearing):** "never drop, never fail
  submit" does NOT mean unbounded accumulation. The parked set is bounded by
  two frozen knobs (`spec()`, above): `max_parked` (pool cap) and
  `park_timeout_ms` (per-run TTL). A parked run that exceeds
  `park_timeout_ms` terminates `probe_run{status: :exhausted}` — parking is
  never indefinite. `submit` past `max_parked` still returns
  `{:ok, run_id}` (submit never synchronously fails on saturation, per
  N-U12.3); the oldest/over-TTL parked runs shed to `:exhausted` so the
  parked set never grows without bound under sustained budget exhaustion.
  This is **additive** to N-U12.3's "never drops silently" rule, not a
  denial of it: a shed run still gets its terminal `probe_run` event, it is
  never simply discarded.

#### Cache-riding (frozen requirement, mechanism opaque)

For `mode: :cache_riding`, the provider request is
`shared_prefix ++ request.suffix` where the shared prefix is
**byte-identical** to the primary loop's most recent request prefix at
`tip_offset` (same messages array bytes — whitespace, ordering, continuity
tokens included; AD-5 applies to probes too: never filter content blocks).
`prefix_ref` is opaque — probes cannot read or mutate the prefix, only ride
it. Byte-identity is what makes the KV/prompt cache hit; it is testable
without any provider (capture two built requests, compare prefixes).

#### Isolation guarantees (frozen)

1. One supervised process per run; a probe crash yields
   `probe_run{status: :error}` and touches nothing else — the primary loop's
   turn proceeds unaffected.
2. `kill(run_id)` is effective mid-provider-call and never propagates to the
   primary loop or sibling probes.
3. Probes emit only `family: :meta` events, only via the Runner. A drafted
   event with `family: :loop` is rejected (see negative contour).
4. Probe results never enter primary context implicitly. The injection
   boundary is a separate explicit call by the loop owner — frozen as absent
   from this interface on purpose.
5. Pool saturation queues or parks; it never drops a submitted run silently
   and never blocks `submit/3`. (Scheduling order is implementation
   freedom.) The parked set is bounded (F5, see Budget above) —
   `max_parked`/`park_timeout_ms` — so "never drops" and "bounded" hold
   simultaneously.

### 3.2 Positive contour

Governing dispositions: AD-6a (reserve-before-call), FI-5 (taint), the
economic law (cache-riding), D2 (in-BEAM pool), roadmap U12 acceptance.

- **P-U12.1 lifecycle completeness:** every submitted run produces exactly
  one `:started`-or-`:parked` and exactly one terminal `probe_run` event;
  journal fold over `probe_run` yields a consistent state machine per
  run_id. Negative contour: N-U12.8 (F9 — closes the gap where N-U12.4 only
  covered `max_calls`, not the started→terminal count).
- **P-U12.2 reserve-before-call:** journal order per provider call is
  `reserve → call → settle`; never a call without a prior same-run reserve
  (Tier-2 U7/U8 pattern, applied to probes).
- **P-U12.3 prefix byte-identity:** for N cache-riding probes built at the
  same tip, all N request prefixes are byte-identical to each other and to
  the primary's request prefix.
- **P-U12.4 isolation:** killing/crashing any subset of concurrent probes
  leaves the primary turn's event trace identical to the no-probes run
  (loop-fold equality, P-U11.5's machinery reused).
- **P-U12.5 provenance stamping:** every result meta event carries
  `provenance.source == :probe_<spec.id>` and
  `trust == context.taint ⊓ refs-taint`; a probe run over tainted context
  can produce no trusted event.
- **P-U12.6 output atomicity:** a run that hits exhaustion/timeout/kill after
  drafting k of n events emits none of them — only the terminal `probe_run`.
  Negative contour: N-U12.9 (F9).

### 3.3 Negative contour

| # | violation | exact required failure | dead injector |
|---|---|---|---|
| N-U12.1 | probe drafts a `family: :loop` event | Runner rejects the whole result: terminal `probe_run{status: :error}` with reason `:family_violation`; zero drafted events emitted | Runner emit path with the family check removed |
| N-U12.2 | provider call without prior reserve | P-U12.2 red fails naming the call; runtime: the call must not have been made (`no reserve ⇒ no call`), observable via the fault-injected provider stub's call counter | Runner variant that settles-only (post-hoc accounting) |
| N-U12.3 | budget refused at submit | run parks: `probe_run{status: :parked}`; `submit` still returned `{:ok, run_id}`; NO provider call occurred | submit path that silently drops the run (returns ok, emits nothing) — the "never drops silently" red must catch it |
| N-U12.4 | `max_calls` exceeded | Runner kills at call `max_calls + 1` attempt: no (n+1)th provider call, terminal `:exhausted` | leash check moved inside the probe (probe-controlled = no control) |
| N-U12.5 | prefix divergence (rebuilt prefix differs by 1 byte — whitespace, reordered key, filtered reasoning block) | P-U12.3 comparison red fails with the first divergent byte offset | prefix builder that re-serializes messages instead of reusing captured bytes |
| N-U12.6 | trusted event drafted from tainted context | Runner overrides to `:tainted` (algebra is Runner-owned) — red asserts the emitted event is tainted regardless of the draft | Runner honoring probe-drafted trust |
| N-U12.7 | `kill/1` on a running probe leaks a provider stream / emits post-kill drafted events | red: no meta event for that run after the `:killed` terminal (I-pattern from U5: no `tool_result` after kill-complete) | kill path that stops the process but not the in-flight interpret emit |
| N-U12.8 | Runner double-emits (or omits) a terminal `probe_run` for one `run_id` | P-U12.1 lifecycle-completeness red fails: fold over `probe_run` shows 0 or ≥2 terminal events for that `run_id` | Runner variant that re-emits `:exhausted` after an already-terminal `:completed` (crash-recovery bug), or one that frees the process without ever emitting a terminal event |
| N-U12.9 | Runner emits the first `k` of `n` drafted `interpret/2` events, then hits exhaustion/timeout/kill before emitting the rest | P-U12.6 atomicity red fails: journal contains `k` result meta events plus the terminal `probe_run`, instead of zero | Runner variant that streams drafted events as they're produced instead of batching-then-emit-on-terminal-success |
| N-U12.10 | submit pumped past `max_parked`, or a parked run left past `park_timeout_ms` (F5) | parked-set size stops growing at `max_parked` (excess runs still receive a terminal `probe_run{status: :exhausted}` — never silently discarded); a parked run past TTL terminates `probe_run{status: :exhausted}` | Runner variant with no cap/TTL check — parked set grows unbounded under sustained budget exhaustion |

N-U12.10 is **additive** to N-U12.3, not a replacement: submit-time
saturation still returns `{:ok, run_id}` and parks (never a synchronous
failure); N-U12.10 only bounds how long and how many runs may sit parked.

### 3.4 Forward-compat note

- Grows by: new `probe_run` statuses, new charge keys (e.g. cost-in-currency),
  new spec keys (defaulted), new probe modes, new context keys. Probes built
  against v1 `context` keep working — new keys are additive.
- Never: renaming `charge` keys, repurposing a terminal status, making
  `submit` blocking, adding an implicit result-injection path, letting probes
  stamp provenance.
- UI-fork reader ignores safely: unknown statuses (render as opaque
  in-flight), unknown charge keys. It relies on: exactly-one-terminal per
  run_id, and the charge split (cached vs uncached) for cost display.

### 3.5 Ruled (was: open questions — now decided, binding)

- **OQ-U12.1 — RULED: TWO-LEVEL** (per-run nested inside a per-session probe
  budget). Reason: per-run-only lets a single session spawn unbounded probes
  (no session cap), contradicting the "runaway impossible" goal (U16) and
  leaving the per-session economy undefined. `budget_scope` reserves
  session-then-run, in that fixed order, so exhaustion of either parks the
  run without an ordering hazard.
- **OQ-U12.2 — RULED: freeze the interface now; `@tag`-pending reds until
  U17.** Reason: C6 cross-family is the only `:standalone` consumer and it's
  Wave 4 — a standalone red now would have no implementation surface to
  validate against and would drag in a cross-family test harness for no
  benefit. The shape is additive and zero-risk to freeze today.
- **OQ-U12.3 — RULED: FULL read-set** (every offset the probe's context
  actually included), not tip-at-submit only. Reason: the taint-meet
  computation (P-U12.5) depends on knowing exactly which records fed the
  derived events; a tip-only `refs` would let a derived event read tainted
  content while claiming a clean tip-only lineage, breaking the algebra.
  Auditable beats cheap; the read-set is a pure output of `build/1`.

---

## 4. Reds unblocked by this doc

| freeze | red suites enabled | what they can now assume |
|---|---|---|
| **JS-FREEZE** (§1) | **U4-R** (reattach/replay + Dormammu FI-12), **U9-R** (checkpoint pointers), **U10-R** (compaction=resume) | one record-kind taxonomy, one offset law, one tip predicate — U4 and U9 reds are written in parallel against the same schema with zero conflict; the false parallel is dissolved at the contract layer. **U4-R/U9-R/U10-R now also assume** `branch_id` (branch-aware `tip(journal, branch := "main")`) + session-lineage edges (`meta.json parents`, resolvable-or-absent); the **closure rule** protects every future kind/type (tip-excluded unless whitelisted into CONVERSATIONAL). |
| **U11-CONTRACT** (§2) | **U12-R** (probe runner needs the meta family + `probe_run` type + taint algebra to state its observables) | meta type registry, `refs`, provenance/taint semantics, reader tolerance rules |
| **U12-CONTRACT** (§3) | **U13-R … U18-R** (every probe red states its gate/extraction behavior as `submit → probe_run lifecycle → meta events with frozen provenance`, against a mock Runner satisfying §3 observables) | invocation, budget unit + exhaustion, result/charge shapes, cache-riding byte-identity, isolation guarantees |

Meta-invariant obligations carried by every suite above: fired-counters on
all fault sites, seed-reproducible schedules, oracle independence
(raw-file/second-decoder), one negative-control mutation per invariant, and
required generator patterns as flagged inline (P-JS3, P-U11.3).

---

## 5. Command / action contract additions (fold-before-reds)

These two items are ratified by the fold-before-reds revision but belong to
neither of the three frozen surfaces (journal / meta / probe) — they govern the
command-ingest and action seams. They are frozen here as the contract source of
truth and cross-referenced from their implementing drafts.

### 5.1 `client_msg_id` — command idempotency (ingest seam)

Every externally-injected command carries a client-supplied idempotency key
`client_msg_id`. Duplicate delivery (same `(session_id, client_msg_id)` within
the dedup window) is deduplicated at the ingest seam — an idempotent accept
referencing the original turn, never a second durable turn. The command's `actor`
comes from the attach/auth context (cross-ref §2.1 actor producer-seam stamping),
and `turn_started.payload` grows an optional `client_msg_id` linking the turn to
its client message. Offset-derived keys are forbidden (they break under
replay/compaction); the key is generated client-side at write time.

### 5.2 `effect_class` + `egress` — the action reversibility taxonomy

Frozen here as the contract source of truth (the field itself lives in the F2
`Raxol.Action` draft, still unfrozen; this freezes the *taxonomy* those reds
depend on):

```
effect_class ∈ :reversible_local | :bounded_sandboxable | :irreversible_external
egress:        boolean
```

The YOLO auto-approvability predicate and the always-escalate set dispatch on
these (`harness-yolo-safe-research.md` §2/§7): `:irreversible_external` is the
irreducible always-escalate class (no lineage, oracle, or calibration overrides
it), and `egress` is the exfil leg of the lethal trifecta. Enforcement is
**structural, compiled in our own tree** — never self-reported by an untrusted
MCP tool (the `destructiveHint`-is-a-lie class, yolo-safe N-Y5).
