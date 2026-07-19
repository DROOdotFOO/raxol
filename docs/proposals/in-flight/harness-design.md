# Agent Harness — Design Record

Date: 2026-07-15
Status: **design discussion captured; no decisions final except those marked LOCKED.**
Companion docs: `harness-synthesis.md` (research Phase 5–6), `harness-facts-two-perspectives.md`
(operator + systems facts), `harness-research/01–09` (raw briefs), `harness-baseline-features.md`
(baseline floor lists).

This is the design conversation written down before compaction eats it — which is itself the
problem the design solves. Captured in our own extraction ontology: locked rules first, then
substance, then the explicitly-named residual (open questions).

---

## 0. The one-paragraph shape

A headless agent-harness **core** owns 100% of durable state and speaks a typed **contract** of
events (core→UI) and commands (UI→core); **detachable UIs** (TUI, LiveView, web, mobile) are pure
subscribers holding nothing persistent. The core is an event-sourced **journal** (durable truth) +
a **materialized view** (the live TEA model, fast rendering). Around the primary loop runs a swarm
of **cheap, non-reasoning, cache-riding meta-probes** that gate/shape/extract/verify — and write
structured events into the journal, folded into projections (rules / memories / worktracks) that
survive context swaps. The probes are made trustworthy by a **control layer**: recognition-framing
(sensors), a self-calibration servo (usable despite miscalibration), and at least one
cross-*family* independent read (ground truth where self-observation can't reach). Background
inference is nearly free; primary attention is the scarce resource; discipline lives at the
*injection* boundary, not generation. The whole thing wants BEAM because the category-empty seams
(durable state, supervised background concurrency) are exactly OTP's native strength.

---

## 1. LOCKED decisions

- **L1. Backend/frontend split.** Headless harness core + detachable UIs over a typed contract.
  The split is not cosmetic — it is what makes the hard baseline features (interrupt-as-kill,
  transcript-as-truth, N-surface attach) achievable at all.
- **L2. Transport-agnostic from day one.** The contract works in-process AND over the wire.
  Rationale: mobile remote sessions / reattach is a high-value later payoff, and BEAM
  distribution (`:pg`, Erlang distribution) makes it cheap to reserve now.
- **L3. Contract granularity = Codex Thread→Turn→Item, folded into TEA.** Turn = one fold-cycle,
  Items = typed events, deltas = the ephemeral tier. (Codex's own contract is already
  event-shaped; TEA's `update/2` is already a fold — the two align.)
- **L4. Event sourcing = journal + materialized-view, NOT pure re-fold-on-read.** The durable
  event journal is the source of truth (satisfies transcript-as-truth). The Dispatcher's
  in-memory model is the live materialized read-model, maintained forward by the loop as today.
  Reattach = replay journal to rebuild the view. Checkpoint = journal offset + model snapshot.
- **L5. State ownership.** Core owns 100% of durable state; UI owns nothing persistent. The moment
  session/checkpoint state lives in a UI's layer, alt-UIs stop attaching cleanly and you've handed
  away the durable seat. This is the single non-negotiable invariant.
- **L6. The contract is internal.** It drives *our* UIs. Exposing it as a third-party-pluggable
  protocol (e.g. an ACP *server*) is a separate, later, self-commoditizing decision — deferred.
- **L7. Keep the contract lightweight.** Message structs + one validation seam. No graph/DSL/CQRS
  framework — Elixir has the control-flow primitives; a framework re-introduces the opacity the
  whole research corpus says users revolt against.

---

## 2. Architecture — the seam (verified against current code)

Verification agent read the live code on `pr/divider-no-default-black-bg`. Findings:

- **Dispatcher is the sole live model owner** (`lib/raxol/core/runtime/events/dispatcher.ex:24`).
  Lifecycle's `model` field is a stale init snapshot, never rewritten (`lifecycle.ex:204`, zero
  post-init writes). `Agent.Session` is a thin routing shim — no model, no view, no buffer
  (`packages/raxol_agent/lib/raxol/agent/session.ex:14-21`). One clean authoritative owner. Good
  foundation for L4/L5.
- **The outbound event seam is missing exactly where it matters — and it's a live bug.** Three
  entry paths, three behaviors:
  - Generic input-event path → broadcasts via a `Registry` subscribe/broadcast primitive
    (`dispatcher.ex:359-390, 739`). But that's terminal-*driver input*, not agent traffic.
  - Agent-message path → **no broadcast**, only `send(runtime_pid, :render_needed)`. Getting the
    model out requires a poll (`GenServer.call(:get_model)`).
  - **Command-result path** — async LLM chunks, shell output, ticks, i.e. the *majority* of agent
    activity — **emits nothing**. `process_command_result/2` (`dispatcher.ex:525-551`) updates
    `state.model` but signals neither `:render_needed` nor any subscriber. The model updates
    silently; even the local renderer doesn't refresh for that traffic.
- **One Dispatcher = one model = one rendering backend**, fixed at Lifecycle start via an atom
  switch (`engine.ex:495-533`, chosen once from `environment:`). No mechanism today for N UIs to
  attach live to one running agent.
- **`:agent` environment is genuinely headless** (skips PluginManager + Terminal Driver), but the
  Rendering Engine starts unconditionally and runs the full view→layout→cells pipeline if the app
  exports `view/1` — just buffering instead of writing bytes. Fully inert only if no `view/1`.

### The keystone commit
Unify the two fold sites (`process_app_update/3` + `process_command_result/2`) behind **one typed
emit**. This single change (a) fixes the live command-result-emits-nothing bug, (b) creates the
event stream, (c) is the contract's outbound half. Smallest possible change, three payoffs. It is
the first stone for everything else.

### Adopt-vs-net-new (better than "net-new")
- **`Raxol.Agent.SessionStreamer`** (`packages/raxol_agent/lib/raxol/agent/session_streamer.ex`)
  is already almost exactly the target: typed vocabulary (`:text_delta, :tool_use, :tool_result,
  :state_change, :turn_complete, :done, :error`), subscribe + bounded history, `Process.monitor`
  dead-subscriber cleanup, and a built+tested SSE surface (`session_stream_server.ex`,
  `GET /sessions/:id/events`). It's just **unplumbed** — only Symphony's Runner glue emits 3 of 7
  types; Dispatcher/Session/Stream never call it. Its 7 types already encode the two-tier split
  (`text_delta` = ephemeral; `turn_complete`/`tool_result`/`state_change` = durable). Its
  subscribe + SSE = half of transport-agnostic (L2), pre-built.
- **`Raxol.Debug.TimeTravel`** (`snapshot.ex:10-24`) already captures `%Snapshot{message,
  model_before, model_after}` — the right event shape `{cause, state, state'}` — at
  `process_app_update/3`, and does model snapshots (the checkpoint side of L4). But it's
  in-memory/bounded (ring buffer, cap 1000), pull-only, blind to the command-result path.
- **Do NOT copy Symphony's `notify_listeners`** — it's a GenServer MapSet + raw `send`,
  full-snapshot-every-time, no history/replay, not Phoenix.PubSub. It proves the *shape* works but
  it's the poll-heavy version. **CLAUDE.md's "six surfaces consume via Phoenix.PubSub" is factually
  wrong** — `Phoenix.PubSub` appears in raxol_symphony only in a comment; 2 of 6 surfaces have
  dead never-subscribed push handlers. (Doc fix owed.)

Net: wire Dispatcher's unified emit → SessionStreamer's vocabulary/transport + add a durable sink
+ fix the command-result emission. Meaningfully smaller than designing a new pub/sub layer.

### The contract (shape)
- **Events (core→UI):** `TurnStarted · ItemDelta · ItemCompleted · ApprovalRequested · CostUpdated
  · …` — Codex Thread→Turn→Item framing.
- **Commands (UI→core):** `Prompt · Steer · Interrupt · ApprovalDecision · …`.
- **One validation seam** (encode/decode), single source of truth (the codex_sdk lesson:
  "own validation in one place, prevents policy divergence").
- **Two-tier stream:** ephemeral deltas (PubSub-only, live UI, never persisted) + durable events
  (item-completed level, the journal).

---

## 3. The seven concepts

All seven share one skeleton: **a cheap meta-query gates or shapes an expensive primary action,
riding the shared cache so it's nearly free, and emitting a structured output that becomes state.**
They are not seven features — they are the projections/boundary/renderer/verifiers of one
event-sourced system.

### C1 — Reasoning gate
Before running always-on reasoning, a hidden cheap probe (structured output if available, else
regex-extract a percentage: `\n+(\.\n+)?\%` → fallback `\n+(\.\n+)`) asks *"0–100%, how probably
does this response benefit significantly from reasoning?"* Buckets: `<30%` skip, `30–70%` dice-roll,
`70%+` reason. If reasoning-budget is a shared-cache knob (Anthropic's is **not**), a second probe
sizes the budget conservatively.
- **Cache insight (correct):** probe and real query branch off the same cached prefix, so the probe
  pays only its own small delta.
- **Research anchor:** reasoning models measurably *underperform* on some tasks (GAIA: a reasoning
  model lost to GPT-4o via excessive recursion + 3.5x latency). Gating is justified.
- **Risk:** self-prediction reliability — can a non-thinking pass predict thinking's benefit?
  Cheap to A/B-validate (run both, correlate probe-score with quality delta). Fixed by C7.
- **Notes:** seed + journal the dice-roll or lose replay. Serial probe adds latency (fine for
  background/autonomous; check it beats a zero-round-trip heuristic interactively).

### C2 — Multi-track structured compaction (**the crown jewel**)
Instead of one lossy panic-summary, run several tracks continuously. On each result, in parallel,
as separate cache-riding queries, extract into **typed classes** (stored structurally):
- *"what changed in how work should be done? guidelines? session constraints?"* → **when…then rules**
- *"what facts / memorable entities are significant this session?"* → **session-only memory list**
  (NOT RAG — session-scoped; add / update / drop)
- *"what work tracks are in motion?"* → **primitive kanban board** (MCP tool)

Results injected as system-message reminders. At 75% context: 3 parallel tracks name what each
class is *missing*; a 4th asks *"what else must be preserved?"* (the explicit residual), transformed
by a separate pure run into a neutral description. Then a fresh session replaces the 75% with the
extracted structured state → seamless context.
- **Why typed tracks (Note 1):** a single "extract what's important" query makes the model *decide
  which class matters* AND extract — the deciding is where silent loss happens. Fixing the class
  per-track removes the deciding step; each track can't drop its class to fit another. Completeness
  becomes checkable *within* a class. The residual track makes the ontology's incompleteness
  *named*, not dropped. This is typed-decomposition > untyped-summarization (= specialized >
  generic, the W3C composite-types finding). The 3x cost is 3 typed completeness guarantees, not 3x
  redundancy.
- **Research anchors (three, independently re-derived):** structured-checkpoint-over-prose-summary
  (#21925 / Codex `checkpoint_v1.json` demands); the OpenClaw fix (constraints as *structured
  state*, not prose that gets summarized away); Manus's recite-goals-via-todo.md (the kanban).
- **HARD PUSHBACK / the upgrade:** reminders are prose the model can ignore (CLAUDE.md-bloat →
  rule-ignoring; 93% blind-approve). Split the when→then rules: **hard/safety constraints → feed
  the actual enforcement layer** (`Authorization.Engine` / `ToolPolicy` — a `when tool=X then deny`
  becomes live policy), **soft guidelines → reminders.** Extraction-to-*executable-policy* is the
  difference between OpenClaw happening and not.
- **Coherence:** the three tracks are three projections folded live over the session event stream.
  C2 *is* the materialized-view over the journal. 75%-swap = drop raw tail, keep projections.

### C3 — Intent-gated tool calls
Instead of a direct tool call, the agent states intent + the data it wants; the MCP response is
*processed against that intent* to return exactly what's needed.
- **Research anchor:** Amp's "librarian" (cheap model keeps main context clean), generalized to all
  tool calls; attacks MCP context bloat (93 tools/55k tokens, ~20-tool ceiling, tool-output rot).
- **The un-named dividend:** the intent-processing step is *also* the injection-sanitization
  boundary. Untrusted tool output is the lethal-trifecta vector; filtering it through a controlled
  step before it enters the privileged context breaks the trifecta by construction. C3 is a
  **security primitive**, not just a token-saver.
- **Risk:** over-filtering drops a field the agent needed but didn't ask for. Keep a "give me raw"
  escape hatch.

### C4 — Agent-generated UI (**Raxol-native moat**)
When a dynamic dashboard is needed, the agent calls a tool that produces a simple reactive UI over
the harness.
- **Safe *because* declarative:** the agent emits a **view descriptor** (a Raxol component tree),
  not eval'd code — the thing that makes agent-generated UI dangerous elsewhere is absent. No
  arbitrary execution, just declarative components the framework renders.
- **Coherence:** the emitted UI subscribes to the same event journal and renders C2's projections
  (worktracks/memories) live. Ties directly to the multi-surface contract. No other harness can
  make this move cheaply — the reactive frontend already exists.
- **Bound it:** constrain to the existing Raxol component vocabulary.

### C5 — Background research ("subconscious") — **weakest, gate hardest**
After a call, a probe asks for latent research needs. A background session spawns; eventually inputs
*"subconscious process completed — here's conclusions."*
- **Risk 1 — confabulation:** *"anything tingling?"* asked every turn always produces *something*
  (the AutoGPT "more work needed" default). **Fix via Note-2 recognition-framing:** replace open
  "tingling" with *"do you see signs of the known incompleteness classes for this domain?"* —
  bounded recognition against a catalog; can come back empty.
- **Risk 2 — runaway:** background spawns are the $47K-loop shape. Requires the non-LLM termination
  predicate + hard budget. Conclusions arrive as an *ignorable suggestion*, never an interrupt.
- **Domain split:** research/open-ended benefits (Anthropic multi-agent +90.2% on research); tight
  coupled execution (coding) mostly gets noise (Cognition). Per-domain, not universal.
- **Cost exception:** this is the *one* track that may genuinely want reasoning (exploration is
  where thinking earns cost) — hence the hardest gate.

### C6 — Cross-family consensus (**the independence keystone**)
Opt-in, only if other model *families* (not other models) available. Post-call: a self-drift probe
(*"do you see risk signs typical for drift, even if not drifting now?"*, 0–100, dice on
uncertainty); then independent families join, each self-selecting via *"0–100, do you want to advise
or steer the leader?"*, then comment.
- **The value is cross-*family* independence, not the self-score.** Self-hallucination-detection is
  weak (models are confidently wrong — that *is* the hallucination problem). An independent family
  catches drift the leader structurally can't self-see (perspective-diverse verify: diversity
  catches what redundancy can't). Self-score = cheap pre-gate; independent read = truth.
- **Why it's load-bearing for the whole swarm:** probability-stacking compounds *multiplicatively*
  only for **independent** catchers. Self-probes on one model share a blind spot and *echo* — an
  echo chamber confidently wrong in unison. Cross-family is the only probe that breaks the
  shared-model correlation. **≥1 independent family is non-negotiable** or the other five's stacking
  just repeats instead of multiplying.
- **Risk:** *"gets to main feed"* — dumping N families' raw comments re-creates Cognition's
  "conflicting implicit decisions." Reconcile or mark clearly as advisory side-channel; don't append
  raw.

### C7 — Self-calibration loop (**the control layer that makes 1/5/6 usable**)
The 30/70/90 thresholds are examples. A servo dynamically adjusts them: track the *distribution* of
a probe's scores; set the operating threshold at the quantile that hits a **human-set target rate**;
if the model inflates everything to 90+, the threshold rides up with it.
- **What it actually is:** rank-based calibration + a servo to a human setpoint. It **drops the
  reliability requirement from "calibrated magnitude" (implausible) to "monotone ordering"
  (plausible)** — you don't need 70% to *mean* 70%, only higher-score to track higher-benefit.
- **Separation:** human owns the setpoint ("reason ~20% of the time"); loop owns the compensation.
  A servo tracking a human reference through a biased sensor.
- **The failure it does NOT fix — saturation:** if scores collapse to a spike (zero variance), no
  threshold recovers information from a constant. Needs a **variance-floor guard** + fallback (force
  finer/pairwise scoring, or default always-on). Miscalibration ≠ saturation.
- **Stability:** it's a controller tuning itself → needs **damping** (shrinking adjustments) +
  **hysteresis** or it oscillates. See §5 (this compounds at the meta-level).
- **Horizon:** the setpoint is a human *guess*. Mature form = outcome-feedback bandit (explore
  against the gate, measure if it helped, let data set the rate) — but needs a verifiable outcome
  signal, exactly what open-ended agent work lacks. Rate-matching to a human prior is the right v1.

---

## 4. The control layer (turns fragile probes into load-bearing ones)

Three conditioning mechanisms, applied across the swarm:

1. **Recognition-framing (Note 2).** Prefer *"do you see signs typical for X?"* (recognition against
   a known-precursor catalog) over *"are you X?"* (self-verdict) or *"will X happen?"*
   (self-predict). It's a pre-mortem, not a confirmation: recognition > judgment; leading > lagging;
   and *"even if not now"* licenses surfacing a concern without self-incrimination, so precursors get
   reported that a verdict-question suppresses. Systematic upgrade for *every* probe (C1, C5, C6).
   Residual: reduces but doesn't eliminate self-observation dependency — a badly-drifted model's
   recognition is also degraded, so C6's independent read stays the ground truth.
2. **Calibration servo (C7).** Rank not magnitude; servo to human setpoint; variance-floor guard;
   damping + hysteresis.
3. **Independence (C6).** ≥1 cross-family axis so probability-stacking multiplies, not echoes.

Sensor conditioning → servo control → independent reference. The six probes are the fragile part;
these three are what make them load-bearing.

---

## 5. The meta-layer — fluid ontology + local/global promotion

### Fluid ontology (the ontology learns itself)
Bootstrap a **fixed minimal basis** — *memories* (facts, declarative) + *work-style* (rules,
procedural) — and let new classes be **produced by an extra cache-riding process**: watch the
residual track; classes that keep recurring in residual get **promoted** to their own track. The
residual *is* the schema-evolution signal.
- **Levels:** L0 the work · L1 probes learning *about* the session · **L2 the meta-loop learning
  how to do L1** (which classes, which thresholds, which recognition-signs). L2 online is nearly
  unclaimed (DSPy-style meta-opt is offline).
- **THE risk — convergence.** A loop that invents its own categories and tunes its own gains can
  settle *or* oscillate/diverge (chase its tail, invent-then-abandon classes). Second-order loops
  don't auto-converge. Fixes: **hysteresis** (a residual must recur N times before promotion; a
  track empty M times before demotion), **damping** (shrinking adjustments), a **budget** on
  meta-adjustment per unit of real work. With them the strange loop reaches a fixed point; without
  them it's the one part that can run away while *looking* like learning.
- **Epistemics:** seed-two-let-the-domain-grow-the-rest is the cohort-research philosophy turned
  inward — don't impose a taxonomy you haven't earned; let the corpus reveal it.

### Local-vs-global split → automated ADR
A background classifier decides, per extracted item, whether it's **session-local** or belongs in
the **project-wide/global** store. Project-scoped decisions get formalized as **ADRs** automatically.
- **Attacks a named research failure:** knowledge evaporation ("let context drift before capturing
  in docs"; the shift-handoff-with-no-memory postmortem). Auto-ADR captures the foundation-invariant
  shape (durable + project-wide + painful-to-lose) that normally evaporates.
- **The classifier is another calibrated probe** — its setpoint is a promotion *rate* (over-promote
  → global store rots with session-noise = the RAG rot C2 avoids; under-promote → evaporation).
- **Global promotion = irreversibility boundary = the ONE human confirm.** Institutional knowledge
  sticks; an ADR shapes future decisions. CDCR result: confirm at irreversibility boundaries. So:
  autonomous extraction locally (low stakes), auto-*draft* the ADR fully, gate the *commit-to-global*
  on a human beat.
- **Provenance mandatory:** every auto-ADR links back to the journal events that justified it —
  auditable, not a black-box assertion. Free, because the journal's already there.

---

## 6. The economic law — background is free, attention is not

- **Background inference is nearly free:** non-reasoning kills the dominant cost (thinking-token
  expansion), cache-riding kills context re-processing, output is a score or short blob. A probe is
  ~1–3 orders of magnitude under a primary reasoning call. Ten probes/turn << one real think.
- **The scarce resource was never compute — it's primary attention/context.** Generating background
  output costs ~nothing; *reading it back* into the primary loop costs budget + context-rot.
- **Discipline moves to the INJECTION boundary, not generation.** Run everything in the background;
  inject stingily. The journal is write-everything-lavish; the projections + reminders are the
  curated read-selective subset that earns a seat in the scarce context. (The ES journal/view split
  already encodes this.)
- **Stakes gate injection, not generation.** High stakes → more background scrutiny allowed to reach
  the primary context. Same irreversibility signal that triggers the human-confirm (§5) triggers
  deeper injected scrutiny. Reflection scales with consequence.
- **Two honest residuals:** (a) cheap ≠ free — org-scale always-on × high volume is death by a
  thousand cheap calls (the $500M/month story); that's the spend-gate's job (mandatory infra), a
  scale backstop, not a per-session concern. (b) C5 deep research is the one genuine-cost exception,
  already hardest-gated.

---

## 7. The strategic thesis (the isomorphisms)

- **The unifying pattern:** primary loop + a swarm of cheap cache-riding meta-probes that
  gate/shape/extract/verify, each emitting structured events → projections that survive context
  swaps. One system, not seven features.
- **Empty-seam ≡ OTP-home-turf, recurring.** The category-empty differentiation seams (durable
  session/checkpoint/policy/compaction state; supervised terminable observable background
  concurrency) coincide, three separate times in the design, with what BEAM natively provides
  (GenServer + supervision + `:pg` + the CRDT swarm + the event journal). The market's empty seam is
  the platform's strongest muscle.
- **Background-tracks-as-moat ≡ OTP-as-substrate.** Background tracks are the ultimate unleveraged
  resource *not* because nobody thought of them, but because they're hard: runaway cost, no
  termination signal, can't-observe-live-vs-dead (the 34hr/1.08M-token runaway, the $47K loop). Hard
  in *exactly* OTP's strength. "Leverage background tracks" and "OTP is the moat" are the same bet.
- **Probability-stacking is the honest game.** Nobody eliminates failure (the destructive incidents
  were confident and non-adversarial). Independent partial catchers compound multiplicatively — so
  maximize independence (different framings, families, classes), and treat ≥1 cross-family axis as
  the thing that makes the math valid rather than an echo.
- **The recurrence is the signal.** The design keeps landing on BEAM's strengths because that's
  genuinely where it wants to live.

---

## 8. Open questions (the explicitly-named residual)

- **Durable sink:** Oban (Postgres job rows, ACID — the BEAM cohort's universal hand-roll) vs a
  dedicated Ecto event-store table vs DETS (zero-infra). The one real infrastructure fork.
- **Event vocabulary:** adopt SessionStreamer's 7 types as-is, or extend to the full Codex
  Thread→Turn→Item framing?
- **Contract transport concretely:** in-process-first then wire, or wire-shaped from day one (L2
  leans wire; exact serialization TBD).
- **Ontology promotion mechanics:** the exact hysteresis params (recur-N, empty-M), damping rate,
  meta-budget that guarantee convergence.
- **Recognition catalogs bootstrap:** drift-signs / incompleteness-classes / "problems where
  non-reasoning fails" start hand-authored and grow from observed residuals + incidents — but the
  *clean* bootstrap is unresolved. (Same shape as the ontology question, one level up.)
- **Calibration horizon:** when/whether to move from rate-matching to an outcome-feedback bandit,
  gated on having a verifiable outcome signal.
- **Self-observation residual:** recognition-framing + calibration reduce but don't remove the
  dependency on the model observing itself; the cross-family read is the only true escape, and it's
  opt-in — so what's the behavior when it's *off*?

---

## 9. Build order (first stones, when we move design → plan)

1. **The keystone emit** (§2): unify the two fold sites behind one typed event through
   SessionStreamer's vocabulary. Fixes the live bug + creates the stream + is the contract's
   outbound half.
2. **Durable sink behind it** (resolve §8 fork) → the journal (L4).
3. **The command + event contract structs + one validation seam** (L3, L7); wire TUI + LiveView as
   the first two subscribers off it (L1) to prove N-surface attach.
4. **Interrupt-as-supervised-kill + spend/blast-radius gate** (baseline †, the mandatory substrate
   under every probe).
5. Only then the probe swarm (C1–C7), on top of the journal + gate.

The first four are the substrate; the seven concepts are cheap once it exists. Don't invert that.
