# FTXUI (C++) — Aesthetic Dossier

**Repo:** https://github.com/ArthurSonzogni/FTXUI · **Docs:** https://arthursonzogni.github.io/FTXUI · **Author:** Arthur Sonzogni · **License:** MIT · **Tagline:** *"Functional Terminal (X) User interface"*

> Research scope: this dossier is about **vibe and identity** — which concrete FTXUI moves produce which feelings on a monospace grid. Ergonomics only appear when they double as an aesthetic device.

---

## 1. One-paragraph read on the vibe

FTXUI is the TUI library that most wants to feel like a **modern GPU-era UI toolkit that got trapped inside a terminal and decided to make the best of it.** Where most C++ terminal code reads as `mvwprintw(win, y, x, ...)` — coordinates, cursor-pushing, imperative grind — FTXUI hands you a **declarative DOM you pipe styles onto**: `text("ftxui") | bold | color(Color::Blue) | border`. The house style that falls out of this is unmistakable in screenshots: **rounded-corner panels, framed windows with inline titles, gauges and sliders, per-cell 24-bit gradients that glow across a flat grid, and menu items that slide/fade under an easing curve.** It reads *rich, boxed, and quietly animated* — the opposite of the raw scrollback aesthetic. The core identity move is that **FTXUI ported the CSS mental model — flexbox, gradients, gamma-correct color blending, an easing library — into C++ and dared the terminal to keep up.**

---

## 2. The styling philosophy: the pipe is the design language

FTXUI's aesthetic opinion is encoded in a single operator. From `elements.hpp`:

```cpp
using Decorator = std::function<Element(Element)>;

// Pipe elements into decorator together.
// -> text("ftxui") | bold | underlined
// -> underlined(bold(text("FTXUI")))
Element operator|(Element, Decorator);
Element& operator|=(Element&, Decorator);
Decorator operator|(Decorator, Decorator);   // decorators compose into decorators
```

The load-bearing design fact is the **last line**: two decorators pipe together into a *new* decorator. This means style is a first-class, nameable, reusable value — not a property you set on a widget. You can write `auto card = border | bgcolor(Color::Grey15);` and apply `card` across an app. This is the same instinct as CSS classes or Tailwind's `@apply`, expressed in C++ function composition.

**Aesthetic consequence — the "stack of adjectives" feel.** Because every decorator is `Element -> Element`, emphasis is built by *accretion*, left to right:

- `text("SAVE") | bold | color(Color::Green)` — reads **confident, single-note**.
- `text("SAVE") | bold | underlined | color(Color::GreenLight) | bgcolor(Color::Grey11)` — reads **refined, layered, "designed"**: a foreground/background pair plus one texture (underline) plus weight.
- `text("!!!") | bold | blink | inverted | underlinedDouble | color(Color::Red)` — reads **noisy, alarm-panel, ransom-note**. The grammar makes over-styling *physically easy to type*, so the line between "premium" and "gaudy" is a discipline the library will not enforce for you.

The full decorator vocabulary (from `elements.hpp`):

| Decorator | Rendered effect | Vibe it carries |
|---|---|---|
| `bold` | bright/heavy weight | primary emphasis, "this is the thing" |
| `dim` | half-intensity | **recede, deactivate, background** — FTXUI's most-used mood setter |
| `italic` | slanted (where supported) | soft aside, label, metadata |
| `inverted` | swap fg/bg | **selection / focus** — the canonical "you are here" |
| `underlined` | single underline | link-ish, tab-ish, gentle marker |
| `underlinedDouble` | ══ double underline | heavier accent, rare, "official" |
| `blink` | terminal blink | urgency / retro-alarm; almost always reads *cheap* |
| `strikethrough` | crossed out | done / invalid / diff-deletion |
| `color(Color)` | 24-bit fg | hue = identity |
| `bgcolor(Color)` | 24-bit bg | **fills the cell** — the "solid chip / badge" look |
| `hyperlink(url)` | OSC-8 clickable link | modern-terminal polish, invisible until hovered |

