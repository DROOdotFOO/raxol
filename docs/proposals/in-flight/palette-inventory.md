# Palette Primitive Inventory

Status: **inventory / audit (v1)** · Date: 2026-07-15 · Owner: Claude
Companion: `Raxol.UI.Theming.Palette` (`lib/raxol/ui/theming/palette.ex`) — the new
canonical origin module this inventory feeds.

Thesis: Raxol does not have a scattering of a few stray hex codes — it has **at least
six independently-written "the standard ANSI 16 colors" tables** and **at least five
independently-written "the default semantic theme" token sets**, several of which are
actively pinned by tests with mutually-incompatible values. This doc catalogs every
palette primitive found, grouped as requested, with the duplicates/conflicts called out
explicitly because that's the actual reason to unify. Nothing described here has been
changed — this is a read-only audit. `Raxol.UI.Theming.Palette` preserves every value
verbatim under an attributed name; it does not silently pick a winner.

---

## 0. Executive summary

| # | Finding | Scale |
|---|---|---|
| 1 | ANSI 16-color basic table exists in **6+ independent copies**, in (at least) 4 conflicting numeric conventions (VGA/half-intensity, xterm, GNOME/Ubuntu Terminal, pure+pastel-bright) | `lib/raxol/ui/theming/colors.ex`, `lib/raxol/style/colors/{color,formats}.ex`, `packages/raxol_terminal/.../color_manager.ex`, `.../sixel_palette.ex`, `.../optimized_style_renderer.ex`, `.../theme/theme_manager.ex`, `packages/raxol_liveview/.../themes.ex` |
| 2 | The 216-color (16-231) cube uses **two different step formulas** (`0,95,135,175,215,255` vs. naive `n*51`) that agree only at the cube's two corners | `lib/raxol/ui/theming/colors.ex` vs. `lib/raxol/style/colors/formats.ex` (+ mirrored in `packages/raxol_terminal/.../sixel_palette.ex`) |
| 3 | **Five unrelated "default semantic theme" token sets** all claim to be *the* default `primary`/`background`/`success`/`warning`/`error` palette, with completely different hex values and even opposite light/dark polarity | `Raxol.UI.Theming.Theme.default_theme/0` + `dark_theme/0`, `Theme.new/0` (via `default_attrs/0`), `Raxol.Style.Colors.System.create_dark_theme/0` + `create_high_contrast_theme/0`, `lib/raxol/ui/universal.ex`, `lib/raxol/ui/state/context.ex` |
| 4 | **Four parallel theme-registry subsystems** exist (`Raxol.UI.Theming.Theme`/`ThemeManager`, `Raxol.Core.Theming.ThemeRegistry`, `Raxol.Themes`, `Raxol.LiveView.Themes`), of which `ThemeRegistry` explicitly documents itself as "single source of truth" yet is consumed almost nowhere | see §6 |
| 5 | Even where two modules deliberately implement the *same* named community theme (Dracula, Nord), the **UI-role mapping disagrees** (which literal color is "cursor") even when the 16 ANSI slots match byte-for-byte | `Raxol.Core.Theming.ThemeRegistry` vs. `Raxol.LiveView.Themes` |
| 6 | The literal pair `"#000000"`/`"#FFFFFF"` (or `:black`/`:white`) appears as an independent hardcoded WCAG-safe fallback **15+ times** across unrelated files | see §5 |
| 7 | The near-black surface value `#1E1E1E` / `rgb(30,30,30)` recurs **3 times independently**, currently in sync by luck, not by shared source | see §5 |
| 8 | One single file defines **two internally-inconsistent** ANSI-16 tables (pure-saturated hex vs. VGA-convention RGB tuples) that disagree with each other on 9 of 16 slots | `packages/raxol_liveview/lib/raxol/live_view/terminal_bridge.ex` — see §5.8 |
| 9 | The "error=red / warning=yellow / success=green / info=cyan" status convention is reinvented independently in **8+ unrelated modules** (playground demos, accessibility, sensor HUD, symphony dashboard, swarm overlay) with no shared vocabulary anywhere | see §9 |
| 10 | A third independent "terminal default fg/bg" polarity exists in `raxol_core`, distinct from both `raxol_terminal`'s and `Theme`'s | `packages/raxol_core/lib/raxol/core/config/config.ex:302-304` — see §5.9 |

---

## 1. (a) Canonical theme tokens

These are the "semantic token" sets: `background`/`foreground`/`accent`/`success`/`warning`/`error`/`surface`/`border`/`muted`/etc. **Five conflicting families**, all still live and each pinned by its own tests. None is "the" default in any global sense — each is default *for its own call sites only*.

### 1.1 `Raxol.UI.Theming.Theme.default_theme/0` — "Dracula-derived IDE" family
`lib/raxol/ui/theming/theme.ex:183-238`

| Token | Value |
|---|---|
| `background` | `#000000` |
| `surface` | `#1E1E1E` |
| `foreground` | `#FFFFFF` |
| `accent` | `#4A9CD5` |
| `error` | `#FF5555` |
| `warning` | `#FFB86C` |
| `success` | `#50FA7B` |
| `fuschia` | `#FF00FF` |

`error`/`warning`/`success` are byte-identical to the real Dracula theme's red/orange/green
(compare §6.1), but `background`/`accent` are not — this is a custom theme *inspired by*
Dracula, not a copy of it. `component_styles.table.header_background` = `#222831` (line 226,
via `Color.from_hex`), a value that appears nowhere else in the codebase.

### 1.2 `Raxol.UI.Theming.Theme.dark_theme/0` — same family, different background
`lib/raxol/ui/theming/theme.ex:243-277`

