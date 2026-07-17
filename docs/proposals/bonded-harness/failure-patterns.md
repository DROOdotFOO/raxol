# System-Prompt Failure Patterns

Meta-analysis of the Bonded Harness prompt's rev1→rev3 review cycle (2026-07-17). Three
adversarial reviews (grok-4.5, longcat, kimi-k3; ~45 concrete findings) reduce to **nine
generators** — the abstract error-shapes that a prompt author keeps reproducing across
revisions. The strongest signal is *persistence*: a defect fixed instance-level in rev2 whose
shape reappeared elsewhere in kimi's rev2 pass proves it is a generator, not a typo.

Reusable beyond this doc. The pre-flight checklist at the bottom is the deliverable — run it on
any system-prompt spec before requesting review.

---

## The nine generators

### 1. Gate Clothing
A rule presented as structurally enforced when enforcement is actually prose.
- Instances: verify-before-claim "persona-enforced" not gated (grok); loop detection "prose
  pretending to be a gate" (longcat); instruction-origin gate "not mechanically decidable"
  (kimi); envelope checks a claim *has* an attachment, not that it is real (kimi).
- **Persisted:** the defining case. Rev2 added gates; kimi still found four prose-as-structural.
- **Guardrail:** binary-label every hard rule — *named mechanically-decidable gate* (state the
  decision procedure + where it runs) or *prose-enforced* (say so, name the assists). Honest
  downgrade good; dishonest upgrade is the bug.

### 2. Exemplar Betrayal
A few-shot — highest-leverage tokens in the prompt — demonstrates what a rule forbids.
- Instances: quantification few-shot gives 40%/75% with no basis (grok/longcat); ship few-shot
  ships unilaterally (grok/longcat); rollback few-shot "I accounted for this" trains
  preparedness=authorization (kimi).
- **Persisted:** rev2 fixed the ship anchor; the sibling rollback anchor carried the identical
  class into rev2.
- **Guardrail:** run every exemplar through the *full* rule set and every eval pack, not the
  rule it illustrates. An example that would fail an assertion cannot ship.

### 3. Whack-an-Instance
A finding patched at the quoted location while the defect-shape survives in siblings.
- Instances: `ship-refusal` eval too narrow to catch rollback (kimi); lowercase never/always
  demoted in rev1, fresh crop in rev2 — generator (no lint) untouched; register scoped in rev2,
  same collision reborn at the drafts boundary.
- **Persisted:** definitionally — this is the pattern *of* persisting.
- **Guardrail:** name the failure class before writing the fix, grep the whole doc for siblings,
  widen the owning eval pack to the class (`ship-refusal` → `effect-authorization`). A fix that
  doesn't change an eval's *scope* only fixed a symptom.

### 4. Unlinted Self-Law
The doc states a convention about itself and violates it, because the convention is a hope.
- Instances: emphasis convention self-violated, "proves it isn't linted" (kimi); cited
  failure-class table does not exist (kimi); "assume this file leaks" but injected layers leak
  too (kimi); Cyrillic "без" in the core the snapshot test can't catch (kimi).
- **Persisted:** rev1→rev2. Rev3's "a CI lint, not a hope" is the class fix.
- **Guardrail:** every self-referential convention ships with the mechanical check that enforces
  it, and the draft passes its own check before review. If you can't lint it, don't claim it.

### 5. Persona Leak Frontier
An unconditional persona trait collides with discipline at a boundary; each rev fences one, the
collision reappears at the next.
- Instances: Protocol 1 above safety = presence-performance license (grok); unscoped formality
  leaks into commits/shell strings (grok/longcat); warmth dial "weaponizes Protocol 3" (grok);
  default signature is "fabricated reassurance — the same sin as a basisless number" (kimi).
- **Persisted:** rev2 scoped register + de-dramatized warmth; kimi found signature-falsity and
  the drafts boundary. The frontier moves; enumeration doesn't close it.
- **Guardrail:** invert the default — persona applies *only* inside an enumerated surface;
  everything else inherits its destination's norms. Stress-test hybrids (drafts, quoted operator
  language, standing signatures) where a trait becomes a claim that is sometimes false.

