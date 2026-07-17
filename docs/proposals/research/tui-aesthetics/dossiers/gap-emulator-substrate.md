# The Terminal-Emulator Substrate as an Aesthetic Layer

> The canvas a TUI paints INTO — and how it co-authors the vibe before the app draws a single cell.

**Gap-fill dossier.** Mission frame: *aesthetics and vibes, not usability.* Every claim below names a concrete technique AND the feeling it produces. The subject is not the app — it is the **substrate**: the emulator's font renderer, cursor engine, window compositor, shader stack, and graphics protocol. A coding-agent harness draws cells; the emulator decides what a cell *looks like*, whether the cursor *breathes*, whether the background has *depth*, and whether "an image" is even a thing that can exist. This layer is the terminal equivalent of the browser's antialiasing, the OS window shadow, and the display's panel — invisible when it works, and doing an enormous amount of vibe-authorship for free.

---

## 0. The central inversion

In web/desktop, the app owns almost everything: fonts, shadows, corner radii, blur, motion curves, raster images. In a terminal, **the substrate owns the physics and the app owns the content.** The harness cannot draw a drop shadow or a gradient button. But it *inherits*, unbidden, whatever the user's emulator does to every glyph: the antialiasing gamma, the ligature substitution, the cursor's easing curve, the window's frosted blur, a CRT bloom pass. This is a rare condition in UI design — **the medium ships with a personality the author didn't choose and can't fully predict.** Understanding the substrate is understanding the half of the vibe you don't control.

The GPU generation (Alacritty 2016 → kitty → WezTerm → Ghostty 2024) is what made the substrate *expressive* rather than *merely fast*. Once glyphs are textured quads on a GPU, you can run a fragment shader over the whole framebuffer, animate cursor corners with spring physics at 120fps, and composite transparency with real blur. The terminal stopped being a teletype emulator and became a **programmable raster surface that happens to default to a character grid.**

---

## 1. GPU / subpixel font rendering + the programming-font & ligature culture

### 1a. The glyph as the atom of mood
Before color, before layout, the single largest vibe lever in a terminal is **the typeface and how it is rastered.** The same `def process(x):` reads as *institutional/IBM-terminal* in a thin hinted Consolas, *warm/indie* in a rounded Comic Mono, *engineered/premium* in Berkeley Mono, *maximalist/hacker* in a heavily-ligatured Fira Code, and *neutral/honest* in plain unhinted monospace. The harness typically cannot pick the font — but its whitespace rhythm, box-drawing, and symbol density all *land differently* depending on which of these the user runs.

### 1b. Ligatures: crafted vs. literal — the sharpest fork
A ligature fuses a multi-character token (`=>`, `!==`, `->`, `===`, `<=`, `>=`, `|>`, `:=`) into a single designed glyph. Tonsky's Fira Code rationale states the mechanism precisely:

