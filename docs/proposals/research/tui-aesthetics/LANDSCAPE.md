# TUI Aesthetics Landscape

> How terminal apps produce *vibes* — the character, mood, and identity that GUI apps build
> with glossy buttons, shadows, custom fonts, and pixel-perfect indents — using only a
> monospace grid, ANSI color, box-drawing glyphs, whitespace, motion-via-redraw, and words.
>
> Corpus: 39 dossiers across four research tracks (14 apps/harnesses, 10 libraries, 6
> blog/publication sweeps, 4 cyberdeck-crossover studies, 5 gap-fill studies), synthesized
> into three cross-cutting sections. Dossiers in `dossiers/`, sections in `sections/`.
> This document is the map; the sections are the reference; the dossiers are the evidence.

---

## 1. Executive summary — the structural findings

These are the load-bearing discoveries, ordered by depth. Each one is a lens, not a tip.

**1. The core inversion: the GUI expresses by adding material; the grid expresses by
subtraction, re-coding, and rhythm.** A shadow is pixels a GUI didn't need; the terminal
has no spare material — its default is wall-to-wall equal-weight monochrome text. So every
expressive act on the grid is a *subtraction from*, *re-coding of*, or *rhythm imposed on*
a uniform field. Emptiness must be paid for, and that payment is what reads as confidence.
This scarcity is why terminal emotion reads so loudly: when the whole field is uniform, a
single deviation — one warm hue, one rounded corner, one whimsical verb — carries enormous
signal. (Section 01 §0.)

**2. Identity concentrates into points: identity-per-pixel is the real currency.** One
clay-orange `#D97757` (Claude Code), one green bold border (lazygit), one `🐶` in a command
cursor (k9s), one `❯` chevron (Pure) each carry more "who" than any amount of chrome.
The strongest levers are the ones with the highest identity density, and the playbook in
Section 02 orders all eleven of them by that metric: signature accent > waiting-state
performance > voice > wordmark/mascot > shape language > motion signature > sigil > layout
silhouette > environmental claim > theme architecture > sound.

**3. Character is a committed point on a set of dials — and the commitment IS the
identity.** Whimsy↔austerity, warm↔cool, framed↔chromeless, airy↔dense, rounded↔sharp,
machine-voice↔human-voice, author's-look↔user's-canvas, ceremony↔instant-boot. No single
beautiful device rescues incoherence (whimsical voice under a brutalist frame, airy padding
around anxious dense data). Conversely, "an undifferentiated default is the one choice that
says nothing." Every memorable app in the corpus is a coherent vote across all seven device
families at once. (Sections 01 cross-family, 02 master dials.)

**4. For a coding agent, the waiting state is the app's face at rest.** The user spends
most of every turn staring at the "working…" indicator, which makes spinner glyph ×
frame interval × verb × meter × streaming cadence the highest-leverage identity real
estate in the entire product. Four shipped agents derive four irreconcilable souls from
*identical latency*: Claude Code's blooming asterisk + whimsical gerund (literate
companion), aider's bouncing bright-head scanner (diagnostic craftsman), Gemini's
brand-wheel-cycling spinner (consumer product), Grok Build's two-cadence sin²-breathing
(mission-control cockpit). Charm's law governs: *same wait, different feeling*. (Section 02
Lever 2; `dossiers/gap-waiting-state.md`.)

**5. Framed vs chromeless is an ontological claim, not a layout choice.** Framed = "I am
a place" (k9s, Grok, ratatui cockpits). Chromeless = "I am a voice in your existing place"
(Claude Code, aider streaming into native scrollback). For agent harnesses this is the
single deepest fork: houseguest or cockpit. Almost everything else — density, ceremony,
screen ownership, voice — inherits its register from this decision. The shell-prompt
corpus names the same fork at the token level: filled-background powerline segments (text
as *material* → cockpit) vs plain text on the void (→ workbench).

**6. The emulator co-authors roughly half the vibe, invisibly.** Font, ligatures, cursor
easing, background blur, CRT shaders, window padding all belong to the user's terminal,
not the app. The design posture that survives this: *design for the floor, be a gift on
the ceiling* — compose so the app reads as intentional on a matte flat terminal and
gorgeous when a phosphor-glow substrate paints it in. (`dossiers/gap-emulator-substrate.md`.)

**7. Vibe is a parameter set, not a style you either have or lack.** Four axes place
every app in the corpus: warmth (menace↔benevolence, set by hue + corner geometry +
contrast), energy (hush↔spectacle, set by motion density + saturation), density
(airy↔wall-to-wall), and era/authorship (retro-operator-built↔modern-consumer-product —
*who the surface announces built it*). The eight vibe families of Section 03 are the
durable clusters on these axes, each with defining moves, lineage, and a named
pastiche-failure mode.

