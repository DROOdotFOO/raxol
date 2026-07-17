# The Charm Ecosystem — Lip Gloss · Bubbles · Bubble Tea · Gum · Huh · Glamour

> "We make the command line glamorous." — charm.land tagline

The single strongest house style in the TUI world. When someone says a CLI "looks
modern" in 2026, they almost always mean it looks like Charm: rounded borders, a
magenta→violet color signature, generous interior padding, adaptive light/dark
hues, and a spinner that has *personality*. Charm's decisive move was to import
**CSS's separation of structure from style** into the terminal (Lip Gloss), then
**package that style as copy-paste defaults** (Gum, Huh) so that even an unstyled
shell script inherits the vibe for free. This dossier maps which concrete moves
produce which feelings.

---

## 0. The thesis, in one screen

Picture a `gum choose` menu dropped into a bare `bash` script. Before Charm, that
was a `select` loop: white-on-black, a numbered list, `1) 2) 3)`, a `#?` prompt.
Ugly, functional, *retro-by-neglect*. Charm's version of the same three lines
renders a vertical list where the focused row is painted **hot pink (#FF06B7 /
ANSI 212)** with a `> ` caret, unselected rows dim to gray, and there's a blank
cell of breathing room around the whole thing. Nothing about the *task* changed.
Everything about the *feeling* changed — from "I am configuring a machine" to
"someone designed this for me." That gap, manufactured entirely from color choice,
one glyph, and whitespace, is the entire Charm aesthetic in miniature.

Charm's insight: **taste can be a default.** Most TUI toolkits give you a palette
and wish you luck. Charm ships an *opinion* — a specific pink, a specific purple, a
rounded border, a 1-cell rhythm — and makes the opinionated path the path of least
resistance. The house style is not enforced; it's just *easier than anything else*.

---

## 1. Lineage & influences

- **Elm → Bubble Tea.** The runtime is a straight port of **The Elm Architecture**:
  `Model` (state) / `Update` (events → new state) / `View` (state → string). The
  aesthetic consequence is subtle but real: because the whole UI is a *pure
  function of state*, redraws are cheap and total, which makes **motion** (spinners,
  progress, transitions) trivial to express. A framework that makes animation easy
  produces apps that animate. The Elm lineage is *why* Charm apps feel alive.
- **CSS → Lip Gloss.** Lip Gloss is explicitly "for users familiar with CSS." It
  borrows the **box model** (margin / border / padding / content), CSS shorthand
  ordering (`Padding(1,2)` = vertical, horizontal; four-value = clockwise-from-top),
  `Align`, `Width`/`Height`, inheritance, and even `MaxWidth`. Naming *is* design
  thinking: by speaking CSS, Lip Gloss tells web developers "your layout instincts
  transfer," and it imports web design's airy, padded sensibility wholesale.
- **The mascot tradition.** Every tool has a whimsical creature and a one-line
  brag: Bubble Tea = "the fun, functional and stateful way to build terminal apps";
  Glow = "read markdown on the CLI…with pizzazz!"; Gum = "a tool for glamorous shell
  scripts"; Crush = "your new coding bestie." The *copy voice* — glamorous,
  fashionable, happy, pizzazz — is itself a design device: it primes the user to
  expect delight, and the software cashes the check.

The recurring descriptor set — **glamorous, fashionable, powerful, magical, smooth,
happy, pizzazz** — is the anti-corporate vocabulary. No "enterprise," no "robust,"
no "solution." That word choice is a deliberate positioning against the beige
seriousness of legacy CLI tooling.

---

## 2. The signature palette — why pink/purple reads "friendly premium"

Charm's colors are not random. Two hue families recur across nearly every demo,
README, and default theme:

| Role | Hex | ANSI-256 | Where it shows up |
|---|---|---|---|
| **Brand pink** | `#FF06B7` | ~`212` | Logo, `gum` default cursor/selection, hero accents |
| **Hot pink (active)** | `#F25D94`, `#FF5F87` | `212`, `205` | Active buttons, status indicators, focused rows |
| **Charm purple** | `#7D56F4` | `99` | The canonical README quickstart color; primary highlight |
| **Purple (light-bg)** | `#874BFD`, `#A550DF`, `#643AFF` | — | Adaptive highlight variants, gradient anchors |
| **Mint / success** | `#43BF6D`, `#73F59F`, `#04B575` | — | Success states, "special" elements |
| **Cream / paper** | `#FFF7DB`, `#FFFDF5`, `#FAFAFA` | — | Button text, title text (never pure white) |