Same `foreground`/`accent`/`error`/`warning`/`success`/`fuschia` as 1.1, but
`background: "#1E1E1E"` (no separate `surface` token — dark_theme's background *is*
default_theme's surface). `component_styles.text_input.background` = `#2D2D2D`, unique to
this variant.

### 1.3 `Raxol.UI.Theming.Theme.new/0` (via private `default_attrs/0`) — "brand light" family
`lib/raxol/ui/theming/theme.ex:306-363`

Called by the zero-arg `Theme.new/0` and thus by anything that constructs a theme without
explicit attrs — a *different* "the default theme" than 1.1/1.2, with opposite light/dark
polarity:

| Token | Value |
|---|---|
| `primary` | `#0077CC` |
| `secondary` | `#666666` |
| `accent` | `#FF9900` |
| `background` | `#FFFFFF` |
| `surface` | `#F5F5F5` |
| `error` | `#CC0000` |
| `success` | `#009900` |
| `warning` | `#FF9900` (same literal as `accent`) |
| `info` | `#0099CC` |
| `text` / `foreground` | `#000000` |

**Both 1.1 and 1.3 are independently pinned by tests** — `test/raxol/ui/components/input/button_visual_test.exs`, `test/raxol/ui/renderer_test.exs`, `test/platform/component_rendering_test.exs` pin `#4A9CD5`; `test/raxol/color_system_test.exs`, `test/raxol/style/colors/{persistence,system}_test.exs` pin `#0077CC`/`#FF9900`. Neither can be changed without breaking the other's assumption of what "default" means.

### 1.4 `Raxol.Style.Colors.System.create_dark_theme/0` / `create_high_contrast_theme/0`
`lib/raxol/style/colors/system.ex:233-271`

A **third and fourth** "default-ish" set, again with different literals for the same
concepts:

| Token | `create_dark_theme/0` | `create_high_contrast_theme/0` |
|---|---|---|
| `primary` | `#90CAF9` | `#FFFF00` |
| `secondary` | `#B0BEC5` | `#000000` |
| `background` | `#121212` | `#000000` |
| `text` | `#FFFFFF` | `#FFFFFF` |

`#121212` also appears as `PaletteManager`'s contrast-check reference background
(`lib/raxol/style/colors/palette_manager.ex:60`, `dark_bg = "#121212"`) and as
`ColorSystemServer`'s fallback background (`lib/raxol/style/colors/system/color_system_server.ex:534`,
`Color.from_hex("#000000")` — note: `#000000` there, not `#121212`; a fifth near-miss value
for the same "background fallback" concept).

### 1.5 `lib/raxol/ui/universal.ex:66-91` — "web / Tailwind-derived" family
```elixir
defp default_theme do
  %{colors: %{
    primary: "#2563eb", secondary: "#6b7280", success: "#10b981",
    warning: "#f59e0b", error: "#ef4444", background: "#ffffff",
    surface: "#f9fafb", text: "#111827", text_muted: "#6b7280"
  }, ...}
end
```
These are the exact Tailwind CSS v3 defaults (`blue-600`, `gray-500`, `emerald-500`,
`amber-500`, `red-500`).

### 1.6 `lib/raxol/ui/state/context.ex:354-379` — "web / Bootstrap-derived" family
```elixir
def create_theme_context(theme_config \\ %{}) do
  default_theme = %{colors: %{
    primary: "#007acc", secondary: "#6c757d", success: "#28a745",
    warning: "#ffc107", error: "#dc3545", background: "#ffffff",
    surface: "#f8f9fa", text: "#212529"
  }, ...}
end
```
`success`/`warning`/`error` are exact Bootstrap 4 semantic colors. **1.5 and 1.6 use the
same token names (`primary`/`secondary`/`success`/`warning`/`error`/`background`/`surface`/`text`)
for two different web-rendering contexts and disagree on every single value** — see §5.1.

### 1.7 `lib/raxol/core/accessibility/theme_integration.ex:267-291` — accessibility-mode scheme
Different shape (ANSI atoms / `{:rgb, r, g, b}` tuples, not hex strings), but the same
semantic-token idea:
```elixir
:high_contrast -> %{bg: :black, fg: :white, accent: :yellow, error: :red, success: :green, warning: :yellow}
:standard      -> %{bg: {:rgb, 30, 30, 30}, fg: {:rgb, 220, 220, 220}, accent: :blue, error: :red, success: :green, warning: :yellow}
```
`{:rgb, 30, 30, 30}` is `#1E1E1E` in decimal — see §5.2 (the third independent
appearance of that exact near-black value).

### 1.8 `Raxol.UI.Theming.SalienceTheme.build/1` — solved, not hand-picked
`lib/raxol/ui/theming/salience_theme.ex:74-116` builds `colors.{background, foreground,
accent, error, warning, success, emphasis, muted}` and
`component_styles.{text_input, button, checkbox, table, focus, disabled}` at *runtime*
from the seed table in §3, solved against a detected/given ground lightness. There is no
static hex value to catalog here except the seeds themselves (§3) — this is the one
"family" that is architecturally supposed to vary, by design, and should not be conflated
with the others as a "conflict."

### 1.9 Fallback tokens (ANSI atoms, not hex)
Two independent "if the theme doesn't define this, fall back to a plain ANSI color" tables,
which happen to agree with each other:
- `Theme.get_color_fallback/1`, `lib/raxol/ui/theming/theme.ex:507-516`: `:white`→`:white`, `:black`→`:black`, `:green`/`:red`/`:yellow`/`:blue`/`:cyan`→themselves, `:foreground`→`:white`, `:background`→`:black`, catch-all→`:white`.
- `Raxol.UI.Theming.Selector`, `lib/raxol/ui/theming/selector.ex:178-182`: `fg: ... || :white`, `bg: ... || :black`, `border: ... || :blue`, `highlight: ... || :cyan`, `title: ... || :yellow`.

---

## 2. (b) Named colors

**One uncontested source**: `Raxol.UI.Theming.Colors.@color_names`, `lib/raxol/ui/theming/colors.ex:28-44`:

```
black #000000, white #FFFFFF, red #FF0000, green #00FF00, blue #0000FF,
yellow #FFFF00, cyan #00FFFF, magenta #FF00FF, gray #808080,
lightgray #D3D3D3, darkgray #A9A9A9, purple #800080, orange #FFA500,
pink #FFC0CB, brown #A52A2A
```

No other file in the audited tree defines an equivalent name→hex table. Gap worth noting:
`Raxol.Style.Colors.Color`'s `@moduledoc` (`lib/raxol/style/colors/color.ex:14`) advertises
`Named: :red, :blue, etc.` as a supported input format, but **no function in `color.ex`
implements named-color resolution** — that capability exists only in
`Raxol.UI.Theming.Colors`. `Raxol.UI.Theming.Palette.named_colors/0` /
`named_color/1` now mirror this table so it has a home independent of that gap.