**The refined vs. noisy line, concretely.** FTXUI's own component defaults (see §7) converge on a three-state palette: `dim` when idle, `inverted` when focused, `bold` when active. That triad — *recede / highlight / assert* — is the tasteful spine. Refinement in FTXUI comes from **using one background fill + one weight change**, and reserving `blink`/`underlinedDouble`/`inverted`-plus-`bgcolor` for genuine state changes. Noise comes from stacking three or more texture decorators (blink+underline+strikethrough) that each fight for the same cell.

---

## 3. Color: named palettes, truecolor, and gamma-correct blending

`color.hpp` exposes four tiers, and the *choice of tier* is itself an aesthetic decision:

- **`Palette1`** — just `Default` (transparent). Enables the "inherit the terminal's own theme" look — the app disappears into the user's color scheme. Maximum restraint.
- **`Palette16`** — the named ANSI 16: `Black, Red, Green, Yellow, Blue, Magenta, Cyan, GrayLight, GrayDark, RedLight … White`. Using these reads **honest / native / retro** because they *become* whatever the user's terminal theme says red is. An app in Palette16 respects Solarized, Gruvbox, Dracula automatically.
- **`Palette256`** — a giant table of *named* xterm-256 colors: `Aquamarine1, BlueViolet, CadetBlue, Chartreuse2, CornflowerBlue, DeepPink1, DeepSkyBlue1, DarkSlateGray1…`. The naming is the tell: FTXUI wants you to pick colors like a **painter reading a Pantone book**, not like a machine indexing 0–255. This tier reads **curated, mid-2010s flat-design**.
- **Truecolor** — `Color::RGB(r,g,b)`, `Color::HSV(h,s,v)`, `Color::RGBA(...)`. This is where the "unexpectedly modern C++ tool" feeling lives: hand-mixed brand hues, exact grays like `Color::RGB(20,20,24)` for a near-black card.

**The premium detail almost nobody else bothers with — gamma-correct interpolation.** From `color.cpp`:

```cpp
Color Color::Interpolate(float t, const Color& a, const Color& b) {
  ...
  constexpr float gamma = 2.2F;
  const float a_f = std::pow(a_u, gamma);
  const float b_f = std::pow(b_u, gamma);
  ...
  return static_cast<uint8_t>(std::pow(c_f, 1.F / gamma));
}
```

FTXUI blends colors in **linear light (γ 2.2), not in raw sRGB bytes.** The felt result: gradients and color fades don't develop the muddy dark band in the middle that naïve `(a+b)/2` averaging produces. Midpoints stay luminous. This is the difference between a gradient that looks *glowing* and one that looks *dirty* — and it's a decision made for you, silently, on every fade. `Color::Blend` additionally does proper alpha compositing (`out.alpha = lhs.a + rhs.a − lhs.a·rhs.a/255`), so `RGBA` overlays read as **glass / frosted panels** rather than hard paint.

---

## 4. LinearGradient backgrounds: depth and glow on a flat grid

This is FTXUI's signature "how did a terminal do that" flourish. From `linear_gradient.hpp`:

```cpp
LinearGradient()
   .Angle(45)
   .Stop(Color::Red,   0.0)
   .Stop(Color::Green, 0.5)
   .Stop(Color::Blue,  1.0);

// shorthand
LinearGradient(Color::Red, Color::Blue);
LinearGradient(45, Color::Red, Color::Blue);
```

Applied via `bgcolor(LinearGradient{...})` (or `color(...)` for a gradient *text* fill). The renderer (`linear_gradient.cpp`) is doing real 2-D projection, per cell:

```cpp
const float dx = std::cos(gradient_.angle * degtorad);
const float dy = std::sin(gradient_.angle * degtorad);
// Project every pixel to get the color.
for (int y = box_.y_min; y <= box_.y_max; ++y)
  for (int x = box_.x_min; x <= box_.x_max; ++x)
    screen.CellAt(x, y).background_color = Interpolate(gradient_, t);
```