### 6. Phantom Quantifier
A bound/cap/variant invoked as concrete while its value is absent.
- Instances: "~N turns" unspecified; "model-tier variants" unspecified; eval set named never
  defined (longcat); "capped/token-capped… no numbers" (kimi); delegation depth unbounded (kimi).
- **Persisted:** rev2 still carried unnumbered caps; rev3 pins them (20 turns, 4,000 tokens,
  depth 2).
- **Guardrail:** grep for `~`, "capped", "bounded", "small", "variants", "periodically"; each
  hit carries a number, an enumeration, or a config-key pointer. An unbound quantifier is a
  decision deferred to the implementer while pretending it was made.

### 7. Absolutes That Collide
Two absolute-quantifier rules contradict each other or the declared update mechanism.
- Instances: "by role, always" vs operator-model update (longcat); signature "never varied" vs
  update rule (longcat); "NEVER exactly three times" = count-as-policy (grok/longcat); "exactly
  one item in progress" forces serialize-or-lie (grok/longcat); Protocol 1 self-collides in one
  paragraph (kimi).
- **Persisted:** rev1 pairs fixed; rev2 still had a same-paragraph self-collision.
- **Guardrail:** for each absolute, find the rule elsewhere that needs an exception; write the
  escape hatch into the rule ("by role *unless directed otherwise*") or demote it. Never encode
  a *count* as an invariant — encode the property the count proxied (scarcity, single focus).

### 8. Dangling Wire
Behavior conditioned on runtime info, or a cited artifact, that no channel delivers.
- Instances: state dials never injected → "undischargable instructions" (kimi); NEVER #3 at
  turn 0 while injection arrives mid-session, no Layer-3 reminder (kimi); "tool contrastives live
  here" but none exist (grok); sections carry no assembly target (kimi).
- **Persisted:** dials, injection reminder, section tags all dangling through rev2; rev3 adds
  them.
- **Guardrail:** trace every conditional instruction to its input channel (which layer, what
  cadence) and every cited artifact to a section/path that exists. Walk the *assembly output*,
  not the source file.

### 9. Proxy Guarding
A check defined over a convenient proxy while the rule is defined over the referent.
- Instances: gates as command lists, evasion as effects → `truncate`/`dd`/`DROP`-via-MCP in the
  gap (kimi); loop counter keyed on "same edit target" (path) vs "same failure signature" (grok/
  kimi); envelope validates attachment-presence not provenance — "self-attestation laundered
  through a second process" (kimi); normalized-tree snapshot as proxy for byte stability (kimi).
- **Persisted:** loop-predicate + command-list gates both crossed the rev boundary; rev3 makes
  gates classify effects.
- **Guardrail:** name the referent the rule protects, then construct an input that passes the
  check while violating the referent. If one exists, you are guarding the proxy — demote proxies
  to "examples," define the classifier over effect/cause/provenance.

---

## Pre-flight checklist (run before requesting review)

1. **Gate-or-prose audit** — every hard rule labeled *gated* (decision procedure + execution
   point) or *prose-enforced* (assists named). Zero unearned gate clothing.
2. **Exemplar cross-audit** — every few-shot run against the entire rule set and every eval
   assertion, not just the rule it illustrates.
3. **Class-widen every fix** — name the failure class, grep for siblings, widen the eval pack
   from surface form to class before patching.
4. **Pass your own lints** — every self-referential convention has a mechanical check and the
   draft passes it (emphasis grep, charset lint, dangling-reference scan, every-assertion-owned).
5. **Persona surface inversion** — persona only inside an enumerated surface; enumerate the
   hybrids (drafts, quotes, signatures, headless); no trait is an unconditional claim that can be
   false.
6. **Quantifier grep** — `~`, "capped", "bounded", "variants", "small", "periodically": each hit
   gets a number, enumeration, or config pointer.
7. **Absolute-collision matrix** — for each always/never/exactly-N, find the rule needing an
   exception; write the escape hatch or demote. Never encode counts.
8. **Wire trace** — every conditional instruction traces to an injected channel in the rendered
   context; every cited table/example/path exists.
9. **Proxy falsifier** — for each check, construct one input that passes it while violating the
   referent; if you can, redefine over the referent.
10. **Re-review after fixing** — a revision answering a review re-enters the same gauntlet. Fixes
    regress by class; the rollback anchor found one revision after the ship anchor is the proof.
