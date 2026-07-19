# Harness — Eval-First Analysis (V's external-cohort ruling, folded)

Date: 2026-07-16 · Status: **ratified by V — dispositions binding.** The
"change-now" items are folded into `harness-freeze-contracts.md` (probe `sunset`
field + the eval gate, §3/§6), `harness-roadmap.md` (the eval unit, U14's control
arm, the packaging item), and `harness-parked.md` (the two named-deferred items).
This doc is the source of truth for *why*; those docs carry the *what*.

V ran an external cohort-research pass against the whole agentic-layer lane and
graded our standing plan against it. The pass is graded in five buckets:
**Aligned** (settled — do not re-argue), **The one bet against consensus**,
**Blind spots**, **Change now** (the ratified deltas), and the **meta-pattern**
that governs the lane. Dispositions below are binding; the "don't re-argue" tags
mean exactly that — reopen only with new external evidence, not with a fresh
opinion.

See `harness-facts-two-perspectives.md` for the underlying operator/systems
evidence this pass grades against (the `B<n>` systems-vantage tags live there),
`harness-design.md` for the `C1`–`C7` probes and the `L<n>` loop-lesson tags,
`harness-community-gaps.md` for the demand signal, and
`docs/proposals/in-flight/README.md` for the ID-prefix → owning-doc map
(`U#`, `NC#`, `AD#`, `FI#`, …).

---

## 1. ALIGNED — settled, do NOT re-argue

Where our plan already matches (or exceeds) the cohort lesson. Each is marked
**don't re-argue**: the external pass confirmed the call, so reopening it burns
budget for no new information.

- **Thin loop, no framework (NC-1 / L7 / B2).** The cohort's lesson #1 is that
  heavy frameworks lose to a thin, legible loop over files. Our NC-1 "no
  graph/DSL" guard, the L7 loop-legibility principle, and the B2 baseline all
  already encode this. **Don't re-argue.**
- **No RAG; C2 memory is session-scoped.** The cohort's read-files-on-demand
  finding (Claude Code out-competing embedding-retrieval IDEs — facts §A1) is
  already our posture: no embeddings retrieval, C2 memory stays session-scoped.
  **Don't re-argue.**
- **Single-threaded writes + clean-context reviewer (NC-2 / C6).** This is the
  shape of Yan's 2026 recantation (single-writer over swarm-of-writers), and C6
  independently re-derives "Context Rot" — the clean-context reviewer is the fix
  the cohort converged on. Our NC-2 (no swarm headline) + C6 cross-family
  consensus already implement it. **Don't re-argue.**
- **Structural security beats the cohort.** Our fail-closed pre-`Port.open`
  posture (AD-6), FI-3, FI-5 taint, and FI-10 write-boundary redaction structurally
  beat the cohort on the OpenClaw / "delete the tests" class of failure — the
  security is compiled into our own tree, not self-reported by an untrusted tool.
  **Don't re-argue.**
- **U14b constraint-extraction to `Authorization.Engine` exceeds the report.**
  Extracting hard rules into executable policy means constraints survive
  compaction *as enforced policy*, not as prose the next summary can drop — this
  is strictly ahead of the report's own recommendation. **Don't re-argue.**
- **Journal + worktracks + checkpoint (AD-3), natively.** Our AD-3 spine is the
  Anthropic long-runner initializer + progress-file pattern, arrived at
  independently. **Don't re-argue.**

---

## 2. THE ONE BET AGAINST CONSENSUS

There is exactly one place our plan bets **against** the cohort's lesson #1, and
V names it deliberately, not accidentally: **the probe swarm (C1–C7) + control
layer + fluid ontology is the heaviest scaffolding in the cohort.** The report's
#1 lesson is "scaffolding loses"; we are building the most scaffolding of anyone
surveyed.

This is a *deliberate* bet — its justification is the cache-riding economics
(probes ride the primary prefix, so they are near-free) and a substrate-first
build order (U11/U12 substrate before the probes that need it). But the bet
carries **three uncited echoes** — places where the cohort already ran our
experiment and we did not cite the result. These are promoted to first-class
citations here because an uncited echo is how a plan fools itself:

