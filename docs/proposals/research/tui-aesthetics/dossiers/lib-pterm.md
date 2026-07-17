# pterm (Go) — Aesthetic Dossier

> "💻 PTerm | Pretty Terminal Printer — A modern Go framework to make beautiful CLIs"
> "PTerm guarantees beautiful output whether it's Windows CMD, macOS iTerm2 or in the backend (for example inside a GitHub Action)."

**What it is:** A batteries-included Go library by Marvin J. Wendt (@MarvinJWendt) built around pre-styled *Printers* and a single central *Theme*. The whole design bet is one sentence: **beauty should be the default, achieved with zero styling code.** You call `pterm.Success.Println("done")` and get a green badge, aligned, colored, cross-platform — no config, no style objects, no layout math. Where Charm's Lip Gloss hands you a paintbox and asks you to compose, pterm hands you a finished, opinionated house style and asks you to *just print*. It is the "template vs. blank canvas" pole of the Go TUI world.

Repo cloned to `scratchpad/pterm`. The aesthetic lives almost entirely in three files: `theme.go` (the ~60-field `Theme` struct + `ThemeDefault`), `prefix_printer.go` (the semantic badge vocabulary), and the `Default*` package vars scattered across each `*_printer.go` (the shipped defaults that *are* the house style). Palette is plain ANSI 16-color names from `color.go`, TrueColor via `rgb.go`.

---

## 1. The identity in one sentence

pterm dresses every Go CLI in the same **friendly, cheerful, cyan-and-magenta uniform**: uppercase status badges on saturated color backgrounds, rounded-corner boxes, braille-dot spinners, block-shaded progress bars, and a hand-drawn full-block headline font — all wired to one overridable `Theme` so a single tool, or a hundred tools built by different authors, all look like they came out of the *same* polished product studio. Its signature is **`FgLightCyan` primary + `FgLightMagenta` secondary**: a bright, almost toy-like duotone that reads as approachable and modern, the deliberate opposite of the austere monochrome that "serious" Rust/Unix tools wear.

---

## 2. The philosophy: "Printers", not "styles"

The API's central noun tells you the whole worldview. Charm's Lip Gloss borrows **CSS** (`.Border()`, `.Padding()`, `.Align()`, flexbox joins) — it's a *styling* vocabulary, you assemble looks. Textual borrows **web CSS** wholesale. pterm instead borrows the **print statement**: `Info`, `Success`, `Warning`, `Error`, `DefaultTable`, `DefaultSpinner`, `DefaultProgressbar` are all *Printers* — pre-composed objects you invoke. The verb is always `Print`/`Println`/`Sprint`/`Srender`.

This is the aesthetic opinion, encoded in grammar:

- **What it makes trivially easy:** semantically-labelled, consistently-colored output. `pterm.Success.Println(...)` is one call. The beauty is free.
- **What it makes deliberately harder:** bespoke, pixel-tuned, one-off layouts. There is no flexbox, no constraint solver, no reactive component tree. If you want a truly custom look you override the `Theme` or chain `.With*()` builders — but you are nudged, hard, toward the shipped defaults.

The README's four stated pillars — **Easy to use, Cross-Platform, Consistent Colors, Component system, Configurable** — are ranked in that order on purpose. "Consistent Colors" explicitly means *"PTerm uses the ANSI color scheme for uniformity and supports TrueColor for advanced terminals."* The house style is built on the **16-color ANSI palette first** so it renders identically on Windows CMD, iTerm2, and a headless CI log — TrueColor is an enhancement, never a dependency. **Feeling produced:** trust and predictability. You never get the "looks great on my machine, garbage in the CI log" betrayal. Beauty that survives the lowest-common-denominator terminal reads as *engineered*, not merely *decorated*.

---

## 3. The Theme struct — one dial that retints everything

`theme.go` defines `Theme`, a flat struct of **~60 named `Style` fields**, and `ThemeDefault`, the single populated instance every Printer reads from by default (`MessageStyle: &ThemeDefault.InfoMessageStyle`, etc. — note the *pointer*: printers hold references into the live theme).

