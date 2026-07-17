# btop — Aesthetic Dossier

> "A monitor of resources." Officially just a system monitor. In practice: a **sci-fi spaceship engineering console** rendered in a terminal, where CPU load, RAM pressure and network throughput read like the animated instrumentation of a starship's power plant. The whole design thesis is **make numbers feel alive** — turn dead columns of `top` into glowing, waveform-driven telemetry.

- **Repo:** https://github.com/aristocratos/btop (C++23; continuation of `bashtop` → `bpytop` → `btop++`)
- **Author:** Jakob P. Liljenberg / "aristocratos" (Sweden)
- **Lineage:** bashtop (2020, pure Bash) → bpytop (2020, Python) → btop++ (2021, C++). Same visual language ported down three languages — the *look* is the constant, the runtime is the variable.
- **Category siblings:** htop, gtop, glances, ytop/bottom, nvtop, zenith. btop is the flamboyant one.
- **Family:** sci-fi / retro-futurist instrumentation.

---

## 1. The one-sentence identity

Every sibling in the resource-monitor category shows the same numbers. btop's entire personality comes from **refusing to show them as numbers**. It shows them as **motion and color**: sub-cell braille waveforms scrolling right-to-left like an oscilloscope, gradient-filled meter bars that change hue as they fill, box outlines colored per-subsystem, and a red 3D-extruded logo bolted to the top like a nameplate on a control panel. The design intent, stated by the author across all three generations, is a **"game inspired menu system"** — it should feel like the HUD of a video game, not a sysadmin tool.

---

## 2. Color system — color IS the data

btop's most important aesthetic decision: **color is not decoration, it is a second encoding of the value itself.**

### 2.1 The 101-step gradient engine
Every metric defines a color ramp as **three anchor colors** — `_start`, `_mid`, `_end` — in its `.theme` file. At load, `generateGradients()` in `src/btop_theme.cpp` linearly interpolates each ramp into a **101-entry array indexed 0–100**, split into two passes of 50+51 when a mid color is present (start→mid, mid→end):

```
theme[cpu_start]="#77ca9b"   green   (idle)
theme[cpu_mid]  ="#cbc06c"   amber   (busy)
theme[cpu_end]  ="#dc4c4c"   red     (saturated)
```

A CPU meter at 73% load literally draws itself in `gradient["cpu"][73]` — a color mathematically two-thirds of the way from amber toward red. **The hue tells you the load before you read the digits.** This is the green→yellow→red "traffic-light" convention (there is even a theme called `HotPurpleTrafficLight`), but applied continuously rather than in three bands.

- **Technique:** per-metric 3-stop gradient expanded to 101 interpolated steps, indexed by the value's percentage → **feeling:** the machine glows with its own workload; a hot CPU is *visibly* hot (red), a calm one is *visibly* calm (green). Instrumentation that runs a fever.

### 2.2 Per-subsystem box colors — zoning by hue
Each box outline has its own signature color, so the four quadrants of the screen read as **four separate instruments** rather than one undifferentiated wall of text. In the default theme:

```
cpu_box  = #556d59  (muted green)
mem_box  = #6c6c4b  (olive)
net_box  = #5c588d  (slate violet)
proc_box = #805252  (dusty red)
```

- **Technique:** color-coded box borders per subsystem → **feeling:** a control panel divided into labeled bays. Your eye learns "green frame = CPU, violet frame = network" and navigates by color memory, exactly like differently-colored gauge clusters on a dashboard.

### 2.3 The meter is a rainbow, not a bar
`Meter::operator()` (`src/btop_draw.cpp`) does NOT fill a bar in one flat color. It draws a row of `■` (U+25A0) block squares, and **each square is colored by the gradient value at its own position along the bar**. So a full memory meter is itself a left-to-right green→amber→red rainbow; a half-full one shows only the green-to-amber half, the rest filled with the dim `meter_bg` color.

- **Technique:** position-indexed gradient across a `■`-square meter, unfilled remainder in `meter_bg` → **feeling:** the bar is a thermometer with a printed scale — you read severity by *how far into the red* the fill has climbed, not just by length.

### 2.4 Truecolor by default, graceful collapse
Themes are 24-bit hex. `lowcolor`/`t_to_256` degrades every gradient to the 256-color cube; TTY mode collapses to 16 ANSI colors with a dedicated `TTY` theme. The aesthetic is designed **truecolor-first** and *degrades* rather than being built for the lowest common denominator — the opposite of htop's 16-color heritage.

