# Harness Visual Doctrine

> The visual guidelines for the Raxol harness. This is doctrine, not mood-board: every rule
> here is the soul law applied to a rendering channel, and every rule has a falsifier a
> reviewer can check. Binds both lanes (harness-agent, harness-ui).
>
> Evidence base: `docs/proposals/research/tui-aesthetics/` (39 dossiers, 3 synthesis
> sections, `LANDSCAPE.md`). Perceptual layer: the H-K salience solver + `tui-design-science`.
> Companion reading: `harness-ui-north-star.md`.

---

## 0. The soul, and what the visuals must do

**Raxol is a machine that cannot lie to the one flying it.** The law: what is shown must be
a provable projection of what is, and the wrong thing must be unrepresentable — applied here
to pixels.

The target feeling is not "wow, cool terminal." It is the feeling of sitting in the seat:
dense at the rim, quiet at the center, one thing glowing, and complete certainty that if
something goes wrong the panel will show it — and if the panel shows nothing, nothing is
wrong. That certainty is the product. Every rule below manufactures it structurally instead
of theatrically.

The identity position (unclaimed by any shipped agent — see LANDSCAPE §2, the coding-agent
table): the **evidential instrument**. Claude Code is the literate houseguest, aider the
austere craftsman, Gemini the consumer product, Grok Build the theatrical cockpit, Crush the
synthwave bestie. Raxol is the one whose aesthetic *is* epistemic honesty: an instrument
panel grown around a log.

---

## 1. The two pillars

### 1.1 Solved attention (the H-K economy)

We operate on **perceptual attention — hue and computed prominence — not specific colors.**
The Helmholtz-Kohlrausch solver computes apparent lightness against the user's *actual*
ground and assigns prominence tiers. Consequences:

- **Prominence is granted, never claimed.** A component declares a semantic role and a
  salience *request*; the solver assigns the tier. Hand-tuned "make this brighter" is the
  visual equivalent of `Job.StateMachine` bypass — unrepresentable by construction.
- **One anchor per screen, zero-sum.** The solver maintains exactly one certified-bright
  point. The recognizable Raxol screenshot is: quiet field, one glowing element,
  mathematically placed. The discipline is the logo.
- **Guest, not occupier.** We never paint the user's background. The solver adapts to their
  ground; the brand is a temperature threaded through roles, not a skin. (Corpus: the
  Claude/lazygit/brick "inherited canvas" register — the trusted one.)
- This pillar is what makes pillar 1.2 possible at all: dynamically grown UI has no human
  hand balancing the screen. The solver is the only thing that can hold coherence across an
  emergent widget set. **Generative composition, solved attention.** Nobody else can do the
  second without the first, and nobody else has the first.

### 1.2 Minimal-but-deep (the grown cockpit)

The harness starts as almost nothing and grows around the user's work:

- **Start: a charged minimum.** After onboarding, a bare prompt — aider's register. But
  charged, not empty (corpus warning: "airiness with nothing to say"; identity stamps in the
  first five seconds). The minimum state carries the full identity load: the boot
  self-check, the prompt sigil, one H-K-certified anchor even when the anchor is just the
  input. Absence reads as *readiness* — a coiled instrument, not an empty tool.
- **Growth: instruments accrete as work happens.** A long-running bridge/solve/generation
  gets a live status widget; it exists because the work exists. UI builds around what the
  person needs, never around what we want to show.
- **Persistence: the cockpit is earned.** Some instruments are session-scoped, some
  project-scoped, some global. A month in, the user sits in a panel shaped by their own
  behavior — "this machine is MINE" achieved through work, not dotfiles. (Ricing-by-working;
  no shipped app in the corpus does accretive UI. This is the second unclaimed
  differentiator.)

---

## 2. Zone ontology: the log and the rim

The screen enacts the architecture. Two zones, two ontologies, two registers — the split IS
the visual language.

| | **The log** (center) | **The rim** (edges/overlays) |
|---|---|---|
| Ontology | History. Projection of the journal. | Present. Projection of live state. |
| Register | Zen-literate: markdown, prose-shaped, airy in Y, left-anchored | Diegetic retrofuturism: readouts, brackets, meters, dense |
| Chrome | Chromeless — "a voice in your place" | Framed — "a place"; instrument bezels |
| Motion | **Never animates.** Append-only. Never repainted. | The only zone that breathes |
| Lifecycle | Permanent. Facts with receipts. | Ephemeral. Dies into the log on settle. |
| Author | The substrate (built, trusted chrome) | Grown (runtime-composed instruments) |

**The register split is a provenance channel, not taste.** Minimal register = the machine's
body speaking. Retrofuturist register = a grown instrument speaking. The user can tell at a
glance whether they are looking at chassis or at something that grew — generative UI's
trust problem (indistinguishable AI-authored surface) solved structurally, at the aesthetic
layer. Never bleed registers across zones.

Corpus grounding: the two registers are LANDSCAPE families §6 (zen-minimal/chromeless-
literate) and §4 (sci-fi diegetic mission-control) — compatible precisely because they sit
on opposite sides of the framed/chromeless fork. The Gundam overlay — HUD elements
appearing for the maneuver over a preserved core, vanishing after — is §4's native lineage.
This reads as one tradition, not a mashup.