```go
ThemeDefault = Theme{
    PrimaryStyle:        Style{FgLightCyan},
    SecondaryStyle:      Style{FgLightMagenta},
    HighlightStyle:      Style{Bold, FgYellow},
    InfoPrefixStyle:     Style{FgBlack, BgCyan},
    SuccessPrefixStyle:  Style{FgBlack, BgGreen},
    WarningPrefixStyle:  Style{FgBlack, BgYellow},
    ErrorPrefixStyle:    Style{FgBlack, BgLightRed},
    FatalPrefixStyle:    Style{FgLightWhite, BgRed, Bold},
    ...
}
```

**The aesthetic power move:** because it's a package-level `var`, `pterm.ThemeDefault = pterm.ThemeDefault.WithPrimaryStyle(...)` (or a wholesale reassignment) **retints the entire application at once** — every table header, spinner, box title, bullet, and progressbar shifts in one line, because they all dereference the same struct. There is no per-widget restyling ceremony. This is the "one override, whole app" contract, and it's what lets a house style feel *coherent*: the color relationships are defined once, centrally, and radiate outward.

The `.With*Style()` methods (`WithPrimaryStyle`, `WithInfoPrefixStyle`, ~30 of them) return a **modified copy** (value receiver `t Theme`), so you can fork a theme without mutating the global — the immutable-builder pattern borrowed from functional Go idiom. **Feeling:** the theme is a *design token table*, exactly like a CSS `:root` custom-property block. Naming the tokens (`SuccessPrefixStyle`, `BulletListBulletStyle`, `TreeStyle`) is itself the design thinking made legible — the struct field list *is* a spec of "every place color has meaning in a CLI."

The default palette leans hard on **cyan** (`FgLightCyan` / `FgCyan` / `BgCyan` appear in Primary, Info, Progressbar title+bar, Header background, Spinner, Table header, Box title, Bullet, Bar label, Logger info) with **magenta** (`FgLightMagenta`) as Secondary/Section accent, **green** for success, **yellow** for warning/highlight, **red** for error/fatal, and **gray** for structural chrome (trees, boxes, separators, timers, scopes). Cyan+magenta as the dominant duo is a distinctly *cheerful, saturated, slightly retro* choice — the same energy as the repo's own magenta codecov and unit-test badges. It is the palette of a tool that wants to look *friendly*, not *dangerous*.

---

## 4. Prefix printers — the semantic badge vocabulary

This is pterm's most-used and most-recognizable surface, and its cleverest bit of tone design. `prefix_printer.go` ships six pre-built `PrefixPrinter` singletons. Each renders a **colored badge (foreground text on a solid background block)** followed by the message in a matching foreground hue.

| Printer | Badge text | Badge style | Message style | Emotional register |
|---------|-----------|-------------|---------------|--------------------|
| `Info` | `" INFO  "` | black on **cyan** bg | light-cyan | calm, neutral, "just so you know" |
| `Success` | `"SUCCESS"` | black on **green** bg | green | reassuring, "it worked" — the dopamine hit |
| `Warning` | `"WARNING"` | black on **yellow** bg | yellow | caution, hazard-tape, "look but don't panic" |
| `Error` | `" ERROR "` | black on **light-red** bg | light-red | alarm, "something failed" |
| `Fatal` | `" FATAL "` | **bold white on deep-red** bg | light-red | maximum severity — the only *bold* + *dark-red* badge, and it kills the process |
| `Debug` | `" DEBUG "` | black on **gray** bg | gray | muted, backgrounded, off by default |
| `Description` | `"Description"` | white on **dark-gray** bg | default | quiet annotation, low-priority context |

Three deliberate techniques generate the tone:

1. **Solid-background badges, not colored glyphs.** pterm does *not* just print a green `✓` — it prints a filled color block with black text inside. On a dark terminal a `BgCyan` badge is a little **paint chip** glued to the left margin. **Feeling:** legible at a glance, punchy, "app that spent money on packaging." It reads as UI, not as log text. The color-on-black-text choice (`FgBlack, BgCyan`) maximizes contrast so the label pops even in a fast-scrolling log.