- **Technique:** truecolor gradients with automatic 256/16-color fallbacks → **feeling:** on a modern terminal it looks like a photograph; the smooth hue transitions are what separate btop from the flat-ANSI look of its elders.

### 2.5 The theme shelf as identity
40+ bundled `.theme` files (dracula, tokyo-night, nord, gruvbox, everforest, kanagawa, solarized, matcha, phoenix-night…). Cross-compatible with bpytop/bashtop themes. Two philosophies coexist in the shelf:
- **Semantic themes** (default, dracula) give *different* gradients per metric — network downloads are blue-violet, CPU is green→red — so each instrument has its own palette.
- **Monochrome-ramp themes** (tokyo-night) set *every* metric to the **same** green→amber→red ramp, so the whole panel speaks one unified color language.

- **Technique:** shipping the whole "designer palette" ecosystem (dracula, nord, gruvbox…) as first-class → **feeling:** btop adopts the ricer/dotfiles aesthetic vocabulary; it expects to be *themed* and photographed for r/unixporn, and dresses for it.

---

## 3. Border & box-drawing language

### 3.1 The friendly/severe toggle: rounded vs sharp corners
btop defines **both** corner sets and switches between them (`src/btop_draw.cpp`):

```
sharp:   ┌ ┐ └ ┘   (left_up, right_up, left_down, right_down)
rounded: ╭ ╮ ╰ ╯   (round_left_up, …)
```

`rounded_corners` defaults to **true**. The single boolean is the app's biggest tonal dial:

- **Rounded (`╭─╮`)** → **feeling:** friendly, modern, soft-glowing, "app-like." The default face btop wants to show.
- **Sharp (`┌─┐`)** → **feeling:** severe, industrial, utilitarian, mainframe. Forced ON in TTY mode (rounded glyphs may not exist in console fonts), so it's also the "bare metal / no fonts" face.

Horizontal runs are light box-drawing `─` / `│`; the code path can request a `dotted_v_line` `╎` for softer internal dividers. Titles are inset into the top border with `┐…┌` bracket caps (`title_left`/`title_right`) so the label sits *in* the frame like an engraved panel label rather than floating above it.

- **Technique:** box titles rendered as inset bracketed labels (`┐ cpu ┌`) in bold, with a superscript number (`¹²³`) prefix for keyboard navigation → **feeling:** each box is a labeled equipment bay with a stamped part number.

### 3.2 Divider tees frame sub-zones
`├ ┤ ┬ ┴` (`div_left`/`div_right`/`div_up`/`div_down`) split a box into stacked graphs (e.g. CPU upper/lower graph fields joined by a `▲▼` divider label showing which field feeds which half). The interior is compartmentalized like a schematic.

---

## 4. Motion language — the aliveness aesthetic

This is btop's beating heart and its strongest differentiator. Where htop redraws a static bar, btop **animates continuously**, and the motion is the point.

### 4.1 Sub-cell braille waveforms — the signature trick
The default graph symbol is **braille** (Unicode U+2800–U+28FF). The trick that gives btop its oscilloscope look: **one braille cell is a 2×4 dot matrix, so a single character encodes TWO horizontal data samples at four-plus vertical levels each.**

`Graph::_create` packs `last` (previous sample) into the left dot-column and `data_value` (current sample) into the right dot-column, each quantized to 5 levels (0–4), then indexes a 25-entry symbol table via `result[0]*5 + result[1]`:

```
braille_up = { " ", "⢀", "⢠", "⢰", "⢸",
               "⡀", "⣀", "⣠", "⣰", "⣸",
               "⡄", "⣄", "⣤", "⣴", "⣼",
               "⡆", "⣆", "⣦", "⣶", "⣾",
               "⡇", "⣇", "⣧", "⣷", "⣿" }
```

So a graph that is `N` characters wide actually shows `2N` samples at **8× the vertical resolution** of a plain block bar. The waveform looks smooth, dense, and *high-fidelity* — like a real scope trace, not a chunky ASCII chart.

- **Technique:** two data points per braille cell + 4-row sub-cell height → **feeling:** analog instrument fidelity inside a character grid. The graph reads as a continuous signal, which is exactly the "spaceship telemetry" register btop is aiming for. This single move is what visually separates btop from every block-based monitor.

### 4.2 Three resolution tiers = three moods
`graph_symbol` ∈ `{braille, block, tty}`, settable **per box**:

- **braille** (`⣿⣶⣤⡀`) — max resolution, smooth, sci-fi. Needs a font with braille glyphs (Terminess, Nerd Fonts).
- **block** (`█▙▄▗`) — half resolution, chunkier, retro-8-bit, universally available.
- **tty** (`█▒░`) — three shading levels only, coarse, deliberately *degraded* Linux-console look.

- **Technique:** selectable graph fidelity → **feeling:** a fidelity dial from "modern oscilloscope" (braille) through "retro game" (block) to "1980s mainframe console" (tty). Same data, three eras of computing.

### 4.3 Redraw cadence as heartbeat
`update_ms` defaults to **2000 ms** (recommended ≥2000 "for better sample times"). Each tick the whole scene scrolls one sample left and redraws. Combined with the braille density, the graphs *flow* rather than *step*. `terminal_sync` and `background_update` exist to suppress flicker so the motion reads as smooth telemetry rather than a stuttering repaint.

- **Technique:** steady ~2s scroll-and-redraw with synchronized-output flicker suppression → **feeling:** a living pulse. The panel is never still; it breathes. Stillness in a monitor reads as "dead/frozen," so continuous gentle motion = "system alive and being watched."

### 4.4 Auto-scaling network graph
The network box auto-rescales its Y-axis to fit traffic and prints the current scale as overlaid `graph_text`. A burst of traffic makes the waveform leap and the scale label jump (`⁴ K → M`).

- **Technique:** live auto-ranging axis with the scale printed *on* the graph → **feeling:** a self-adjusting oscilloscope reacting to what it measures; the instrument feels intelligent, responsive, watching.

### 4.5 Superscript sample markers
Values overlaid on graphs use superscript digits `⁰¹²³⁴⁵⁶⁷⁸⁹` (`Symbols::superscript`), and box nav numbers are superscript too — a tiny typographic flourish that reads as "engraved gauge markings."

---

## 5. Typography substitutes (no fonts, only a grid)

btop has only bold/dim/italic and glyph choice to work with, and uses all of them as type:

- **`Fx::b` bold** for box titles and active values → the "headline" weight; makes labels feel stamped/engraved.
- **`Fx::i` italic** for the version string (`v1.x.x` in bold-italic next to the logo) and detail text → the one "hand-signed" flourish in an otherwise mechanical UI.
- **dim / `inactive_fg`** for disabled and background text → recedes, creating depth layers (see §6).
- **Nerd Font / Unicode icons** — arrows `↑↓←→`, enter `↵`, the `▲▼` field-selector, the `■` meter square, battery/temperature glyphs. These substitute for iconography a GUI would draw in pixels.
- **`graph_text`** — a dedicated theme color for text printed *on top of* graphs (uptime, net scale), so overlaid labels stay legible against the moving waveform beneath.

- **Technique:** bold=structure, italic=signature, dim=depth, superscript=gauge-markings → **feeling:** a full typographic hierarchy conjured from four text attributes and clever glyph picks — the terminal equivalent of choosing a display face, a caption face, and an italic accent.

---

## 6. Density & depth — the "dark gradient" trick

btop is **dense** — it fills the screen edge to edge, no wasted margins, four subsystems tiled into a mosaic. Whitespace is scarce and used only to separate zones. But it avoids feeling flat via a **depth gradient in the process list**:

- `proc_gradient` (default **true**) applies a *darkening gradient* down the process list: rows fade from `main_fg` toward `inactive_fg` as they descend, via the synthesized `proc`/`proc_color` gradients in `generateGradients()`.
- `proc_colors` (default **true**) tints each process row's usage columns with the CPU gradient — so a busy process's numbers glow red right there in the list.

- **Technique:** vertical darkening gradient + per-row usage tint in the process list → **feeling:** the list has a light source; the top is "in focus / near," lower rows "fall into shadow." A flat table becomes a 3D readout with atmospheric depth. This is btop's answer to the drop-shadow — depth without a shadow layer.

- **Selection & state color:** selected process = `selected_bg`/`selected_fg` (bright inverse block); paused list = `proc_pause_bg` banner; a *followed* process = `followed_bg`/`followed_fg` + `proc_follow_bg` banner. State is communicated by **background-color washes**, not text — the panel changes mood when you interact with it.

---

## 7. Identity moments