A second, smaller named-color table exists for a different purpose — rainbow-cycling, not
theming — in `lib/raxol/plugins/examples/rainbow_theme_plugin.ex:346-357`:
`:red→{255,0,0}, :orange→{255,165,0}, :yellow→{255,255,0}, :green→{0,255,0}, :blue→{0,0,255}, :indigo→{75,0,130}, :violet→{238,130,238}`, fallback `{128,128,128}`. `:orange` here
(`{255,165,0}` = `#FFA500`) matches `Colors.@color_names[:orange]` exactly; the rest don't
overlap in name (roygbiv vs. CSS names) so this isn't a conflict, just a second, purpose-built
table.

A third named-color table, `Raxol.Terminal.Color.TrueColor.Palette.@colors`
(`packages/raxol_terminal/lib/raxol/terminal/color/true_color/palette.ex:6-25`, RGB-tuple
flavored), is the pleasant exception in this whole audit: **it agrees byte-for-byte with
`Colors.@color_names` on all 12 overlapping names** (`black, white, red, green, blue,
yellow, magenta, cyan, orange, purple, pink, brown, gray`) and adds 5 new ones
(`lime {0,255,0}` — an intentional CSS synonym for `green`, `navy {0,0,128}`,
`olive {128,128,0}`, `silver {192,192,192}`, `teal {0,128,128}`). No conflict — a strict
superset, and a good candidate to merge into `Palette.named_colors/0` outright rather than
keep as a separate "variant."

---

## 3. (c) Salience / H-K tier anchors

`Raxol.UI.Theming.Salience` (`lib/raxol/ui/theming/salience.ex`) is the OKLCH/H-K-compensated
tier *solver* (algorithm, out of scope to merge). Its primitives — the constants the solver
is built on — are:

```elixir
@hk_k 0.14
@tier_deltas %{alarm: 0.33, recede: 0.35, differentiate: 0.42, baseline: 0.57, anchor: 0.65}
@reference_ground 0.2
@al_min 0.03
@al_max 0.97
@max_delta 0.65
```
(`lib/raxol/ui/theming/salience.ex:26-44`)

`Raxol.UI.Theming.SalienceTheme`'s semantic seed table — `(name, hue, chroma, tier)` —
is the actual "palette" primitive in the H-K system (`lib/raxol/ui/theming/salience_theme.ex:25-34`):

```elixir
@seeds [
  %{name: :foreground, h: 250, c: 0.022, tier: :baseline},
  %{name: :accent,     h: 242, c: 0.074, tier: :differentiate},
  %{name: :error,      h: 25,  c: 0.16,  tier: :alarm},
  %{name: :warning,    h: 57,  c: 0.13,  tier: :differentiate},
  %{name: :success,    h: 134, c: 0.075, tier: :differentiate},
  %{name: :emphasis,   h: 77,  c: 0.125, tier: :anchor},
  %{name: :muted,      h: 250, c: 0.0,   tier: :recede},
  %{name: :border,     h: 250, c: 0.0,   tier: :recede}
]
```

Hue choices follow what the module comment calls "the compensated-Darcula family" —
orange 57 (warning), yellow 77 (emphasis), green 134 (success), blue 242 (accent),
neutral-blue 250 (foreground/muted/border), red 25 (error). These are hue *positions*
inspired by Dracula's color wheel, not literal Dracula hex values (contrast with §1.1,
which reuses literal Dracula hex values for the same three roles).

### Darcula reference bake — BYTE-EXACT TEST FIXTURE, DO NOT ALTER

`test/raxol/ui/theming/salience_test.exs:7-24` (`@darcula_baked`) pins 16 `(tier, c, h) ->
hex` solves that `Salience.solve/3` must reproduce byte-for-byte:

```elixir
{:differentiate, 0.13,  57,  "#b96922"}
{:anchor,        0.125, 77,  "#f5bd63"}
{:baseline,      0.022, 250, "#a9b5c1"}
{:differentiate, 0.075, 134, "#728e60"}
{:differentiate, 0.074, 242, "#5b8aad"}
{:differentiate, 0.086, 314, "#9673a7"}
{:recede,        0.0,   140, "#717171"}
{:recede,        0.09,  140, "#527c49"}
{:differentiate, 0.05,  57,  "#9b7d67"}
{:recede,        0.0,   250, "#717171"}
{:recede,        0.04,  57,  "#826a59"}
{:differentiate, 0.1,   57,  "#ae7142"}
{:anchor,        0.14,  314, "#e5b3fe"}
{:recede,        0.03,  57,  "#7e6c5f"}
{:baseline,      0.0,   250, "#b4b4b4"}
{:alarm,         0.16,  25,  "#ad3132"}
```

(Regenerated 2026-07-19 after fixing three H-K solver bugs — see
`lib/raxol/ui/theming/salience.ex`'s moduledoc and git history: the apparent-lightness
compensation sign was inverted, `hue_factor/1`'s warm lobe was a 3-cycle comb instead of a
single cycle peaking near red, and gamut-shrink chroma clipping wasn't re-solved against the
apparent-lightness target. The seed table and tier deltas above are unchanged; only the
solved hex outputs shifted.)

`test/raxol/ui/theming/salience_theme_test.exs:29-35` additionally pins the *semantic*
solves at the reference ground (0.2): `warning → #b96922`, `error → #ad3132`,
`emphasis → #f5bd63`, `success → #728e60`. **These 16+4 hex values are generated by
`Salience.solve/3`'s floating-point math, not stored as literals anywhere in `lib/` — they
cannot be "unified" by pointing at a shared constant, because the constant IS the solver.**
`Raxol.UI.Theming.Palette` does not reproduce this table; it only mirrors the `(name, h, c,
tier)` seeds above (by delegating to `SalienceTheme.seeds/0`, not by copying literals, so
it can never drift from the live source) and documents where the byte-exact fixture lives
so nobody "fixes" a perceived duplicate by touching it.