2. **Uppercase labels padded to equal width.** The badge texts are `" INFO  "`, `"WARNING"`, `"SUCCESS"`, `" ERROR "`, `" FATAL "`, `" DEBUG "` — all **exactly 7 characters**, with leading/trailing spaces added specifically (per the source comment) *"so all default prefix badges share the same width and messages line up when different printers are mixed."* **Feeling:** the left edge of every message text forms one clean vertical rule. Mixed `Info`/`Success`/`Error` output tabulates itself. This is the single detail that most makes pterm output look *designed* rather than *emitted* — alignment is the cheapest luxury signal on a character grid, and pterm bakes it in for free.

3. **The Checkmark pair.** `Theme.Checkmark{ Checked: Green("✓"), Unchecked: Red("✗") }` — the green-check / red-cross dyad, the universal "pass/fail" glyph vocabulary, shipped as a theme token so interactive confirms and checklists speak it consistently. **Feeling:** instantly-parsed success/failure semantics; the ✓/✗ is culturally pre-loaded, no legend needed.

The emotional map is a **traffic-light + severity gradient**: green (go/good) → cyan (neutral info) → yellow (caution) → red (error) → bold-dark-red (fatal) → gray (debug/muted). A developer reading pterm output never has to *decode* status; the color does it pre-cognitively. That is the whole value proposition of a shipped semantic palette: it turns "what does this line mean?" into a peripheral-vision reflex.

---

## 5. Structured-output printers — one product, many data shapes

pterm's second act is making *every* data structure wear the same uniform, so a multi-command CLI feels like one coherent tool. The defaults (from each `*_printer.go`):

- **Box** (`DefaultBox`): **rounded corners** `╭ ╮ ╰ ╯`, thin `│`/`─` edges in **gray**, title in **bold light-cyan**, title top-left by default, 1 column of left/right padding, 0 vertical. **Feeling:** the rounded corners are the single biggest "friendly/soft/modern" signal — sharp `┌┐└┘` corners read institutional and severe; `╭╮╰╯` read approachable, almost *rounded-rectangle-button* soft. This one glyph choice does most of pterm's "warm" personality work at the structural level. Title can be repositioned to any of six anchor points (top/bottom × left/center/right) via `.WithTitle*()`.

- **Header** (`DefaultHeader`): a full-width **solid color band** — bold light-white text on a **gray** (`BgCyan` in some presets) background, `Margin: 5` of padding around the text. **Feeling:** a colored banner strip is a website `<header>` translated to the grid; it reads as a section masthead, "important, framed, top-of-page." When centered/full-width it's polished; over-used it tips into "overproduced brochure."

- **Section** (`DefaultSection`): a **magenta bold** heading prefixed with the `»` guillemet indent character, 1 blank line above and below. **Feeling:** `»` is a distinctive, slightly editorial choice (vs. a plain `#` or `>`) — it says "here begins a movement," lighter and more typographic than a boxed header. The vertical padding gives output *breathing rhythm*, whitespace as pacing.

- **Table** (`DefaultTable`): body in default fg, **bold light-cyan** headers, **gray** separators; optional `.WithBoxed()` wraps it in the rounded box. **Feeling:** the bold-cyan header row is the "this is a real table, not aligned text" tell; the gray separators recede so data dominates.

- **Tree** (`DefaultTree`): classic `└ ├ │ ─` connectors in **gray**, 2-space indent, with an optional `┬`-style connector for parent nodes. **Feeling:** the muted-gray skeleton keeps the *structure* quiet so the *labels* read as content — the tree lines are scaffolding, not decoration.

- **BulletList** (`DefaultBulletList`): a **cyan `•`** bullet, default-fg text. Simple, warm, consistent.

- **BarChart** (`DefaultBarChart`): `██` (double full-block) vertical bars, `█` horizontal, sized to **2/3 of the terminal** width/height, optional value labels. **Feeling:** solid full-block bars are chunky and confident — data as *architecture*, not sparkline-delicate. The 2/3 auto-sizing means charts feel proportioned to the window without manual tuning.

