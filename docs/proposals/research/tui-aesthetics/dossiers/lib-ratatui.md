# Dossier: ratatui (Rust)

> "Cook up delicious terminal user interfaces." — ratatui.rs homepage

- **Repo:** https://github.com/ratatui/ratatui
- **Docs:** https://ratatui.rs · https://docs.rs/ratatui
- **Version examined:** 0.30.2 (source shallow-cloned; glyphs read directly from `ratatui-core/src/symbols/`)
- **Lineage:** hard fork of `tui-rs` (Florian Dehau, 2016), community-revived as *ratatui* in 2023; mascot is a chef rat, theme is cheese/cooking.
- **Paradigm:** immediate-mode — the whole UI is redrawn from application state every frame; no retained widget tree.

---

## 1. The thesis: everything lives in a Block

ratatui has one dominant compositional gesture, and it is the **`Block`**. The docs call it "a foundational widget that creates visual containers by drawing borders around an area... a wrapper or frame for other widgets, providing structure and visual separation." Almost every other widget (`List`, `Table`, `Paragraph`, `Chart`, `Gauge`, `Sparkline`) accepts an optional `.block(...)`. The result is the single most recognizable fact about the ratatui aesthetic:

**A ratatui screen reads as a wall of labeled rectangular instrument panels.** Box-drawing borders segment the terminal into a dashboard of framed cells, each with a title tucked into its top edge. This is the "instrument-panel / cockpit / engineering-console" vibe — orderly, gridded, serious, every region accounted for and captioned. Where a web app would use whitespace, drop shadows, and card elevation to separate regions, ratatui uses **the border line as the universal separator**. The frame *is* the design language.

Describe the canonical screen: a top strip that is one bordered block holding tab labels; a left column that is a bordered `List`; a large right pane that is a bordered `Paragraph` or `Chart`; a one-line bottom `Block` (often borderless) holding keybind hints in dim text. Titles sit *in* the border stroke, not above it — `┌ Files ─────┐` — so the label costs zero extra vertical rows. Nothing floats; everything is enclosed. The feeling is *contained competence*.

---

## 2. Border weight as a seriousness dial

