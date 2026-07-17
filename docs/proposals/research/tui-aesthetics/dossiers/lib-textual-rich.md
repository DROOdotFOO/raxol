# Textual + Rich (Textualize) — Aesthetic Dossier

> "Rich is a Python library for _rich_ text and beautiful formatting in the terminal."
> — Rich README
> "A major advantage of CSS is that it separates how your app _looks_ from how it _works_."
> — Textual Guide, *Textual CSS*

**What it is:** Two stacked libraries by Will McGugan / Textualize (Python). **Rich** (2020) is the rendering layer — colored text, tables, panels, markdown, syntax highlighting, progress bars, pretty tracebacks. **Textual** (2021) is the application framework on top — a widget DOM, an event loop, and a full CSS dialect (**TCSS**) plus a documented **theme system** built from ~11 semantic base colors that auto-generate light/dark shade ramps and contrast-guaranteed text colors. Together they are the closest thing the terminal has to a **design-system spec**: not a color scheme you hand-pick, but a *generator* that manufactures a coherent, legible palette from a single seed and imprints a soft, web-app "material" look on everything built with it.

Where Charm/Lip Gloss (Go) hands you Flexbox-style primitives and lets you art-direct by hand, Textual hands you a **stylesheet and a theme engine** and lets the system do the art direction. That difference *is* the aesthetic: Rich/Textual apps look "designed by a system, not by hand" — consistent, muted, accent-driven, faintly corporate-modern — because they literally are.

---

## 1. The identity in one sentence

Textual takes the browser's entire presentation stack — cascading stylesheets, a box model, semantic color variables, docking and layers — and ports a "much cut down version" of it into the character grid, so that a TUI reads not as a *console* but as a **flat-design web app from ~2018**: soft rounded panels floating on a slightly-lighter surface over a darker background, one accent color doing all the call-to-action work, body text that is never pure white but a *slightly transparent* white, and de-emphasized text that fades in disciplined muted/disabled steps. The vibe is **calm, layered, legible, and unmistakably "systematized."**

---

## 2. The 11-color theme model — the heart of the aesthetic

Textual defines **eleven base colors**. Only `$primary` is mandatory; the rest are generated if omitted. The names are *semantic roles*, not hues — this is the single most important design decision, because it means the palette encodes **meaning**, and swapping the seed re-skins the whole app while keeping the meaning intact.

| Variable | Documented role | The feeling it encodes |
|----------|-----------------|------------------------|
| `$primary` | "the _branding_ color… titles, and backgrounds for strong emphasis" | **This is who we are.** Identity, headers, focus. |
| `$secondary` | "an alternative branding color, used for similar purposes as `$primary`" | A second voice; supporting emphasis. |
| `$accent` | "used **sparingly** to draw attention" | **Call-to-action.** The one hot spot the eye is trained to. |
| `$foreground` | "the default text color, legible on `$background`, `$surface`, and `$panel`" | The reading voice. |
| `$background` | "background, where there is no content" | The floor. The void behind everything. |
| `$surface` | "the default background of widgets, typically sitting **on top of** `$background`" | **Elevation, layer one.** The card. |
| `$panel` | "differentiate a part of the UI **from** the main content" | A distinct region; sidebar/aside. |
| `$boost` | "a color with **alpha** that can be used to create _layers_ on a background" | **Fake elevation.** Depth without shadow. |
| `$success` | "indicate success… typically a background color" | Green semantics. |
| `$warning` | "indicates a warning… typically a background color" | Amber caution. |
| `$error` | "indicates an error… typically a background color" | Red alarm. |

The aesthetic payload: **de-emphasis and emphasis are baked into the vocabulary.** A designer never picks "a slightly darker gray for the sidebar" — they write `background: $panel` and the system supplies a color that is *guaranteed to relate correctly* to everything else. Wrong-looking combinations become hard to express. That is the terminal equivalent of a Figma design-token file.

---

## 3. Shade ramps — three lighter, three darker, from one seed