- **Heatmap**: a green→yellow→red cell-background ramp (`BgRed, BgLightRed, BgYellow, BgLightYellow, BgLightGreen, BgGreen`) with an RGB-range TrueColor variant — the same traffic-light semantics extended to a grid.

The through-line: **consistent border glyphs, consistent indent units, consistent accent color (cyan) across radically different data shapes.** A tree, a table, and a box all share the same gray chrome and cyan-highlight logic, so switching between `list`, `status`, and `tree` subcommands in one CLI never feels like switching apps. *That* coherence — not any single widget — is what makes pterm output feel like "one designed product."

---

## 6. Decorative headliners — the welcome-banner aesthetic

- **BigText** (`DefaultBigText`): despite common description as "figlet fonts," pterm ships its **own hand-drawn full-block font** — a map of each character to a 7-row-tall glyph built from `█` solid blocks (e.g. the letter `a` is a 7-line `█████ / ██ ██ / ███████ / ...` grid). `putils.LettersFromString` / `LettersFromStringWithStyle` feed it, and you can color each letter-run independently. The canonical example is the demo's own logo: `LettersFromStringWithStyle("P", FgLightCyan)` + `LettersFromStringWithStyle("Term", FgLightMagenta)` — a **cyan "P" + magenta "Term"** big-block wordmark, centered. **Feeling:** the block-letter banner is the "app has arrived, here is its NAME" moment — it borrows the demoscene/ASCII-art tradition of the splash screen. Solid `█` blocks (vs. figlet's outline fonts) read *bolder and more modern*, less 1990s-BBS. Deployed once at startup it's a confident brand stamp; sprayed everywhere it would be kitsch.

- **RGB / gradient text** (`rgb.go`): `pterm.NewRGB(0,255,255)` (cyan) `.Fade(...)` to `NewRGB(255,0,255)` (magenta) paints a **per-character TrueColor gradient** across a string — the demo literally fades a paragraph from cyan to magenta. `Fade` interpolates in RGB space across one or many stops. **Feeling:** the gradient is pterm's "look what your terminal can do" flourish — iridescent, playful, a wink. It always degrades to a flat color on non-TrueColor terminals, so it's decoration-that-can't-break. The chosen endpoints (cyan→magenta) are, again, the house duotone — even the fancy effect stays on-brand.

- **Center** (`DefaultCenter`): centers any content (including multi-line boxes and bigtext) in the terminal width, with `.WithCenterEachLineSeparately()`. **Feeling:** centering is the layout gesture that says "this is a title card / splash / dialog, not a log line." Combined with a box + bigtext it produces the full "polished welcome screen" — the visual grammar of *presentation* rather than *stream*.

---

## 7. Live components — motion as personality

