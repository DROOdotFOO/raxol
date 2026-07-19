# Harness Spec — Backend (the core)

Date: 2026-07-15
Status: spec draft. The headless harness core: owns 100% durable state, runs the loop + the probe
swarm, emits the protocol. Conforms to `harness-spec-protocol.md`. Grounded in `harness-design.md`,
`harness-synthesis.md` (AD/FI dispositions), `harness-facts-two-perspectives.md`.

---

## 0. The one invariant

**The core owns 100% of durable state; every UI owns nothing persistent (L5).** The moment
session/checkpoint/policy state lives in a UI layer, alt-surfaces stop attaching cleanly and the
durable seat is given away. Everything below serves this.

---

## 1. Process topology (OTP tree, per session)

```
Session.Supervisor  (:rest_for_one — order matters)
├── Journal            durable append sink (the source of truth, L4)
├── Dispatcher         the loop; SOLE live model owner (dispatcher.ex:24); unified typed emit
├── EmitBus            wired SessionStreamer — PubSub + SSE, both populations, protocol §2
├── Projections.Supervisor   the plural materialized-view fleet (DynamicSupervisor, growable)
│   ├── Projection.Model         the TEA model (fast render read-model)
│   ├── Projection.Rules         C2 when→then rules
│   ├── Projection.Memory        C2 session memory
│   ├── Projection.Worktracks    C2 kanban
│   └── …promoted classes…       fluid ontology adds/removes at runtime
├── Gates
│   ├── SpendGate         per-run/session/lifetime cap, atomic reserve (Ledger pattern)
│   └── BlastRadiusGate   FS/shell/DB reserve before Port.open, fail-closed (AD-6)
└── Probes.Supervisor    the second population — Oban-scheduled background workers (C1–C7)
```

`:rest_for_one`: Journal must outlive Dispatcher; a Dispatcher crash restarts it + the bus +
projections *from the journal*, not from nothing.

---

## 2. The keystone commit (do this first)

Today three entry paths behave three ways; the async one is a live bug:

- generic input → broadcasts via Registry (terminal-driver input only, dispatcher.ex:359-390)
- agent-message → `send(runtime_pid, :render_needed)` only, no broadcast
- **command-result** (async LLM chunks, shell, ticks = *most* agent activity) → **emits nothing**
  (`process_command_result/2`, dispatcher.ex:525-551); model updates silently, even the local
  renderer doesn't refresh.

**Unify `process_app_update/3` + `process_command_result/2` behind one typed emit** →
`Journal.append` (durable tier) + `EmitBus.publish` (both tiers). One small commit, three payoffs:
fixes the live no-observer bug, creates the event stream, is the protocol's outbound half. It is
also what makes the probe swarm *possible* — probes are observers on this stream; without the
command-result emit they're blind to exactly the async/shell activity C2/C5/C6 must watch.

```elixir
# one seam both fold sites call
defp emit(state, %Event{} = ev) do
  if ev.tier == :durable, do: Journal.append(state.journal, ev)
  EmitBus.publish(state.bus, ev)
  state
end
```

---

## 3. The loop = the primary population

- **Turn = one fold cycle.** `update(msg, model) -> model` is the fold; `turn_started` → items →
  `turn_completed` bracket it. Explicit `Command` types keep the loop *visible* — validated against
  the LangChain backlash whose #1 grievance was *"no way to inspect or modify agent state during
  execution"* (Octomind ripped it out). Do **not** add a graph/DSL over control flow (NC-1).
