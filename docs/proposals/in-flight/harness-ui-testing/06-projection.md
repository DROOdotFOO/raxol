# 06 — Projection & Block-Model Spine: Test Design

Date: 2026-07-15 · Status: test-design draft (pre-implementation)
Area owner: the **block-model spine** — T4 (HarnessBlock), T7 (journal-fold
projection), T26 (streaming markdown), T13a (fixture assembly), plus the
**fixture format** the whole `harness-ui-testing/` suite records against.

Sources: `harness-spec-protocol.md` (the Envelope/Event/Command contract, two
tiers, validation seam), `harness-ui-roadmap.md` v2 (T4/T7/T26/T13a specs +
D-PA), `harness-ui-methodology.md` (fixtures = permanent regression harness),
`harness-ui-research/triad-*.md` (T13 fake-green, T7 identity), agent-lane
`harness-storage-research.md` FI-12 (the Dormammu test).

**Reality check (grounded 2026-07-15):** the contract in
`harness-spec-protocol.md` is a **spec draft — it does not exist in code yet**.
No `Envelope`/`Event`/`Command` structs, no unified codec, no projection.
Existing raw material the contract will unify: `Raxol.Agent.Stream.Event`
(the 7 loop types), `Raxol.Agent.ThreadEvent`/`ThreadLog` (append-only journal),
`SessionStreamer`. **A markdown renderer already exists** —
`Raxol.UI.Components.MarkdownRenderer` (lib/raxol/ui/components/, 544 LOC, full
component contract + `render_with_builtin/2` + `inline_segments/1`), with a
419-line test that already asserts marker-leakage (`refute … =~ "*"`) and width
invariants. **T26 is not net-new: it extends MarkdownRenderer with a
streaming/provisional-close path + seal-time full parse.** So this suite is
written *against the contract*, test-first: the fixtures and properties are the
executable specification the T4/T7/T26/T13a builders implement to. Module names
below are expected targets; reconcile at build time (projection/block likely
`Raxol.Harness.{Projection,Block}` under the UI lane; markdown streaming extends
the existing `Raxol.UI.Components.MarkdownRenderer`).

### Test harness — grounded in the existing suite (agent-verified 2026-07-15)

| need | existing facility to reuse |
|---|---|
| property tests | `StreamData ~> 1.1` + `use ExUnitProperties`; `property "…" do check all(g <- gen, max_runs: 200..500) do … end`. Shared gens in `Raxol.Test.PropertyGenerators` (test/support) — extend, don't fork. |
| element-tree render asserts (P-MD, block bodies) | MarkdownRenderer test pattern: local recursive `flat_texts/1` + `flat_leaves/1` over the `%{type: :column\|:row\|:text, children, content, style}` tree; `assert full_text =~ …`, `refute full_text =~ "*"` for marker leak. |
| byte-stream asserts (P-E2E-04, T2b) | `Raxol.Test.CrossTerminal.RenderOracle` (test/support/cross_terminal): `Oracle.emit(prev,next)`, `changed_rows/2`, exact-CUP `=~ "\e[2;1H"`, `grid_diff == grid_full`. The established byte layer — P-E2E and the substrate suite share it. |
| golden snapshots | FATE pattern: committed refs `priv/fate/golden.refs`, `Raxol.FATE.{load_refs,verify,run}`, regen `mix raxol.fate --gen`, `assert FATE.run() == FATE.run()`. Our `<name>.blocks.json` + `mix raxol.harness.fixtures.bless` mirrors it. |
| terminal-output capture (T13a) | `Raxol.Test.TestUtils.capture_terminal_output/1` (group-leader→`StringIO`); `assert_render_event/2`, `refute_render_event/1`. |
| byte-exact numeric fixtures | module-attribute reference table (`@darcula_baked`, salience_test.exs) — pattern for any hex/width oracle. |
| global-state isolation (T13a assembly) | `use Raxol.Test.IsolatedCase` (setup runs `IsolationHelper.reset_global_state/0`) for runtime singletons; pure projection/block tests stay `use ExUnit.Case, async: true`. |
| JSONL load | precedent: asciicast_test splits on `"\n"`, `Jason.decode!/1` per line (Jason = project JSON lib). |