- **Spinner** (`DefaultSpinner`): the **braille-dot sequence** `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` cycled at **100ms/frame**, drawn in **light cyan** with **light-white** message text and a running **timer** (gray) shown by default. `.WithRemoveWhenDone()` erases it on completion; success/warning lines can be printed *above* a running spinner. **Feeling:** the braille spinner is the *lightest, smoothest* rotation glyph available — 8-dot cells make it look like a fluid orbit rather than a clunky `| / - \`. 100ms is brisk-but-not-frantic. Cyan + running timer = "calmly working, and being honest about how long." The braille spinner has become almost a genre convention precisely because it feels premium; pterm makes it the default so every app gets that texture for free.

- **Progressbar** (`DefaultProgressbar`): filled with `█` in **cyan**, unfilled track `░` (light shade) in **dark-gray**, `MaxWidth: 80`, and by default shows **title + count + percentage + elapsed time** all at once. `.UpdateTitle()` lets the label change per-step ("Installing chrome…", "Installing git…"). **Feeling:** the `█`-on-`░` contrast is the classic solid/shade pairing — the bar has *texture*, the filled portion reads as dense/heavy and the track as light/empty, so progress feels physically substantial. Showing four metrics by default is pterm's "informative by default" bias (from the tagline: *"makes terminal output look better and more informative"*): it assumes you'd rather see too much status than too little.

- **Area** (`DefaultArea`): a redraw region for arbitrary in-place updates — the primitive under live clocks, dynamic charts, animated boxes, and fullscreen modes. `area.Update(...)` overwrites the region each frame. **Feeling:** the aesthetic of *continuous in-place mutation* — a value that ticks, a chart that grows, a box that morphs — is what separates a "living" TUI from a scrolling log. Area is the engine that lets pterm's otherwise line-oriented printers become animated. The demo drives a centered clock, a dynamic bar chart, and a box that iteratively grows its padding/title through an Area, showing the same static Printers made kinetic.

- **Logger** (`DefaultLogger`): structured logging with **bold colored level tags** — Trace (bold gray), Debug (bold blue), Info (bold cyan), Warn (bold yellow), Error (bold red), Fatal (bold white-on-red) — plus key/value `Args`, timestamps (gray), and **automatic wrapping of long messages**. **Feeling:** it brings the semantic-color discipline of the prefix printers into the structured-logging idiom (à la zerolog/slog) — every log line is pre-sorted by severity color, and long lines wrap cleanly instead of producing "weird line breaks." Consistency between casual `pterm.Info` and formal `Logger.Info` means a tool can grow from script to service without changing visual language.

---

## 8. Describe the screen — the pterm demo, in words

Boot the flagship demo (`_examples/demo/demo`, the VHS-recorded GIF on the README). The screen **clears to black, then centered near the top blooms a two-tone block-letter wordmark: a cyan `P` fused to a magenta `Term`,** each glyph a solid stack of `█` blocks seven rows tall. Below it, a **full-width light-blue banner bar** with magenta bold text reads *"PTDP - PTerm Demo Program."* Then a **cyan `INFO` badge** — black text in a filled cyan chip — introduces a paragraph, with the word `./_examples/demo` glowing magenta and a green timestamp at the end.

Cut to structured logging: lines march down, each stamped with a **bold color level tag** — gray `TRACE`, blue `DEBUG`, cyan `INFO`, yellow `WARN`, red `ERROR` — trailing `key=value` args. Cut to a **progress bar**: a cyan `████████░░░░░░` track at 80 columns, its title mutating *"Installing chrome… Installing git… Installing vscode…"* while **green `SUCCESS` badges** stack above it, one per package. Cut to a **braille spinner** — a smooth cyan orbit `⠹` — with a live timer. Cut to a **centered table** with a bold-cyan header row, then the same table again wrapped in a **rounded-corner `╭─╮` gray box**. A paragraph **fades character-by-character from cyan to magenta.** Finally a box **grows before your eyes** — padding expanding, a title sliding from top-left to top-center to top-right — redrawn in place via an Area.

The whole sequence never leaves the cyan/magenta/green/yellow/red/gray palette. Nothing is bespoke; everything is a `Default*` printer. And *that* is the point: the demo is a catalog of shipped defaults, and it looks like a coordinated product because every element dips from the same six-color, rounded-corner, aligned-badge well.

---

## 9. Lineage & influences

- **The "print statement" heritage.** pterm's deepest ancestor is `fmt.Println` itself. It positions as a *drop-in beautifier* — you were already printing; now your prints are pretty. This is philosophically opposite to Bubble Tea (Elm-architecture, model/update/view, event loop) + Lip Gloss (CSS-style declarative styling), which ask you to *rebuild* your app as a reactive TUI. pterm is **additive**; Charm's stack is **architectural**. Two poles of "make the terminal beautiful": one templated, one composable.
- **ANSI-16 conservatism.** By anchoring the house style to the 3/4-bit ANSI palette and treating TrueColor as optional enhancement, pterm inherits the *cross-platform reliability* tradition (the same instinct that makes tools ship ASCII fallbacks). Its beauty is defined at the floor, not the ceiling — a very different bet from Charm/Crush's TrueColor-gradient maximalism.
- **The semantic-log-color tradition.** The colored `INFO/WARN/ERROR` badge lineage runs back through npm/webpack build output, Ruby's `rake`, and countless CI systems that colorized log levels. pterm crystallizes that folk practice into a *shipped, aligned, themeable* vocabulary.
- **The block-letter / splash-screen tradition.** BigText descends from figlet and demoscene ASCII art — the culture of the terminal *banner* as identity marker.
- **Widely embedded.** pterm is one of the most-adopted Go output libraries (thousands of stars, 1500+ unit tests, JetBrains-sponsored), used across many CLIs — which means its cyan-badge house style is, for a slice of the Go ecosystem, *what a friendly CLI looks like* by default.

---

## 10. Notable quotes

> "💻 PTerm | Pretty Terminal Printer — A modern Go framework to make beautiful CLIs."
> — README headline, github.com/pterm/pterm

> "PTerm emphasizes ease of use, with examples and consistent component design."
> — README, Main Features table

> "PTerm uses the ANSI color scheme for uniformity and supports TrueColor for advanced terminals."
> — README, "Consistent Colors" feature

> "PTerm is ready to use without configuration but allows easy customization for unique terminal output."
> — README, "Configurable" feature

> "PTerm guarantees beautiful output whether it's Windows CMD, macOS iTerm2 or in the backend (for example inside a GitHub Action or other CI systems)."
> — README, Cross-Platform feature

> "PTerm is a Go library that makes terminal output look better and more informative. Developers can easily change how it looks to fit their needs."
> — pterm.sh landing page

> `// The prefix text is padded so all default prefix badges share the same width and messages line up when different printers are mixed.`
> — source comment, `prefix_printer.go` (the alignment-as-luxury decision, stated outright)

