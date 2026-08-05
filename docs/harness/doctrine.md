# Harness Doctrine: the visual laws

The one law, *what is shown must be a provable projection of what is, and the
wrong thing must be unrepresentable*, is stated once, at every scale, in
[../PHILOSOPHY.md](../PHILOSOPHY.md). This document is that law applied to the
harness surface: the concrete visual constraints a harness change must satisfy,
and why. Read PHILOSOPHY first; this does not repeat it.

The harness optimizes three operator moments, and anything serving none of them
is suspect:

- **Watching**: glanceable truth: what it is doing now (a named stage, not a
  spinner), what it has consumed, what it needs from you. Working and hung must
  be distinguishable at a glance.
- **Deciding**: the approval arrives at the decision moment with the diff
  already there, expandable, blast radius stated. An illegible prompt gets
  rubber-stamped, so the ones that remain must be maximally legible.
- **Returning**: catch-up as evidence (what changed while you were away),
  never a success toast.

## Zone ontology: the log and the rim

Two zones with two ontologies and two registers. The split *is* the visual
language.

| | **Log** (center) | **Rim** (edges, overlays) |
|---|---|---|
| Ontology | History: a projection of the journal | Present: a projection of live state |
| Register | Literate: markdown, prose-shaped, chromeless | Instrument: readouts, meters, framed |
| Motion | Never animates; append-only | The only zone that breathes |
| Lifecycle | Permanent facts with receipts | Ephemeral; dies into the log on settle |

The register split is a **provenance channel**: the literate register is the
machine's own body speaking; the instrument register is a grown instrument
speaking. Never bleed one register into the other zone.

"Never animates" is a **logical** law about content, not a byte law: a sealed
block's content never mutates, but the full-viewport substrate is free to
repaint the screen from the model. The immutability that matters is the fact,
not the pixels.

## The clocking law

**Motion is clocked by the event stream, never by wall time.**

- Motion exists only while events flow. Spinners and meters tick on event
  arrival; events stop and the screen goes still. "The panel shows nothing"
  therefore *means* "nothing is happening". It is a property of the render
  loop, not a promise. (`Raxol.Harness.StreamCadence` paces egress off real
  ingest; the `StatusStrip` spinner rides the existing tick, never a new timer.)
- Moving is an in-flight claim (dim/italic); still is a settled fact. The
  freeze to full weight is the commit beat.
- Completion is one event-driven blink, after which the widget dies into the
  log as a fact line carrying its receipt. Nothing lingers.
- No easing, no decorative transitions: an instant snap reads as native.
- The one rule that sorts every future flourish: a flourish is legal if and
  only if a real event in the stream drives it, and illegal on a timer.

## Channel grammar

- **Color.** Achromatic chassis; chroma is signal. Color encodes *state, never
  speaker*. The error hue is withheld from the resting UI: the alarm works
  because the room is otherwise silent. Roles resolve through the theme, never
  raw hex, and prominence is granted by the salience solver
  (`Raxol.UI.Theming.Salience`) and the region policy against the user's real
  ground (see [../core/RENDERING.md](../core/RENDERING.md)), never hand-set.
  One certified-bright anchor per screen; two anchors are zero anchors.
- **Border and shape.** The log has no boxes, nesting is carried by indent and
  gutter. The rim uses recessive single-line bezels and a heavy `┃` rail for
  ownership or selection. Border *color* may carry focus or status; border
  *shape* never varies decoratively.
- **Typography.** Four channels, one meaning each: **bold** = structure,
  **dim** = supporting or provisional, **italic** = in-flight, **reverse** =
  the one selected thing. The dim ramp is the opacity substitute. Lowercase for
  identity and status; UPPERCASE only for rim instrument labels.
- **Evidence.** "Done" carries its receipt inline: exit code, diff stat,
  duration, tokens, cost. The waiting state is evidential too: a named actual
  phase plus a live meter (`running mix test · 12s · 3.1k tokens`), never a
  whimsical gerund and never naked stillness.
- **Voice.** Terse, factual, lowercase-calm; warmth comes from precision. An
  error is a sober diagnostic plus evidence plus what the machine already did
  about it. Ceremony is legal only when it is itself evidence.
- **Sound.** One semantic completion event, a two-note language at most
  ("done" / "needs you"), fired by the event stream, silent by default.

## Falsifier classes

A harness visual change is reviewed against these. Any one is a defect:

1. **Unbound pixel**: a rendered value not traceable to journal or model state.
2. **Timer-clocked motion**: animation driven by wall time instead of events.
3. **Claimed prominence**: hand-set brightness or salience bypassing the
   solver; raw hex in a component instead of a role token.
4. **Register bleed**: the rim's idiom in the log (history animating as
   content) or the log's idiom broken onto the rim.
5. **Performed activity**: a spinner or meter asserting work with no evidence
   surface attached.
6. **Unearned ceremony**: a decorative boot, exit, or transition beat not
   backed by a real check or event.

The meta-falsifier: faking the evidence look while faking the wiring beneath it
collapses the register to theater: a meter not wired to real numbers loses
everything at once. It is the one defect class the surface cannot survive.
