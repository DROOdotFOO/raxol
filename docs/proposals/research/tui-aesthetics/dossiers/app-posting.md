# Posting — Aesthetic Dossier

**What it is:** A modern HTTP/API client (a Postman/Insomnia rival) that lives entirely in the terminal, built by Darren Burns on **Textual**, the Python TUI framework he co-maintains. Tagline: *"The API client that lives in your terminal."*

**Why it matters for TUI aesthetics:** Posting is the reference specimen of the **"desktop-grade app inside a character grid"** school. It does not read as a script, a REPL, or a dashboard — it reads as a *product*, an IDE-class application. It achieves that with almost no imagery: a jewel-toned dark palette, rounded low-opacity panels that ignite on focus, semantic color coding, Rich-powered syntax highlighting, and obsessive padding discipline. Because it is styled with **TCSS (Textual CSS)** — literal CSS-in-the-terminal — its entire aesthetic system is legible as a stylesheet. This dossier reconstructs that stylesheet into a theory of *which move produces which feeling*.

Repo cloned shallow into `undefined/posting/`. Primary style sources: `src/posting/posting.scss` (the app stylesheet), `src/posting/themes.py` (11 built-in themes as data), `src/posting/config.py`, `src/posting/app.py`.

---

## 1. The core sensation: "a jewel embedded in obsidian"

Boot Posting with defaults and the screen is near-black — not pure black, an **indigo-tinted black** (`#0F0F1F`). Panels are a shade lighter (`#1E1E3F` surface, `#2D2B55` panel), so the layout reads as *slightly-raised slabs floating on a dark void*. Every interactive accent is a **saturated jewel color** — amethyst purple (`#C45AFF`) and hot-pink (`#FF69B4`) — but those jewels are mostly held at **low opacity** until you touch them. The restimulation is: a calm, expensive, dim workspace that **lights up exactly where your attention is**.

This is the default theme, named — tellingly — **`galaxy`**:

```python
galaxy_primary     = "#C45AFF"  # amethyst / electric purple
galaxy_secondary   = "#a684e8"  # softer lavender
galaxy_accent      = "#FF69B4"  # hot pink (header text, cursors, focus bars)
galaxy_warning     = "#FFD700"  # gold
galaxy_error       = "#FF4500"  # orange-red
galaxy_success     = "#00FA9A"  # spring/mint green
galaxy_background  = "#0F0F1F"  # indigo-black void
galaxy_surface     = "#1E1E3F"  # raised slab
galaxy_panel       = "#2D2B55"  # deeper indigo panel
```

- **Technique → feeling:** near-black with a *hue tint* (indigo, never `#000000`) → warmth and depth; a pure-black background reads as "terminal/void," a tinted one reads as "designed surface."
- **Technique → feeling:** purple+pink primary/accent on dark → premium, nocturnal, "IDE at 2am." Purple is the rarest UI hue and signals bespoke intent; nobody's default terminal is purple, so purple = *someone chose this*.
- **Technique → feeling:** the cosmic name (`galaxy`) and its sibling names (`nebula`, `aurora`, `twilight`, `hypernova`, `synthwave`) → the whole product is framed as *atmospheric*, not utilitarian.

---

## 2. The palette system — CSS-in-terminal as the styling paradigm

Posting's themes are **not** ad-hoc color literals scattered in code. They are a typed data model (`themes.py`, a Pydantic `Theme`) with nine **semantic slots**: `primary, secondary, accent, background, surface, panel, warning, error, success`. That model compiles to a **Textual `Theme`**, and Textual auto-derives an entire scale from each color: `$primary-muted`, `$accent-muted`, `$surface-lighten-1`, `$surface-darken-1`, `$success-muted`, `$text-primary`, `$text-success`, etc. The `.scss` stylesheet then references only these *variables* — never a raw hex.

The consequence is the aesthetic backbone: **every widget is painted from the same nine-color vocabulary**, so a re-theme is total and coherent. Swap `galaxy` for `hacker` and the *entire* app — scrollbars, focus bars, status pills, method labels, syntax highlighting — turns matrix-green in lockstep, because nothing hardcoded a color.