> "For every color, Textual generates 3 dark shades and 3 light shades."

Each base color spawns a six-step ramp via suffixes: `-lighten-1/-2/-3` (3 = lightest) and `-darken-1/-2/-3` (3 = darkest). So from a single `$primary` you get `$primary`, `$primary-lighten-1..3`, `$primary-darken-1..3` — seven usable values, all perceptually related.

**Why it produces the "designed by a system" vibe:** hand-built terminal themes pick colors one at a time and inevitably drift — the hover state is a random lighter blue, the pressed state a random darker one, and they never quite feel like a family. A generated ramp guarantees the family resemblance. Hover = `-lighten-1`, active/pressed = `-darken-1`, disabled fill = a muted blend — every interaction state is a *mathematical offset* of the same seed, so the whole app breathes in one hue-consistent rhythm. **Feeling: coherence you can't quite point at — nothing clashes because nothing was chosen independently.**

---

## 4. Contrast-aware `$text` — legibility as a guarantee, not a hope

The text system is where the "design system" claim earns itself. Three neutral text variables, all *derived* rather than set:

- `$text` — "set to a **slightly transparent black or white, depending on which has better contrast** against the background." (Not `#fff`. A translucent white/black that auto-flips per background.)
- `$text-muted` — "a slightly faded text color. Use this for text which has **lower importance**." (De-emphasis.)
- `$text-disabled` — "faded out text which indicates it has been **disabled**." (Dead/inactive.)

Then six **colored** text variables — `$text-primary`, `$text-secondary`, `$text-accent`, `$text-warning`, `$text-error`, `$text-success` — each "guaranteed to be legible against a background of `$background`, `$surface`, and `$panel`."

The clever loop: **muted background + matching text-color are engineered as a pair.** Muted colors are "generated from the base colors by blending them with `$background` at 70% opacity," and the system "aims to ensure that the colored text it generates is legible against the corresponding muted color. In other words, `$text-primary` text should be legible against a background of `$primary-muted`." So a "tinted pill" — `$primary` text on `$primary-muted` fill — is *guaranteed readable* without the designer ever running a contrast checker.

**The three-tier text ramp (`$text` → `$text-muted` → `$text-disabled`) is the single most recognizable Textual signature.** It's why Textual apps feel *quiet and hierarchical*: your eye is led down a gradient of importance — bright heading, normal body, faded caption, ghosted disabled control — and that visual hierarchy comes free with the theme. **Feeling: information triage done for you; the screen tells you what matters before you read a word.**

**Describe the screen:** a dark panel. The section title sits in near-white `$text`. Below it, a row of settings in the same weight. One is greyed to `$text-disabled` — you know it's off without a checkbox. A small status chip glows in `$text-success` green against a barely-there `$success-muted` wash. Nothing shouts; the loudest thing on screen is a single `$accent`-colored button, and it's loud *only because everything else agreed to be quiet.*

---

## 5. TCSS as aesthetic control surface — the box model comes to the grid

Textual re-implements a "much cut down version of CSS." The vocabulary is deliberately the *web designer's* vocabulary, and that choice imports the web designer's *instincts*:

- **Box model:** `padding` (interior breathing room), `margin` (exterior space, and — faithful to CSS — "margins **overlap** between adjacent widgets"), `border`, `outline` (a border that "doesn't change widget size" and "may overlap the content area"). `box-sizing: border-box` is the default, matching modern CSS resets.
- **Layout:** `dock` (pin a widget to an edge — the terminal equivalent of `position: sticky` headers/footers/sidebars), `layers` + `layer` (explicit z-ordering — how modals and tooltips float *above* content on a medium with no real z-axis), `align`, `layout: horizontal | vertical | grid`, and fractional `fr` units plus `%`, `vw/vh`, `auto`.
- **Selectors:** type selectors, `#id`, `.class`, pseudo-classes like `:hover` and `:focus`, cascading with specificity — the full mental model.

