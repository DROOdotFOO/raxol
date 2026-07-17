# Dossier: prompt_toolkit (Python)

> "`prompt_toolkit` *is a library for building powerful interactive command line applications in Python.*"
> — [project README](https://github.com/prompt-toolkit/python-prompt-toolkit)

- **Repo:** https://github.com/prompt-toolkit/python-prompt-toolkit
- **Docs:** https://python-prompt-toolkit.readthedocs.io
- **Author:** Jonathan Slenders (created ~2014)
- **Downstream that defines its look:** IPython (its input line since IPython 5.0), ptpython, ptipython, `pgcli`/`mycli`/`litecli`, `aws-shell`, `http-prompt`, `xonsh`, `poetry`'s prompts, and thousands of REPLs and CLI wizards.
- **Deps:** Pygments + wcwidth only. Pure Python, cross-platform (Linux/macOS/BSD/Windows).

prompt_toolkit is the invisible engine behind "the way modern Python prompts look." When you type into IPython and the code lights up *as you type*, when a gray ghost-suggestion trails your cursor, when a floating completion menu pops under the caret, when a reverse-video toolbar hugs the bottom of the screen — that is prompt_toolkit's house style leaking through. Its aesthetic opinion is not decorative; it is encoded in an API that makes *semantic, class-based theming* easy and *inline ANSI* hard. This dossier maps which concrete moves produce which feelings.

---

## 1. The Core Aesthetic Thesis: CSS for the Character Grid

prompt_toolkit's central design decision is to import the **stylesheet mental model of the web** into the terminal, and to say so out loud:

> "Like we do for web design, it is not a good habit to specify all styling inline."
> — [styling docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/advanced_topics/styling.html)

Everything downstream flows from this. UI controls carry **class names**, not colors. A separate **style sheet** maps class → style-string. The result is that a REPL author decorates their content semantically (`class:prompt`, `class:bottom-toolbar`, `class:completion-menu`) and a *theme* decides what those mean. This is the exact separation-of-concerns that makes the "polished REPL" aesthetic **retintable in one place**.

**Technique → feeling:** semantic class names (`prompt`, `bottom-toolbar`, `scrollbar`, `completion-menu`, `validation-toolbar`, `auto-suggestion`) instead of literal colors → the whole app can be re-skinned by editing one dict → produces a feeling of **coherence and intentionality**, the sense that this program was *designed*, not colored by hand. A prompt where the input, the toolbar, the menu, and the error bar all share a palette reads as a single object; one where each was hand-ANSI'd reads as a pile of `print` statements.

### The style-string micro-language

Style strings are a tiny CSS-of-the-terminal:

```
"fg:ansiyellow bg:black bold underline"
"bg:#008888 #ffffff"          # (bare hex after bg: is treated as fg)
"nobold noitalic"             # negation, so a child can undo a parent
"reverse"                     # swap fg/bg at the terminal level
```

Attributes: `bold`, `italic`, `underline`, `blink`, `reverse`, `hidden`, each with a `no…` negation. **Technique → feeling:** negatable attributes (`nobold`) → styles *cascade and override* like CSS rather than replace → gives themers the confidence to set a broad rule and carve exceptions, which is why prompt_toolkit themes feel *layered* rather than flat.

### Class definition, three ways

```python
# 1. inline string on a control
Window(..., style="class:left,bottom")

# 2. Style list (ordered, priority = source order)
style = Style([
    ('left',   'bg:ansired'),
    ('top',    'fg:#00aaaa'),
    ('bottom', 'underline bold'),
])

# 3. the canonical form everyone copies
style = Style.from_dict({
    'completion-menu.completion':         'bg:#008888 #ffffff',
    'completion-menu.completion.current': 'bg:#00aaaa #000000',
    'scrollbar.background':               'bg:#88aaaa',
    'scrollbar.button':                   'bg:#222222',
})
```

`Style.from_dict({...})` is *the* recognizable prompt_toolkit idiom — the snippet that says "this is a prompt_toolkit app" the way `st.title()` says Streamlit. Its very shape (a dict of dotted selectors → space-separated style tokens) trains authors to think in a theme table.

### Dotted selectors and the cascade

```
style="class:a.b.c"
# expands to:  "class:a class:a.b class:a.b.c"
```

> "If we write: `style="class:a.b.c"`, then this will actually expand to the following: `style="class:a class:a.b class:a.b.c`."

**Technique → feeling:** dotted class expansion → a syntax-highlight token like `pygments.keyword` or a menu state like `completion-menu.completion.current` inherits from its ancestors → the theme author can paint *the whole family* with one broad rule (`completion-menu`) and then *accent one member* (`.current`). This is precisely why completion menus in ptpython feel like a single object with a highlighted row rather than two unrelated colored bands. Space-joined multi-selectors (`'dialog frame.label'`, `'sidebar.label selected'`) further mimic CSS descendant selectors — style *this* only when nested inside *that*.

Priority: "we concatenate all the style strings from the root control through all the parents to the child in one big string," processed left-to-right, **rightmost wins**. Same rule as CSS specificity-by-order. The medium teaches its own logic: the theme *is* a stylesheet.

---

## 2. The Shipped Defaults: The House Style You Inherit for Free

The strongest aesthetic statement any library makes is its **defaults** — the look imprinted on every app whose author never touches theming. prompt_toolkit ships three merged default layers (`PROMPT_TOOLKIT_STYLE`, `WIDGETS_STYLE`, `COLORS_STYLE` in `styles/defaults.py`). Reading them is reading the house style.

### 2a. The prompt furniture (PROMPT_TOOLKIT_STYLE)

```python
("bottom-toolbar",                     "reverse"),
("auto-suggestion",                    "#666666"),
("completion-menu",                    "bg:#bbbbbb #000000"),
("completion-menu.completion.current", "fg:#888888 bg:#ffffff reverse"),
("completion-toolbar",                 "bg:#bbbbbb #000000"),
("scrollbar.background",               "bg:#aaaaaa"),
("scrollbar.button",                   "bg:#444444"),
("validation-toolbar",                 "bg:#550000 #ffffff"),
("search-toolbar",                     "bold"),
```

Read the screen this paints: a plain black-on-default input line. As you type, **gray ghost text** (`#666666`) trails to the right, the fish-shell prediction. Press Tab and a **light-gray floating slab** (`bg:#bbbbbb`, black text) drops under the cursor, its selected row punched out in **near-white reverse video**. Along the right edge of any scroll region sits a two-tone gutter: a `#aaaaaa` track with a `#444444` thumb. If your input fails validation, a **blood-dark red bar** (`bg:#550000`, white text) snaps to the bottom. And the bottom toolbar is simply `reverse` — no color, just fg/bg swapped, so it inverts *whatever the terminal's own colors are*.

**Technique → feeling, itemized:**
- `bottom-toolbar: reverse` (no hardcoded color, just invert) → a full-width bar that **adopts the user's terminal palette** → feels *native and ambient*, "the app is running and watching," while never fighting the user's chosen scheme. It's the single most recognizable prompt_toolkit tell.
- `auto-suggestion: #666666` — dim gray → **ghost text reads as "not yet real."** The specific mid-gray is dark enough to recede behind the cursor yet light enough to read: it says *prediction, not commitment*. This grayscale-for-speculative convention is load-bearing for the whole "assistive, live" personality.
- `completion-menu: bg:#bbbbbb #000000` — light gray slab, black text → a **floating physical card** hovering over the text plane → the depth illusion (a lighter rectangle over darker terrain) makes it feel like a *menu that popped up*, not text that appeared.
- `.completion.current: … reverse` — selected row inverted → the highlight **borrows the cell's own colors and flips them**, so the cursor-row always contrasts regardless of theme → feels crisp and unambiguous, IDE-like.
- `validation-toolbar: bg:#550000` — very dark desaturated red → **alarm without panic.** Not `#ff0000`; a muted oxblood that signals error while keeping you *inside* the editing flow rather than yanking you out.

### 2b. The dialog toolkit: deliberate DOS / Turbo Pascal nostalgia (WIDGETS_STYLE)

This is the most emotionally specific thing in the library. The default dialog theme is a near-exact recreation of **Borland Turbo Vision** — the blue-background, shadowed, double-bordered dialogs of Turbo Pascal and early-90s DOS IDEs:

```python
("dialog",                 "bg:#4444ff"),        # cornflower/royal DOS blue field
("dialog.body",            "bg:#ffffff #000000"), # white paper panel, black ink
("dialog frame.label",     "#ff0000 bold"),       # red bold title on the frame
("dialog.body scrollbar.button", "bg:#000000"),
("button",                 ""),
("button.focused",         "bg:#aa0000 #ffffff"), # focused button = dark-red block, white text
("dialog shadow",          "bg:#000088"),         # drop shadow = darker navy
("dialog.body shadow",     "bg:#aaaaaa"),         # inner shadow = gray
```

**Describe the screen:** a **royal-blue backdrop** (`#4444ff`) fills the terminal. Centered on it floats a **white panel** (`#ffffff`) with black text — a sheet of paper on a blue desk. The panel's frame carries a **bold red title label**. Toward the panel's lower-right, a band of **darker navy** (`#000088`) sits offset by one cell down and right — a *drop shadow* that lifts the dialog off the blue field into a fake third dimension. Tab between buttons and the focused one becomes a **solid dark-red block with white text** (`#aa0000`/`#ffffff`), the same crimson as the Turbo Vision default button highlight.

**Technique → feeling:**
- `dialog bg:#4444ff` — saturated royal blue field → instantly reads as **"install wizard / BIOS setup / Norton Commander."** Blue was the DOS-era "system chrome" color; using it says *this is a serious modal decision* while wrapping it in warm nostalgia.
- `dialog shadow: bg:#000088` offset from the body → a **1-cell darker-blue shadow** is the entire 3D trick. Two flat rectangles, one darker and shifted, and the eye reads *elevation*. This is the character-grid equivalent of a CSS `box-shadow`, achieved with nothing but a second colored rectangle.
- `dialog.body bg:#ffffff #000000` — white-on-blue panel → maximum figure/ground separation → the dialog **commands the screen**; you cannot ignore it, which is exactly what a modal wants.
- `frame.label #ff0000 bold` — red bold title → the one hot accent on an otherwise blue/white/gray composition → your eye lands on the title *first*. Red-on-white-panel is pure Borland.
- `button.focused bg:#aa0000 #ffffff` — dark-red focus block → keyboard focus is a **filled color swatch**, not an underline or bracket → focus feels *physical*, a lit button you're about to press.

The dialog shortcuts (`message_dialog`, `yes_no_dialog`, `input_dialog`, `button_dialog`, `radiolist_dialog`, `checkboxlist_dialog`, `progress_dialog`) all inherit this theme, so *any* one-liner wizard you build with prompt_toolkit's high-level API is born wearing the Turbo Pascal costume unless you override it:

```python
from prompt_toolkit.shortcuts import yes_no_dialog
yes_no_dialog(title="Confirm", text="Do you want to continue?").run()
# -> blue field, white shadowed panel, red title, red focused buttons. Free.
```

**The aesthetic opinion:** by making the retro-DOS look the *default*, prompt_toolkit stakes a claim — terminal modals should feel like the confident, chrome-heavy dialogs of the golden age of DOS tooling, not like bare `input()` prompts. It's nostalgia as a design default.

### 2c. ptpython's overlay: the "live assistive IDE" personality

ptpython (`ptpython/style.py`) layers its own `default_ui_style` on top, and this is where the "IDE-in-a-terminal" mood is built:

```python
"in":                            "bold #008800",       # green input prompt marker
"out":                           "#ff0000",            # red output marker
"prompt":                        "bold",
"completion.param":              "#006666 italic",      # italic teal param hints
"completion.keyword":            "fg:#008800",
"signature-toolbar":             "bg:#44bbbb #000000",  # cyan call-signature strip
"signature-toolbar current-name":"bg:#008888 #ffffff bold",
"status-toolbar":                "bg:#222222 #aaaaaa",  # dark charcoal status bar
"validation-toolbar":            "bg:#440000 #aaaaaa",
"sidebar":                       "bg:#bbbbbb #000000",  # gray options sidebar
"sidebar.title":                 "bg:#668866 #ffffff",  # muted green title
"sidebar.label selected":        "bg:#222222 #eeeeee",
"docstring":                     "#888888",             # dim gray docstrings
"window-border":                 "#aaaaaa",
```

**Describe the screen:** a `>>>`-style prompt in **bold green**, output tagged in **red**. Type an open-paren and a **cyan signature strip** (`bg:#44bbbb`) surfaces showing the function's parameters, the current argument brightened to `bg:#008888` white-bold. Along the bottom, a **charcoal status bar** (`bg:#222222`, muted gray text) reports mode. Press F2 and a **light-gray sidebar** slides in with a soft **sage-green title** (`#668866`) and a dark-charcoal selection cursor. Docstrings float in **quiet gray** (`#888888`).

**Technique → feeling:**
- green `in` / red `out` markers → **traffic-light IO semantics** → input vs output is legible at a glance without reading a single word; the REPL feels *structured*, like a transcript.
- `signature-toolbar bg:#44bbbb` cyan → a **teal call-tip band** that appears/disappears with context → the shell feels *attentive*, reaching to help mid-expression. Cyan (a color reserved for help/hints across the theme) becomes the "assistant is speaking" color.
- `docstring #888888` gray → documentation whispers rather than shouts → **calm authority**, info-on-demand that never crowds the code.
- muted, desaturated palette overall (`#668866`, `#44bbbb`, `#222222`) → nothing is fully saturated → reads as **professional / tasteful** rather than toy-bright. This restraint is the "grown-up REPL" signature that separates ptpython from a rainbow-colored shell.

---

## 3. Color-Depth Adaptation: Theming as Discipline Across 4 Palettes

prompt_toolkit exposes four explicit color depths and expects a *good* theme to survive all of them:

- `ColorDepth.DEPTH_1_BIT` — monochrome
- `ColorDepth.DEPTH_4_BIT` — 16 ANSI colors
- `ColorDepth.DEPTH_8_BIT` — 256 colors *(default)*
- `ColorDepth.DEPTH_24_BIT` — truecolor

Set via `Application(color_depth=...)` or the `PROMPT_TOOLKIT_COLOR_DEPTH` env var. The degradation rule is explicit:

> "When 4 bit color output is chosen, all colors will be mapped to the closest ANSI color."

**The aesthetic discipline this implies:** because a `#4444ff` will be *snapped to the nearest ANSI blue* on a 16-color terminal, a theme author must design so the composition **still reads with only 16 colors** — the DOS-blue dialog collapses gracefully to `ansiblue`, the red buttons to `ansired`, the gray menu to `ansiwhite`/`ansigray`. This is why the defaults lean on colors that *have* clean ANSI analogues. **Technique → feeling:** designing hex colors that degrade to sensible ANSI → the app looks *deliberate on a cheap terminal and rich on a good one* → produces trust; it never looks broken.

Two tells of this discipline in the API:
- **Named ANSI colors as first-class citizens.** You can write `fg:ansired`/`bg:ansibrightblue` instead of hex, which means the color *is* whatever the user's terminal theme defines. ptpython's `default-ansi` scheme is built entirely from `ansigreen`, `ansiblue`, `ansibrightblack`, etc. **Feeling:** a theme in pure ANSI names **inherits the user's own palette** (their Solarized, their Dracula) → the app feels like it *belongs* to the user's terminal, chameleon-like, rather than imposing.
- **`AdjustBrightnessStyleTransformation(min_brightness, max_brightness)`** — a runtime transform that lifts too-dark or crushes too-bright colors so a theme designed for dark backgrounds stays legible on light terminals. **Feeling:** the theme *adapts to the room's lighting*; nothing disappears into the background.

The offered choice between 16 named-ANSI colors (user-owned, chameleon) and 24-bit hex (author-owned, exact) is itself an aesthetic fork: *do you want your app to look like the user's terminal, or like your brand?* prompt_toolkit makes both one keyword apart.

---

## 4. Syntax Highlighting as Tone (Pygments Integration)

prompt_toolkit renders input through **Pygments lexers**, and lets you attach any Pygments style:

```python
from prompt_toolkit.styles.pygments import style_from_pygments_cls
from pygments.styles import get_style_by_name
style = style_from_pygments_cls(get_style_by_name('monokai'))
```

Because Pygments tokens flow through the *same* dotted-class cascade (`pygments.keyword`, `pygments.string`, …), the choice of Pygments theme sets the **entire emotional temperature of the prompt**:

**Technique → feeling:**
- `monokai` → warm charcoal background feel, hot pinks/greens/oranges → **energetic, modern, "hacker cool."**
- `solarized-dark` → low-contrast ochres and cyans on teal-black → **calm, easy, deliberately un-flashy, "designed."**
- `bw` / no lexer → plain text → **austere, serious, minimal** — the choice IPython-in-a-pipe or a scripting tool makes to say *I am a tool, not a toy.*

Syntax color *while typing* (not after Enter) is itself the aesthetic: the prompt becomes a **live editor**, and the tokenizer's color choices are the closest thing a terminal REPL has to "typography." Selecting a Pygments theme is the terminal-app equivalent of a web designer choosing a typeface + palette in one move.

---

## 5. Layout Furniture: Building the "Full-Screen App" Look

Beyond prompts, prompt_toolkit is a full TUI toolkit whose container vocabulary produces the framed, paneled, status-barred look of a real application:

- **`HSplit` / `VSplit`** — stack rows / columns (the API borrows the *split* metaphor, not flexbox terms).
- **`Window`** — "the leaves in the tree structure that represent the UI"; owns scrolling, line-wrap, margins (scrollbars, line numbers), cursor-line/column highlighting, alignment, and a **background fill character**.
- **`Frame`** — draws a **border with an optional title label** (the `dialog frame.label` red title lives here).
- **`Box`** — padding container.
- **`Float` / `FloatContainer`** — overlay elements (the mechanism behind floating completion menus and pop-ups).
- **`ScrollablePane`** — long scrollable forms.
- **`TextArea`, `Label`, `Button`, `VerticalLine`** — ready widgets.

**Technique → feeling:**
- **Frames with title labels** → box-drawing rectangle + a word inset in the top border → instantly reads as a **titled panel / window**, the single strongest "this is an application, not a script" signal on the character grid.
- **`Float` completion/pop-up menus** → menus that visually *overlap* the content plane rather than pushing it → creates **z-depth**, the feeling of layers stacking toward the viewer, which no amount of inline flow can produce.
- **`Window` background fill character** → an empty pane can be filled with a chosen glyph (dots, shades) → lets a designer give **texture to negative space**, e.g. a dotted void that reads as "nothing here yet" vs a blank that reads as "loading."
- **cursor-line / cursor-column highlight** → a faint tinted row/column following the caret → the **"you are here" glow** of a spreadsheet or editor; the app feels *inhabited*.

Input **Processors** (`PasswordProcessor` → asterisks, `TabsProcessor`, `ShowTrailingWhiteSpaceProcessor`, highlight-search/selection) post-process the rendered text — turning invisible structure (whitespace, tabs, matches) into **visible marks**. **Feeling:** making the invisible visible reads as *precision tooling*, the app that cares about the bytes.

Right-prompt (`rprompt`) and multiline continuation prompts add symmetry:
```python
def prompt_continuation(width, line_number, is_soft_wrap):
    return "." * width      # dotted gutter down the left of every wrapped line
```
**Feeling:** a dotted continuation gutter turns a multiline paste into a **visually bracketed block** — it looks *composed*, like a code cell, not a runaway line.

---

## 6. What the API Makes Easy vs Hard (the opinion is in the ergonomics)

Every library's deepest aesthetic statement is what it makes *frictionless*:

- **Easy:** semantic class names, `Style.from_dict`, Pygments themes, ANSI-named colors, a whole shipped dialog theme, ghost-suggestions, bottom toolbars. → The path of least resistance leads to a **coherent, themeable, assistive** app.
- **Hard / discouraged:** hand-writing raw ANSI escapes, per-character inline color, imperative "move cursor, set red, print" style. The docs explicitly scold inline styling ("not a good habit"). → The library **structurally nudges you away from the pile-of-print-statements look** and toward the stylesheet.
- **No global state** (a headline feature) → the same app runs identically in a terminal, an asyncio task, or an SSH/telnet server. **Aesthetic consequence:** the look is *portable and consistent* across surfaces; a prompt_toolkit app served over SSH looks exactly like the local one. Consistency is itself a vibe.

This is the same trick Lip Gloss (borrowing CSS flexbox terms) and Textual (borrowing web CSS wholesale) later pulled: *encode a design philosophy in the vocabulary of the API.* prompt_toolkit got there first for Python by borrowing CSS's **class + stylesheet + cascade + specificity-by-order** model and mapping it onto the character grid.

---

## 7. Community Showcase Vibes

- **IPython** (input line since 5.0): green/colored syntax highlighting while typing, the multi-column completion menu, the fish-style history suggestion — the "modern Python REPL" look millions recognize is *prompt_toolkit wearing IPython's clothes*.
- **ptpython / ptipython**: the fullest expression — sidebar config panel, cyan signature toolbars, charcoal status bar, docstring pane. The "IDE compressed into a REPL" mood.
- **`pgcli` / `mycli` / `litecli`**: SQL keyword highlighting + smart completion menus → make a database shell feel **intelligent and modern**, a major reason these tools spread.
- **`http-prompt`, `aws-shell`, `xonsh`**: prove the aesthetic generalizes — any domain CLI gains the same live-highlight, floating-menu, bottom-toolbar personality.

The through-line: apps built on prompt_toolkit share a **family resemblance** — live syntax color, gray ghost-suggestions, floating gray completion cards, reverse-video status bars, and (in dialogs) shadowed DOS-blue modals. That family resemblance *is* the house style.

---

## 8. Notable Quotes (with sources)

- "`prompt_toolkit` *is a library for building powerful interactive command line applications in Python.*" — [README](https://github.com/prompt-toolkit/python-prompt-toolkit)
- "Like we do for web design, it is not a good habit to specify all styling inline." — [Styling docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/advanced_topics/styling.html)
- "If we write: `style="class:a.b.c"`, then this will actually expand to the following: `style="class:a class:a.b class:a.b.c`." — [Styling docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/advanced_topics/styling.html)
- "When 4 bit color output is chosen, all colors will be mapped to the closest ANSI color." — [Styling docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/advanced_topics/styling.html)
- "Usually, the input is compared to the history and when there is another entry starting with the given text, the completion will be shown as gray text behind the current input." — [Asking for input docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/asking_for_input.html)
- "A custom `Style` instance can be passed to all dialogs to override the default style." — [Dialogs docs](https://python-prompt-toolkit.readthedocs.io/en/master/pages/dialogs.html)
- Feature bullets incl. "Syntax highlighting of the input while typing" and "Auto suggestions (fish shell-like)" and "No global state" — [README](https://github.com/prompt-toolkit/python-prompt-toolkit)

---

## 9. Lineage & Influences

- **Upstream inspiration:** GNU Readline / BPython (the "better REPL" tradition) for *what* to build; **CSS/HTML** for *how to theme it*; **fish shell** for the gray autosuggestion; **zsh** for `RPROMPT`; **Borland Turbo Vision / Turbo Pascal DOS IDEs** for the default dialog costume.
- **Peers / descendants it shaped:** its class-based theming prefigures **Textual** (Slenders-adjacent Python TUI wave) and rhymes with Go's **Lip Gloss / Bubble Tea** and Rust's **ratatui** — all of which encode a design system in API vocabulary. prompt_toolkit is the Python node in the "terminal apps deserve a real design system" movement.
- **Key architectural facts feeding the aesthetic:** pure Python, Pygments + wcwidth only, wide-char (CJK) aware, no global state, runs over SSH/telnet/asyncio — so the look is portable and the width math is correct (double-width chars don't break box borders).

---

## 10. Design Cheat-Sheet — Technique → Vibe

| Concrete technique | Vibe it produces |
|---|---|
| `bottom-toolbar: reverse` (invert, no color) | Native, ambient status bar that adopts the user's palette; "the app is live" |
| `auto-suggestion: #666666` gray ghost text | Predictive/assistive; "not yet real," fish-shell helpfulness |
| `completion-menu: bg:#bbbbbb #000000` floating slab | A physical card popping over the text plane; IDE depth |
| `.completion.current: reverse` | Crisp, theme-agnostic selection highlight |
| `dialog: bg:#4444ff` + `shadow: bg:#000088` | Turbo Pascal / DOS-wizard nostalgia; a modal that commands the screen |
| `button.focused: bg:#aa0000 #ffffff` | Focus as a lit physical button, not an underline |
| `validation-toolbar: bg:#550000` oxblood bar | Alarm without panic; error inside the flow |
| Pygments theme choice (monokai/solarized/bw) | Sets the prompt's entire emotional temperature |
| ANSI-named colors (`ansiblue`) vs hex | Chameleon (user's palette) vs branded (author's exact color) |
| DEPTH_1/4/8/24 + closest-ANSI degrade | Discipline: deliberate on cheap terminals, rich on good ones; trust |
| `Frame` with title label (box-draw + inset word) | "This is an application," a titled window |
| `Float` completion/pop-ups | Z-depth, layers stacking toward the viewer |
| Green `in` / red `out` markers (ptpython) | Traffic-light IO; the REPL reads as a structured transcript |
| `signature-toolbar: bg:#44bbbb` cyan strip | Attentive assistant reaching to help mid-expression |
| `docstring: #888888` dim gray | Calm authority; info-on-demand that never crowds |
| Semantic class + `Style.from_dict` (whole thesis) | Coherence; the app was *designed*, retintable in one place |
```