1. **Echo (a): C1's gate ≈ Cognition's "Smart Friend" — which mostly failed
   there.** The C1 reasoning-benefit gate (score-then-decide before spending
   reasoning) is structurally Cognition's (Devin) "Smart Friend" pattern, and it
   *mostly failed* in that deployment (cf. the Cognition-vs-Anthropic multi-agent
   contradiction, facts §B4: narrow specific patterns work, general ones don't).
   The promised mitigation was always a **U13 A/B test** — and that A/B **was
   never a roadmap unit.** A bet whose falsifier is un-scheduled is not yet a
   falsifiable bet.
2. **Echo (b): no probe has a sunset criterion.** "Guardrails built for a weaker
   model constrain the smarter one." Every probe is scaffolding compensating for
   some current model weakness; none of them declares *when it should be deleted*.
   Without a sunset, a probe that outlives the weakness it patched becomes a tax
   on the stronger model. (This is the direct source of the ratified `sunset`
   field, §4.2.)
3. **Echo (c): C2 never argued against provider-native compaction.** Anthropic
   ships `compact-2026-01-12` + the memory tool + `clear_tool_uses` context
   editing — our **own** facts doc lists them (facts §B1, §B3). C2 (multi-track
   compaction, the crown jewel) never makes the case for why our compaction beats
   the provider-native primitive on the same corpus. Building a crown jewel that
   duplicates a provider primitive, without measuring against it, is the
   compensator trap. (This is the direct source of U14's ratified control arm,
   §4.3.)

**Fluid ontology (U19 / L2) is a separate, softer instance of the same bet:**
nobody in the cohort self-modifies their own extraction schemas. V's disposition:
**keep deferring — Wave 5.** It is not cancelled; it is the least-supported piece
of scaffolding and must wait until the substrate under it is proven. (Named-deferred
in `harness-parked.md`.)

---

## 3. BLIND SPOTS

Three gaps the plan did not have a home for. Ranked by V.

1. **No model-behavior eval unit — the biggest gap.** Nothing in the plan
   measures probe *signal quality*: no measurement of the C1 score↔benefit
   correlation, no measurement of compaction fidelity across a model swap, no
   null-baseline for any probe. This is **live now** (Wave 4 is starting), and it
   is the load-bearing blind spot: every other item in "The bet" (§2) is
   un-decidable without it. → ratified as the eval unit (§4.1).
2. **Distribution / packaging.** The cohort's Codex lesson is a zero-dependency
   binary; we carry a BEAM runtime dependency. There is **no packaging doc** and
   no ratified answer for how the CLI surface ships. → ratified as a pre-CLI-surface
   packaging decision (§4.4).
3. **Plugin supply chain for the agent surface.** OpenClaw's registry ran ~12%
   malicious packages; an agent surface that loads third-party plugins inherits
   that exposure. Deferred, but now **named** so it is not silently dropped.
   (Named-deferred in `harness-parked.md`.)

---

## 4. CHANGE NOW — the ratified deltas

Four changes, ratified 2026-07-16. Each has a home in the contract/roadmap/parked
docs; this section states the intent, those docs carry the binding text.

### 4.1 The eval unit gates Wave 4

A journal-replay-based model-behavior eval unit. **The infra is ~80% already
built and merely unnamed:** the journal replay path (U4 / P-JS5 replay closure)
plus the FI-2 version tags (`{harness_version, model, config_hash}` on the log
head) are exactly the substrate a replay-eval needs. Naming it is most of the
work.

- **Probe acceptance gains a new bar:** a probe is accepted only if it **beats a
  null baseline on the eval set.** A probe that does not beat "do nothing" is
  scaffolding with no signal.
- **U13's A/B becomes an exit criterion,** not a someday-nice-to-have — it is the
  falsifier echo (a) was missing.
- **The eval unit gates Wave 4:** the probes do not graduate without it.

→ roadmap: the eval unit (proposed **U23** — see the numbering flag below).
→ freeze: §6 "Eval gate".

### 4.2 One-line sunset per probe spec

Every probe spec gains a one-line **sunset** criterion:

> "delete when provider-native X matches on eval."

This is echo (b) made structural. A probe with no sunset is a permanent tax; a
probe with a sunset is a bet with an expiry. **Every new probe spec SHOULD carry
one; Wave-4 graduation REQUIRES one.** Grandfathered C-probes (existing C1–C7)
get their sunset lines added at their next touch.

→ freeze: §3 `spec()` gains an OPTIONAL `sunset` field + governing note.
→ roadmap: probe units carry a one-line sunset annotation requirement.

### 4.3 U14 gains a control arm

C2 (multi-track compaction) vs Anthropic-native compaction (`compact-2026-01-12`
+ memory tool), run over the **same corpus.** This is echo (c) made measurable.

- **The control arm is U14's exit criterion.** If native compaction wins on the
  same corpus, **C2 demotes to an adapter** over the provider primitive rather
  than a from-scratch crown jewel.

→ roadmap: U14's exit criterion.

### 4.4 Ratify packaging before the CLI surface

Decide **burrito vs `mix release`** (BEAM-runtime-dep vs self-contained binary)
and write a decision doc, **before** the CLI surface ships. This closes blind
spot #2.

→ roadmap: a "Packaging ratification" pre-CLI-surface item (decision doc required).

**Numbering flag:** V's ruling proposed "U22" for the eval unit, but **U22 is
already taken** in `harness-roadmap.md` (the asciicast fix, PR #544; the corpus
labels the whole range "U0–U22"). To honor the "do not renumber existing units"
rule, the eval unit lands as **U23**. Recorded here so the intent-vs-number
divergence is not lost.

---

## 5. META-PATTERN — the law that governs the lane

**Every abandoned scaffold in the cohort report was a compensator for a model
weakness that later expired. Every survivor had a falsifier.**

The corollary, binding on this lane going forward:

> **Anything built atop model behavior needs a measured exit criterion.**

This is why §4.1 (eval), §4.2 (sunset), and §4.3 (control arm) are one idea in
three places: each attaches a falsifier to a piece of model-behavior scaffolding.
A probe, a compaction track, or a reasoning gate without a measured exit is a
compensator waiting to become a tax. The eval unit is the instrument that makes
the exit criteria measurable rather than rhetorical — which is why it gates Wave 4
and why it was the #1 blind spot.

---

## 6. Disposition table (binding)

| ref | disposition | home |
|---|---|---|
| thin loop (NC-1/L7/B2) | ALIGNED — don't re-argue | — |
| no RAG, C2 session-scoped | ALIGNED — don't re-argue | — |
| single-writer + clean reviewer (NC-2/C6) | ALIGNED — don't re-argue | — |
| structural security (AD-6/FI-3/FI-5/FI-10) | ALIGNED — don't re-argue | — |
| U14b constraint→policy | ALIGNED — exceeds report | — |
| journal+worktracks+checkpoint (AD-3) | ALIGNED — don't re-argue | — |
| probe swarm C1–C7 = heaviest scaffolding | THE BET — deliberate, now falsifiable | this doc §2 |
| echo (a) C1 ≈ Cognition "Smart Friend" | cited; A/B → exit criterion | roadmap U13 |
| echo (b) no probe sunset | cited; → `sunset` field | freeze §3 |
| echo (c) C2 vs native compaction | cited; → control arm | roadmap U14 |
| fluid ontology U19/L2 | keep deferring — Wave 5 | parked |
| eval unit | CHANGE NOW — gates Wave 4 | roadmap U23, freeze §6 |
| probe sunset lines | CHANGE NOW | freeze §3, roadmap |
| U14 control arm | CHANGE NOW — exit criterion | roadmap U14 |
| packaging (burrito vs mix release) | CHANGE NOW — pre-CLI, decision doc | roadmap |
| plugin supply chain (OpenClaw ~12%) | blind spot #3 — named-deferred | parked |