**8. Words are the facial expressions.** With no face, no font, no illustration, voice is
where a TUI is most unmistakably a *someone* — and the least fakeable channel. The
whimsical gerund (Claude's 187 verbs), the spec-sheet BIOS-POST (aider), the emoji mood
(k9s's 😎/😗/😡), imperfect-but-sincere English (superfile's "Thanks for using
superfile!!") each perform a disposition toward the user: ally or gatekeeper. Error
personality — the register under maximum stress — is the truest character test.

**9. Color's power comes from scarcity, and named palettes are tribes.** On the grid,
color is a second encoding of meaning, never decoration; the alarm works because the room
is silent (mc's reserved red). And a bag of 16 hex codes becomes an *identity* when
wrapped in a story — science (Solarized/CIELAB), place (Nord, Tokyo Night), character
(Dracula), community (Catppuccin). Adopting one is choosing a tribe and a mood in one
gesture; threading one accent through every focus/active/selected surface is the single
strongest perceived-maturity signal.

**10. Motion timing is a grammar, and stillness is a valid sentence.** Interval is the
emotional register (≤50ms anxious, ~80ms brisk-calm, ≥250ms breathing). Tempo can encode
state (Grok: fast whirl = acting, slow pulse = watching). `sin²` breathing reads
alive-and-calm where blinking reads alarm. And the deliberate absence of motion is its own
statement — in a *tool*, easing reads as lag and instant snap reads as native (Posting,
yazi, mc); in a *monitor*, stillness reads as dead (btop). The domain decides.

---

## 2. The three synthesis sections

### [`sections/01-vocabulary-of-expression.md`](sections/01-vocabulary-of-expression.md) — the device catalog

The complete replacement toolkit: for every GUI expressive device, its grid substitutes
and the feeling each produces. Seven device families, each entry giving *what it is, what
it evokes, who uses it, how it fails*:

1. **Color deployment** — semantic role color, single-accent-as-temperature,
   color-as-data gradients, secretly-tinted neutrals, period palettes, reserved red,
   generated token systems, degradation ladders, ANSI-16 remap.
2. **Border & box-drawing semantics** — the corner/weight mood dial (rounded=consumer,
   sharp=engineered, heavy=brutalist, double=DOS), border-color-as-focus, inlaid titles,
   border fusion, the left-rail, framed-vs-chromeless, and *five* distinct drop-shadow
   substitutes (surface-lightness layering, alpha overlays, depth-fade, grey-ramp
   extrusion, dim-scrim occlusion).
3. **Whitespace & density rhythm** — the 1-cell padding ring ("the terminal's
   drop-shadow"), the density↔airiness master dial, density-as-a-toggle, tabulation as the
   cheapest luxury, centered-once ceremony, textured voids.
4. **Glyph & symbol language** — the block-glyph material kit, the sub-cell braille/
   blitter ladder as a mood dial, single-glyph mascots vs block wordmarks, Nerd-Font
   richness vs austere refusal, geometric sigil kits, graphics-protocol escape velocity.
5. **Motion timing** — spinner timbre×tempo, the whimsical gerund, instrumentation
   clusters ("the verb makes you smile while the numbers make you trust"), streaming
   cadence, sin² breathing, tempo-as-state, the shine-sweep gloss substitute, stillness,
   ephemeral motion.
6. **Casing & typography substitutes** — the four-channel type system (bold/dim/italic/
   reverse, one meaning each), reverse-video as button, the dim opacity ramp,
   casing-as-voice, color-as-weight.
7. **Voice & copywriting** — the terse↔whimsical register spectrum, emoji affect, the
   taxi-meter, self-narrating chrome, error personality registers, ceremony and its
   refusal.

Closes with four worked compound identities (Claude Code, k9s, Grok Build, mc), a sound
coda, and a ~45-row master technique→feeling index. **Use it as: the parts bin.**

### [`sections/02-identity-and-character.md`](sections/02-identity-and-character.md) — the personality playbook

How a TUI becomes a *someone*. Eleven identity levers ordered by identity-per-pixel
strength, each with concrete moves and evidence; the first-five-seconds boot spectrum
(maximal ceremony → warm-modest → zero-as-statement); error personality under stress;
and sibling-differentiation case studies — the flagship being the coding-agent table
showing five agents diverge on exactly four dials: screen ownership, whose voice is the
colored actor, the waiting-state performance, and the whimsy↔austerity position. Ends with
the master-dials table and the one-line doctrine: *concentrate identity into a few
high-density points, then commit to a coherent position on every dial across every
surface.* **Use it as: the character sheet builder.**

### [`sections/03-vibe-families.md`](sections/03-vibe-families.md) — the taxonomy / the map

Eight aesthetic families plotted on four axes, each with defining moves, lineage,
exemplars, execution keys, and the specific way it fails into pastiche:

| # | Family | One-line feeling | Fails when |
|---|---|---|---|
| 1 | Orthodox DOS/BBS retro | "this already worked in 1994" | truecolor/scanlines break the 16-color quotation |
| 2 | Hacker phosphor / cyberdeck | operator-authorship, transgression | consumer chrome under the phosphor filter |
| 3 | Industrial-dense ops cockpit | instrument under load | density with no salience hierarchy |
| 4 | Sci-fi diegetic mission-control | stakes; operating a machine | gloss undercuts scarcity-reads-as-authenticity |
| 5 | Charm glamorous / pastel-cute | "someone designed this for me" | over-cute breaks the grid or the seriousness |
| 6 | Zen-minimal / chromeless-literate | calm literate houseguest | airiness with nothing to say |
| 7 | Systematized / flat-material web-import | "designed by a system" | stopping at the framework default |
| 8 | Riced-personal / palette-tribe | belonging; "this machine is MINE" | screenshot-self ≠ working-self |

Plus the retro↔modern cluster picture, the filled-segments-vs-plain-text master fork, and
the cross-family modifiers (border-weight grammar, palette-tribe overlay, voice register,
motion cadence, substrate posture, sound role). **Use it as: the direction picker.**

---

## 3. Annotated dossier index

One line each: coverage + the single most valuable insight.

### Apps & harnesses (`dossiers/app-*.md`)

- **aider** — chrome-refusal as identity; the *absence* of UI is the aesthetic ("a Unix
  citizen, not an application"); phosphor palette as deliberate CRT quotation; the
  taxi-meter cost line as trust.
- **btop** — the monitor that refuses to show numbers as numbers; every value
  triple-encoded (position + 101-step gradient hue + scrolling braille waveform) so the
  panel reads from across a room; grey-ramp glyph drop-shadow on the logo.
- **charm-crush** — the neutrals are not neutral: plum-shifted "grays" put the synthwave
  in the shadows; ANSI-16 remap recolors even external tool output — the most aggressive
  environmental identity claim in the corpus.
- **claude-code** — brand as a temperature: one hue on the user's own background; the
  blooming/breathing `✻`; 187 whimsical gerunds as load-bearing charm; chromeless
  dot-and-hang nesting keeps agent runs prose-shaped.
- **gemini-cli** — the gradient block wordmark as the single most identity-defining pixel
  decision; the five-tier graceful-degradation ladder engineered to *fade, not shatter*.
- **grok-build** — zero-chroma graphite chassis so any colored glyph reads as a status
  light; the human-is-gray/machine-is-magenta inversion; sin² breathing + tempo-as-state;
  the shine-sweep gloss substitute; OSC-12 cursor repaint ("engine on"). Reconstructed
  from git history and source comments.
- **k9s** — the logo is the face *and* the mood ring (wordmark recolors red on error);
  8-state lifecycle palette turns 60 pods into a peripheral heat-map; a 🐶 in the command
  cursor disarms an industrial cockpit.
- **lazygit** — the entire brand is one green bold border on the active panel; mode
  recoloring means "the UI has weather"; the command-log builds trust through glass walls.
- **midnight-commander-mc** — stasis as identity: the CGA blue is a *quotation*, kept for
  thirty years; reserved red ("the fire alarm works because the building is silent");
  ideological stillness.
- **ncmpcpp** — the binary is a canvas: ship a neutral skeleton, expose an obsessive
  theming grammar, let the rice community supply the soul; 8-level partial-block ramps
  for fluid hi-fi motion.
- **posting** — "the purple one": the rarest UI hue signals *someone chose this*; the
  padding numbers ARE the composition; `animation: none` — stillness is the polish.
- **superfile** — kawaii-warm file manager; deliberately imperfect English kept because it
  reads as sincere; rounded everything; identical padding sells one designed system.
- **yazi** — graphics-protocol escape velocity ("GUI broke into terminal"); async
  instant-swap weightlessness as the anti-spinner statement; the duck as flat-app-icon
  mascot.
- **zellij** — self-narrating chrome: the status bar rewrites its vocabulary per mode,
  reads keys from the actual config, labels absence `UNBOUND` — discoverability rendered
  as beauty.

### Libraries & frameworks (`dossiers/lib-*.md`)

- **charm-ecosystem** — taste as a *default*: import CSS's structure/style split, then
  package the style as copy-paste defaults so an unstyled script inherits the vibe; the
  magenta→violet quadrant as "I am not IBM."
- **textual-rich** — the 11-role semantic palette auto-generating ramps + contrast-safe
  text: wrong-looking combinations become hard to express; the recognizable cost —
  you can spot a Textual app like a Bootstrap site.
- **ratatui** — the Block frame IS the design language; border fusion (`merge_borders`)
  makes tiled panels read as one fabricated chassis.
- **brick** — role-based AttrMap with CSS-like inheritance: visual drift becomes
  *structurally unrepresentable*; sober box-drawing texture as a value.
- **ink** — Yoga flexbox in the terminal: `flexDirection`+`gap`+`padding` one keystroke
  each makes the tidy column-of-cards the *lazy* default — the onboarding-wizard feel of
  modern JS CLIs explained.
- **prompt_toolkit** — semantic-class stylesheets (CSS-for-the-grid): whole app
  retintable in one place, reads designed-not-hand-colored.
- **ftxui** — style as a first-class composable value (`element | bold | color | border`);
  easy richness, easy noise.
- **notcurses** — the blitter ladder as a *mood dial*: the same image served as retro
  block-art or near-photograph; per-cell alpha planes give genuine drop shadows.
- **nushell** — one `table.mode` token re-skins every table: taste is a setting; type-aware
  cell color ("the table understands its contents"); color scarcity as legibility doctrine.
- **pterm** — beauty defined at the ANSI-16 floor, truecolor as garnish; equal-width badge
  labels self-tabulate streaming output into something that looks designed, not emitted.

### Blog & publication sweeps (`dossiers/blogs-*.md`)

- **practitioner-essays** — the builders' testimony (McGugan, Charm, Warp, Ghostty);
  half-block "McGugan boxes" giving panels material solidity; web-design-under-constraint
  as the modern school's self-description.
- **discourse-critique** — the community's vibe *vocabulary* decoded: what triggers
  "fast," "cozy," "honest," "focused"; the warning that cargo-culting the retro look while
  dropping the frugality throws away the actual source of the "fast" vibe.
- **color-scheme-culture** — how 16 hex codes become an identity: every great palette
  ships a story (lab science, arctic landscape, vampire brand, cat-and-coffee community);
  palette psychology by family.
- **motion-and-feel** — spinner taxonomy (timbre×tempo), progress-bar aesthetics,
  typewriter cadence, terminal recordings as marketing; motion as the one channel the app
  doesn't share with the user's environment.
- **voice-and-guidelines** — the canon (clig.dev, 12-factor CLI, Elm error empathy):
  output as a conversation with a *disposition* — ally or gatekeeper; tone is a dose,
  not a virtue.
- **ansi-heritage** — CP437 → BBS artpacks → modern textmode: the shade-ramp `░▒▓█`
  luminance fade that makes a flat grid feel *lit*; the scene's group-tag badge culture as
  ancestor of the fetch card.

### Cyberdeck crossover (`dossiers/cyber-*.md`)

- **deck-culture** — operator-authorship as the deck's core value: a single-hue phosphor
  screen "looks emitted by hardware, not styled by a color team"; boot ritual as ownership
  claim; why consumer chrome breaks character.
- **scifi-terminals** — the movie-terminal corpus reduced to two dials (warmth, energy):
  vibe is a parameter set; the "used future" doctrine — legibility of wear is the source
  of belief; LCARS as proof the same primitives can produce warmth.
- **ricing-culture** — the three levers of the self-portrait (palette = who you are in
  hue; negative space = who you are in what you omit; the fetch-card totem = who you are,
  declared); the converged implicit design system nobody legislated.
- **grid-games** — vibe engineering with glyphs alone: warm→cool color-temperature
  falloff produces coziness-at-center/dread-at-edges; Cogmind's restraint doctrine (a
  small consistent glyph subset, not all of CP437); diegesis as the strongest immersion
  move.

### Gap-fill studies (`dossiers/gap-*.md`)

- **prompt-statusline** — the master fork (filled segments vs plain text) from which
  every prompt inherits its register; the sigil as maximum identity-per-character; the
  transient prompt as an identity of discipline.
- **emulator-substrate** — the canvas layer the app can't control (fonts, ligatures,
  cursor easing, shaders, blur): co-authors ~half the vibe; design for the floor, be a
  gift on the ceiling.
- **waiting-state** — the agent's face at rest, exhaustively: spinner glyph taxonomy with
  feelings, interval as emotional register, the gerund, instrumentation clusters,
  streaming cadences, the austere no-spinner pole.
- **sound-and-haptics** — the channel that works when nobody is looking: two-note timbre
  languages (done / needs-you), deliberate silence as seniority, one semantic event
  translated into each surface's native quiet idiom.
- **layout-rhythm** — the pre-verbal layer: the eye clocks the density silhouette in
  200ms before reading a word; emptiness must be paid for; dense screens must pay the
  legibility debt in another currency (color, weight, alignment).

---

## 4. Open questions and tensions

Where the corpus genuinely disagrees — these are decisions, not facts:

1. **Whimsy is polarizing and there is no neutral resolution.** Claude's gerunds draw
   "unprofessional and dismissive" bug reports *and* are its most-loved signature.
   The corpus's only stable answer is dose-plus-toggle (customizable, not removable) —
   but a toggle dilutes commitment, and commitment is the identity. Tension unresolved.
2. **Author's look vs user's canvas.** Posting commits to its own truecolor palette and
   refuses ANSI fallback; aider/lazygit/brick inherit the user's theme and honor
   `NO_COLOR`; Crush remaps the user's ANSI-16 outright. Assertive branding and respectful
   deference are both praised in the corpus, by different tribes. Choosing is a values
   statement about who owns the terminal.
3. **Framed cockpit vs chromeless houseguest for agents specifically.** Grok and Claude
   Code sit at opposite poles of the same product category, both executed excellently.
   The corpus offers no winner — only the observation that the choice determines almost
   everything downstream. (Note Grok's fullscreen ownership enables things Claude's
   scrollback ontology can't: recursive subagent cockpits, a dispatch dashboard.)
4. **Aliveness vs stillness.** "Stillness reads as dead" (monitors) vs "stillness is the
   polish" (tools) resolves by domain — but an agent harness is *both* a tool and a
   monitor of a live process, so it must mix registers deliberately (still chrome, alive
   status) rather than pick one.
5. **Density flatters the expert; air welcomes the human.** Dense = "you can drink from
   a firehose"; airy = "I have room for you." A harness serves both a watching operator
   and a reading collaborator. The corpus's best answer is density-as-a-dial (Posting
   `--compact`, Grok compact mode), which costs coherence.
6. **The substrate is uncontrollable and unknowable.** You cannot detect the user's font,
   shader, or blur. Every truecolor-first design is a bet; every 16-color design leaves
   beauty on the table. The degradation-ladder doctrine mitigates but does not dissolve
   this.
7. **The aliveness techniques have an accessibility cost.** The reactive spinner that
   reads "alive" to the eye spams a screen reader; braille glyphs read as noise. The
   corpus flags it (discourse dossier) but no shipped app in the corpus fully solves it.
8. **Semantic token systems trade identity for coherence.** "Designed by a system" is
   also "spot-a-Textual-app" genericism. The rescue is always a signature accent laid on
   top — which is a hand-authored move the system cannot generate.

---

## 5. Applying this (the decision order)

The material above compresses to one procedure. Do it in this order; each step constrains
the next:

1. **Pick the cluster** (Section 03 §9): retro/operational (honest, frugal,
   operator-built) or modern/designed (friendly, crafted, consumer). This is *who the
   surface announces built it*.
2. **Take the master fork**: framed material ("I am a place" — cockpit) vs text on the
   void ("I am a voice in your place" — houseguest). For a harness this is the screen-
   ownership question, and the coding-agent table (Section 02) shows it plus three more
   dials — whose voice is the colored actor, the waiting-state performance, the
   whimsy↔austerity position — fully determine an agent's soul.
3. **Set warmth and energy** (hue + corner geometry + contrast; motion density +
   saturation) to land the exact family in the Section 03 table. Read its
   fails-into-pastiche row before committing.
4. **Choose the high-density identity points** (Section 02 playbook, top five): the one
   accent hue, the waiting-state performance, the voice register, the mascot/sigil, the
   shape language.
5. **Derive everything else from the parts bin** (Section 01) — and make every device
   family vote the same way. Coherence across families is the identity; the audit
   question for any screen is "which family does this vote for?"
6. **Then sign it** with the modifiers: palette-tribe compatibility (ship named themes),
   substrate posture (design for the floor), sound role, environmental claims.

For the Raxol harness specifically: this landscape covers the *vibes* layer and is
complementary to the perceptual-science layer (`tui-design-science` skill — legibility,
salience, grid ergonomics). The science constrains what reads; this corpus determines what
it *feels like*. Note also that the five shipped coding agents occupy five distinct
positions (houseguest / austere craftsman / consumer product / mission-control cockpit /
synthwave bestie) — the map in Section 03 shows which territories in the space are still
unclaimed.