The aesthetic consequence: **because padding, docking, and layers are trivial, Textual apps default to the "app" idiom, not the "console" idiom.** A console scrolls a flat river of text. A Textual app *docks a title bar and footer, floats cards with internal padding on a surface, and layers a modal over a dimmed backdrop.* The tooling makes the dashboard shape the path of least resistance. **Which border and layout choices tip it one way or the other is section 6.**

The other half of the aesthetic is *workflow*: `textual run app.py --dev` gives **live CSS editing** — "modifications to CSS code result in the interface updating accordingly." Design iteration in a TUI at the speed of a browser inspector. That fast loop is *why* Textual apps end up visually fussed-over; the medium finally rewards tweaking.

---

## 6. The border vocabulary — where "sleek dashboard" and "hacker terminal" fork

Textual ships ~16 named border styles (`textual borders` previews them live). The choice of border is the loudest single tonal dial in the whole system, because on a flat grid the *frame* is doing the work that drop-shadows and rounded-rect chrome do on the web.

| Border | Glyphs / character | Reads as |
|--------|--------------------|----------|
| `round` | `╭ ╮ ╰ ╯` soft corners + `─ │` | **Friendly, modern, "app."** The soft-UI default of the era. Cushioned, approachable. |
| `solid` | `┌ ┐ └ ┘ ─ │` square corners | Neutral, utilitarian, "classic TUI." |
| `heavy` | `┏ ┓ ┗ ┛ ━ ┃` thick strokes | **Bold, assertive, present.** Emphasis; a widget that wants to be a heading. |
| `double` | `╔ ╗ ╚ ╝ ═ ║` | **Retro/formal, DOS-BIOS, "important dialog."** Nostalgic authority. |
| `dashed` | dashed line | Light, provisional, "draft." |
| `ascii` | `+ - |` | **Deliberate retro / max-compat / hacker.** No Unicode; reads as "raw terminal," 1980s. |
| `tall` | uses top/bottom half-blocks `▔▁` for a tall thin frame | Sleek, minimal, "chrome-less card edge." |
| `wide` | thick horizontal bands | Chunky, poster-like. |
| `hkey` / `vkey` | half-block key lines | Subtle rails; a hint of a frame, not a cage. |
| `panel` | title-bar-style top | Header-forward, "titled section." |
| `inner` / `outer` | shaded blocks giving an inset/raised bevel | **Fake bevel — pseudo-3D.** Skeuomorphic "pressed/raised." |
| `blank` / `hidden` / `none` | invisible but reserves space | Alignment without visible chrome; the "flat/brutalist" choice. |

**The fork, concretely:**
- `round` + generous `padding` + `surface`/`panel` layering → **sleek modern dashboard.** Soft floating cards, air, a single accent. This is the Textual house style.
- `ascii` or `double` + zero padding + high-contrast primary → **hacker terminal / retro.** Sharp, dense, nostalgic, "I am inside a machine."
- `blank`/`none` + `hatch` backgrounds + heavy color blocks → **flat/brutalist.** No frames, just fields of color meeting hard edges.

Textual's own default widgets lean `round`/`tall` with muted borders — the framework's thumb is on the "sleek app" side of the scale, and you have to actively choose `ascii`/`double` to get the retro register back.

---

## 7. Rich's rendering primitives — the tone-setters that made "pretty Python CLI" a baseline

Before Textual there is Rich, and Rich's *defaults* are why an entire generation of Python CLIs (pip, poetry-adjacent tools, pytest plugins, countless internal scripts) share a look. Two default choices did most of the imprinting:

**Table default box = `HEAVY_HEAD`.** A Rich table you make with zero styling gets a **heavy-ruled header row over light-ruled body rows** — the header's `┡━╇┩` thick underline transitioning into thin `├─┼┤` body separators:
```
┏━━━━┳━━━━┓   ← heavy header top
┃ id┃name┃
┡━━━━╇━━━━┩   ← heavy→light transition rule
│  1 │ Ada│
├────┼────┤   ← light body rules
```
The effect is *typographic hierarchy for free*: the header visually "sits above" the data. It reads as **considered, editorial, "someone designed this table"** — the opposite of `print(dict)`.

