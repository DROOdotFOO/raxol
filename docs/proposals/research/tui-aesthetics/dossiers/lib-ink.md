# Ink — React for CLIs (JavaScript/TypeScript)

> "React for interactive command-line apps." Yoga (Flexbox) + React reconciler,
> rendering to a monospace grid. The library that made the modern JS-CLI *look*
> a thing: gradient wordmarks, round-bordered panels, blue braille spinners.

- Repo: https://github.com/vadimdemedes/ink
- Component kit: https://github.com/vadimdemedes/ink-ui
- Author: Vadim Demedes (@vadimdemedes)
- Ecosystem: ink-gradient, ink-big-text, ink-spinner, ink-link, ink-box, ink-table
- In production: Claude Code, GitHub Copilot CLI, Gatsby, Prisma, Cloudflare
  Wrangler, Vercel, Shopify CLI, Terraform CDK, npm's own `create-*` flows.

---

## 1. The one-sentence aesthetic thesis

Ink's aesthetic opinion is a *category import*: **it makes the terminal behave
like the browser box model, so web designers' muscle memory transfers wholesale.**
Everything downstream — the "installer/onboarding" feel, the boxed cards, the
gutter rhythm — flows from one decision: *every element is a flex container.*

From the docs, verbatim:

> "Ink uses Yoga to build Flexbox layouts in the terminal, so you can use similar
> CSS-like props you already know."

> "Each element is a Flexbox container. Think of it as if every `<div>` in the
> browser had `display: flex`."

That sentence is the whole vibe. In a raw terminal you think in cursor moves and
columns; in Ink you think in `flexDirection`, `padding`, `gap`, `justifyContent`.
The **medium's native logic (character cells) is hidden under web logic (boxes)**,
and that substitution is what gives Ink-built tools their recognizable "a designer
touched this" polish versus the raw-`printf` look of classic Unix tools.

---

## 2. Layout as aesthetic — Yoga/Flexbox vocabulary

### The `<Box>` primitive

`<Box>` is a flex container. Its prop surface is deliberately a near-1:1 mirror of
CSS flexbox, and the naming *is* the design statement — the API teaches you to
think in web layout terms:

- **Direction/flow:** `flexDirection` (`row` | `column`), `flexGrow`,
  `flexShrink`, `flexBasis`, `flexWrap`
- **Alignment:** `justifyContent` (`flex-start`/`center`/`space-between`/…),
  `alignItems`, `alignSelf`
- **Spacing:** `gap`, `padding` (+ `paddingX`/`paddingY`/`paddingTop`…),
  `margin` (+ `marginX`/`marginY`/…)
- **Sizing:** `width`/`height` (integers = cells, or `"50%"` percentages),
  `minWidth`/`maxWidth`, `aspectRatio`
- **Borders:** `borderStyle`, `borderColor`, plus per-edge `borderTop`,
  `borderLeft`, and Ink 4's per-edge `borderTopColor`, `borderDimColor`.

**Which technique → which feeling.** Because `gap`, `paddingX`, and
`flexDirection="column"` are one keystroke each, the *path of least resistance* is
a **column of evenly-guttered cards** — exactly the layout of a web onboarding
wizard. The default output of "just throw components in a Box" already looks
groomed. Contrast a hand-rolled bash script, where alignment is manual and
therefore usually skipped: Ink's flex defaults make *tidy* the lazy option, and
tidy reads as *trustworthy / professionally made*.

**Describe the screen.** A `create-app` scaffolder built in Ink typically renders:
a full-width column, `gap={1}` between rows so every block breathes with one blank
line, a round-bordered panel pinned near the top holding the wordmark, then a
left-aligned checklist marching down the column, each row `paddingLeft`-indented
so the glyph gutter lines up like a form. Nothing touches the screen edges; the
whitespace margins say "this is a considered layout, not console spew."

### `<Spacer>`, `<Newline>`, `<Static>`

- `<Spacer>` = `flex-grow: 1` filler → pushes siblings apart (title left, status
  right on one row). The **justified header bar** feel of a polished TUI.
- `<Static>` renders content **once, above** the live region and never repaints it
  — this is the technique behind the "permanent scrollback log of completed steps
  + a live spinner at the bottom" pattern (Gatsby/Jest look). Aesthetically it
  creates a **two-zone screen**: an immutable *history* that scrolls up into the
  terminal buffer, and a *live cockpit* that mutates in place. That split is what
  makes long installs feel like a *progress narrative* rather than a wall of text.

