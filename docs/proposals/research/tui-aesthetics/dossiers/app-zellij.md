# Aesthetic Dossier — Zellij

**Category:** Terminal multiplexer (the "modern / self-documenting" family — the friendly answer to tmux's austerity)
**Repo:** https://github.com/zellij-org/zellij • **Site:** https://zellij.dev • **Creator:** Aram Drevekenin (imsnif) • https://poor.dev
**Language:** Rust • **License:** MIT • **Tagline:** "A terminal workspace with batteries included"
**Researched from:** shallow clone of `main` (source read directly), CHANGELOG, 41 shipped themes, plus web sources.

---

## 0. One-sentence identity

Zellij takes the same character grid tmux uses and makes it feel like a *designed product* — rounded pane corners, powerline-arrow tab and mode ribbons, a status bar that rewrites itself to teach you the current mode's verbs, and a semantic-role theme engine that reskins the entire multiplexer from one 40-line file. Where tmux says *nothing* until you configure it, Zellij's whole surface is a self-narrating instrument that also happens to be pretty.

The name is the thesis: **zellij** (Arabic الزليج) is Moroccan/Andalusian mosaic tilework — hand-chiseled polygons tessellated into radiating star patterns. Panes tiling a screen *are* zellige. The identity is "tessellation as craft," not "terminal as teletype."

---

## 1. The core aesthetic bet: discoverability rendered as beauty

Every other decision descends from one maintainer conviction, stated plainly:

> "It is Aram's belief that an interface being discoverable and looking good is one of the most important aspects of using software. It not only makes new and returning users feel at home, it helps discovering features."
> — poor.dev / External work

> "Zellij is powerful, simple, beautiful and yet deeply configurable."
> — Aram Drevekenin, *Why Zellij?* (poor.dev/blog/why-zellij)

> "Creating discoverable textual interfaces is hard, and doing so without the benefit of a mouse or a touch screen is even harder."
> — poor.dev

The aesthetic consequence: **the UI is never silent.** tmux's blank green bar is a status *report*; Zellij's bar is a *tutorial that restyles per mode*. The "looking good" and the "self-documenting" are the same design move — legible structure reads as both instruction and polish.

---

## 2. Describe-the-screen (default layout)

Boot Zellij with defaults and you get a three-band composition (`assets/layouts/default.kdl`):

```
 Zellij (my-session)          Tab #1                                          ← tab-bar plugin, row 1
╭─ pane title ────────────────────────────────────────────────────╮
│                                                                  │
│  $ your shell lives here                                         │  ← content pane, rounded frame
│                                                                  │
╰──────────────────────────────────────────────────────────────────╯
 Ctrl + <p> PANE <t> TAB <r> RESIZE <s> SEARCH ...   Tip: Alt+n => new pane   ← status-bar plugin, row 3
```

- **Row 1 — tab bar:** a left-aligned session name, then tabs rendered as **powerline ribbon segments** ( arrow-separated), the active tab filled with the theme's `ribbon_selected` background (usually a saturated green/accent), inactive tabs in muted `ribbon_unselected`.
- **Middle — the content pane** wrapped in a single-weight box frame whose corners are **rounded** (`╭ ╮ ╰ ╯`) when `rounded_corners` is on, with a colored title tab reading the pane's name/command.
- **Row 3 — status bar:** the "superkey" ribbon (`Ctrl + ...`) followed by mode tiles, and on the right a rotating **Tip:** line and swap-layout indicator.

Both bars are `size=1 borderless=true` panes running **WASM plugins** — the chrome is built from the same plugin system users get, which is itself an identity statement: "the frame is not privileged; it's just very good tenant code."

---

## 3. Border & box-drawing language

**File:** `zellij-server/src/ui/boundaries.rs`, `zellij-server/src/ui/pane_boundaries_frame.rs`

Zellij defines *both* sharp and round variants of every corner and swaps them at render time:

```rust
pub const TOP_LEFT: &str = "┌";      pub const TOP_LEFT_ROUND: &str = "╭";
pub const TOP_RIGHT: &str = "┐";     pub const TOP_RIGHT_ROUND: &str = "╮";
pub const BOTTOM_LEFT: &str = "└";   pub const BOTTOM_LEFT_ROUND: &str = "╰";
pub const BOTTOM_RIGHT: &str = "┘";  pub const BOTTOM_RIGHT_ROUND: &str = "╯";
```

```rust
if self.style.rounded_corners {
    match corner {
        boundary_type::TOP_LEFT  => boundary_type::TOP_LEFT_ROUND,   // ┌ → ╭
        boundary_type::TOP_RIGHT => boundary_type::TOP_RIGHT_ROUND,  // ┐ → ╮
        ...
```

| Technique | Vibe it produces |
|---|---|
| **Single-weight lines only** (`│ ─ ┼ ├ ┤ ┬ ┴`); no double `═` or heavy `┃` frames | Quiet, contemporary, "app-like" — not the CAD-diagram heaviness double lines carry. The frame recedes so content leads. |
| **Rounded corners `╭╮╰╯`** (opt-in via `rounded_corners true`) | The single most-cited "Zellij looks modern" cue. Rounding a 1-cell corner reads as *softened, friendly, designed-this-decade* — the terminal equivalent of `border-radius`. tmux can only make hard `┌┐` right angles, which read as utilitarian/severe. |
| **Unfocused frame = 8-bit GRAY (238)**, focused frame = theme accent (`frame_selected`, usually green ~`158 206 106`) | Focus becomes a *warm glow* against gray siblings. The eye is pulled without a single blink or arrow — color-as-attention. |
| **Colored title "tab" welded onto the top border** carrying pane name / running command / exit code | The border does double duty as a label surface; the pane announces *what it is*, so the grid feels self-describing rather than anonymous. |
| **Corners degrade gracefully** — with frames disabled, top corners collapse to `─`; stacked panes reuse `└┘` on top edges to signal "there's a pane above" | The box-drawing vocabulary itself encodes state; structure is legible from glyphs alone. |

**Important nuance for accuracy:** `rounded_corners` **defaults to `false`** (confirmed in the config snapshots and `default.kdl`, where `rounded_corners true` is a commented example). The rounded look is Zellij's *signature*, but it's an opt-in the community adopted so widely it became the brand. The default frame is still single-weight sharp corners — already softer than tmux by virtue of the gray/accent focus coloring.

---

## 4. The mode-aware keybind ribbon — self-documentation AS aesthetic

**Files:** `default-plugins/status-bar/src/first_line.rs` (superkey + mode tiles), `second_line.rs` (per-mode verb list)

This is Zellij's beating heart. The status bar is a **two-line, mode-reactive instrument**:

**First line — the mode ribbon.** A leading "superkey" (`Ctrl +`) is factored out once, then each mode is a **powerline tile**: `<p> PANE`, `<t> TAB`, `<r> RESIZE`, `<s> SEARCH`, `<o> SESSION`, `<q> QUIT`... The docstring spells out the intended shape:

> "A long mode shortcut tile consists of a leading and trailing `separator`, a keybinding enclosed in `<>` brackets and the name of the mode displayed in capitalized letters next to it. For example, the default long mode shortcut tile for 'Locked' mode is: ` <g> LOCK `."

Each tile carries one of four visual states (`Unselected`, `UnselectedAlternate`, `Selected`, `Disabled`) mapped to different color declarations. Enter Pane mode and the `PANE` tile lights to `Selected` (theme accent fill) while the rest dim.

**Second line — the verb list rewrites per mode.** `get_keys_and_hints` returns, per `InputMode`, the exact verbs of that mode:

```rust
// Pane mode:
(s("New"), ...), (s("Change Focus"), ...), (s("Close"), ...),
(s("Rename"), ...), (s("Toggle Fullscreen"), ...), (s("Toggle Floating"), ...), ...
// Resize mode:
(s("Increase/Decrease size"), ...), (s("Increase to"), ...), (s("Decrease from"), ...)
// Search mode:
(s("Enter Search term"), ...), (s("Search down"), ...), (s("Case sensitive"), ...), (s("Whole words"), ...)
```

| Technique | Vibe it produces |
|---|---|
| **Status bar rewrites its entire vocabulary on mode switch** | The interface *narrates itself in real time*. It feels alive and attentive — a teacher leaning over your shoulder, not a manual on a shelf. This is the defining feeling that separates Zellij from tmux. |
| **Keys shown are read from the user's ACTUAL keybindings** (`action_key(&km, ...)`), not hardcoded | Honesty as aesthetic: rebind a key and the bar tells the truth. Unbound actions render a bold `UNBOUND` placeholder — even absence is labeled. |
| **Two forms per hint (long + short) with width-responsive collapse** — `"Increase/Decrease size"` → `"Increase/Decrease"`, `"Toggle Fullscreen"` → `"Fullscreen"` | Graceful degradation reads as *craft*. The bar never overflows; it just gets terser, like a responsive web layout reflowing. |
| **Superkey factoring** — `Ctrl +` printed once, then bare letters in tiles | Reduces visual noise, makes the chord grammar legible: "hold Ctrl, then pick a tile." Structure teaches structure. |
| **`-- INTERFACE LOCKED --`** bold banner in Locked mode | A single emphatic line that changes the emotional register: the UI *feels* frozen/safe, not just behaviorally locked. Personality through copy. |
| **Rotating `Tip:` line** in Normal mode ("Tip: `Alt+n` => open new pane.") | Friendly, conversational voice (`=>`, sentence case, ends in a period). Reads like a helpful colleague, not a syslog. |

The tip copy is deliberately warm (`default-plugins/status-bar/src/tip/data/quicknav.rs`):

```
 Tip: <keys> => open new pane.  <keys> => navigate between panes.  <keys> => increase/decrease pane size.
```

There's even a code comment betraying the care: *"Let's see if we have some pretty groups in common here"* — arrows (`← ↓ ↑ →`) and letter keys are visually grouped and joined with `" or "` so the hint reads like natural language, not a key dump.

---

## 5. Tab bar & active-tab accent treatment

**File:** `default-plugins/tab-bar/src/tab.rs`

Tabs are **powerline ribbon segments** (`ARROW_SEPARATOR = ""`, U+E0B0). The active-tab logic is a small color state machine:

```rust
let background_color = if tab.active            { palette.ribbon_selected.background }   // accent fill
    else if is_hovered                          { palette.ribbon_unselected.emphasis_1 } // hover tint
    else if is_alternate_tab                    { alternate_tab_color }                  // zebra
    else                                        { palette.ribbon_unselected.background };
```

| Technique | Vibe it produces |
|---|---|
| **Active tab = solid accent-background pill** with arrow caps | The current tab reads as *physically raised / selected*, like a highlighted browser tab. Filled-background beats underline for "you are here" punch. |
| **Powerline `` arrow separators** flowing tab-into-tab | The "seamless ribbon" look — segments interlock like flowing chevrons. This is the single most "modern terminal" visual signature after rounded corners. |
| **Mouse-hover tint** (`is_hovered` → `emphasis_1`) | Micro-interaction borrowed from GUIs: the tab *responds to the cursor*. Terminals almost never do this; it reads as unexpectedly alive and premium. |
| **Zebra "alternate tab" coloring** used *only* when arrow fonts are unavailable | Adaptive elegance: without Nerd Fonts you can't draw the arrow caps, so it falls back to alternating shades to keep tabs distinguishable. The design degrades instead of breaking. |
| **Inline state tags** — ` (FULLSCREEN)`, ` (SYNC)`, ` [!]` bell, per-client `[▓]` cursor swatches | The tab is a status glyph, not just a name. Multiplayer collaborators show up as colored blocks *inside* the tab — presence made visible. |
| **Flashing-bell foreground swap** (`emphasis_3`) | An alert that's a *color pulse*, not a beep — attention without noise, in keeping with the "quiet but expressive" register. |

Fallback: `tab_separator()` swaps the arrow glyph for a plain separator when the terminal lacks arrow-font capability — the ribbon look is aspirational-default, ASCII-safe underneath.

---

## 6. The theme system — semantic roles, not ANSI slots

**Files:** `zellij-utils/assets/themes/*.kdl` (41 themes), `Styling` struct in `zellij-utils/src/data.rs`

This is Zellij's deepest and most underrated design decision. A theme does **not** map "red = this, blue = that." It maps **UI semantic roles**, each with a `base` foreground, a `background`, and **four `emphasis_0..3` accent colors**:

```kdl
themes {
    catppuccin-mocha {
        text_unselected   { base 205 214 244; background 24 24 37;  emphasis_0 250 179 135; ... }
        text_selected     { ... }
        ribbon_selected   { base 24 24 37;    background 166 227 161; emphasis_0 243 139 168; ... }
        ribbon_unselected { ... }
        frame_selected    { base 166 227 161; background 0; ... }
        frame_highlight   { base 250 179 135; ... }
        exit_code_success { base 166 227 161; ... }
        exit_code_error   { base 243 139 168; ... }
        table_title / table_cell_selected / list_selected / ...
        multiplayer_user_colors { player_1 245 194 231; player_2 137 180 250; ... }
    }
}
```

| Technique | Vibe it produces |
|---|---|
| **Semantic role palette** (`ribbon_selected`, `frame_selected`, `exit_code_error`…) rather than 16 ANSI slots | One file reskins the *entire* multiplexer coherently — tabs, frames, hints, tables, exit codes all move together. A theme feels like a *complete identity swap*, not a recolor. Swapping catppuccin→retro-wave changes the whole personality. |
| **Four `emphasis` accents per role** | Rich, layered highlighting (a hint can have key-color + action-color + separator-color) instead of flat monochrome. This is what lets the status bar look *composed* rather than uniform. |
| **41 shipped truecolor themes** — catppuccin (×4), tokyo-night (×4), gruvbox, nord, dracula, solarized, everforest, kanagawa, ayu, rosé-adjacent, plus originals: `cyber-noir`, `blade-runner`, `retro-wave`, `vesper`, `menace` | Batteries-included identity: you're one line from a curated look. The *original* neon themes (retro-wave: `#00FF00` on black, `#FF35...` magenta) signal "we have taste, not just ports." |
| **`multiplayer_user_colors` as a first-class theme slot** (10 player colors) | Collaboration is themed, not bolted on. Each remote cursor gets a stable, palette-harmonized color — presence that *belongs* to the aesthetic. |
| **Dark/light theme pairs + live switching** (CSI 2031, `ToggleTheme`, `SetDarkTheme`/`SetLightTheme` keybindings; live-reload on theme-dir change) | The identity is *responsive to environment* — it can follow the OS's dark/light mode. Terminals treated like modern apps. |

Theme lineage in the CHANGELOG reads like a design diary: KDL config switch (#1759), hex colors (#1536), the **new theme definition spec** (#3242, #4002) that introduced this semantic-role model, cyberpunk themes (#2868), catppuccin (#1937), and dark/light switching (#5105–5113).

---

## 7. Floating panes, plugin UI, and layered-surface framing

- **Floating panes** get the same rounded/single-weight frame but signal their "lifted" status through a **pin indicator** and a distinct interaction affordance (`render_pinned_indication`, `is_floating` branches in `pane_boundaries_frame.rs`). Zellij doesn't fake a drop-shadow with `░▒` dithering — instead the floating pane simply *overlaps* the tiled grid, and its frame + pin glyph carry the "I'm on top" meaning. The layering language is **occlusion + a pin badge**, not shadow.
- **Plugin UIs** (session-manager, strider file browser, plugin-manager, the `about` page, multiple-select) are built from a shared component kit: `ribbon()`, `table()`, `Text`, `NestedList`, `BulletinList`. Because every panel draws from the same ribbon/table primitives with the same semantic theme roles, **plugins look like they belong to Zellij**, not like third-party bolt-ons. Consistency *is* the brand.
- **`ribbon()` component** (`zellij-server/src/ui/components/ribbon.rs`) is the reusable powerline pill: arrow-cap + padded bold text + arrow-cap, selected vs unselected coloring. It's the atomic unit of Zellij's visual language, shared by tabs, mode tiles, and plugin selectors alike.

---

## 8. Typography substitutes & glyph vocabulary

The character grid has no fonts, so Zellij leans on:

| Device | Where | Vibe |
|---|---|---|
| **BOLD everywhere structural** — mode names, keys, actions, ribbon text all `.bold()` | first_line/second_line/ribbon | Bold is Zellij's "heading weight." Gives the UI a confident, high-contrast spine. |
| **DIM for de-emphasis** (`dimmed_foreground_color`, unfocused frame gray) | frames, secondary hints | Recedes background chrome so focused content pops — the terminal's only "opacity." |
| **ALL-CAPS mode names** (`PANE`, `RESIZE`, `LOCK`, `-- INTERFACE LOCKED --`) | status bar | Caps read as *labels/system-state*, giving the bar an instrument-panel authority. |
| **`<key>` angle-bracket enclosure** for shortcuts | mode tiles | A consistent "this is a key" typographic frame — instantly parseable grammar. |
| **Nerd Font / Powerline glyphs** — `` (E0B0) arrow separators, pin/lock icons | tabs, ribbons | The "GUI-grade" cue. Powerline arrows are the terminal's borrowed drop-shadow: they imply depth and flow. Gated behind an `arrow_fonts` capability with ASCII fallback. |
| **Sentence-case conversational copy** (`=> open new pane.`, `Tip:`) | tips | Human warmth; the app *talks* rather than *reports*. |

---

## 9. Motion & redraw language

- **Mode transitions** are instant full-bar restyles — no easing, but the *swap itself* is the motion: the whole ribbon reflows and recolors on every `Ctrl+<x>`, which reads as responsive and snappy.
- **Rotating tips** cycle through `TIPS` (quicknav, floating-panes-mouse, sync-tab, edit-scrollback, move-tabs…) — a slow ambient motion that keeps the bar feeling alive across a long session and dribbles out feature discovery over time.
- **Bell flashing** — tab foreground pulses to `emphasis_3` on `is_flashing_bell`: attention as a color blink.
- **Hover feedback** on tabs and pane titles (mouse tracking) — sub-frame interactivity uncommon in TUIs; the surface *tracks your cursor*.
- No spinners/marquees in the core chrome; the aesthetic is **calm** — motion is reserved for meaning (bell, mode, hover), never decoration.

---

## 10. Identity moments

- **Name & logo:** the mosaic-tile metaphor (Islamic geometric tessellation). Panes tiling = zellige tiles. The README dedicates a whole *"Origin of the name"* section to it — the craft heritage is deliberately foregrounded.
- **`about` plugin** (`default-plugins/about/`): an in-app welcome / what's-new page with hoverable menu items and version — Zellij ships an *About screen*, a very "product" thing for a multiplexer.
- **Signature color:** no single fixed brand color (it's theme-driven), but the **focus-green accent** (`frame_selected` ≈ `158 206 106` / catppuccin green `166 227 161`) recurs as the default "you are here / active" signal across bundled themes. Cyber themes (retro-wave, blade-runner, cyber-noir) are the "house originals" that broadcast the project's own taste.
- **Empty/degraded states are labeled, never blank:** `UNBOUND` for unbound actions, `-- INTERFACE LOCKED --`, exit-code coloring (`exit_code_success` green / `exit_code_error` red on a pane's frame after a command finishes) — the frame reports how your last command *ended*, in color. That's personality: the UI has opinions about your exit codes.
- **Batteries-included ethos as identity:** the chrome is WASM plugins, so "the status bar is a plugin you could rewrite" is itself a flex — extensibility worn on the sleeve.

---

## 11. What makes it FEEL different from its siblings

| vs. | The felt difference |
|---|---|
| **tmux** | tmux is austere, silent, expert-only — a blank green bar that assumes you've read the man page. Zellij is *warm and narrating*: rounded corners, flowing ribbons, a bar that teaches. tmux = a workshop tool; Zellij = a designed product. The gap is emotional (severe vs. friendly) and epistemic (opaque vs. self-documenting). |
| **screen** | Ancient, no chrome, no color identity. Zellij is from another era of design entirely. |
| **Wezterm/Kitty (GPU terminals w/ multiplexing)** | Those get "modern" from GPU font rendering and real pixels; Zellij achieves a comparable *modern* read using **only** rounded box-drawing + powerline glyphs + semantic truecolor themes — pure grid craft. |
| **Compact-bar mode** | Zellij can also collapse its own chrome to a single combined line (`compact-bar`), proving the verbosity is a *choice*, not bloat — the identity flexes from "teacher" to "minimalist" on one config flag. |

The essential Zellij feeling: **a terminal that behaves like it was designed by someone who cares whether you feel welcome.** Discoverability and prettiness are fused — the same rounded, colored, self-narrating surface does both jobs at once.

---

## 12. Reusable techniques (for a Raxol/TUI design vocabulary)

1. **Round the corners to signal "modern."** `╭╮╰╯` vs `┌┐└┘` is the cheapest, highest-impact "this decade" cue on the grid.
2. **Focus via warm accent vs. gray, not blink.** Unfocused = 8-bit gray 238; focused = theme accent. Attention without motion.
3. **Make the status bar restyle per mode.** A context-reactive hint ribbon turns documentation into ambient UI and reads as "alive."
4. **Read keys from real config, label absence (`UNBOUND`).** Honesty is an aesthetic; it makes the surface trustworthy.
5. **Two-tier responsive copy (long/short) with width-collapse.** Never overflow; degrade to terser labels like responsive web.
6. **Theme by semantic role, not ANSI slot.** `ribbon_selected`/`frame_selected`/`exit_code_error` + N emphasis accents → one file, whole-app coherent reskin.
7. **Powerline ribbons () as the atomic pill,** with an ASCII/zebra fallback when glyphs are unavailable.
8. **Let the frame report state:** pane title = command, corner color = exit code, tags = `(SYNC)`/`[!]`. The border earns its cells.
9. **Layer via occlusion + a badge (pin), not fake shadows** — cleaner than `░▒` dithering on a grid.
10. **Warm, sentence-case voice** (`Tip: … => open new pane.`) to make a system tool feel like a colleague.

---

## Sources

- Zellij source (shallow clone `main`): `boundaries.rs`, `pane_boundaries_frame.rs`, `components/ribbon.rs`, `default-plugins/{tab-bar,status-bar,about}/`, `assets/themes/*.kdl`, `assets/layouts/{default,compact}.kdl`, `assets/config/default.kdl`, `CHANGELOG.md`, `README.md` — https://github.com/zellij-org/zellij
- Aram Drevekenin, *Why Zellij?* — https://poor.dev/blog/why-zellij/
- Aram Drevekenin, homepage & external work — https://poor.dev/ , https://poor.dev/external_work/
- Zellij docs / FAQ — https://zellij.dev/ , https://zellij.dev/faq/
- Zellij 0.31.0 release notes (search panes, custom status-bar keybindings) — https://zellij.dev/news/sixel-search-statusbar/
- "Zellij vs tmux: The Modern Terminal Multiplexer (2026)" — https://petronellatech.com/blog/zellij-terminal-multiplexer-guide-2026/
- "Zellij Review: The multiplexer that finally stuck" — https://jpk.io/dev-tools/zellij-terminal-multiplexer-review/
- DeepWiki architecture overview — https://deepwiki.com/zellij-org/zellij
- Interview of Aram (YouTube) — https://www.youtube.com/watch?v=VZ_lEXPnD4o
- Origin-of-name (zellige mosaic) — README §"Origin of the name"
