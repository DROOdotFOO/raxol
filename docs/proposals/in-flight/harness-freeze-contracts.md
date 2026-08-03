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

**Ratification authority:** throughout this doc, **"V"** is the project owner
(vsevolod.rodionov), whose ratification rulings are recorded inline with dates
("RATIFIED by V, YYYY-MM-DD") and are the sole gate between PROPOSED and frozen;
`AF-*` audit-finding provenance lives in the PR #569 review threads by design —
findings enter this doc only where they change contract text.

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
     - **Carve-out — skip-unknown is a *fold* rule, not a *selection/security*
       rule (clarified per AF review #569).** "Skip in typed folds" is sound
       only for associative/commutative folds, where a dropped record yields a
       degraded-but-consistent result. Two frozen operations are NOT such folds
       and state their own overriding tolerance:
       (a) an unknown `trust` value folds **fail-closed to `:tainted`** per
       §2.1.1 / §2.4 — it is not skipped (skipping would fail *open*); and
       (b) the conversational **tip** is a `argmax`-by-offset **selection**, not
       a fold — silently skipping an unknown-but-possibly-conversational record
       changes the *answer* rather than degrading it, so tip derivation carries
       its own skew rule (the tip skew-guard, RATIFIED §1.4 / must-fail red
       N-JS-skew, §1.3). Where a specific section states a fail-closed /
       selection rule, it overrides this general skip.
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
   of any other record. **I2 scoping (byte-identity/hash invariants) is a
   WRITE-TIME property:** the `$redacted` rewrite is the one legal *post-write*
   mutation of a payload value, and it MUST be accompanied by an I9-corpus
   fixture containing a redacted record — so replay/hash tooling is exercised
   against a legally-mutated log, not only against strictly-append-only ones.
7. **Decision-time evaluation law (the general form of the taint/GC gates
   below).** Tolerate-and-mark applies to REPLAY/AUDIT seams; ADMISSION
   decisions (gates, `gc` acceptance, gate-relevant trust) MUST evaluate the
   folded truth synchronously at decision time. A red suite that only tests the
   replay seam is incomplete without its decision-time counterpart. This is why
   OQ-U11.3's "taint miscount ⇒ marker, not reject" (a replay-seam tolerance)
   does NOT license a gate to read a stamped `trust` field: the stamp is
   display/audit metadata, the fold is the security boundary. HIGH-1 (§2.1 taint
   point 6 / §5.2) and HIGH-2 (§1.1 schedule arming) are two instances of this
   law.

---

## 1. JS-FREEZE — journal record-kind schema

**Governs:** U4 (reattach/replay, AD-15/FI-12), U9 (checkpoint, AD-10/AD-3a —
AD-3a = checkpoint as an in-log pointer record, not out-of-band state), U10
(compaction=resume, AD-3b — AD-3b = compaction is resume, one artifact, never
a second kind; both sublabels are children of parent AD-3, defined in
`harness-synthesis.md`). Kills the U4∥U9 false parallel: both units
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

**Frozen law: GC never orphans checkpoints.** GC/truncation never removes
records at/above the newest healthy checkpoint's `tip_offset` — a checkpoint's
restore path must stay intact. A `gc` proposal violating this is rejected at
the same seam as `:invalid_tip` (a synchronous admission decision, §0
clause 7 — never accepted-then-marked).

#### The complete kind set (v1 — minimal, each justified)

| kind | who appends | payload | why it exists |
|---|---|---|---|
| `event` | EmitBridge (durable tier) | the contract Event fields as landed (`v, session_id, turn_id, ts, family, type, tier, payload`) | the existing corpus; `"kind"` absent ⇒ `"event"` (grandfather clause — every landed journal stays valid, byte-for-byte) |
| `checkpoint` | checkpoint writer (U9/U10), via the same single Writer | §1.1-checkpoint below | AD-10: checkpoints are **in-log pointer records** — all four cohort leaders independently converged here; HEAD sidecar stays offset+config only, never model state |
| `annotation` | any writer (reopen the single Writer) | `%{target_offset \| target_range, label, body_ref, author, consent_class}`; `consent_class ∈ private \| shareable \| train` (grow-only) | human/agent notes on history (F14, community-gaps VB#13); **open-any-writer through the single Writer** (non-authoritative, **tip-excluded by the closure rule**); annotations **are records** — they count toward segment rotation and GC, so unbounded annotation bloat is a **GC-policy concern, not a contract gate**; sharing/export honors `consent_class` |
| `schedule` | scheduler writer (durable trigger store) | `%{trigger_id, when: cron\|event\|once, next_fire, payload_ref, armed, armed_by}` — `armed_by` REQUIRED, arming provenance (§1.1-schedule below) | wake / self-initiated autonomy (F9, community-gaps class 13); the journal is the authoritative trigger store — external cron tables are projections; **tip-excluded**; the session lifecycle enum grows `:dormant` (a session parked between wakes); **inside the taint lattice via `armed_by`** (§1.1-schedule) |

**The single-writer mutual-exclusion mechanism (frozen — what "any writer" and
"open-any-writer" mean above).** "Any writer can append an annotation" and
"open-any-writer through the single Writer" (`schedule` row) name a routing
discipline, never a second writer process: the Writer is a **per-session-dir
singleton GenServer, registered via `:global` keyed by the session directory**
(`{:global, {Raxol.Agent.Journal.FileStore.Writer, dir}}` — this is exactly
what the landed `FileStore.Writer` already does). "Any writer" means any
caller — the annotation feature, the scheduler, a future kind's producer —
routes its append THROUGH that one singleton Writer process via
`GenServer.call/2`, never that two `Writer` processes may coexist for one
session directory. A second `Writer` registered for the same dir is precisely
the N-JS6 violation (§1.3): NC-12 and the offset law (above) hold only because
every append, regardless of who logically "owns" the kind, funnels through
this one process.

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

#### `schedule` arming provenance (frozen — the wake trigger enters the taint lattice)

The `schedule` record carries required arming provenance so a wake armed from
tainted context is distinguishable from a trusted one:

- **`armed_by` (required, refs):** a list of journal offsets
  (`[non_neg_integer()]`, may be empty) naming the events whose *content
  determined the trigger* — the schedule's lineage into the taint algebra
  (§2.1). Empty is legal and meaningful: direct human arming with no
  content-derived input.
- **Actor rule:** the same envelope-actor rule as events (§2.1, producer-seam
  stamping) applies to the ARMING command — the command's `actor` comes from
  the attach/auth context, never invented by the scheduler module. The
  `schedule` *record* itself still carries no `actor` field (pointer-record
  rule, §2.1) — arming attribution lives on the arming command path;
  `armed_by` carries the content lineage.
- **Wake linkage:** the `woken` loop event's `refs` MUST include the schedule
  record's offset, so every wake folds back to its arming provenance.
- **Frozen taint law:** a wake fired from a schedule whose `armed_by` lineage
  folds tainted is a TAINTED wake — the `woken` event's derived taint follows
  the fold (§2.1 algebra), and gates treat post-wake actions accordingly
  (decision-time fold, §0 clause 7). A wake armed from tainted context MUST be
  distinguishable from a trusted one; without `armed_by` the two would be
  indistinguishable, which is exactly the hole this closes.

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

- **No legal tip on a fresh/no-conversation branch (resolves the `pos_integer`
  can't-encode-`:no_tip` observation):** `tip_offset`'s type is `pos_integer()`
  because a checkpoint can only ever be appended where a real conversational
  tip already exists — `tip(journal, branch)` is `:no_tip` on an
  empty/no-conversational branch (§1.1-tip), and per N-JS1 that is not a
  legal write target: a checkpoint MUST NOT be appended before any
  conversational record exists on its branch (you cannot checkpoint before
  any conversation). The type deliberately has no slot for `:no_tip` — it is
  a precondition on the append seam, not a representable value.
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

**The closure rule (frozen).** CONVERSATIONAL is a whitelist **of event
`type`s** (each implicitly within `kind == "event" ∧ family == "loop"`, the two
clauses the predicate applies first). It is the ONLY door for **types**: every
new `family:loop` event type introduced in the future is tip-excluded **unless
explicitly added to CONVERSATIONAL**. Adding a member is a `schema_version` minor
bump; nothing becomes a tip by default. **New record *kinds* are tip-excluded
structurally, not by the whitelist** (clarified per AF review #569): a non-`event`
kind can never satisfy the predicate's `kind == "event"` clause, so
whitelist-addition is *unreachable* for kinds — the "unless added to
CONVERSATIONAL" door does not apply to them. Making a future non-`event` kind
tip-eligible would require a deliberate amendment of the predicate itself (a
distinct, heavier change), which the closure rule intentionally does **not**
provide a default door for. This protects every future kind (`annotation`,
`schedule`, the reserved `gc`) — excluded by construction — and every future
`family:loop` type — excluded unless whitelisted — from silently moving
historical tips.

Excluded by decision: `state_change`, `idle`, every `family: "meta"` event,
every non-`event` kind. Also excluded by decision though it is `family: "loop"`:
`woken` (§1.1-schedule) — a cron/trigger fire is not where a resumed conversation
lands, so it is deliberately kept out of CONVERSATIONAL (the closure rule keeps
it out by default; this records the exclusion is intentional, not an oversight).
That exclusion **is** the Dormammu test (FI-12): a trailing checkpoint, meta
event, idle marker, or `woken` must never be selected as tip.
`approval_requested` is included — a pending approval is exactly where a
resumed conversation must land. **Ratified (was implicit, AF-3):** (AF-\<n\> =
adversarial-audit finding N (longcat/review), distinct from the F\<n\>
future-foundations tags in `harness-future-foundations-ideation.md` §3.1 — see
`docs/proposals/in-flight/README.md` for the full ID-prefix map.)
`approval_requested` is emitted `family:loop` (a turn-bracket signal), never
`family:meta`, so it passes the tip predicate — this is a frozen decision,
not an accident of which module happens to emit it (`BlastRadiusGate`/U8
must emit it as `family:loop`).

`item_started`'s membership above is ratified, not tentative (OQ-JS3 — see
§1.5): it stays in CONVERSATIONAL from day one. EmitBridge must wire its
emit mapping for `item_started` before U4-R/U9-R reds are authored.

**Emit-vocabulary landing status (baseline correction):** `approval_requested`
and `item_started` are CONTRACT-frozen members of CONVERSATIONAL, but they are
NOT YET LANDED in the emit vocabulary — only `turn_started` and the other
already-landed loop types are wired today. Their EmitBridge wiring is
implementation work the U4-R/U9-R reds depend on; nothing in this freeze should
be read as claiming these types already exist in code.

**`woken` loop-vocabulary registration (like `item_started`):** `woken` must be
registered in the loop vocabulary and its EmitBridge neutral→contract mapping
wired **before any `woken` is emitted** — the producer seam rejects unregistered
types. This registration is orthogonal to its CONVERSATIONAL exclusion: `woken`
is emittable (`family:loop`) but is never a tip.

- **U4 locates the tip** by backward scan under this predicate (over the
  tolerant Reader output — unknown kinds/types encountered on the way are
  skipped, not fatal).
- **U9 references the tip** via `tip_offset`, frozen at write time and
  validated at write time: the record at `tip_offset` MUST satisfy
  `conversational?` or the append is rejected (see negative contour). With
  `branch_id`, `tip_offset` MUST name a conversational record on the
  checkpoint's own `branch_id` (same-branch tip).

#### Record lifecycle (who stamps what — the full stamping path)

```
neutral map (producer)          business fields only
      │
      ▼
EmitBridge.stamp                adds envelope fields: actor, scope,
      │                         provenance, cost_ref
      ▼
Writer.stamp                    adds id, kind, branch_id, schema_version
      │
      ▼
disk (NNNNNN.jsonl)             append-BEFORE-publish; the live path mirrors
                                the SAME stamped envelope, so durable + live agree
```

Both the durable path (`durable_record/1`) and the live path (`map_event/3`)
carry the envelope fields (`actor`, `scope`, `provenance`, `cost_ref`); a field
stamped on one path but stranded on the other is the **named failure mode**
(N-U11.8-class: two records / two paths disagreeing on an envelope field). A red
author carrying a new envelope field must extend BOTH functions plus the Reader
decode, or the durable and live views diverge.

#### Reader tolerance (frozen behavior)

- Unknown `kind` ⇒ the record **participates in offset continuity** (it has a
  stamped dense id), is **excluded from event folds and the tip scan**, and is
  **preserved** in raw reads. Never `{:damaged}`, never dropped, never crashes.
- Missing `kind` ⇒ `"event"` (grandfather clause).
- `Journal.read/2` grows one additive option: `:kinds` (list of kind strings;
  default: all kinds). `:from_offset` unchanged.
- **`last_offset` semantics (AF-6, ratify-before-impl):** `Reader.last_offset`
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
  If present, `"bytes"` is **REQUIRED to equal the dereferenced file's byte
  size**; a mismatch is a typed error `{:error, :blob_size_mismatch}` at deref
  time (same failure family as `:snapshot_corrupt`), not journal damage.
  Bulk bytes live at `<session>/blobs/<sha256>` — content-addressed, FI-8 atomic
  write, **written before** the referencing record (same discipline as checkpoint
  snapshots). Records stay small facts + pointers. Readers built against v1 MUST
  deref-or-render-opaque a `$blob` value (a reader-seam tolerance rule); a
  missing/altered blob file degrades under N-JS3 semantics (deref-fail ⇒
  tombstone, journal stays `:ok`, nothing deleted implicitly per FI-7). The
  Writer externalizes payloads over a per-record byte ceiling (the threshold is
  policy; the ceiling's *existence* is the law). **FI-10 at `$blob` (frozen):**
  blob bytes pass `Contract.sanitize_payload`-class sanitization + MS secret
  exclusion **before** `sha256`/write — the exact same write-boundary discipline
  as checkpoint snapshot files (§FI-10 below), so a large secret cannot evade
  scrubbing by being externalized. **Ordering law: sanitize BEFORE externalize**
  — a sanitized-shorter value may never cross the byte ceiling, so sanitization
  always precedes the externalize decision (and redaction runs before hashing).
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
parents: [ %{session_id, offset, relation, detail \\ null} ]   # list, possibly empty
relation ∈ :fork | :spawn | :merge | :import      # grow-only enum
# detail: optional grow-only map (e.g. %{role: :subagent}), default null
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
- **P-JS2 tip determinism — relabeled PROPERTY (AF-9), not a must-fail red:**
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
- **P-JS7 grandfather — relabeled CORPUS TEST (AF-9), not a must-fail red:**
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
- **P-JS10 blob round-trip — relabeled PROPERTY (AF-9):** for every `$blob` value
  in a healthy journal, the referenced `blobs/<sha256>` file exists and
  `sha256(bytes)` matches the pointer; deref-then-fold equals the same fold with
  the bytes inlined. A missing blob leaves the journal `:ok` (tombstone), never
  `{:damaged}`.
- **P-JS11 low-watermark density (`@tag :gc` — deferred):** under the full I1
  fault schedule, record ids are dense across `[low_watermark, n]`; with
  `low_watermark = 1` this is exactly P-JS1. A prefix missing below an attesting
  `gc`/HEAD watermark reads healthy; missing without attestation reads damaged.
  **Deferred:** not authorable until a `gc` record kind or a HEAD
  `low_watermark > 1` exists — at `low_watermark = 1` there is no below-watermark
  range to truncate, so the scenario is ungeneratable. A test harness MAY inject
  a synthetic `gc` record + HEAD watermark to exercise it, with an explicit
  "simulates future state" note.
- **P-JS12 redaction preserves framing:** replacing a payload value with
  `$redacted` leaves every other record's framing, `id`, `kind`, and hash
  byte-identical; the journal folds `{:ok, _}` before and after. Generator MUST
  place a redacted record between two hash/offset-checked records (vacuous
  otherwise).
- **P-JS13 self-containment — relabeled CORPUS/lint TEST (AF-9):** no golden
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
| N-JS7 | live/ephemeral id surfaces before its durable record is readable (emit-ahead-of-journal — the I3 publish-ahead invariant; invariants.md defines I1–I10, there is no I13) | P-JS5 replay-closure red fails: a late subscriber's `attach_live` stream includes an id not yet present in `read(0..o-1)` | EmitBridge variant that publishes the live id before the Writer append/ack returns |
| N-JS8 | tip scan ignores `branch_id` (selects a record from another branch), or a closure-rule tip predicate patched to accept a non-whitelisted kind/type | P-JS8 fails: `tip(journal, b)` returns an offset with `branch_id ≠ b`, or selects a non-CONVERSATIONAL record | predicate variant dropping the `branch_id == b` clause, or one admitting any `family:loop` type regardless of CONVERSATIONAL membership |
| N-JS9 | reader marks a session damaged for a missing/dangling or cyclic lineage parent | P-JS9 fails; tolerance red asserts `{:ok, _}` and identical fold | reader that resolves lineage as replay input and damages-on-missing-parent |
| N-JS10 | `$blob` deref failure treated as journal corruption, or blob written AFTER the referencing record | P-JS10 fails: reader returns `{:damaged, _}` on a missing blob (must be tombstone + `:ok`), or a crash between record-append and blob-write leaves a referenced-but-absent blob | reader that damages-on-missing-blob; Writer that appends the record before the blob file |
| N-JS11 | a GC'd leading prefix (missing below `low_watermark`) reported as damaged, or a real missing-middle at/above the watermark reported healthy | P-JS11 fails on either side **(`@tag :gc` — deferred until a `gc` kind or HEAD `low_watermark > 1` exists; see P-JS11)** | reader with the density check hardcoded to `1..n` (ignores `low_watermark`), or one treating any missing segment as attested |
| N-JS12 | a "redaction" that rewrites framing/`id`/`kind`/hash, or scrubs a value by any means other than the `$redacted` marker | P-JS12 fails: a neighboring record's hash/offset changes, or the scrub reads as interior corruption (I5/I6) | redactor that re-serializes the record (OpenHands PR #9793 timestamp-corruption class), or one that substring-scrubs across framing |
| N-JS13 | a second concurrent writer / CRDT merge admitted into one journal (NC-12 violation) | P-JS1/P-JS11 density fails: two writers collide on offsets, or a merge produces a non-dense id set | Writer variant accepting appends from a second live writer, or a "converge" path that offset-unions two divergent logs |
| N-JS-skew (tip skew-guard, RATIFIED by V 2026-07-16 — §1.4) | an **older-minor** reader computes the tip on a **higher-`schema_version`** journal whose highest conversational record is a loop-event type **unknown to that reader** (a possibly-hidden newer tip sits above the reader's computed tip) | the reader returns `{:tip_uncertain, reason}` (degrade); it MUST NOT return the silently-older computed offset as if it were the tip. Generator MUST make the journal's stamped minor exceed the reader's and place ≥1 unknown-to-reader `family:loop` event **above** the reader's computed tip (vacuous otherwise; inert at same-version) | reader variant that skips the unknown loop type and falls through to the older computed tip **silently** (drops the skew-guard) → the reattach-lands-wrong bug goes green-on-broken → suite fails |

Every fault site above carries a fired-counter (meta-inv 1); schedules are
seed-reproducible (meta-inv 2). **N-JS6 is the load-bearing single-Writer
lockstep test (AF-7, ratify-before-impl):** the one-offset-law (§1.1) holds
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
  record (self-containment law). **Adding a CONVERSATIONAL member stays a legal
  minor bump, but it is only skew-safe because the reader applies the tip
  skew-guard below** — additive whitelist growth moves the tip forward for newer
  readers, so an older-minor reader that cannot see the new type MUST degrade the
  tip loudly rather than select a silently-older one (removal moves tips for
  everyone and stays forbidden; addition moves tips only across skew and is
  neutralized by the guard, not by barring the addition).
- A UI-fork reader ignores safely: any unknown kind (skip in folds, keep in
  raw), any unknown field on known kinds, any unknown `reason`, an unknown
  `branch_id` (skip in a main-only fold, keep in raw), `$blob` (deref-or-opaque),
  `$redacted` (opaque tombstone), a missing lineage parent (still healthy). It
  must never ignore: `id` continuity, the tip predicate as frozen — additions to
  CONVERSATIONAL ship as minor bumps a **same-or-newer** reader reads forward; an
  **older**-minor reader applies the tip skew-guard below (degrade, never
  silently-older).

#### The tip skew-guard (RATIFIED by V, 2026-07-16)

**RATIFIED by V, 2026-07-16** — Option A over B/C. Root cause: the tip is an
`argmax`-by-offset **selection**, not an associative **fold**, so §0.2's
skip-unknown tolerance (which is only sound for folds) does **not** protect it —
dropping the highest-offset element changes the answer instead of degrading it.
(Full options analysis and rejected alternatives: §7 PA-1, retained as the
ratification record.)

**The rule.** A reader computes `tip(journal, branch)` over the types it knows
(its own compiled CONVERSATIONAL whitelist), exactly as §1.1 defines. It then
MUST degrade the result to `{:tip_uncertain, reason}` **iff** an
**unknown-to-this-reader** loop-event record sits at an offset **above** its
computed tip on the same branch — concretely, iff there exists a record `r` with
`r.branch_id == branch ∧ r.kind == "event" ∧ r.family == "loop" ∧ r.offset >
computed_tip.offset ∧ r.type ∉ (this reader's known loop-type registry)`, on a
journal whose stamped `schema_version` minor exceeds the reader's own. Such an
`r` could be a CONVERSATIONAL type the reader cannot see, i.e. a possibly-hidden
newer tip. Otherwise (every trailing record past the computed tip is a *known*
non-conversational record — checkpoint, meta, idle, or a known-excluded loop type
such as `woken`) the reader's tip is **provably correct even under skew** and it
returns the correctly-computed tip unchanged.

**Minimally over-broad by construction.** The guard fires in exactly the
collision case and never spuriously: a newer-minor journal whose new
conversational types are not above the reader's tip computes the correct tip and
does **not** degrade. So the common case is inert; degradation replaces a
silently-wrong offset (the U4 reattach hazard) with a distinguishable,
fork-handleable signal — loud-degrade, not lockstep. `reason` names the guard
(`:schema_ahead_unknown_loop_type` or equivalent) so the fork can fall back /
prompt / resume-after-update.

**Invariant this preserves (why Option A and not B/C).** The skew-guard is a
**reader-seam guard only** — no stored field, no write-path change, no new record
state. Therefore:
- the tip stays **derived-not-stored** (no second source of truth, no HEAD-lag
  class);
- the whitelist stays the **only door** (the closure rule, §1.1, is untouched);
- **P-JS2 / P-JS8 dual-oracle recompute** still hold — both oracles recompute the
  tip from immutable framing fields, so oracle independence (meta-inv 6) is
  intact; a stamped `tip_eligible` (Option C) would have collapsed both oracles
  to one source;
- the guard is **inert at same-version** (`minor == minor` ⇒ the `schema_version`
  precondition is false ⇒ the guard never fires), so every existing red and
  property (P-JS2/P-JS8, N-JS1/N-JS5/N-JS8) is unchanged. It is coverage added
  *above* the existing contract, never a modification of it.

The must-fail red is **N-JS-skew** (§1.3).

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
- **OQ-JS4 (live-delivery wire shape) — RULED: RATIFIED (V, 2026-07-16).** The
  reattach live tail is delivered as `{:reattach_live, session_id, record}`
  messages to the attaching process, where `record` is the full durable
  journal record (the same map `read/*` yields — NOT a projection). Frozen as
  the U4-R suite provisionally pinned it (its moduledoc). Grow-only: the tuple
  shape and arity are fixed; any future per-delivery metadata rides *inside*
  `record` (already grow-only per §1.1) or as a NEW message type, never by
  widening/reordering this tuple. This freezes only the *law-satisfying wire*
  — the closure law itself is P-JS5 (§1.2) and the no-publish-ahead ordering
  is I3 / N-JS7 (§1.3); the fan-out + permission BUS that produces these
  messages (AD-15 second half) is still unfrozen and tracked as OQ-JS6.
  - *Non-normative context (2026-07-17, changes no law):* the layered
    protocol work (`harness-bus-{protocol,encoding,transport}.md` + the
    `raxol_agent_client_protocol` package) recontextualizes this ratified
    tuple as exactly the **`(term × process)` cell** of the encoding ×
    transport matrix — the BEAM-local wire. The *portable/cross-language*
    wire for the same semantics is **ACP (Agent Client Protocol, Zed's
    editor↔agent JSON-RPC 2.0) + our `_raxol/session.load` extension with
    offset params riding `_meta["raxol.io"]`**. Everything ratified here
    stands unchanged; do NOT freeze this tuple as the cross-language wire —
    that role belongs to the ACP extension surface. (ACP here = Agent
    *Client* Protocol; unrelated to `raxol_earn` = Agent *Commerce* Protocol.)
- **OQ-JS5 (`attach` base-dir) — RULED: GROW THE ARITY NOW (V, 2026-07-16).**
  `attach/3`'s frozen shape gains a trailing optional `opts` keyword:
  `attach(session_id, offset, historyPolicy, opts \\ [])` where `opts` may
  carry `:base_dir` (session-dir root override; default = the
  `RAXOL_SESSIONS_DIR`-resolved path the FileStore already honors, §0 clause
  5). Ruled now, while cheap: arity is a one-way door, and §0-clause-5
  directory portability (tar + untar into a fresh base) makes an explicit
  base-dir a plausible near-term need; an omitted `opts`/absent `:base_dir`
  is byte-for-byte the current env-resolved behavior, so this is purely
  additive (optional-with-default, never optional→required). The U4-R
  self-containment red already pins the `RAXOL_SESSIONS_DIR` resolution; the
  `:base_dir` opt is the same seam made explicit.
  - *Implemented 2026-08-01.* `Raxol.Agent.Reattach.attach/4` now carries
    `opts \\ []` (`attach/3` preserved, so the U4-R suite is unchanged);
    `:base_dir` is threaded through `FileStore.session_dir/2` to both the
    history read and the live-tail dir. The same `opts` carries the OQ-JS6
    admission seam (`:authorize`, below).
- **OQ-JS6 (broadcast/permission bus — AD-15 second half) — RATIFIED
  (2026-08-01).** The status pointer's condition is met: the admission +
  fan-out layer landed in `raxol_agent_client_protocol` and survived its gates.
  Ratification targets THAT artifact (per the pointer), not a bespoke bus
  module. Full frozen shape, the two-wire boundary ruling, and the contour
  pointers are in **"AD-15 second half — admission + fan-out bus"** below.
- **OQ-JS7 (`:snapshot` reattach delivery) — RATIFIED (V, 2026-08-02).** The
  BEAM-local `:snapshot` history policy delivers a RESTORED MODEL (U9 checkpoint
  fold) synchronously in the attach RESULT map under a new `:snapshot` key,
  alongside a live record tail beginning at the model's fold horizon. The model
  rides a NEW channel (the synchronous result), never the `{:reattach_live, …}`
  tuple (OQ-JS4 forbids widening it). Full frozen shape + the fold-horizon
  no-gap/no-dup law + the no-checkpoint ruling are in **"`:snapshot` reattach
  delivery"** below.

#### AD-15 second half — admission + fan-out bus (RATIFIED 2026-08-01)

Ratifies OQ-JS6. The mechanism that gates **who** may attach and fans
`{:reattach_live, …}` to N subscribers is the `_raxol/*` extension in
`raxol_agent_client_protocol` — it survived its gates: 113 extension tests
(reattach 33, token 33, journal_writer 21, attach_policy 19, journal 7),
invariant families `J1–J12`, `P-BUS*`, `INV-AP1–20`, `CDI-*`, each positive
contour shipping a **named dead-injector**, drift-audited by
`torture/pbus_coverage_audit_test.exs`. The design specs it was built from
(`acp-*-design.md`, `harness-bus-protocol.md`) are deliberately un-checked-in;
the binding contract is the package `test/INVARIANTS.md` + the cited moduledocs.

**Frozen shape (the mechanism).**

- **One fail-closed funnel (CDI-1).** `Ext.AttachPolicy.Runner` is the SOLE
  admission point: it isolates the policy in a `Task.Supervisor.async_nolink`
  task with a bounded `yield` + `shutdown(:brutal_kill)`, so a hostile policy
  can neither block nor crash the bus, and every non-`{:ok, %Grant{}}` outcome
  DENIES (`-32000 "attach denied"`, CDI-5, no `data` — anti-oracle). One
  decision gates BOTH history and live (an attach = read access to the full
  durable record stream). The default policy `LocalNode` is deny-by-default;
  there is NO `AllowAll` module — the absent module is the guarantee (INV-AP3).
- **`RXC1` capability token (INV-AP*).** Offline-verifiable detached Ed25519
  over `"RXC1." <> b64url(claims)`; the `RXC1` prefix (inside the signed bytes)
  IS the algorithm binding — no `alg` field anywhere, so the `alg:none` /
  downgrade class is structurally unexpressible. `verify/4` is total + pure
  (clock injected, no I/O, never raises, never mints an atom). Authorizes an
  attach to a **writerless tar'd dir** from the token bytes + a shipped pubkey
  alone. Restrictive claims narrow access, never widen (enforce-if-present).
- **Register-before-`h` bus seam (J1/J2, bus §4).** Per attach: authorize →
  REGISTER (subscribe) FIRST → snapshot `h` (decision-time, read from the store,
  never a cached counter) → the monotone gate is armed with `h` BEFORE any live
  receive → emit `history(max(from,1)..h)` → reply (replay-before-respond) →
  steady state (`offset ≤ h` dropped forever, `offset > h` forwarded once).
  `from > h+1` is rejected (minting a gap is illegal). This is the wire-level
  realization of the P-JS5 closure law (§1.2).
- **Taint annotates, NEVER filters (J5, §6).** Every delivered frame carries the
  record's taint; no path drops/withholds/reroutes by taint — a taint filter
  would break `history ++ live == durable substream`. Kind-projection (§3.4) is
  the only projection, applied identically to history and live. `grant.lens` is
  reserved (v1 nil), threaded opaquely, never interpreted.
- **Mid-attach expiry (CDI-6).** A token grant's `exp` arms a per-subscriber
  timer that force-closes the held live tail at `expires_at`; process identity
  closes the timer-vs-reconnect race (each attach is its own subscriber whose
  timer targets only itself).

**The two-wire boundary ruling.** Admission is enforced at the process/trust
boundary, NOT symmetrically on every wire:

- **ACP boundary (untrusted peers) — HARD-GATED.** `session/load` (+ rider) and
  `_raxol/session.load` converge on `Ext.Reattach.attach/1`, which runs the
  Runner funnel before any read. An untrusted peer is admitted only via a valid
  `RXC1` capability (Token policy) or a transport `LocalNode` trusts. This is the
  security boundary.
- **BEAM-local `Raxol.Agent.Reattach` (in-process) — OPTIONAL SEAM, default
  trusted.** `attach/4` carries `opts[:authorize]` (an `authorize_fun`, default
  `{:ok, :in_process}`). Rationale: an in-process caller can
  `FileStore.Reader.scan` the session dir directly, so a gate on the function is
  bypassable — it is a SEAM for a host that fronts reattach with its own
  transport (inject a policy that defers to the ACP Runner / `AttachPolicy`), not
  a boundary. The seam is fail-closed (any verdict but `{:ok, grant}` →
  `{:error, :attach_denied}`, nothing read or tailed) so an injected policy
  cannot "mostly" admit. Negative control: the `:authorize`-denial test in the
  U4-R guards suite.
  - *Implemented 2026-08-02.* The ready-made policy-deferring authorizer is
    `Raxol.AgentClientProtocol.Ext.AttachPolicy.Bridge.authorizer/1`: it
    translates the BEAM-local attach ctx into the CDI-2 Runner ctx and returns
    the Runner's verdict verbatim, so a host wires
    `Reattach.attach(…, authorize: Bridge.authorizer(policy:, transport:))` to
    gate in-process attaches through the SAME fail-closed funnel. It lives in
    `raxol_agent_client_protocol` (which owns the Runner) and produces a plain
    closure, so the dep graph is unchanged (`raxol_agent` does not depend on it).

**Forward-compat.** Grows by: new `Grant` fields (optional; `lens` already
reserved), new token claims (grow-only, restrictive-narrowing), new `scope`
allow-list atoms, new `via` provenance, a future `RXC2` token version (new
prefix — never a signed-in `alg`). Never: an `AllowAll` policy module, a taint
filter on delivery (breaks closure), widening/reordering the frozen
`{:reattach_live, session_id, record}` tuple (OQ-JS4 — new per-delivery data
rides inside `record` or as a NEW message type), an `alg`/header field on the
token, or optional→required on any grant/claim field.

#### `:snapshot` reattach delivery (RATIFIED 2026-08-02)

Ratifies OQ-JS7. `:replay` and `:live` stream raw durable **records**; the
`:snapshot` history policy instead restores a folded **model** from the newest
U9 checkpoint and streams only the record tail the model does not yet cover. The
model is folded state, not a record, so OQ-JS4's `{:reattach_live, session_id,
record}` tuple cannot carry it — it rides a NEW channel. This ratifies THAT
channel and the anchoring law, for the BEAM-local wire
(`Raxol.Agent.Command.route(:attach, …)` → `Raxol.Agent.Reattach`).

**Frozen shape (the delivery).**

- **Model in the synchronous result (grow-only map, not a message).**
  `route/2` of an `:attach` command with `history_policy: :snapshot` returns
  `{:ok, %{snapshot: model, history: [], from_offset: H+1, live: pid}}` — the
  restored model under a new **`:snapshot`** key, ADDITIVE on the `attachment()`
  map `:replay`/`:live` already return (§0 only-grows). The `:snapshot` key is a
  synchronous sibling of the `:history` list `:replay` already delivers in the
  result (folded state is synchronous, like `history` — it is not an event), so
  it belongs in the result, never on the message channel. The
  `{:reattach_live, …}` tuple and the message wire are UNTOUCHED.
- **Live tail unchanged.** The record tail streams from `H+1` as the frozen
  `{:reattach_live, session_id, record}` tuple (OQ-JS4), delivered by the same
  read-side `Raxol.Agent.Reattach` tailer `:replay`/`:live` use.

**The fold-horizon law (no gap, no dup).** `H` is the offset up to which the
restored model already reflects the journal; the model ⊕ the live tail from
`H+1` reconstruct current-plus-future state with **no record both folded and
streamed** (no dup) and **none dropped** (no gap). `H` follows the landed U9
restore semantics, which are asymmetric by checkpoint kind:

- **snapshot-backed checkpoint** — restore folds the post-checkpoint tail
  forward, so `model == fold(0..T)` (P-JS4) and `H = T`, the RECORD horizon
  (highest record id at the decision-time read).
- **tip-only pointer** (`snapshot_ref: nil`, OQ-JS1) — restore folds `0..tip`
  only, so `model == fold(0..tip_offset)` and `H = tip_offset`; the
  post-checkpoint tail (`tip+1..`) is streamed live.

Anchored on ONE decision-time read: the SAME record set restores the model and
computes `H`, so a concurrent append lands strictly above `H` and is delivered
live exactly once — the P-JS5 closure law (§1.2) realized for the model channel.
A FIXED anchor is the named failure mode: always-`tip+1` double-delivers a
snapshot-backed checkpoint's tail (dup); always-`T+1` drops a tip-only pointer's
tail (gap).

**No-checkpoint ruling (strict).** A session with NO checkpoint returns
`{:error, :no_checkpoint}` — `:snapshot` is a restore-from-checkpoint fast path,
not a general resume. A caller without a checkpoint uses `:replay` (raw replay
from an offset) or `:live` (tail only); a caller that wants the fast path first
writes a checkpoint (`Raxol.Agent.Journal.Records.Checkpoint.write/3`) at a turn
boundary, then attaches `:snapshot`. A missing/corrupt snapshot surfaces
`{:error, :snapshot_missing}` / `{:error, :snapshot_corrupt}` (N-JS3) — NEVER a
silent fallback to replay (the N-JS3 dead injector).

**The two-wire boundary (mirrors OQ-JS6).** This frozen shape is the BEAM-local
`(term × process)` wire: `model` is Elixir-side folded state delivered in-process.
The cross-language surface carries the equivalent semantics over the ACP
`_raxol/*` extension (a `session/load` that returns folded state), NOT this
map/tuple — do not freeze this shape as the portable wire.

**Read-side, writerless-safe.** `:snapshot` reads through the tolerant Reader and
folds via the checkpoint restore seam (`restore_checkpoint/3`, which dereferences
only the session dir), opening no Writer — as writerless-safe as `:replay`/`:live`
(§1.1's reattach-is-read-side rule).

**Positive contour.** `snapshot ⊕ attach_live(H+1..) ==` the current model
folded forward over future records; no record is both folded into `snapshot` and
delivered live; the first live id is `> H`.

**Forward-compat.** Grows by: new optional keys on the attachment map (`:snapshot`
added here; a future `:lens`/projection key rides the same way). Never:
widening/reordering `{:reattach_live, …}` (OQ-JS4), making `:snapshot` a required
key on the `:replay`/`:live` results, or a silent no-checkpoint / corrupt-snapshot
fallback (the strict rulings above).

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
- `approval_decided` carries **no `actor` in its payload** — `envelope.actor` is
  the single source of truth (uniform-actor principle). Any decision-scoped view
  of "who decided" is derived at read time from the envelope, never stored on the
  payload (a payload copy would re-introduce the dual-location drift the
  uniform-actor seam exists to eliminate). Live enforcement state built on these
  records (e.g. U8's in-memory approvals) MUST be rebuildable by a fold over
  `approval_decided` events on replay/resume — the journal is the authority,
  the in-memory set is a projection.

#### `cost_ref` — spend correlation (spend-bearing records only)

Optional `cost_ref` appears **only** on spend-bearing records — `item_completed`,
the `probe_run` terminal (§3), and the `turn_completed` rollup — pointing into
the Ledger's reserve/settle identity. **Negative decision (frozen): no `bill_to`
per record.** The Ledger is the single money truth; billing is a **derived fold**
over Ledger + lineage subtrees (walk the R1 edges — R1 = session-lineage
edges, defined in `harness-future-foundations-ideation.md` §3.1, and landed
here as the §1.1 `meta.json parents` shape), never a per-record
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

- **`params_hash` canonicalization spec (normative, written once):** `sha256`
  over a canonical JSON serialization of the params object with **sorted keys**,
  produced by exactly ONE named normative serializer —
  `Raxol.Agent.Fingerprint.canonical_json/1` (to be implemented with U11-I;
  every golden fixture MUST hash through it, so two independent encoders cannot
  diverge). The excluded-ephemeral key list is **exhaustive and frozen**
  (grow-only): `request_id`, `idempotency_key`, `trace_id`, `timestamp`/`ts`.
  Everything else is included — in particular **`seed` is INCLUDED in the hash**
  (it is a sampling parameter; replay identity needs it). There is no open-ended
  "other per-call noise" exclusion: an ambiguous exclusion is not a contract.
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
| `speculation` | `%{phase, branch_ref, outcome, refs}` — `phase ∈ :begin\|:commit\|:rollback` (grow-only); `outcome ∈ :cleared\|:rejected\|:disagreed\|:timeout\|nil` | session | YOLO/tournament branch lifecycle (yolo-safe C2); at `:begin`, `refs` names **in-session** parent tip **offset(s) only** — plural stays legal for in-journal branches (a merge-commit over Option-B branches names N in-journal parents). **Cross-session merge parentage lives in lineage `:merge` edges (`meta.json`, §1.1-lineage), never in `refs`** — in-journal refs resolve only within the enclosing session (§2.1 session-scoping contract), so a cross-session parent has no legal `refs` slot; the limitation is explicit by design |
| `approval_decided` | `%{request_ref, decision, refs}` — `decision ∈ :approved \| :denied` (grow-only) | session | AD-14 decision record (G4); `actor` lives on the **envelope only** (single-source, uniform-actor principle), never in the payload; journaled so U8's "after deny, no later success" is a fold, not an honor system; tip-excluded (a trailing deny is not a resume point) |
| `policy_amended` | `%{scope, rule_id, before, after, source, refs}` — `source ∈ :human\|:calibrate\|:oracle` (grow-only) | session | journaled **BEFORE enforcement** (reserve-before-call applied to policy); U18-servo learned policies are `source: :calibrate` **rows, never a side file** |

**`refs` is frozen as the uniform annotation mechanism:** a required payload
key on every meta type — a list of journal offsets (`[non_neg_integer()]`,
may be empty) naming the loop event(s)/record(s) this meta event annotates or
derives from. (The protocol draft's `promote.journal_refs` unifies to `refs`;
that draft field never landed in code, so this is a pre-freeze naming
decision, not a rename.) `promote` additionally requires `refs != []` —
provenance-mandatory (protocol §3).

**Session-scoping contract (AF-1/OQ-U11.1 — permanent, load-bearing):** `refs`
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
6. **Gates fold taint, never read the stamped field (frozen law — the
   decision-time form of point 5; §0 clause 7):** any gate admitting a call
   on TrustedLineage grounds (YOLO clause-4, BlastRadiusGate taint
   escalation) MUST compute trust by folding this algebra over the call's
   `refs`/lineage at decision time; reading the stamped envelope `trust`
   value for an ADMISSION decision is forbidden. Rationale: OQ-U11.3 makes a
   taint miscount an alarm+marker (not a reject), so a mis-stamped `:trusted`
   event reads trusted until something folds — the stamped field is
   display/audit metadata, the fold is the security boundary. Echoed at the
   auto-approve predicate (§5.2); negative contour N-U11.11.

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

- **P-U11.1 codec round-trip — relabeled PROPERTY (AF-9), not a must-fail
  red:** every registry meta type round-trips through the JSON codec
  byte-stable (post-sanitize), including `scope`, `provenance`, `refs`.
  Round-tripping is naturally a property/oracle-independence test (encode
  then decode then compare), not a single-mutation red.
- **P-U11.2 grandfather decode — relabeled CORPUS TEST (AF-9), not a
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
  contour: N-U11.7 (AF-9).
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
  MAY name N **in-session** parent tip offsets in `refs`; a merge-commit
  speculation naming ≥2 in-journal parents round-trips and folds without any
  singular-parent assumption. Generator MUST include a ≥2-parent case (vacuous
  otherwise).

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
| N-U11.11 | a gate reads the stamped envelope `trust` for an ADMISSION decision instead of folding the algebra over `refs`/lineage (§2.1 point 6) | decision-time red fails: a mis-stamped `:trusted` event with tainted refs is admitted by the field-reading gate where the folding gate escalates/denies | gate variant reading `event.provenance.trust` directly — a mis-stamped `:trusted` event with tainted refs passes the field-reading gate, fails a folding gate |

### 2.4 Forward-compat note

- Grows by: new meta types (registry append), new provenance sources, new
  provenance keys, new trust lattice points (readers fail-closed to
  `:tainted` on unknown), new statuses inside `probe_run`, new `scope`
  values (AF-2, ratify-before-impl — readers render unknown scopes opaquely).
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
              max_parked: pos_integer(),         # pool-level cap on parked runs (AF-5); probe may override the pool default
              park_timeout_ms: pos_integer(),    # TTL a parked run may wait before terminating :exhausted (AF-5)
              # --- eval-first growth (2026-07-16, ratified; OPTIONAL, defaulted absent) ---
              sunset: String.t() | nil           # one-line delete-criterion, e.g. "delete when provider-native compaction matches on eval"
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

**`sunset` — the probe's own delete-criterion (eval-first, ratified 2026-07-16).**
Optional-with-default-absent (additive under §0), so no grandfathered probe
breaks. Every probe is scaffolding compensating for a current model weakness;
`sunset` states in one line *when that weakness is expected to expire and the
probe should be deleted* (e.g. `"delete when provider-native compaction matches
on eval"`). **Governing note:** every probe spec **SHOULD** declare a `sunset`;
**Wave-4 graduation REQUIRES** one (a probe with no sunset does not graduate).
Grandfathered C-probes (the existing C1–C7 / `:probe_c1_gate` … `:probe_c7`
sources, §2.1 registry) MUST gain a `sunset` line **at their next touch**. This
is the structural form of the eval-first meta-pattern — anything built atop model
behavior carries a measured exit criterion (see `harness-eval-first-analysis.md`
§4.2/§5, and the eval gate at §6 below).

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
  # module fails submit. Parking is BOUNDED (AF-5) — see max_parked/
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
  shape (AD-6a — AD-6a = reserve-before-call, child of parent AD-6, defined in
  `harness-synthesis.md`): reserve `estimate = max_output_tokens +
  uncached_prompt_estimate` **before** each provider call; settle actuals
  after. Fail-closed: no reserve ⇒ no call, ever.
- **Settlement is internal, not part of the probe interface (AF-4,
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
- **Bounded parking (AF-5 fix, load-bearing):** "never drop, never fail
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
- **Saturation observability (frozen — the backpressure observable):** when a
  run parks, or the parked set sheds (`max_parked` overflow / `park_timeout_ms`
  expiry), the Runner emits telemetry
  `[:raxol, :agent, :probe, :saturation]` with counts (parked, shed, running),
  AND the `probe_run{status: :parked}` / `:exhausted` events already journal
  the facts. A caller CAN therefore distinguish "accepted and running" from
  "accepted and parked/shed" via `status/2` and the `probe_run` stream —
  **`submit`'s `{:ok, run_id}` is an acceptance receipt, not an execution
  promise.** Saturation is never silent: it is observable both live
  (telemetry) and durably (the journaled lifecycle).

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
   freedom.) The parked set is bounded (AF-5, see Budget above) —
   `max_parked`/`park_timeout_ms` — so "never drops" and "bounded" hold
   simultaneously.

### 3.2 Positive contour

Governing dispositions: AD-6a (reserve-before-call), FI-5 (taint), the
economic law (cache-riding), D2 (in-BEAM pool), roadmap U12 acceptance.

- **P-U12.1 lifecycle completeness:** every submitted run produces exactly
  one `:started`-or-`:parked` and exactly one terminal `probe_run` event;
  journal fold over `probe_run` yields a consistent state machine per
  run_id. Negative contour: N-U12.8 (AF-9 — closes the gap where N-U12.4 only
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
  Negative contour: N-U12.9 (AF-9).

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
| N-U12.10 | submit pumped past `max_parked`, or a parked run left past `park_timeout_ms` (AF-5) | parked-set size stops growing at `max_parked` (excess runs still receive a terminal `probe_run{status: :exhausted}` — never silently discarded); a parked run past TTL terminates `probe_run{status: :exhausted}` | Runner variant with no cap/TTL check — parked set grows unbounded under sustained budget exhaustion |

N-U12.10 is **additive** to N-U12.3, not a replacement: submit-time
saturation still returns `{:ok, run_id}` and parks (never a synchronous
failure); N-U12.10 only bounds how long and how many runs may sit parked.

**Parking precedence (frozen):** if a run cannot be parked because `max_parked`
is exceeded, it terminates `:exhausted` (**never `:parked`**) — still exactly one
terminal `probe_run` event. `max_parked` dominates the parking state: budget
exhaustion parks, but a full parked set overrides parking with `:exhausted`.

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
  run without an ordering hazard. **Partial-failure rollback (frozen):** if
  the run-level reserve is refused after the session-level reserve
  succeeded, the session-level reservation is RELEASED before the run parks
  — no leaked session budget. Negative contour: an injector that leaks the
  session reservation on run-refusal must fail a budget-conservation red
  (the session budget fold returns to its pre-submit value).
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
`client_msg_id`. **Dedup window = session lifetime.** The **journal is the dedup
truth**: an accepted command carries its `client_msg_id` in the resulting durable
event's payload (`turn_started.payload` grows an optional `client_msg_id` linking
the turn to its client message), so the set of seen keys is a fold over the
journal. The ingest seam's dedup state is an **in-memory index rebuilt by fold on
restart/replay** — a re-delivery of the same `(session_id, client_msg_id)` after
a BEAM restart still deduplicates, because the index is reconstructed from the
durable events, not held only in RAM. The idempotent accept for a duplicate is a
**live ack referencing the original turn, NOT a second durable event** — a
duplicate never appends to the journal (so a re-sent, only-live-acked message
never re-emits a durable `turn_started`). The command's `actor` comes from the
attach/auth context (cross-ref §2.1 actor producer-seam stamping). Offset-derived
keys are forbidden (they break under replay/compaction); the key is generated
client-side at write time.

### 5.2 `effect_class` + `egress` — the action reversibility taxonomy

Frozen here as the contract source of truth (the field itself lives in the F2
`Raxol.Action` draft, still unfrozen; this freezes the *taxonomy* those reds
depend on):

```
effect_class ∈ :reversible_local | :bounded_sandboxable | :irreversible_external
egress:        boolean
```

**Auto-approve predicate (inlined, normative here):** a call **escalates**
(requires human approval) iff `effect_class == :irreversible_external` **OR**
`egress == true`; otherwise it is **YOLO-applicable over trusted lineage** (see
`harness-yolo-safe-research.md` §2/§7 for the full model). `:irreversible_external`
is the irreducible always-escalate class (no lineage, oracle, or calibration
overrides it), and `egress` is the exfil leg of the lethal trifecta. Enforcement
is **structural, compiled in our own tree** — never self-reported by an untrusted
MCP tool (the `destructiveHint`-is-a-lie class, yolo-safe N-Y5).

**Decision-time fold law (echo of §2.1 taint point 6 / §0 clause 7):** the
"trusted lineage" leg of YOLO-applicability is established by folding the taint
algebra over the call's `refs`/lineage at decision time — never by reading the
stamped envelope `trust` field. A gate that admits on the stamped value fails
N-U11.11.

**F2 dependency:** `effect_class`/`egress` live in the not-yet-landed F2
`Raxol.Action` draft — reds that assert `effect_class`-keyed escalation carry
`@tag :action_surface` until F2 lands.

---

## 6. Eval gate (ratified 2026-07-16)

Folded from V's external-cohort ruling (`harness-eval-first-analysis.md`,
disposition binding). This is additive under §0 — it adds an **acceptance bar**
to probes and an **exit criterion** to U13; it renames and repurposes nothing.

The governing meta-pattern: **every abandoned scaffold in the cohort was a
compensator for a model weakness that expired; every survivor had a falsifier.
Anything built atop model behavior needs a measured exit criterion.** The probe
`sunset` field (§3) states the criterion; this section states how it is measured.

- **Journal-replay eval set (the instrument).** The eval is journal-replay-based
  and rides infra that is ~80% already present: the replay closure (P-JS5, §1.2)
  plus the FI-2 log-head version tags (`{harness_version, model, config_hash}`).
  It is named as a roadmap unit (**U23 eval harness** — see the numbering flag in
  `harness-eval-first-analysis.md` §4.4: V's ruling said "U22", but U22 is the
  already-landed asciicast fix, so the eval unit is U23).
- **Probe acceptance bar (new).** A probe is accepted **only if it beats a null
  baseline on the eval set** — "beats do-nothing" is the floor. A probe whose
  signal does not clear the null baseline does not ship.
- **U13 A/B is an exit criterion (new).** The C1 reasoning-gate's A/B test (score↔
  benefit correlation) is promoted from someday-nice-to-have to a required exit
  criterion — it is the falsifier the C1≈Cognition-"Smart-Friend" echo was
  missing (`harness-eval-first-analysis.md` §2, echo a).
- **The eval unit gates Wave 4.** The probes (U13–U18) do not graduate without
  the eval harness in place: it is the measurement surface for every probe's
  `sunset` and acceptance bar.

This gate does not alter any frozen schema; it constrains *which* probes may
graduate, not *what* the probe/meta/journal records look like.

---

## 7. Amendments — adversarial review #569

> **PA-1 is RATIFIED by V (2026-07-16) and PROMOTED to frozen law** — the tip
> skew-guard now lives in §1.4 (rule + invariant) and §1.3 (must-fail red
> N-JS-skew). PA-1 below is retained as the ratification record / options
> analysis; the binding text is §1.4/§1.3.
> **PA-2..PA-10 remain PROPOSED — NOT YET FROZEN, awaiting separate V
> ratification.** Each is a **constitution one-way-door**; none is binding until V
> ratifies it, and until then the frozen law is §0–§6 (incl. the promoted PA-1).
> These are drafts responding to the automated adversarial review on PR #569
> (personas: Saboteur / Security Auditor / New Hire). The two clean
> doc-consistency clarifications (closure-rule prose, §1.1; skip-unknown carve-out,
> §0.2) were applied inline and marked "clarified per AF review #569" — they
> change no law, only remove literal-reading traps; V may still veto them.
> Everything in PA-2..PA-10 is a **contract ruling** and is drafted-not-applied.
> PA-2..PA-5 respond to that automated pass; **PA-6..PA-10 respond to the second,
> net-new adversarial pass (adversarial review 2026-07-16, DROOdotFOO)** and
> follow the same additive lane.

### PA-1 (HIGH) — RATIFIED 2026-07-16, promoted to §1.4/§1.3 — the only-grows law does not protect tip stability across version skew

**Problem (Saboteur, §0.3 + §1.1 closure + §1.4).** The tip is DERIVED by each
reader from *its own compiled* CONVERSATIONAL whitelist. Adding a member is a
`schema_version` MINOR bump (additive, legal). A record of the newly-whitelisted
type written by a `1.y` writer is legitimately conversational and may be the
highest-offset conversational record — i.e. the tip. A `1.x` reader (UI fork, not
lockstep-updated) lacks that type in its whitelist, so it **skips** the record in
its tip scan (the §0.2 reader-tolerance rule) and selects an *older* record as
tip. The two readers disagree on the tip of the *same* journal. §0.3 promises
"readers built against 1.x read all later 1.y" and §1.4 says the tip predicate
"can read forward" — **both are false for the tip specifically.**

**Root cause (the load-bearing insight).** Skip-unknown is safe for
associative/commutative **folds** (a dropped record degrades the result
consistently) but the tip is an **`argmax`-by-offset selection** — dropping the
max element does not degrade the answer, it *changes* it to a wrong one.
Reader-side tolerance was written for folds; it does not hold for the one
selection operation in the contract. §1.4 already forbids *removing* a member
("removal would silently move historical tips"); the **symmetric additive case
moves tips for older readers just as much** — it was simply never named.

**Consequence.** U4 reattach/resume lands at the WRONG offset under version skew.
The freeze's central promise — "a separate UI fork never needs a lockstep update"
— is FALSE for all tip-derived behavior. This is exactly the failure the freeze
exists to prevent, so it must be closed before red suites are authored.

**Options considered.**

| Option | What it costs the UI fork | Preserves no-lockstep promise? | Interaction with ratified tip law |
| --- | --- | --- | --- |
| **A. Skew-guard: older reader degrades the tip LOUDLY when a hidden newer tip is possible** (recommended) | Zero cost to READ/FOLD/RENDER. On a newer-minor journal, tip-derived *resume* returns a distinguishable `:tip_uncertain` result **only** when an unknown loop-event type sits above the reader's computed tip; the fork then falls back / prompts, instead of silently landing wrong. | **Refines it honestly:** no lockstep to keep reading; a lockstep is needed only to *resume at the tip of a newer-minor journal that actually collides*. Loud-degrade replaces silent-wrong. | **Clean.** Tip stays DERIVED, RECOMPUTABLE, dual-oracle-checkable; whitelist stays the only door; branch-awareness untouched. Adds a reader-seam GUARD only — no stored field, no write-path change. Inert at same-version (minor==minor), so every existing red/property (P-JS2/P-JS8/N-JS*) is unchanged. |
| **B. CONVERSATIONAL additions become MAJOR bumps, not minor** | Every new turn-signal type (an `item_started`-class addition) becomes a breaking major; a `1.x` reader is walled out of a `2.0` journal *entirely*, even when the new type is nowhere near the tip. | **No** — converts silent-divergence into an explicit version-wall; makes lockstep REQUIRED for all conversational-vocabulary growth. | **Reverses ratified text.** §0.3 ("a minor bump = additive growth") and §1.1 ("adding a member is a minor bump") both flip; breaks AD-11 upcast-on-read (major implies migration). Heaviest constitutional change of the three. |
| **C. Tip computed version-robustly (writer stamps `tip_eligible` per record)** | Zero ongoing cost; a `1.x` reader reads the `1.y` writer's stamps and gets the *correct* tip under skew — the only option that truly *preserves* correct tips, not just degrades. | **Yes**, strongest form. | **Violates ratified tip law twice.** (1) "The tip is a derived position, NEVER a stored field … storing it is the HEAD-lag bug class" — stamping the predicate result is storing tip computation at write time. (2) Fatally, P-JS2/P-JS8 determinism is verified by **two independent oracles both recomputing** the tip (meta-inv 6 oracle independence); a stamped bool collapses both oracles to one source — the derived-not-stored law is *what makes* the tip dual-oracle-checkable. Also needs a grandfather predicate-fallback for unstamped records, so it doesn't even fully escape version-coupling. |

**RECOMMENDATION: Option A (the skew-guard), in its precise form. — RATIFIED by V,
2026-07-16; promoted to §1.4 (rule + invariant) and §1.3 (N-JS-skew).** It is the
only option that keeps *every* ratified property intact (derived-not-stored,
dual-oracle recomputability, positive-whitelist closure, branch-awareness) while
making the freeze's promise *true* instead of false. It buys safety by converting
a silent-wrong-offset into a loud, fork-handleable degrade — the same
fail-closed philosophy as §0.7 and the taint lattice. Option C trades away the
ratified oracle-independence that the whole tip-determinism suite rests on; Option
B nukes minor-only growth. Neither is worth it.

**Precise guard condition (minimally over-broad).** A reader need NOT degrade on
every higher-minor journal — only when a hidden newer tip is actually possible.
After computing its best tip on a branch `b`, the reader degrades **iff** there
exists a higher-offset record on `b` with `kind == "event" ∧ family == "loop" ∧
type ∉ (the reader's own known loop-type registry)` — i.e. a type that *could* be
a CONVERSATIONAL member the reader cannot see. If every trailing record past the
computed tip is a *known* non-conversational record (checkpoint, meta, idle, or a
known-excluded loop type such as `woken`), the reader's tip is **provably
correct even under skew** and it does not degrade. So in the common case — a
newer journal whose new conversational types are not near the tail — the fork
computes the correct tip and never degrades; degradation fires exactly in the
collision case, and never spuriously.

*(The three text blocks below are the as-proposed drafts, now **PROMOTED** —
the §0 carve-out, the §1.4 rule, and the N-JS-skew red are live in-doc. Retained
here verbatim as the ratification record.)*

**Text — amend §0 (the UI-fork promise) [PROMOTED].** Appended to the §0 preamble:

> *Carve-out (PA-1): the "never needs a lockstep update" promise covers
> reading, folding, and rendering a newer-minor journal — all of which stay
> healthy. It does **not** promise a correct **tip** (an `argmax` selection, not
> a fold) when a newer minor may have whitelisted a conversational type the
> reader cannot see. In that collision the reader MUST return a distinguishable
> degraded tip (`:tip_uncertain` / offset-with-`:maybe_stale_under_skew`), never
> a silently-older offset. This is loud-degrade, not lockstep: the fork keeps
> working and resumes at the tip once updated.*

**Text — amend §1.4 (Never / reader-ignores) [PROMOTED].** Added to the "Never"
bullet, alongside the existing removal clause:

> *…adding a CONVERSATIONAL member is a legal minor bump, but a reader at an
> older minor MUST apply the tip skew-guard (PA-1): additive whitelist growth
> moves the tip forward for newer readers, and an older reader that cannot see
> the new type MUST degrade the tip loudly rather than select a silently-older
> one. (Removal moves historical tips for everyone and stays forbidden; addition
> moves tips only across skew and is neutralized by the skew-guard, not by
> barring the addition.)*

And to the "ignores safely" list, replace the tip clause with:

> *…the tip predicate as frozen — additions to CONVERSATIONAL ship as minor
> bumps a same-or-newer reader reads forward; an **older**-minor reader applies
> the PA-1 skew-guard (degrade, never silently-older).*

**New contour [PROMOTED — live at §1.3 as N-JS-skew].** A must-fail red
**N-JS-skew**: a `1.x` reader computing a tip on a `1.y` journal whose highest
conversational record is an unknown-to-`1.x` loop type MUST return the degraded
result, never the older offset. Dead injector: a reader variant that falls
through to the older offset silently. This is inert at same-version, so it adds
coverage without touching any existing red.

### PA-2 (HIGH) — `$redacted` is an unauthorized, unattributable evidence-destruction primitive

**Problem (Security Auditor, §0.6 + §1.1 `$redacted`).** The sole legal rewrite
of the append-only audit log carries **no authorization, actor, or approval**.
The `$redacted` payload is `%{reason, at_ts}` only. The one operation that
destroys evidence in an integrity-critical journal is the *least* gated act in
the contract, while `promote` (a mere knowledge rollup) mandates a human
`approval_decided` and `refs != []`. There is no `redaction` meta event recording
*who* authorized the scrub, no envelope `actor` binding, and no negative contour
asserting an unauthorized redaction is rejected.

**RECOMMENDATION (draft — contract ruling, needs ratification).** Gate the
rewrite *additively* (no optional→required flip on the payload marker itself):

1. **New `redaction` meta type** (grow-only, §2 registry): payload
   `%{target_offset, target_id, reason, actor, authorized_by, at_ts}`, emitted
   `family:meta`, stamped with the envelope `actor` (§2.1). The `$redacted`
   value stays `%{reason, at_ts}` (unchanged, so no framing/hash disturbance),
   but a legal redaction MUST be **accompanied by** a `redaction` meta event that
   binds the actor and authorization.
2. **Producer-seam law:** a `$redacted` rewrite with no matching `redaction`
   meta event on the journal is a producer-seam reject — the redaction act is
   unauthorized-by-construction. (Reader seam stays tolerant: a lone
   `$redacted` value already in a historical journal still renders as an opaque
   tombstone; this gates the *act*, not the *tolerance*.)
3. **New must-fail red N-JS-redact:** an unauthorized/actor-less redaction is
   rejected; dead injector = a rewrite path that scrubs a payload without
   emitting the `redaction` meta event.

This mirrors the existing `promote` gating (human approval + non-empty refs) and
brings the most destructive operation up to at least the provenance bar of the
least destructive one. It is additive (new meta type + new contour), so it fits
under only-grows without reversing §0.6.

### PA-3 (MEDIUM) — cache-riding prefix byte-identity is undefined for parked runs

**Problem (New Hire/Saboteur, §3.1 vs Bounded parking, §3).** Cache-riding
requires a prefix "byte-identical to the primary loop's *most recent* request
prefix at `tip_offset`." A run may be parked up to `park_timeout_ms`, by which
time the primary loop has advanced — the contract never says whether byte-identity
is measured against tip-at-submit or the live primary. A parked run riding a
stale prefix cannot cache-hit, quietly defeating the economic premise (P-U12.3).

**RECOMMENDATION (draft).** Freeze the ride target to a **fixed offset captured
at submit**: the prefix is byte-identical to the primary's request prefix at the
`tip_offset` observed **when the run was submitted/parked**, not the live primary
at execution time. Rationale: the ride target must be immutable for byte-identity
to be testable-without-a-provider (§3.1's own test hook: capture two built
requests, compare). A run whose fixed target has been invalidated by primary
advance rides a *known* offset and simply may miss the live cache — an accepted,
*predictable* cost, versus an undefined one. Add one frozen sentence to §3.1 and a
property that the ride prefix equals the submit-time tip prefix.

### PA-4 (MEDIUM) — cross-branch tip validation has no negative contour

**Problem (Saboteur, §1.1 same-branch-tip vs §1.3 N-JS1).** §1.1 requires a
checkpoint's `tip_offset` to name a conversational record on the checkpoint's
*own* `branch_id`. N-JS1's dead injector only covers a tip pointing at a
*non-conversational* record; N-JS8 covers the tip *scan* dropping `branch_id`. A
checkpoint whose `tip_offset` names a *conversational record on the wrong branch*
has no must-fail red — that bug ships green.

**RECOMMENDATION (draft).** Add a must-fail red **N-JS-xbranch**: appending a
checkpoint whose `tip_offset` names a conversational record on a `branch_id`
other than the checkpoint's own is `{:error, :cross_branch_tip}` at the
constructor/append seam (no record appended, offset counter untouched — same
shape as N-JS1). Dead injector: a checkpoint constructor that validates
`conversational?` but omits the same-branch clause. Purely additive contour.

### PA-5 (MEDIUM) — taint entry-classification is unfrozen with no negative control

**Problem (Security Auditor, §2.1 taint point 2).** The derivation algebra is
robust, but *which* sources are tainted is per-deployment policy "NOT frozen
here," with **no negative contour / dead injector** at the `tool_result`
producer. Two implementations can legally disagree on what is tainted, and the
mutation suite cannot catch a mis-classification at the source — the fail-closed
lattice is only as sound as an out-of-contract policy the reds never exercise.

**RECOMMENDATION (draft — narrow).** Keep *which* sources are tainted as policy
(that judgment is genuinely deployment-specific and should stay unfrozen), but
freeze the **existence and fail-closed default** of classification and give it a
dead injector: (a) every `tool_result` MUST carry an entry-trust classification
(absence ⇒ fail-closed `:tainted`, never untainted-by-omission); (b) a must-fail
red **N-U11-classify**: a producer that emits a `tool_result` with no entry-trust
classification, or defaults it to `:trusted`, is rejected. This freezes the
*contract of the boundary* (a classification exists and fails closed) without
freezing the *policy content* (which sources) — closing the "no negative control
at the source" gap while respecting the deliberate policy carve-out.

### PA-6 (HIGH) — CAS pointer deref has no runtime confinement (traversal via `$blob` / `snapshot_ref`)

**Problem (adversarial review 2026-07-16, DROOdotFOO — HIGH 1; §0.5 + §1.1
`$blob` / checkpoint `snapshot_ref`).** Self-containment (§0 clause 5) is
enforced only by a fixture lint scan; the runtime deref rules never require the
reader to validate that a pointer is a bare content hash confined to the session
dir. N-JS3-family reds cover *missing/altered* blobs, not a pointer that
**escapes** (`{"$blob": "blobs/../../../../etc/passwd"}`). An `:import`ed or
corrupted journal feeds attacker-controlled pointers straight into the tolerant
reader seam — "deref-or-render-opaque" today derefs first.

**Proposed frozen text (draft — contract ruling, needs ratification).** Added to
§1.1 reader tolerance, governing BOTH deref paths — `$blob` deref and checkpoint
`snapshot_ref` resolution at restore:

> *CAS deref confinement: a CAS pointer is well-formed iff it matches
> `^(blobs|snapshots)/[0-9a-f]{64}(\.json)?$` (`blobs/<sha>` bare;
> `snapshots/<sha>.json`), AND the path resolved against the session directory
> (canonicalized, symlinks not followed) stays strictly inside it. A
> non-conforming pointer is NEVER dereferenced: the reader renders it as an
> opaque tombstone under N-JS3 semantics (`{:error, :ref_escape}` family at the
> deref seam; journal stays `:ok`, nothing read, nothing deleted). The producer
> seam rejects writing a non-conforming pointer loudly.*

Check-then-deref, belt and suspenders: the regex is the contract; the
resolved-containment check catches encodings the regex author didn't foresee.

**New contour.** Must-fail red **N-JS-traversal**: a journal fixture
(`:import`-lineage flavored) carrying (a) a `$blob` with `../` segments and (b) a
checkpoint whose `snapshot_ref` escapes the session dir — the reader/restore
path MUST perform zero filesystem reads outside the session dir and render both
refs opaque. Dead injector: a deref that joins the pointer onto the session dir
without validation.

**Adoption cost.** One validation function at two deref call sites; zero schema
change; every conforming pointer (all existing fixtures) is byte-for-byte
unaffected. Purely additive under §0.

### PA-7 (HIGH) — snapshot redaction does not remove the secret in v1

**Problem (adversarial review 2026-07-16, DROOdotFOO — HIGH 2; §1.1 `$redacted`
+ FI-7 + OQ-JS2).** Redacting a snapshot-referenced value "produces a NEW
snapshot file; the pre-redaction file may be deleted under FI-7 consent" — but
GC is deferred entirely (OQ-JS2), so for all of v1 the pre-redaction snapshot —
the secret, content-addressed, on disk — is never deleted. The one legal rewrite
scrubs the payload *value* and leaves the snapshot *bytes* recoverable. Distinct
from PA-2 (authorization): a fully-authorized redaction still fails to redact.

**Proposed frozen text — PRIMARY variant (synchronous deletion; draft, needs
ratification):**

> *Redaction of snapshot-referenced content is complete only when the
> pre-redaction CAS file is gone: the redaction act (1) writes the
> post-redaction snapshot (FI-8 atomic), then (2) synchronously deletes the
> pre-redaction `snapshots/<sha>.json` in the same act — never deferred to GC.
> The referencing checkpoint is not rewritten; the dangling pointer surfaces
> `:snapshot_missing` (N-JS3), already the accepted cost. A crash between (1)
> and (2) leaves the old file as a loud, retryable INCOMPLETE redaction — never
> silently considered done.*

**FI-7 analysis (why this is not the forbidden delete).** FI-7 forbids deletion
*implicitly* — as a side effect nobody asked for. Redaction is the contract's
one explicit, consented destruction act (§0 clause 6; PA-2 adds actor +
authorization + a `redaction` meta event). Deleting the pre-redaction bytes is
not a new deletion power; it is the *completion* of the deletion the consent was
FOR. Scrubbing the pointer while keeping the bytes is redaction theater.

**FALLBACK variant (documented no-op), if V rejects deletion:** freeze the
honest warning instead — *"snapshot redaction in v1 does NOT remove the secret
bytes; the pre-redaction CAS file persists until FI-7 GC ships. Do not rely on
`$redacted` for PII/secret scrubbing of snapshot content."* — so nobody builds
compliance on a scrub that doesn't scrub. **V picks the variant.**

**New contour (deletion variant).** Must-fail red **N-JS-redact-cas**: after an
authorized snapshot redaction, the pre-redaction bytes are absent from the
session dir, and restore via the old checkpoint surfaces `:snapshot_missing` —
never the secret. Dead injector: a redaction path that writes the new snapshot
but leaves the old file.

**Adoption cost.** Deletion variant: one file removal inside the already-atomic
redaction act + an incomplete-redaction retry surface; no framing/offset/hash
disturbance (the checkpoint record is untouched). Fallback variant: zero code,
one loud sentence.

### PA-8 (HIGH) — GC truncation can orphan taint lineage (`refs` / `armed_by`)

**Problem (adversarial review 2026-07-16, DROOdotFOO — HIGH 3; §1.1
low-watermark + §1.1-schedule + §2.1 taint).** The taint algebra folds over
`refs` (§2.1 point 4) and `schedule.armed_by`. GC may truncate any prefix below
the watermark, and the frozen no-orphan law covers only *checkpoints*. A tainted
ancestor truncated below the watermark becomes unreadable to the decision-time
fold — and the contract never says whether an unreadable ref target folds
`:tainted` or `:trusted`. GC the tainted ancestor and the descendant launders by
truncation, defeating §2.1 point 3. GC is deferred, but `refs`/`armed_by` freeze
NOW.

**Proposed frozen text (BOTH halves, belt and suspenders; draft, needs
ratification):**

> *1. (Prevention — companion to "GC never orphans checkpoints", §1.1)
> GC/truncation never orphans a live `refs`/`armed_by` target above any
> surviving descendant: it never removes a record that any surviving record
> at/above the watermark names — directly or transitively — via `refs` or
> `armed_by`. A `gc` proposal that would sever a surviving record's
> taint-lineage closure is rejected at the same synchronous admission seam as
> `:invalid_tip` (§0 clause 7).*
> *2. (Containment — if prevention fails) a `refs`/`armed_by` target that
> cannot be read (below the watermark, missing, damaged) folds **fail-closed
> `:tainted`** — never `:trusted`, never skipped. Same fail-closed family as
> unknown trust values (§2.1 point 1) and the §0.2 fold carve-out.*

Half 1 keeps lineage foldable; half 2 guarantees that even a buggy or hostile
truncation can only make the fold MORE conservative, never launder.

**New contour.** Must-fail red **N-JS-gc-taint**: (a) a journal whose surviving
descendant refs an offset below the watermark — the decision-time fold yields
`:tainted`; (b) a `gc` proposal severing a live `refs`/`armed_by` closure is
rejected, nothing truncated. Dead injectors: a fold that skips unreadable refs
(fails open); a GC acceptor that checks only checkpoint coverage.

**Adoption cost.** Half 2 is one branch in the fold, testable today. Half 1
constrains the future GC ruling (OQ-JS2) and costs nothing while
`low_watermark = 1`; when GC lands it may keep tainted prefixes alive longer or
force a lineage-summary design — that trade is exactly what V is ratifying.

### PA-9 (MEDIUM) — §5.1 `client_msg_id` has zero negative contour + an unbounded index

**Problem (adversarial review 2026-07-16, DROOdotFOO — MED 4; §5.1).** §5
carries no must-fail reds at all. A duplicate is deduplicated as a
live-ack-only, journal-silent accept — indistinguishable, at the seam, from a
silent swallow; no contour asserts a second durable event is impossible. And the
in-memory index "rebuilt by fold" over a session-lifetime window carries no
frozen bound.

**Proposed frozen text (draft, needs ratification):**

> *Observability: the duplicate's live ack carries a grow-only dedup marker —
> `%{dedup: true, original_turn_id, original_offset}` — so the collision is
> observable at the seam that produced it, plus telemetry
> `[:raxol, :agent, :ingest, :dedup_hit]`. A duplicate NEVER appends any record
> — not even a meta event (a journaled duplicate-marker would let a replayer
> bloat the journal without ever passing dedup); the ack is the observability
> surface, the journal stays silent.*
> *Index bound: dedup is guaranteed over the readable suffix
> `[low_watermark, n]` — the index is exactly the fold §5.1 already freezes, and
> a fold cannot see below the watermark. While `low_watermark = 1` (all of v1,
> until GC ships), this IS the frozen session-lifetime window, verbatim. When GC
> ships, a key whose only occurrence was truncated MAY be accepted as new — an
> accepted cost to be stated loudly in the GC ruling, same class as the dangling
> snapshot pointer.*

*(Consistency note — why NOT "pruned at the compaction boundary": AD-3b freezes
compaction=resume=one artifact — a compaction is a `checkpoint` record in the
SAME journal (§1.1 "deliberately NOT kinds"), not a fresh session artifact, so a
compaction boundary would prune keys the fold can still see and break the
rebuilt-by-fold law. The watermark is the boundary at which folds* legally
*lose sight; the index bound must be that boundary.)*

**New contour.** Must-fail red **N-cmd-dedup**: re-delivering
`(session_id, client_msg_id)` — including across a BEAM restart (index rebuilt
by fold) — yields exactly one durable `turn_started` (journal byte-identical
after the replay, offset counter untouched) AND a live ack carrying the dedup
marker naming the original turn. Dead injectors: an ingest seam that appends a
second `turn_started`; an ack without the marker (silent swallow); an index not
rebuilt on restart.

**Adoption cost.** Grow-only ack fields + one telemetry event; no journal schema
change; the index bound is a definition, not new code, while `low_watermark = 1`.

### PA-10 (MEDIUM) — schedule missed-wake semantics on resume are unfrozen

**Problem (adversarial review 2026-07-16, DROOdotFOO — MED 5; §1.1-schedule).**
The record freezes `next_fire`/`armed` and the lifecycle enum grows `:dormant`,
but nothing specifies firing when a dormant session resumes with `next_fire` in
the past: once? per-missed-interval (thundering herd)? drop? The record shape is
frozen; the firing law the reds need is absent.

**Proposed frozen text (draft, needs ratification):**

> *Missed-wake law (fire-ONCE-on-resume, coalescing): when a session resumes
> (or the scheduler restarts) and an armed schedule's `next_fire` lies in the
> past, the trigger fires exactly once — never once per missed interval, never
> silently dropped. The resulting `woken` event's payload grows an optional
> grow-only field `missed_fires: non_neg_integer()` (default `0`): with `m ≥ 1`
> scheduled fire times in the past, the single coalesced wake carries
> `missed_fires: m - 1`, so the skip is durable, observable, and foldable.
> After the coalesced fire, a recurring trigger's `next_fire` recomputes forward
> from NOW — missed intervals are never replayed. `once` triggers fire the one
> time and disarm as already frozen. `woken.refs` MUST still include the
> schedule offset; the §1.1-schedule taint law is unchanged.*

**New contour.** Must-fail red **N-sched-coalesce**: resume a dormant session
whose armed cron trigger is `m ≥ 2` fire-times past — exactly one `woken` event
appears, with `missed_fires: m - 1` and the schedule offset in `refs`, and
`next_fire` is strictly in the future afterward. Dead injectors: a wake loop
emitting `m` `woken` events (the herd); a resume path that silently advances
`next_fire` without firing (the drop); a wake payload lacking the count.

**Adoption cost.** One grow-only payload field + a coalescing branch in the wake
path; `missed_fires` default `0` keeps every normal wake byte-compatible. Purely
additive under §0.

### LOW items (noted, not drafted)

- **§1.1 `consent_class` enforcement (Security, LOW).** "Sharing/export honors
  `consent_class`" names no enforcer and no dead injector; `policy_amended`
  ordering vs a concurrent decision-time gate fold is unpinned. Recommend a
  follow-up contour once an export/sharing seam exists; deferrable — no red is
  authored against it yet.
- **§1.1 GC covering-checkpoint (New Hire, LOW).** Restoring from an *old*
  checkpoint whose `tip_offset` was truncated below `low_watermark` relies on a
  "covering checkpoint" that is not defined. Already `@tag :gc` deferred (OQ-JS2);
  fold the covering-checkpoint definition into the GC ruling when GC lands.
- **Self-containment of the constitution (New Hire, MEDIUM).** Load-bearing
  obligations `meta-inv 1/2/5/6` and numerous `AD-*/FI-*` IDs are referenced but
  never enumerated here; they live in `harness-invariants.md`, which is not frozen
  by this doc. Recommend **version-pinning** those siblings (a commit/rev pin
  block in §0) rather than inlining all of them — a freeze doc should pin every
  obligation it makes binding. Drafted as a recommendation; the pin block itself
  awaits V's call on which rev to pin.

---