> "Sequences like `->`, `<=`, or `:=` are single logical tokens, even if they take two or three characters on the screen. Your eye spends a non-zero amount of energy to scan, parse and join multiple characters into a single logical one."
> — [Fira Code README](https://github.com/tonsky/FiraCode)

The **aesthetic** payload (independent of the readability claim): ligatures make code look *designed, premium, curated* — the arrow becomes a true arrow, `!==` a struck-through inequality. It signals "someone tuned this environment." The counter-aesthetic is deliberate ligature refusal: **monospace-literal.** Seeing `=` `=` `=` as three discrete equals reads *honest, raw, close-to-the-metal, un-precious* — the vibe of people who distrust the layer between them and the bytes. Neither is "better"; they are two identities. A harness's arrows and operators inherit whichever side the user chose.

- **Fira Code** — rounder shapes, expressive ligatures (`===` → satisfying triple bar); reads *warm, slightly informal, approachable.* ([betterwebtype analysis](https://betterwebtype.com/5-monospaced-fonts-with-coding-ligatures/))
- **JetBrains Mono** — conservative ligatures, geometric, taller x-height; reads *structured, precise, corporate-modern.* ([JetBrains Mono](https://www.jetbrains.com/lp/mono/))
- **Berkeley Mono** — paid, retro-industrial proportions; reads *engineered, premium, "I bought my font."*
- **Iosevka** — narrow, configurable, dense; reads *hacker-maximalist, space-efficient, technical.*
- **Comic Mono / Comic Code** — humanist, playful; reads *disarming, indie, anti-corporate.*

### 1c. Rendering physics as texture
- **Subpixel vs. grayscale antialiasing + hinting/gamma.** Heavier antialiasing → glyphs feel *soft, expensive, retina-native.* Crisp light hinting → *sharp, technical, wiry.* The macOS-vs-Linux font-rendering war is at bottom an argument about which mood is "correct."
- **Font weight & letter-spacing.** A slightly heavier weight or +2% cell width reads *airy, confident, premium*; tight and thin reads *dense, utilitarian, information-first.* The harness controls neither but its dashboards inherit both.
- **Box-drawing crispness.** Whether `│ ─ ╭ ╰ ┃ ═` land as **pixel-perfect hairlines** or slightly fuzzy is a GPU-rasterizer property. Crisp box-drawing is *the single biggest "this looks intentional" signal* a TUI gets for free — rounded corners `╭╮╰╯` on a crisp rasterizer read *soft/modern*; sharp `┌┐└┘` read *engineered/CAD*; heavy `┏┓┗┛` read *bold/brutalist*; doubled `╔╗╚╝` read *retro-DOS.* Same characters, different mood, and the emulator decides how sharp they are.

---

## 2. The cursor as an expressive element

The cursor is the one glyph that moves on its own. It is the terminal's *heartbeat*, and the substrate's cursor engine is pure vibe.

### 2a. Shape → posture
- **Block █** — occupies a full cell; reads *assertive, retro, "I am a terminal," teletype-authentic.*
- **Beam │** — thin i-beam; reads *modern, editor-like, GUI-adjacent, gentle.*
- **Underline _** — low-profile; reads *understated, vintage-DOS, unobtrusive.*

### 2b. Blink → temperament
- **Blinking** — the classic pulse; reads *alive, waiting, slightly impatient, retro-authentic.*
- **No-blink (steady)** — reads *calm, focused, modern-premium.* The "turn off cursor blink" move is a deliberate *sober/serious* signal.
- **Blink easing.** GPU cursors can fade the blink with an easing curve instead of a hard on/off. A **smooth sine-fade blink reads *breathing, liquid, alive*; a hard square-wave blink reads *mechanical, digital, insistent.*** Same period, opposite temperament.

### 2c. Mode-driven shape as state signaling (the vim pattern)
Modal editors drive cursor **shape from state**: block in normal mode, beam in insert, underline in replace. This turns the cursor into a **wordless mode indicator** — you *feel* which mode you're in peripherally before reading any statusline. Aesthetic effect: the environment feels *responsive and stateful*, a machine that changes posture as you change intent. A harness with modes (browsing vs. editing vs. running) can lean on the same channel via DECSCUSR escape codes.

### 2d. Animated cursors — the "alive/liquid/premium" frontier
This is the newest and most emotionally loaded substrate move. Instead of teleporting, the cursor **animates across the screen.**
- **kitty `cursor_trail`** — a trail follows large cursor jumps; "creating a cool visual effect of the cursor zooming around the screen." Tunable via `cursor_trail_decay` (fast/slow fade), `cursor_trail_start_threshold` (min cells before a trail fires), and `cursor_trail_color`. ([kitty.conf](https://sw.kovidgoyal.net/kitty/conf/)) Vibe: *playful, kinetic, "the room has momentum."*
- **Neovide smear cursor** — the flagship. Four cursor corners animate **independently using critically-damped spring physics**; corners are ranked by alignment with travel direction so "leading corners move faster and the trailing corner moves slowest, creating the trail." Optional **particle VFX** (`neovide_cursor_vfx_mode`: railgun, torpedo, pixiedust, sonicboom, ripple, wireframe) trail *particles* behind the cursor, fading with `ease_in_quad`. ([Neovide cursor renderer](https://deepwiki.com/neovide/neovide/3.3-cursor-renderer)) Vibe: *the cursor is a comet.* This is the maximal "alive/liquid" pole — the environment feels physical, reactive, almost wet.
- **smear-cursor.nvim** — brings the smear to *any* terminal by drawing the trail with block/box characters and shading, no GPU cursor required. ([sphamba/smear-cursor.nvim](https://github.com/sphamba/smear-cursor.nvim)) Proof that the "liquid" vibe can be *faked in the glyph grid* when the substrate won't provide it.

The static-vs-animated cursor fork is the cursor version of the ligature fork: **animated = premium/alive/toy-like; static = sober/fast/serious.** Note the tension — cursor trails add *lag* by design (`cursor_trail_size = 1.0` removes the trail for instant jumps), so the "alive" vibe literally trades responsiveness for character.

---

## 3. Window-level chrome — depth, air, and lived-in warmth

Everything so far is inside the grid. The **window compositor** wraps the grid in atmosphere, and this is where the substrate does its most "designed object" work.

### 3a. Background opacity + blur → frosted-glass depth
Setting `background_opacity < 1` plus a **blur** behind the window (kitty `background_blur`, macOS/compositor blur, `background-blurred-radius`) produces the **frosted-glass** look: your wallpaper or the window behind bleeds through, softened. Vibe: *depth, atmosphere, lived-in warmth* — the terminal stops being an opaque black rectangle and becomes a **pane of tinted glass floating over a desktop.** This is the signature move of the r/unixporn community — the translucent, blurred terminal over a moody wallpaper is *the* screenshot archetype. ([OMG!Ubuntu on blur](https://www.omgubuntu.co.uk/2022/03/blur-me-gnome-extension-translucent-windows)) The mood ranges from *cozy/ambient* (warm wallpaper, heavy blur) to *cyberpunk/neon* (dark wallpaper, sharp neon text bleeding through). Crucial caveat for a harness: **transparency destroys contrast control.** Text legibility now depends on what's behind the window — a vibe the harness can neither see nor manage.

### 3b. Padding / margins → "airy" vs. "packed"
`window_padding` (WezTerm) / `window-padding-x/y` (Ghostty) inserts pixels between the outermost cells and the window edge:
```lua
config.window_padding = { left = 16, right = 16, top = 16, bottom = 0 }
```
([WezTerm window_padding](https://wezterm.org/config/lua/config/window_padding.html)) Generous padding reads *airy, expensive, gallery-like* — the content has room to breathe, signaling "this is worth space." Zero padding reads *dense, utilitarian, terminal-brutalist* — every pixel is data. This is the terminal's version of web whitespace/margin: **the cheapest luxury signal there is, and it lives entirely in the substrate.** A harness cannot add outer padding but can *mirror* the feeling with internal gutters.

### 3c. Rounded window corners → soft/modern vs. sharp/technical
WezTerm defaults to rounded corners on macOS (`MACOS_FORCE_SQUARE_CORNERS` to override). ([window_decorations](https://wezterm.org/config/lua/config/window_decorations.html)) Rounded outer corners read *friendly, modern, native-macOS*; forced square corners read *technical, tiling-WM, no-nonsense.* The corner radius of the *window* rhymes (or clashes) with the corner style of the app's *box-drawing* — a harness using `╭╮` rounded panels inside a rounded window feels *coherently soft*; sharp `┌┐` panels inside a rounded window feels *deliberately engineered against the frame.*

### 3d. Inactive-pane dimming → depth-of-field / focus
WezTerm de-saturates and dims inactive panes via an HSB multiplier: `inactive_pane_hsb = { saturation = 0.9, brightness = 0.8 }` (aggressive: `0.7 / 0.5`). ([Colors & Appearance](https://wezterm.org/config/appearance.html)) Vibe: **depth-of-field** — the active pane pops forward, the rest recede into soft focus, like a photographic bokeh. It makes a multiplexed workspace feel *cinematic and attention-directed* rather than a flat wall of equal rectangles. The harness can imitate this *inside* one pane (dim inactive regions) but the emulator does it *between* panes for free.

---

## 4. Retro / CRT & custom shaders — phosphor-warm, used-future, cassette-futurist

GPU emulators expose a **custom fragment shader** stage (`custom_shader` in kitty/Ghostty) that runs over the entire rendered framebuffer every frame. This is the substrate's most theatrical capability — it can retexture the *entire terminal* into another era.

### 4a. The CRT stack and what each pass *feels* like
The canonical retro shaders (Ghostty shader galleries, cool-retro-term's presets) compose several effects, each with a distinct emotional payload:
- **Scanlines** (dark horizontal gaps between rows) → *analog, video-signal, "this is a screen not a page," nostalgic.*
- **Phosphor glow / bloom** (bright text bleeds light into neighbors) → *warm, radiant, the text emits rather than prints.* This is the emotional core. As the cassette-futurism sources put it, "the phosphor glow — the central visual effect of the style — only exists in relation to a dark ground"; on a light background "the entire depth of field that the style depends on collapses." ([CARI: Cassette Futurism](https://cari.institute/aesthetics/cassette-futurism)) The glow *requires darkness to exist* — which is why every CRT terminal is dark-mode.
- **Screen curvature / barrel distortion** (the frame bulges) → *physical object, convex glass, tactile, "there is a tube behind this."*
- **Chromatic aberration / RGB split** (color fringing at edges) → *analog imperfection, signal-degraded, glitch-adjacent, VHS.*
- **Flicker / noise / jitter** → *unstable, alive, haunted, low-fi.*
- **Amber / green monochrome phosphor** → the era selector: amber = *warm, IBM/DEC-terminal, cozy-retro*; green = *matrix/hacker, colder, military.*

thijskok's shader pack ships exactly this palette — "Amber, Green & Blue Phosphor Glow, Soft Background Glow, Subtle Scanlines & Flicker" — explicitly to make the terminal "feel cozy," "a soft, glowing, vintage vibe." ([Retro Vibes: CRT Glow for Ghostty](https://thijskok.nl/retro-vibes-crt-glow-for-your-ghostty-terminal/))

### 4b. The lineage — cool-retro-term and cassette futurism
The reference implementation is **cool-retro-term** (2015), which turned "old CRT" into a toggleable aesthetic with presets (Default Amber, Vintage, Futuristic, IBM DOS, Apple ][). It codified the vocabulary the Ghostty/kitty shader packs now inherit. The whole family lives inside the **cassette-futurism** aesthetic: "a future conjured from CRT monitors glowing amber in the dark... that glorious sweet spot where high-tech dreams meet low-fi reality." ([Cassette Futurism, Aesthetics Wiki](https://aesthetics.fandom.com/wiki/Cassette_Futurism)) The vibe is not "old" — it is **"used future"**: technology that looks lived-in, worn, and warm rather than sterile Apple-white. It signals romanticism, craft, and a rejection of glassy minimalism.

### 4c. Shader stacking as maximalism
Because shaders compose, users stack them — 0xhckr's gallery shows combos like `drunkard + retro-terminal + bloom` and `glitchy + bettercrt + water + bloom`. ([0xhckr/ghostty-shaders](https://github.com/0xhckr/ghostty-shaders)) The available names alone map the mood space: `matrix-hallway`, `starfield`, `underwater`, `smoke-and-ghost`, `inside-the-matrix`, `fireworks`, `glow-rgbsplit-twitchy`. Vibe of stacking: *maximalist, playful, "my terminal is a demoscene toy."* The opposite pole — no shader, flat matte background — reads *serious, fast, professional, "I have work to do."* The shader stage is the purest expression of the identity fork: **terminal-as-theater vs. terminal-as-tool.**

> A harness cannot know whether it is being painted through a bloom-and-scanline CRT shader or onto a flat matte surface. Bold bright colors that look punchy on matte can **bloom into illegible halos** under a glow shader — the substrate can silently rewrite the app's contrast.

---

## 5. Graphics protocols — escaping the glyph grid

The rising frontier: protocols that let a TUI blit **real pixels** into the cell grid, breaking the fundamental constraint that a terminal shows only characters.

### 5a. The three protocols and their lineage
- **Sixel** — the ancestor, from 1980s DEC terminals. Six vertical pixels per band, palette-limited. Reads *retro, low-res, "miniature preview," charmingly crunchy.* Broad but crusty support. ([Akmatori: Terminal Graphics Protocols](https://akmatori.com/blog/terminal-graphics-protocols))
- **iTerm2 inline images (OSC 1337)** — true-color, file-based, custom dimensions. Reads *clean, photographic, macOS-native.*
- **kitty graphics protocol** — the modern standard: true-color, GPU-composited, z-indexed, animatable, placement-controlled. Adopted by kitty, Ghostty, Konsole, WezTerm, wayst, and more. ([kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)) Reads *crisp, high-fidelity, "the terminal is a real display."*

### 5b. What pixels do to the vibe
The moment a TUI shows a real image — a chart, an image thumbnail, a rendered diff, a QR code, a logo, a syntax-highlighted screenshot — it crosses a line from **tool to app.** Yazi (file manager) rendering true image previews, `timg`/`chafa` showing photos, ratatui-image widgets, `presenterm` slides with embedded diagrams: each reads *graphics-forward, premium, "this doesn't feel like a terminal anymore."* The vibe is **escape velocity** — the app has slipped the glyph grid and is doing things the medium "shouldn't" be able to do, which reads as *impressive, modern, boundary-pushing.*

The fallback ladder itself is an aesthetic tell: **kitty/iTerm pixels → sixel → Unicode half-blocks `▀▄` → ASCII art.** Each rung down reads progressively more *retro/constrained/honest*. A harness that degrades from a crisp image to half-block mosaic to a box of text is *showing its respect for the substrate it landed on* — and the half-block tier has its own beloved *lo-fi/mosaic* charm (the `chafa`/`▀` look).

### 5c. The catch for an agent harness
Graphics protocol support is **wildly non-uniform** and often un-detectable in advance. Claude Code's own issue tracker carries live feature requests for terminal graphics support ([anthropics/claude-code #2266](https://github.com/anthropics/claude-code/issues/2266), [#54546](https://github.com/anthropics/claude-code/issues/54546)) — evidence that even flagship agent harnesses currently treat pixels as aspirational, not assumable. A harness that *hard-requires* pixels excludes Alacritty (no image protocol at all, by design — Alacritty's identity is *minimal, fast, no-frills, "a grid and nothing else"*) and tmux-wrapped sessions.

---

## 6. Vibe words (the substrate's palette of feelings)

`phosphor-warm` · `frosted-glass depth` · `liquid/alive` · `crafted/premium` · `honest/raw` · `airy/expensive` · `used-future` · `graphics-forward` · `cassette-futurist` · `terminal-brutalist`

---

## 7. Technique → feeling table

| Substrate technique | Concrete move | Feeling it produces |
| --- | --- | --- |
| Programming ligatures ON | `=>` `!==` `->` fuse into designed glyphs | crafted, premium, curated, "someone tuned this" |
| Ligatures OFF (monospace-literal) | three discrete `=` chars | honest, raw, close-to-the-metal, un-precious |
| Heavy grayscale AA + high gamma | soft, filled glyph edges | expensive, retina-native, gentle |
| Crisp light hinting | sharp hairline strokes | technical, wiry, sober |
| Rounded box-drawing `╭╮╰╯` on crisp rasterizer | soft panel corners | modern, friendly, approachable |
| Heavy box-drawing `┏┓┗┛` | bold hairlines | brutalist, confident, structural |
| Block cursor █ | full-cell solid | assertive, retro, teletype-authentic |
| Beam cursor │ | thin i-beam | modern, editor-like, gentle |
| Steady (no-blink) cursor | constant, no pulse | calm, focused, serious |
| Sine-eased blink | soft fade in/out | breathing, alive, liquid |
| Hard square-wave blink | instant on/off | mechanical, digital, insistent |
| Mode-driven cursor shape (vim) | block↔beam↔underline by mode | responsive, stateful, wordless signaling |
| kitty cursor_trail | trail follows big jumps | playful, kinetic, momentum |
| Neovide smear + particle VFX | spring-physics corners + comet particles | the cursor is a comet — physical, wet, premium |
| Background opacity + blur | wallpaper bleeds through, softened | frosted-glass depth, cozy/ambient, lived-in |
| Generous window padding | 16px gutter around cells | airy, expensive, gallery-like |
| Zero padding | cells touch the frame | dense, utilitarian, terminal-brutalist |
| Rounded window corners | soft outer radius | friendly, modern, native |
| Inactive-pane dimming (HSB) | non-focused panes desaturate/dim | cinematic depth-of-field, attention-directed |
| Scanline shader | dark gaps between rows | analog, video-signal, nostalgic |
| Phosphor glow / bloom shader | text bleeds light | warm, radiant, text-emits-not-prints |
| Screen curvature shader | frame bulges convex | physical object, tactile, tube-behind-glass |
| Chromatic aberration shader | RGB fringing at edges | signal-degraded, glitch, VHS |
| Amber monochrome phosphor | warm single-hue text on black | cozy-retro, IBM/DEC terminal |
| Green monochrome phosphor | cold single-hue text on black | matrix, hacker, military |
| No shader, flat matte bg | pure grid, no post-processing | serious, fast, professional, tool-not-toy |
| kitty/iTerm graphics protocol | real true-color pixels in-grid | graphics-forward, app-not-tool, escape velocity |
| Sixel fallback | palette-limited banded pixels | retro, crunchy, charming-miniature |
| Unicode half-block `▀▄` fallback | mosaic from block glyphs | lo-fi, honest, respects the constraint |

---

## 8. What a coding-agent harness CAN and CANNOT assume about its substrate

**Cannot assume (delegate to the emulator, design defensively):**
- **The font, its weight, its ligatures.** The same operators render as crafted-or-literal depending entirely on the user. Do not rely on any specific ligature; do not assume any symbol renders at a specific width beyond the Unicode East-Asian-width contract.
- **True contrast.** Transparency/blur and CRT bloom shaders can silently rewrite the app's colors — bright bold colors may halo into illegibility under glow, and any color's legibility over a translucent background is unknowable. Prefer colors that survive both matte and glow; never depend on a specific background *color* being visible.
- **Cursor behavior.** Shape, blink, easing, and trail are the user's. The harness's DECSCUSR shape requests may be honored, ignored, or overridden (see [Helix vs kitty cursor_trail conflict](https://github.com/helix-editor/helix/issues/12642)).
- **Real pixels.** Graphics protocols are non-uniform and often undetectable ahead of time; Alacritty and many tmux sessions have none. Pixels are a *progressive enhancement*, never a floor.
- **Window chrome.** Padding, corners, opacity, pane-dimming all belong to the emulator and cannot be read or set from inside the grid.

**Can assume (the floor to design to):**
- A monospace character grid with stable cell advance (respecting CJK/emoji double-width via a proper width table).
- 16 named ANSI colors, almost always 256-color, usually truecolor — but the *rendered* result is theme-and-shader-dependent, so design in **semantic roles** (accent/muted/danger), not hex.
- Box-drawing and a wide Unicode glyph repertoire (with graceful fallback for terminals that tofu rarer glyphs).
- Cursor positioning, and *requesting* (not guaranteeing) a cursor shape via DECSCUSR.
- Redraw/diff as the only motion primitive the app fully controls.

**Effects the harness should OWN (draw itself, inside the grid, substrate-independent):**
- Internal padding/gutters and whitespace rhythm (mirror the "airy" luxury signal the emulator provides outward).
- Box-drawing panel style and corner character choice (own the "soft vs. engineered" fork rather than inheriting it from the window frame).
- Dimming/focus *within a pane* (own the depth-of-field the emulator only provides *between* panes).
- Motion via redraw — spinners, progress, streaming reveal, smear-in-glyphs à la smear-cursor.nvim when it wants "alive" without a GPU cursor.
- Semantic color roles and a coherent theme that degrades gracefully across 16/256/truecolor.

**Effects the harness should DELEGATE (let the emulator provide, and get out of the way):**
- CRT/retro shading, bloom, scanlines — never bake fake scanlines into content; let the user's shader own the era.
- Background transparency/blur and the frosted-glass depth — never assume it, never fight it; keep foreground contrast self-sufficient.
- Ligatures and font rasterization — emit plain ASCII operators and let the substrate fuse them or not.
- Cursor animation/trail — let the emulator's cursor engine own "alive"; only fake it in-grid when the app *needs* the vibe and the substrate won't give it.
- Real image display — use the graphics protocol when present, degrade down the ladder (kitty → sixel → half-block → ASCII) when absent.

**The synthesis:** the substrate co-authors roughly half the vibe — the *texture* (font, glyph raster, glow), the *atmosphere* (blur, padding, corners), and the *life* (cursor motion). The harness authors the other half — the *composition* (layout, rhythm, color roles, box style) and the *content-level motion* (redraw). The winning posture is **not to fight the substrate for control it owns, but to compose so well within the guaranteed grid that the app reads as intentional under a matte flat terminal, and reads as *gorgeous* when the user's phosphor-glow, frosted-glass, comet-cursor substrate paints it in.** Design for the floor; be a gift on the ceiling.

---

## Sources

- [Fira Code README (tonsky) — ligature rationale](https://github.com/tonsky/FiraCode)
- [5 monospaced fonts with coding ligatures — Better Web Type](https://betterwebtype.com/5-monospaced-fonts-with-coding-ligatures/)
- [JetBrains Mono](https://www.jetbrains.com/lp/mono/)
- [kitty.conf — cursor_trail, cursor_trail_decay, background_blur](https://sw.kovidgoyal.net/kitty/conf/)
- [Neovide cursor renderer — spring physics, smear, VFX](https://deepwiki.com/neovide/neovide/3.3-cursor-renderer)
- [sphamba/smear-cursor.nvim](https://github.com/sphamba/smear-cursor.nvim)
- [Helix overrides kitty cursor_trail (conflict)](https://github.com/helix-editor/helix/issues/12642)
- [WezTerm — window_padding](https://wezterm.org/config/lua/config/window_padding.html)
- [WezTerm — window_decorations / rounded corners](https://wezterm.org/config/lua/config/window_decorations.html)
- [WezTerm — Colors & Appearance / inactive_pane_hsb](https://wezterm.org/config/appearance.html)
- [thijskok — Retro Vibes: CRT Glow for Ghostty](https://thijskok.nl/retro-vibes-crt-glow-for-your-ghostty-terminal/)
- [Fun with Ghostty Shaders — catskull.net](https://catskull.net/fun-with-ghostty-shaders.html)
- [0xhckr/ghostty-shaders gallery](https://github.com/0xhckr/ghostty-shaders)
- [Cassette Futurism — CARI Institute](https://cari.institute/aesthetics/cassette-futurism)
- [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Terminal Graphics Protocols: Kitty, Sixel, iTerm2 — Akmatori](https://akmatori.com/blog/terminal-graphics-protocols)
- [Claude Code — terminal graphics protocol feature request #2266](https://github.com/anthropics/claude-code/issues/2266)