The playground demo `lib/raxol/playground/demos/salience_demo.ex:17-21` additionally
hardcodes three ground presets for its UI (`"dark" 0.10`, `"mid-gray" 0.50`, `"light"
0.92`) — demo-only, not a palette primitive of general interest.

---

## 4. (d) Scattered hardcoded hexes/ANSI atoms (file:line)

Primitives that are real defaults (not incidental doctest examples), found outside the
theming/style/colors core, grouped by area. Not exhaustive of the entire 50k-file tree —
this is what the audit surfaced as genuine default-color definitions, as opposed to
one-off usages of a color in a demo.

### UI components
- `lib/raxol/ui/focus_helper.ex:18-22` — `@default_focus_style %{border: :single, border_fg: :cyan}`, `@default_pseudo_styles %{disabled: %{fg: :gray}, active: %{border: :double, border_fg: :white}, focused: @default_focus_style}`. **Byte-identical in spirit to `Theme.default_theme`'s `component_styles.{focus,disabled,active}`** (§1.1) — currently in sync, no shared source.
- `lib/raxol/ui/components/modal/rendering.ex:111` — `@default_surface "#1E1E1E"`, fallback when `Theme.get_color(:surface, ...)` raises/exits (see §5.2 — third independent copy of this exact value).
- `lib/raxol/ui/components/table.ex:573` — `selected_row_style = Map.get(theme, :selected_row, %{bg: :blue, fg: :white})`.
- `lib/raxol/ui/components/markdown_renderer.ex:20-23` — `@heading_style %{bold: true, fg: :cyan}`, `@hr_style %{fg: :white}`, `@code_style %{fg: :yellow}`, `@blockquote_style %{fg: :green}`.
- `lib/raxol/ui/components/display/viewport.ex:22` — `@subtle_thumb_bg {110, 140, 180}` (pastel blue scrollbar thumb); `viewport.ex:292` — glyph-mode scrollbar `style: %{fg: :white}`.
- `lib/raxol/ui/cell_dim.ex:43-60` — `@ansi_16_codes`, a second independently-maintained copy of `Raxol.Core.Renderer.Color.@ansi_16_map`'s atom→SGR-code table (comment at line 41 acknowledges it mirrors that map's ordering); `cell_dim.ex:63` — `@unknown_atom_rgb {128, 128, 128}` fallback mid-gray.

### Core renderer
- `lib/raxol/core/renderer/color.ex:249-260` — `merge_with_defaults/1`'s default semantic-token RGB table: `foreground {0,0,0}, background {255,255,255}, primary {0,119,204}, secondary {102,102,102}, accent {255,153,0}, error {204,0,0}, warning {255,153,0}, success {0,153,0}, surface {245,245,245}, text {51,51,51}, info {0,153,204}` — a **sixth** semantic-token family, RGB-tuple flavored, with `background`/`foreground` polarity matching §1.3/1.5/1.6 (light) not §1.1/1.2 (dark).
- `lib/raxol/core/renderer/color.ex:305-315` — terminal-background-detection fallbacks: `"iTerm.app"/"Apple_Terminal" -> :black`, `COLORFGBG` `"...,0" -> :black`, `"...,15" -> :white`.

### Charts / visualization plugins
- `lib/raxol/plugins/visualization/chart_renderer.ex:253` — `Style.new(bg: :blue, fg: :blue)`, unconditional default bar-chart color.
- `lib/raxol/plugins/visualization/treemap_renderer.ex:676` — `Style.new(fg: :black, bg: color)`, fixed label text color over a dynamic background.

### Plugins
- `lib/raxol/plugins/examples/status_line_plugin.ex:375-401` — two full built-in status-line themes (`"default"`: mode `fg: :cyan` bold, git `fg: :green`, cursor `fg: :yellow`, size `fg: :blue`, cpu/memory `fg: :magenta`, time `fg: :white`, `bg: :black`; `"minimal"`: all `fg: :white`, `bg: :default`).
- `lib/raxol/plugins/examples/rainbow_theme_plugin.ex:346-357` — see §2.
- `lib/raxol/system/updater/updater_core.ex:156-157` — `fg = {0, 255, 0}` / `bg = {0, 0, 0}`, hardcoded bright-green-on-black for update-available notifications.

### Effects
- `lib/raxol/effects/border_beam/colors.ex` — see §7 (dedicated section, explicitly in scope).

### Terminal package (`packages/raxol_terminal`)
- `packages/raxol_terminal/lib/raxol/terminal/colors.ex:15-19` — `%Raxol.Terminal.Colors{}` defstruct defaults: `foreground: "#000000", background: "#FFFFFF", cursor_color: "#000000", selection_foreground: "#FFFFFF", selection_background: "#0000FF"`. **Light-on-dark is inverted here relative to `Theme.default_theme`** — see §5.3.
- `packages/raxol_terminal/lib/raxol/terminal/config/defaults.ex:77` — `cursor_color: "#ffffff"` — conflicts with the struct default above (`#000000`) for the same concept in the same package.
- `packages/raxol_terminal/lib/raxol/terminal/color/color_manager.ex:10-26` — `Raxol.Terminal.Color.Manager.default_palette`, a fifth verbatim copy of the xterm-convention ANSI 16 table (see §5).
- `packages/raxol_terminal/lib/raxol/terminal/ansi/sixel_palette.ex:18-34` — `initialize_base_palette/0`, a sixth verbatim copy of the same xterm-convention ANSI 16 table, plus its own 216-cube/grayscale generation (naive `*51` cube, matching `formats.ex`'s formula not `theming/colors.ex`'s).
- `packages/raxol_terminal/lib/raxol/terminal/rendering/optimized_style_renderer.ex:28-45` — `@style_patterns`, the GNOME/Ubuntu-Terminal-convention ANSI 16 table (see §5).
- `packages/raxol_terminal/lib/raxol/terminal/theme/theme_manager.ex:104-176` — `Raxol.Terminal.Theme.Manager.new/1`'s hardcoded `default_theme`: pure-saturated ANSI 16 as RGBA maps (`red {255,0,0,1.0}`, etc.), background `{0,0,0,1.0}`, foreground `{255,255,255,1.0}`, selection `{51,51,51,1.0}`; bright variants blended 50% toward white (`bright_red {255,128,128,1.0}`). This module's `@moduledoc` explicitly says themes should come from `Raxol.Core.Theming.ThemeRegistry` (§6.2) — its own `new/1` default doesn't follow that advice.