### 7.1 The startup/header logo — a 3D-extruded nameplate
`ansi_banner.utf8` + `banner_gen()` draw **"BTOP"** in heavy box-block letters (`██████╗`) with two devices:
1. **A vertical red gradient** top-to-bottom: 256-color `196 → 160 → 124 → 88 → 52` (bright red fading to blood-dark red). The logo *itself* is a gradient, echoing the whole app's color thesis.
2. **A grey drop-shadow / extrusion:** the `╗╔` corner-shading characters are drawn in a descending grey ramp (`bg_i = 120 − z·12` per row, i.e. `#787878` fading to near-black). This makes the block letters look **3-D extruded with a shadow falling down-right** — a genuine drop-shadow effect built purely from box-corner glyphs and a grey ramp.

Version string appended in **bold italic** immediately after.

- **Technique:** gradient-filled block-letter wordmark + grey-ramp corner-glyph drop shadow → **feeling:** a chunky, confident, slightly retro-arcade nameplate. It announces "this is a *designed* object," not a utility. The red says "power / danger / engine"; the extrusion says "solid, physical, a real panel."

### 7.2 The clock — instrument-panel timestamp
`clock_format` defaults to `"%X"` (locale time), drawn centered in the top border of the CPU box (`update_clock`, strftime-formatted, live). A running clock at the top of a stats panel is pure **mission-control** signaling — the console always tells you "now."

- **Technique:** live strftime clock embedded in the top frame → **feeling:** a NASA/flight-deck timestamp; the panel is on-watch, timestamped, operational.

### 7.3 Boxed zoning as the instrument-panel frame
The whole layout is the identity: four rounded, color-framed, individually-titled boxes tiling the screen, each with its own graph, meters and clock/logo furniture. **Presets** (up to 9, `presets` config) let the user recompose the panel — cpu-only, cpu+proc, a block-symbol variant — like reconfigurable cockpit layouts. Preset 0 is always "all boxes."

- **Technique:** reconfigurable multi-box tiled layout with per-box symbol/visibility presets → **feeling:** a modular control surface you arrange to taste; the app treats its own layout as a customizable dashboard, reinforcing the instrument-panel metaphor.

### 7.4 Error / empty personality
Restrained and diagnostic rather than cute — btop's "voice" is that of a competent instrument, not a mascot. Missing-data states show the box furniture with empty graphs; GPU/battery boxes simply don't appear if absent (`show_battery` in top-right only *if battery present*). Config-validation errors print terse engineer's messages (`"Config value update_ms set too low (<100)."`). No jokes, no persona — the seriousness *is* the sci-fi register. The tool wants to feel like reliable flight instrumentation, and reliable instruments don't crack wise.

---

## 8. Voice & copywriting tone

- README self-description: terse, technical, proud — "Resource monitor that shows usage and stats… C++ version and continuation of bashtop and bpytop."
- Feature list leads with **"Easy to use, with a game inspired menu system."** — the *only* explicitly aesthetic claim, and it's about *feel* (game HUD), not function.
- Config comments are dry engineer-voice (`#* Update time in milliseconds, recommended 2000 ms or above for better sample times for graphs.`).
- The persona lives entirely in the **pixels, never the prose.** btop shows off visually and stays laconic verbally — the inverse of tools that over-explain in text.

---

## 9. What makes it FEEL different from its siblings

| Sibling | Their register | btop's move |
|---|---|---|
| **htop** | flat 16-color bars, static-ish, utilitarian | truecolor gradients + braille waveforms + rounded frames = "designed object" vs "tool" |
| **glances** | information-dense text tables | btop trades some density for *motion and color* — graphs over numbers |
| **bottom/ytop** | also braille graphs, cooler/flatter | btop's per-metric gradients + drop-shadow logo + theme ecosystem = warmer, more theatrical |
| **top** | pure text | btop is the same data reimagined as a game HUD |

The differentiator in one line: **btop encodes every value THREE times — position (length/height), color (gradient hue), and motion (scrolling waveform) — so the panel is legible at a glance, from across a room, as pure shape and color.** Its siblings mostly encode once (text) or twice (text + bar). That triple-encoding, plus the rounded-frame + gradient-logo + theme-shelf packaging, is why btop reads as *"the pretty one"* and gets screenshotted for r/unixporn while htop gets used and forgotten.

---

## 10. Aesthetic decision history (reconstructed from lineage & source)

