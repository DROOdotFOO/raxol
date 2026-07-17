# notcurses (C) — Aesthetic Dossier

> "Profound changes are imminent in the ancient craft of the Beautiful." notcurses is the **maximalist** of terminal graphics libraries — a library whose entire personality is a refusal to assume the terminal is poor. Where the whole ncurses tradition begins from the lowest common denominator and lets you claw upward, notcurses begins at the ceiling and steps *down* only when forced. It is the reference implementation of the **"blingful"** aesthetic: 24-bit color, stacked translucent planes, multimedia, and a graduated ladder of sub-cell blitters that can turn a monospace grid into anything from chunky ASCII art to a near-photographic image, silently choosing the best rendering the terminal can bear.

- **Repo:** https://github.com/dankamongmen/notcurses (C, Apache-2.0)
- **Docs:** https://notcurses.com
- **Author:** Nick Black ("dankamongmen"), Atlanta. Previously wrote **outcurses**, an effects/widgets library *for* ncurses — notcurses is the deliberate break from that lineage, abandoning ncurses constraints for creative freedom.
- **Self-description:** "blingful character graphics/TUI library. definitely not curses."
- **Category:** low-level TUI/character-graphics library (the substrate other apps are built on), sibling to ncurses, termbox, and — one abstraction layer up — to the whole toolkit ecosystem. But where those are *libraries of restraint*, notcurses is a **library of ambition**.
- **Family:** demoscene / maximalist / "text mode for the 21st century."

---

## 1. The one-sentence identity

Every terminal library draws cells. notcurses's identity is that it treats the cell not as an atom but as a **container of sub-cell resolution** — and it will pack as many addressable pixels into each character cell as the terminal's Unicode version and graphics protocol allow, then degrade gracefully and *invisibly* when it can't. The aesthetic thesis is stated as an inversion of the entire curses philosophy:

> "Curses assumes the minimum and allows you (with effort) to step up, whereas Notcurses assumes the maximum and steps down (by itself) when necessary."

That single sentence is the whole design opinion. It reframes capability-detection from **caution** (curses: "prove to me this terminal can do color") into **ambition** (notcurses: "of course it can; I'll dial back only if reality objects"). Everything downstream — the blitter ladder, the pixel protocols, the translucent planes — is that manifesto made API. Apps built on notcurses *dare* to look like GUIs because the library dares first.

---

## 2. The blitter ladder — resolution as a vibe dial

This is notcurses's signature technique and its most important contribution to TUI aesthetics: a **graduated ladder of "blitters"**, each of which subdivides the single character cell into more addressable sub-regions using progressively richer Unicode block glyphs, ending in true pixels. Choosing a blitter is choosing a point on a continuum from "retro ASCII art" to "photograph." The rungs (from `notcurses_visual(3)`):

| Blitter | Glyphs used | Sub-regions per cell | Effective look |
| --- | --- | --- | --- |
| `NCBLIT_1x1` | space + solid block | 1 | ASCII baseline; blocky; stretches image 2× vertically |
| `NCBLIT_2x1` | half blocks `▀▄` | 2 (1×2) | classic "half-block" pixel art; **aspect-correct** |
| `NCBLIT_2x2` | quadrants `▖▗▘▙▟` | 4 (2×2) | chunky-but-square pixels; exactly 2 colors/cell |
| `NCBLIT_3x2` | sextants | 6 (2×3) | noticeably finer; gated on **Unicode 13** |
| `NCBLIT_4x2` | octants | 8 (2×4) | denser again; gated on **Unicode 16**; "can lose color fidelity" |
| `NCBLIT_BRAILLE` | braille `⠀`–`⣿` | 8 dots (2×4) | monochrome-ish, stippled; "very good for plots" |
| `NCBLIT_PIXEL` | Sixel / Kitty / iTerm2 | true pixels | **photographic**; a real image in the grid |

### 2.1 What each doubling *feels* like

