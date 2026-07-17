# Drew Review Corpus — Meta-Pattern Analysis (PRs #587–#629, 2026-07-16/17)

Source: `DREW-FINDINGS-24H.md` (48 Drew entries across 27 PRs; 12 PRs with zero Drew activity).
Counting basis: severity fractions below are computed over the **~70 CRITICAL/HIGH/MEDIUM findings**
(round-1 plus new-in-re-review). LOW findings (~60 more) are cited where they shift a class's weight
but are excluded from fractions. Caveat: Drew sometimes folds 2–3 issues into one severity bullet,
so counts are ±10%; where the corpus doesn't support a number I say so.

Hard anchors: **3 CRITICALs** (#609 keymap/overlay routing, #610 enable_reader swallow, #613 symlink
escape), **3 BLOCK verdicts** (#609, #610, #613), **~17 cross-persona severity promotions**.

---

## 1. Repeating issue classes (root-cause, not per-PR)

### Class table

| # | Class | C/H/M count | ~Fraction | PRs instantiating | Upstream cause |
|---|-------|-------------|-----------|-------------------|----------------|
| B | Claims-outran-code / unwired "dormant" features | ~11 | **15%** | 587, 588, 604, 605, 606, 615, 617, 618, 619, 620 | Process: guarantees written at design time, never re-audited against final wiring |
| G | Proxy validation (trust-boundary myopia) | ~10 (2 CRIT) | **14%** | 587, 595, 609, 610, 613, 619 | Knowledge gap: validating a *representation* instead of the *referent* |
| D | Self-confirming / vacuous tests | ~10 | **14%** | 588, 591, 608, 609, 610, 611, 613, 618 | Test methodology: benign generators, oracles derived from the code under test |
| C | Fail-open defaults on safety-critical paths | ~9 (1 CRIT) | **13%** | 587, 592, 593, 594, 605, 610, 617, 620 | Design habit: "missing data = benign" chosen on approval/authz/degradation surfaces |
| E | Unbounded growth / hot-path asymptotics | ~9 | **13%** | 587, 594, 605, 606, 611, 618, 621 | Architecture: session-lifetime collections meeting per-frame loops, no growth inventory |
| A | Unsanitized content → terminal bytes | ~8 (6 HIGH) | **11%** | 589, 590, 591, 593, 595, 607 | Architectural seam: sanitization ownership undefined between producer and PaintAuthority |
| F | Width/sanitizer oracle incompleteness | ~4 | **6%** | 591, 607, 608 | Shared-oracle gap: TextMeasure/wide_char? wrong; N divergent hand-rolled sanitizers |
| H | Jargon / doc decodability | ~3 (+many LOW) | **4%** | 589, 594, 595, (609, 593 LOW) | Process: violates repo's own recorded voice rule |
| — | Misc single-instance logic bugs | ~7 | **10%** | 588, 592, 609, 615, 617, 620, 621 | — |

Key structural facts:

- **Severity concentrates in C∪G** (fail-open + proxy-validation): all 3 CRITICALs and all 3 BLOCKs
  live there, though it's only ~27% by count.
- **Count concentrates in B∪D** (overclaiming + weak tests): ~29% by count, but these are the
  *enablers* — nearly every A and C finding carries Drew's refrain "untested: every property drives
  alphanumeric-only content" or "the test pins the fail-open default rather than flagging it".
- **A, F, D interlock**: A shipped six times in one day because D's generators never contained an
  ESC byte; F is why even a *diligent* caller following the documented TextMeasure contract still
  ships the bug (#590's explicit point).

### Class details and seed verification

**A. Unsanitized content → terminal (seed "escape-injection" — CONFIRMED, and it's a single seam
replicated, not six bugs).** #589 `seal/append_sealed` writes iodata verbatim; #590 footer lines
verbatim; #591 `turn_stage` interpolated raw; #593 FlatAuthority "PROVABLY escape-free" only for
escape-free input; #595 ViewText truncates width but strips nothing; #607 fence info-string label.
Six HIGHs, same root: the paint-authority layer assumes "sealed content is trusted" and no module
owns the boundary. Critically, the class **closes mid-corpus**: #613 lands `TermText.sanitize/2`
(which "held up under hostile probing"), #608 R4 lands the ContentGuard fixed-point ingress
invariant, and by #619/#621 Drew *verifies the defense as safe* ("sanitize+truncate boundary is
sound", "footer injection… checked and defended"). The lane learned; the lesson is that the fix was
architectural (one seam), not per-PR vigilance.

**B. Claims-outran-code (seed "claims-outran-tests" + "doc-code parity drift" — CONFIRMED, largest
class).** Two sub-shapes:
- *Behavioral overclaim*: #605 moduledoc claims O(n) walk, code is O(n²) via `Enum.at`; #606 module
  named "backpressure" provides none; #618 title "O(N²)→O(N)" false for the commonest payload and
  for view assembly; #620 "balanced by construction" / "confirmed on the device" overclaims; #610 R2
  "crypto-random" doc claim over a monotonic counter; #588 moduledoc "runs locally" false under the
  repo's own default env.
- *Dormant feature presented as live* (~8 PRs!): #587 BlastRadiusGate zero call sites ("LOCKED by
  default" isn't); #604 Ansi16Salience zero callers; #605 `classify/3` + `seal_display_mode/1`
  unwired with a **false coverage claim** ("covered by the property test" — the test never calls
  it); #606 `input_check` defaults off; #615 `blur/1` zero production callers; #617 `grade_blocks/2`
  dead code + approval floor never engaged on the wired path; #618 `render_streaming_incremental`
  no caller. Upstream cause is the lane's bottom-up unit strategy (legitimate) colliding with PR
  framing that claims delivered behavior (not legitimate). Drew's consistent remedy: he accepts
  *honesty* ("INERT at runtime until that unit lands") as full resolution for unwired code.

**C. Fail-open defaults on safety surfaces — CONFIRMED (seed "trust-boundary myopia" splits into C
and G).** The signature: absence of data resolves to the *permissive* interpretation exactly where
stakes are highest. #594 missing `blast_radius` renders "No tracked effects." under `rm -rf /`;
#592 missing `composing?` defaults to key-stealing (the exact bug the unit exists to fix, and the
test codifies the fail-open); #593 env override silently defeats the degenerate-geometry data-loss
floor; #587 approver never authenticated; #610 reader re-enable failure swallowed while the ledger
records `:enabled` (a lie); #620 over-broad rescue reclassifies logic bugs as retryable device
failure; #617 unknown-turn grades *loudest*; #605 `pending_input?` fed from a proxy that can't
honor the gate's contract. Counter-signal worth keeping: #615/#617's endgame shows the team
internalizing the right rule — over-report unread (fail-safe) accepted, under-report rejected.

**G. Proxy validation — CONFIRMED, the highest-severity class.** Every instance checks a syntactic
stand-in instead of the semantic authority: #595 `validate_base_url!` prefix-match
(`localhost.evil.com` passes); #613 symlink target resolved against the *lexical* parent instead of
the resolved-real parent (CRITICAL, reproduced escape) plus depth counter conflating nesting with
symlink hops; #619 evidence refs resolved by *existence-only* `Map.get` while the gate's five
acceptance predicates go unenforced (then R2: turn_id-only check still misses `:stale_evidence` /
`:mutation_echo`); #587 deny keyed by bare `call_id` while grants key the full ref; #609 the
`:not_composing` guard reads only `composing?` when the real question includes `overlay_open?`
(CRITICAL); #610 tmp file trusts `/tmp` + predictable name (symlink race). The test-side twin is
#613's property that "validates confine against itself" — proxy validation *and* proxy oracle.

**D. Self-confirming tests — CONFIRMED.** Sub-shapes: (i) benign-only generators (#589/#590/#591
alphanumeric-only; #613 generator plants no symlinks); (ii) self-referential oracles (#613 escape
property checks confine's output against confine's output; #618 R2 work metric reads the field it
validates); (iii) tests that pin the bug (#592 codifies the fail-open default; #609's overlay test
pins `composing?: true`, masking the CRITICAL; #619's own passing cross-turn test *is* the
reproduction of the HIGH); (iv) threshold tests that can't detect weakening (#611 can't distinguish
clamp-removed from clamp-loosened-50x); (v) coverage governance (#588 blanket `:skip_on_ci` deletes
all CI coverage of the only PtyHarness suite; #591 property generator structurally never generates
the safety-relevant state). Also #610: the "exhaustive compensation property" is vacuous over the
one step the model treats as infallible.