**Panel default box = `ROUNDED`.** `Panel("text")` yields `╭─…─╮ / │ … │ / ╰─…─╯` — the soft-cornered card. Rich chose **rounded as the default frame**, and that one default is arguably the origin of the whole "modern pretty CLI" look: every quick `Panel` anyone drew came out cushioned.

The full box vocabulary (each an 8-line character grid) — the aesthetic range Rich offers:

- `ROUNDED` `╭─┬╮…╰─┴╯` — soft, friendly, default panel. Modern.
- `SQUARE` `┌─┬┐…└─┴┘` — crisp, neutral, classic.
- `HEAVY` `┏━┳┓…┗━┻┛` — bold, present, emphasis.
- `DOUBLE` `╔═╦╗…╚═╩╝` — retro-formal, DOS authority.
- `HEAVY_HEAD` — the default table; heavy header, light body. Editorial hierarchy.
- `MINIMAL` `╷ │ ╶─┼╴` — only interior rules, faint stub tick marks, no outer frame. **Airy, low-ink, "quiet data."**
- `SIMPLE` — just a single `──` rule under the header, everything else whitespace. **Maximum restraint; reads as elegant / typographic / "expensive."**
- `HORIZONTALS` — horizontal rules only, no verticals. Newspaper/ledger feel.
- `ASCII` / `ASCII2` — `+-|` fallback; retro / guaranteed-compat.
- `MARKDOWN` — pipe-table styling for copy-paste into `.md`.

**The MINIMAL/SIMPLE end of the range is the "designer's secret":** removing box lines and leaning on whitespace + one header rule is what makes a table read as *refined* rather than *chunky*. Rich gives you the whole dial from `DOUBLE` (loud, retro) through `HEAVY_HEAD` (default, structured) to `SIMPLE` (whisper-quiet), and the vibe of the app shifts entirely along it.

**Console markup — styling as conversation.** Rich's `[bold red]alert[/]` BBCode-like markup makes styling *inline and legible in source*: `:warning:` becomes ⚠️, `[link=url]text[/link]` becomes a real OSC-8 hyperlink, `[dim]`, `[italic]`, `[reverse]`, `[on blue]`. The tonal effect of markup-as-default: styling feels **lightweight and conversational rather than programmatic** — you *decorate a sentence* instead of *constructing a style object* — which lowers the friction of adding color so far that Rich apps end up *more* colorful than they'd otherwise be. The medium encourages ornament.

**Syntax highlighting** (via Pygments) defaults toward the `monokai`/`ansi_dark` family — the same warm-on-dark code palette that VS Code normalized — so embedded code in a Rich/Textual app instantly carries "modern editor" connotations. `ansi_dark`/`ansi_light` special themes defer to the user's own terminal palette (respect the ricer's colorscheme), while a named theme like `monokai` overrides it (impose the house look). That choice — defer vs. impose — is itself an aesthetic stance.

**Gradient / truecolor text, emoji, spinners, progress bars** round out Rich's "delight" surface: smooth 24-bit color gradients across text, a large emoji vocabulary, and flicker-free animated progress. These are the ornaments that made the "pretty Python CLI" feel *generous* — the library ships joy in the box.

---

## 8. Built-in themes as ready-made moods

Textual registers a set of themes by default; each is a **complete mood in one word**, and because they're just 11-color seeds fed to the same generator, they all get the same disciplined ramps/muted/text machinery — so switching theme re-skins mood without breaking structure:

- **textual-dark** — the house default. Cool blue-primary on near-black surface. **Calm, corporate-modern, "SaaS dashboard at night."**
- **textual-light** — the daylight twin. Airy, clean, "settings panel."
- **nord** — desaturated arctic blue-grays. **Cool, muted, Scandinavian-minimal, restful.**
- **gruvbox** — warm retro amber/olive/rust on brown-black. **Cozy, analog, "old paper and CRT," nostalgic-warm.**
- **tokyo-night** — deep indigo with neon-pastel accents. **Nocturnal, synthwave-adjacent, "coding at 2am."**
- **catppuccin-mocha** (community-ubiquitous) — soft pastel lavender/pink on muffled dark. **Gentle, cute, low-contrast comfort.**
- **dracula** — purple/pink/green on charcoal. **Playful-gothic, high-recognition.**
- **monokai** — the classic warm-code palette. **Editor-nostalgic.**
- **solarized-light / atom-one-dark / atom-one-light / flexoki** — each imports a whole subculture's colorscheme wholesale.

The design-guide stance: **lean on `$accent` for the one thing that must be noticed, and on `$surface`/`$panel` layering for depth** — rather than reaching for many bright colors. Themes differ mostly in *hue and warmth*, not in *structure*, because the structure (hierarchy via the text ramp, elevation via surface layering) is constant across all of them. That's why a Textual app "feels like a Textual app" regardless of which theme is loaded.

---

## 9. Depth without shadows — faking elevation on a flat grid

The terminal has no z-axis, no blur, no drop-shadow. Textual fakes elevation with four stacked tricks, and the *combination* is what reads as "material":

1. **Surface layering (value, not shadow).** `$background` (darkest) → `$surface` (a step lighter, the card) → `$panel` (a distinct region). Because `$surface` is lighter than `$background`, a widget on `$surface` **appears to float above** the void — pure figure-ground via lightness. This is the primary depth cue and it costs nothing but a value difference. **Feeling: cards sitting on a table.**
2. **`$boost` — alpha overlay.** A semi-transparent color explicitly "used to create _layers_ on a background." Stacking `$boost` tints *accumulates* — two overlapping boosted layers are lighter than one — so overlap itself becomes a depth signal, the way stacked translucent glass panes get brighter. **Feeling: frosted panes; genuine sense of "on top of."**
3. **`hatch` — texture as material.** `hatch: cross red;`, `hatch: left green 40%`, or a custom char — "fills a widget's background with a repeating character for a pleasing textured effect." A faint diagonal `╱╱╱` or cross `✕✕` hatch at low opacity gives a surface *grain*, distinguishing a region without a border. **Feeling: a textured panel vs. a flat void — the difference between matte cardstock and blank paint.**
4. **`opacity` / `tint`.** Fading a whole widget's opacity (to dim a backdrop behind a modal) or applying a color `tint` over content. Dimming the backdrop is the terminal's version of the modal scrim — **it manufactures focus by pushing everything else "back."**

**Which combos read which way:**
- `$surface` card + `round` border + `padding` + a `$boost` header strip → **material / elevated.** The web-app card, faithfully faked.
- `$background` everywhere, `none` borders, hard color blocks, no hatch → **flat / brutalist.** Fields of color meeting at hard edges, no illusion of depth.
- `hatch` + `double` borders + saturated primaries → **retro-decorated**, closer to a BBS/ANSI-art register than a SaaS dashboard.

The house default sits firmly at "material/elevated," which is exactly why Textual apps surprise people by *not looking like terminal apps.*

---

## 10. History, lineage, influences