**The vibe mechanics:**

- **Magenta→violet is the "friendly premium" axis.** Blue reads corporate/trust;
  green reads finance/terminal-hacker; red reads danger. Magenta and purple are
  *rare* in tooling, associated with creativity, cosmetics ("lip gloss," "glamorous"),
  and play. Choosing the least-used quadrant of the color wheel is how a CLI signals
  "I am not IBM." The pink is warm enough to read *approachable*, saturated enough
  to read *deliberate* — the combination is what "premium but fun" looks like.
- **Never pure white text.** Charm's light text is `#FFF7DB` / `#FFFDF5` — a warm
  cream, not `#FFFFFF`. That 1% warmth is imperceptible as "a color" but perceptible
  as *comfort*; the screen stops feeling like a fluorescent-lit spreadsheet.
- **Gradients as emotional pacing.** `Blend1D` / `Blend2D` and
  `BorderForegroundBlend` let a border or fill sweep from `#EDFF82` (yellow) through
  to `#14F9D5` (cyan) or `#643AFF` (violet). A solid color says "state"; a *gradient*
  says "this was fussed over." Progress bars fill with a gradient specifically so the
  bar's growth doubles as a mood curve — the eye reads left-to-right warm-to-cool as
  forward motion.

### AdaptiveColor / CompleteColor as *taste*, not just compatibility

This is Charm's most quietly radical idea. Terminals have a background color the app
can't control. A hardcoded `#333` looks sharp on white and vanishes on black.
Lip Gloss's answer:

```go
lightDark := lipgloss.LightDark(lipgloss.HasDarkBackground(os.Stdin, os.Stdout))
c := lightDark(lipgloss.Color("#D7FFAE"), lipgloss.Color("#D75FEE")) // light-bg, dark-bg
```

`AdaptiveColor{Light, Dark}` picks a *different hue* depending on the terminal's
background. `CompleteColor` goes further — you specify the exact value for
`TrueColor`, `ANSI256`, and `ANSI` (16-color) profiles, and Lip Gloss picks the one
matching the detected terminal, then **auto-downsamples** (and strips color entirely
when piped to a non-TTY).

The *marketing* of this is the tell: it is sold not as "compat glue" but as
**tailoring**. The vibe produced is "this app noticed my setup and dressed for it."
An app that renders a considered lavender on your dark solarized theme *and* a
considered plum on your colleague's light terminal feels bespoke — the way a
responsive website that reflows for your phone feels like it was built for you
specifically. Degradation-as-taste: even on a 16-color TTY you get *a* deliberate
color, never a broken one.

---

## 3. Lip Gloss box model — the airy signature

If the palette is Charm's *color* signature, **whitespace and borders** are its
*spatial* signature. Dense retro TUIs (htop, midnight commander, ncurses classics)
pack every cell — information density as a value. Charm does the opposite: it treats
**empty space as a material**.

### Borders: which weight sends which mood

Lip Gloss ships these border presets (`lipgloss.<X>Border()`):

| Preset | Glyphs (corners) | Mood it sends |
|---|---|---|
| **RoundedBorder** | `╭ ╮ ╰ ╯` | Soft, friendly, contemporary. **The Charm default vibe.** Rounded corners are the single most recognizable Charm tell — they read as "app," not "terminal." |
| **NormalBorder** | `┌ ┐ └ ┘` | Neutral, clean, unremarkable — the "off" position. |
| **ThickBorder** | `┏ ┓ ┗ ┛` | Emphatic, bold, "this box matters." Weight = importance. |
| **DoubleBorder** | `╔ ╗ ╚ ╝` | Retro/formal, DOS-era gravitas — used deliberately for a *vintage* accent (note `gum style --border double`). |
| **HiddenBorder** | (spaces) | Invisible border that still reserves the cells — pure spacing trick to align without a visible line. |
| **ASCIIBorder** | `+ - |` | Maximum-compat fallback; reads "plain/old" on purpose. |
| **MarkdownBorder** | `| -` table pipes | For rendering tables that look like GitHub markdown. |

