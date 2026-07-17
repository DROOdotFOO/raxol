# Dossier: Terminal Color-Scheme Culture as Identity

**Slug:** `blogs-color-scheme-culture`
**Scope:** How a 16-color palette becomes a personal or brand identity. The histories,
design rationales, and encoded psychology of the major terminal/editor palette families:
Solarized, gruvbox, Dracula, Nord, Catppuccin, Tokyo Night, and base16/tinted-theming.
**Mission frame:** aesthetics and vibes, not usability. Every entry pairs a **concrete
technique** (a hex relationship, a naming convention, a mascot, a contrast decision) with
the **feeling** it produces. Ergonomics appears only where it doubles as an aesthetic device.

---

## 0. The thesis: the palette IS the interface's face

On the web you express identity through drop shadows, glossy buttons, a bespoke typeface,
pixel-perfect indents, hero imagery. Strip all of that away — leave only a monospace grid,
16 (or 256, or truecolor) slots, box-drawing glyphs, and whitespace — and **color is almost
the entire expressive budget left.** The terminal cannot change its font geometry per-app;
it cannot render a gradient button. What it *can* do is assign meaning and mood to ~16
foreground/background values. So the color scheme stops being a preference and becomes the
**visual signature** — the thing a screenshot is instantly recognizable by, the thing that
travels as a brand across 200+ apps, the thing communities organize around.

The central move all these projects make: **treat 16 arbitrary ANSI slots as a designed
system with internal mathematical or semantic relationships**, then give that system a
*name and a story*. The name + story is what converts a palette into an identity. "16 hex
codes" is a config file. "An arctic, north-bluish palette reminiscent of the Aurora
Borealis" is a personality you can belong to.

---

## 1. SOLARIZED — the scientific origin myth (Ethan Schoonover, 2011)

**Repo/site:** https://ethanschoonover.com/solarized/ · **Structure:** 8 monotones + 8 accents = 16.

### The technique: designed in CIELAB, not RGB
Schoonover came from a photography / color-management background and designed the palette in
the **CIELAB perceptual color space**, then generated sRGB hex values from canonical CIELAB
values. This is the load-bearing technical move and the source of the whole "scientific"
aura around the scheme.

- **Technique:** monotones have *symmetric CIELAB lightness differences*. **Feeling:**
  rigor, trustworthiness, "this was engineered, not vibed." The dark and light modes are
  literal inversions with identical perceived contrast steps — which reads as *precision* and
  *inevitability* rather than taste.
  > "The monotones have symmetric CIELAB lightness differences, so switching from dark to
  > light mode retains the same perceived contrast in brightness between each value. Each
  > mode is equally readable." — ethanschoonover.com

- **Technique:** reduce *brightness* contrast but keep *hue* contrast. **Feeling:** calm,
  shaded, non-fatiguing — yet still legible/distinct. This is the single most-copied idea in
  the entire genre.
  > "Solarized reduces *brightness contrast* but, unlike many low contrast colorschemes,
  > retains *contrasting hues* (based on colorwheel relations) for syntax highlighting
  > readability." — ethanschoonover.com

### The describe-the-screen passage
Solarized on screen looks like *aged paper in shade* (light mode: `base3` #fdf6e3, a warm
cream, never pure white) or *deep teal-grey dusk* (dark mode: `base03` #002b36, a desaturated
blue-green-black, never pure black). Text is never maximum-contrast black-on-white or
white-on-black — it sits a few CIELAB steps in from the extremes. The accents (yellow, orange,
red, magenta, violet, blue, cyan, green) are all pulled to roughly equal muted saturation, so
no single color screams; syntax highlighting reads as a *harmonized chord* rather than a set
of alarms.

### The origin metaphor: reading in the shade
The emotional core is a physical-comfort metaphor about *sunlight*, which is also where the
name comes from:
> "On a sunny summer day I love to read a book outside. Not right in the sun; that's too
> bright. I'll hunt for a shady spot under a tree. The shaded paper contrasts with the crisp
> text nicely... Black text on white from a computer display is akin to reading a book in
> direct sunlight and tires the eye." — ethanschoonover.com

- **Technique:** frame the palette as *the shade under the tree*. **Feeling:** the scheme
  isn't just colors, it's a small act of care for your eyes — a considered, almost gentle
  posture. This narrative move (attach a sensory memory to the palette) is what later projects
  imitate wholesale.