- **Technique → feeling:** semantic tokens (`$accent`, `$text-success`) instead of literals → the app feels *systematic and intentional*; color always *means* something (accent = focus, success = 2xx, error = 5xx), never decoration for its own sake.
- **Technique → feeling:** the `-muted` variant used as a *background* behind `-text` foreground (e.g. `color: $text-success; background: $success-muted`) → the "colored pill" look. A 2xx status renders as green text on a dim-green lozenge — a desktop-app status chip reproduced in cells.
- **Technique → feeling:** live theme hot-reload (`watch_themes: true`, edit YAML → UI refreshes instantly) → theming feels like a *creative surface*, encouraging the "make it yours" ritual that bonds users to the app.

### The theme gallery as mood library

The 11 built-ins are a deliberate spread of *moods*, each a coherent emotional register:

| Theme | Palette move | Vibe produced |
|---|---|---|
| **galaxy** (default) | amethyst+pink on indigo-black | premium nocturnal IDE |
| **nebula** | electric blue + cyan on deep navy | cool, oceanic, focused |
| **sunset** | coral→peach gradient warmth | soft, golden-hour calm |
| **aurora** | mint+violet neon on deep sea-blue | ethereal, shimmering |
| **nautilus** | ocean blue + teal + gold | nautical, classic, sturdy |
| **cobalt** | slate blue, restrained | corporate-cool, understated |
| **twilight** | midnight-blue base | quiet, dusky |
| **hacker** | `#00FF00` on `#000000`, method verbs all green shades | retro cyberpunk / phosphor CRT |
| **manuscript** | *the only light theme* — "aged paper" `#F5F1E9`, "ink blue," "aged leather brown," "parchment" | analog, bookish, warm daylight |
| **hypernova** | comment says *"designed to WOW"* — neon aqua/pink/yellow on near-black | maximal, arcade, showy |
| **synthwave** | comment: *"retro 80s… neon grids and sunset vibes"* — hot pink + electric purple | Miami-noir nostalgia |

- **Technique → feeling:** shipping *named moods* rather than "dark/light" → color choice becomes *self-expression*; the identity of the app is "the one with beautiful themes."
- **Technique → feeling:** `manuscript` deliberately breaks the neon family with sepia/parchment and in-code comments like `# Ink blue` / `# Aged leather brown` → proof the palette is *authored by hand*, not generated; the designer is thinking in materials (leather, paper, ink), which is the essence of aesthetic intent.

---

## 3. Semantic color-coding: HTTP verbs as a color language

HTTP methods get their own dedicated palette, and — the giveaway of a designer with web-native taste — **they are the Tailwind CSS 500-level swatches**:

```python
get:     "#0ea5e9"  # sky-500
post:    "#22c55e"  # green-500
put:     "#f59e0b"  # amber-500
delete:  "#ef4444"  # red-500
patch:   "#14b8a6"  # teal-500
options: "#8b5cf6"  # violet-500
head:    "#d946ef"  # fuchsia-500
```

In the collection sidebar and method selector, each request is tagged with its verb in *its own* color. The eye learns the language: destructive `DELETE` is always red, safe `GET` always sky-blue.

- **Technique → feeling:** a fixed verb→hue mapping → **scannability as aesthetic**; a wall of endpoints becomes a color-coded index, and the color-coding itself signals "this tool understands REST."
- **Technique → feeling:** borrowing the *Tailwind* palette specifically → subliminal familiarity for web developers; it makes a terminal app feel like it belongs to the same design universe as their web stack. (Themes can override these — `hacker` recolors every verb a shade of green; `synthwave` remaps them to its neon set — so the *semantics* survive the reskin.)

---

## 4. Border & box-drawing language: the "section that ignites"

Posting's single most identity-defining move lives in one CSS rule (`posting.scss`):

```scss
.section {
  border: round $accent 40%;
  border-title-color: $text-accent 50%;
  border-title-align: right;
  &:focus-within {
    border: round $accent 100%;
    border-title-color: $foreground;
    border-title-style: b;
  }
}
```