---

## 0. The six risks this suite exists to kill

| # | Risk | Primary killers |
|---|---|---|
| R1 | Projection non-determinism (same journal → different block list) | P-DET-* determinism property |
| R2 | Ephemeral deltas leaking into durable blocks | P-TIER-*, N-SEAL-* |
| R3 | Fold state corrupting across rebuilds | P-FOLD-*, identity definition |
| R4 | Mid-stream markdown flashing raw syntax / crashing on partial input | P-MD-*, N-MDFUZZ-* |
| R5 | T13a green with stub rendering (triad fake-green) | P-E2E-* content asserts + N-STUB mutation gate |
| R6 | Fixture format rotting (too coupled to today's event shapes) | §1 versioned schema + upcast + forward-compat N-FWD-* |

Everything below serves one or more of these. A test that can pass while its
risk is live is a bug in the test.

---

## 1. Fixture format (the load-bearing decision)

### 1.1 Schema decision: versioned JSONL of Envelopes, both tiers recorded

**A fixture is the recorded *bus stream*, not the journal.** The journal
persists only the durable tier (spec §5); but to test the two-tier *separation*
we must replay the ephemeral `item_delta` traffic too. So the fixture records
**both tiers** — every `%Envelope{}` that crossed the bus, in arrival order.
The projection-under-test is responsible for routing durable→blocks and
ephemeral→tail; the fixture gives it the chance to get that wrong.

Format: **JSONL** (one JSON object per line). Line 1 is a **header record**;
every subsequent line is one serialized Envelope.

```jsonc
// line 1 — header (FI-2: every transcript version-tagged)
{"record":"header","schema":"harness-fixture/1","envelope_v":1,
 "harness_version":"0.x.y","backend":"anthropic","model":"claude-…",
 "config_hash":"…","recorded_at":"2026-07-15T…Z","name":"multi-tool-turn",
 "kind":"golden|adversarial","notes":"hand-authored: orphan item_completed at id 7"}

// line N — one Envelope (spec §2/§3)
{"record":"envelope","v":1,"session_id":"s1","kind":"event",
 "body":{"id":42,"turn_id":"t1","ts":170…,"family":"loop","type":"item_completed",
         "tier":"durable","scope":"session",
         "provenance":{"source":"primary","trust":"trusted"},
         "payload":{"item_id":"i3","item_type":"tool_result","content":"…"}}}
```

Rationale for JSONL over one big JSON array:
- **append-friendly** — a `Recorder` streams lines as events cross the bus; a
  crash leaves a valid partial fixture (all complete lines still parse).
- **offset = line number** — `attach{from_offset}` / `seek{to_offset}` map to
  "start at line K", so replay-from-offset tests are trivial to author.
- **diffable** — golden fixtures live in git; a one-event change is a one-line
  diff in review.
- **hand-authorable** — adversarial fixtures are written by hand; JSONL is the
  only format a human edits comfortably.

### 1.2 Loader & the upcast story (R6 — the anti-rot mechanism)

`Raxol.Harness.Fixture.load/1` reads header → validates `schema` +
`envelope_v` → maps each line through the **same codec the runtime uses**
(`decode/1`, per spec §6). Two consequences, both deliberate:

1. **Fixtures go through the real validation seam.** A malformed line in a
   *golden* fixture is a loud load-time failure, not a silently-skipped line.
   A malformed line in an *adversarial* fixture is the point (see §4).
2. **Upcast, never mutate.** When the contract grows (spec §7, methodology R6:
   contract-only-grows), old fixtures stay byte-frozen on disk. `load/1` runs
   `Fixture.Upcast.to_current(envelope_v, envelope)` which fills new fields
   with declared defaults (new optional field → default; never rename/remove
   while dependents in flight). The upcast is a pure `vN → vCurrent` function
   with one clause per version bump; each bump adds a clause + a fixture that
   was recorded at the old version and must still load+project. **The frozen
   bytes + a regenerable block-list snapshot are the regression anchor.**

Golden **block-list snapshots** (the projection output, §3) are stored beside
each fixture as `<name>.blocks.json`. They regenerate only on an *intentional*
projection change, gated by review — a snapshot churn in a PR that didn't mean
to touch projection is the tripwire.

### 1.3 Recording tooling

- `Raxol.Harness.Fixture.Recorder` — a bus subscriber (PubSub topic per
  session, spec §2) that serializes every Envelope to JSONL + writes the
  header from the live `{harness_version, backend, model, config_hash}`.
  Used to capture *golden* sessions from real runs.
- Adversarial fixtures are **hand-authored JSONL** (no recorder) — malformed
  by construction, checked in with a `notes` field explaining the pathology.

### 1.4 Canonical golden sessions (the frozen set)

Six fixtures are canonical; the suite must keep all six green. They span the
event-shape space so contract growth that breaks one is caught:

| name | shape | exercises |
|---|---|---|
| `simple-chat` | 1 turn, 1 message, deltas → completed | baseline determinism, tier split |
| `multi-tool-turn` | 1 turn: reasoning + 2×(tool_use,tool_result) + message | item ordering, block kinds, fold |
| `long-folds` | ~30 turns, fold defaults set, replay from mid-offset | rebuild identity, position preservation, offset replay |
| `unicode-heavy` | CJK + emoji ZWJ + combining + RTL in message & tool output | width-safe rendering, no panic on grapheme boundaries |
| `markdown-stream` | one real markdown doc streamed delta-by-delta | T26 provisional-close at every prefix, seal = full parse |
| `adversarial` | interleaved: out-of-order, dup, orphan, missing turn_started, trailing meta record, late delta, one unknown item_type | the entire negative suite's recorded companion |

`simple-chat`, `multi-tool-turn`, `long-folds` are also the **T13a** assembly
fixtures. `adversarial` is authored so each pathology is at a documented
offset (in `notes`) — negative tests seek to it.

---

## 2. The projection identity (precise, per T7 — kills the fake-green ambiguity)

The triad's T7 finding: "identical transcript" is meaningless until *identity*
is defined. **Definition, binding for every determinism property:**

```
identity(fixture) = { durable_block_list, fold_defaults }
```

- `durable_block_list` — the ordered list of `%Block{}` derived from
  `family: :loop, tier: :durable` block-producing events, each block a pure
  function of its source events + its **fold default**.
- `fold_defaults` — the per-kind default fold state the projection assigns
  (e.g. reasoning folds by default, message expands). Part of identity.
- **NOT in identity:** UI-local fold *toggles* (a user expanded block 3),
  scroll position, the live tail buffer, ephemeral deltas, salience/prominence
  (D-PA-scoped, tested elsewhere), meta-family events.

Two things must never leak into each other:
1. A UI-local fold toggle must **not** change identity (so rebuild is stable).
2. A `fold_default` change **must** change identity (so it's a reviewed diff).

This definition is the spine of §3.1 and the reason N-DORM (§4) can be precise.

---

## 3. POSITIVE suite

Test IDs: `P-<CAT>-NN`. Library: `StreamData` (`~> 1.x`, present in main +
raxol_agent). Property tests use `property/1` + `check all`; example tests use
canonical fixtures.

### 3.1 Determinism — P-DET (R1)

| ID | kind | statement |
|---|---|---|
| P-DET-01 | property (fixtures) | For every canonical fixture F: `project(F) == project(F)`. Pure function, no ambient state. |
| P-DET-02 | property (fixtures) | `identity(project(F)) == load("<F>.blocks.json")` — output matches frozen snapshot. |
| P-DET-03 | property (generated) | For generated valid session S (gen §5): `identity(project(S))` is invariant under **N replays**. |
| P-DET-04 | property (fixtures+gen) | Replay-from-offset: for all valid offsets k, `identity(project(replay(F, from: k)))` restricted to blocks sealed at ≥k equals the corresponding tail of `identity(project(F))`. (T7 "rebuilds identically from offset 0" generalized to any offset.) |
| P-DET-05 | property (generated) | **Ephemeral-shuffle invariance:** inserting/removing/reordering any `item_delta` events leaves `identity` unchanged. (Deltas are not identity.) |
| P-DET-06 | property (generated) | **Meta-noise invariance:** interleaving arbitrary `family: :meta` events leaves `durable_block_list` unchanged (0 blocks derived from meta). Sets up N-DORM. |

Generators feed P-DET-03/05/06; fixtures feed P-DET-01/02/04. P-DET-04 is the
one most likely to catch a rebuild bug (R3) and is the property the agent-lane
attach/replay path depends on.

### 3.2 Two-tier separation — P-TIER (R2)

| ID | kind | statement |
|---|---|---|
| P-TIER-01 | property (fixtures+gen) | `count(durable blocks of block-producing kinds) == count(item_completed of those kinds)`. Independent of `item_delta` count. Deltas create **zero** durable blocks. |
| P-TIER-02 | property | For each item: the **tail's final rendered state** (deltas accumulated) equals the **sealed block's content**, and the sealed block's content is sourced from `item_completed.content` (spec §5: `item_completed` carries final content, the tail is a throwaway preview). |
| P-TIER-03 | example (`simple-chat`) | Project with the delta stream vs. project with all `item_delta` stripped → identical `durable_block_list`. (The "lost on detach, rebuilt-from-nothing is fine" invariant.) |
| P-TIER-04 | property | No durable block's content contains a partial/provisional artifact — sealed content is only ever the completed content, never a mid-stream fragment. |

P-TIER-02 is subtle and load-bearing: it asserts the sealed block trusts
`item_completed.content`, not the concatenated deltas. A well-formed fixture
has them agree; the *adversarial* fixture has one item where they disagree
(late/dropped delta) — that case is N-SEAL-01.

### 3.3 Fold round-trip + position — P-FOLD (R3)

| ID | kind | statement |
|---|---|---|
| P-FOLD-01 | property | Pre-seal: `fold(unfold(block)) == block` and `unfold(fold(block)) == block` (round-trip, T4). |
| P-FOLD-02 | example (`long-folds`) | Toggling fold on block K preserves scroll anchor / the block above K stays put (position preservation, roadmap P3). |
| P-FOLD-03 | property | A UI-local fold toggle does **not** change `identity` (§2 leak-guard #1). |
| P-FOLD-04 | property | Changing a `fold_default` **does** change `identity` (§2 leak-guard #2) — regression tripwire, asserts snapshot churn on intentional change. |
| P-FOLD-05 | example (`long-folds`) | Rebuild from offset 0 restores `fold_defaults`, discards UI-local toggles (identity-stable rebuild). |
| P-FOLD-06 | property | Post-seal fold behavior matches the **D-PA policy** (frozen / re-emit / live-region-only) — parameterized on the D-PA verdict; the test reads the policy, asserts the matching branch. Until D-PA lands, runs against all three as `@tag :d_pa_pending`. |

### 3.4 Streaming markdown — P-MD (R4, T26)

T26 **extends `Raxol.UI.Components.MarkdownRenderer`** with a streaming path;
these tests reuse its existing test conventions (local `flat_texts/1` /
`flat_leaves/1` over the element tree, `refute full_text =~ "*"` marker-leak
checks). The existing 419-line `markdown_renderer_test.exs` already covers the
*complete-input* leak/width cases — P-MD adds the **partial-input** axis.

Corpus: a small set of real markdown docs under `test/fixtures/markdown/`
(one with nested fences, one table-heavy, one deep list + emphasis, one
unicode-heavy) — harvested from real agent tool-output, not synthetic. The
**prefix generator** (§5) yields every delta-boundary prefix and a sample of
byte prefixes.

| ID | kind | statement |
|---|---|---|
| P-MD-01 | property (prefixes) | At **every** prefix of a corpus doc, the provisional render contains **no raw markers** — no visible ```` ``` ````, no unbalanced `**`/`_`, no bare table pipes rendered as syntax. (The remend/provisional-close pattern, render-only.) |
| P-MD-02 | property (prefixes) | Provisional render never raises and returns within a bounded step budget (no hang) for every prefix. |
| P-MD-03 | example (`markdown-stream`) | Sealed render (full doc) == full-parse render — provisional close is discarded at seal, source never mutated. |
| P-MD-04 | example | An unclosed table streams as a **scrollable block**, never a zero-width collapse (roadmap T26 accept). |
| P-MD-05 | property | Provisional-close is monotone-ish: appending a delta never *removes* already-rendered committed content (no from-scratch flashing of earlier lines). |
| P-MD-06 | example (`unicode-heavy` md) | Width computed via `Raxol.UI.TextMeasure`, never `String.length`; CJK/emoji in a fenced block don't corrupt the block frame. |

### 3.5 T13a end-to-end byte assertions — P-E2E (R5, the anti-stub)

The `HarnessSurface` app composed over a fixture, byte-captured (native
scrollback bytes + footer region). **These tests assert on CONTENT, not
presence** — that is the entire point (triad fake-green finding).

| ID | kind | statement |
|---|---|---|
| P-E2E-01 | example (`multi-tool-turn`) | The **actual text** of each sealed message/tool_result block appears in the captured history bytes (assert the tool-result body string, a reasoning-block string, a markdown-rendered message string — ≥3 distinct real contents). |
| P-E2E-02 | example | Strip fields render the fixture's values: session cost, context %, turn stage — assert the numbers, not the presence of a strip. |
| P-E2E-03 | example | Composer echoes typed input verbatim (bracketed-paste with a newline lands as one block per T11). |
| P-E2E-04 | example | Sealed blocks land in native scrollback (byte-capture asserts T2b invariant end-to-end: no rewrite of prior block lines at constant width) — reuses the substrate suite's capture helper. |
| P-E2E-05 | example (`long-folds`) | Fold/jump on replayed content works: jump to block K scrolls to it; folded block shows one-line summary + outcome row content. |
| P-E2E-06 | example | Each block **kind** renders its real body: diff block shows real diff hunks, approval block shows the real action/blast-radius text — not a `[diff]` placeholder. |

**Content-anchoring rule:** every P-E2E assertion names a specific string that
originates in the fixture payload. An assertion of the form
`assert render =~ "block"` or `assert length(blocks) == 5` is **forbidden** in
this section — presence asserts are what let stubs pass.

---

## 4. NEGATIVE suite

Test IDs: `N-<CAT>-NN`. The projection's contract under bad input:

> **reject-or-recover, never silently mis-render.** Every recovery emits a
> diagnostic (telemetry event `[:raxol, :harness, :projection, :recovered]`
> with `%{reason, event_id}`), and the resulting `durable_block_list` is still
> deterministic. Silence + wrong output is the only failing outcome.

### 4.1 The recovery policy (defined, so tests can assert it)

| condition | tier | policy |
|---|---|---|
| Malformed envelope (schema violation) | at codec seam | **reject loud** — `decode/1 → {:error, reason}`, never reaches projection (spec §6). |
| Duplicate event (same `id`) | projection | **idempotent** — second application is a no-op; diagnostic. |
| Out-of-order `id` (lower after higher) | projection | **drop loud** — not applied; diagnostic. Journal offset is monotonic; a regression is a bug upstream, surfaced not swallowed. |
| Orphan `item_completed` (no `item_started`) | projection | **render as block** — `item_completed` is durable + carries content, so it is renderable alone; block flagged `provenance: recovered`; diagnostic. |
| Missing `turn_started` | projection | **synthetic turn** — items attach to a synthesized turn container; diagnostic. |
| Interleaved turns | projection | **group by `turn_id`**, not arrival order; no diagnostic (legal per contract). |
| Late `item_delta` after `item_completed` | projection | **drop loud** — never appended to the sealed block; diagnostic (N-SEAL). |
| Unknown `item_type` / block `kind` | projection | **opaque block** — render kind label + raw content, never crash (contract-only-grows, N-FWD). |
| Non-conversational record as rebuild tip | projection | **never selected** — tip is the last `family: :loop, tier: :durable` block-producing record (N-DORM / FI-12). |

### 4.2 Adversarial event streams — N-ADV (generators)

| ID | kind | statement |
|---|---|---|
| N-ADV-01 | property (gen corruptions) | For any corruption combination applied to a valid session (dup, out-of-order, orphan, missing turn_started, interleave), projection produces a deterministic block list AND emits a diagnostic for each recovered condition. Never raises. |
| N-ADV-02 | property | Out-of-order id → the offending event is not in any block's source set; block list equals the list from the in-order stream minus the dropped event. |
| N-ADV-03 | property | Duplicate id → identical block list to the de-duplicated stream (idempotence). |
| N-ADV-04 | example (`adversarial` @ orphan offset) | Orphan `item_completed` → exactly one recovered block with correct content + `provenance: recovered`. |
| N-ADV-05 | property | Interleaved turns → blocks grouped by `turn_id` in first-seen turn order; no cross-turn content bleed. |

### 4.3 Dormammu / non-conversational tip — N-DORM (R2/R3, mirrors FI-12)

The agent-lane FI-12: resume tip-finding must never select a non-conversational
record as tip (root cause: untyped records defaulting to valid-tip, 593K tokens
burned). **UI-lane analogue:** rebuild/resume must never fold a
non-conversational journal record into a durable block, and the "current tip"
the UI resumes at must be the last *conversational* block.

| ID | kind | statement |
|---|---|---|
| N-DORM-01 | property | A journal ending in a run of `family: :meta` records (gate_decision, calibrate, promote) rebuilds to a block list whose **last block is the last `family: :loop` conversational record** — the trailing meta records produce zero blocks and are never the tip. |
| N-DORM-02 | property | No `family: :meta` event ever appears in `durable_block_list` regardless of interleaving (strengthens P-DET-06 into a safety assertion). |
| N-DORM-03 | example (`adversarial` @ trailing-meta offset) | Rebuild-from-offset landing on a meta record does not fold it; the resumed view's tip is the prior conversational block. |
| N-DORM-04 | property | An **untyped / unknown-family** record (the literal FI-12 root cause) is treated as non-conversational: not a block, not a tip; diagnostic emitted. **Type-driven selection, never default-to-renderable.** |

### 4.4 Delta-after-seal — N-SEAL (R2)

| ID | kind | statement |
|---|---|---|
| N-SEAL-01 | example (`adversarial` @ late-delta offset) | A late `item_delta` for an already-`item_completed` item is dropped; the sealed block content is byte-identical to before the late delta; diagnostic emitted. |
| N-SEAL-02 | property | For any position of a late delta after seal, sealed block content == `item_completed.content` (the delta never leaks into durable). |
| N-SEAL-03 | property | The late delta also does not resurrect the live tail for that (completed) item. |

### 4.5 Markdown fuzz — N-MDFUZZ (R4)

| ID | kind | statement |
|---|---|---|
| N-MDFUZZ-01 | property (`StreamData.binary()`) | Arbitrary bytes → provisional render never raises, returns within step budget, produces *some* safe output (printable/escaped). |
| N-MDFUZZ-02 | property | Arbitrary byte **prefixes of valid markdown** (truncate a corpus doc at a random byte, incl. mid-multibyte-grapheme) → never raises, no raw-marker leak, no hang. |
| N-MDFUZZ-03 | property | Pathological nesting (N open fences, N `**`, deep list) up to a bound → bounded time + memory, no stack blow-up. |
| N-MDFUZZ-04 | property | Adversarial width (zero-width joiners, RTL overrides, control chars) → block frame integrity preserved, width via `TextMeasure`. |

### 4.6 Forward-compat unknown kind — N-FWD (R6, contract-only-grows guard)

Distinguish two layers (they have *opposite* policies):
- **Envelope/event TYPE at the codec seam** → strict; an unknown top-level
  `Event.type` is a version mismatch, handled by `Envelope.v` + upcast, else
  loud error (spec §6). Tested by the fixture loader/upcast path.
- **Vocabulary within a known event** (`item_type`, block `kind`,
  view-descriptor node — T23) → **graceful opaque render** (contract-only-grows;
  T23 accept: "out-of-vocabulary node = typed error block, not a crash").

| ID | kind | statement |
|---|---|---|
| N-FWD-01 | example (`adversarial` @ unknown-item_type offset) | `item_completed` with an `item_type` not in today's vocabulary → renders an **opaque block** (kind label + raw content preserved), never crashes, deterministic. |
| N-FWD-02 | property | A fixture recorded at `envelope_v = current` with an added optional field (simulated future contract) still loads, upcasts, and projects to a stable block list (old UI tolerates new fields). |
| N-FWD-03 | example | A future block `kind` (T23 agent-generated descriptor) outside the bounded vocabulary → typed error/opaque block, not eval, not crash. |
| N-FWD-04 | property | Upcast round-trip: `to_current(v_old, e_old)` projects identically to the same session re-recorded at current version (no behavior change from version bump alone). |

### 4.7 T13a stub detection — N-STUB (R5, the meta-test)

The mutation gate that makes P-E2E honest: if a block body renderer is replaced
with a stub, the P-E2E suite **must fail**. This is a test *of the tests*.

| ID | kind | statement |
|---|---|---|
| N-STUB-01 | mutation (`@tag :mutation`) | Inject a stub renderer (block body → `"[block]"`) via a test-only override; run the P-E2E suite; assert it **fails** (≥1 P-E2E test red). If P-E2E stays green with a stub, N-STUB-01 fails — surfacing the fake-green. |
| N-STUB-02 | mutation | Stub the strip renderer (fields → `"—"`); assert P-E2E-02 fails. |
| N-STUB-03 | mutation | Stub the markdown renderer (body → escaped raw source); assert P-E2E-01 (content) fails. |

N-STUB runs in a dedicated `mix test --only mutation` lane (not default suite —
it deliberately breaks rendering). CI runs it as a separate green-must-be-green
job: N-STUB passing means "the anti-stub asserts have teeth."

---

## 5. Generators (StreamData)

All under `Raxol.Harness.Fixture.Gen` (test support). Composable; every
generated session is assigned monotonic `id`s post-hoc so id-order is a
separable axis (corruptions perturb it deliberately).

| generator | produces |
|---|---|
| `loop_event()` | one well-formed `%Event{family: :loop}` of a random type |
| `item(kind)` | `item_started` → `[item_delta …]` → `item_completed` with content == concatenated deltas (well-formed invariant) |
| `turn()` | `turn_started` → `[item …]` (message/reasoning/tool_use+tool_result) → `turn_completed` with usage/cost |
| `session()` | `[turn …]`, ids assigned monotonically, valid by construction |
| `ephemeral_noise(session)` | inserts extra `item_delta` at random points (feeds P-DET-05, P-TIER) |
| `meta_noise(session)` | interleaves `family: :meta` events (feeds P-DET-06, N-DORM) |
| `untyped_record()` | a record with unknown/absent family (FI-12 root cause; N-DORM-04) |
| `corrupt(session, ops)` | applies ops ∈ {`shuffle_ids`, `dup_event`, `drop_item_started`, `drop_turn_started`, `interleave_turns`, `late_delta`, `trailing_meta`, `unknown_item_type`} — the negative-stream generator (N-ADV) |
| `markdown_prefixes(doc)` | every delta-boundary prefix + sampled byte prefixes (incl. mid-grapheme) of a corpus doc (P-MD, N-MDFUZZ-02) |
| `garbage()` | `StreamData.binary()` + control-char-weighted bytes (N-MDFUZZ-01) |

**Shrinking matters:** `corrupt/2` composes StreamData generators (not
post-hoc mutation of a fixed list) so a failing case shrinks to the *minimal*
corruption that breaks projection — the debugging payoff.

---

## 6. Five highest-value tests

1. **P-DET-04** (replay-from-any-offset identity) — the single property that
   proves rebuild/reattach can't diverge; every agent-lane attach/seek path
   leans on it. If one test survives, this one.
2. **N-DORM-04** (untyped record never a block/tip) — the literal FI-12
   root cause ported to the UI; type-driven selection, not default-to-render.
3. **P-TIER-02** (sealed content == `item_completed.content`, tail is
   throwaway) — the mechanical two-tier law; kills delta-leak (R2) at the source.
4. **P-MD-01** (no raw-marker leak at *every* prefix) + **N-MDFUZZ-02**
   (byte-prefix fuzz never crashes) — together they make streaming markdown
   safe on adversarial partial input, the highest-crash-risk surface.
5. **N-STUB-01** (mutation gate) — the test that keeps T13a honest; without it
   the whole P-E2E section can rot into presence-checks and nobody notices.

---

## 7. Open questions (for the orchestrator / D-PA)

1. **D-PA gates P-FOLD-06.** Post-seal fold behavior (frozen / re-emit /
   live-region-only) is undecided until T0's verdict. Tests are written
   parameterized; the golden `.blocks.json` for `long-folds` can't freeze its
   post-seal expectations until D-PA lands. Everything else is D-PA-independent.
2. **Orphan `item_completed`: render vs. drop.** §4.1 chose *render as
   recovered block* (content is present, dropping loses data). Confirm this is
   the desired policy vs. drop-loud — it changes N-ADV-04's expectation.
3. **Codec ownership of fixtures.** Fixtures load through the real `decode/1`.
   That means the T7 suite has a hard dep on the (unbuilt) codec seam. Option:
   a thin `Fixture.decode/1` shim that mirrors the seam until the real codec
   lands, then delete it. Recommend the shim so T7 tests aren't blocked on the
   full contract PR.
4. **Where does `%Block{}` and the projection live?** Assumed
   `Raxol.Harness.{Block,Projection,Markdown,Fixture}`. If the block model
   lands inside `raxol_agent` (contract is there) vs. the UI package, the test
   file locations move. Flagged for the naming decision at build time.
5. **Markdown corpus provenance.** P-MD needs 4–5 real markdown docs as
   fixtures. Recommend harvesting from actual agent tool-output (a real diff, a
   real table, a real nested-list plan) so the corpus reflects production
   distribution, not synthetic markdown.
6. **Snapshot regeneration policy.** `.blocks.json` snapshots regenerate on
   intentional projection change via `mix raxol.harness.fixtures.bless` — model
   it directly on the FATE precedent (`priv/fate/golden.refs` +
   `mix raxol.fate --gen` + `assert run() == run()`). Add the review rule that
   snapshot churn without a projection-code diff blocks the PR. **Decision:
   reuse the FATE harness or stand up a parallel one?** Recommend parallel (the
   fixtures are event-level, not pixel-hash-level) but borrow its `--gen` UX.