Rounded is the mood-setter. The difference between `┌────┐` and `╭────╮` around a
prompt is the difference between a *dialog box on a mainframe* and a *card in a
modern app*. It costs nothing — same cell count — but the curved corner glyph is
doing the entire "this is 2020s software" signal by itself. Custom borders (a
`Border` struct of eight edge strings) let authors invent glyph motifs (Charm's own
examples include a `.-.:*:` "cute" border), but the default *ambition* everyone
copies is rounded.

**Gradient borders** (`BorderForegroundBlend(c1, c2)`) sweep the border's color
along its perimeter — a frame that fades pink→purple. This is the "premium chrome"
move: the border stops being a boundary and becomes decoration.

### Padding & margin: the 1-cell rhythm

Lip Gloss defaults nothing (padding 0), but every Charm demo, and Gum's/Huh's
built-in styles, converge on a **1-cell interior rhythm**:

```go
lipgloss.NewStyle().
    Border(lipgloss.RoundedBorder()).
    Padding(0, 1).          // one cell of breathing room left/right of text
    Margin(1, 2)            // one row above/below, two cells outboard
```

That single ring of blank cells between text and border is *the* airy feel. Cramped
TUIs put text flush against the frame (`│text│`); Charm writes `│ text │`. The eye
reads the gap as *confidence* — the layout isn't fighting for room, so neither is
the user. Titles pad `0,1`; dialogs pad `1,0`; status bars pad `0,1`. The rhythm is
loose enough to feel generous, tight enough to never waste a full column.

Lip Gloss also ships **custom fill characters** (`PaddingChar('·')`,
`MarginChar('░')`) — so even the *empty* space can carry texture (a dotted or
shaded fill), turning negative space into a subtle decorative field when desired.

### Composition primitives that shape the whole-screen feel

- `JoinHorizontal` / `JoinVertical` with alignment → assemble panes like flexbox,
  producing the multi-column dashboard look (a bordered sidebar list beside a
  content pane beside a status bar) that reads as "an application, not a script."
- `Place` / `PlaceHorizontal` / `PlaceVertical` → center a dialog in available
  space. **Centering is a luxury signal**: a modal floating dead-center with padding
  around it is the terminal equivalent of a well-margined print page.
- Immutability by value: `style2 := style1.Bold(true)` copies rather than mutates.
  Aesthetically irrelevant to the user, but it's *why* authors freely derive style
  variants (`focused := base.Foreground(pink)`), which is *why* consistency is easy,
  which is *why* Charm apps look internally coherent.

---

## 4. Gum & Huh — taste shipped as a default

Lip Gloss gives you the *vocabulary*. Gum and Huh make the *opinion* free.

### Gum — glamour for shell scripts

Gum wraps Bubbles+Lip Gloss so a bare `bash` script gets Charm styling with zero Go:

```bash
gum choose "fix" "feat" "docs"                 # styled vertical picker
gum input --placeholder "scope"                # placeholder-ghosted text field
gum confirm "Commit changes?" && git commit    # yes/no, exit code as answer
gum filter < flavors.txt                        # fuzzy-search list, live-narrowing
gum spin -- sleep 5                             # spinner while a command runs
gum style --foreground 212 --border double "Hi" # ad-hoc styled text block
```

The *point* is the defaults. Out of the box, with **no flags**:

- The **selection cursor is Charm pink (212)** with a `> ` caret — the same hot pink
  as the brand. Your throwaway script inherits the house color without asking.
- **Focused vs. unfocused** rows are distinguished by foreground color, not just a
  marker — the active row *glows*, the rest recede to gray. This is the single
  strongest "designed" tell.
- **Placeholders are ghosted** (dim/faint) rather than absent, so an empty input
  still looks intentional.
- Spacing follows the 1-cell rhythm; multi-select shows check-state glyphs.
- `GUM_<CMD>_<OPT>` env vars let a whole team set a palette once and have every
  script match — theming as ambient environment.

