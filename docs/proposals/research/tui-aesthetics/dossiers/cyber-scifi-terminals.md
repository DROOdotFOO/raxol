# Dossier: Cyber / Sci-Fi Terminals — The Diegetic Screen as Aesthetic Source

> *Scope: the screen-as-character. How fictional operating systems, cockpit HUDs, and movie
> terminals build identity, mood, and menace out of exactly the primitives a real TUI has —
> a monospace grid, a handful of colors, glyphs, whitespace, redraw-motion, and words.
> Every entry names a concrete, reproducible technique and the feeling it manufactures.*

The central insight of this whole tradition: **on-screen computers in film almost never
show real software.** They show a *performance* of software — designed by prop artists and
motion-graphics houses (Territory Studio, Territory, Ed Fanning, Cantina, GMUNK) whose only
job is to make you *feel* something in the two seconds the camera lingers. That makes them a
purer aesthetic corpus than real UIs: nothing is there for ergonomics, everything is there
for vibe. A real terminal can steal the whole vocabulary because these interfaces were
already constrained to text, glyphs, and glow.

There is a master pattern beneath the whole genre, and it is worth stating first because it
recurs in every case study below:

**Scarcity reads as authenticity; authenticity reads as *stakes*.** The fewer capabilities a
screen shows off, the more we believe it is a real working machine doing a real dangerous
job. A green wall of monospace telemetry feels *load-bearing* in a way a glossy animated
dashboard never does. This is the aesthetic gift to real TUIs: the constraints we apologize
for are exactly the constraints that generate gravity.

---

## 0. The Root Doctrine: "The Used Future"

Everything downstream inherits from one production-design decision George Lucas made on
*Star Wars* (1977) and Ridley Scott's team pushed further on *Alien* (1979). Lucas rejected
the "new and clean and shiny" future of prior sci-fi and asked for a **used future** — tech
that looks maintained, scuffed, and boring the way a family car is boring. Ron Cobb and
Roger Christian made it filmable: dented droids, bad wiring, machinery that "feels maintained
rather than designed for wonder."

**Why this matters for a character grid:** the used-future doctrine says *legibility of wear*
is the source of belief. On a screen you cannot dent a chassis, but you can:

| Technique | Feeling produced |
|---|---|
| Choose *legacy*-looking type (serif or chunky mono, not a sleek geometric sans) | "this system is old and has been running a long time" — trust through age |
| Show version strings, build numbers, uptime counters, revision dates | the machine has *history*; it existed before you booted it |
| Let output be terse, unstyled, unpolished — plain rows, no rounded panels | nobody decorated this; it's a *tool*, not a product |
| Mix eras deliberately (a 1970s font under a modern layout) | the "temporal authenticity" of tech that accreted in layers |

Ron Cobb's other gift — the **Semiotic Standard** icon set aboard the Nostromo (coherent,
functional signage: emergency, gravity, airlock) — is the diegetic ancestor of a good TUI
status-glyph legend. The lesson: a *small, consistent, purpose-built symbol vocabulary* signals
"this is a real operational environment" far more than illustrative icons do.

> Lucas, paraphrased in the ASC: the future should feel like an Apollo capsule after
> splashdown — as ordinary as a station wagon.