- **Interrupt = supervised kill (AD-1).** Process-per-turn; `interrupt` command terminates the
  supervised turn subtree. Closes "Stop doesn't stop it" — vendor-confirmed (Cursor #162740),
  self-identified safety issue, closed not-planned at Anthropic (#50665). Cooperative flags can't
  interrupt a running shell; a supervisor kill can.
- **Steer = distinct message (AD-2).** `steer` injects at the next safe tool boundary; never the
  same path as interrupt, never a queue the loop must remember to poll.
- **Continuity-token discipline (AD-5)** enforced at the codec (protocol §6).

---

## 4. Journal + materialized-views (L4)

> SUPERSEDED by D1/D2 (files + in-BEAM pool) — see `harness-freeze-contracts.md`.
> The "Durable sink decision" sub-section below (Oban/Ecto-table/DETS) reflects a
> since-ratified choice: D1 ruled the journal is **files** (NC-6/NC-7 — no
> Ecto/DETS event table), D2 ruled the probe scheduler is an **in-BEAM supervised
> pool** (no Oban). Read `harness-freeze-contracts.md` §1/§3, not this section,
> for storage/runner shape; the rest of §4 (materialized-views, reattach,
> checkpoint/rewind concepts) still applies at the level of intent.

- **Journal** = durable append log of the durable tier, both populations. Source of truth
  (transcript-as-truth, FI-1). Ordered by `Event.id` (= offset).
- **Materialized-views = plural, dynamic.** Each `Projection.*` is a GenServer subscribed to the
  bus, forward-folding its own inputs (by `provenance.source`) into a fast read-model. The
  Dispatcher model is just one of them. Re-folding N growing projections per read would be absurd —
  keep them forward-folded, which is what the loop already does for the model. This is why it's
  journal+matview, **not** pure re-fold (design §2; the code would fight the pure version).
- **Reattach** (mobile payoff) = `attach{from_offset}` → replay durable events → rebuilt view.
- **Checkpoint/rewind** = journal offset + a model snapshot. `Raxol.Debug.TimeTravel` already
  snapshots `%Snapshot{message, model_before, model_after}` at `process_app_update/3` — that *is*
  `{cause, state, state'}`, the event shape. It becomes the snapshot side of the journal; extend it
  to the command-result path (currently blind) and give it a durable sink (currently ring-buffer
  cap 1000, in-memory, pull-only).

### The storage backend (concretized by round-2 research — AD-9/10/11, FI-7..12)

One directory per session; the directory IS the session (portable, tar-able,
rsync-able, grep-able):

```
~/.raxol/sessions/<session_id>/
├── meta.json          # created_at, cwd, git branch, title, schema_version
│                      #   — atomic writes only (temp+fsync+rename, FI-8)
├── HEAD               # sidecar: current offset + config. NEVER model state
│                      #   (AD-10, OpenHands). Atomic writes only.
├── journal/
│   ├── 000001.jsonl   # framed JSONL, size-capped ascending segments (AD-9)
│   ├── 000002.jsonl
│   └── ...
└── snapshots/
    └── <offset>.json  # checkpoint payloads; the checkpoint RECORD lives
                       #   in the journal as a pointer (AD-10)
```

Five components, all behind a `Raxol.Agent.Journal` behaviour (the pluggable
FileStore-injection demand is real — OpenHands PR #2509 — and server
deployments will want S3/DB impls later; the behaviour is the cheap seam now):

1. **Writer** — one GenServer per session (single-writer invariant). Append
   framed JSONL; batched `:file.datasync` on mailbox drain with ≤200ms
   ceiling; immediate sync for side-effect events (tool results, approvals);
   never `delayed_write`. Segment rotation at cap. Disk-full fails the write
   loudly and never touches other files (FI-11).
2. **Reader** — tolerant: parse-fail on the *final* line of the last segment
   → truncate (Ra tail policy); parse-fail anywhere interior → hard alarm,
   session marked damaged, **nothing deleted** (FI-7) and **nothing injected
   into model context** (FI-9). Upcast-on-read chain for old schema versions
   (AD-11); schema SemVer'd independently of app version.
3. **Index** — derived and disposable, always rebuildable from journals.
   v0: session listing = readdir + `meta.json` (no index at all). Query/search
   later = optional SQLite index behind the behaviour (NC-6: SQLite never
   primary — every cohort adopter burned).
4. **Retention** — explicit command with preview (`sessions gc --dry-run`
   shape: cwd/branch/size/last-activity per Codex #20230 demand); no
   automatic deletion path exists anywhere (FI-7).
5. **Redaction boundary** — secret patterns scrubbed at the writer boundary;
   no upload/telemetry channel of session content exists (FI-10).

### Durable sink decision (the two-populations resolution)
The bare-seam "Oban *or* Ecto table *or* DETS?" was a false either/or. Two roles the two
populations split cleanly:

- **Oban = the probe scheduler**, not the journal — concurrency caps, retries, rate-limit,
  backpressure on the background swarm. This *is* the economic law's "cheap ≠ free at scale"
  spend-gate substrate. (Oban praised as durable BEAM agent state — *"states, arg persistence,
  retry handling cover pretty much all my use cases"*; 25.3M downloads.)
- **Journal = a separate append store** — a foldable Ecto event table (or DETS for zero-infra
  early). The shared log both populations read.

So: **both, different jobs.** Oban runs the probes; the table is the log. Ratify the table-vs-DETS
choice by the deployment (Postgres present → table; embedded → DETS).

---

## 5. The probe swarm = the second population (C1–C7)

All probes: **non-reasoning, cache-riding, background, short output.** ~1–3 orders of magnitude
under a primary reasoning call — ten probes/turn ≪ one real think. They emit `family: :meta`
events (protocol §3). Scheduled via Oban (backpressure = the scale backstop; the $500M/month
"cheap ≠ free" residual is Oban's job, not per-session).

- **C1 Reasoning gate.** Before always-on reasoning, a probe scores *"0–100, how much does this
  benefit from reasoning?"* (structured output, else regex `\n+(\.\n+)?\%`). `<30` skip / `30–70`
  seeded dice / `70+` reason. Emits `gate_decision{score, threshold, choice, seed}` (seed =
  replayable). Justified: reasoning models measurably underperform on some tasks (GAIA: lost to
  GPT-4o via recursion + 3.5× latency).
- **C2 Multi-track structured compaction (the crown).** Per result, parallel cache-riding
  extractions into **typed classes**, each its own projection:
  - rules (when→then) — **split by stakes:** hard/safety constraints feed the *enforcement layer*
    (`Authorization.Engine`/`ToolPolicy` — `when tool=X then deny` becomes live policy, AD-7); soft
    guidelines become reminders. Extraction-to-executable-policy is the difference between OpenClaw
    happening and not (compaction summarized away "suggest, don't execute" → deleted 200+ emails).
  - session memory (add/update/drop) — session-scoped, not RAG.
  - worktracks (kanban, MCP tool) — Manus recite-goals pattern.
  - At 75% context: 3 tracks name what each class is *missing* + a 4th names the residual; a fresh
    session replaces the raw tail with the projections. Structured checkpoint over lossy prose
    (#21925 4-point ask; Codex `checkpoint_v1.json` re-injected verbatim). Typed decomposition >
    untyped summarization: fixing the class per-track removes the silent "which class matters"
    decision where loss happens.
- **C3 Intent-gated tools.** Agent states intent + wanted data; MCP response processed to exactly
  that. Attacks bloat (GitHub MCP = 93 tools/55k tokens; ~20-tool ceiling). Un-named dividend: the
  intent-processing step is the **injection-sanitization boundary** — untrusted tool output filtered
  before it enters privileged context breaks the lethal trifecta by construction (Willison, 2.5+
  yrs unmitigated across 15 systems). Marks derived events `trust: :tainted` (FI-5). Keep a
  "give me raw" escape hatch.
- **C5 Background research ("subconscious").** Recognition-framed probe (*"do you see signs of the
  known incompleteness classes?"*, bounded, can return empty — **not** open "anything tingling?"
  which always confabulates, the AutoGPT default). Spawns a background session; conclusion arrives
  as an **ignorable suggestion, never an interrupt**. Hard-gated: non-LLM termination predicate +
  budget (the $47K/264-hr loop had none). The one probe that may genuinely want reasoning →
  hardest gate.
- **C6 Cross-family consensus (the independence keystone).** Opt-in, only across model *families*.
  Self-drift probe first (recognition-framed, cheap pre-gate); then ≥1 **independent family** reads
  drift the leader structurally can't self-see. The value is cross-family independence, not the
  self-score (self-hallucination-detection is weak — that *is* the hallucination problem).
  **Load-bearing for the whole swarm:** probability-stacking multiplies only for *independent*
  catchers; same-model self-probes echo. ≥1 cross-family axis is non-negotiable or the other six
  repeat instead of multiply. Advice reconciled or marked advisory — never raw-appended (Cognition
  "conflicting implicit decisions").
- **C7 Calibration servo.** Tracks each gate's score *distribution*; sets the operating threshold at
  the quantile hitting a **human-set target rate**. Drops the requirement from "calibrated
  magnitude" to "monotone ordering." Human owns the setpoint; loop owns compensation. Guards:
  **variance-floor** (saturation ≠ miscalibration — a constant carries no information; fall back to
  finer/pairwise scoring or default-on) + **damping + hysteresis** (a controller tuning itself
  oscillates without them). Emits `calibrate{observed, quantile, new_threshold}`.

(C4 agent-generated UI is a frontend concern — see `harness-spec-frontend.md`.)

---

## 6. Control layer (makes fragile probes load-bearing)

Applied across the swarm (design §4):

1. **Recognition-framing.** Prefer *"do you see signs typical for X?"* (recognition vs a
   known-precursor catalog) over *"are you X?"* (self-verdict) or *"will X happen?"* (self-predict).
   Pre-mortem, not confirmation; leading not lagging; *"even if not now"* licenses surfacing a
   concern a verdict-question suppresses. Systematic upgrade for C1/C5/C6.
2. **Calibration servo (C7).** Rank not magnitude; servo to human setpoint; variance-floor; damping
   + hysteresis.
3. **Independence (C6).** ≥1 cross-family axis so stacking multiplies, not echoes.

Sensor conditioning → servo control → independent reference.

---

## 7. Meta layer (the ontology learns itself)

- **Fluid ontology.** Bootstrap a fixed minimal basis — *memories* + *work-style* — and let new
  classes be promoted by a cache-riding process watching the **residual** track: a class recurring
  in residual N times gets its own projection; a track empty M times gets demoted. The residual is
  the schema-evolution signal. Levels: L0 the work / L1 probes learning about the session / L2 the
  meta-loop learning how to do L1.
- **Convergence guards (mandatory).** Second-order loops don't auto-converge — a loop inventing its
  own categories and tuning its own gains can oscillate/diverge. **Hysteresis** (recur-N /
  empty-M), **damping** (shrinking adjustments), a **budget** on meta-adjustment per unit of real
  work. Without them it's the one part that runs away *while looking like learning*.
- **Local-vs-global → auto-ADR.** A background classifier (another calibrated probe; setpoint = a
  promotion *rate*) tags each extracted item session-local or project-global. Global items become
  **auto-drafted ADRs**, provenance-linked to the journal events that justify them. Attacks
  knowledge evaporation (the shift-handoff-with-no-memory postmortem). **Global promotion =
  irreversibility boundary = the one human confirm** — autonomous extraction locally (low stakes),
  auto-draft fully, gate commit-to-global on a human beat (`promote` event → `approval_decision`,
  protocol §3–4).

---

## 8. Safety substrate (the floor under every probe — AD/FI)

- **SpendGate (B9, AD-6).** Per-run/session/lifetime cap, atomic `try_spend` reserve before the
  next call — gated *before* the bill, not after. Only goose (`--budget`) + OpenHands ship per-run
  caps; leaders ship account-level only. Cost and control are the same bug (#68619: 4M tokens/5min
  *and* interrupt-loses-everything).
- **BlastRadiusGate (C2/AD-6).** Any shell/FS/DB Action atomically reserves against a supervised
  gate before `Port.open`, fail-closed. Defense **independent of the model's confidence** — every
  documented destructive incident was cooperative, not adversarial (the model confidently helping;
  ~800GB wipe was harness housekeeping with no transcript at all).
- **String-denylists are provably incomplete.** Expansion/substitution/tilde/script-wrap/binary-pad
  all defeat them (COMPASS 60–87% under adversarial; `rm -rf a && b | c` bypass #58424). Enforce on
  *typed intent* outside the model, not on the command string.
- **Sandbox seam at the Port (FI-4).** BEAM isolation stops at the VM edge; a shell subprocess is
  outside it. Route Shell through a wrappable point (Seatbelt / bubblewrap+Landlock) before
  enforcement ships. Codex is the only major CLI shipping OS sandbox on by default.
- **Housekeeping gated identically (FI-3).** "The harness did it, not the agent" is a distinction
  users don't credit (the 800GB deletion). Cleanup/GC code goes through the same gate + audit.
- **Evidence-gated done (FI-6).** `turn_completed`/completion carries a verification artifact (test
  output, diff, exit code) as first-class, not prose. Gate "done" on evidence (#75720, the
  *"false-progress machine"* — the exact failure this whole capture exercise guards against).

---

## 9. Backend capability floor (baseline, reference)

Table stakes from `harness-baseline-features.md` §B. Already built in Raxol: B1 multi-provider SSE
(`Backend.HTTP`), B5 permission (`Authorization.Engine` ALLOW/ASK/DENY × once/session/**root** —
ahead of the cohort; `:root` covers a spawn subtree none of the six researched harnesses handle),
B9 reservation (`Ledger`/`SpendGate`), B10-partial (TimeTravel snapshots), B8 MCP (own the JSON-RPC
wire directly, AD-8 — no stable Elixir SDK; Hermes died → Anubis LGPL). New/rewire: B3 contract
validation at dispatch (AD-4, the 54.3pt bucket), B4 structured compaction (C2), B6/B13 journal,
the unified emit (§2).

---

## 10. Build order

1. **Keystone emit** (§2) — unify the fold sites behind one typed event through EmitBus.
2. **Durable sink** behind it (§4) — the journal (Ecto table or DETS).
3. **Protocol structs + codec** (the one validation seam) + wire TUI + LiveView as first two
   subscribers to prove N-surface attach.
4. **Interrupt-as-kill + SpendGate + BlastRadiusGate** (§3, §8) — the mandatory substrate.
5. **Then** the probe swarm (C1–C7) on top of the journal + gates.

The first four are substrate; the seven concepts are cheap once it exists. Don't invert it.