Every character cell is assigned its own truecolor background by projecting the cell's position onto the gradient axis. **Describe the screen:** a title bar spanning 80 columns becomes a smooth sweep from indigo at the left edge to teal at the right, each column a fraction of a hue apart, with no visible banding because of the gamma-correct interpolation. It reads as **depth and lighting** — the flat grid suddenly has a light source. Angled gradients (`.Angle(45)`) sweep diagonally, which reads as **energy / motion** even in a static frame; multi-stop gradients (`Red→Green→Blue`) read **playful / spectral / "look what I can do."**

**Where it tips from premium into gaudy.** A gradient behind *sparse foreground text* reads premium (the header-bar look). A gradient behind a *full block of body text* fights legibility and reads gaudy — the text is now sitting on 40 different background colors. The tasteful FTXUI move is gradient-as-chrome (title bars, gauges, `separatorHSelector` sliders, one hero panel) and flat-fill-as-content-area. The very existence of `separatorHSelector(left, right, unselected_color, selected_color)` — a separator that is itself a two-color gradient scrubber — shows the library treats gradients as a *structural* accent, not just decoration.

---

## 5. Flexbox: real CSS semantics, breathing layouts

FTXUI didn't approximate layout — it *ported the CSS flexbox spec*. `flexbox_config.hpp` opens with:

```cpp
/*
  This replicate the CSS flexbox model.
  See guide for documentation:
  https://css-tricks.com/snippets/css/a-guide-to-flexbox/
*/
```

Linking the CSS-Tricks flexbox guide **in a C++ header** is the clearest possible statement of design lineage: FTXUI is telling C++ developers "you already know this vocabulary from the web." The config struct exposes the full model:

- `Direction`: `Row | RowInversed | Column | ColumnInversed`
- `Wrap`: `NoWrap | Wrap | WrapInversed` — **default is `Wrap`.** That default matters: an FTXUI flexbox of chips or tags *reflows* onto multiple lines as the terminal narrows, giving the responsive "breathing" feel instead of clipping.
- `JustifyContent`: `FlexStart | FlexEnd | Center | Stretch | SpaceBetween | SpaceAround | SpaceEvenly`
- `AlignItems`: `FlexStart | FlexEnd | Center | Stretch`
- `AlignContent`: same 7 as justify, for multi-line cross-axis distribution
- `gap_x`, `gap_y` (default `0`) via `.SetGap(x, y)`

Builder style, straight from web-land: `FlexboxConfig().Set(Direction::Row).Set(Wrap::Wrap).SetGap(1,1)`.

**Aesthetic consequence.** The everyday layout primitives are `hbox` (row), `vbox` (column), `gridbox` (2-D table), `dbox` (**z-stacked layers** — overlays, modals, drop shadows), plus `hflow`/`vflow` (wrapping flexbox shorthands). The `flex`, `flex_grow`, `flex_shrink` decorators and the blank `filler()` element let panels **claim or yield space elastically**. The vibe this produces: FTXUI apps *resize gracefully*. A dashboard built with `flex` and `SpaceBetween` keeps its gutters even as the window stretches — it looks *engineered*, not hard-coded. But note the **whitespace default is tight**: `gap_x/gap_y = 0` and no default padding, so an FTXUI layout with no deliberate spacing reads **dense / packed / utilitarian**. Elegance requires you to opt into breathing room (via `separatorEmpty`, `borderEmpty`, gaps). The library's *default* tone is efficient-and-boxed; the *airy* tone is available but must be reached for.

---

## 6. Borders, separators, windows: the framed-panel house style

Nothing defines "this is an FTXUI app" in a screenshot more than **framed panels with rounded corners.** The border vocabulary (from `elements.hpp` + the verified glyph table in `border.cpp`):