Sources: [Gamerant — Used Future Aesthetic](https://gamerant.com/science-fiction-used-future-aesthetic-explained/),
[kk.org / The Technium — The Used Future](https://kk.org/thetechnium/the-used-future/),
[The Ringer — Sci-Fi Is Stuck in the '70s](https://www.theringer.com/2025/08/20/tv/sci-fi-is-stuck-in-the-70s-alien-earth-star-wars-andor-blade-runner).

---

## 1. Alien / MU/TH/UR 6000 — The Oppressive Working Terminal

*Describe the screen:* A curved CRT in a dark room. Green text on black, slightly stretched,
crawling upward line by line at reading-typewriter speed. No graphics, no chrome, no mouse —
just a query and a cold reply, `MOTHER` answering in clipped uppercase. When Ripley demands
the truth, the screen fills with a scrolling directive and the machine simply *keeps going*,
indifferent. The horror is that it is not evil; it is a **utility** that was always going to
prioritize the company over the crew, and it tells you so in plain monospace.

This is the single most important reference for a "serious operational" TUI vibe.

### Reproducible techniques → feelings

| Technique | Feeling |
|---|---|
| **Green (or amber) monochrome text on pure black** | legacy hardware, phosphor warmth, "this is a real machine from before color mattered" |
| **All-caps terse replies** (`UNABLE TO COMPUTE`, `PRIORITY ONE`) | machine authority; no social softening; slightly menacing flatness |
| **Teletype reveal** — text appears character-by-character or line-by-line at ~human-read cadence, *not* instant | the machine is *thinking* / *transmitting*; you wait on its schedule, not yours → subordination, suspense |
| **A single steady or slow-blink block cursor** waiting at a prompt | anticipation; the machine is listening; you are on the record |
| **Serif-ish or otherwise "wrong" type choice** (Alien used a stretched *City Light*, a serif) | uncanny, institutional, un-sleek — subverts the expected sci-fi sans and reads as *older and stranger* |
| **Optical distortion cues** — the *implication* of a curved screen via slight vignette, bloom, edge darkening | the used-future CRT; "beaten-up kit" |
| **No decoration around content** — content sits directly on black, no borders | austerity; every character is functional; institutional coldness |

The self-destruct sequence deserves its own note: it is a masterclass in **escalation via
type and motion** — hand-painted, heavily letter-spaced emergency labels, a relentless
countdown, and the interface actively *fighting the user* (the famous unfriendly override
UX). For a TUI: a countdown that redraws in place, wide letter-spacing on a warning banner,
and a color shift to red as a threshold is crossed all inherit directly from this.

The counter-lesson from Alien's inconsistency (it cut between lo-res 4:3 and hi-res 16:9
displays): **don't over-unify.** A little heterogeneity in fidelity actually strengthens the
used-future read — real fleets never have matching screens.

Sources: [Typeset In The Future — Alien](https://typesetinthefuture.com/2014/12/01/alien/),
[Medium — UX of the Nostromo self-destruct](https://dinosaurenby.medium.com/a-deep-dive-into-the-ux-of-the-nostromos-self-destruct-procedure-9eda80793fe8),
[Boing Boing — MUTHUR 6000 recreation](https://boingboing.net/2025/08/11/recreation-of-muthur-6000-computer-system-from-alien.html).

---

## 2. Fallout — Pip-Boy / RobCo — Retro-Futurist Green Monochrome

*Describe the screen:* Bright, slightly-too-saturated green glyphs on black, curving with a
CRT bulge, faint scanlines drifting, a soft phosphor glow blooming off every character. A
RobCo terminal boots with `ROBCO INDUSTRIES (TM) TERMLINK PROTOCOL`, then offers a numbered
list. Everything is monospace, everything is uppercase-friendly, the "graphics" are ASCII —
a health bar is a row of blocks, a map is line-art. It feels like a 1950s vision of a 1990s
computer: **atompunk**, optimistic-then-abandoned.

This is the most *directly copyable* reference for a real TUI because Fallout's whole UI
budget was already spent on text and glyphs.

| Technique | Feeling |
|---|---|
| **One bright green on black, no second hue** | disciplined, iconic, "single-phosphor terminal"; monochrome = identity |
| **ASCII/Unicode as the *only* graphics vocabulary** — bars from `█▓▒░`, frames from box-drawing, maps from line glyphs | ingenuity under constraint; charm; the machine "does its best with what it has" |
| **CRT skeuomorphism**: scanlines, a subtle screen curvature vignette, phosphor bloom, occasional flicker/roll | nostalgia, warmth, "this is hardware not a webpage" |
| **Boot banner with a fictional vendor + version + (C) line** | instant world-building; the OS has a *brand* and therefore a history |
| **Slow green-on-black typewriter reveal for lore text** | ceremony; you *read* rather than scan; reverence for the data |
| **Menu = numbered list you key into**, no pointer | tactile, deliberate, "terminal not GUI" |

The important structural point: Fallout proves **a color and a font can be a franchise.**
"RobCo green" is as recognizable as a logo. A real TUI that commits hard to *one* signature
phosphor color and *one* boot ritual buys enormous identity for zero pixels.

Sources: [Fallout Wiki — Pip-Boy 2000](https://fallout.fandom.com/wiki/Pip-Boy_2000),
[Hackaday — Replica Fallout Terminal](https://hackaday.com/2017/03/25/replica-fallout-terminal/),
[AlrikOlson/robco-terminal (GitHub)](https://github.com/AlrikOlson/robco-terminal).

---

## 3. WarGames / WOPR / NORAD — Vector Cold-War Menace

*Describe the screen:* A dark war room. Enormous projection screens show **vector graphics** —
wireframe world maps, arcing trajectory lines sweeping between continents, glowing text labels
(`DEFCON 1`), a countdown that ticks with fatal calm. On the personal side, a modem dial-up,
a blinking cursor, and a slow conversational teletype: `GREETINGS PROFESSOR FALKEN` /
`SHALL WE PLAY A GAME?` — one line at a time, patient, almost gentle, which is what makes it
terrifying.

The WOPR graphics were literally generated on HP 9845C scientific computers (~half a million
frames over 10 months) — i.e., *authentic period vector-graphics hardware*, which is why they
still read as "real computer."

| Technique | Feeling |
|---|---|
| **Vector/wireframe line-art on black** (maps, arcs, grids from `─│╱╲` and box glyphs) | clinical, computational, "this is a simulation of the real world" — abstraction as authority |
| **Sweeping animated arcs / trajectories redrawn frame by frame** | live process, unstoppable momentum, dread |
| **A conversational teletype at slow human cadence** | the machine as an intelligence you *talk to*; patience reads as inevitability |
| **Enormous type + single-word status (`DEFCON 1`)** at telemetry scale | institutional gravity; the stakes are civilizational |
| **Countdown timers rendered as the *only* moving element** | tunnel-vision urgency; time itself is the antagonist |
| **Uppercase throughout** | military/institutional register; no individual voice |

For a TUI the takeaway is the **"big glowing status word"** move: when everything is quiet
telemetry and *one* value renders huge and centered, that value becomes the whole emotional
frame. Scale-as-emphasis is available in a character grid via figlet/banner glyphs and
generous whitespace.

Sources: [HP 9845 Project — Screen Art: WarGames](https://www.hp9845.net/9845/software/screenart/wargames/),
[CIO — The Technology of WarGames](https://www.cio.com/article/220297/the-technology-of-wargames.html),
[Wikipedia — WarGames](https://en.wikipedia.org/wiki/WarGames).

---

## 4. TRON — The Light Grid / Cyberspace-as-Place

*Describe the screen:* Pure black, and out of it a **grid of bright lines receding to a
vanishing point**, glowing cyan and magenta, humming. Circuitry traced in light. Type is a
clean sans that seems etched from neon. There is no "screen" here — the screen *is* the world.

TRON (1982) crystallized the visual metaphor that *inside a computer looks like a glowing
wireframe grid on black.* We Are The Mutants calls the light grid "the symbol *par excellence*
of 'The Eighties'." The receding grid produces "an imaginary place that is at once empty plain
and cityscape — both quiet and humming with possibility... the feeling of power and control
that comes with seeing the world through the heads-up display of a targeting computer."

| Technique | Feeling |
|---|---|
| **Bright lines on pure black** (never light-background) | "digital," "inside the machine," cyberspace — black = the void the computer draws into |
| **Perspective grid / receding lines** via box-drawing + spacing | depth, vastness, a *place* rather than a page; power/overview |
| **Neon dual-accent palette** (cyan + magenta on black) | electric, synthetic, high-energy; the "80s digital" signal |
| **Glowing outline typography** (bold + bright accent on dark) | etched-from-light, weightless, non-physical |
| **Circuit-trace motifs** from `─┼┐└╱` line glyphs | "you are inside a computer's logic" |

Why black matters, stated plainly: vector displays of the 60s–70s *drew lines onto darkness*;
raster/paper is ink-on-white. So **a dark background is not a theme choice — it is the single
strongest signal that a surface is "a computer drawing" rather than "a document."** Any TUI
that wants the cyber register starts from black and adds light, never the reverse.

Sources: [We Are The Mutants — Vanishing Point / the Light Grid](https://wearethemutants.com/2017/02/16/vanishing-point-how-the-light-grid-defined-1980s-futurism/),
[TV Tropes — Tron Lines](https://tvtropes.org/pmwiki/pmwiki.php/Main/TronLines).

---

## 5. The Matrix — Digital Rain

*Describe the screen:* Columns of glowing green glyphs — mirrored half-width katakana, Latin
letters, numerals — cascading downward at varying speeds, the leading character brightest, a
fading trail behind each, endlessly. It is not information you can read; it is **information
as texture, as weather.**

Simon Whiteley built the code font by scanning characters from his wife's Japanese cookbooks,
choosing katakana for its "very nice simple strokes," flipping glyphs back-to-front "to create
the illusion of viewing the code from the inside out," and tinting it green "to match the look
of text on an old IBM CRT monitor."

| Technique | Feeling |
|---|---|
| **Falling columns of glyphs, per-column varying speed** (a classic terminal animation) | living system, endless process, "the machine is always running" |
| **Brightness gradient in a trail** — head char brightest, tail fading via dimmer color steps | motion and depth on a static grid; the eye follows the head |
| **Unfamiliar / mirrored glyphs (katakana, symbols)** | alien intelligence; *unreadable* = "this is the machine's own language, not ours" |
| **Green-on-black, CRT-matched hue** | the IBM-terminal ancestor; instant "code" association |
| **Text as ambient wallpaper, not content** | mood over meaning; the interface *breathes* |

Key aesthetic principle for TUIs: **motion doesn't have to carry information to carry feeling.**
A low-density idle animation (rain, a slow scan, a pulsing glyph) makes a terminal feel *alive*
and *inhabited* rather than frozen. The Matrix legitimized "meaningless but beautiful glyph
motion" as a first-class terminal aesthetic — the direct ancestor of `cmatrix`, screensavers,
and idle-state TUI flourishes.

Sources: [Snopes — Matrix code / sushi recipes](https://www.snopes.com/fact-check/the-matrix-code-sushi/),
[No Film School — Matrix Digital Rain Origin](https://nofilmschool.com/matrix-digital-rain-origin),
[Wikipedia — Digital rain](https://en.wikipedia.org/wiki/Digital_rain).

---

## 6. LCARS (Star Trek: TNG) — The Optimistic Anti-Terminal

LCARS is the important *counter-example* — proof that "computer interface" need not mean
"green text on black." Michael and Denise Okuda designed a warm world: **rounded-corner
"elbow" blocks in peach, amber, gold, mauve, and blue on black**, a condensed sans
(*Swiss 911 Ultra Compressed*), and softly curved frames that route the eye. It reads as
*calm, benevolent, effortlessly advanced* — a future where the computer is a trusted colleague,
not a threat.

| Technique | Feeling |
|---|---|
| **Rounded block frames** (achievable in a grid with `╭╮╰╯` and half-block padding) | soft, humane, non-threatening; "designed for people" |
| **Warm pastel palette on black** (not green/amber) | optimism, wealth, post-scarcity calm — color as *reassurance* |
| **Ultra-condensed all-caps labels in colored blocks** | organized, categorized, "everything has its place" |
| **Asymmetric swooping layout, content nested in frames** | fluid, confident, architectural |
| **Color-coded functional zones** | legibility-as-serenity; you always know where you are |

For a TUI: LCARS teaches that **the same primitives (blocks, color, condensed type, black
background) can produce warmth instead of menace purely via hue and corner-rounding.** Swap
green-mono-sharp for pastel-block-round and the identical machine flips from *threat* to
*ally*. This is the clearest demonstration in the whole corpus that vibe is a *parameter set*,
not a fixed style.

Sources: [Wikipedia — LCARS](https://en.wikipedia.org/wiki/LCARS),
[Memory Alpha — Okudagram](https://memory-alpha.fandom.com/wiki/Okudagram).

---

## 7. Severance — Lumon MDR — Sterile Retro-Bureaucratic Dread

*Describe the screen:* A boxy CRT with a slight bulge, teal keycaps, a trackball. The screen
shows a shallow field of numbers in a soft, slightly-pixelated sans (the show uses *Input
Sans*), and the numbers subtly *tremble* — the ones that feel "scary" wobble. Muted palette:
teal-blue digits on a pale field, everything low-contrast, everything a little *too calm*.

Lumon's terminals descend from the 1977 Data General Dasher D2 — deliberately anachronistic,
"toys more than high-tech computers." The unease is manufactured by **contradiction**: a CRT
*and* a touchscreen *and* a trackball; a keyboard with **no Escape key** (a prop Easter egg
literalizing "no exit").

| Technique | Feeling |
|---|---|
| **Muted low-contrast palette** (teal/blue on off-white, no bright accents) | clinical calm that curdles into dread; "nothing here is for you" |
| **Micro-motion on data** — numbers that subtly jitter/tremble | the uncanny; ordinary content behaving *slightly* wrong |
| **Soft, faintly-pixelated humanist sans, not a sharp mono** | corporate-friendly surface hiding something; "the unknown" |
| **Deliberate anachronism / era-mixing** | disorientation; you can't place *when* you are |
| **Missing-affordance symbolism** (no Escape key) | entrapment encoded in the tool itself |
| **Vast empty margins, sparse content** | isolation, institutional hush, the single task as a cell |

The TUI lesson is subtle and powerful: **understatement + a single wrong detail beats
maximalist styling.** A near-normal screen with one uncanny behavior (a value that trembles,
a color that's slightly off, an action you can't take) generates more mood than any amount of
glow. Severance is the *low-contrast, high-unease* pole of the design space — the opposite of
TRON's high-energy neon.

Sources: [Designboom — Severance mid-century/brutalist/retro-futurist universe](https://www.designboom.com/design/severance-closer-look-mid-century-brutalist-retro-futuristic-universe-lumon-03-21-2025/),
[Creative Bloq — Severance prop design](https://www.creativebloq.com/entertainment/movies-tv-shows/5-perfect-severance-prop-designs-that-shaped-the-apple-series),
[Trickle — Severance 60-30-10 UI](https://trickle.so/blog/how-severance-uses-the-60-30-10-rule-to-inspire-ui-design).

---

## 8. The FUI Studios — How the Sausage Is Made (Territory et al.)

Territory Studio (*Blade Runner 2049*, *The Martian*, *Guardians of the Galaxy*, *Ex Machina*)
and peers are the modern authors of the movie-terminal look. Their process reveals *why* these
screens feel the way they do — and it validates the whole "vibe over function" premise.

- **They start from physical/organic textures, not from software.** For *Blade Runner 2049*
  they photographed "optical lenses, cine projectors, microfiche, and card systems" and even
  "grapes, grapefruits, eyeballs and bone... dissected, magnified, photographed and scanned to
  create organic abstraction." → *Feeling:* the interface has an analog soul; it's warm, worn,
  physical, not a flat vector — the used-future carried into motion graphics.
- **The Martian pole = plausible near-future realism**, built with NASA/ESA consultation:
  restrained, data-dense, plain. → *Feeling:* competence, trust, "this could be real."
- **They invent typographic ecosystems** — mixing "kanji, latin, cyrillic and arabic
  letterforms" for signage. → *Feeling:* a lived-in multilingual world; density of civilization.
- **Mood boards drawn from "opera, dance choreography, luminous sea life"** → the palette and
  rhythm decisions are *emotional* first, technical never.

The transferable doctrine for a TUI: **decide the feeling and the reference texture first,
then pick the glyphs/colors/timing that encode it.** The pros never start from "what data do I
have"; they start from "what should this *feel* like," then constrain to the medium. A character
grid is just a very strict version of the same discipline.

Sources: [Territory Studio — Blade Runner 2049](https://territorystudio.com/project/blade-runner-2049/),
[HUDS+GUIS — Blade Runner 2049 UI](https://www.hudsandguis.com/home/2018/blade-runner-2049),
[SciFi Interfaces — Q&A with Territory Studio](https://scifiinterfaces.com/2020/06/23/scifi-interfaces-qa-with-territory-studio/),
[Pond5 — Near-Future Design behind Sci-Fi UI](https://blog.pond5.com/54667-computer-screen-design-territory-films/).

---

## 9. Cross-Cutting Technique Atlas (grid-reproducible)

Everything above collapses into a compact vocabulary. Left column = a move available in a real
monospace terminal; right column = the feeling it manufactures.

### Color & light
- **Black background, always** → "this is a computer drawing, not a document" (the single most
  load-bearing choice; see TRON §4).
- **Single phosphor hue (green / amber)** → legacy hardware, single-gun CRT, discipline, identity
  (Fallout, Alien, Matrix).
- **Amber vs green** → amber = warmer, older, "reading terminal, calm"; green = colder,
  "operational, alert." A real temperature difference, not just palette.
- **Neon dual-accent (cyan+magenta) on black** → 80s digital, high energy, cyberspace (TRON).
- **Warm pastels on black** → benevolent advanced future (LCARS) — subverts the "computer = green"
  expectation.
- **Muted low-contrast** → clinical dread, institutional hush (Severance).
- **One value rendered in red/bright while all else is dim** → alarm, threshold crossed (Alien,
  WarGames).
- **Dim-trail brightness gradients** → depth and motion on a flat grid (Matrix rain).

### Type & case
- **ALL CAPS telemetry** → machine/institutional voice, no individual softening, authority.
- **"Wrong" typeface (serif, or a humanist sans where you expect mono)** → uncanny, older, stranger
  (Alien's City Light; Severance's Input Sans).
- **Wide letter-spacing on warning banners** → gravity, ceremony, danger.
- **Big figlet/banner glyphs for a single status word** → scale-as-emphasis; civilizational stakes.
- **Vendor/version/copyright boot banners** → instant world-building; the OS has a history.

### Motion (via redraw)
- **Teletype character/line reveal at human cadence** → the machine is thinking/transmitting; you
  wait on *its* clock → subordination + suspense. (The single most evocative TUI motion.)
- **Blinking block cursor at an idle prompt** → the machine is listening; anticipation.
- **Idle ambient animation (rain, slow scan sweep, pulsing glyph)** → the system is *alive* and
  inhabited even when idle.
- **Countdown redrawn in place as the only moving element** → tunnel-vision urgency.
- **Subtle micro-jitter on a single element** → the uncanny; ordinary content behaving slightly
  wrong (Severance).
- **Sweeping arcs/trajectories redrawn frame-by-frame** → unstoppable live process, dread.

### Structure & texture
- **No decoration; content sits directly on black** → austerity, everything is functional, coldness.
- **Rounded block frames (`╭╮╰╯` + half-block fills)** → humane, designed-for-people (LCARS).
- **Sharp box-drawing frames (`┌┐└┘├┤`)** → industrial, operational, no-nonsense.
- **ASCII/Unicode as the *only* graphics** (bars `█▓▒░`, line-art maps) → charm, ingenuity, "does
  its best with what it has."
- **Vast empty margins around sparse content** → isolation, focus, the task as a cell.
- **A small consistent status-glyph legend (Semiotic Standard)** → real operational environment.
- **CRT skeuomorphism: scanlines, curvature vignette, phosphor bloom, occasional flicker/roll** →
  nostalgia, warmth, "hardware not webpage."
- **Deliberate era-mixing / mild fidelity heterogeneity** → used-future authenticity; disorientation.

---

## 10. The Two Axes (a design map for TUI mood)

Reading across the corpus, two orthogonal dials govern nearly all of it:

1. **Warmth axis** — *menace ↔ benevolence.* Set by hue + corner geometry + contrast.
   Green/amber-sharp-high-contrast → threat/operational (Alien, WarGames, Fallout).
   Pastel-round-warm → ally (LCARS). Muted-low-contrast → uncanny dread (Severance).

2. **Energy axis** — *hush ↔ spectacle.* Set by motion density + palette saturation.
   Idle blinking cursor + sparse telemetry → hush/gravity (Alien, Severance).
   Cascading rain, sweeping arcs, neon grid → spectacle/aliveness (Matrix, TRON, WarGames).

The same character grid lands anywhere on this plane purely by choosing hue, corner style,
contrast, and motion density. **Vibe is a parameter set, not a style you either have or lack.**
That is the whole thesis of the cyber/sci-fi corpus, and it is entirely reproducible in a real
terminal.

---

## Sources (consolidated)

- Typeset In The Future — *Alien*: https://typesetinthefuture.com/2014/12/01/alien/
- Medium — UX of the Nostromo self-destruct: https://dinosaurenby.medium.com/a-deep-dive-into-the-ux-of-the-nostromos-self-destruct-procedure-9eda80793fe8
- Gamerant — Used Future Aesthetic Explained: https://gamerant.com/science-fiction-used-future-aesthetic-explained/
- kk.org / The Technium — The Used Future: https://kk.org/thetechnium/the-used-future/
- The Ringer — Sci-Fi Is Stuck in the '70s: https://www.theringer.com/2025/08/20/tv/sci-fi-is-stuck-in-the-70s-alien-earth-star-wars-andor-blade-runner
- Fallout Wiki — Pip-Boy 2000: https://fallout.fandom.com/wiki/Pip-Boy_2000
- AlrikOlson/robco-terminal (GitHub): https://github.com/AlrikOlson/robco-terminal
- HP 9845 Project — Screen Art: WarGames: https://www.hp9845.net/9845/software/screenart/wargames/
- CIO — The Technology of WarGames: https://www.cio.com/article/220297/the-technology-of-wargames.html
- We Are The Mutants — Vanishing Point / the Light Grid: https://wearethemutants.com/2017/02/16/vanishing-point-how-the-light-grid-defined-1980s-futurism/
- TV Tropes — Tron Lines: https://tvtropes.org/pmwiki/pmwiki.php/Main/TronLines
- Snopes — Matrix code origin: https://www.snopes.com/fact-check/the-matrix-code-sushi/
- No Film School — Matrix Digital Rain Origin: https://nofilmschool.com/matrix-digital-rain-origin
- Wikipedia — LCARS: https://en.wikipedia.org/wiki/LCARS
- Memory Alpha — Okudagram: https://memory-alpha.fandom.com/wiki/Okudagram
- Designboom — Severance universe: https://www.designboom.com/design/severance-closer-look-mid-century-brutalist-retro-futuristic-universe-lumon-03-21-2025/
- Creative Bloq — Severance prop design: https://www.creativebloq.com/entertainment/movies-tv-shows/5-perfect-severance-prop-designs-that-shaped-the-apple-series
- Territory Studio — Blade Runner 2049: https://territorystudio.com/project/blade-runner-2049/
- HUDS+GUIS — Blade Runner 2049 UI: https://www.hudsandguis.com/home/2018/blade-runner-2049
- SciFi Interfaces — Q&A with Territory Studio: https://scifiinterfaces.com/2020/06/23/scifi-interfaces-qa-with-territory-studio/