- **Rich (2019–2020)** began as Will McGugan's side project to make Python terminal output beautiful — color, tables, markdown, tracebacks. It went viral (one of the fastest-starred Python libs of its moment) precisely because its *defaults* were pretty: `HEAVY_HEAD` tables, `ROUNDED` panels, Pygments code. It reset the baseline expectation for what a Python CLI should look like.
- **Textual (2021)** grew out of Rich as the app framework — McGugan's thesis that "advancements made for web frameworks over two decades weren't coming back to the terminal," so he'd "cherry pick things which worked well and port them." The deliberate imports: **CSS** (styling separated from logic), a **DOM** (widget tree), **event bubbling**, **reactive attributes**, **flexbox/grid-ish layout**, **docking**. Textual is a web framework wearing a terminal as a costume.
- **Textualize (the company, 2021–2025)** productized it; a pivot toward **textual-web** (serving TUIs as web pages — same code, browser or terminal) underlined the whole philosophy: the terminal and the browser are the *same* presentation problem. (Textualize wound down as a company in 2025; the libraries remain widely used and maintained.)
- **Lineage it sits in:** downstream of the web's CSS/flexbox tradition (import), parallel to **Charm/Lip Gloss** in Go (which borrows the *same* web vocabulary — flexbox terms, borders, padding — independently), and upstream of a wave of "pretty" Python TUIs. The shared ancestor with Lip Gloss is telling: **two of the most influential modern TUI stacks both decided the terminal should borrow the browser's design language.** That convergence is the era's defining aesthetic move.

---

## 11. What it makes easy vs. hard — the aesthetic opinion encoded in the API

A library's aesthetics live in its *defaults and its ergonomics* — what's one line vs. what's a fight.

**Easy (therefore common in Textual apps):**
- A rounded, padded card on a lighter surface → a few lines of TCSS. → *soft modern dashboards everywhere.*
- Contrast-safe text hierarchy → automatic via `$text`/`$text-muted`/`$text-disabled`. → *quiet, layered, legible.*
- A coherent palette from one seed → set `$primary`, done. → *"designed by a system."*
- Docked header/footer, layered modal → `dock:` / `layers:`. → *the "app" idiom.*
- Re-theming the entire app → swap the theme. → *mood is a runtime toggle.*