**E. Unbounded growth / asymptotics.** #606 unbounded queue then unbounded mailbox then
count-not-bytes (three iterations to a still-open residual); #605 O(n²) per-frame walks over
session-lifetime block lists; #618 open-fence O(N²) (measured 498x by Drew, fixed to 1.0x); #621
per-keystroke O(N) filesystem scoring; #587 unpruned MapSets; #617 un-windowed `source_events` ×
per-seal rescan ("correctness and cost are coupled to the same retention decision"); #594 frame-rate
log flood; #611 unclamped query axis. Upstream: no standing "what grows, and what bounds it?"
question at PR time.

**F. Width/Unicode oracle gap — CONFIRMED but narrower than seeded.** The flagship is #591: ⏳
U+23F3 measured 1 col, renders 2 — `wide_char?/1` has no 0x2300–0x23FF range, so the module's own
moduledoc citing TextMeasure *because* naive length fails on ⏳ is factually wrong; and
`display_width` counts ESC bytes as width-1, so the width bound *passes while injecting*. Sequels:
#607 R2 sanitizer `/u` regex crashes on invalid UTF-8 (the fix introduced a new crash on the exact
untrusted caller it defended); #607 R2 two divergent control-strip regexes with no shared source;
#608 R4 ContentGuard blind to 8-bit C1. Small count, but it corrupts the **single source of truth**
that every other module is instructed to trust — highest blast-radius-per-finding class.