---

## 3. Borders & boxes — where weight sets formality

Ink's border presets come from Sindre Sorhus's `cli-boxes` module. Ink 3 shipped
**7 border styles**; the author frames them as pure delight:

> "Boxes can have stylish borders now! … there are 7 border styles in total, so
> you can pick the one you like the most." — Vadim Demedes, *Ink 3*

The presets and the tone each sets:

| `borderStyle` | Glyphs (corners) | Vibe it produces |
|---|---|---|
| `single` | `┌ ┐ └ ┘ │ ─` | Neutral, default-serious. The "form field" look. |
| `double` | `╔ ╗ ╚ ╝ ║ ═` | Retro/DOS, "system panel," heavier authority. Nostalgic BBS energy. |
| `round` | `╭ ╮ ╰ ╯ │ ─` | **The modern-JS-CLI signature.** Soft, friendly, "designed." ink-ui's Alert uses it by default. |
| `bold` | `┏ ┓ ┗ ┛ ┃ ━` | Emphatic, alert, "look here." Heavier ink = higher priority. |
| `singleDouble` | single sides, double top/bottom | Quirky, asymmetric, decorative. |
| `doubleSingle` | double sides, single top/bottom | As above, transposed. |
| `classic` | `+ + + + | -` ASCII | Deliberately retro/plain, max-compat, "teletype" nostalgia. |

**Rounded corners are the tell.** The single most identifiable move of the "Ink
look" is `borderStyle="round"` in a bright accent color with `paddingX={1}`. The
`╭─╮` corners soften the grid's hard geometry the way `border-radius` softens a web
card; combined with color it reads as *contemporary and approachable* rather than
*mainframe*. The canonical example even ships in the readme — the update-available
nag box:

```jsx
<Box borderStyle="round" borderColor="green" paddingX={1} flexDirection="column">
  <Text color="green">New version is available!</Text>
  <Text>Run <Text color="blue">npm i -g my-cli</Text> to update</Text>
</Box>
```

`paddingX={1}` (one cell of breathing room inside the border) is doing quiet but
essential work: text jammed against a border reads cramped/amateur; one column of
inset reads *calm and intentional*. Border weight is a **formality dial** — hairline
`single`/`round` = light & modern, `double`/`bold` = heavy & official.

---

## 4. Text styling & the Chalk palette

`<Text>` carries the type-styling vocabulary, backed by Chalk:

- **Color:** `color` / `backgroundColor` — named 16-color (`green`, `cyan`…), hex
  (`#ff8800`), or `rgb()`. Truecolor where the terminal supports it.
- **Weight/emphasis:** `bold`, `italic`, `underline`, `strikethrough`
- **Dim/inverse:** `dimColor` (lowers luminance — the workhorse for *secondary*
  text), `inverse` (swap fg/bg — instant "selected/highlight chip")
- **Wrapping:** `wrap` = `wrap` | `truncate` | `truncate-start` | `truncate-middle`
  | `truncate-end`

**`dimColor` is the whole typographic hierarchy.** The terminal has no font sizes,
no font weights beyond bold, no gray-scale of type. Ink's ecosystem leans on
`dimColor` to manufacture a **two-tier hierarchy** — bright = primary, dim =
metadata/hint — which is exactly what a web designer would do with `color: #999`.
ink-ui's ProgressBar uses `dimColor` for the *unfilled* track and UnorderedList
uses it for the bullet markers, so the eye reads the content as foreground and the
scaffolding as background. That figure/ground separation is what stops a dense TUI
from looking like undifferentiated noise.

**`inverse` = the selection chip.** Flipping fg/bg on a single word paints a solid
colored block behind it — the terminal's only "button/pill." It signals *this cell
is active/selected* with zero extra glyphs.

### `<Transform>` — per-character effects

`<Transform>` takes a function `(output, index) => string` and rewrites the final
rendered string char-by-char. This is Ink's escape hatch for effects the box model
can't express: gradient tints, per-character color cycling, hyperlink wrapping,
zebra-striping. It's *the* seam between "declarative React layout" and "raw ANSI
tricks," and it's what libraries like ink-gradient are built on. Aesthetically it
enables **texture** — the difference between flat blocks of color and text that
*shimmers*.

---

## 5. Signature flourishes — the brand splash

### ink-big-text — figlet wordmarks

