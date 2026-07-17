# Nushell — Table & Theming Aesthetic Dossier

> Nushell is not a UI framework. It is a shell. But it is the single most influential **opinionated data-display aesthetic** in the modern terminal, because it made one radical decision: pipelines carry *structured data*, not text, and structured data is *rendered*, not printed. The moment a command's output is a table of typed values instead of a stream of bytes, the terminal acquires a design surface it never had before — borders, per-type color, header emphasis, alignment, wrapping. Nushell's `table.mode` catalog and `color_config` are the vocabulary of that surface. Any dashboard, `ls`-replacement, or data TUI that wants tabular output to look *designed rather than dumped* is, knowingly or not, working in the idiom Nushell codified.

- **Repo:** https://github.com/nushell/nushell (Rust; table engine is the vendored `nu-table` crate over `tabled`)
- **Docs:** https://www.nushell.sh/book/coloring_and_theming.html · https://www.nushell.sh/book/tables.html
- **Authors:** Jonathan Turner, Yehuda Katz, Andrés N. Robalino (2019 origin); large maintainer team since
- **Lineage:** PowerShell (structured objects down the pipe) → Nushell (structured *data*, typed, rendered as tables) → the "everything is a table" house style now echoed across `nu`-adjacent tooling
- **Category siblings:** PowerShell's `Format-Table`, `column -t`, `csvlook`/`csvkit`, `visidata`. Nushell is the one that made the *border style itself* a first-class, swappable design token.
- **Family:** structured-data-first / "the table understands its contents."

---

## 1. The one-sentence identity

Every other shell prints `ls` as a ragged column of filenames the color of your `LS_COLORS`. Nushell prints `ls` as a **bordered, typed, right-aligned table** where the size column is cyan because it is a `filesize`, the date column is purple because it is a `datetime`, the row index is green because it is structure not content, and the whole thing is wrapped in `╭─╮ │ ╰─╯` rounded corners by default. The personality is: **the shell has taste about your data, and expresses that taste through type-aware color and a chosen border language.** Nothing is "just text." Everything is a value with a type, and every type has a look.

---

## 2. Table mode as a whole-personality switch

The most important aesthetic fact about Nushell: **one setting re-skins the entire tool's character.**

```nu
$env.config.table.mode = 'rounded'
```

That single string swaps the box-drawing vocabulary for *every table the shell will ever render* — `ls`, `ps`, `open data.json`, a custom pipeline, all of it. It is the closest thing the terminal has to a CSS theme swap: change one token, the whole product changes mood. The full catalog (18 modes) is a mood palette, not a preference list. Each mode sends a different message:

| Mode | Characters | The mood it sends |
| --- | --- | --- |
| **`rounded`** *(default)* | `╭╮╰╯ │ ─` | Soft, friendly, modern. The curved corners are the single most recognizable Nushell signature — they say "this is a designed, contemporary tool, not a 1980s utility." |
| **`heavy`** | `┏┓┗┛ ┃ ━` | Bold, dense, authoritative. Thick strokes make a table feel *important* and load-bearing — good for a headline result you want to dominate the screen. |
| **`double`** | `╔╗╚╝ ║ ═` | Formal, heavyweight, retro-institutional. Reads like a DOS-era admin panel or a certificate border — ceremonial weight. |
| **`single`** / **`thin`** | `┌┐└┘ │ ─` | Traditional, clean, delicate. The neutral "I am a table" with no editorial spin. `thin` reads more fragile/precise. |
| **`compact`** | `─┬┼┴ │` (outer border dropped) | Minimal, space-efficient, engineer-ish. Keeps the internal grid but sheds the outer frame — the data breathes, less ink. |
| **`compact_double`** | `═╦╬╩` internal, no outer box | Minimal but emphatic — the double lines give structure without the boxed-in feeling. A denser cousin of compact. |
| **`light`** | header underline only | Very open, airy, quiet. Draws a single rule under the header and nothing else — the table is mostly whitespace, letting content lead. |
| **`reinforced`** | heavy corners `┏┓┗┛` on thin body | Emphasized corners, quiet middle. The frame is anchored at the corners like reinforced stitching — subtle strength. |
| **`markdown`** | `| a | b |` + `---` | Portable, plain, copy-paste-native. This is the "my output is documentation" stance — a table you can paste straight into a `.md` file or GitHub comment. Deliberately un-fancy for interoperability. |
| **`psql`** | `---+---` pipes and dashes | Database-console familiarity. Mimics PostgreSQL's `psql` output — instantly legible to anyone who lives in SQL shells; a knowing wink at DBAs. |
| **`dots`** | `⋮ :..:` dotted separators | Light, sketchy, low-ink texture. The dotted rules feel provisional, soft — like graph paper rather than a printed form. |
| **`restructured`** | `===` rules | reStructuredText / academic-doc look. Equals-sign rules evoke technical documentation and Python-world tooling. |
| **`basic`** | `+---+ | |` ASCII | Classic, universal, retro-ASCII. The lowest-common-denominator table every tool has drawn since the 1970s — nostalgic, maximally compatible. |
| **`ascii_rounded`** | `.-'| ` ASCII faking curves | Rounded *vibe* without Unicode — for terminals/fonts that can't render box-drawing. Compatibility cosplay of the default look. |
| **`basic_compact`** | ASCII, no outer border | Basic's minimal cousin — ASCII grid, no frame. |
| **`none`** | whitespace only | **Brutalist / data-first / accessible.** No borders at all — columns held apart by spacing alone. A deliberate design stance, not an absence of one (see §6). |
| **`with_love`** | `❤` everywhere the border would be | Playful, whimsical, a joke rendered as a feature. Replaces every rule and corner with heart glyphs — proof the border layer is a pure, swappable token, and that the maintainers know it. |
| **`default`** | rounded-family | The historical fallback name; renders in the modern rounded idiom. |