---

## 5. (e) DUPLICATES AND CONFLICTS

This is the actual point of the exercise. Grouped by primitive concept.

### 5.1 ANSI 16-color basic table — 4 conflicting conventions, 6+ literal copies

| Idx | Name | **xterm** convention | **VGA/half-intensity** convention | **GNOME/Ubuntu Terminal** convention | **pure+pastel-bright** convention |
|---|---|---|---|---|---|
| 0 | black | `{0,0,0}` | `{0,0,0}` | `#000000` | `{0,0,0}` |
| 1 | red | `{205,0,0}` | `{128,0,0}` | `#cc0000` | `{255,0,0}` |
| 2 | green | `{0,205,0}` | `{0,128,0}` | `#4e9a06` | `{0,255,0}` |
| 3 | yellow | `{205,205,0}` | `{128,128,0}` | `#c4a000` | `{255,255,0}` |
| 4 | blue | `{0,0,238}` | `{0,0,128}` | `#3465a4` | `{0,0,255}` |
| 5 | magenta | `{205,0,205}` | `{128,0,128}` | `#75507b` | `{255,0,255}` |
| 6 | cyan | `{0,205,205}` | `{0,128,128}` | `#06989a` | `{0,255,255}` |
| 7 | white | `{229,229,229}` | `{192,192,192}` | `#d3d7cf` | `{255,255,255}` |
| 8 | bright_black | `{127,127,127}` | `{128,128,128}` | `#555753` | `{128,128,128}` |
| 9 | bright_red | `{255,0,0}` | `{255,0,0}` | `#ef2929` | `{255,128,128}` |
| 10 | bright_green | `{0,255,0}` | `{0,255,0}` | `#8ae234` | `{128,255,128}` |
| 11 | bright_yellow | `{255,255,0}` | `{255,255,0}` | `#fce94f` | `{255,255,128}` |
| 12 | bright_blue | `{92,92,255}` | `{0,0,255}` | `#729fcf` | `{128,128,255}` |
| 13 | bright_magenta | `{255,0,255}` | `{255,0,255}` | `#ad7fa8` | `{255,128,255}` |
| 14 | bright_cyan | `{0,255,255}` | `{0,255,255}` | `#34e2e2` | `{128,255,255}` |
| 15 | bright_white | `{255,255,255}` | `{255,255,255}` | `#eeeeec` | `{255,255,255}` |

Sources:
- **xterm**: `Raxol.Style.Colors.Formats.basic_ansi_color/1` (`lib/raxol/style/colors/formats.ex:127-142`), `Raxol.Style.Colors.Color.to_ansi_16/1` inline list (`lib/raxol/style/colors/color.ex:167-200`), `Raxol.Terminal.Color.Manager.default_palette` (`packages/raxol_terminal/lib/raxol/terminal/color/color_manager.ex:10-26`), `Raxol.Terminal.ANSI.SixelPalette.initialize_base_palette/0` (`packages/raxol_terminal/lib/raxol/terminal/ansi/sixel_palette.ex:18-34`).
- **VGA/half-intensity**: `Raxol.UI.Theming.Colors.@ansi_basic_colors` (`lib/raxol/ui/theming/colors.ex:318-353`).
- **GNOME/Ubuntu Terminal**: `Raxol.Terminal.Rendering.OptimizedStyleRenderer.@style_patterns` (`packages/raxol_terminal/lib/raxol/terminal/rendering/optimized_style_renderer.ex:28-45`).
- **pure+pastel-bright**: `Raxol.LiveView.Themes.@themes.default` (`packages/raxol_liveview/lib/raxol/live_view/themes.ex:47-67`, hex flavor) and `Raxol.Terminal.Theme.Manager.new/1`'s hardcoded default (`packages/raxol_terminal/lib/raxol/terminal/theme/theme_manager.ex:104-131`, RGBA-map flavor) — two independent files landing on identical values.

The xterm and VGA conventions disagree on 9 of 16 indices. The 216-color cube compounds
this: `theming/colors.ex`'s cube (`0, 95, 135, 175, 215, 255` step values,
`lib/raxol/ui/theming/colors.ex:356-378`) is the real xterm 256-color formula; `formats.ex`'s
cube (`0, 51, 102, 153, 204, 255`, `lib/raxol/style/colors/formats.ex:74-80`, mirrored in
`packages/raxol_terminal/lib/raxol/terminal/ansi/sixel_palette.ex:36-49`) is a naive linear
split that only agrees with the real formula at the two ends. Any code resolving ANSI
256-color index 52 gets `{95,0,0}` via one path and `{51,0,0}` via the other. The 24-step
grayscale ramp (232-255, `value = (code-232)*10+8`) is the one piece all sources agree on.

### 5.2 The near-black surface value `#1E1E1E` / `rgb(30,30,30)` — 3 independent copies, currently in sync
- `Raxol.UI.Theming.Theme.default_theme/0.colors.surface` = `"#1E1E1E"` (`theme.ex:193`)
- `lib/raxol/ui/components/modal/rendering.ex:111` — `@default_surface "#1E1E1E"`, explicitly commented as intentionally matching the theme's surface color (ADR-0029) rather than a literal black
- `lib/raxol/core/accessibility/theme_integration.ex:283` — `:standard` mode background `{:rgb, 30, 30, 30}` (= `#1E1E1E` in decimal)

Three files, zero shared constant. If any one of these changes, the others silently drift.