---

## 3. The clocking law (motion)

**Everything is clocked by the journal, not by wall time.**

- Motion exists only while events flow. Spinners/meters tick on event arrival, never on
  `setInterval`. Events stop → screen goes still. "Panel shows nothing → nothing is
  happening" becomes a property of the render loop, not a promise.
- **Moving = in-flight claim. Still = settled fact.** Streaming/provisional content renders
  dim/italic; the moment it freezes to full weight is the commit beat — the event is
  durable. The user watches claims become facts, every turn.
- **The completion blink.** When a tracked process finishes (the "waiting for files,
  1→100%" widget), one event-driven flash is legal — it is fired *by* the completion event —
  then the widget dies into the log as a fact line with its receipt ("all good" + counts +
  duration). Blink → settle → buried as history. No lingering, no victory laps.
- Tempo may encode state (fast tick = acting, slow pulse = watching) because tempo derives
  from real event rate. Idle "aliveness" pulses only if driven by real heartbeat telemetry.
- Easing/decorative transitions: none. In a tool, instant snap reads as native; easing reads
  as lag (corpus: Posting, yazi, mc). The rim breathes with data; nothing else moves.

---

## 4. Channel grammar

### 4.1 Color
- **Achromatic chassis; chroma = signal.** All chrome carries zero-to-near-zero chroma so
  any colored cell reads as a status light on an instrument (corpus: Grok's one structural
  move — we keep it and wire it to truth).
- **Color encodes state, never speaker.** Authorship/structure is carried by rails and
  glyphs; the hue budget is reserved for status so color is never ambiguous.
- **Reserved alarm.** The error hue is withheld entirely from the resting UI. The alarm
  works because the room is silent (mc doctrine).
- **Roles, never colors.** Components name semantic roles resolved through the theme; a raw
  hex in a component is a defect (brick doctrine: drift structurally unrepresentable —
  same defect class as ADR-0029).
- Chassis has no temperature; temperature is a theme decision. Default accent hue: **open
  decision, V's call** (candidates weighed in LANDSCAPE §5 discussion; amber has the
  deepest instrument lineage but carries caution-light connotation).

### 4.2 Borders & shape
- Log: no boxes. Nesting via dot-and-hang indentation; a box in the chromeless stream is
  reserved for "stop and look here" and therefore rare.
- Rim: single-line recessive frames as bezels; titles and counts inlaid in the border rule
  (the border earns its cells); heavy `┃` rails for ownership/selection. Border *color* may
  carry focus/status; border *shape* never varies decoratively.
- No rounded-vs-sharp mixing within a zone. Pick per register and hold.

### 4.3 Typography
- Four-channel code, one meaning each: **bold** = structure, **dim** = supporting/
  provisional, **italic** = in-flight/introspective, **reverse** = the one selected/stamped
  thing. Overloading a channel destroys the code.
- Dim ramp = the opacity/hierarchy substitute (text → muted → disabled).
- Casing: lowercase for identity and status verbs (calm, technical); UPPERCASE only for
  rim instrument labels; never decorative.

### 4.4 Evidence surfaces
- **"Done" carries its evidence.** Every completion line ships its receipt inline: exit
  code, diff stat, duration, tokens/cost, journal offset. The taxi-meter is always on.
- **The waiting state is evidential.** No whimsical gerunds (a gerund performs an inner
  life — theater). No naked stillness either. Named actual phase + live meter:
  `running mix test · 12s · 3.1k tokens`. The numbers are the trust channel.
- **Glass walls.** Instruments can reveal their wiring: what data path feeds this widget,
  what produced this line (lazygit command-log doctrine, generalized).