### Why it mattered culturally
Solarized established the **genre template**: (a) exactly 16 colors, (b) paired light+dark,
(c) a public design rationale essay, (d) ports to every app, (e) a memorable one-word name.
On HN it's repeatedly described in near-reverent terms ("a beacon in the darkness," "moving
beyond gimmicky themes") *because* of the science framing. The critique is the mirror image:
low contrast that some (especially aging eyes) find *too* dim — the same reduced-contrast move
that reads as "calm" to one user reads as "muddy/hard to see" to another. Its influence spawned
direct successors (OKSolar, which re-derives it in the newer OKLab space) — proof that the
"scientific palette" is itself now a *tradition* people iterate on.

**Sources:** https://ethanschoonover.com/solarized/ · https://en.wikipedia.org/wiki/Solarized ·
https://news.ycombinator.com/item?id=33406805 · https://news.ycombinator.com/item?id=33674649 (OKSolar)

---

## 2. GRUVBOX — retro warmth as identity (Pavel Pertsev / morhetz, 2012)

**Repo:** https://github.com/morhetz/gruvbox · **Lineage:** "heavily inspired by badwolf,
jellybeans and solarized."

### The technique: earthy/retro hues + configurable contrast
Where Solarized is cool and clinical, gruvbox is *warm and analog*. The palette leans on
**dark browns, burnt oranges, mustard yellows, olive/lime greens, and a dusty aqua** — colors
that evoke 1970s print, faded film, and CRT phosphor rather than a spec sheet.

- **Technique:** stated design goal — "keep colors easily distinguishable, contrast enough and
  still pleasant for the eyes." **Feeling:** comfortable, lived-in, unpretentious.
  > "Designed as a bright theme with pastel 'retro groove' colors and light/dark mode
  > switching in the way of solarized." — github.com/morhetz/gruvbox

- **Technique:** the word **"retro groove"** itself. **Feeling:** nostalgia, analog warmth,
  a deliberate rejection of neon modernism. The *name of the aesthetic* does identity work
  before a single color is seen.

- **Technique:** hard / medium / soft **contrast variants** for both dark and light. **Feeling:**
  the palette adapts to *your* mood and light, rather than dictating one. This "dial your own
  warmth" flexibility is an identity of its own — gruvbox users often speak of it as *cozy*.

### The describe-the-screen passage
Gruvbox dark is a **near-black warm brown** background (`#282828`) — not blue-black like Nord,
not teal like Solarized, but *coffee-dark*. On it sit a creamy off-white foreground, a signal
**orange** (`#fe8019`) for operators/constants, a **mustard yellow**, an **olive green**, and a
muted **aqua**. Nothing is saturated to gaming-RGB levels; every hue looks like it was left in
the sun a decade ago. The overall read is *a well-worn leather notebook* or *a Wes Anderson
color card* — earthy, autumnal, humane.

- **Feeling summary:** where Solarized says "I am careful," gruvbox says **"I am comfortable."**
  It is the archetype of the **warm/retro** pole of the whole palette-psychology axis.

**Sources:** https://github.com/morhetz/gruvbox · https://gruvbox.org/ ·
https://deepwiki.com/morhetz/gruvbox/3.1-color-palette

---

## 3. DRACULA — the palette that became a brand empire (Zeno Rocha, 2013)

**Repo:** https://github.com/dracula/dracula-theme · **Site:** https://draculatheme.com ·
**Structure:** dark purple base + 6 vivid accents.

### The technique: a *character* and a *logo*, not just hex codes
Dracula is the clearest proof that **identity = story + mark**. The others have a rationale;
Dracula has a *brand*: a name (the vampire), a mascot/logo (the fanged emblem), Pro merch
(t-shirts, hoodies), a paid product, a "one theme, all platforms" promise across 400+ apps.

- **Origin story as identity anchor:** Rocha built it in 2013 *after his laptop was stolen in
  Madrid*, reinstalling everything and finding no theme he liked. **Feeling:** underdog /
  personal-taste authenticity. The theft anecdote is repeated everywhere — the *narrative* is
  part of the brand.
  > "Dracula's original colors, created in 2013, were based on personal taste. This new Pro
  > version brings a more refined and mathematical approach that normalizes luminosity and
  > saturation." — from Wikipedia's summary of the Pro rationale

- **Technique:** consistency-across-tools as the *point*. **Feeling:** a seamless, context-
  switch-free world where every app wears the same face. Rocha's stated driver was "the cost
  of context switching" — he wanted a *uniform* experience, which is exactly how a palette
  becomes a personal identity: it's the same everywhere you look.