Every major panel is a **rounded-corner box** (`╭─╮ … ╰─╯`, Textual's `round` border) drawn in the **accent color at 40% opacity** — a dim, recessive frame. Its title sits **right-aligned** and dimmed to 50%. The instant a panel gains focus, its border snaps to **100% accent** and the title goes **bold and full-brightness**. Focus, therefore, is not a subtle outline change — it's the panel **catching fire**.

- **Technique → feeling:** `round` (rounded) borders over sharp/heavy → soft, friendly, "modern app"; rounded corners are the terminal's cheapest signifier of "consumer software," not "sysadmin tool."
- **Technique → feeling:** border at **40% → 100% opacity on focus** → a *dimmer-switch* interaction. The unfocused UI is quiet and de-emphasized; attention literally brightens the region you're in. This single opacity-lerp does the work that glow, shadow, and elevation do in a GUI.
- **Technique → feeling:** **right-aligned** border titles → unconventional, editorial, "designed"; left-aligned titles read as default/framework, right-aligned reads as a deliberate compositional choice.
- **Technique → feeling:** title going **bold** on focus → typographic weight substitutes for the color/size emphasis a GUI would use.

**Focus bars instead of full borders.** For smaller controls (inputs, command palette, autocomplete, rich logs) Posting drops the box entirely and paints a single **thick accent bar on the left edge**:

```scss
Input:focus            { border-left: outer $surface-lighten-1; }
PostingRichLog:focus   { border-left: wide $accent; }
CommandPalette #--input{ border-left: wide $accent; }
AutoComplete           { border-left: wide $accent; }
Input.error            { border-left: thick $error; }
```

- **Technique → feeling:** a left-edge accent rule → the "active line" marker of a code editor (VS Code's focused-gutter, a quoted block). It says *editor*, and it costs one column. An **error** swaps the bar to `thick $error` red — the same grammar, different meaning.

---

## 5. Density, whitespace, and the "it's an app not a script" tell

Posting is generous with breathing room in a medium where most tools cram to the edges. The app header is padded `1 3` (a blank row above/below, three columns left/right); the body `0 2`; the URL bar `0 3`; modals `1 2`. Sections are separated by their rounded frames plus internal padding.

```scss
AppHeader { padding: 1 3; }
AppBody   { padding: 0 2; }
UrlBar    { padding: 0 3 0 3; }
.modal-body { padding: 1 2; border: wide $background-lighten-2; }
```

- **Technique → feeling:** **deliberate padding** (blank rows/columns as margin) → the single strongest "this is an application" signal in a TUI. A script prints flush-left to column 0; an *app* insets its content and lets the background frame it. Whitespace is the terminal's drop-shadow.
- **Technique → feeling:** a `--compact` mode that strips borders and zeroes padding (`.section { border: none }`, `AppBody { padding: 0 }`, tabs collapse to height 1) → the app offers *two densities*, an explicit acknowledgment that whitespace is a dial, not an accident. Roomy by default (welcoming), compact on demand (power/density).

---

## 6. Empty states & texture: the hatch signature

Where a lesser TUI leaves a blank void, Posting fills empty regions with a **diagonal hatch texture**:

```scss
$empty-hatch: right $surface-lighten-1 70%;
#no-body-label      { hatch: $empty-hatch; color: $text-muted; }
#empty-message      { hatch: right $surface-lighten-1 70%; }
#textual-jump-info  { hatch: right $accent 30%; }
```

An empty request body, an empty cookies table, the jump-mode banner — all get a subtle repeating slash-fill in a slightly-lighter surface tone.

- **Technique → feeling:** `hatch` fill on empty/placeholder zones → texture where there'd be void; it reads like *engineering drawing / blueprint crosshatch*, or a "no signal / intentionally blank" material. It turns "nothing here" from a bug-like gap into a **designed surface**, and quietly reinforces the drafting-table, precision-instrument mood.

---

## 7. Scrollbars: invisible until intended

```scss
* {
  scrollbar-size-vertical: 1;
  scrollbar-color: $primary 10%;
  scrollbar-color-hover: $primary 80%;
  scrollbar-color-active: $primary;
  scrollbar-background: $surface-darken-1;
  &:focus { scrollbar-color: $primary 50%; }
}
```

Scrollbars are **one column wide** and the thumb sits at **10% primary opacity** — a ghost. Hover brings it to 80%, drag to 100%, focusing the pane to 50%.

- **Technique → feeling:** ultra-thin, near-transparent scrollbars that **escalate opacity with interaction** → the chrome disappears when unused and materializes under the cursor; the same dimmer-switch philosophy as the borders. The UI is *quiet at rest, responsive on contact* — a coherent, app-wide interaction grammar.

---

## 8. Typography substitutes & syntax highlighting as decoration

With one monospace face and no font choice, Posting leans on the four levers the terminal allows — **bold, dim, color, and Rich markup** — and on **tree-sitter syntax highlighting** as its richest content ornament.

**The header** is a masterclass in doing a lot with two style spans:

```python
Label(f"[b]Posting[/] [dim]{VERSION}[/]", id="app-title")
```

Bold "**Posting**" + dim version number, with the `user@host` string docked far-right in `$text-muted`. Weight contrast alone establishes a title/subtitle hierarchy.

**Syntax highlighting** is the response area's centerpiece. JSON bodies are colored by semantic slot — keys, strings, numbers, booleans, nulls each mapped to a theme color (`syntax-json-key → primary`, `string → accent`, `number → secondary`, `boolean → success`, `null → warning`). The **URL bar** is itself highlighted: protocol in `$accent`, host/base in `$secondary`, separators (`/`) dimmed:

```python
class UrlStyles: base = secondary; protocol = accent; separator = "dim"
```

Unresolved template `{{variables}}` render in `$error`, resolved ones in `$success`.

- **Technique → feeling:** syntax-highlighted JSON → the response reads like it's in an editor, not a `curl` dump; color-per-token is the terminal's substitute for the typographic richness (varied fonts/sizes) a GUI viewer would use. It signals *craft* and makes payloads *scannable*.
- **Technique → feeling:** highlighting the **URL itself** (bright protocol, dim slashes) → even the address bar is treated as code worthy of decoration; nothing is left as plain text. This relentless tokenization is the "IDE" feeling.
- **Technique → feeling:** resolved variables green / unresolved red, live as you type → color carries *correctness state*; the UI is constantly, quietly telling you whether you're about to send something valid.

---

## 9. Status feedback: the colored pill

When a response returns, the response panel's **border title becomes a status chip**:

```python
def _make_border_title(self, response):
    style = self.get_component_rich_style("border-title-status")
    return f"Response [{style}] {response.status_code} {response.reason_phrase} [/]"
```

…and the whole panel gets a class (`success`/`warning`/`error`) that colors that chip green/amber/red on its matching `-muted` background. The **border subtitle** shows size + timing: `1.2 kB in 84.30[dim]ms[/]` — the `ms` unit dimmed so the number pops.

```scss
ResponseArea.success .border-title-status { color: $text-success; background: $success-muted; }
ResponseArea.error   .border-title-status { color: $text-error;   background: $error-muted; }
```

- **Technique → feeling:** status code as a **colored lozenge in the frame** → instant, pre-attentive read of success/failure; the whole panel edge participates in signaling the result. It's the terminal equivalent of a toast/badge, welded into the box border.
- **Technique → feeling:** dimming the **unit** (`ms`) but not the number → typographic hierarchy inside a single string; your eye lands on `84.30`, the `ms` recedes to context. Micro-craft that adds up to "polished."

---

## 10. Motion language: stillness as speed

Posting's animation default is, deliberately, **`none`**:

```python
animation: AnimationLevel = Field(default="none")   # config.py
# app.py: "The animation is set AFTER the app is initialized intentionally"
```

There are no spinners, no easing curves, no sliding panels in the default experience. Feedback is **instant state-swap**: focus toggles the border opacity, a response snaps in, a status pill appears. The one motion event is the **jump-mode overlay** — pressing `ctrl+o` blankets the screen with accent-colored single-key labels docked over every widget.

- **Technique → feeling:** **no animation by default** → *snappiness as an aesthetic*. In a TUI, easing reads as lag; instantaneous redraw reads as *native, fast, keyboard-speed*. The stillness is the polish — the app never makes you wait on a transition.
- **Technique → feeling:** jump-mode's sudden overlay of accent-muted hatched labels (`.textual-jump-label { color: $text-accent; background: $accent-muted; text-style: bold; }`) → a Vimium/Vim-motions moment; the screen briefly becomes a *keyboard map*, which is both functional and a strong "power tool" identity beat.

---

## 11. Command palette & keybind footer: discoverability as texture

Two GUI-borrowed affordances anchor the "modern app" read:

**The command palette** (`ctrl+p`) is a centered, 65vw-wide overlay with a black 33%-tint scrim behind it, no full border, and the signature `border-left: wide $accent` bar down its input and list. It's the VS Code / Raycast command bar, faithfully reproduced.

```scss
CommandPalette {
  background: black 33%;                 /* dim the app behind */
  & > Vertical { margin-top: 2; width: 65vw; max-height: 65vh; }
  & #--input   { border-left: wide $accent; }
  & CommandList{ border-left: wide $accent; }
}
```

**The footer** is a persistent, always-visible keybind hint bar (Textual's `Footer`), showing `ctrl+j Send`, `ctrl+t Method`, `ctrl+o Jump`… Each binding carries a tooltip.

- **Technique → feeling:** a **dimming scrim** (`black 33%`) behind the palette → *modality and depth*; the app "steps back" while the palette floats forward. Z-depth simulated with a translucent wash — the terminal's only way to say "this is on top."
- **Technique → feeling:** the ever-present keybind footer → *discoverability as decoration*; the strip of `key description` pairs is both a cheat-sheet and a visual signature (it frames the bottom edge and says "keyboard-first tool"). Themes can even make the footer background `transparent` (galaxy/aurora/hypernova) so the hints float directly on the void.
- **Technique → feeling:** command palette + jump mode together → the identity of a **keyboard-native power tool**; the aesthetic *is* the interaction model made visible.

---

## 12. Identity moments

- **Startup:** no splash, no ASCII banner — the app just *is there*, header reading "**Posting** `2.10.0`" bold-over-dim, top-left. The restraint is the statement: it opens like an installed application, not a script announcing itself.
- **Signature colors:** amethyst `#C45AFF` + hot-pink `#FF69B4` (the galaxy default). Purple/pink is the memory hook — Posting is "the purple one."
- **Signature textures:** the diagonal `hatch` fill (empty states) and the `border: round $accent 40%→100%` ignite-on-focus panel.
- **The `user@host` chip → production dread.** A standout identity beat from the 2.0 release: hostnames in the header accept Rich markup, and the docs' hero example is `"[black on #ff0000 bold blink]PRODUCTION[/]"` — a **blinking red PRODUCTION badge** so you never fire a `DELETE` at the wrong environment. The author frames it around a real feeling: *"when working inside a TUI, it's sometimes easy to forget which host you're on."* Personality via *dread management*.
- **Empty states** never read as broken — hatched fill + `$text-muted` placeholder copy ("no body," etc.) make emptiness look intentional.
- **Error personality:** invalid inputs grow a `border-left: thick $error` red bar; unresolved variables turn red inline. Errors are handled in the same color grammar as everything else — no jarring modal, just the system's red vocabulary lighting up.

---

## 13. What makes it FEEL different from its siblings

Against other terminal HTTP clients and TUIs in general:

- **vs. `curl`/`httpie` (script tools):** those print flush-left, ephemeral, monochrome-ish. Posting has *chrome* — padded panels, persistent header/footer, a stateful colored layout. It's an *environment*, not a *command*.
- **vs. `k9s`/`lazygit`/htop-family (dense dashboards):** those pack information edge-to-edge with heavy/double borders and maximal density — the "cockpit" aesthetic. Posting goes the *opposite* way: generous whitespace, rounded thin borders, low-opacity chrome that recedes. It feels **calm and roomy** where the cockpits feel **busy and instrumented**.
- **vs. generic Textual apps:** Textual's out-of-the-box look is competent but blue-corporate. Posting overrides it into a **jewel-toned, purple-signature, semantically-color-coded** surface with a hand-authored theme gallery. It demonstrates that Textual is a *substrate*, and taste is the differentiator.

The essence: **Posting proves a terminal app can feel expensive.** It does so not with more pixels but with *restraint plus one loud accent* — a dim, tinted, well-padded dark canvas that stays quiet until your focus lands, then ignites exactly one region in amethyst and pink. Color always means something; whitespace does the framing; motion is banished so everything feels instant. The result reads as a designed product, and that "someone cared about this" signal is the whole aesthetic.

---

## 14. History, lineage, influences (from commits & sources)

- **Framework lineage:** Built on **Textual** (Will McGugan / Textualize), which Darren Burns co-develops. Posting is effectively the flagship demo of what Textual + **TCSS** + **Rich** can do — CSS-in-terminal is the enabling technology for the whole aesthetic.
- **Design lineage:** the semantic-token theme model, the `-muted`/`-lighten`/`-darken` scales, the `:focus-within` opacity lerp, and the command-palette-with-scrim are all **web-design patterns transplanted into cells**. The HTTP-verb palette being literal **Tailwind-500** hues confirms a web-native design sensibility.
- **Evolution:** Posting **1.0** launched mid-2024 (Show HN, Jul 2024) as "the modern HTTP client that lives in your terminal." **2.0** (Textual 1.0 era) brought "a better theming system," a richer command palette, the Scripts tab, and the customizable/Rich-markup hostname (the blinking-PRODUCTION beat). Theme growth is visible in git: commit `06d52ea` "Add hypernova and synthwave" (via PR #300 `new-themes`) shows the mood library expanding over time, with in-code comments (`# designed to WOW`, `# retro 80s… neon grids`) recording explicit aesthetic intent.
- **Author stance:** Burns positions Posting as **terminal-native, not a desktop imitation** — the polish serves keyboard-first, SSH-friendly workflows rather than mimicking Postman's chrome. On HN he noted a pragmatic constraint that shaped the look: *"There's no fallback to the ANSI theme of the terminal as it breaks a lot of Textual's features"* — i.e., Posting commits to its *own* truecolor palette rather than inheriting the user's 16-color scheme, which is precisely why it can guarantee the jewel-toned identity on every machine.

---

## 15. Notable quotes

- **Tagline (docs):** *"The API client that lives in your terminal."*
- **README:** *"A powerful HTTP client that lives in your terminal."*
- **themes.py inline comments:** `hypernova` — *"High-contrast neon theme designed to WOW"*; `synthwave` — *"Retro 80s synthwave aesthetic with neon grids and sunset vibes"*; `manuscript` — `# Ink blue`, `# Aged leather brown`, `# Parchment`, `# Aged paper`.
- **themes doc, on the semantic slots:** `accent: '#e74c3c'  # header text, scrollbars, cursors, focus highlights` — the accent's job spelled out: it's the *attention* color.
- **Posting 2.0 blog (hostname feature):** hero example `"[black on #ff0000 bold blink]PRODUCTION[/]"`, framed as *"when working inside a TUI, it's sometimes easy to forget which host you're on."*
- **Darren Burns, HN:** *"There's no fallback to the ANSI theme of the terminal as it breaks a lot of Textual's features."*
- **User (tusharsadhwani), HN:** *"This is already the best API testing client that I have found. It's lightweight, it's snappy, it's intuitive."*
- **config.py:** `theme: str = Field(default="galaxy")` — the default mood, in one line.

---

## 16. Links / sources

- Repo: https://github.com/darrenburns/posting
- README: https://github.com/darrenburns/posting/blob/main/README.md
- Themes doc: `docs/guide/themes.md` (in repo) / https://posting.sh
- Posting 2.0 announcement: https://darren.codes/posts/posting2/
- Author site / projects: https://darren.codes/ , https://darren.codes/projects/
- Show HN (v1) thread: https://news.ycombinator.com/item?id=40926211
- PyPI: https://pypi.org/project/posting/
- Key source files (local clone `undefined/posting/`): `src/posting/posting.scss`, `src/posting/themes.py`, `src/posting/config.py`, `src/posting/app.py`, `src/posting/widgets/response/response_area.py`, `src/posting/widgets/request/url_bar.py`