- **`NCBLIT_1x1` / `NCBLIT_2x1`** → **feeling:** honest, retro, unmistakably "terminal." Half-blocks are the aesthetic of Teletext, PETSCII, and 1980s bulletin-board art — you *read* the blockiness as heritage, not failure. 2×1 is the aspect-preserving sweet spot for "I want an image but I want it to still look like a terminal did it."
- **`NCBLIT_2x2` (quadrants)** → **feeling:** the "chunky pixel" videogame look — Minecraft-in-a-terminal. Square-ish cells, only two colors each, so images read as bold poster-ized blocks. Deliberate, crafted, low-fi-on-purpose.
- **`NCBLIT_3x2` sextants → `NCBLIT_4x2` octants** → **feeling:** the moment the image stops looking like "art" and starts looking like a *downsampled photo*. Each doubling of vertical resolution smooths the mosaic; at octants (8 sub-cells) the eye reads gradients and curves instead of blocks. This is the rung where a TUI quietly announces "this is a modern terminal." The Unicode-version gating (sextants need U13, octants need U16) means **the finer your look, the newer the terminal font must be** — notcurses turns "how new is your Unicode?" into "how photographic can I be?"
- **`NCBLIT_BRAILLE`** → **feeling:** scientific-instrument, oscilloscope, plotter-pen. Braille's 2×4 dot matrix is monochrome and stippled — bad for photos, sublime for *line plots and waveforms* (the docs say so explicitly). This is the aesthetic btop borrows for its scrolling CPU graphs: the "engineering readout" vibe.
- **`NCBLIT_PIXEL`** → **feeling:** the uncanny one. A genuine bitmap sits inside your character grid; the TUI has become a GUI. Reviewers describe pushing "an SNES game's output straight to the console."

- **Technique:** a single enum choice (`NCBLIT_*`) that trades cell-resolution against terminal capability → **feeling:** the same photo can be served as retro block-art *or* as a sharp bitmap from one code path, so an app can pick a **mood** (nostalgic / crafted / photographic) rather than fighting the grid.

### 2.2 Degradation as an aesthetic value, not an apology

The selection logic (`NCBLIT_DEFAULT`) encodes taste directly:
- UTF-8 disabled → collapse everything to `NCBLIT_1x1` (pure ASCII, no complaint).
- `NCSCALE_NONE` / `NCSCALE_SCALE` → `NCBLIT_2x1` (protect aspect ratio; images stay un-distorted).
- `NCSCALE_STRETCH` → `NCBLIT_4x2` if octants exist, else `NCBLIT_3x2`, else `NCBLIT_2x2` — always the **finest available**, stepping down one rung at a time.

The escape hatch is `NCVISUAL_OPTION_NODEGRADE`: pass it and the render *fails* rather than falling back. The default is the opposite — **silent graceful step-down**. This is a genuine design ethics: the app author states intent ("show me this image as richly as possible") and the library negotiates with reality on their behalf, never surfacing the negotiation. The aesthetic payoff is that **notcurses apps look their best everywhere and broken nowhere** — the same binary is photographic on a Kitty terminal and tasteful block-art on a Linux VT, with zero conditional code from the developer.

- **Technique:** best-blitter-available default + opt-in `NODEGRADE` fail-hard → **feeling:** confidence. Apps can *aim high* without risk, so they do; the house style of notcurses software is more visually ambitious than ncurses software precisely because the downside is removed.

---

## 3. Pixel graphics — the TUI that behaves like a GUI