### The describe-the-screen passage
Dracula dark is a **desaturated blue-purple charcoal** (`#282a36`) — noticeably *purple*, which
is the tell. On it: a bright off-white foreground, a soft **purple** (`#bd93f9`), hot **pink/
magenta** (`#ff79c6`), acid **green** (`#50fa7b`), **cyan** (`#8be9fd`), warm **yellow**
(`#f1fa8c`), and **orange**/**red** for warnings. The accents are *more saturated and playful*
than Solarized or Nord — this is a theme that wants to look **cool and a little theatrical**,
matching the gothic name. The vibe is *neon nightlife with a sense of humor*, not clinical calm.

- **Technique:** the Pro version "normalizes luminosity and saturation." **Feeling:** the brand
  matured from "vibes-based" to "engineered," borrowing Solarized's scientific legitimacy
  *after* winning on personality first. Note the reversal: Solarized led with science; Dracula
  led with *character* and retrofitted the math.

### Cultural weight
"Dracula is the dark mode color scheme with a cult following of coders" (Lizzy Lawrence,
Protocol). Dracula Pro passed **$250k+ in sales** — the first palette to prove a color scheme
could be a *business*. This is the culmination of "palette as identity": people don't just use
Dracula, they *buy the shirt*.

**Sources:** https://draculatheme.com · https://zenorocha.com/dracula-theme ·
https://en.wikipedia.org/wiki/Dracula_(color_scheme) · https://github.com/dracula/dracula-theme

---

## 4. NORD — the arctic mood board (arcticicestudio, 2016)

**Repo:** https://github.com/nordtheme/nord · **Site:** https://www.nordtheme.com ·
**Structure:** 16 colors in **four named sub-palettes**.

### The technique: name the *sub-groups* after a landscape
Nord's signature identity move is dividing its 16 colors into **four poetically-named palettes**,
each a piece of an arctic scene. This is world-building via naming — the palette is a *place*.

| Sub-palette | Colors | Poetic frame | Feeling encoded |
|---|---|---|---|
| **Polar Night** | 4 dark blue-greys | night, depth | foundation, restraint, the ground layer |
| **Snow Storm** | 3 near-whites | snow, luminosity | clarity, gentle brightness |
| **Frost** | 4 blues (the "heart") | "frozen polar water," "pure and clear ice," "arctic waters" | calm focus, glacial vitality |
| **Aurora** | 5 colors (red/orange/yellow/green/purple) | "reminiscent of the Aurora Borealis / northern lights" | semantic states — error, warning, success, anomaly |

- **Technique:** the entire palette is **cold-biased** — even the "warm" Aurora accents are
  muted and sit inside an overwhelmingly blue field. **Feeling:** icy, minimal, focused, elegant.
  Nord is the archetype of the **cold/nordic** pole.
  > "Nord consists of four palettes utilizing a total of sixteen carefully selected, dimmed
  > pastel colors for an eye-comfortable experience... The Frost palette can be described as
  > the heart of Nord." — nordtheme.com

- **Technique:** "created for clear, uncluttered and elegant designs following a minimal and
  flat style pattern." **Feeling:** Scandinavian design-minimalism — the palette carries the
  same values as flat UI / Bauhaus restraint. It *looks like* the design philosophy it names.

### The describe-the-screen passage
Nord is a **blue-grey twilight**: the background (`#2e3440`) is a cool slate that reads as
*dusk over snow*. Text is a soft blue-white. The accents are **desaturated and low-energy** —
even the red (`#bf616a`) is a dusty rose, the green (`#a3be8c`) a sage, the yellow (`#ebcb8b`) a
pale sand. The overall effect is *quiet, hushed, expensive* — like a Scandinavian furniture
catalog. Where Dracula is nightlife and gruvbox is a leather notebook, **Nord is a snowfield at
blue hour.** Its most common critique is the flip side of its identity: so uniformly low-contrast
and blue that some find it *hard to distinguish* syntax — the "hushed" vibe can tip into "muddy."

**Sources:** https://www.nordtheme.com/docs/colors-and-palettes/ · https://github.com/nordtheme/nord ·
https://news.ycombinator.com/item?id=33406069

---

## 5. CATPPUCCIN — pastel cuteness as a community (2021)

**Repo:** https://github.com/catppuccin/catppuccin · **Site:** https://catppuccin.com ·
**Structure:** **4 flavors** × **26 named colors** each. Tagline: *"Soothing pastel theme for
the high-spirited!"*

### The technique: cuteness + community as the identity
Catppuccin is the most *2020s* of the families — its identity is **a cat mascot, coffee-drink
flavor names, a Discord community, and hundreds of user-contributed ports.** The palette is
almost a byproduct of a *fandom*.

- **Technique:** name the four modes after **coffee drinks** — Latte (light), Frappé, Macchiato,
  Mocha (dark). **Feeling:** warm, cozy, café-comfortable; approachable and non-technical. You
  don't "configure a contrast variant," you *pick a drink*.
  > "Latte — Our lightest theme harmoniously inverting the essence of Catppuccin's dark themes."
  > "Mocha — The Original — Our darkest variant offering a cozy feeling with color-rich accents."
  > — catppuccin README

- **Technique:** name individual colors *whimsically and sensuously* — **Rosewater, Flamingo,
  Pink, Mauve, Maroon, Peach, Sky, Sapphire, Lavender** (plus a structured greyscale: Text,
  Subtext, Overlay, Surface, Base, Mantle, Crust). **Feeling:** playful, tactile, a little
  gourmand. Naming a grey "Crust" and a blue "Sapphire" turns a spec into a *menu*.

- **Technique:** the stated four-principle philosophy. **Feeling:** designed-but-friendly; the
  "middle ground" positioning is itself a personality (neither austere Solarized nor loud gaming
  RGB).
  > "Colorfulness — the colorfulness of something contributes to the distinction amongst the
  > parts of that something." / "Balance — not too dull, not too bright." / "Harmony — vivacious
  > colors must complement each other." — catppuccin README
  > "a community-driven pastel theme that aims to be the middle ground between low and
  > high-contrast themes." — catppuccin.com

- **Technique:** the **cat mascot + "high-spirited" + emoji-forward branding** (😸) and an
  open **ports registry** (hundreds of apps, each maintained by community members). **Feeling:**
  belonging. Catppuccin is less "a palette I use" and more "a community I'm in." This is the
  purest expression of *palette-as-identity*: the aesthetic is a social badge.

### The describe-the-screen passage
Catppuccin Mocha is a **soft dark plum-grey** (`#1e1e2e`, "Base") — warmer and gentler than
Dracula's purple-charcoal. The accents are **pastel, chalky, low-saturation** — a candy pink,
a lavender, a sky blue, a mint, a peach — like *macarons* or *sidewalk chalk*. Nothing is sharp;
every edge is soft. Latte (the light flavor) is a warm off-white with the same pastel accents
darkened just enough to read — *a pastel sticker sheet in daylight*. The vibe is **cozy, cute,
gentle, safe** — the "cottagecore" of terminal themes.

**Sources:** https://github.com/catppuccin/catppuccin ·
https://raw.githubusercontent.com/catppuccin/catppuccin/main/README.md · https://catppuccin.com/palette/

---

## 6. TOKYO NIGHT — the neon-cityscape mood (enkia, ~2020)

**Repo:** https://github.com/enkia/tokyo-night-vscode-theme · Tagline: *"celebrates the lights
of Downtown Tokyo at night."*

### The technique: a specific *place at a specific time* as the palette
Tokyo Night's identity is a single vivid image: **the neon skyline of Tokyo after dark.** Every
color choice is justified by that scene — this is the "mood board palette" taken to its logical
end.

- **Technique:** deep **navy/indigo** background (not black) + saturated **blue and purple**
  accents + occasional **amber/warm** points. **Feeling:** electric-but-calm; the glamour of a
  city at night without the harshness. The background *recedes* so the accents read like *signage
  glowing against a dark sky.*
  > "The design draws from the color palette of Tokyo's cityscape after dark: deep indigo skies,
  > electric blue signage, soft purple neon, and warm amber streetlights." — reported summary
  > "the background recedes and syntax colors carry just enough saturation to be distinct without
  > being harsh." — reported summary

### The describe-the-screen passage
Tokyo Night (Storm variant) is a **deep desaturated navy** (`#24283b`) — a *night sky over a
city*. Blues and purples dominate the syntax, punctuated by teal, a soft green, and a warm
orange/yellow that read like *distant streetlights and neon kanji*. It's more saturated than Nord,
cooler than Dracula, and more *cinematic* than either — the palette equivalent of a Blade-Runner /
city-pop album cover. The feeling is **wistful, urban, nocturnal glamour.**

**Sources:** https://github.com/enkia/tokyo-night-vscode-theme ·
https://marketplace.visualstudio.com/items?itemName=enkia.tokyo-night

---

## 7. BASE16 / TINTED-THEMING — identity as *architecture* (Chris Kempson, 2012 → Tinted Theming)

**Repo:** https://github.com/chriskempson/base16 · **Fork/steward:** https://github.com/tinted-theming ·
**Structure:** a *specification*, not a single palette — 16 slots with fixed semantic roles.

### The technique: standardize the *slots*, let the *colors* vary
base16 is the meta-move of the whole genre. Instead of one palette, it defines a **contract**:
`base00`–`base07` are a dark→light greyscale ramp; `base08`–`base0F` are eight accent hues with
*assigned syntactic meaning* (red=variables, orange=constants, ... through to browns/pinks). Any
palette that fills those 16 slots can be mechanically **templated** into any app.

- **Technique:** fixed slot semantics + **Mustache templating** → one scheme builds for hundreds
  of apps automatically. **Feeling (for the maker):** your palette becomes *portable identity* —
  define 16 colors once, wear them everywhere with zero per-app work. This is the infrastructure
  that makes "one theme, all platforms" (Dracula's promise) a *generic capability* anyone can use.
  > "Base16 is not a theme but a framework for building Tomorrow styled themes using a base of
  > sixteen colours." — base16 guidelines
  > "base00 to base07 are typically variations of a shade... base08 to base0F are typically
  > individual colors used for types, operators, names and variables." — base16 guidelines

- **Technique:** the **16-slot constraint itself** (inherited from ANSI, kept deliberately).
  **Feeling:** discipline as aesthetic — "wrong becomes hard" because the structure forces a
  coherent dark-ramp + 8-accent shape on every scheme. The constraint *is* the design system;
  it's why base16 schemes feel like a *family* even when their hues differ wildly.

- **Technique:** a huge **shared scheme gallery** (Tinted Theming's `schemes` repo). **Feeling:**
  a commons / lingua franca. base16 is the *Esperanto* of terminal palettes — Solarized, gruvbox,
  Nord, and Tokyo Night all exist *as* base16 schemes, so the framework is the connective tissue
  under the whole culture.

### The describe-the-screen passage
base16 has no single look — but a *base16-shaped* theme is recognizable by its **structural
regularity**: a clean 8-step monochrome ramp behind exactly 8 accent colors, each doing the same
syntactic job across every app you open. Switching your entire computer's aesthetic — editor,
terminal, window manager, shell prompt — with **one command** (`tinty` / base16-shell) is itself
the aesthetic experience: *total environmental coherence.*

**Sources:** https://github.com/chriskempson/base16 · https://chriskempson.com/projects/base16/ ·
https://github.com/tinted-theming/home · https://deepwiki.com/chriskempson/base16

---

## 8. THE PSYCHOLOGY AXIS — mapping technique to feeling across families

The families sort onto a small set of axes. Each axis is a **technique dial** with a **feeling** at
each end.

### Axis A — color temperature (the primary identity split)
- **Cold/blue** (Nord, Tokyo Night, Solarized-dark): technique = blue-biased background + desaturated
  cool accents. Feeling = calm, focused, minimal, *expensive*, a little austere.
- **Warm/earthy** (gruvbox, Catppuccin-Mocha, Solarized-light): technique = brown/amber-biased
  background + muted warm accents. Feeling = cozy, nostalgic, humane, safe.
- **Purple/theatrical** (Dracula): technique = purple-charcoal base + high-saturation playful
  accents. Feeling = cool, nocturnal, fun, branded.

### Axis B — saturation / energy
- **Muted/dimmed** (Solarized, Nord, gruvbox): "designed pastel," low chroma. Feeling = mature,
  restful, serious craft.
- **Pastel-soft** (Catppuccin): low chroma but *light* — chalky candy. Feeling = cute, gentle, young.
- **Vivid/neon** (Dracula, Tokyo Night accents): high chroma against dark. Feeling = energetic,
  glamorous, expressive.

### Axis C — contrast philosophy (the load-bearing comfort choice)
- **Low brightness-contrast, high hue-contrast** (Solarized's founding idea, inherited by nearly
  all): technique = pull fg/bg toward the middle, keep hues far apart. Feeling = "the shade under
  the tree," reduced eye fatigue *as an aesthetic of care*. Its risk (too dim) is the same knob.
- **Configurable contrast** (gruvbox hard/med/soft): the *dial itself* is identity — "adjust me to
  your mood/room."

### Axis D — how identity is *narrated* (the naming/story layer — where palette becomes brand)
This axis, not the colors, is what most converts a palette into an identity:
- **Science story** (Solarized: CIELAB, symmetric lightness) → *trust, rigor, inevitability.*
- **Landscape/world story** (Nord: Polar Night/Frost/Aurora; Tokyo Night: the city at dusk) →
  *immersion, mood, place.*
- **Character/brand story** (Dracula: vampire, logo, merch, the theft anecdote) → *personality,
  belonging-by-purchase.*
- **Community/cuteness story** (Catppuccin: cat mascot, coffee flavors, sensuous color names, ports
  registry) → *belonging-by-membership, play.*
- **Architecture story** (base16: 16 fixed slots, templating) → *portability, discipline, the
  commons.*

**The meta-pattern:** a bag of 16 hex codes is inert. It becomes an *identity* when wrapped in
(1) an internal relationship (CIELAB math, a dark-ramp + 8-accent contract), (2) a name that is a
*noun with connotations* (a place, a drink, a monster, a season), and (3) a *distribution mechanism*
(ports, templates, merch) that lets a person wear the same face across every surface they touch. The
terminal's poverty of expressive channels is precisely what makes the palette carry this much
identity weight — with fonts and shadows gone, **the 16 colors are the whole personality.**

---

## 9. Notable quotes (verbatim, for reuse)

- **Solarized / selective contrast:** "Solarized reduces *brightness contrast* but, unlike many
  low contrast colorschemes, retains *contrasting hues* (based on colorwheel relations) for syntax
  highlighting readability." — ethanschoonover.com
- **Solarized / the shade metaphor:** "Not right in the sun; that's too bright. I'll hunt for a
  shady spot under a tree... Black text on white from a computer display is akin to reading a book
  in direct sunlight and tires the eye." — ethanschoonover.com
- **gruvbox / retro groove:** "Designed as a bright theme with pastel 'retro groove' colors and
  light/dark mode switching in the way of solarized." — github.com/morhetz/gruvbox
- **Dracula / science-after-taste:** "Dracula's original colors, created in 2013, were based on
  personal taste. This new Pro version brings a more refined and mathematical approach that
  normalizes luminosity and saturation." — Wikipedia (Dracula color scheme)
- **Nord / the arctic heart:** "Nord consists of four palettes utilizing a total of sixteen
  carefully selected, dimmed pastel colors for an eye-comfortable experience... The Frost palette
  can be described as the heart of Nord." — nordtheme.com
- **Catppuccin / the middle ground:** "a community-driven pastel theme that aims to be the middle
  ground between low and high-contrast themes." — catppuccin.com
- **Catppuccin / harmony principle:** "Harmony — vivacious colors must complement each other." —
  catppuccin README
- **Tokyo Night / the city image:** "deep indigo skies, electric blue signage, soft purple neon,
  and warm amber streetlights." — reported design summary
- **base16 / framework-not-theme:** "Base16 is not a theme but a framework for building Tomorrow
  styled themes using a base of sixteen colours." — base16 guidelines

---

## 10. Sources

- Solarized (official): https://ethanschoonover.com/solarized/
- Solarized (Wikipedia, CIELAB detail): https://en.wikipedia.org/wiki/Solarized
- Solarized dev on HN: https://news.ycombinator.com/item?id=33406805
- OKSolar (OKLab re-derivation): https://news.ycombinator.com/item?id=33674649
- gruvbox: https://github.com/morhetz/gruvbox · https://gruvbox.org/ · https://deepwiki.com/morhetz/gruvbox/3.1-color-palette
- Dracula: https://draculatheme.com · https://zenorocha.com/dracula-theme · https://en.wikipedia.org/wiki/Dracula_(color_scheme) · https://github.com/dracula/dracula-theme
- Nord: https://www.nordtheme.com/docs/colors-and-palettes/ · https://github.com/nordtheme/nord
- Catppuccin: https://github.com/catppuccin/catppuccin · https://catppuccin.com/palette/ · https://raw.githubusercontent.com/catppuccin/catppuccin/main/README.md
- Tokyo Night: https://github.com/enkia/tokyo-night-vscode-theme · https://marketplace.visualstudio.com/items?itemName=enkia.tokyo-night
- base16 / Tinted Theming: https://github.com/chriskempson/base16 · https://chriskempson.com/projects/base16/ · https://github.com/tinted-theming/home · https://deepwiki.com/chriskempson/base16
