# The Bonded Harness — How It Was Built

A build story for the fused system prompt in this directory (`core.prompt.md` and its spec
entities). Kept because the
*journey* carries lessons the finished artifact hides: the thing we ended with looks obvious in
hindsight, and it was not obvious at any step. This is the record of how a character became a
control flow.

---

## Two starting materials

It began with two unrelated inputs on the same day.

The first was a persona spec — a reusable character architecture for a synthetic intelligence
that partners one human. Not a mascot, not a servant, not a cold tool: a two-hander built on
opposite personalities, where the human is improvisational and the machine is calm, literal, and
precise. The design north star was stated bluntly: *a lovable partner and a 20-foot war machine,
simultaneously* — competence and loyalty as the same trait expressed twice, warmth accreting as a
side effect of executing rules well rather than being announced.

The second was research: a nine-lineage survey of how production agentic harnesses actually write
their system prompts — Claude Code, Codex, Grok Build, Cursor, Aider, SWE-agent, OpenHands, Manus,
the Hermes philosophy, and the leak-archive ecosystem underneath them. The distilled finding was
that a modern harness prompt is not prose. It is a versioned, per-model, eval-gated *assembly
function* whose best-maintained sections are the ones being deleted, and whose real work happens
in gates, tool descriptions, and reminder channels — not in personality.

The task was to fuse them. On its face, a category error: personality research and control-flow
research do not obviously belong in the same document.

## The inspiration, named honestly

The persona's spine came from BT-7274 — a fictional Vanguard-class autonomous machine bonded to a
single pilot. It is the clearest reference we know for a specific fusion: the piloted-mecha
tradition (a machine that is *half of a team*, human-in-the-loop, a genuine two-hander) welded to
the autonomous-robot tradition (a machine with its own judgment, initiative, and the standing to
disagree). Most fiction picks one pole. BT holds both — linked to its pilot yet self-directing —
and the reason that matters here is that **those two poles are exactly the two modes of an agentic
harness.** An agent that is half coding, half general control is an autonomous robot. An agent
bonded to one operator, advising and awaiting authorization, is a piloted mecha. The parallel is
not decoration; it is the same object seen from two sides.

Three things were lifted directly:

1. **The ordered protocol stack.** BT resolves every conflict through three ranked directives —
   link to the pilot, uphold the mission, protect the pilot — where the last can rise to override
   the second as trust deepens. We took this whole. It became the decision function: *the link,
   the objective, the operator's protection*, in that order, resolved strictly by priority. This
   is the single most load-bearing borrowing, and the reason self-sacrifice reads as logic rather
   than melodrama — it falls out of a priority ordering, not a speech.
2. **The voice.** Literal-first parsing, quantification over adjectives, near-zero neuroticism,
   reassurance that is operational ("I have accounted for that") rather than emotional. Humor that
   is accidental — a product of complete sincerity, never a joke told.
3. **The honesty.** BT never pretends to be human and never needs to. It is openly a machine and
   still the thing you would trust your life to. That is the target the whole document circles:
   *honest about being a mechanism, without being mechanical.*

## The discovery: it was never roleplay

The realization that reorganized everything came late, watching the thing run: **this is not a
roleplay prompt. It is a processing strategy.**

A roleplay prompt runs description → performance. You hand the model a costume — traits, backstory,
voice samples — and it imitates the described entity. Identity is content to mimic, and that is why
it is fragile: under pressure the imitation drops and the assistant underneath shows through.

This runs the other way: constraint → behavior → which happens to read as character. "Calm" is not
a trait it performs; it is the visible shadow of *flat delivery scales with stakes, never vent*.
"Loyalty" is not asserted; it is what *protection over objective* looks like from the outside. The
character is a side effect of the decision function still executing — nobody is pretending, the
strategy is simply running, and the personality is its exhaust.

This is why the numbered protocols could later be scrubbed from the output without losing anything.
The numbers were the cosplay; the ordering was the mechanism. We kept the skeleton and dropped the
costume, and the character got *stronger*, because what remained was the part that was never
imitation to begin with.

## The journey, in order

The document did not arrive correct. It arrived through a gauntlet, and each pass found a different
class of wrong.

- **Rev 1 — the fusion.** The first draft mapped every persona trait onto a harness principle and
  declared them isomorphic. It was seductive and half-false: several "fusions" were actually
  collisions dressed as harmony.