Gum's whole reason to exist is the sentence "even shell scripts should feel
designed." It's the **democratization of the house style** — the aesthetic ships
downstream to people who will never write a line of Go or read the Lip Gloss docs.

### Huh — forms that look art-directed by default

Huh is the form library. Field types: **Input** (single-line), **Text**
(multi-line), **Select**, **MultiSelect**, **Confirm**, **Note**. A bare Huh form,
with no theming, renders with:

- A **title** per field in an accent color, help text dimmed beneath it.
- A clearly highlighted **focused field** vs. dimmed inactive fields (the form
  guides your eye down the page by *brightness gradient*).
- Selected options marked and colored; validation errors in a warning hue.
- Multi-group forms paginate like a wizard.

Crucially, Huh ships **named themes as first-class objects**: `ThemeCharm()` (the
pink/purple house look), `ThemeDracula()`, `ThemeCatppuccin()`, `ThemeBase16()`,
and a plain `ThemeBase()`. That a *form library* treats "Dracula" and "Catppuccin"
as built-in options tells you Charm considers **community aesthetics part of the
API surface** — it's meeting users where their terminal-decorating subculture
already lives. Switching a whole form's personality is one function call; the
structure never changes, only the skin. That is Lip Gloss's structure/style split
delivered at the product level.

---

## 5. Motion & delight — the spinner as a vocabulary of moods

Bubbles ships a catalog of predefined spinners. Because Bubble Tea makes redraw
free, the spinner choice is *pure characterization* — same wait, different feeling.
Exact frames and cadence from `bubbles/spinner/spinner.go`:

| Spinner | Frames | FPS | Mood |
|---|---|---|---|
| **Line** *(default)* | `\| / - \` | 10 | Utilitarian, neutral, "a computer is working." The safe/serious pick. |
| **Dot** | `⣾⣽⣻⢿⡿⣟⣯⣷` (braille) | 10 | Smooth, refined, quietly premium — braille density reads as high-res. |
| **MiniDot** | `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` | 12 | Compact, fast, modern — the tasteful default many pick over Line. |
| **Jump** | `⢄⢂⢁⡁⡈⡐⡠` | 10 | Bouncy, a little playful. |
| **Pulse** | `█▓▒░` | 8 | Breathing/fading block — calm, ambient, "thinking." |
| **Points** | `∙∙∙ ●∙∙ ∙●∙ ∙∙●` | 7 | Friendly, dotty, conversational (like a typing indicator). |
| **Meter** | `▱▱▱ ▰▱▱ ▰▰▱ ▰▰▰ …` | 7 | Fake-progress bar — implies measured advancement. |
| **Ellipsis** | ` . .. ...` | 3 | "typing…" — chatty, human, low-key. |
| **Hamburger** | `☱ ☲ ☴ ☲` | 3 | Quirky, geometric, a wink. |
| **Globe** | `🌍 🌎 🌏` | 4 | Emoji whimsy — "doing something worldly/networked." |
| **Moon** | `🌑🌒🌓🌔🌕🌖🌗🌘` | 8 | Calm, cyclical, delightful — the "cute" pick. |
| **Monkey** | `🙈 🙉 🙊` | 3 | Maximum play — see/hear/speak-no-evil. Pure joy, zero seriousness. |

**The design logic:** a spinner is the one moment a CLI has the user's undivided
attention (they're *waiting*), so it's where personality gets its highest ROI.
Charm turns that dead time into brand. Choosing **Line** says "I'm a serious tool";
choosing **MiniDot** or **Dot** says "serious but designed"; choosing **Moon** or
**Monkey** says "this is going to be fun." The FPS matters too — 12fps braille reads
*fluid and expensive*; 3fps emoji reads *deliberate and cute*. Same wait, and the
author dials the emotional register by picking one line from a menu.

Progress bars extend this: `bubbles/progress` fills with a **gradient** by default,
so the bar's advance is also a color sweep — the fill isn't just "how much" but a
warming/cooling emotional curve that paces the wait.

---

## 6. Glamour — "the CLI can be beautiful prose"

Glamour is the thesis stated most explicitly: *long-form text in a terminal can feel
like a designed document.* It's a **stylesheet-driven markdown renderer** — you hand
it markdown and a theme name, it returns ANSI. Themes are JSON stylesheets, exactly
paralleling CSS.

```go
out, _ := glamour.Render(markdown, "dark")   // or "light", "notty", "dracula", "pink", "ascii", "auto"
```

Concrete styling from the built-in **`dark`** theme (`styles/dark.json`), ANSI-256:

- **document**: color `252` (near-white), **margin 2** — the whole doc is inset two
  cells from the edge. That margin is the "page" feel; text never touches the frame.
- **h1**: color `228` (pale yellow) on **background `63`** (indigo), bold — a *filled
  banner heading*, the boldest element on screen, like a printed chapter title.
- **h2–h6**: prefix markers, de-escalating weight (h6 drops bold, color `35`) — a
  real typographic hierarchy, the way a document (not a log) organizes itself.
- **block_quote**: `indent_token "│ "` — a vertical bar gutter, exactly the visual
  language of a pull-quote in web typography.
- **code** (inline): color `203` (coral/salmon) on **background `236`** (dark gray) —
  a shaded inline chip, so code *pops* out of prose the way `<code>` does on the web.
- **code_block**: color `244`, margin 2, with full **Chroma syntax highlighting**
  (keyword `#00AAFF` blue, string `#C69669` tan, function `#00D787` green, text
  `#C4C4C4`) — real editor-grade colorization inside a terminal document.