**Hard (therefore rare — and *that's the house style*):**
- Pixel-hand-tuned one-off colors that ignore the ramp → you're fighting the token system. → *idiosyncratic, hand-crafted looks are discouraged.*
- Dense, chrome-heavy "everything boxed" retro screens → possible (`ascii`/`double`) but against the grain of the muted defaults.
- Truly novel layouts that aren't box-model expressible → you're fighting CSS, same as on the web.

So the library's opinion is: **be a calm, layered, accent-driven, systematically-colored app.** It makes the "modern flat-material web app" trivially easy and makes "gaudy hand-tuned hacker terminal" mildly annoying. The path of least resistance is the aesthetic.

---

## 12. Voice, defaults, and the house style it imprints

Even with zero custom styling, a Textual app arrives wearing: **textual-dark** (cool blue on near-black), **rounded/tall muted borders**, a **docked header and footer**, **generous padding**, the **three-tier text ramp**, and a **single accent** for focus/CTA. A Rich script arrives wearing **HEAVY_HEAD tables**, **ROUNDED panels**, **monokai code**, and **markup-driven color**. None of that was chosen by the app author — it's the framework's taste, applied by default, and it's remarkably consistent from app to app. That consistency is the point: **you can spot a Rich/Textual app the way you can spot a Bootstrap website** — a shared design DNA visible under the surface content.

---

## Techniques → feelings (quick index)

- 11 **semantic** color roles (`$primary`…`$accent`) instead of raw hues → *meaning-encoded palette; re-skin without redesign.*
- **3-light/3-darken auto ramps** per color → *effortless family resemblance; nothing clashes because nothing was chosen alone.*
- **Contrast-aware `$text`** (translucent b/w that auto-flips) → *never pure `#fff`; always legible; softly premium.*
- **`$text` → `$text-muted` → `$text-disabled`** three-tier ramp → *information triage; visual hierarchy for free; calm.*
- **Muted-bg + matching text-color engineered as a pair** → *tinted pills/chips guaranteed readable; confident color use.*
- **`round` (`╭╮╰╯`) as the default border** → *friendly, cushioned, "app not console."*
- **`ascii`/`double` borders** → *retro / hacker / DOS-authority when you want it back.*
- **`inner`/`outer` bevel borders** → *fake pseudo-3D press/raise.*
- **Rich `HEAVY_HEAD` default table** (heavy header → light body) → *editorial typographic hierarchy; "someone designed this."*
- **Rich `ROUNDED` default panel** → *the origin of the "pretty modern CLI" card.*
- **`MINIMAL`/`SIMPLE` box styles** (whitespace + one rule) → *refined, expensive, whisper-quiet data.*
- **Console markup `[bold red]…[/]`** → *styling as conversation; low friction → generous color.*
- **Surface > background lightness step** → *figure-ground elevation; cards floating; depth from value alone.*
- **`$boost` alpha overlays** (accumulate on overlap) → *frosted glass; genuine "on top of."*
- **`hatch` texture fills** → *material grain; matte cardstock vs. blank void.*
- **`opacity`/`tint` backdrop dimming** → *modal scrim; manufactured focus.*
- **Docking + layers** → *sticky header/footer + floating modals; the "app" idiom on a flat medium.*
- **Named themes (nord/gruvbox/tokyo-night/catppuccin)** → *whole moods as one-word runtime toggles; structure constant, warmth varies.*
- **Live `--dev` CSS editing** → *browser-speed iteration → apps that actually got fussed-over.*

---

## Notable quotes

- "Rich is a Python library for _rich_ text and beautiful formatting in the terminal." — *Rich README*
- "A major advantage of CSS is that it separates how your app _looks_ from how it _works_." — *Textual Guide, Textual CSS*
- On `$primary`: "the primary color, can be considered the _branding_ color. Typically used for titles, and backgrounds for strong emphasis." — *Textual design docs*
- On `$accent`: "used sparingly to draw attention." — *Textual design docs*
- On `$text`: "set to a slightly transparent black or white, depending on which has better contrast against the background." — *Textual design docs*
- On the legibility loop: "`$text-primary` text should be legible against a background of `$primary-muted`." — *Textual design docs*
- On `$boost`: "a color with alpha that can be used to create _layers_ on a background." — *Textual design docs*
- On `hatch`: "fills a widget's background with a repeating character for a pleasing textured effect." — *Textual styles docs*
- McGugan's rationale (paraphrased across interviews): advancements from two decades of web frameworks "weren't coming back to the terminal," so he set out to "cherry pick things which worked well and port them to the terminal." — *SE Radio #669 / Sourcery interview*
- On the work itself: building Textual is "figuring out how to make a terminal do things that it shouldn't really be able to do." — *McGugan interviews*

---

## Sources

- Textual — Design / theme system: https://textual.textualize.io/guide/design/
- Textual — CSS (TCSS) guide: https://textual.textualize.io/guide/CSS/
- Textual — Styles guide (box model): https://textual.textualize.io/guide/styles/
- Textual — `border` style reference: https://textual.textualize.io/styles/border/
- Textual — `hatch` style reference: https://textual.textualize.io/styles/hatch/
- Rich — README / mission: https://github.com/Textualize/rich
- Rich — box constants source (character grids): https://github.com/Textualize/rich/blob/master/rich/box.py
- Rich — Box appendix: https://rich.readthedocs.io/en/stable/appendix/box.html
- Rich — Console markup: https://rich.readthedocs.io/en/stable/markup.html
- Rich — Table (default `HEAVY_HEAD`): https://rich.readthedocs.io/en/stable/reference/table.html
- Rich — Syntax highlighting (Pygments/monokai/ansi_dark): https://rich.readthedocs.io/en/stable/syntax.html
- "The future of Textualize": https://textual.textualize.io/blog/2025/05/07/the-future-of-textualize/
- SE Radio #669 — Will McGugan on Text-Based User Interfaces: https://se-radio.net/2025/05/se-radio-669-will-mcgugan-on-text-based-user-interfaces/
- Sourcery interview — Will McGugan, side project to startup: https://www.sourcery.ai/blog/will-mcgugan-interview
- Changelog #511 — "The terminal as a platform": https://changelog.com/podcast/511