- **bashtop (2020, Bash):** established the entire visual language — box zoning, braille graphs, gradient meters, "game inspired menu," theme files. Remarkable that this ran in *pure Bash*; the aesthetic was the whole reason the project existed, since the data was trivially available from `/proc`.
- **bpytop (2020, Python):** same look, rewritten in Python for speed/portability; theme format preserved so themes carry across.
- **btop++ (2021, C++):** third rewrite for performance; **theme files remain byte-compatible with bpytop/bashtop** — the clearest possible statement that *the look is the product, the language is an implementation detail.* Three full rewrites and the palette/gradient/braille system survived every one unchanged.
- Ongoing theme PRs (dracula, tokyo-night by community authors named in-file: `# By: Pascal Jaeger`) show the theme shelf is a **community-curated identity surface**, not a fixed brand — btop's "brand" is deliberately re-skinnable.
- Recent additions (`proc_pause_bg`, `followed_fg`, process-following banners) extend the **"state as background-color wash"** language rather than adding text — consistent with the founding thesis that meaning should be carried by color, not words.

---

## 11. Concrete technique → feeling index (quick reference)

| Technique | Feeling produced |
|---|---|
| 101-step per-metric gradient indexed by value % | the machine glows with its workload; hot = red, calm = green |
| `■`-square meter colored per-position along its length | a thermometer with a printed severity scale |
| Color-coded box borders per subsystem | four labeled instrument bays; navigate by color memory |
| Braille cell = 2 samples × 4 sub-rows | analog-scope fidelity inside a character grid |
| braille/block/tty symbol tiers | fidelity dial: modern scope → retro game → mainframe |
| Rounded `╭╮` default vs sharp `┌┐` | friendly/modern vs severe/industrial — one boolean |
| ~2s scroll-and-redraw, flicker-synced | a heartbeat; the panel breathes, so it feels alive |
| Auto-scaling net graph with on-graph scale label | a self-adjusting oscilloscope that reacts to reality |
| Darkening gradient down process list | atmospheric depth; a light source, not a flat table |
| Gradient block-letter logo + grey-ramp drop shadow | a 3-D extruded arcade nameplate; "designed object" |
| Live strftime clock in the top frame | mission-control / flight-deck "on watch" |
| Superscript `¹²³` nav & value markers | engraved gauge markings |
| Bold=structure / italic=signature / dim=depth | a full type hierarchy from four text attributes |
| 40+ designer-palette theme shelf | ricer/dotfiles culture; dresses for the screenshot |

---

## 12. Describe-the-screen (in words)

> You open btop and four soft-cornered boxes snap into place, each rimmed in a different muted color — green, olive, violet, red — like the gauge clusters of a control panel. Top-left, a red block-letter **BTOP** logo sits with a grey shadow falling off its lower-right, a version number in bold italic beside it, and a live clock ticking in the box's top edge. Below, a CPU waveform scrolls leftward every couple of seconds, drawn in dense braille dots that ripple from green through amber toward red as the load climbs; the curve looks like a real oscilloscope trace, not a bar chart. Memory shows as horizontal rows of little squares that fill left-to-right and change hue as they fill, the empty remainder dimmed out. The network box auto-rescales, its waveform leaping when traffic bursts, a tiny `K/M` scale label riding on top. At the bottom, the process list fades gently into shadow toward its lower rows, each busy process's usage numbers tinted the same hot gradient. Nothing is ever quite still. It feels less like reading `top` and more like watching the engine readouts of a ship.

---

## Sources
- btop source (cloned): `src/btop_draw.cpp` (Symbols, braille/block/tty maps, `Graph::_create`, `Meter::operator()`, `banner_gen`), `src/btop_theme.cpp` (`generateGradients`, default theme colors), `src/btop_config.cpp` (defaults: `rounded_corners=true`, `graph_symbol=braille`, `update_ms=2000`, `proc_gradient=true`, presets), `ansi_banner.utf8`
- https://github.com/aristocratos/btop — README (Description, Features "game inspired menu system", Themes)
- https://github.com/aristocratos/btop/tree/main/themes — theme shelf (dracula.theme, tokyo-night.theme, etc.)
- https://github.com/aristocratos/bpytop — Python predecessor (same theme format, "game inspired")
- https://github.com/aristocratos/bashtop — original Bash implementation, origin of the visual language
- https://deepwiki.com/aristocratos/btop4win/3.4-themes-and-customization — theme/customization overview
- https://www.terminal.guide/tools/system-monitor/btop/ — third-party design writeup