- **link**: color `30` (teal) underlined; **link_text**: color `35` bold.
- **hr**: color `240`, rendered as `\n--------\n` — a literal horizontal rule.
- **emph** → italic, **strong** → bold, **list** → indent 2.

Describe the screen: you `glow README.md` and instead of raw `# Title` and backtick
noise, you get a two-cell-margined page with an indigo-bannered title, teal
underlined links, salmon inline-code chips, a syntax-highlighted fenced block, and a
`│`-gutter blockquote. It reads like a **rendered document**, not a text file. That
is the entire "the CLI can be beautiful prose" argument, made visually.

The theme roster itself is a values statement: **`notty`** (no styling, for pipes/CI —
degrade gracefully), **`ascii`** (compat), **`auto`** (adapt to background, the
AdaptiveColor idea again), plus community skins **`dracula`** and **`pink`**. Same
structural hierarchy, swappable mood — Lip Gloss's structure/style split applied to
prose.

---

## 7. What the API makes *easy* vs *hard* — the aesthetic opinion encoded

A toolkit's real aesthetic is the gradient of effort it imposes. Charm's:

- **Easy:** rounded borders, padding, adaptive color, gradients, centered dialogs,
  named themes, a personality spinner, styled shell prompts. → Apps drift toward
  *airy, colorful, soft-cornered, adaptive*.
- **Hard(er):** dense information grids, flush-packed cells, monochrome austerity,
  fixed single-profile color. Nothing *stops* you, but you're swimming upstream. →
  The "1990s ncurses cockpit" look requires opting out of every default.

That gradient *is* the house style. Charm didn't write a style guide; it wrote a
library where the beautiful thing is the easy thing and the retro-dense thing is the
laborious thing. The aesthetic propagates because it's the path of least resistance.

The naming reinforces it: CSS terms (`Padding`, `Margin`, `Border`, `Align`,
`Inherit`, `MaxWidth`) tell web developers their instincts port; Elm terms
(`Model`/`Update`/`View`) tell functional programmers state is safe. The API is a
Trojan horse — it teaches web-app design sensibilities to people writing terminal
programs, and the terminal starts to look like the web: padded, rounded, colored,
responsive.

---

## 8. The describe-the-screen gestalt

A canonical Charm app (say, the Lip Gloss `layout` example, or Crush, or `gum`):