The exact glyphs (from `symbols/line.rs`, verified against the crate's own render tests) are the aesthetic core. Each border *type* is a full box-drawing `Set` — vertical, horizontal, four corners, four tees, cross — so it composes cleanly at junctions.

| `BorderType` | Corners render as | Feeling it produces |
|---|---|---|
| **`Plain`** (default) | `┌─┐` `│ │` `└─┘` | Neutral, technical, "just a frame." The unmarked default — the baseline engineering look. |
| **`Rounded`** | `╭─╮` `│ │` `╰─╯` | Softer, friendlier, modern. The single most common *deliberate* choice in tasteful ratatui apps; rounding the corners is the terminal equivalent of `border-radius: 6px` — it signals care and contemporary polish without adding color. |
| **`Double`** | `╔═╗` `║ ║` `╚═╝` | Retro, DOS/BIOS-era, "system dialog." Reads as heavier, more official, slightly nostalgic — used for modals and alerts to say *this matters, stop*. |
| **`Thick`** | `┏━┓` `┃ ┃` `┗━┛` | Bold, loud, high-emphasis. Draws the eye to the *active/focused* panel. Common idiom: normal panels use `Plain`, the focused one switches to `Thick` — border weight becomes the focus indicator with zero color cost. |

Beyond the four headliners, `symbols/border.rs` ships a surprising deep bench that most users never touch but which defines the ceiling of the aesthetic:

- **Dashed families** — `LIGHT_DOUBLE_DASHED` `┌╌╌╌┐`, `LIGHT_TRIPLE_DASHED` `┌┄┄┄┐`, `LIGHT_QUADRUPLE_DASHED` `┌┈┈┈┐` plus heavy variants (`┅ ┉ ╍`). Dashes read as *provisional, tentative, in-progress* — a lighter commitment than a solid rule. Rarely used, which is itself telling: ratatui's house taste favors the solid stroke.
- **`QUADRANT_OUTSIDE` / `QUADRANT_INSIDE`** — borders drawn with quadrant blocks (`▛▀▜ ▌ ▐ ▙▄▟`) that sit *half a cell outside or inside* the rect, giving a chunky, pixel-inflated frame. Vibe: bold, blocky, almost pixel-art.
- **McGugan-box sets** — `ONE_EIGHTH_WIDE` (`▁▁▁` top, `▏ ▕` sides, `▔▔▔` bottom) and `ONE_EIGHTH_TALL`. Named after Will McGugan (Textual/Rich author): use the *thinnest possible* one-eighth blocks pushed to cell edges so the border is a hairline that barely intrudes. Vibe: minimal, delicate, almost frameless — a whisper of enclosure.
- **`PROPORTIONAL_WIDE` / `PROPORTIONAL_TALL`** and **`FULL`/solid** — half- and full-block borders (`▄▄▄` / `████`) engineered so horizontal and vertical strokes *look* equally thick (correcting for the ~2:1 cell aspect ratio). Vibe: solid, filled, poster-like heaviness.

The design lesson encoded here: **line weight is ratatui's primary non-color emphasis channel.** Because color is used sparingly (see §4), the *stroke* carries the hierarchy — thin/dashed = incidental, plain = default, thick/double = attention, solid = maximal.

`border_set` lets you supply an arbitrary `border::Set`, and `merge_borders` (with `MergeStrategy`) makes adjacent blocks' borders *fuse at shared edges* into clean tees and crosses instead of doubling up — the feature that keeps a dense multi-panel dashboard from looking like a pile of overlapping boxes. That merge behavior is what makes tiled ratatui layouts look *drafted* rather than *stacked*.

---

## 3. Title-in-the-border: the caption grammar

Titles are `Line`s embedded in the top or bottom border stroke. The API is deliberately expressive:

- `.title(...)` / `.title_top(...)` / `.title_bottom(...)` — position on the frame.
- Alignment via the `Line` itself: `Line::from("Title").left_aligned()/.centered()/.right_aligned()`, or a block-wide default via `.title_alignment(...)`.
- **Multiple titles coexist** and are auto-spaced; you can put a left-aligned name in the top-left *and* a right-aligned status in the top-right of the same border.
- `.title_style(...)` layers a style on titles *independently* of `.border_style(...)`.

This produces a very specific and beloved idiom: **panel identity in the top-left corner, live status in the top-right, help hint in the bottom border.**

```
┌ Processes ──────────────────── CPU 42% ┐
│ firefox        18%                      │
│ ratatui         2%                      │
└──────────────────── [q]uit [/]filter ───┘
```

The bottom-border title as a keybind legend is a near-universal ratatui convention — it turns the frame into a self-documenting affordance strip. Because `title_style` and `border_style` are separate layers, a common move is a **dim gray border with a bold-white or accent-colored title**, so the label pops while the frame recedes to structure. The frame is furniture; the title is signage.

---

## 4. Color: restraint as the house style

ratatui **ships no default theme.** `Style::default()` is empty — inherit the terminal's own colors. This is the single most consequential aesthetic decision in the library, and it is a decision *by omission*: because the framework hands you a blank, monochrome canvas and makes you type a color to get one, the path of least resistance is **the terminal's default foreground on default background, with color added only as a deliberate signal.**

The `Color` enum (`style/color.rs`) tiers gracefully:
- 16 **named** ANSI colors (`Black`, `Red`, … `White`, plus `Light*` and `DarkGray`/`Gray`) — these *respect the user's terminal theme*, so a red is "your terminal's red." Using named colors is the polite, theme-respecting choice and gives ratatui apps their chameleon quality.
- `Indexed(u8)` — 256-color palette.
- `Rgb(u8,u8,u8)` — truecolor, for apps that want to override the terminal and own their look.
- `Reset` — explicitly fall back to terminal default.

The emergent look is the famous **"monochrome-plus-one-accent" Rust-tool palette**: default-foreground text and borders everywhere, with a *single* accent color (very often cyan, sometimes green or magenta) marking the selected item, the focused border, or the active tab. The showcase page confirms it: apps "often employ restrained palettes, typically using one accent color against neutral backgrounds for clarity and reduced eye strain." This restraint reads as *engineering-serious, calm, trustworthy* — the opposite of a candy-colored dashboard. Color is treated as *information*, not decoration; when a ratatui app suddenly shows red, you believe it.

For teams that *do* want a curated modern palette, ratatui ships `style::palette::tailwind` (22 Tailwind CSS ramps, 11 shades each, 50→950) and `style::palette::material`. The docstring is revealing — it includes Black and White in every ramp "to avoid being affected by any terminal theme that might be in use," i.e. the palettes exist precisely to let you *escape* the chameleon default and commit to an owned, consistent, web-inspired look. The demo2 showcase app leans on tailwind for its gradient-y modern flavor. That ratatui borrows *Tailwind's* ramp naming is itself an aesthetic tell: it imports the web's most legible color-scale vocabulary wholesale.

---

## 5. Stylize: the fluent shorthand that makes styling cheap

The `Stylize` trait (`style/stylize.rs`) gives every stylable thing a chainable, adjective-like API:

```rust
"ERROR".red().bold().on_black()
Line::from("hint").dim().italic()
Block::bordered().title("Logs".cyan())
```

`.red()`, `.on_blue()`, `.bold()`, `.dim()`, `.italic()`, `.underlined()`, `.reversed()`, `.slow_blink()`, `.crossed_out()` — the color adjectives read like English, and background colors are the `on_*` prefix (a naming choice lifted from Rich/the CSS mental model). The `Modifier` bitflags (`BOLD DIM ITALIC UNDERLINED SLOW_BLINK RAPID_BLINK REVERSED HIDDEN CROSSED_OUT`) map directly onto the SGR text attributes terminals have always had.

Aesthetically this matters because **what a library makes ergonomic becomes its house style.** `.dim()` is one word, so ratatui apps are full of dimmed secondary text (help hints, inactive tabs, timestamps) — *dim* becomes the de-facto "muted/secondary" tier, the terminal's answer to gray-500 body text. `.bold()` is one word, so titles and selected rows are bold. `.reversed()` (swap fg/bg) is one word, so the *selection highlight* across `List`/`Table` is overwhelmingly rendered as an inverted bar rather than a colored background — that inverted cursor-row is a signature ratatui texture. The fluent trait quietly steers thousands of apps toward the same three-tier text hierarchy: **bold (primary) / normal (content) / dim (chrome).**

---

## 6. The symbols module as texture vocabulary

For data-viz, ratatui's aesthetic knob is **glyph density**, exposed through `symbols/` and the `Marker` enum. This is where "delicate/precise" vs "bold/chunky" is literally a one-line choice.

**Marker resolution ladder** (`symbols/marker.rs`), lowest to highest pseudo-pixel density:
- `Dot` (`•`) — 1 point/cell. Sparse, plotted, *scientific-scatter* feel. The default.
- `Block` (`█`) — 1 solid point/cell. Chunky, bold, unmistakable.
- `Bar` (`▄`) — half-block point. Weighty but grounded.
- `Braille` (`⠓ ⣇ ⣿`) — 2×4 dots/cell, an 8× resolution boost. The signature ratatui line-chart texture: **fine, delicate, precise, almost anti-aliased** — this is what makes `bottom`'s CPU graphs and `trippy`'s plots look smooth. The braille table is a full 256-glyph lookup indexed by bit pattern.
- `HalfBlock` (`█▄▀`) — square-ish 2× grid, good for heat/pixel art.
- `Quadrant` (2×2), `Sextant` (2×3), `Octant` (2×4) — "densely packed and regularly spaced pseudo-pixels *without visible bands between cells*." Octant matches braille's resolution but with no inter-dot gaps, so it reads as **solid contiguous fill** rather than dotted — a subtly different, more poster-like texture (newer Unicode, less widely supported, so a bolder bet).

**Bar/gauge fills** come in eighths. `symbols/bar.rs` gives vertical eighths `▁▂▃▄▅▆▇█` (used by `Sparkline`, `BarChart`) and `symbols/block.rs` gives horizontal eighths `▏▎▍▌▋▊▉█` (used by `Gauge`, progress bars). Because fills advance in *eighth-cell* increments, a ratatui gauge animates **smoothly** rather than jumping a whole character at a time — the sub-cell resolution is why progress bars feel liquid and precise instead of blocky. `THREE_LEVELS` vs `NINE_LEVELS` sets let you trade that smoothness for a coarser, chunkier retro look.

**Shade ramp** (`symbols/shade.rs`): `░ ▒ ▓ █` (light→medium→dark→full) plus `DOT` (`•`). These drive the `Shadow` effect and any dithered fill; the shade characters carry a distinctly *retro/CRT/ANSI-art* connotation.

The takeaway: a ratatui chart's *personality* is set almost entirely by its `Marker`. Braille = a lab instrument. Block = an arcade readout. Same data, opposite mood, one enum away.

---

## 7. Shadows and the McGugan techniques: depth without pixels

Newer ratatui (0.30) adds `Block::shadow(...)` — a `Shadow` rendered in an offset area *behind* the block, with presets `overlay` (style only), `block` (full `█` fill), and `light/medium/dark_shade` (`░▒▓` fill), plus a `Dimmed` cell-effect that darkens whatever's under it. The docstring shows a popup with a `▒` drop-shadow to its lower-right:

```
┌Popup─────┐
│content   │▒
└──────────┘▒
  ▒▒▒▒▒▒▒▒▒▒▒
```

This is the terminal reaching for the *one* thing the medium supposedly can't do — **elevation/depth** — and getting it via a shaded offset. A shadowed modal reads as *floating above* the dashboard; it's the closest the character grid comes to a CSS `box-shadow`, and it lands the same "this is a layer on top" message. The named borrow from **Will McGugan** (Rich/Textual) for the one-eighth "box" technique is an explicit acknowledgement of shared cross-library craft: sub-cell block characters used to fake sub-character-grid precision.

---

## 8. Layout as rhythm: constraint-solved whitespace

Positioning is a **constraint solver** (Cassowary), and the constraint *names* are pure CSS-flexbox vocabulary — a deliberate signal that ratatui wants you to think in web-layout terms:

- `Constraint::Length(n)` — fixed cells.
- `Constraint::Percentage(p)` / `Constraint::Ratio(a,b)` — relative.
- `Constraint::Min(n)` / `Constraint::Max(n)` — bounds.
- `Constraint::Fill(weight)` — proportionally absorb leftover space (like `flex-grow`).

And `Flex` modes name themselves after flexbox exactly: `Start`, `End`, `Center`, `SpaceBetween`, `SpaceAround` (plus `Legacy`, which dumps slack into the last element — the pre-Flex behavior kept for back-compat). `Layout::spacing(n)` inserts uniform gaps between children "without manual padding calculations."

Aesthetically, the constraint engine is what produces ratatui's **calm, grid-locked, aligned** feel. Because you declare *relationships* ("this pane fills, that one is 30%, leave 1 cell between them") rather than absolute coordinates, panels stay aligned and proportional across every terminal size — the layout never looks hand-jammed. When constraints can't all be satisfied the solver returns a close approximation rather than failing, so resizing *degrades gracefully* instead of shattering. The presence of `Flex::Center`/`SpaceAround` and `spacing()` makes *breathing room* a first-class, one-argument choice — which is why well-made ratatui apps have that airy, evenly-gapped composure, and why dense apps that skip it read as deliberately utilitarian. `Padding` (inside a block) vs `spacing`/`margin` (between layout children) cleanly separates *inner* from *outer* whitespace, mirroring the CSS box model.

---

## 9. What the API makes easy = what the ecosystem looks like

The tacit style guide is the showcase (`ratatui.rs/showcase`) — gitui, bottom, atac, trippy, xplr, taskwarrior-tui, csvlens, scope-tui, openapi-tui. The recurring signature across all of them:

1. **Bordered panels everywhere**, tiled to fill the screen — the instrument-panel grid.
2. **Titles in the border**, name top-left, help bottom.
3. **Tab bars** for top-level navigation (a `Tabs` widget rendered in a thin top block).
4. **Gauges + sparklines** for any live metric, braille-smooth.
5. **Single-accent palette** on terminal-default ground; selection as an inverted/`reversed` bar.
6. **Padding and even spacing** around blocks in the polished apps; tight packing in the utilitarian ones.

This is the ecosystem's shared "good taste," and it exists *because the library made exactly those moves the cheapest ones to type.* `Block::bordered()` is a single call; a plain unframed region takes more deliberate effort. `.dim()` and `.reversed()` are one word. `Flex::Center` is one variant. The aesthetic is downstream of the ergonomics — ratatui's opinions live in what it makes easy, and what it makes easy is **the clean, framed, monochrome-plus-cyan engineering console.**

---

## 10. Identity & voice: serious tool, playful brand

There is a deliberate tension between the *product's* look (crisp, restrained, engineering-precise) and the *project's* voice (a chef rat, cheese jokes, "cook up delicious TUIs," "always fresh and full of cheese," "start cooking"). The culinary/mascot branding makes systems programming feel approachable and un-intimidating, while the library's defaults push users toward disciplined, professional output. The rat says *this is fun*; the empty `Style::default()` says *but your app will look like it means business.* That split — whimsical identity, austere output — is itself part of the ratatui character.

---

## Notable quotes

- **"Cook up delicious terminal user interfaces."** — homepage tagline (ratatui.rs).
- **"All the ingredients you need to cook up exceptional terminal applications. Always fresh and full of cheese."** — homepage (ratatui.rs).
- **"A `Block` is a foundational widget that creates visual containers by drawing borders around an area. It serves as a wrapper or frame for other widgets, providing structure and visual separation in terminal UIs."** — `ratatui-widgets` Block docs.
- **"Without a persistent widget state, your UI logic becomes a direct reflection of your application state. You don't have to sync them or worry about past widget states."** — Rendering concept (ratatui.rs/concepts/rendering).
- **"There are 22 palettes... Black and White are also included for completeness and to avoid being affected by any terminal theme that might be in use."** — `style/palette/tailwind.rs` docstring (the "own your look vs. inherit the terminal's" tension, stated outright).
- **"Quadrant characters display densely packed and regularly spaced pseudo-pixels... without visible bands between cells."** — `Marker` docs (`symbols/marker.rs`), the density-vs-texture design note.

## Sources

- https://github.com/ratatui/ratatui — source (symbols/line.rs, border.rs, block.rs, bar.rs, marker.rs, shade.rs, style/color.rs, style/stylize.rs, style/palette/tailwind.rs, block/shadow.rs), v0.30.2
- https://ratatui.rs/ — homepage, branding, tagline
- https://ratatui.rs/recipes/widgets/block/ — Block recipe
- https://ratatui.rs/concepts/layout/ — Constraint/Flex layout
- https://ratatui.rs/concepts/rendering/ — immediate-mode philosophy
- https://ratatui.rs/showcase/apps/ — community gallery / house style
- https://docs.rs/ratatui/latest/ratatui/widgets/struct.Block.html — Block API
- https://docs.rs/ratatui/latest/ratatui/symbols/index.html — symbols module
- https://docs.rs/ratatui/latest/ratatui/layout/enum.Flex.html — Flex modes
- https://blog.orhun.dev/ratatui-0-23-0/ — "From tui-rs to Ratatui" (lineage, Orhun Parmaksız)
- https://kdheepak.com/blog/the-basic-building-blocks-of-ratatui-part-4/ — community deep-dive on Block
- https://tailwindcss.com/docs/customizing-colors — the Tailwind palette ratatui vendors
