# The PR Gauntlet — harness-ui pre-PR self-review checklist

Status: ADOPTED 2026-07-17. Derived from the 24h Drew-review corpus (48 review entries,
~70 CRITICAL/HIGH/MEDIUM findings across PRs #587–#629; analysis in
`DREW-PATTERNS-META.md`, corpus in `DREW-FINDINGS-24H.md`). Every item below is tied to
the finding class it kills and the PRs where it would have fired. Run the gauntlet on
EVERY PR before opening it, and again on every fix commit (two fix-introduced defects in
24h: #607 R2 sanitizer crash, #608 R2 two-sided regex).

Ordering is by expected yield — run top-down; the first three items carry all the
CRITICALs and BLOCKs from the corpus.

---

## 0. Persona order (before the checklist: how to read your own diff)

Simulate in this order — it matches where each persona has unique coverage:

1. **New Hire first** — one question: *"which documented sentence has no enforcing
   line?"* Cheapest check, sits at the convergence attractor: any yes tends to bloom
   into a multi-persona HIGH. Multi-persona-visible defects are exactly
   unenforced-stated-invariant defects.
2. **Security Auditor on fs/env/process/network seams only** — its unique coverage
   (world-readable tmpfiles, symlink races, env overrides, DoS axes). No other persona
   reaches these.
3. **Saboteur on hot loops, missing-data paths, and state machines** — its unique
   coverage (asymptotics, stuck states, fail-open defaults under absence).

Simulating all three on everything is NOT the lesson; the overlap region IS the
stated-invariant audit (item 2 below), and the persona-unique regions are narrow.

---

## 1. Byte-boundary trace  `[kills class A — 11%, 6 HIGHs in one day: #589/590/591/593/595/607]`

For every function that writes to a device or seals into scrollback:

- [ ] Enumerate byte sources. Any caller-supplied content routed through
      `TermText.sanitize`/ContentGuard **at the write seam** — not at the producer.
- [ ] Ingress fixed-point test at each seal/repaint ingress (the #608-R4 pattern:
      `sanitize(sanitize(x)) == sanitize(x)` and `guard(output)` holds). This is the
      only mechanism in the corpus that earned an on-the-spot CLEAN.
- [ ] "No raw ANSI" claims tested with content containing `\e[2J`, `\e[H`, OSC, 8-bit
      C1, embedded `\n`/`\r`, and invalid UTF-8 — not alphanumerics.

The seam exists post-#613. The check reduces to: *is this write routed through it, and
is there an ingress fixed-point test?*

## 2. Guarantee → enforcement → falsifier audit  `[kills class B — 15%, largest: #587/604/605/606/615/617/618/620]`

For each sentence in the PR title / moduledoc that states a guarantee:

- [ ] Name the **line that enforces it** and the **test that fails if it breaks**.
      No line or no test ⇒ reword or delete the claim.
- [ ] `grep` every new public function for production callers. Zero callers ⇒ declare
      **SEAM**: title and moduledoc must say "unwired; inert until X lands". Drew
      accepts honesty as *full resolution* for unwired code — this converts the largest
      finding class into a one-line disclosure.
- [ ] Complexity/behavior claims measured, not asserted (#605 claimed O(n) over an
      O(n²) `Enum.at` walk; #618's title was false for the commonest payload).
- [ ] Never claim test coverage for a function the test doesn't call (#605's false
      "covered by the property test").

**LIVE / SEAM framing rule:** every headline guarantee is declared LIVE (call site +
failing test named) or SEAM (disclosed dormant). Maintain the lane wiring ledger
(dormant seams + before-live-traffic preconditions) and link it from the PR body.

## 3. Absence-semantics sweep on decision surfaces  `[kills class C — 13%, 1 CRITICAL: #587/592/593/594/605/610/617/620]`

List every `Map.get(_, _, default)`, optional param, `rescue`, and catch-all clause on
any approval / authorization / degradation / keybind-guard path:

- [ ] Answer "what does **missing** mean here?" The safe default for a guard is the
      **restrictive** one: assume composing, assume irreversible, assume unproven,
      refuse the override on degenerate geometry.
- [ ] What does the recovery/default **render**, and is it **TRUE**? "No effects
      declared" ≠ "No effects" (#594 rendered "No tracked effects." under `rm -rf /`).
      Missing safety data renders as an explicit unsafe-warning, never a reassuring
      zero-state.
- [ ] Rescue clauses classify precisely — an over-broad rescue reclassifying logic bugs
      as retryable device failure (#620) is a fail-open.
- [ ] Direction check: over-reporting (unread, danger) is acceptable fail-safe;
      under-reporting is not (#615/#617 endgame rule).

## 4. Referent-vs-representation check  `[kills class G — 14%, 2 CRITICALs, highest severity: #587/595/609/610/613/619]`

For each validation, ask: *am I checking the thing, or a proxy for the thing?*

- [ ] Prefix match ≠ host equality (`localhost.evil.com` passed #595's
      `validate_base_url!`).
- [ ] Lexical path ≠ resolved realpath (#613's symlink escape — CRITICAL).
- [ ] Key-exists ≠ gate-accepted (#619 checked `Map.get` existence while five
      acceptance predicates went unenforced).
- [ ] Partial identity ≠ identity (#587 denied by bare `call_id` while grants keyed the
      full ref).
- [ ] One flag ≠ the real question (#609's `:not_composing` guard read `composing?`
      when the question included `overlay_open?` — CRITICAL).
- [ ] Tests for these use an **independent oracle** (OS realpath, SealOracle emulator
      replay, the actual gate predicates) — never the module's own output (#613's
      property validated confine against confine).

## 5. Generator/oracle adversarial audit  `[kills class D — 14%, the enabler class: #588/589/590/591/609/610/611/613/618]`

Three questions per property/golden suite:

- [ ] **(a)** Does the generator contain the hostile alphabet for this surface? Shared
      adversarial corpus: ESC/CSI/OSC/8-bit C1, invalid UTF-8, embedded `\n`/`\r`, wide
      emoji (U+2300–U+23FF, emoji-presentation), symlinks (leaf AND ancestor),
      digit-leading bracket labels. Benign-only generators are why class A shipped six
      times in one day.
- [ ] **(b)** Is the oracle independent of the implementation? (#618 R2's work metric
      read the field it validated.)
- [ ] **(c)** Does any test **pin** a default rather than challenge it? (#592's test
      codified the fail-open; #609's overlay test pinned `composing?: true`, masking
      the CRITICAL.)
- [ ] Threshold tests must detect weakening, not just removal (#611 couldn't
      distinguish clamp-removed from clamp-loosened-50×). Ratio/invariant asserts over
      absolute wall-clock.
- [ ] No blanket `:skip_on_ci` on the sole coverage of a subsystem (#588).
- [ ] "Exhaustive" properties: name the failure arm the model treats as infallible —
      that's where the vacuity lives (#610).

## 6. Growth inventory  `[kills class E — 13%: #587/594/605/606/611/617/618/621]`

One table per PR: each new collection / queue / accumulator / loop → its bound → what
enforces the bound.

- [ ] Per-frame code touching session-lifetime data = automatic flag (#605, #617).
- [ ] Caps state whether they count items or **bytes** (#606 R2).
- [ ] Drop semantics fit the stream model (snapshot vs append-only).
- [ ] No per-keystroke work proportional to unbounded external state (#621's
      filesystem scoring).
- [ ] Log emission bounded (frame-rate log flood, #594).

## 7. Fix-commit re-gauntlet  `[#607/#608: two fix-introduced defects in 24h]`

- [ ] Every fix commit gets the full gauntlet, same as the original diff (#607's fix
      introduced a `/u` regex crash on invalid UTF-8 — on the exact untrusted caller
      it defended).
- [ ] **Root-cause-layer-first:** when the reviewer names a layer mismatch ("undecidable
      at this layer, own it at seam X"), the first fix commit goes to seam X — never a
      better heuristic at the wrong layer. This deletes whole review rounds (#608
      R2→R4 was compressible to one round).

---

## Response playbook (deterministic — what flips Drew's verdict)

| Finding type | Response that works | Response that does NOT work |
|---|---|---|
| Behavioral gap | Enforcement + reproduction: red→green test, tripwire he can re-break, measured delta (498×→1.0×) | Doc patch, dependency-constraint argument ("cannot re-validate here" — called a false constraint) |
| Claim on dormant/unwired code | Honest disclosure: "INERT at runtime until X lands" | Arguing the claim is aspirational without saying so in the artifact |
| Reachability-wrong finding | Traced-invariant rebuttal **plus** enforce the invariant with a tripwire (#617 R4 — Drew re-broke it himself to verify) | Rebuttal alone — severity stays worst-case; only the verdict is reachability-weighted. Mirror that split; don't argue severity down |

Additional rules:

- A **BLOCK verdict requires a recorded resolution round** before merge (#609 merged on
  a BLOCK with no recorded round — never repeat).
- Four of 48 review entries were pure CI-nag. Don't make the reviewer babysit CI: check
  `gh pr checks` before requesting re-review.
- Negative results are disclosed (Drew publishes his own refuted hypotheses; we do the
  same in response ledgers — it's why surviving findings are credible).

## 8. Visual-doctrine falsifiers  `[any diff touching rendering; source: docs/proposals/in-flight/harness-visual-doctrine.md §7]`

- [ ] **Unbound pixel** — every rendered value traceable to journal/model state.
- [ ] **Timer-clocked motion** — no animation/tick driven by wall time; events only.
- [ ] **Claimed prominence** — no hand-set brightness/salience bypassing the H-K solver;
      no raw hex/RGB in a component — semantic role tokens through the palette layer only.
- [ ] **Register bleed** — no rim idiom in the log (nothing in history animates or
      repaints), no log idiom broken on the rim.
- [ ] **Performed activity** — no spinner/meter without an attached evidence surface
      (phase name, live number, receipt on completion).
- [ ] **Unearned ceremony** — every boot/exit/transition beat backed by a real check or
      real event.
- [ ] **(v2) Label-vs-binding divergence** — affordance text must match its declared call.

Meta-falsifier: a meter not wired to real numbers collapses the register to theater —
the one defect class the brand cannot survive.

## Red lines (structural, never re-litigate)

- No raw ANSI in View DSL strings; all device writes through the sanitization seam.
- No `\e[2J`/`\e[3J` on the inline surface; immutable-prefix byte invariant holds.
- Fail-closed on approval/authz/degradation; explicit-unknown over reassuring-zero.
- No wall-clock in tests where a work-metric or ratio exists; order-of-magnitude bounds.
- No Co-Authored-By trailers (Drew's standing requirement).
- mix.lock: gates first, `git checkout -- mix.lock` LAST, no mix commands after.
