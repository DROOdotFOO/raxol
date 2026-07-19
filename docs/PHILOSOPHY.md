# Philosophy

Raxol has one law, applied at every scale:

> **What is shown must be a provable projection of what is, and the wrong
> thing must be unrepresentable.**

Everything else in this repository is that law showing up at a different
altitude. This document names the law once, shows where it recurs, and states
what it implies for anything visual built on the framework. It is the "why"
behind the rules that other documents state as "what" (ADR-0029,
`docs/WHY_OTP.md`, `docs/core/RENDERING.md`, the design-science material).

## The law at each scale

**The cell.** A terminal is not a canvas; a cell holds one grapheme, two
colors, a few attributes, and nothing else. There is no alpha: a cell is
transparent precisely when we emit no background SGR for it, so transparency
is an absence, not a value. Almost every rendering bug this project has
shipped came from one name doing two jobs (`:black` meaning both "unpainted"
and "black"; `nil` meaning both "transparent" and "erase"), and the fix was
always the same move: split the meanings apart and make the wrong one
unrepresentable. See ADR-0029.

**The model.** `update/2` is pure; effects are Directives the runtime
executes. Because the model is a fold over messages, the journal is the
ground truth and every rendered frame is a disposable projection of it. Kill
the UI, respawn it: same truth. Time-travel debugging is not a feature we
built so much as a reward for purity we refused to give up.

**Color.** Hierarchy is solved, not eyeballed. The salience solver
(`Raxol.UI.Theming.Salience`) levels apparent lightness per tier against the
user's detected terminal ground, so a color's prominence states its
importance and cannot quietly misstate it. One `:anchor` per screen;
hierarchy is zero-sum, and two anchors are zero anchors.

**The interface.** A UI discloses state; it does not perform activity. No
spinner-forever, no success toast without evidence, no motion that does not
encode a state change. "Done" carries its evidence. Restraint is the trusted
register; ornament reads as slop. Interactive approval that degrades to
rubber-stamping is worse than no approval at all, which is why guarantees
live in enforcement layers, not in reassuring chrome.

**Money.** A process that holds a signing key is the crown jewel. The ledger
reserves atomically; in-flight intents are checkpointed; a crash
mid-settlement resumes to exactly one debit, because an ungoverned runtime
with no memory of the in-flight payment would re-sign and debit twice. The
spending policy is enforced by the same runtime that renders the screen
showing it.

**Agents.** An agent is not a client scraping our output; it is a second
species of observer reading the same Component tree through a different
projection. Terminal cells, LiveView DOM, and MCP tools are functors from
one source category (ADR-0012), so a human and an agent can never be shown
two different truths. The corollary cuts both ways: if an agent cannot tell
what is action and what is decoration in your component tree, your visual
hierarchy is probably lying to humans too.

**The prose.** Documentation that describes an API that does not exist is
the same defect class as a double debit. Docs get corrected toward what the
code does, not what a draft imagined.

## Why the origin story is one idea, not two

The README gives two seeds: a terminal for AGI, and the cockpit of a Gundam
Wing Suit. They are the same seed. Both describe a machine that a human (and
now an agent) must trust with real stakes while it is under fire: it cannot
go down, cannot lose state, must hot-swap components while running, and must
never show its operator something untrue, because the operator acts on what
the panel shows. The cockpit constraint set is the law under adversarial
conditions; the agent surface is the law extended to a second kind of
reader. OTP is not a technology preference here, it is the terrain the
problem keeps pointing back to: crash isolation, supervision, hot reload,
and distribution are what "cannot lie, cannot die" compiles to on the BEAM.

## Costume and body

Two registers coexist in this repository and must not be confused.

The **costume** is the flavor: synthwave palettes, border-beam comets, the
ZERO System's self-check and funnels. It is theater, and it is welcome.

The **body** is the discipline underneath: the cell model, the salience
solver, the journal, the ledger, one anchor per screen, adapting to the
user's terminal instead of painting over it. The character grid deletes
size, gloss, and shadow, which removes the tools that let design lie; what
remains is hierarchy, rhythm, and restraint, which were always the real
ones.

The costume only works because the body is real. The ZERO System demo lands
because the funnels are live CRDT entities, the boot lines probe real
modules, and the crash beat is pinned by `payment_recovery_test`. Scarcity
reads as authenticity, and authenticity reads as stakes. Beauty in Raxol is
evidence of engineering seriousness, never a substitute for it. A demo that
faked any of it would be ornament, and ornament reads as slop.

## What this implies for anything visual

The target feeling is sitting in the seat: dense, quiet, one thing glowing,
and complete certainty that if something goes wrong the panel will show it,
and if the panel shows nothing, nothing is wrong. That certainty is the
product. Concretely:

- An instrument panel grown around a log, never a replacement for the log.
  The terminal stays a terminal; the shell never takes the screen.
- Every visual element is a projection of durable truth, with prominence
  proportional to relevance. Every pixel passes "what does this tell me
  right now?"
- Trust comes from legibility, not reassurance. Calm is what a machine that
  cannot lie looks like.
- We are a guest in the user's terminal, not an occupier: their background,
  their scrollback, their light mode, their reduced-motion setting.
- Emptiness is paid for with information density elsewhere; that payment is
  what reads as confidence.
- When reviewing a visual change, the question is never "does this look
  right?" On the author's configuration it will. The question is: what is
  this value's one job, and what happens when the user's terminal is not
  mine?