### 5.3 Terminal chrome default polarity conflict
- `Raxol.UI.Theming.Theme.default_theme/0`: `background #000000`, `foreground #FFFFFF` (dark-on-black)
- `Raxol.Terminal.Theme.Manager.new/1`: `background {0,0,0}`, `foreground {255,255,255}` (matches Theme's polarity)
- `packages/raxol_terminal/lib/raxol/terminal/colors.ex:15-19` (`%Raxol.Terminal.Colors{}`): `foreground "#000000"`, `background "#FFFFFF"` — **inverted** (black text on white)
- `packages/raxol_terminal/lib/raxol/terminal/config/defaults.ex:77`: `cursor_color: "#ffffff"` vs. the struct's own `cursor_color: "#000000"` two files over — conflicting even within the same package for the same concept
- `packages/raxol_core/lib/raxol/core/config/config.ex:302-304`: `foreground: "#ffffff", background: "#000000", cursor: "#ffffff"` — a **third package**, a **third independent struct**, matches `Theme`'s polarity but not `raxol_terminal`'s own `Colors` struct polarity two bullet points up. Three packages, two polarities, zero shared source.

### 5.4 "Web semantic theme" conflict (Tailwind-flavored vs. Bootstrap-flavored)
See §1.5 vs §1.6 in full. Side by side:

| Token | `universal.ex` (Tailwind-derived) | `state/context.ex` (Bootstrap-derived) |
|---|---|---|
| `primary` | `#2563eb` | `#007acc` |
| `secondary` | `#6b7280` | `#6c757d` |
| `success` | `#10b981` | `#28a745` |
| `warning` | `#f59e0b` | `#ffc107` |
| `error` | `#ef4444` | `#dc3545` |
| `background` | `#ffffff` | `#ffffff` (match) |
| `surface` | `#f9fafb` | `#f8f9fa` (close but not equal) |
| `text` | `#111827` | `#212529` |

### 5.5 Bootstrap-4 fingerprint recurs independently in two unrelated files
`lib/raxol/style/colors/accessibility/palette_generator.ex:46-58` (seed colors for
`generate_accessible_palette/2`) and `lib/raxol/ui/state/context.ex:359-361` both use the
exact Bootstrap 4 semantic set `success #28a745/#28A745`, `warning #ffc107/#FFC107`,
`error #dc3545/#DC3545` (palette_generator additionally has `info #17A2B8`, link `#0066CC`).
No shared source; presumably both authors independently reached for "the standard-ish web
colors."

### 5.6 Named community themes: same theme, disagreeing UI-role assignment
`Raxol.Core.Theming.ThemeRegistry` (`lib/raxol/core/theming/theme_registry.ex`) and
`Raxol.LiveView.Themes` (`packages/raxol_liveview/lib/raxol/live_view/themes.ex`) both ship
`:dracula` and `:nord`. The 16 ANSI slot values match byte-for-byte for `:dracula` (both:
`black #21222c/#21222c, red #ff5555/#ff5555, ... bright_white #ffffff/#ffffff`). But the
**"cursor" UI-role assignment disagrees**:

| Theme | `ThemeRegistry.ui.cursor` | `LiveView.Themes.cursor` |
|---|---|---|
| dracula | `#ff79c6` (the theme's magenta/pink) | `#f8f8f2` (the theme's foreground/white) |
| nord | `#88c0d0` (the theme's cyan) | `#d8dee9` (a value ThemeRegistry calls `foreground`, not `cursor`) |

For `:nord` specifically, `ThemeRegistry.ui.foreground` (`#d8dee9`) equals
`LiveView.Themes.nord.cursor` (`#d8dee9`) — the two tables assign the *same literal value*
to *different semantic roles*. `ThemeRegistry` also has no `:light`/`:synthwave84` overlap
check needed since `LiveView.Themes.synthwave84` and `ThemeRegistry.synthwave84` were not
byte-compared in this pass (flagged for follow-up, lower priority — `synthwave84` is a less
architecturally central theme than dracula/nord).

### 5.7 WCAG-safe black/white fallback — 15+ independent occurrences
The literal pair (`"#000000"`/`"#FFFFFF"`, `Color.from_hex("#000000")`/`Color.from_hex("#FFFFFF")`,
or `:black`/`:white`) appears as a hardcoded "safe" fallback independently in:
`lib/raxol/style/colors/utilities.ex:204-205`, `lib/raxol/style/colors/system/color_system_server.ex:534`,
`lib/raxol/style/colors/accessibility/palette_generator.ex:129,148`,
`lib/raxol/style/colors/accessibility/suggester.ex:34,75-76,138-139,150-151,197,255,269` (10
occurrences in one file alone), `lib/raxol/utils/color_conversion.ex:29` (as `{0,0,0}`),
`lib/raxol/ui/theming/theme.ex:507-516` (`get_color_fallback/1`), `lib/raxol/ui/theming/selector.ex:178-179`,
`lib/raxol/protocols/theme_implementations.ex:318,346,384` (3 more occurrences),
`lib/raxol/ui/theme_resolver.ex:243-246,306,375` (default theme + 2 more fallback sites).
None of these share a constant.

### 5.8 One file, two internally-inconsistent ANSI-16 tables
`packages/raxol_liveview/lib/raxol/live_view/terminal_bridge.ex` defines **two different**
16-color lookups a few dozen lines apart, and they disagree with each other:

- `named_color_to_hex/1` (lines 753-778) — pure+pastel-bright convention: `red -> "#ff0000"`, `bright_red -> "#ff8080"` (matches `Raxol.LiveView.Themes.default` exactly; also adds aliases `gray/grey -> "#808080"`, `dark_gray/dark_grey -> "#404040"`, `light_gray/light_grey -> "#c0c0c0"`, `:default -> "inherit"`).
- `@ansi_16` (lines 781-798) — VGA/half-intensity convention: `1 => {128, 0, 0}`, `2 => {0, 128, 0}`, ... (matches `Raxol.UI.Theming.Colors.@ansi_basic_colors`, §5.1's "VGA" column, exactly).

`red` is `"#ff0000"` via one function and `{128, 0, 0}` via the other **in the same
module**. Whichever code path a given render takes silently determines which "red" the
user sees. `terminal_bridge.ex:355-360` (`@beam_css_colors`) is a third, smaller duplicate
in the same file — a byte-for-byte CSS-string re-encoding of `border_beam/colors.ex`'s
`@css_palettes` (§7), independently maintained. `tea_live.ex:147` hardcodes an inline
`style="background: #1a1a2e; color: #e0e0e0;"` that duplicates `Themes.default`'s `bg`/`fg`
instead of calling `Themes.to_css_vars(:default)`.

### 5.9 A third independent "terminal default colors" polarity
See §5.3 — `packages/raxol_core/lib/raxol/core/config/config.ex:302-304` adds a third
package's worth of hardcoded terminal fg/bg/cursor defaults, distinct from both
`raxol_terminal`'s `Colors` struct and `Raxol.UI.Theming.Theme`.

### 5.10 "Default focus color" conflict
`lib/raxol/ui/focus_helper.ex:18` — `@default_focus_style %{border: :single, border_fg: :cyan}`
vs. `lib/raxol/ui/components/focus_ring.ex:25` — `Keyword.get(opts, :color, :blue)`. Two
different components, two different ideas of what an unthemed focus indicator looks like.

---

## 6. Parallel theme-registry subsystems (structural finding, not a single value conflict)

Four separate "manage a set of named themes" subsystems coexist:

### 6.1 `Raxol.UI.Theming.Theme` + `Raxol.UI.Theming.ThemeManager`
The pervasively-used one (dozens of call sites, dozens of pinning tests). Owns §1.1-1.3.
`ThemeManager` (`lib/raxol/ui/theming/theme_manager.ex`) is pure GenServer machinery with
no hardcoded colors of its own — themes are registered into it at runtime.

### 6.2 `Raxol.Core.Theming.ThemeRegistry`
`lib/raxol/core/theming/theme_registry.ex`, 633 lines. Explicitly documents itself (moduledoc,
lines 1-39) as **"single source of truth for all Raxol themes"**, "following Chris McCord's
recommendation: one source of truth for themes that both LiveView and terminal components
can consume." Owns 10 complete, internally well-organized, non-conflicting named themes:
`synthwave84, nord, dracula, monokai, gruvbox, solarized_dark, solarized_light,
tokyo_night, one_dark, catppuccin` — each with a 4-slot `ui` map (background/foreground/cursor/selection)
and a 16-slot `colors` map. `default/0` returns `:dracula`. Despite the ambitious moduledoc,
**it is consumed by exactly one file**: `packages/raxol_terminal/lib/raxol/terminal/theme/theme_manager.ex`
(`Raxol.Terminal.Theme.Manager`, which properly delegates via `load_from_registry/2` rather
than hardcoding its own palette — the one example in this audit of a module correctly
deferring to a shared source). Nothing in `Raxol.UI.Theming.*` or `Raxol.LiveView.*` reads
from it, despite `LiveView.Themes` hand-maintaining 3 of the same 10 theme names (§5.6).

### 6.3 `Raxol.Themes`
`lib/raxol/themes.ex`, 289 lines, `BaseManager` GenServer. A **third** independent theme
system, RGB/RGBA-tuple flavored, four built-in themes (`"default"`, `"dark"`, `"light"`,
`"high_contrast"`) hardcoded in `init_manager/1` / `load_theme_from_identifier/1`
(`lib/raxol/themes.ex:94-208`):
```
"default":      background/foreground/cursor: :default (atom), selection: {128,128,128,64}
"dark":         background {0,0,0}, foreground {255,255,255}, cursor {255,255,255}, selection {64,64,64,128}
"light":        background {255,255,255}, foreground {0,0,0}, cursor {0,0,0}, selection {192,192,192,128}
"high_contrast":background {0,0,0}, foreground {255,255,255}, cursor {255,255,0}, selection {255,255,255,128}
```
Consumed by exactly one file: `lib/raxol/plugins/examples/rainbow_theme_plugin.ex`.

### 6.4 `Raxol.LiveView.Themes`
`packages/raxol_liveview/lib/raxol/live_view/themes.ex`, 5 built-in CSS-variable themes
(`default, light, nord, dracula, synthwave84`), each a flat 19-slot map (`bg, fg, cursor` +
16 ANSI names) — fully cataloged in §5.1/§5.6. Hand-maintains its own copies of 3 themes
`ThemeRegistry` (§6.2) already owns.

**Net effect**: a caller asking "what does Raxol consider the default theme" gets a
different, non-interoperable answer depending on which of these four modules they ask, and
`ThemeRegistry` — the one that explicitly tried to be the fix — isn't actually load-bearing
yet.

---

## 7. BorderBeam effect accent palettes (explicitly in scope)

`lib/raxol/effects/border_beam/colors.ex` — 7 variants (`colorful, mono, ocean, sunset,
electric, neon, matrix`), each independently encoded twice: once as ANSI atoms
(`@palettes`, `@glow_colors`, `@bloom_colors`) for terminal rendering, once as CSS hex
(`@css_palettes`, `css_glow_hex/1`, `css_bloom_hex/1`) for the LiveView/web path. The two
encodings are not derived from each other — e.g. `colorful`'s ANSI palette starts
`:bright_red` while its CSS palette starts `#ff0040` (a red-magenta, plausible but not
mechanically derived from `:bright_red`'s any of the ANSI tables in §5.1). This is
intentional per-variant art direction, not a bug, but it's exactly the kind of "two
encodings of one concept, no shared source" pattern the rest of this doc flags — noted here
for completeness since the task named this file explicitly. Full values preserved verbatim
in `Raxol.UI.Theming.Palette.effect_palette/2`.

---

## 8. Recurring conventions with no shared vocabulary (meta-finding)

Beyond literal value conflicts, the same *semantic convention* — "error is red, warning is
yellow, success/ok is green, info/running is cyan" — is reinvented independently, with no
shared constant, in at least: `lib/raxol/core/accessibility/theme_integration.ex:272-289`,
five+ playground demos (`lib/raxol/playground/demos/{vfs_demo,repl_demo,scroll_anchor_demo,
osc_ambient_demo,sparkline_demo}.ex`), `packages/raxol_sensor/lib/raxol/sensor/hud.ex:179-188`,
`packages/raxol_symphony/lib/raxol/symphony/surfaces/terminal.ex` (preflight/status colors),
and `lib/raxol/swarm/overlay_renderer.ex:156-202` (`staleness_style/1`, `quality_color/1`).
None of these call into a shared "status color" primitive, despite all encoding the same
four-way traffic-light idea. Not folded into `Palette` in this PR (the shape varies too much
— some are ANSI atoms, some are hex, some have 3 states, some have 5 — to safely collapse
into one function without a design decision), but worth a follow-up: a single
`Palette.status_color(:error | :warning | :success | :info)` would remove this whole class
of drift.

Also worth recording for completeness/rigor: `raxol_acp`, `raxol_agent`, `raxol_gateway`,
`raxol_mcp`, `raxol_plugin`, `raxol_speech`, `raxol_telegram`, and `raxol_watch` were swept
and contain **no** hardcoded color primitives of their own — they either have no rendering
surface or fully inherit theming from `raxol`/`raxol_liveview`.

---

## 9. Migration note — top call sites that should eventually point at `Raxol.UI.Theming.Palette`

Not done in this PR (out of scope — refactoring call sites is the risky, separate follow-up).
Ranked by how clearly a single primitive is duplicated with no semantic reason to differ:

1. `lib/raxol/style/colors/formats.ex:127-142` (`basic_ansi_color/1`) — read `Palette.ansi_16(:xterm)` instead of the inline list.
2. `lib/raxol/style/colors/color.ex:167-200` (`to_ansi_16/1`) — same table, second copy in the same directory; same fix.
3. `packages/raxol_terminal/lib/raxol/terminal/color/color_manager.ex:10-26` (`default_palette`) — third copy of the xterm table, different package.
4. `packages/raxol_terminal/lib/raxol/terminal/ansi/sixel_palette.ex:18-34` (`initialize_base_palette/0`) — fourth copy; also fix its 216-cube formula to match `Palette.ansi_256_cube/1` (or explicitly pick the naive variant and document why sixel wants it).
5. `lib/raxol/ui/components/modal/rendering.ex:111` (`@default_surface`) — read `Palette.near_black_surface/0` instead of a third independent `"#1E1E1E"` literal.
6. `lib/raxol/core/accessibility/theme_integration.ex:283` (`:standard` mode bg) — same value, fourth form (`{:rgb, 30, 30, 30}`); worth converting to call `Palette.near_black_surface/0` + a hex→rgb-tuple helper.
7. `lib/raxol/ui/focus_helper.ex:18-22` (`@default_focus_style`/`@default_pseudo_styles`) — currently hand-copies `Theme.default_theme/0`'s focus/disabled/active convention; should read from wherever `Theme` ends up sourcing those (or from `Palette` if that convention gets promoted there).
8. `lib/raxol/style/colors/utilities.ex:204-205` + `lib/raxol/style/colors/accessibility/suggester.ex` (10 occurrences) — replace repeated `Color.from_hex("#000000")`/`Color.from_hex("#FFFFFF")` literals with `Palette.black/0` / `Palette.white/0`.
9. `lib/raxol/ui/universal.ex:66-91` vs `lib/raxol/ui/state/context.ex:354-379` — decide (product decision, not a mechanical fix) whether the web-rendering surfaces should actually share one semantic palette; if so, `Palette.semantic_defaults(:web_tailwind)` / `(:web_bootstrap)` are both preserved so the decision can be made deliberately instead of by accident.
10. `packages/raxol_liveview/lib/raxol/live_view/themes.ex` — the 3 theme names it shares with `Raxol.Core.Theming.ThemeRegistry` (`nord`, `dracula`, `synthwave84`) should delegate to `ThemeRegistry.to_liveview_format/1` instead of hand-maintaining independent copies that have already drifted on UI-role assignment (§5.6). This is the highest-value fix in the whole inventory — it deletes an entire duplicate subsystem rather than just pointing at a shared constant — but it's also the riskiest (changes actual rendered output), hence explicitly deferred.
11. `packages/raxol_liveview/lib/raxol/live_view/terminal_bridge.ex:753-798` (`named_color_to_hex/1` + `@ansi_16`) — collapse the two internally-disagreeing tables in this one file (§5.8) into one call to `Palette.ansi_16_named/1`; lowest-risk, highest-clarity fix in this list since it's a self-contained single-file change with no cross-module coordination needed.

---

## Appendix: files read in full for this audit

`lib/raxol/ui/theming/{colors,palette_registry,salience,salience_theme,theme,theme_manager,selector,theme_behaviour}.ex`,
`lib/raxol/style/colors/{color,formats,palette_manager,system,utilities,hsl,advanced,adaptive,harmony,gradient,accessibility,persistence,hot_reload}.ex`,
`lib/raxol/style/colors/system/color_system_server.ex`,
`lib/raxol/style/colors/accessibility/{palette_generator,suggester}.ex`,
`lib/raxol/cli/colors.ex`, `lib/raxol/core/color_system.ex`, `lib/raxol/core/renderer/color.ex`,
`lib/raxol/utils/color_conversion.ex`, `lib/raxol/effects/border_beam/colors.ex`,
`lib/raxol/core/theming/theme_registry.ex`, `lib/raxol/themes.ex`,
`lib/raxol/ui/universal.ex`, `lib/raxol/ui/state/context.ex`,
`lib/raxol/core/accessibility/theme_integration.ex`, `lib/raxol/ui/focus_helper.ex`,
`lib/raxol/ui/components/modal/rendering.ex`, `lib/raxol/ui/cell_dim.ex`,
`packages/raxol_liveview/lib/raxol/live_view/{themes,terminal_bridge}.ex`,
`packages/raxol_terminal/lib/raxol/terminal/{colors,color/color_manager,color/true_color/palette,ansi/sixel_palette,rendering/optimized_style_renderer,theme/theme_manager,config/defaults}.ex`,
`packages/raxol_core/lib/raxol/core/config/config.ex`,
`lib/raxol/ui/{focus_helper,theme_resolver}.ex`, `lib/raxol/ui/components/focus_ring.ex`,
`priv/themes/Default.json` (empty scaffold — `{"name":"Default","palette":{},"ui_mappings":{}}`,
no primitives to catalog), `test/raxol/ui/theming/{salience_test,salience_theme_test}.exs`.
Plus a targeted grep sweep across the rest of `lib/` (all subdirectories) and every
`packages/*/lib/` for `#[0-9a-fA-F]{6}` and ANSI-atom style attributes — including
`raxol_sensor`, `raxol_symphony`, `raxol_payments` (real hits) and confirming
`raxol_acp`/`raxol_agent`/`raxol_gateway`/`raxol_mcp`/`raxol_plugin`/`raxol_speech`/
`raxol_telegram`/`raxol_watch` are clean (§8).