---

## 11. The transferable lessons (for Raxol)

1. **Ship a semantic palette as tokens, not advice.** pterm's `Info/Success/Warning/Error` aren't a style guide — they're *objects you call*. The green-check/red-cross, the cyan-badge/red-badge severity ramp, do their emotional work pre-cognitively because they're the path of least resistance. A theme that must be *assembled* is a theme most users will skip.
2. **Equal-width, uppercase, background-filled badges** are the cheapest way to make streaming output look designed: they auto-align the message column and read as UI chips, not log text.
3. **Rounded corners `╭╮╰╯` vs. sharp `┌┐└┘`** is a one-glyph personality switch — soft/friendly vs. institutional/severe. Choose it consciously; it sets the entire warmth register of every framed element.
4. **One central Theme struct of named Style tokens, dereferenced by pointer**, gives you "one override retints the whole app" — the CSS-`:root` pattern for the grid. The field *names* double as a spec of every place color carries meaning.
5. **Define beauty at the ANSI-16 floor, treat TrueColor as garnish.** Effects that degrade gracefully (the cyan→magenta fade collapsing to flat color) never produce the "great locally, broken in CI" betrayal — and surviving the worst terminal is itself a luxury signal.
6. **Braille-dot spinner (100ms) + `█`-on-`░` progress bar** are genre-defining "premium texture" defaults; adopting them costs nothing and buys instant polish.
7. **"Informative by default"** (progressbar showing title+count+percent+elapsed at once) is a legible stance — assume the user wants context, let them subtract it, rather than making them opt in.

---

## Links

- Repo: https://github.com/pterm/pterm
- Docs / landing: https://pterm.sh
- Go package docs: https://pkg.go.dev/github.com/pterm/pterm
- Demo source: https://github.com/pterm/pterm/tree/master/_examples/demo/demo
- Author: Marvin J. Wendt — https://marvin.ws
- Key source files: `theme.go` (Theme struct + ThemeDefault), `prefix_printer.go` (semantic badges), `spinner_printer.go`, `progressbar_printer.go`, `box_printer.go`, `bigtext_printer.go`, `tree_printer.go`, `section_printer.go`, `rgb.go`, `color.go`
- Alternatives/reception: https://go.libhunt.com/pterm-alternatives , https://awesome-go.com/advanced-console-uis/