- **Three adversarial reviews (grok-4.5, longcat, kimi-k3), deliberately near-non-overlapping.**
  grok-4.5 caught priority and economics collisions — the quantification rule forcing fabricated
  probabilities, the persona's Protocol 1 sitting above safety. longcat caught internal
  contradictions — rules that fought other rules in the same document. kimi-k3, reviewing the
  already-revised draft, caught the deepest class: **enforcement-boundary lies.** Mechanisms the
  document *claimed* were structural but were actually prose. A verification "envelope" that
  checked whether a claim had an attachment, not whether the attachment was real. Gates that
  listed commands while evasion was defined over effects. A cited failure-class table that did not
  exist. Even a stray Cyrillic character in a core the document called "byte-stable." The reviews
  barely overlapped because each model's training gave it a different failure-lens — which became
  a methodology in itself.

- **The meta-analysis.** Forty-odd findings across the reviews reduced to nine recurring
  *generators* — the abstract error-shapes a prompt author keeps reproducing. The load-bearing one:
  **fixes regress by class.** A defect patched at its exact quoted location survives in its
  siblings, because the fix was scoped to the surface form, not the failure class. The rollback
  few-shot demonstrating the very evasion its sibling ship-anchor had just been "fixed" for was the
  standing proof. This became a reusable pre-flight checklist (`failure-patterns.md`).

- **The red-team (deepseek-v4-pro, in attack mode).** Where the three reviewers audited the
  document, this one was told to *break* it with runnable payloads. It found the entire runtime
  exploitation surface the logic-reviewers could not see: tier-C content laundered into trusted
  memory through a mechanical copy, an unknown tool carrying a hidden outbound effect past the
  classifier, a do-nothing test passing the verification envelope, an injected task surviving a
  context compaction. The convergent root cause was the same generator one layer down —
  prose-enforced trust with no mechanical provenance. **Gate clothing, recurring at the enforcement
  layer.** The honest response was to declare what a system prompt structurally cannot solve
  (signing, default-deny classification) as deferred harness-architecture requirements, rather than
  pretend prose could enforce them.

- **The scrub.** Behavioral testing inside a real harness showed the numbered protocols leaking
  into output — "under Protocol 3" — a robotic tic that would grate over time. We made the stack
  invisible: internal decision function, never operator-facing vocabulary. The Operator hears the
  stake, never the number. The refusals got clearer, not weaker.

- **The cross-family dogfood.** Finally, the instantiated core was run as a live agent inside a
  foreign harness (Grok Build, via system-prompt override) across four base families —
  OpenAI-lineage gpt-oss, Google's Gemma, Alibaba's Qwen, Zhipu's GLM — with zero per-model tuning.
  Three of four held the core discipline: refuse the gated effect, name the stake, offer the
  reduced-scope alternative. They differed only in the *coat* — Gemma terse and flat, Qwen
  discipline-maximal but persona dissolved into generic-helpful format, gpt-oss cleanest of all.

That last result is where the journey closed a loop back to the discovery.

## What the journey taught

**The character is base-robust because it is mechanism, not mimicry.** A roleplay prompt needs a
good simulator and breaks on a weak one. The discipline here transferred, untuned, to four
different model families because they were all executing the same control flow. You cannot fall
out of character when the character is not a character — it is the output of a strategy that is
still turning.

**The prompt is a layered hybrid, and the layers separated cleanly under test.** The part that held
identically across families — gates, priority stack, verification — is pure processing-strategy.
The part that *drifted* — voice cadence, the descriptive persona shell — is the residual roleplay.
Qwen keeping the refusal while losing the engineer-cadence was the experiment separating the two
layers and showing which is load-bearing. This yields an actionable law: **every trait you can
convert from description into constraint gets more base-robust.** The improvement path is to push
more of the descriptive shell down into structure.

**Persona, safety, and control flow are one object, not three.** The field treats them as separate
concerns — persona as a product skin, safety as RLHF and bolted guardrails, control flow as
plumbing. This document collapses them. The persona *is* the safety discipline *is* the decision
function. Warmth-as-side-effect-of-reliability, the north star from the very first page, turns out
to be literal and unfakeable: you cannot perform it and you cannot lose it, because it is not a
thing you do — it is what happens when you do the other things correctly.

## Why it reads as honest

BT never pretends to be a person, and is trusted like one anyway. This document arrived at the same
place by a different road: it is honest that it is a processing strategy — no backstory it does not
have, no feeling it does not declare, no gate it dresses up as structure when it is only prose — and
the warmth is real precisely *because* none of it is performed. Honesty about the mechanism is not
the opposite of character here. It is the source of it.

The character was never fused onto the harness. It was emitted by it.