Wraps `cfonts` to render **giant ASCII-art wordmarks**. Fonts: `block`,
`simpleBlock`, `simple`, `3d`, `simple3d`, `chrome`, `huge`, `shade`, `grid`,
`pallet`, `tiny`. This is the terminal's answer to a logo: where a plain shell shows
a filename, Ink shows a **six-rows-tall name in block letters** on startup.

> "Awesome text component for Ink." — ink-big-text readme

The vibe: a big-text splash is a **territory claim**. It says "this is a Product,
not a script." It borrows the ceremony of a desktop-app splash screen. The block
letters fill vertical space the way a hero banner fills a landing page.

### ink-gradient — rainbow/pastel text

Applies a color gradient **character-by-character** across text. Built-in presets:
`rainbow`, `pastel`, `cristal`, `teen`, `mind`, `morning`, `vice`, `passion`,
`fruit`, `instagram`, `atlas`, `retro`, `summer` — plus custom `colors={[...]}`.

The canonical combo — and the single most-copied snippet in the ecosystem:

```jsx
<Gradient name="rainbow">
  <BigText text="unicorns" />
</Gradient>
```

**When it reads delightful vs. try-hard.** The `ink-big-text` + `ink-gradient`
"rainbow wordmark on boot" is the ecosystem's most recognizable — and most
polarizing — gesture.
- *Delightful* when: shown once, at startup, in a `pastel`/`vice`/`morning`
  gradient (soft, low-saturation ramps read as "designed"), sized to fit, then
  gone. It's a *greeting* — momentary warmth, like a friendly hello.
- *Try-hard* when: `rainbow` (max saturation, full spectrum) on every subcommand,
  or persisting during work. Continuous rainbow reads as *toy*, undermines the
  authority a `bold` red error later needs. The gradient's charm is inversely
  proportional to its dwell time.

The deeper pattern: gradients smuggle **analog continuity** (a smooth hue ramp)
onto a **discrete grid**. That tension — smoothness where you expect blockiness —
is precisely the delight, and precisely why overuse cheapens it.

### ink-link — hyperlinks

Emits OSC-8 terminal hyperlinks so a word is *clickable* (falls back to showing the
URL). The vibe: **hypertext affordance in a text-only medium** — a tiny signal that
the tool lives in the modern (iTerm/Kitty/VSCode-terminal) world.

---

## 6. ink-ui — the house style, encoded

ink-ui is the *shipped* component library, and its `theme.ts` files are the
clearest statement of the "Ink house look" because they hard-code the defaults
every app inherits. The theming model itself is telling:

> "Each field in styles object is a function; it can return different styles based
> on the props that were passed in or a state of a component."

Themes have two halves: **`styles`** (functions returning Ink `TextProps`/`BoxProps`)
and **`config`** (non-visual, e.g. which glyph a list marker uses). You reskin via
`extendTheme(defaultTheme, {...})` + `<ThemeProvider>`, and custom components read
theirs with `useComponentTheme`. The design thinking: **style is a pure function of
state**, so a focused/selected/error state is just a different return value — the
same discipline as a CSS-in-JS `styled(props => …)`.

### The semantic color law (verbatim from source)

Both Alert and StatusMessage encode the exact same mapping:

```js
const colorByVariant = { info: 'blue', success: 'green', error: 'red', warning: 'yellow' };
```

This is the **traffic-light tone system** made canonical: green=go/done,
yellow=caution, red=stop/error, blue=neutral/info. Because it's baked into the
default theme, *every* ink-ui app speaks the same emotional color language — you
learn it once and it's true across tools. That consistency is itself an aesthetic:
**predictable = calm**.

### Default glyphs (from `figures`, verbatim from source)

ink-ui pulls its symbols from `figures` (Unicode with ASCII fallbacks for old
terminals — so the look degrades gracefully rather than mojibake-ing):

| Component | Element | Glyph | `figures` name |
|---|---|---|---|
| Alert / StatusMessage | success | `✔` | `tick` (green) |
| " | error | `✖` | `cross` (red) |
| " | warning | `⚠` | `warning` (yellow) |
| " | info | `ℹ` | `info` (blue) |
| Select / MultiSelect | focus pointer | `❯` | `pointer` (blue) |
| Select / MultiSelect | selected | `✔` | `tick` (green) |
| UnorderedList | bullet marker | `─` | `line` (dimColor) |
| ProgressBar | completed | `◼` | `square` (magenta) |
| ProgressBar | remaining | `░` | `squareLightShade` (dimColor) |