`NCBLIT_PIXEL` reaches past Unicode entirely into **bitmap protocols**: Sixel (DEC's 1980s dot-graphics format, revived), the **Kitty** graphics protocol, **iTerm2**'s inline images, and the **Linux framebuffer** on the bare console. notcurses probes for these at startup and uses the best one present. Multimedia is first-class: with the (optional) FFmpeg/OpenImageIO backend it decodes **images *and video*** and blits frames into planes — `ncplayer` plays videos as terminal graphics; `ncneofetch` shows a real logo; the `view` demo renders "images and a video are rendered as text."

- **Technique:** true pixel protocols + a video decoder wired to the plane system → **feeling:** the terminal stops being a text device and becomes a *frame buffer with a prompt*. The vibe is transgressive — you feel you're getting away with something, which is exactly the "blingful" delight the author is chasing.
- **The old-tricks fallback** → third-party reviewers single this out: it "will also work on the basic Linux console, with no graphical system installed, by using some very old tricks… the aesthetic really tickles our love for the **demoscene**, particularly since it borrows some of those techniques as a fallback pixel drawing mode." The library's cultural home is the **demoscene** — the subculture of pushing constrained hardware to spectacular visual excess. That is the emotional register of a notcurses app at full tilt: not corporate polish but *demo-reel bravado*.

- **Technique:** Sixel/Kitty/iTerm2/framebuffer under one `NCBLIT_PIXEL` roof, framebuffer as demoscene-flavored fallback → **feeling:** "text mode for the 21st century" (Hackaday) — simultaneously futuristic (real bitmaps) and nostalgic (VT sixels, console framebuffer), a retro-futurist duality.

---

## 4. Planes, the z-axis, and alpha — real compositing on a grid

The other half of notcurses's aesthetic reach is **NCPlanes**: independent rectangular rendering surfaces stacked on a **z-axis** with a strict (currently total) order, over a mandatory **standard plane** that can't be deleted. Planes can be moved in x/y (`ncplane_move_yx`), reordered in depth (`ncplane_move_top`/`ncplane_move_bottom`), and merged down (`ncplane_mergedown` composites "the frame that would be rendered if only source and destination existed on the z-axis"). Crucially, **every cell carries alpha**.

### 4.1 The alpha vocabulary

Each `nccell`'s foreground and background channel carries 2 alpha bits with four modes:
- **`NCALPHA_OPAQUE`** — normal solid color.
- **`NCALPHA_BLEND`** — this cell's color *mixes* with whatever plane sits beneath it.
- **`NCALPHA_TRANSPARENT`** — the cell shows the plane below through entirely (a true hole).
- **`NCALPHA_HIGHCONTRAST`** — the library computes a foreground color guaranteed to contrast with whatever background bleeds through, so overlaid text stays legible over arbitrary imagery.

### 4.2 What this unlocks that flat-cell models can't

- **Drop-shadow panels** — a dark, half-transparent (`BLEND`) plane offset a cell down-and-right behind a dialog produces a genuine soft shadow; the content beneath *darkens* rather than being erased. Flat single-buffer libraries can't do this without manually reading and recoloring the cells behind the box.
  - **feeling:** depth, elevation, "this modal floats above the app" — the exact GUI cue that says *modal*, achieved on a character grid.
- **Translucent modals / dimmed backdrops** — a full-screen `BLEND` plane over the app dims everything uniformly, then an opaque dialog sits on top. The classic "focus the dialog, mute the world" move.
  - **feeling:** hierarchy and focus; the world recedes without disappearing.
- **Layered overlays / heads-up glass** — transparent-background planes let a HUD, tooltip, or status glass sit over live content, compositing per-cell.
  - **feeling:** a stacked, dimensional interface rather than a single flat page.
- **`HIGHCONTRAST` captions over images** — text over a photographic pixel plane stays readable automatically.
  - **feeling:** polish; the app never shows you white-on-white, so it reads as *considered*.

- **Technique:** z-ordered planes + per-cell 4-mode alpha + `mergedown` compositing → **feeling:** **dimensionality**. The single most GUI-like quality a TUI can have — shadows, translucency, stacking — comes free, and notcurses apps that use it feel spatial where ncurses apps feel papery.

---

## 5. Color and gradient fidelity — the demo-reel palette

notcurses's color model is a **64-bit `ncchannels`** value packing two 32-bit channels (foreground + background), each carrying **24-bit RGB** (≈16.7M colors), a "use terminal default" flag, the alpha bits above, and an alternate **palette-indexed** mode for constrained terminals. Everything higher-level — cells, gradients, fades — is implemented on this one channel API, so color is uniform and granular down to the cell.

### 5.1 Per-cell gradients

- `ncplane_gradient` / `ncplane_gradient2x1` paint a region by interpolating between **corner colors**, giving smooth RGB washes across an area of cells.
- `ncplane_stain` **recolors existing glyphs** with a gradient without touching the characters — you can lay a color sweep over already-drawn text.

- **Technique:** corner-anchored per-cell RGB gradients + glyph-preserving `stain` → **feeling:** the "sunset behind the logo" look. Smooth color transitions are what separate the notcurses maximalist register from flat 16-color ANSI; a gradient-filled title bar reads as *produced*, cinematic, demo-scene-adjacent rather than utilitarian.

### 5.2 Fades and pulses (motion via redraw)

`notcurses_fade` gives `ncplane_fadein`, `ncplane_fadeout`, and `ncplane_pulse`. Fades interpolate the plane's colors over a `timespec` duration, invoking a callback per frame; **they prefer true RGB interpolation and fall back to palette reprogramming** where RGB isn't available (same degrade-don't-fail ethos). `ncplane_pulse` loops fade-in/fade-out to make an element **breathe**.

- **Technique:** timed RGB fade of a whole plane, pulse = looped fade → **feeling:** *aliveness*. A pulsing element throbs like a heartbeat or a "press me" call-to-action; a scene that fades in reads as cinematic curtain-up. This is emotion via *animated color over time*, the terminal's only real motion channel, used lavishly.

### 5.3 Two registers coexist

The color machinery supports both the **maximalist demo-reel personality** (the `notcurses-demo` show — pulsating translucent boxes, color-cycling jungle ruins, a logo "stimulated with energy") **and** restrained information-UI use (a single tasteful gradient on a header, braille plots in one accent color). The library imprints *capability*, not a mandated look — but its defaults and examples pull toward the flamboyant end, and that gravity shows up in software built on it.

---

## 6. The house style — what notcurses makes *easy* (and therefore common)

A library's aesthetic is what it makes easy vs. hard. notcurses makes easy:

1. **Rich imagery** — one `ncvisual_from_file` + blit gets you an auto-degrading picture. So notcurses apps *have logos, art, video*. ncurses apps almost never do. → **house vibe:** illustrated, not just typeset.
2. **Depth** — planes + alpha make shadows/overlays a few calls. → **house vibe:** layered, floating, spatial.
3. **Smooth color** — 24-bit-first with automatic 256/16 fallback; gradients and fades are one call each. → **house vibe:** saturated, cinematic, animated.
4. **Sub-cell precision** — the blitter ladder means charts/sparklines/art get 2×–8× the resolution for free (btop's braille waveforms, gradient meters). → **house vibe:** high-fidelity instrumentation.

What it makes *harder* is the ncurses "grey box of white text" — you'd have to opt out of everything the library is proud of. So the imprinted default of a notcurses app is **maximal**: colored, illustrated, layered, animated. The name itself — *not*-curses — is the aesthetic thesis compressed to two syllables.

### 6.1 API names encode the ambition

Where Lip Gloss borrows CSS flexbox terms and Textual borrows web CSS to *invite* web designers, notcurses borrows the vocabulary of **graphics hardware and the demoscene**: *blitter* (the Amiga/console block-transfer chip), *plane* (framebuffer layers), *channels*, *alpha*, *stain*, *pulse*, *fade*, *mergedown*. The lexicon tells you what the author thinks he's building: not a text UI toolkit but a **graphics library that happens to output to a terminal**. The tools are named `ncplayer`, `ncneofetch`, `nctetris`, `ncls` (an image-showing `ls`) — every one a small proof that the terminal can do a thing you assumed it couldn't.

---

## 7. Describe-the-screen: notcurses at full tilt

Picture the `notcurses-demo` intro on a Kitty terminal. The screen doesn't clear to a prompt — it **fades up** from black, RGB-interpolated over a second. A logo materializes and is "stimulated with energy" (the `xray` demo): color pulses radiate across it, each cell a slightly different hue as a gradient sweeps through. Translucent boxes (`boxes`: "pulsating boxes with a transparent center") stack and breathe, and *through their centers you can see the plane beneath* — not a redrawn approximation, real per-cell alpha compositing. In `jungle`, "low-bandwidth color cycling reveals ancient ruins": the glyphs never move, only their palette rotates, and stone temples emerge from noise the way demoscene plasma effects did on an Amiga. In `view`, a **video plays** — actual decoded frames blitted at octant or pixel resolution, smooth enough that you forget you're looking at characters. In `keller` — "the miracle of sight, and painting with Braille" — an image is rendered entirely in braille dots, a stippled monochrome etching. And in `whiteout`, "a great Nothing slowly robs the world of color": the whole scene desaturates over time, a fade run in reverse, mournful.

Now picture the *same binary* on a bare Linux console with no fonts and no graphics protocol. The video still plays — via framebuffer or half-blocks. The braille etching collapses to sextants or quadrants. The colors quantize to the 256- or 16-color cube. Nothing errors; nothing is missing; it just steps down a rung. That invariance — **spectacular where it can be, tasteful where it must be, broken nowhere** — is the whole aesthetic argument of the library made visible.

---

## 8. Lineage & influences

- **Against ncurses (1993, itself descended from pcurses/curses of the late 1970s–80s):** notcurses is explicitly a *reaction*. ncurses is the library of the minimum — 8/16 colors, byte-oriented, terminfo-cautious. notcurses inverts every axiom: 24-bit, grapheme-cluster-native, capability-optimistic. The author even notes the Apache-2.0 license was chosen partly to avoid the licensing "drama" around ncurses.
- **From outcurses:** Nick Black's own earlier ncurses effects/widgets library — notcurses is the decision to stop building *on* ncurses and start over.
- **The demoscene:** the deepest aesthetic influence — color cycling, plasma, framebuffer tricks, "maximum spectacle on constrained hardware." The framebuffer fallback is a literal demoscene technique.
- **Sixel & the DEC terminals:** reviving 1980s DEC dot-graphics as a first-class modern output path — retro-futurism as engineering.
- **Downstream:** notcurses's sub-cell/braille rendering aesthetic is visible across the modern TUI renaissance (btop's braille waveforms and gradient meters are the same visual language), and it is the reference point whenever anyone asks "how far can terminal graphics actually be pushed?"

---

## 9. Notable quotes

- **The manifesto (README / man page):** "Curses assumes the minimum and allows you (with effort) to step up, whereas Notcurses assumes the maximum and steps down (by itself) when necessary." — the entire aesthetic in one line.
- **The tagline:** "blingful character graphics/TUI library. definitely not curses."
- **The front page:** "Profound changes are imminent in the ancient craft of the Beautiful."
- **The docs on the blitter tradeoff:** braille "doesn't tend to work out very well for images, but (depending on the font) can be very good for plots"; octants "preserve aspect ratio… but can lose color fidelity." — capability stated as a design *tradeoff*, not a spec.
- **Hackaday (third-party):** "This is truly text mode for the 21st century" … it can "pull off silliness like pushing an SNES game's output straight to the console" … "the aesthetic really tickles our love for the demoscene."
- **Demo captions as house voice:** `xray` — "stimulate a logo with energy"; `whiteout` — "a great Nothing slowly robs the world of color"; `outro` — "a message of hope from the library's author." The captions are playful, literary, a little grandiose — the personality of the maximalist.

---

## 10. Techniques → feelings, condensed

| Concrete technique | Feeling it produces |
| --- | --- |
| Blitter ladder (1x1→2x1→2x2→3x2→4x2→braille→pixel) as a resolution dial | one photo served as retro block-art *or* photograph — pick a mood, not fight the grid |
| Half-blocks / quadrants | heritage, crafted low-fi, "videogame pixel" |
| Sextants/octants (U13/U16-gated) | downsampled-photo smoothness; "this is a modern terminal" |
| Braille 2×4 dots | oscilloscope / engineering-instrument readouts and plots |
| `NCBLIT_PIXEL` (Sixel/Kitty/iTerm2/fb) | transgressive delight; a GUI hiding in a prompt |
| Best-blitter default + `NODEGRADE` opt-in | confidence — aim high with no downside, so apps do |
| Framebuffer fallback | demoscene bravado; retro-futurist |
| Z-ordered planes + per-cell alpha (BLEND/TRANSPARENT/HIGHCONTRAST) | depth — drop shadows, translucent modals, floating glass |
| `mergedown` compositing | spatial, dimensional UI vs. papery flat-cell |
| 24-bit-first color w/ auto 256/16 fallback | photographic on new terminals, tasteful on old, code-free |
| `ncplane_gradient` / `stain` | cinematic "sunset behind the logo" washes |
| `ncplane_pulse` / `fadein`/`fadeout` | aliveness — breathing CTAs, curtain-up scenes |
| Demoscene-derived API lexicon (blitter/plane/alpha/stain) | the library announces it's a graphics engine, not a text toolkit |

---

## Sources

- notcurses repo & README — https://github.com/dankamongmen/notcurses
- notcurses front page — https://notcurses.com/
- `notcurses_visual(3)` (blitter ladder, degradation, NCSCALE, NODEGRADE) — https://notcurses.com/notcurses_visual.3.html
- `notcurses_plane(3)` (z-axis, mergedown, standard plane) — https://notcurses.com/notcurses_plane.3.html
- `notcurses_channels(3)` (64-bit channels, RGB, alpha modes, gradient/stain) — https://notcurses.com/notcurses_channels.3.html
- `notcurses_fade(3)` (fadein/fadeout/pulse, RGB-vs-palette) — https://manpages.ubuntu.com/manpages/kinetic/man3/notcurses_fade.3.html
- `notcurses-demo(1)` (demo catalog & captions) — https://notcurses.com/notcurses-demo.1.html
- Nick Black's dankwiki (author philosophy, outcurses lineage, planes) — https://nick-black.com/dankwiki/index.php?title=Notcurses
- Hackaday, "Terminal Magic With Notcurses" (third-party aesthetic read) — https://hackaday.com/2021/05/20/terminal-magic-with-notcurses/
- FOSDEM 2021 talk "Notcurses: blingful TUIs and character graphics" — https://linuxreviews.org/images/1/1e/Notcurses_fosdem_2021.pdf
- Hacker News discussion — https://news.ycombinator.com/item?id=28193032