- **Technique:** a single `table.mode` enum re-skins the box-drawing language of every rendered table globally → **feeling:** the whole tool changes character from one line of config; the terminal gains the "theme swap" affordance of the web. The *existence* of `with_love` (hearts as borders) is itself the thesis: the border is decoration, decoration is a token, tokens are swappable, and taste is a setting.

The choice of **`rounded` as the shipped default** is the deepest aesthetic commitment. Most terminal tooling defaults to sharp ASCII `+---+` (or no border at all). By defaulting to `╭─╮` curved Unicode corners, Nushell declares up front: *this is a soft, modern, Unicode-native tool, and your data deserves a nicely-drawn frame.* Every fresh install imprints that friendliness before the user configures anything.

---

## 3. Type-aware `color_config` — "the table understands its contents"

The second pillar. Nushell colors table cells **by the runtime type of the value**, not by position or by regex. Because the pipeline carries typed data, the renderer *knows* that a cell is an `int`, a `filesize`, a `datetime`, a `bool` — and it can assign each type a signature color. This is semantic color: hue *means* type.

The two axes of `color_config`:

**A. By primitive data type** — every value type gets a color slot:
`any`, `binary`, `block`, `bool`, `cell-path`, `datetime`, `duration`, `filesize`, `float`, `int`, `list`, `nothing`, `range`, `record`, `string`.

**B. By table component** — structural roles get their own colors:
`header`, `separator`, `row_index`, `empty`, `hints`, `leading_trailing_space_bg`, `search_result`.

The shipped `std/config dark-theme` makes concrete choices worth reading as a design document:

```
header      : green_bold      # structure/labels shout in bold green
row_index    : green_bold      # the index column matches the header — "this is scaffolding, not data"
filesize     : cyan           # sizes are cool cyan
datetime     : purple         # dates/times are purple
bool         : light_cyan     # truthy values pop bright
empty        : blue
hints        : dark_gray      # de-emphasized guidance recedes
separator    : default        # borders stay neutral so content leads
search_result: {bg: red, fg: white}   # matches are inverted red — impossible to miss
int/float/string/duration/range: default  # the "body" stays terminal-default, so accents mean something
```