**Seed verdicts**: claims-outran-tests ✓ (B, largest); self-confirming tests ✓ (D); trust-boundary
myopia ✓ (split C fail-open / G proxy-validation, holds all CRITICALs); display-width/Unicode ✓ but
~6% not systemic-by-count — systemic by blast radius; regex residue-guard arc ✓ but it's an
*oddity/process* datum, not a class (see §4); doc-code parity ✓ (folded into B + H).

---

## 2. Higher-level pre-PR self-review targets (ranked by expected yield)

1. **Byte-boundary trace** (kills A; would have fired on #589/#590/#591/#593/#595/#607 — 6 PRs,
   6 HIGHs). For every function that writes to a device or seals into scrollback: enumerate byte
   sources; any caller-supplied content must pass ContentGuard/TermText *at the write seam*, and the
   claim "no raw ANSI" must be tested with content that contains `\e[2J`, `\e[H`, OSC, C1, `\n`, and
   invalid UTF-8. Post-#613 the seam exists — the check reduces to "is this write routed through it,
   and is there an ingress fixed-point test (#608 R4 pattern)?"

2. **Guarantee→enforcement→falsifier audit** (kills B; fires on #587/#604/#605/#606/#615/#617/#618/#620).
   For each sentence in the title/moduledoc that states a guarantee: name the line that enforces it
   and the test that fails if it breaks. `grep` every new public function for production callers;
   zero callers ⇒ the PR must self-label the unit "unwired seam" and drop behavioral claims. This is
   the exact question Drew's New Hire persona asks, and it is his single most reliable finding
   generator.

3. **Absence-semantics sweep on decision surfaces** (kills C; fires on #587/#592/#593/#594/#605/#610/#617/#620).
   List every `Map.get(_, _, default)`, optional param, rescue, and catch-all clause on any
   approval / authorization / degradation / keybind-guard path and answer "what does *missing* mean
   here?" The safe default for a guard is the restrictive one (assume composing; assume irreversible;
   assume unproven; refuse the override on degenerate geometry). Distinguish "no effects declared"
   from "no effects" (#594's formulation) — it generalizes to every one of these.

4. **Referent-vs-representation check** (kills G; fires on #587/#595/#609/#610/#613/#619). For each
   validation ask: am I checking the thing, or a proxy for the thing? Prefix ≠ host equality;
   lexical path ≠ resolved path; key-exists ≠ gate-accepted; `call_id` ≠ request identity;
   `composing?` ≠ "input is owned elsewhere". Tests for these must use an **independent oracle**
   (OS realpath, emulator replay, the actual gate predicates), never the module's own output.

5. **Generator/oracle adversarial audit** (kills D; fires on #589/#590/#591/#609/#610/#611/#613/#618).
   Before opening the PR, answer three questions about each property/golden suite: (a) does the
   generator contain the hostile alphabet for this surface? (b) is the oracle independent of the
   implementation? (c) does any test *pin* a default rather than challenge it? Also: no blanket
   `:skip_on_ci` on a module that is the sole coverage of a subsystem (#588); no absolute wall-clock
   asserts where a ratio/invariant assert exists (#611).

6. **Growth inventory** (kills E; fires on #587/#605/#606/#617/#618/#621). One table per PR: each
   new collection/queue/accumulator/loop → its bound → what enforces the bound. Per-frame code
   touching session-lifetime data is an automatic flag. State whether a cap counts items or bytes
   (#606 R2), and whether drop semantics fit the stream model (snapshot vs append-only, #606 R2 LOW).

7. **Fix-commit re-gauntlet** (from the #607/#608 arcs). A fix commit gets the same adversarial pass
   as the original diff: twice in this corpus the fix introduced a new defect class (#607 R2
   sanitizer crash on invalid UTF-8; #608 R2 two-sided residue regex).

---

## 3. Cross-persona convergence mechanics

Observed promotions (~17: L→M ×2, M→H ×12, H→C ×2, plus 3-persona confirmations). The mechanics:

**Multi-persona-visible defects are unenforced-stated-invariant defects.** When a module advertises
a guarantee its code doesn't hold at a boundary, each persona independently manufactures its own
story from the same root: Saboteur sees production corruption (benign ANSI breaks layout; queue
OOMs), Security sees an attack (injection wipes scrollback; token-flood DoS), New Hire sees a doc
that lies (the guarantee rests on an assumption the documented contract doesn't cover). All six
escape-injection HIGHs, the fail-open defaults (#592, #593, #594), the unbounded queue (#606), and
both CRITICAL promotions (#609 routing desync = broken feature + confused deputy; #610 swallow =
leaked resource + unsound safety proof) follow this shape. The 3-persona hits (#588, #590, #593,
#608 R2) are all "the module's central advertised invariant is bypassable."

**Single-persona-only defects are depth defects in one dimension:**
- Saboteur-only: asymptotics and algorithmic state (#605 O(n²) HIGH — notably HIGH *without*
  promotion because it contradicts the module's own doc; #618 O(N²) shapes; #615 stuck-divider
  state machine).
- Security-only: confidentiality and local-attacker surfaces (#610 world-readable tmp file/symlink
  race; #611 query-axis DoS; #608 OSC-52 allowlist gap). No other persona reaches filesystem/env/
  process seams.
- New Hire-only: contract decodability and drift (jargon moduledocs; #610 OTP private-protocol
  coupling; #607 vocabulary split; duplicated thresholds #609).

**Implication for self-simulation order:** run **New Hire first** — "which documented sentence has
no enforcing line?" is the cheapest question and it sits at the convergence attractor: any yes is
likely to bloom into a multi-persona HIGH. Then **Security specifically on fs/env/process/network
seams** (its unique coverage), then **Saboteur on hot loops, missing-data paths, and state machines**
(its unique coverage). Simulating all three on everything is not the lesson; the lesson is that the
overlap region *is* the stated-invariant audit (§2 item 2), and the persona-unique regions are
narrow and enumerable.

**A calibration note:** the promotion rule fires on root-cause identity regardless of reachability,
so several promoted HIGHs were dormant (#587 conditional on `call_id` reuse; #605 no producer emits
the flags yet; #619 unreachable via the honest producer). Drew is consistent about conditioning the
*verdict* on reachability (CONCERNS not BLOCK for unwired code) while keeping *severity* worst-case.
Our self-review should mirror that split rather than argue severity down.

---

## 4. Oddities

**Refuted / reachability-wrong findings (low rate, ~2–3 of ~70 H/M).**
- #619 R1: the "reattach shifts refs" staleness hypothesis is *self-refuted inside the same finding*
  ("that hypothesis is refuted") — Drew publishes his own falsification work.
- #609: substrate-overpaint hypotheses "investigated and did NOT survive verification" — negative
  results disclosed, which is why the one surviving CRITICAL is credible.
- #617 R1 MEDIUM (ladder inversion): correct about the function in isolation, wrong about
  reachability; our traced-invariant rebuttal downgraded it — and then Drew *demanded the invariant
  be enforced*, which R4's tripwire did (he re-verified by re-breaking projection.ex:207 himself).
  Nothing in the corpus is flat-wrong about code behavior; the errors are reachability judgments.

**Verdict/severity inconsistencies.**
- The mechanical BLOCK rule ("CRITICAL or ≥3 HIGH") produces odd edges: #591 (two HIGHs that defeat
  the module's entire width/safety contract) merges as CONCERNS, while #605's Saboteur-only O(n²)
  HIGH carries the same label as live escape-injection HIGHs. Severity is not reachability-weighted
  even though verdicts are.
- **All three BLOCKs merged anyway**: #609 merged with the CRITICAL and *no recorded re-review
  round in-window*; #610 merged at CONCERNS with the footer-truncation MEDIUM open; #613 merged
  after the fix. #609 is the anomaly — a BLOCK with one review entry and a merge 1.5h later. Either
  the fix round happened outside Drew's commentary or the BLOCK was overridden silently; the corpus
  can't distinguish. Worth an explicit rule: a BLOCK requires a recorded resolution round.
- **Drew pushed a fix himself on #613** ("Fix pushed by the adversarial-review lane", commit
  715417b1) — reviewer/author role-blending. It was excellent work (root-caused, red-then-green),
  but it means the fix to the corpus's worst finding was never independently reviewed.

**Churn rounds.** #591 R2 and #592 R2 are literally "still failing CI"; #610 R3 "have conflicts
here"; #617 R2 "pls address above". Four of 48 entries (~8%) carry zero technical content — Drew as
CI babysitter. Separately, #597/#598 closures reveal two parallel PRs re-implementing what the base
branch already carried (lane-coordination overhead, not review overhead).

**The #608 four-round regex arc: partially avoidable.** R1 predates the residue guard (the `[K` fix
arrived in R2's commit, so R1 *couldn't* have caught it — the arc length is partly an artifact of
fix commits adding new surface each round). But R2→R3→R4 was compressible: Drew's R2 finding already
stated the terminal root cause verbatim — "a fixed letter-set regex cannot distinguish ESC-stripped
CSI residue from a bracket label… the honest containment is upstream at the ContentGuard/seal seam."
Our R3 response narrowed the regex (trading FP for FN, spawning the `[4K]`/`[2FA]` residual FP
class); only R4 built the seam invariant Drew had named two rounds earlier — which he then verified
by red-proving it and issued the corpus's only escalating-to-CLEAN verdict on the spot. **Rule: when
the reviewer names a layer-mismatch as root cause ("undecidable at this layer, own it at seam X"),
the first fix commit goes to seam X, not to a better heuristic at the wrong layer.** That deletes
one full round (R3) and its residual-FP finding.

**What changes Drew's verdict vs what doesn't.** Sharp, consistent pattern:
- *Enforced mechanisms* flip verdicts: reproduced red→green tests (#613 fix, #621 substrate fix,
  #620 both HIGHs), tripwires he can re-break (#617 R4), measured deltas (#618: 498x→1.0x). Four
  arcs ended CLEAN (#608, #615, #617 R4, #621, #622) — every one via enforcement.
- *Documentation-only responses* do NOT flip behavioral findings: #619 R2 stays HIGH (he calls the
  "cannot re-validate" dependency argument a **false constraint** — the predicates are pure and
  local); #606 R2 "narrowed, not closed" (bound moved from queue to mailbox); #618 title
  overstatement persists across all three rounds.
- *Exception*: honesty **is** accepted as full resolution for **unwired** code (#606 input-first,
  #615 dormancy, #617 away-pull tradeoff, #618 earmark gate) — "addressed by honesty, not by
  enforcement… credit for the candor."
So the response playbook is deterministic: behavioral finding → enforcement + reproduction;
claim finding on dormant code → honest disclosure; never send a doc patch for a behavior gap.

**Coverage holes.** 12 of 39 PRs got zero Drew activity, including #596 (payments hardening),
#624 (ACP, pre-alpha), and — most notably — #627 (live agent session), the exact surface a dozen
findings defer to ("fix before live traffic", "before the live-session owner wires this in").
Absence of findings on those is absence of review, not cleanliness. The accumulated "must land
before live traffic" preconditions (queue bounds #606, sanitize-before-T13b #595, pending_input
real feed #605, dead-device telemetry #620) have no tracking artifact other than review prose.

---

## 5. Three highest-leverage process changes (adoptable tomorrow)

**Sufficiency judgment on the four already-adopted measures** (adversarial self-review stage,
claims-audit gate, security persona, doc-parity check): the corpus says *necessary but not
sufficient*. Claims-audit + doc-parity attack class B+H (~19%); the security persona and adversarial
self-review would plausibly have caught much of C and some of G (~20% more) *if pointed at the
right questions*. Structurally uncovered: **D (test methodology, 14%)** — persona review reads code,
not generators/oracles, and a self-confirming test looks green from every persona; **A+F recurrence
prevention (17%)** — six identical seam gaps in one day prove per-PR vigilance loses to an
architectural seam; **E (13%)** — nobody's checklist asks "what grows?". Hence:

### 1. Hostile-input generator standard + independent-oracle rule (attacks D, unlocks A and G)
Every property/golden/conformance suite touching content, paths, or identity must (a) draw from a
shared adversarial corpus — ESC/CSI/OSC/8-bit C1, invalid UTF-8, embedded `\n`/`\r`, wide emoji
(U+2300–U+23FF, emoji-presentation), symlinks (leaf *and* ancestor), digit-leading bracket labels —
and (b) assert against an oracle not derived from the code under test (SealOracle emulator replay,
OS realpath, the real DoneGate predicates). Justification by frequency: class D is ~14% directly,
and it is the stated reason classes A (11%, six HIGHs) and G's worst member (#613 CRITICAL) shipped
green — the same fix-shape covers ~35% of H/M findings. This is one shared test-support module plus
a review checkbox, adoptable in a day.

### 2. One enforced sanitization/width seam, with ingress fixed-point tests (attacks A+F at the recurrence level)
Finish what #613/#608-R4 started: route every PaintAuthority write (`seal`, `append_sealed`,
`repaint`, footer, flat) through `TermText.sanitize`/ContentGuard; add the ContentGuard fixed-point
assertion at each seal/repaint ingress (the #608 R4 pattern — the only mechanism in the corpus that
earned an on-the-spot CLEAN); collapse the divergent control-strip regexes (markdown_renderer vs
markdown_body) into one canonical helper; fix `wide_char?` (0x2300–0x23FF emoji-wide, C1 handling)
and make invalid-UTF-8 a handled input of the sanitizer, not a crash. Justification: A+F is ~17% of
H/M findings and 6 of 13 HIGHs in the first review batch; the corpus demonstrates the class dies
architecturally (post-seam PRs #619/#621 are verified-defended) and not procedurally (six modules
re-opened it in one day pre-seam). Constraint over checklist — wrong becomes impossible.

### 3. Reachability-honest PR framing + a wiring/preconditions ledger (attacks B, de-noises everything else)
Two-line rule per PR: every headline guarantee is declared **LIVE** (name the production call site
+ the test that fails if it breaks) or **SEAM** (zero callers — title and moduledoc must say
"unwired; inert until X"). Plus one lane-level ledger with two sections: (i) dormant seams awaiting
wiring (BlastRadiusGate.authorize, Ansi16Salience, classify/3 + seal_display_mode, StreamCadence
input_check, Surface.blur ↔ mode-1004, grade_blocks, render_streaming_incremental) and (ii)
before-live-traffic preconditions extracted from review prose (#605 pending_input real feed, #606
mailbox/bytes bounds, #618 wire the checkpoint, #620 dead-device telemetry/bound). Justification:
class B is the largest by count (~15%), ~8 PRs shipped dormant headline features, and Drew's own
resolution rule (honesty suffices for unwired code) means this change converts an entire finding
class into a one-line disclosure — the cheapest severity-mass reduction available. The ledger also
fixes the corpus's scariest structural gap: #627 (live session) is open and unreviewed while its
preconditions live only in the prose of seven other PRs' reviews.

**Also adopt as checklist lines (not full process changes):** absence-semantics sweep on decision
surfaces (§2.3 — covers the remaining C mass; give the adopted security persona this exact
question); root-cause-layer-first fix policy for review responses (#608 lesson — when the reviewer
names the owning seam, fix there first); fix commits get the full adversarial pass (#607/#608 —
two fix-introduced defects in 24h); a BLOCK verdict requires a recorded resolution round before
merge (#609 anomaly).