> A rounded-cornered panel floats with a cell of margin around it, not flush to any
> edge. A tab strip runs across the top; the active tab is drawn with a
> corner-notched border so it "connects" to the body below it, the inactive tabs
> sitting slightly detached. Inside, a bordered sidebar list (rounded, right-edge
> only) sits beside a content pane, one blank column of gutter between them. The
> focused list row burns hot pink (`#F25D94`/212) with a `> ` caret; the rest are
> soft gray. A title sits in warm cream (`#FFF7DB`) text on a violet (`#7D56F4`)
> fill. At the very bottom, a status bar: a pink nugget on the left ("● READY"),
> then a gradient-tinted section, then a right-aligned encoding label — like a
> code editor's status line. Nothing is pure white or pure `#000`; everything is a
> considered off-hue. A MiniDot braille spinner ticks at 12fps in the corner while
> something loads. The whole thing looks less like a terminal and more like a
> lovingly art-directed native app that happens to be made of characters.

Every one of those effects traces to a named primitive: `RoundedBorder`,
`Padding(0,1)`, `AdaptiveColor`, `Foreground(#F25D94)`, `Place` centering,
`spinner.MiniDot`, `JoinHorizontal`, gradient `Blend1D`. The magic is fully
enumerable — which is exactly why it became the default ambition everyone copies.

---

## 9. Techniques → feelings (quick index)

| Technique | Feeling produced |
|---|---|
| `RoundedBorder()` corners (`╭╮╰╯`) | Soft, modern, "app not terminal" |
| `ThickBorder()` weight | Emphasis, importance, gravity |
| `DoubleBorder()` (`╔╗╚╝`) | Deliberate retro/formal accent |
| 1-cell interior padding (`│ text │`) | Airy, confident, un-cramped |
| Margin + `Place` centering | Luxury, print-page composure |
| Charm pink `#FF06B7`/212 accents | Friendly, playful, on-brand, premium |
| Charm purple `#7D56F4` fills | Creative, distinctive, anti-corporate |
| Cream text `#FFF7DB` (not `#FFF`) | Warmth, comfort, softness |
| `AdaptiveColor` / `CompleteColor` | "Tailored to my terminal," bespoke |
| Gradient border/fill (`Blend1D`) | "Fussed over," premium chrome, pacing |
| Focused row glows, others dim | Clear guidance, "designed," alive |
| Ghosted placeholders | Intentional even when empty |
| `spinner.Line` | Serious, utilitarian |
| `spinner.MiniDot`/`Dot` (braille) | Serious *and* designed, high-res |
| `spinner.Moon`/`Monkey`/`Globe` | Playful, cute, joyful |
| Progress bar gradient fill | Emotional pacing of the wait |
| Glamour indigo-banner `h1` | Document authority, "a page not a log" |
| Glamour `│ ` blockquote gutter | Editorial, web-typography familiarity |
| Glamour salmon inline-code chips | Code "pops," `<code>`-like affordance |

---

## 10. Notable quotes

- "We make the command line glamorous." — **charm.land** (masthead)
- "Style definitions for nice terminal layouts 👄" — **Lip Gloss** repo description
- "The fun, functional and stateful way to build terminal apps." — **Bubble Tea**
- "A tool for glamorous shell scripts." — **Gum**
- "Read markdown on the CLI… with pizzazz!" — **Glow**
- "The stylesheet-driven markdown renderer." — **Glamour**
- "Artificial intelligence made glamourous." — **Crush**
- Lip Gloss "takes an expressive, declarative approach to terminal rendering. Users
  familiar with CSS will feel at home." — **Lip Gloss README**

---

## Sources

- Lip Gloss — https://github.com/charmbracelet/lipgloss
- Lip Gloss layout example (palette source) — https://github.com/charmbracelet/lipgloss/tree/master/examples/layout
- Charm homepage — https://charm.land
- Bubble Tea — https://github.com/charmbracelet/bubbletea
- Bubbles spinner catalog — https://github.com/charmbracelet/bubbles/blob/master/spinner/spinner.go
- Gum — https://github.com/charmbracelet/gum
- Huh — https://github.com/charmbracelet/huh
- Glamour — https://github.com/charmbracelet/glamour
- Glamour dark theme stylesheet — https://github.com/charmbracelet/glamour/blob/master/styles/dark.json
- Lip Gloss v2 pkg docs — https://pkg.go.dev/charm.land/lipgloss/v2