**Reading these defaults as a mood board:**

- **Spinner** frame color = `blue`. Not red, not green — a calm, neutral "working"
  hue. Blue says *in progress, no news*, reserving green/red for outcomes.
- **ProgressBar** = magenta filled `◼` against a dim `░` track. Magenta is an
  unexpected, playful accent (not the obvious green) — a small personality choice
  that reads as *modern/creative* rather than *enterprise*. The `◼`-vs-`░` pair
  gives the bar **texture and depth** (solid foreground marching over a ghost
  track) instead of a flat `[####----]`.
- **Badge** = colored `backgroundColor` with `color: 'black'` label — a solid
  **pill/chip**, exactly like a web status badge. Inverse-video as branding.
- **UnorderedList** marker = a dim `─` (horizontal dash), not the classic `•`
  bullet or `*`. The thin dim dash is quieter, more editorial — it recedes so the
  content leads. A deliberately *understated* list.
- **Select** focus uses the `❯` pointer in blue and shifts padding
  (`paddingLeft: isFocused ? 0 : 2`) so the focused row **juts left** into the
  gutter — motion-by-indentation, a subtle "this one" nudge without a heavy
  highlight bar.
- **Alert** container defaults: `borderStyle: 'round'`, variant-colored border,
  `gap: 1`, `paddingX: 1`, a bold title. That's the *entire* "modern CLI callout"
  look specified in ~10 lines — round border + accent color + inset + icon gutter.

### Describe the screen — an ink-ui form

A prompt built from ink-ui reads like a tidy web form transplanted to text: a
column with `gap:1` between fields; each `Select` option indented two cells, the
active one pulled flush-left and prefixed with a blue `❯`, its label re-colored
blue; a green `✔` marks what's already chosen. Below, a magenta progress bar fills
left-to-right over a dim track. On error, a round red-bordered Alert slides in with
a red `✖` in its left icon column and a bold title. Every color is doing semantic
work; nothing is decorative-only. The overall feeling: **quiet competence** — the
CLI equivalent of a clean Stripe-dashboard form.

---

## 7. Motion — the React reconciler as animation engine

Ink's most structurally interesting aesthetic move: **animation is just React
state + re-render.** You `setState` on an interval; React reconciles; Ink diffs and
repaints only changed cells. There's no animation API to learn — the same
`useState`/`useEffect` that drives a web component drives terminal motion.

- **Spinners:** ink-spinner cycles `cli-spinners` frames. The default `dots` is the
  braille ramp `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` at an 80ms interval. Braille dots are
  sub-character-resolution — they animate *within* a single cell, so the motion is
  smooth and small, reading as *alive but unobtrusive*. (Ink 4 added a first-party
  `useAnimation`/`interval`+`frame` hook for exactly this indexed-frame pattern.)
- **Gradient cycling / text animation** (ink-text-animation): shifting the gradient
  offset each tick makes color *flow* across a wordmark — shimmer, pulse, neon.
- **Progress:** re-rendering the fill character count each tick = a bar that grows.

**What continuous motion signals.** A steadily spinning braille spinner is a
**liveness proof** — "the process is alive, not hung." Its *smoothness and framerate*
are read as *polish*: a janky, stuttering spinner reads as a rough tool; a buttery
80ms braille cycle reads as *engineered*. Motion is the terminal's only way to say
"I'm working on it," and Ink makes that motion cheap enough that even one-off
scripts get it — which is why the animated spinner became the ambient signature of
the whole modern-JS-CLI genre. The flip side: because Ink repaints declaratively,
**stillness is also expressive** — a screen that stops moving reads as *done/idle*,
so the transition spinner→static-checkmark is a satisfying "completed" beat.

---

## 8. Lineage & influences

- **Upstream idea:** React's declarative reconciler + a custom renderer. Ink is to
  the terminal what React-DOM is to the browser and React-Native is to mobile —
  same tree, different backend. The insight: if React can render to any host, the
  terminal is just another host.