| Style | Corners / edges | Vibe |
|---|---|---|
| `LIGHT` | `┌ ┐ └ ┘ ─ │` | clean, neutral, default-CAD |
| `ROUNDED` | `╭ ╮ ╰ ╯ ─ │` | **soft, friendly, modern** — and the default for `window()` |
| `HEAVY` | `┏ ┓ ┗ ┛ ━ ┃` | bold, emphatic, "this panel matters" |
| `DOUBLE` | `╔ ╗ ╚ ╝ ═ ║` | retro-DOS, Turbo-Vision, Norton-Commander nostalgia |
| `DASHED` | `┏ ┓ ┗ ┛ ╍ ╏` | tentative, draft, dotted-outline |
| `EMPTY` | invisible | reserves the frame's *space* without ink — padding by stealth |

The telling default: `Element window(Element title, Element content, BorderStyle border = ROUNDED);`. **FTXUI chose rounded corners as its resting face.** `╭─` reads warmer and more contemporary than the `┌─` most curses apps default to — it's the terminal equivalent of `border-radius: 8px`. Every stock FTXUI window inherits that softened, approachable feel unless the author overrides it.

`window(title, content)` renders the title *inline in the top border* (`┌Title──┐`), the panel-with-caption idiom that makes FTXUI dashboards look like tiling window managers. `borderStyled(BorderStyle, Color)` colors the frame independently of its content — a cyan `╭─╮` around white text reads as **an active/highlighted card**, a gray one as **inactive** — giving you focus states expressed purely through frame color.

**Separators as rhythm.** The `separator*` family (`separatorLight`, `separatorHeavy`, `separatorDouble`, `separatorDashed`, `separatorEmpty`, `separatorCharacter("·")`) lets you subdivide a panel with a *matching weight* — a heavy border around heavy separators reads coherent; mixing weights reads accidental. `separatorEmpty` is the secret whitespace tool: it inserts a blank gutter row/column, the single most effective move for turning FTXUI's dense default into something that breathes. `separatorHSelector`/`separatorVSelector` are gradient-tinted position indicators — a separator that *shows where you are* along its length.

---

## 7. Component defaults: the imprinted "house style"

FTXUI's opinion is strongest where you *don't* customize. The stock transforms (from `button.cpp` and `component_options.cpp`) imprint a consistent look on every default app:

```cpp
// Default Button
Element DefaultTransform(EntryState params) {
  auto element = text(params.label) | border;   // every button is a rounded box
  if (params.active)  element |= bold;           // pressed/active -> heavier
  if (params.focused) element |= inverted;       // focused -> fg/bg swap
  return element;
}

// Default Menu entry
if (state.focused)                       e |= inverted;   // highlight cursor row
if (state.active)                        e |= bold;       // current selection
if (!state.focused && !state.active)     e |= dim;        // everything else recedes
```

That last triad — **`dim` everything, `invert` the cursor, `bold` the active** — is the FTXUI signature. A default menu reads as a list of grayed items with one bright inverted bar sliding through them. It's legible, calm, and instantly recognizable. The `Menu` also ships `HorizontalAnimated()` / `VerticalAnimated()` presets and a `Toggle`, `Button::Animated(bg, fg)` — animation is a *first-class option on the standard widgets*, not an add-on.

Focus even reaches the **hardware cursor**: `focusCursorBar`, `focusCursorBlock`, `focusCursorUnderline`, each with a `…Blinking` variant. FTXUI will reshape the terminal's own caret (bar vs. block vs. underline) to match the focused field — a detail that makes a text input feel *native and intentional* rather than emulated.

---

## 8. Motion: an easing library most GUI toolkits would envy

FTXUI ships a full **CSS/Robert-Penner-grade easing suite** in `animation.hpp` — 10 families × In/Out/InOut = ~30 curves:

`Linear · Quadratic · Cubic · Quartic · Quintic · Sine · Circular · Exponential · Elastic · Back · Bounce` (each In / Out / InOut).

```cpp
Animator(float* from, float to = 0.f,
         Duration duration = std::chrono::milliseconds(250),
         easing::Function easing_function = easing::Linear,
         Duration delay = std::chrono::milliseconds(0));
```

Two of these curves carry real personality: **`Back`** *overshoots and settles back* (the "pop" of a modern web modal), and **`Elastic`/`Bounce`** *spring past and oscillate* (playful, toy-like). Their mere presence signals FTXUI wants motion to feel *physical*, not linear-and-mechanical. The default component animation duration is **250 ms with `QuadraticInOut`** — the same "feels right" ease-in-out and quarter-second that web transitions standardized on. An FTXUI app therefore animates at the *tempo your muscle memory expects from the browser.*

**The signature animated move — the sliding menu underline.** `MenuOption::…Animated` drives the highlight with a **leader/follower pair of animators** (`leader_function`, `follower_function`, each with its own duration/delay). The leading edge and trailing edge of the underline move on *separate* curves, so the highlight **stretches as it launches and compresses as it arrives** — a liquid, elastic slide rather than a hard jump between items. Combined with `AnimatedColorsOption` (foreground and background colors *cross-fade* on focus over 250 ms), navigating an FTXUI menu feels like operating a small, well-damped machine. Motion is opt-in per widget and driven by `RequestAnimationFrame()` (named exactly like the browser API), which **only redraws when an animation is in flight** — so idle apps stay at 0% CPU. The aesthetic payoff: FTXUI can feel *alive* without feeling *busy*.

---

## 9. Canvas: sub-cell drawing for the "graphics in a terminal" flex

`canvas.hpp` turns a character grid into a pixel surface at up to **8× vertical resolution** via braille:

- **Braille mode** — 2×4 dots per cell → each "pixel" is 1×1 at quarter-cell precision. `DrawPoint`, `DrawPointLine`, `DrawPointCircle(Filled)`, `DrawPointEllipse(Filled)`.
- **Block mode** — 2×2 half/quarter blocks per cell. Same primitive family (`DrawBlock*`).
- `DrawText(x, y, str)` to place labels into the pixel field; every primitive takes an optional `Stylizer`/`Color` for per-point coloring.

**Describe the screen:** a live CPU sparkline drawn in braille reads as a *smooth curve*, not a bar chart of `#` characters — the extra sub-cell resolution is exactly what separates "chart" from "ASCII art." Circles are round, lines are anti-jagged-ish, and with per-point color you get **glowing oscilloscope / synthwave** aesthetics inside a text window. Canvas is how FTXUI apps show game-of-life boards, audio meters, and radar sweeps that look drawn rather than typed. It's the "we have a GPU at home" move — and combined with the animation loop, it's what powers the library's `canvas_animated` demo.

---

## 10. Lineage & influences

- **React / reactive TUIs.** The README credits React and Fabien Sanglard-adjacent "reactive terminal interfaces" writing. The whole `Element = f(state)` model — *describe the tree, don't paint the cursor* — is React's core idea in C++.
- **CSS flexbox** — imported *by name and by spec link* into `flexbox_config.hpp`. FTXUI's layout vocabulary (`justify_content`, `align_items`, `gap`, `flex_grow`) is CSS's, deliberately, so web devs feel at home. This mirrors what **Lip Gloss** (Go) and **Textual** (Python) did — borrowing web/CSS terms to signal "modern layout." FTXUI is the C++ member of that cohort.
- **Web animation** — `RequestAnimationFrame`, 250 ms defaults, `QuadraticInOut`, a Penner easing set: the timing culture of the browser, transplanted.
- **Turbo Vision / DOS TUIs** — the `DOUBLE` border and framed-`window()` idiom nod back to the Borland/Norton era, but softened by making `ROUNDED` the default.
- **The three-module architecture** (`screen` → `dom` → `component`) mirrors the browser stack: raster surface → DOM/layout → interactive widgets. The naming (`dom`, `Element`, `Decorator`, `Node`) is web-native on purpose.