### 4.5 Voice
- Terse, factual, lowercase-calm. Warmth from precision, never jokes. Errors: sober
  diagnostic + evidence + what the machine already did about it ("resumed to one debit,
  offset N" — the will holds, shown not narrated).
- Ceremony is legal only when it is evidence. The boot beat is a real self-check (POST):
  every line an actual check with its actual result, doubling as the identity card. The
  machine proves itself before accepting you. No logo shine sweeps, no splash art.

### 4.6 Sound (when a surface has it)
- One semantic completion event, translated per surface into its native quiet idiom
  (chime/toast/haptic/tab-pulse), gated on duration + focus. Two-note language at most:
  "done" / "needs you." Fired only by journal events. Silence is the default register.

---

## 5. Widgets — the grown instruments

### 5.1 v1 scope: representation only

**v1 widgets are read-only projections. No interactive affordances.** Live statuses of
ongoing processes: a bridge settling, a solve running, "waiting for N files" counting to
100%, then the completion blink, then settlement into the log. That is the whole v1
vocabulary — and it is enough to carry the soul, because the live-status widget is the
purest possible form of "provable projection of what is."

Interactive widgets (agent-authored buttons → tool calls) are **v2**, gated on the binding
contract below. Recorded now so v1 code doesn't paint us out of it.

### 5.2 The primitive vocabulary

Widgets are composed exclusively from the minimal toolset: the CSS-flex replica, overflow,
markdown, and role-token styling. **Expressive enough for any instrument, too poor to
fabricate.** There is no free-drawing primitive; there is nothing else.

### 5.3 The binding contract (the law that makes generated UI honest)

**An agent composes projections; it never paints pixels.** A widget is a program — an
Arrival scheme fragment — that is a *pure mapping* from a declared data source (MCP tool
output / model path / journal query) to a view built from the primitive vocabulary.

- Every widget declares its binding. **An unbound widget is unrepresentable** — the
  interpreter refuses it, same defect class as an unbound meter.
- The mapping is pure. Effects may only be *returned* as declared messages (the TEA Command
  boundary), and in v1 the returned-effect set is empty.
- Widget programs are data: inspectable, diffable, and **journaled**. The accretion of the
  cockpit is itself event-sourced — kill the process, respawn, same grown cockpit; the
  time-travel debugger can scrub to the moment an instrument appeared.
- (v2, recorded) Interactive bindings add the falsifier class **label-vs-binding
  divergence**: an affordance whose label says X while its binding calls Y. Mitigation:
  affordances reveal their actual tool + args on inspection; consequential calls route
  through the existing checkpoint/spending gates.

### 5.4 Layout: request, never claim

Everything is a widget; everything is dynamically stretched. A widget declares intrinsic
content + semantic role; **flex grants space, H-K grants prominence.** Two solvers, one
economy. A widget cannot claim size or importance — both are assigned. This is what keeps
an emergent widget set coherent with no human designer in the loop.

### 5.5 Lifecycle

```
grown (event: process starts, widget program journaled)
  → live (rim; breathes with its data source; dim/italic register for provisional values)
  → completion blink (single event-driven flash)
  → settled (dies into the log as a fact line + receipt)
  → [optionally pinned: session / project / global — the instrument earns permanence]
```

Nothing accretes unboundedly: settled things leave the rim and are buried as history.
Persistence scoping governs *instruments* (recurring, pinned), not overlays (ephemeral).

---

## 6. Costume and body

- **Body** = the role graph + the clocking law + the zone registers. Invariant.
- **Costume** = a palette binding on the role tokens. Themes (synthwave, phosphor, tribe
  palettes — Nord/gruvbox/Catppuccin compatibility) are legal and encouraged; a costume
  cannot lie because the roles underneath still project truth.
- **Effect legality rule:** any flourish (glow burst, TRANS-AM moment) is legal iff driven
  by a real event in the stream, illegal on a timer. One rule sorts every future flourish.

---

## 7. Falsifier classes (review checks)

Every rule above has a checkable violation. These join the PR gauntlet for anything
touching rendering:

1. **Unbound pixel** — any rendered value not traceable to journal/model state.
2. **Timer-clocked motion** — animation driven by wall time instead of events.
3. **Claimed prominence** — hand-set brightness/salience bypassing the H-K solver; raw hex
   in a component instead of a role token.
4. **Register bleed** — rim idiom in the log (a breathing element in history) or log idiom
   broken on the rim; history repainted or animated.
5. **Performed activity** — spinner/meter asserting work with no evidence surface attached
   (no meter, no phase name, no receipt on completion).
6. **Unearned ceremony** — decorative boot/exit/transition beats not backed by a real check
   or event.
7. **(v2) Label-vs-binding divergence** — affordance text inconsistent with its declared
   call.

The meta-falsifier: **cargo-culting the evidence look while faking the wiring loses
everything at once.** A meter not wired to real numbers collapses the register to theater —
worse than honest consumer cheer, because the brand promise was "cannot lie." Any pixel
whose value cannot be traced to journal state is a bug of the ADR-0029 class.

---

## 8. The session narrative (what a user experiences)

1. **Boot** — the self-check ritual. Proof before greeting. Identity card with real values.
2. **Work** — the log accretes downward; claims shimmer dim, settle to still facts with
   receipts; the rim breathes with real telemetry; instruments appear because work exists.
3. **Trouble** — the room was chromatically silent, so the alarm is pre-attentive and
   unmissable; it arrives with evidence and with what the machine already did about it.
4. **Idle** — near-stillness, pulse at the rate of real heartbeat telemetry. The certainty
   feeling lives here: nothing shown, nothing wrong.
5. **Return** — the cockpit the user grew is still there, replayed from the journal. Over
   weeks it becomes theirs.

---

## 9. Decisions open / deferred

- **Default accent hue** — V's call (chassis is achromatic; temperature is themeable).
- **Pin/accretion policy** — what promotes an instrument from ephemeral to session/project/
  global: explicit pin, adaptive-layer recommendation, or both. `adaptive/` (behavior
  tracking + layout recommendations) is the candidate engine.
- **v2 interactive contract** — full Arrival ↔ TEA wiring spec ("this button becomes this
  MCP tool call producing new state"), including the label-vs-binding lint and checkpoint
  routing. Separate proposal when v1 representation widgets are proven.