The design logic is **restraint as legibility**: most body types are left `default` (your terminal's foreground), and only *meaningful* types get accent hues — `filesize` cyan, `datetime` purple, `bool` bright, plus the green structural chrome (header + index). The result is a table where color is *sparse and therefore semantic*: a splash of cyan is always a size, a splash of purple is always a time. Your eye parses the table's schema pre-cognitively, by hue, before reading a single glyph.

- **Technique:** assign color by the value's *type* (filesize→cyan, datetime→purple, bool→bright), and give structural roles (header, row_index) a shared bold-green so chrome reads as chrome → **feeling:** legible-at-a-glance structure; the table appears to *understand what it contains*. You navigate by color-memory ("cyan column = sizes") the way btop's per-subsystem box colors let you navigate by hue.
- **Technique:** leave most body types `default` and accent only a few → **feeling:** color scarcity makes color meaningful; a highlighted cell is signal, not noise. The opposite of the "rainbow puke" `LS_COLORS` look.

### 3.1 Closures — color as a function of the *value*, not just the type

The most advanced move: a color slot can be a **closure** that receives the actual value and returns a color. Color becomes a continuous function of data, like btop's load-gradient — but expressed in shell script.

```nu
# filesize colored by magnitude: grey for zero, cyan for small, blue for large
$env.config.color_config.filesize = {|x|
  if $x == 0b { 'dark_gray' } else if $x < 1mb { 'cyan' } else { 'blue' }
}

# bool colored by truth value
$env.config.color_config.bool = {|x| if $x { 'green' } else { 'light_red' } }
```

Now a 4 GB file is *visibly* a different color from a 12 KB file in the same `ls`; `false` glows red against `true`'s green. The table doesn't just know the *type* of each cell — it reacts to the *value*.

- **Technique:** closure-valued color slots that map the runtime value → a color (magnitude bands for filesize, truthiness for bool) → **feeling:** the table has *opinions about its data* — big files look heavy, falses look alarming. Data-driven conditional formatting, the terminal equivalent of a spreadsheet's color scales, but declared in one line. (Constraint the aesthetic reveals: closures run only for **table output**, not for `shape_` command-line coloring.)

---

## 4. Shape coloring — the command line as live, intelligent feedback

`color_config` styles *output*; the `shape_*` variables style the **command line as you type it**. Nushell parses your input into an AST in real time and colors each syntactic *shape* — this is what gives the prompt its "alive, intelligent" feel, the sense that the shell is reading over your shoulder and understands the sentence before you press Enter.

The `shape_` vocabulary is a full grammar made visible:
`shape_int`, `shape_float`, `shape_string`, `shape_bool`, `shape_binary`, `shape_range`, `shape_list`, `shape_record`, `shape_table`, `shape_block`, `shape_closure`, `shape_operator`, `shape_pipe`, `shape_redirection`, `shape_flag`, `shape_variable`, `shape_vardecl`, `shape_keyword`, `shape_filepath`, `shape_directory`, `shape_globpattern`, `shape_glob_interpolation`, `shape_internalcall`, `shape_external`, `shape_externalarg`, `shape_external_resolved`, `shape_signature`, `shape_string_interpolation`, `shape_raw_string`, `shape_literal`, `shape_match_pattern`, `shape_matching_brackets`, `shape_garbage`.

The dark-theme's shape choices tell a story:

```
shape_garbage           : {fg: white, bg: red, attr: b}   # unparseable input turns RED — instant "this is wrong"
shape_flag              : blue_bold      # --flags glow blue
shape_string            : green          # strings green
shape_int / shape_float : purple_bold    # numbers pop purple
shape_pipe / shape_redirection : purple_bold   # pipeline plumbing emphasized
shape_internalcall      : cyan_bold      # known built-in commands cyan
shape_external          : cyan           # external commands slightly cooler cyan
shape_matching_brackets : {attr: u}      # the bracket under your cursor and its partner underline together
```

Two feedback aesthetics stand out:

- **`shape_garbage` = white-on-red-bold.** The instant you type something the parser can't understand, it flushes red *before you hit Enter*. Error-as-you-type, rendered as alarm color. The shell feels like it's catching you — vigilant, almost protective.
- **`shape_external` vs `shape_internalcall`** get *different* colors, so you can see at a glance whether `ls` means Nu's built-in `ls` or an external binary. The coloring encodes the shell's own resolution decision — the tool shows you what it thinks you meant.
- **`shape_matching_brackets` underline.** Move the cursor onto a `(` and both it and its `)` underline. Live structural feedback, the terminal echo of an editor's rainbow-bracket matching.

- **Technique:** real-time AST-driven syntax coloring where each grammar shape has its own hue, invalid input flips to white-on-red, and command *kind* (internal vs external) is color-coded → **feeling:** the prompt is *alive and reading along*; typing feels like a conversation with something that understands syntax, not a dumb text buffer. This is the single biggest contributor to Nu's "smart shell" vibe.

---

## 5. Ships-with-taste: default palette & the standard-library themes

Nushell imprints a house style through **defaults that are already opinionated**, plus first-class light/dark theme modules in the standard library:

```nu
use std/config dark-theme
$env.config.color_config = (dark-theme)   # or (light-theme)
```

Design decisions baked into the shipped themes:

- **Green is the structural accent.** Both `header` and `row_index` are `green_bold`. Green = "this is scaffolding." It's a calm, positive, non-alarming color for the chrome, leaving red/purple free to carry meaning in the data.
- **Light/dark are true perceptual inversions, not a color flip.** The `light-theme` doesn't just swap a background — it *darkens the accents* so they survive on a light terminal: `bool` goes `light_cyan → darkcyan`, `separator` goes `default → dark_gray`, and nearly every body type collapses to `dark_gray`. The maintainers understood that a bright cyan that pops on black *disappears* on white, so they re-chose each hue for contrast. That is real perceptual-uniformity discipline shipped as a default.
- **The base16 convention.** The official theming example is structured as `base00`…`base0f` variables mapped onto `color_config` keys — deliberately aligning Nu with the community-standard base16 palette ecosystem (gruvbox, nord, solarized, tokyo-night…), so any base16 theme drops in. Nu speaks the dotfiles/ricer palette language natively.

- **Technique:** ship pre-built `dark-theme`/`light-theme` as importable stdlib functions, with accents re-tuned per background for contrast, and structure the example around base16 variables → **feeling:** "batteries-included taste." A new user gets a coherent, contrast-correct look for free, and the community's palette vocabulary plugs straight in. Defaults *are* the house style, and they set the expectation that a Nu table should look considered.

---

## 6. Accessibility-as-aesthetic: `none` + `plain` as a design stance

Nushell's accessibility guidance doubles as a deliberate minimalist *look*:

```nu
$env.config.table.mode = "none"
$env.config.error_style = "plain"
```

`mode: none` strips every border — columns are held apart by whitespace alone — and `error_style: plain` strips the fancy multi-line, caret-underlined, colorized error boxes down to a single plain sentence. Officially this is for screen readers. Aesthetically it is **data-first brutalism**: remove all decoration and what remains is pure content on a grid of spaces. The stripped-down look is not a downgrade; it's a stance — the same "honesty of raw material" move as monospace-brutalist web design or a Bloomberg-terminal wall of unstyled numbers.

- **Technique:** `table.mode: none` + `error_style: plain` removes all box-drawing and error chrome → **feeling:** austere, honest, high-density; the data is the design. Removing decoration is itself an aesthetic decision — and the fact that Nu makes it a *named, first-class* configuration (rather than an afterthought) is what makes it a design stance rather than a failure mode.

---

## 7. Structural rendering choices that carry vibe

Beyond borders and color, the table *engine* makes choices that shape the feel:

- **Right-alignment of numeric/filesize columns** (against left-aligned strings) → **feeling:** columns of numbers line up on their ones-digit like a ledger; the table reads as *accounting-grade*, precise, trustworthy.
- **The row-index column** (`#`) on the left by default → **feeling:** every result is addressable and countable; the table feels like a database result set you can reach into (`get 3`), not a printout.
- **Expanded (`table -e`) vs collapsed views** — nested records/lists can expand into sub-tables inside cells, or collapse to a `{record 3 fields}` summary → **feeling:** the table honestly represents *depth*; structure nests visibly rather than being flattened to text. A cell can itself be a little framed table, so the whole output reads as fractal/self-similar structure.
- **`empty` and `nothing` get their own colors** (blue / configurable) → **feeling:** absence is rendered *explicitly* — a null is a colored token, not a confusing blank — so gaps in data are legible rather than ambiguous.
- **Width-aware trimming** (wrap vs truncate-with-`...`) → the table negotiates with terminal width rather than blowing past it → **feeling:** the output respects its frame; it never sprawls off the right edge into garbage.

- **Technique:** typed alignment (numbers right, strings left) + always-present row index + nestable expand/collapse cells → **feeling:** "spreadsheet-grade" rigor in a shell; data looks *tabulated and addressable*, the opposite of a text dump.

---

## 8. What the API names encode (design thinking made lexical)

The vocabulary itself is the design opinion — what's *easy to say* is what Nu wants you to do:

- Border styles are a **named enum of moods** (`rounded`, `heavy`, `compact`, `with_love`) rather than a low-level "draw these 11 corner glyphs." You choose a *character*, not corners. That abstraction *is* the aesthetic claim: table style is a design token.
- `color_config` keys are **data-type names and table-component names** (`filesize`, `datetime`, `header`, `row_index`, `separator`) — not positions or selectors. The API forces you to think semantically ("how should a *filesize* look") rather than positionally ("color column 3"). Type-driven styling is baked into the vocabulary.
- `shape_*` mirrors the **grammar of the language** one-to-one (`shape_pipe`, `shape_flag`, `shape_internalcall`). The names expose that the shell has a real parser and colors its own AST — the naming advertises the intelligence.
- The two-axis split (`table.mode` for *structure*, `color_config` for *content*) cleanly separates skeleton from skin — the same separation CSS makes between box-model and color, and the same one Lip Gloss/Textual borrow from web CSS. Nu arrived at it from the data side.

- **Technique:** name style tokens by *mood* (border modes) and by *semantics* (types/components), never by position → **feeling:** the API teaches you to treat terminal data as designed, typed, and themeable; it makes the "designed table" easy and the "raw dump" require opting out (`mode: none`).

---

## 9. Lineage & influence

- **From PowerShell:** the ancestral idea — objects, not text, flow through the pipe — came directly from Jonathan Turner's PowerShell experiments. Nu inherited "structured data down the pipeline" and added *rendering taste* on top: typed color and swappable borders that PowerShell's `Format-Table` never made this ergonomic or this pretty.
- **From base16 / dotfiles culture:** the `base00`-`base0f` theming convention and the assumption that users will theme (nord, gruvbox, tokyo-night) place Nu inside the ricer/r/unixporn ecosystem — it *expects* to be dressed and screenshotted.
- **Downstream:** the "every command returns a styled table" expectation Nu normalized now shapes how people evaluate *any* data-emitting TUI. Once you've seen `ls` as a rounded, type-colored table, a plain `ls` looks unfinished. That shifted-baseline is Nu's real aesthetic legacy: it raised the floor for what tabular terminal output is *allowed to look like*.

---

## 10. Notable quotes

- On the founding thesis (Turner & Katz): *"they settled on the idea of using structured data rather than just text between applications… adding some structure to the data opened up a lot of possibilities."* — Changelog Interviews #363 / recounted in coverage of Nu's origin.
- The house mantra, repeated across the docs and community: **"To Nu, everything is data."** — the sentence from which the entire rendering aesthetic follows; if everything is typed data, everything can be *rendered with type-aware taste*.
- On accessibility-as-configuration (the book): setting `table.mode: "none"` and `error_style: "plain"` *"disables borders and other decorations for both table and errors."* — the stripped look treated as a first-class, named stance.
- On closures/output-only styling (the book): *"Closures are only executed for table output. They do not work in other contexts like for `shape_` configurations."* — the boundary between output styling and command-line styling, stated as a rule.

---

## 11. Transferable moves for a terminal UI framework (Raxol lens)

1. **Make border style a single global token** with a named-mood enum (soft/rounded, heavy, compact, none). One setting → whole-app character. Nu proves users *love* this and will theme it.
2. **Color by semantic type, not position.** If your framework knows a cell is a duration/size/timestamp, give the *type* a default hue and leave everything else neutral — color scarcity is legibility.
3. **Ship contrast-correct light AND dark defaults** where accents are *re-chosen* per background, not merely inverted. This is the perceptual-uniformity discipline that separates a real theme from a color flip.
4. **Offer conditional/closure coloring** (value→color) for magnitude and truthiness — the "table has opinions about its data" effect is cheap and high-impact.
5. **Treat `none`/`plain` as a designed stance,** named and first-class, not a fallback — data-first brutalism is a legitimate look and an accessibility win at once.
6. **Separate structure from skin** (borders vs colors) as two independent config axes, the CSS box-model/color split — it keeps both simple and composable.

---

## Sources

- https://www.nushell.sh/book/coloring_and_theming.html — the canonical theming reference (modes, color_config, shape_ vars, closures, accessibility)
- https://www.nushell.sh/book/tables.html — table rendering, modes, expand/collapse, width
- https://github.com/nushell/nushell — nu-table / tabled engine source
- https://raw.githubusercontent.com/nushell/nushell/main/crates/nu-std/std/config/mod.nu — the shipped dark-theme / light-theme definitions (exact color values)
- https://blog.mrhaki.com/2025/12/nushell-niceties-tables-with-different.html — visual walkthrough of every border mode
- https://jdriven.com/blog/2025/12/Nushell-Niceties-Tables-With-Different-Themes — table theme showcase
- https://deepwiki.com/nushell/nushell/6.4-table-rendering-and-output — TableTheme struct, general/expanded/collapsed modes
- https://www.nushell.sh/blog/2019-08-23-introducing-nushell.html — original introduction, structured-data thesis
- https://spin.atomicobject.com/nushell-treats-everything-as-data/ — "the shell that treats everything as data"
- https://changelog.com/podcast/363 — Turner/Robalino/Katz on structured-data origins
- https://www.nushell.sh/blog/2026-04-11-nushell_v0_112_1.html — confirms `rounded` as current default table mode
- https://github.com/nushell/nushell/issues/15072 — light theme discussion