---

## 11. What FTXUI makes *easy* vs *hard* (its aesthetic will)

**Easy (therefore what FTXUI apps look like):**
- Rounded framed panels with inline titles → tiling-WM dashboard look.
- Piling on emphasis via `| bold | color | border` → richly styled text everywhere.
- 24-bit gradients and gamma-correct fades → glowing headers/gauges.
- Responsive reflowing layouts (flexbox, `flex`, wrapping default) → resize-graceful UIs.
- Smooth eased animation on stock widgets → the "alive" menu/button feel.
- Braille charts → real-looking graphics.

**Hard (therefore rare in FTXUI apps):**
- **Generous whitespace.** Zero default gaps/padding means airy designs require deliberate `separatorEmpty`/`borderEmpty`/gap work. The path of least resistance is *dense*.
- **Restraint.** The pipe grammar makes over-decoration trivially typeable; the library won't stop you stacking blink+inverted+underline.
- **Fully theme-native minimalism.** Possible via `Palette1`/`Palette16`, but the whole feature-set *pulls toward* truecolor and gradients — the gravity is toward "rich," not "spare."

**Net house tone:** *modern, boxed, richly-colored, gently animated, engineered-feeling — dense by default, glowing when it wants to be.* FTXUI's gift to C++ is that a terminal tool can look like it shipped in 2020s web design language; its trap is that the same ease makes the gaudy version equally one pipe away.

---

## 12. Notable quotes & sources

- **README / docs, on intent:** *"Simple and elegant syntax (in my opinion)"* and *"Functional style. Inspired by … React."* — https://github.com/ArthurSonzogni/FTXUI
- **`elements.hpp`, on the pipe:** *"Pipe elements into decorator together. For instance the next lines are equivalents: `text("ftxui") | bold | underlined` -> `underlined(bold(text("FTXUI")))`."*
- **`flexbox_config.hpp`, on lineage:** *"This replicate the CSS flexbox model. See guide for documentation: https://css-tricks.com/snippets/css/a-guide-to-flexbox/"*
- **`linear_gradient.hpp`:** *"A class representing the settings for linear-gradient color effect … `.Angle(45).Stop(Color::Red, 0.0).Stop(Color::Green, 0.5).Stop(Color::Blue, 1.0)`."*
- **`color.cpp`, gamma:** `constexpr float gamma = 2.2F;` in `Color::Interpolate` — perceptual, linear-light blending.
- **`border.cpp`, verified glyphs:** ROUNDED = `╭ ╮ ╰ ╯`, DOUBLE = `╔ ╗ ╚ ╝`, HEAVY = `┏ ┓ ┗ ┛`.
- **`animation.hpp`:** full easing family incl. `Elastic`, `Back`, `Bounce`; `Animator` default 250 ms.

### Links
- GitHub repo: https://github.com/ArthurSonzogni/FTXUI
- Documentation home: https://arthursonzogni.github.io/FTXUI/
- Live WebAssembly examples: https://arthursonzogni.github.io/FTXUI/examples/
- Color gallery example: https://arthursonzogni.com/FTXUI/doc/examples_2dom_2color_gallery_8cpp-example.html
- Linear gradient gallery: https://arthursonzogni.com/FTXUI/doc/examples_2component_2linear_gradient_gallery_8cpp-example.html
- Animated underline menu demo: https://arthursonzogni.github.io/FTXUI/examples/?file=component/menu_underline_animated_gallery
- Animated button styles: https://arthursonzogni.github.io/FTXUI/examples/?file=component/button_style
- DeepWiki architecture writeup: https://deepwiki.com/ArthurSonzogni/FTXUI
- Awesome-TUIs listing: https://github.com/rothgar/awesome-tuis