- **Yoga (Facebook's Flexbox engine):** the same C++ layout engine behind React
  Native. Adopting it is the decision that imports *web layout intuition* wholesale
  — the aesthetic is inherited from CSS, not invented for the terminal.
- **The Sindre Sorhus micro-package cosmos:** `chalk` (color), `cli-boxes`
  (borders), `cli-spinners` (spinner frames), `figures` (symbols+fallbacks),
  `cfonts`/figlet (big text), `gradient-string` (gradients). Ink doesn't invent its
  visual atoms — it *composes the existing npm CLI-aesthetics toolbox* into a React
  component model. The "Ink look" is really the "sindresorhus CLI look" given a
  declarative API.
- **Sibling in the wider TUI world:** the same "borrow web/CSS vocabulary" impulse
  shows up in Charm's **Lip Gloss** (Go, CSS-like `Border`/`Padding`/`Align`) and
  **Textual** (Python, literal CSS files + a DOM). Ink is the JS/React branch of a
  cross-language convergence: *make the terminal legible to web designers by
  speaking CSS.*
- **Downstream reach:** because Gatsby, Prisma, Cloudflare Wrangler, Shopify CLI,
  Vercel, GitHub Copilot CLI, and Claude Code all render through Ink, its defaults
  (round borders, blue spinner, traffic-light status colors, gradient boot splash)
  have become the *de facto house style of the JS ecosystem's command line* — the
  thing users now unconsciously expect a "good" CLI to look like.

---

## 9. What Ink makes EASY vs HARD (its aesthetic opinion)

A library's aesthetic *is* its gradient of least resistance:

**Easy (therefore common, therefore "the Ink look"):**
- Column-of-cards layouts with even `gap` gutters → onboarding-wizard feel
- Round-bordered accent-colored panels → modern-callout feel
- Two-tier hierarchy via `dimColor` → clean figure/ground
- Semantic traffic-light status (green/yellow/red/blue) → calm predictability
- Animated braille spinner + static-log split → progress-narrative feel
- Gradient big-text boot splash → product-launch ceremony

**Hard (therefore rare in Ink apps):**
- Precise cell-level cursor art / character-mosaic imagery (you're fighting the box
  model; you drop to `<Transform>` or raw ANSI)
- Dense data grids with perfect column alignment across variable content (flexbox
  helps but there's no true `<table>`; ink-table is a bolt-on)
- Reflowing full-screen TUIs that repaint at high frame rates over slow SSH
  (declarative diffing is convenient but not the tightest possible byte stream)
- Anything that *wants* the raw-teletype, no-chrome Unix aesthetic — Ink's defaults
  are so groomed that "deliberately plain" takes effort (use `classic` borders,
  drop the splash).

The takeaway: **Ink pushes every app toward "tidy, boxed, gently branded,
gently animated."** That homogenizing pull is its gift (any dev ships a
designed-looking CLI) and its tell (a certain sameness across Ink tools — you can
often *spot* an Ink app by its round borders and blue spinner).

---

## 10. Notable quotes

- "Ink uses Yoga to build Flexbox layouts in the terminal, so you can use similar
  CSS-like props you already know." — Ink readme
- "Think of it as if every `<div>` in the browser had `display: flex`." — Ink docs
- "Boxes can have stylish borders now! … there are 7 border styles in total, so you
  can pick the one you like the most." — Vadim Demedes, *Ink 3*
- "People loved using React to declaratively build UIs for their command-line
  apps." — Vadim Demedes, *Ink 3*
- "Each field in styles object is a function; it can return different styles based
  on the props that were passed in or a state of a component." — ink-ui theming docs
- `{ info: 'blue', success: 'green', error: 'red', warning: 'yellow' }` — ink-ui
  `colorByVariant`, the encoded tone system (Alert + StatusMessage source)

---

## 11. Sources

- Ink repo/readme — https://github.com/vadimdemedes/ink
- ink-ui repo — https://github.com/vadimdemedes/ink-ui
- ink-ui theme source (badge/alert/spinner/select/progress-bar/unordered-list) —
  https://github.com/vadimdemedes/ink-ui/tree/main/source/components
- "Ink 3" release post (author) — https://vadimdemedes.com/posts/ink-3
- ink-gradient — https://github.com/vadimdemedes/ink-gradient
- ink-big-text — https://github.com/vadimdemedes/ink-big-text
- ink-spinner — https://github.com/vadimdemedes/ink-spinner
- cli-spinners (default `dots` frames) — https://www.npmjs.com/package/cli-spinners
- figures (symbols + fallbacks) — https://github.com/sindresorhus/figures
- cli-boxes (border presets) — https://github.com/sindresorhus/cli-boxes
