# Aesthetic Dossier — Layout Rhythm & Spatial Composition

> **Category:** cross-cutting theory — the compositional grammar of the monospace grid
> **One-line:** Before a single color or glyph is chosen, a TUI has already declared its personality through *where it puts the gaps* — density vs. airiness is the master mood dial, padding is the terminal's drop-shadow, and negative space is a luxury signal you spend cells to afford.
> **Scope:** This is a *synthesis* dossier. Padding, whitespace, framing, and column discipline are noted per-app across the corpus but never studied as one system. Here they are the subject. Evidence is drawn from the app dossiers (k9s, btop, ncmpcpp, lazygit, aider, Claude Code, superfile, yazi, Posting, Gemini CLI, Grok CLI) and the framework dossiers (ratatui, Textual/Rich, Charm/Lip Gloss, brick, pterm), cross-referenced against web-design whitespace theory (Refactoring UI) and the layout engines themselves (ratatui's Cassowary solver, Textual's TCSS box model, brick's Fixed/Greedy algebra).

---

## 1. The core thesis: layout is the first thing you read, before you read anything

A terminal hands every app the *same* raw material — an 80×24 (or bigger) grid of equal-width cells, monochrome, no z-axis, no sub-pixel positioning. Two apps can use the identical 16 colors and the identical box-drawing glyphs and feel like they were made by different species, purely because of **how they distribute emptiness**. Layout rhythm is the pre-verbal layer: your eye clocks the *silhouette* of a screen — packed vs. spacious, framed vs. floating, gridded vs. ragged — in the first 200 ms, before it resolves a single word. That silhouette is the app's first sentence about itself.

The whole grammar reduces to one governing question: **what does this app do with the cells it isn't using for content?** A dense tool spends them on more content. An airy tool spends them on nothing, deliberately — and *spending cells on nothing is the single most expensive-looking move available on a character grid*, because the terminal's native default is wall-to-wall text. Emptiness has to be *paid for*; that payment is what reads as confidence.

**Technique → feeling (the master axis):**
- **Wall-to-wall content, cells rationed for information (k9s, btop, ncmpcpp, htop)** → *industrial-dense / instrument-panel / serious / urgent*. "There is too much to show and not enough screen; every cell is working."
- **Generous margins, single-column content, blank-line breathing (Claude Code, Posting, superfile, Charm apps)** → *calm / warm / designed / expensive-minimal*. "There is room for you; nothing here is in a hurry."

Everything below is a refinement of this one dial.

---

## 2. The density↔airiness axis, anchored at both poles

### 2a. The dense pole — "information wants to be dense"

k9s states the philosophy outright: *near-zero chrome between rows, no zebra striping, single-column-1 padding on crumbs, borders only around framed panels* → **maximum rows per screen**. The dossier's own gloss: "Whitespace is rationed — the rhythm is tight columns and full-bleed tables, the opposite of an airy web dashboard. This density is the 'industrial' in industrial-dense."

btop is the same instinct made kinetic: *"fills the screen edge to edge, no wasted margins, four subsystems tiled into a mosaic. Whitespace is scarce and used only to separate zones."* ncmpcpp is the purest specimen: *"no card padding, no gutters beyond a space between columns, one item per line, header/body/bar/status stacked with zero wasted rows… utilitarian, high-information, 'everything on one screen' — the antithesis of a spacious modern app."*

**Technique → feeling:**
- **Full-bleed tables that touch the terminal edges, no outer margin** → *urgency, seriousness, "a professional instrument, not a toy."* The absence of margin says "I would give you whitespace if I could afford it, but I can't — there's a cluster on fire."
- **One data row per line, zero inter-row spacing** → *scan-density; the screen is a readout you sweep peripherally, not a page you read.* k9s explicitly turns this into "a heat map you read peripherally."
- **Columns separated by a single space, not a gutter** → *packed-ledger feel.* The eye is trusted to find the column boundary; the app doesn't waste a cell drawing it for you.

The dense pole's emotional register is **competence under pressure**. It flatters the user as an expert who can drink from a firehose. Its risk is *anxiety* and *illegibility to newcomers* — density with no salience hierarchy reads as noise (see §7 on how the dense tools rescue themselves with color and alignment rather than space).

### 2b. The airy pole — "you don't have to fill the whole screen"

Claude Code is the reference: *"the vertical rhythm is generous — blank lines between turns, tool results indented and dimmed, Claude's prose in plain white with orange only at accent points. The page breathes. Nothing competes for attention except the one thing currently streaming. This whitespace cadence is what lets it feel 'literate' — laid out like well-typeset text, not packed like a TUI trying to use every cell."*

Posting's dossier names the tell precisely: *"deliberate padding (blank rows/columns as margin) → the single strongest 'this is an application' signal in a TUI. A script prints flush-left to column 0; an app insets its content and lets the background frame it. **Whitespace is the terminal's drop-shadow.**"* superfile spends columns it doesn't need — a fixed sidebar, a dedicated metadata panel — and the dossier is explicit that the waste *is the point*: *"Whitespace and multi-panel framing are the terminal's way of saying 'I am a spacious application, I am not in a hurry, I have room for you.'"*

**Technique → feeling:**
- **Blank line between logical units (turns, sections, records)** → *pacing, literacy, calm.* Vertical whitespace is read as *punctuation* — it's the paragraph break that tells the eye "this thought is complete."
- **Single-column content on a wide terminal, content not stretched to fill** → *editorial confidence.* Refactoring UI's rule "you don't have to fill the whole screen" ported to cells: a 60-column measure centered or left-anchored in a 200-column terminal reads as *typeset*, not *unfinished*.
- **Content inset from column 0 (left margin of 1–3 cells)** → *product-grade.* The flush-left-to-column-0 default is the mark of a script; the inset is the mark of an app. This is the cheapest single move that shifts register from "tool" to "product."

The airy pole's register is **hospitality and confidence**. It flatters the user as a guest. Its risk is *preciousness* and *low information yield* — airiness with nothing to say reads as a landing page wasting your terminal.

### 2c. Density as a *dial*, not a fixed choice — the most sophisticated move

The tell of a mature design is offering *both* densities as an explicit toggle, which announces "we know whitespace is a parameter, not an accident":
- **Posting** ships a `--compact` mode: `border: none`, `padding: 0`, tabs collapse to height 1. *"Roomy by default (welcoming), compact on demand (power/density)."*
- **Grok CLI** has a compact mode that *"strips all outer padding for small screens,"* with configurable `outer_vpad`/`outer_hpad`.
- **yazi** makes it per-row: *"density is a dial. Default `none` keeps rows clean for a calm, spacious feel; switch to `size` or `mtime` and each row grows a muted metadata tail… The user chooses between airy and information-dense."*

**Technique → feeling:** *a user-facing density toggle* → *"this app has a designer who thought about whitespace as a value, and trusts you to pick your own trade."* The existence of the dial is itself an aesthetic statement of self-awareness.

---

## 3. Padding discipline — the interior rhythm

Padding is whitespace *inside* a container, between the content and its edge (or, if chromeless, between content and neighboring content). It is the highest-leverage, lowest-cost luxury signal on the grid because it operates at the scale the eye reads at.

The canonical unit is **the 1-cell ring**. Charm/Lip Gloss's dossier calls it "the airy signature": *"That single ring of blank cells between text and border is the airy feel. Cramped `│text│` reads as a system utility; `│ text │` with one cell of breathing room reads as confident, un-cramped."* Lip Gloss borrows the CSS box model wholesale — `Padding(0,1)` = "one cell of breathing room left/right of text," `Margin(1,2)` = "one row above/below, two cells outboard."

Posting's padding table is a legible spec of intent: header `1 3`, body `0 2`, URL bar `0 3`, modals `1 2`. The values encode a hierarchy — the *header* (identity, top-of-page) gets the most vertical breathing room; the *body* (dense content) gets horizontal inset only; the *modal* (a focused interruption) gets a symmetric frame. **The padding numbers ARE the composition.**

**Technique → feeling:**
- **1-cell horizontal padding inside every box** → *un-cramped, designed.* The difference between `│text│` and `│ text │` is one cell and it is the entire difference between "utility" and "product."
- **Asymmetric padding (more vertical on headers, horizontal-only on bodies)** → *typographic hierarchy without changing font (there is no font).* Vertical space around a header is the terminal's `<h1>` margin.
- **Consistent padding across all containers (the *same* ring everywhere)** → *"one designed system, not a grab-bag of widgets."* superfile's dossier: the consistency — nothing has a hard corner, everything has the same inset — "is what sells it as one designed system."
- **pterm's equal-width badges** (`" INFO  "`, `"WARNING"`, all padded to exactly 7 chars *"so all default prefix badges share the same width and messages line up"*) → *self-tabulating output; the left edge of every message forms one clean vertical rule.* The source comment states the thesis outright: this is "the single detail that most makes pterm output look designed rather than emitted — alignment is the cheapest luxury signal on a character grid."
- **aider's `NoInsetCodeBlock`** (strips Rich's default horizontal code-block padding, `padding=(1,0)`, vertical only) → *"dense but ruled."* Deliberately *removing* padding where code lives keeps the diff tight and machine-legible while the surrounding chat stays spaced — padding used as a *register switch between prose and code*.

The Refactoring UI principle governs the whole discipline: **"Start with too much white space, then remove."** *"It's a lot more obvious when you need to remove white space than when you need to add it."* Ported to the terminal: the airy tools are airy because they started roomy and pulled back; the dense tools are dense because they started roomy and pulled *all the way* back for a reason (a cluster to monitor, a playlist to browse).

---

## 4. Framed vs. chromeless — the border as the master structural fork

The single loudest layout decision is whether regions are **enclosed in box-drawing borders** or **float in shared whitespace**. This is a fork with two whole personalities on the far ends.

### 4a. Framed / boxed — the cockpit

ratatui's dossier states it flatly: *"A ratatui screen reads as a wall of labeled rectangular instrument panels. Box-drawing borders segment the terminal into a dashboard of framed cells, each with a title tucked into its top edge. This is the instrument-panel / cockpit / engineering-console vibe — orderly, gridded, serious… the frame IS the design language."* Where a web app uses whitespace and elevation to separate regions, the boxed TUI *"uses the border line as the universal separator."*

**Technique → feeling:**
- **Every region wrapped in `╭─╮`/`┌─┐`** → *contained, orderly, cockpit, "every region accounted for and captioned."* The frame is reassurance: nothing spills, everything has a labeled home.
- **Titles inlaid into the top border** (`├ title ┤────`, superfile; `╭─┤ path ├──╮`) → *window-chrome mimicry; a GUI title bar transplanted to cells.* superfile: this "means the whitespace inside the panel is never spent on labels. The frame does the labeling; the interior stays clean."
- **Border-fusion at shared edges** (ratatui's `merge_borders` → tees and crosses instead of doubled lines) → *"drafted rather than stacked."* This is what separates a *designed* multi-panel dashboard from a *pile* of boxes.

### 4b. Chromeless / borderless — the literate stream

The opposite pole drops boxes entirely and lets whitespace (and at most a hairline) do all separation:
- **yazi:** *"A thin gray hairline `│` rules between each column — no boxes, no corners, no double lines. The panes float in shared whitespace… airy and un-boxed; the density comes from the file rows themselves, not from chrome."*
- **lazygit's `hidden` border mode:** *"all spaces — borderless, panes float on whitespace… airy, 'just floating text,' the most modern/minimal look."*
- **Claude Code:** near-total chromelessness — dot-and-hang-indent nesting (`⏺` call, `⎿` result) instead of bordered panels, *"so a 20-step agent run still reads like a document, not a control panel."*

**Technique → feeling:**
- **No borders, whitespace-only separation** → *literate, chromeless, breathing, modern-minimal, "2020s app."* yazi's dossier: this is "a quiet way of saying 'this is a 2020s app'" — the opposite of DOS-era double-line `╔═╗` boxes.
- **A single hairline `│` rule where a box would go** → *the minimum viable separator; structure without enclosure.* It's the terminal's `<hr>` rotated vertical — it divides without imprisoning.

### 4c. The border-weight sub-dial

Within "framed," line weight is its own mood axis. lazygit ships five border styles as a one-key mood slider, and the dossier maps each to a feeling:
- **single light `┌─┐`** (default) → *precise, engineered, unfussy, modern-minimal-Unix.*
- **rounded `╭─╮`** → *soft, friendly, "border-radius: 6px."* The near-universal *deliberate* choice — Claude Code (`borderStyle:"round"` ×31 vs `"single"` ×3), superfile, Posting, pterm, Charm all default rounded. The dossier consensus: rounded corners are "the terminal's cheapest signifier of consumer software, not sysadmin tool."
- **double `╔═╗`** → *retro / BBS / DOS-nostalgic.*
- **bold `┏━┓`** → *assertive, chunky, institutional.*
- **hidden** → *weightless.*

lazygit's dossier nails why this is powerful: *"One config key moves the whole app across a mood axis from brutalist to soft to weightless."* ratatui generalizes it: *"line weight is ratatui's primary non-color emphasis channel"* — thin/dashed = incidental, plain = default, thick/double = attention.

**The deepest framing insight (Grok CLI):** framing changes what the app *is ontologically*. Grok's persistent frame + margins + bottom bar are *"what make it read as a bounded application window rather than a scrolling log that runs off the top of the terminal."* Chrome converts a *stream* into an *application*. Claude Code makes the opposite choice on purpose (stay inline, refuse the alt-screen) to remain a *houseguest in your scrollback* rather than an *app you enter and exit*. **Framed = "I am a place." Chromeless = "I am a voice in your existing place."**

---

## 5. Alignment grids & columns — the engineered-vs-casual fork

Alignment is the cheapest signal that a human *cared*. A ragged right edge reads as emitted; a justified one reads as composed.

The governing example is **right-aligned numerics**. Nushell's dossier: *"Right-alignment of numeric/filesize columns (against left-aligned strings) → columns of numbers line up on their ones-digit like a ledger; the table reads as accounting-grade, precise, trustworthy."* ncmpcpp uses `$R` right-alignment to push track durations to the edge — its *only* source of whitespace rhythm in an otherwise gutter-free layout. k9s tints and right-aligns metric deltas.

**Technique → feeling:**
- **Right-aligned numbers, left-aligned strings (typed alignment)** → *accounting-grade, precise, trustworthy, "spreadsheet rigor."* The ones-digit column is a vertical rule the eye trusts.
- **Aligned `key : value` pairs (colons in a column)** → *engineered, legible, "a spec sheet."* Misaligned key/value reads as a hand-typed note.
- **A shared left rule where every message's text begins** (pterm's equal-width badges) → *self-tabulating, designed.*
- **Ragged, flush-left, no column discipline** → *casual, scripty, conversational.* Not always wrong — Claude Code's prose is deliberately ragged because it's *text*, not a table. Ragged says "I am reading matter"; justified says "I am data."

The framework layer makes alignment *emergent* rather than hand-tuned, which is why modern TUIs look composed for free. brick's Fixed/Greedy algebra: *"Alignment isn't hand-tuned pixel math; it emerges from declared intent."* ratatui's Cassowary constraint solver: *"Because you declare relationships ('this pane fills, that one is 30%, leave 1 cell between them') rather than absolute coordinates, panels stay aligned and proportional across every terminal size — the layout never looks hand-jammed."* The aesthetic payoff of constraint-based layout is *calm* — nothing is ever crowded because the solver won't let it be.

---

## 6. Proportional composition — pane splits, ratios, and what the proportions signal

How a screen divides into regions, and in what *proportions*, carries mood.

The layout engines expose the vocabulary directly. ratatui's constraints: `Length(n)` (fixed cells), `Percentage(p)`, `Ratio(a,b)`, `Min(n)`/`Max(n)`, `Fill(weight)` (proportional leftover, like `flex-grow`). Textual: fractional `fr` units, `%`, `vw/vh`, `auto`, plus `dock` (pin to edge) and `layers` (z-order). brick: `Fixed` widgets rendered first, `Greedy` widgets absorb the remainder.

**Technique → feeling:**
- **Even splits (50/50, three equal columns)** → *neutral, systematic, "no region is privileged."* The default, reads as balanced but a little characterless.
- **Golden-ish / asymmetric splits (e.g. a 30% sidebar + 70% main, or ~62/38)** → *editorial hierarchy; the app has an opinion about what matters.* superfile's fixed narrow sidebar + wide panels is an asymmetric spend that says "the files are the star, navigation is support."
- **`Fill`/`Greedy` for the content region, `Length` for chrome** → *"content is the hero, chrome is fixed furniture."* Docked header/footer at fixed height + a greedy body is the universal "app" skeleton (Textual's dock, Gemini/Grok's fixed top-and-bottom bars around a growing middle).
- **Two coexisting densities in one screen** (Gemini CLI: *"airy hero region up top, compressed instrument panel along the bottom"*) → *scale spectrum; ceremony where you land, density where you work.* The padded banner welcomes; the middot-separated status strip informs.

`Layout::spacing(n)` and `Flex::SpaceBetween`/`SpaceAround` make *inter-pane breathing room* a one-argument choice. ratatui's dossier: *"The presence of `Flex::Center`/`SpaceAround` and `spacing()` makes breathing room a first-class, one-argument choice — which is why well-made ratatui apps have that airy, evenly-gapped composure, and why dense apps that skip it read as deliberately utilitarian."* The clean split of `Padding` (inside a block) vs `spacing`/`margin` (between children) mirrors the CSS box model exactly — *inner* vs *outer* whitespace as separate dials.

---

## 7. How the dense pole avoids reading as noise (density's rescue)

A critical asymmetry: airiness is *self-justifying* (space always reads as calm), but density is *not* — packed cells default to noise. The dense masters rescue legibility not by adding space (they can't afford it) but by adding **other** organizing channels, which is itself an aesthetic signature:

- **Color as a second spatial encoding** (btop: *"color is not decoration, it is a second encoding of the value itself"*; k9s: a screen of 60 pods becomes "a heat map you read peripherally"). When you can't space things apart, you *tint* them apart.
- **A depth gradient / fade** (btop's process list "fades gently into shadow toward its lower rows") → the illusion of z-depth substituting for the whitespace that would otherwise separate near from far.
- **Alignment doing the work space would do** (ncmpcpp's right-aligned durations; the column gap as the only rhythm).
- **Sub-cell braille density** (btop's waveforms: 2 samples × 4 sub-rows per cell) → *packing more signal into each cell rather than spreading signal across more cells.* Density pushed *below* the grid resolution.

**Technique → feeling:** *density + a strong non-spatial hierarchy (color-temperature, fade, alignment)* → *"instrument panel you read peripherally"* rather than *"wall of undifferentiated text."* The lesson for any dense design: **if you spend the whitespace budget on information, you must pay the legibility debt in another currency — color, weight, or alignment.**

---

## 8. Centered vs. left-anchored — what horizontal placement signals

Where content sits on the horizontal axis is a small decision with a loud voice.

- **Centered content** → *ceremony, arrival, landing-page, "look at this."* Gemini CLI's centered `GEMINI` block-letter banner, pterm's centered big-block wordmark, btop's centered clock in the top border. The dossiers converge: centering is for **identity moments** — the splash, the welcome, the now-playing hero (ncmpcpp's `alternative` UI *"trades some density for a large centered now-playing block"*). Centered = *this is a stage.*
- **Left-anchored / flush-left flow** → *terminal-native, working, conversational.* This is the reading axis of every shell, log, and REPL; content that starts at (or near) the left margin and flows down reads as *native to the medium* — you're in the terminal's own idiom. Claude Code's entire stream is left-anchored prose precisely to stay in the "literate colleague" register rather than the "app presenting itself" register.
- **Centered empty-states** (yazi's mute centered `Loading...` / `No items`) → *composed even in absence; the void is arranged, not abandoned.*

**Technique → feeling:** *reserve centering for ceremony (welcome, identity, empty-state), keep working content left-anchored* → *the app knows the difference between presenting itself and getting out of the way.* Constant centering of working content reads as *brochure*; never centering anything reads as *raw script*. The tasteful apps center exactly once (the splash) and left-anchor everything after.

---

## 9. Negative space as the load-bearing element

The deepest reframe: on the terminal, **negative space is not the absence of design — it is the primary material.** Because the medium's default is wall-to-wall text, *every empty cell is a choice*, and a screen's confidence is legible in how many empty cells it can afford to leave.

- **Empty margins = confidence** ("I have shown you what matters and stopped"). **Wall-to-wall = utilitarian urgency** ("I have more to show than screen to show it").
- Charm's dossier frames the whole philosophy as a fork: the utilitarian tradition wants to *"pack every cell — information density as a value. Charm does the opposite"* — it treats whitespace as the point.
- Even *textured* negative space is a move: Posting fills empty regions with a diagonal `hatch` (`right $surface-lighten-1 70%`) so the void reads as *intentional surface* rather than *nothing loaded yet*; Lip Gloss's `MarginChar('░')` lets even the margin carry a dotted field. **Technique → feeling:** *a faint texture in the empty region* → *"this emptiness is designed, not broken"* — the difference between a blank canvas and a missing image.
- Posting again on the tinted-not-black ground: *"near-black with a hue tint (indigo, never `#000000`) → a pure-black background reads as 'terminal/void,' a tinted one reads as 'designed surface.'"* Even the *color* of the negative space distinguishes *composed emptiness* from *raw terminal*.

**Technique → feeling:** *treating empty cells as a positive design element (afforded margins, textured voids, tinted grounds)* → *luxury, intention, "a surface someone composed,"* vs. the raw terminal's *"a buffer someone dumped to."*

---

## 10. Describe-the-screen: the two poles side by side

**The dense cockpit (k9s / btop / ncmpcpp lineage).** You launch it and the screen *fills* — edge to edge, no margin, the terminal's own frame is the only outer boundary. Rows stack with zero gaps, one record per line, columns separated by a single space and held in place by right-aligned numbers that line up on their ones digit like a ledger. A bright inverse bar marks the cursor row; everything else is tinted by *meaning* — green calm, orange watch, red trouble, gray dead — so the whole grid reads as a heat map you scan peripherally. If there are panels, each is a box with a title tucked in its top edge, borders fused at the seams into clean tees. Nothing breathes; nothing is wasted; the silhouette says *"an instrument under load, and you are its operator."*

**The airy stream (Claude Code / Posting / superfile lineage).** You launch it and the screen *recedes* — content inset a few cells from the left, a blank row between each logical unit, a single warm accent and otherwise plain text on a tinted-not-black ground. Where there are containers they are rounded-corner boxes with a one-cell ring of padding inside, dim at rest and igniting to full brightness only where your attention is. Vast stretches of the terminal are simply *empty*, and the emptiness reads as poise, not as an unfinished page. The rhythm is a well-typeset document, not a control panel. The silhouette says *"a spacious application that has room for you, and is in no hurry."*

Same grid. Same glyphs. Opposite souls — decided entirely by the distribution of gaps.

---

## Vibe words

`industrial-dense` · `instrument-panel` · `wall-to-wall` · `airy` · `breathing` · `chromeless` · `literate` · `cockpit/contained` · `engineered/tabulated` · `expensive-minimal` · `flush-left-native` · `ceremonial-centered`

---

## Technique → feeling master table

| Technique (concrete move) | Feeling / vibe it produces |
|---|---|
| Full-bleed content to terminal edges, zero outer margin | industrial-dense, urgent, "instrument under load" |
| One record per line, no inter-row spacing | scan-density; a readout you sweep, not a page you read |
| Columns separated by a single space, no gutter | packed-ledger; eye trusted to find the boundary |
| Blank line between logical units (turns/sections) | pacing, literacy, calm; whitespace as punctuation |
| Content inset 1–3 cells from column 0 | product-grade; "app," not "script" ("whitespace is the drop-shadow") |
| Single-column measure, content not stretched to fill | editorial confidence ("you don't have to fill the screen") |
| 1-cell padding ring inside every box (`│ text │`) | un-cramped, confident, designed |
| Asymmetric padding (vertical on headers, horizontal on bodies) | typographic hierarchy without a font |
| Identical padding across all containers | "one designed system, not a grab-bag" |
| Equal-width badges/labels padded to a common length | self-tabulating output; cheapest luxury signal |
| Every region in a box-drawing border | contained, orderly, cockpit, "every region captioned" |
| Titles inlaid into the top border line | window-chrome mimicry; interior stays label-free |
| Border-fusion (merged tees/crosses) on tiled panels | "drafted, not stacked" |
| No borders, whitespace-only separation | literate, chromeless, breathing, 2020s-app |
| Single hairline `│` where a box would go | minimum viable separator; structure without enclosure |
| Rounded corners `╭─╮` as default box style | soft, friendly, consumer-software (`border-radius: 6px`) |
| Double/bold borders `╔═╗`/`┏━┓` | retro/BBS or assertive/institutional |
| Right-aligned numerics vs left-aligned strings | accounting-grade, precise, trustworthy |
| Aligned `key : value` colons in a column | engineered, spec-sheet legible |
| Ragged flush-left prose | conversational, "reading matter, not data" |
| Constraint/Fill/Greedy layout (declared relationships) | calm, self-resolving, never crowded, resize-graceful |
| Asymmetric pane split (30/70, ~62/38) | editorial hierarchy; the app has an opinion |
| Docked fixed chrome + greedy body | "content is the hero, chrome is furniture" |
| Two densities in one screen (airy hero + dense bar) | ceremony where you land, density where you work |
| Density as a user toggle (`--compact`, line-modes) | self-aware design; whitespace as a knob |
| Centered content | ceremony, arrival, landing-page, "a stage" |
| Left-anchored flowing content | terminal-native, working, in the medium's idiom |
| Textured/tinted negative space (hatch, tinted ground) | "emptiness is designed, not broken/void" |
| Dense layout + strong color/fade/alignment hierarchy | instrument-panel legibility; density's rescue |

---

## Recommendations for a coding-agent harness — the "warm-but-serious" register

The target register sits *between* the poles: not the airy hospitality of a landing page (too precious for a tool you live in for hours), not the wall-to-wall urgency of k9s (too anxious for a collaborator). Concretely:

1. **Anchor left, inline, flush-adjacent — not centered, not alt-screen.** Follow Claude Code: content inset 1–2 cells from column 0, flowing down the terminal's native scrollback. Reserve centering for a *single* identity moment (a modest startup banner sized to fit 80×24) and nothing else. This buys "terminal-native, working colleague" over "app presenting itself." *Warmth comes from the left-anchored literate flow; seriousness from refusing ceremony after the greeting.*

2. **Breathe vertically, ration horizontally.** Put a blank line between turns/tool-calls/logical units (the literate cadence). Do *not* spend generous horizontal margins — a coding harness shows diffs, file trees, and command output that want the full width. So: **airy in the Y axis, dense in the X axis.** This is the exact split that reads as "calm to read, but respects that you have real work on screen."

3. **Chromeless by default, hairlines over boxes, boxes only for interruptions.** Use whitespace + a `⏺`/`⎿` dot-and-hang-indent nesting grammar (Claude Code) for the *stream*; reserve a rounded-corner bordered box strictly for *modal moments* — a permission prompt, a plan, an error that must be acknowledged. A box in a chromeless stream reads as "stop and look here," which is exactly the salience you want for approvals. **Rounded corners** (`╭─╮`), single weight — the near-universal "warm/modern" default; never double or bold (institutional), never sharp (severe).

4. **One-cell padding ring inside every box you *do* draw, and identical everywhere.** The consistency is what reads as "designed system." Follow Posting's asymmetric scheme: more vertical breathing on any header/identity strip, horizontal-only inset on dense content bodies.

5. **Tabulate where there are numbers, ragged where there is prose.** Right-align token counts, durations, line counts, diff stats (`+12 -4`) into ledger columns; keep the model's prose flush-left and ragged. The switch between tabulated and ragged *is* the switch between "here is data" and "here is a voice" — and a coding agent is constantly both.

6. **Offer a `--compact` / density toggle.** It costs little and signals design maturity: roomy default for reading, compact for a power user watching a long run on a small pane.

7. **Tint the ground, don't sit on pure black.** Inherit the user's background where possible (chameleon, respectful) but if you own it, a faintly-tinted near-black reads as "designed surface" over "raw void" — the difference between warm and cold at zero information cost.

8. **Spend the whitespace budget on the *one* thing streaming.** Claude Code's core move: at any instant, exactly one thing is live and everything else is dim and de-emphasized. Whitespace + dimming isolates the active turn. This is how you get "calm" without "empty" — the space isn't wasted, it's *directing attention*.

The net silhouette to aim for: **a literate, left-anchored, vertically-breathing stream that stays out of your scrollback's way, tightens into aligned ledger columns exactly when it has numbers to show, and draws a single soft-cornered box only when it genuinely needs you to stop.** Warm because it reads like a colleague's well-spaced notes; serious because it never wastes your horizontal width or centers itself on a stage.

---

## Notable quotes & sources

**On whitespace as the primary signal (from the corpus):**
- *"Deliberate padding (blank rows/columns as margin) → the single strongest 'this is an application' signal in a TUI. A script prints flush-left to column 0; an app insets its content… **Whitespace is the terminal's drop-shadow.**"* — Posting dossier (§5).
- *"Whitespace and multi-panel framing are the terminal's way of saying 'I am a spacious application, I am not in a hurry, I have room for you.' A sparse `lf` says tool; superfile's padded, paneled, labeled layout says product."* — superfile dossier (§3).
- *"Information wants to be dense. Whitespace is rationed — the rhythm is tight columns and full-bleed tables, the opposite of an airy web dashboard. This density is the 'industrial' in industrial-dense."* — k9s dossier (§3).
- *"The frame IS the design language."* / *"line weight is ratatui's primary non-color emphasis channel."* — ratatui dossier (§1, §2).
- *"One config key moves the whole app across a mood axis from brutalist to soft to weightless."* — lazygit dossier (border modes, §3).
- *"alignment is the cheapest luxury signal on a character grid, and pterm bakes it in for free."* — pterm dossier / `prefix_printer.go` source comment (§misc).
- *"Alignment isn't hand-tuned pixel math; it emerges from declared intent."* — brick dossier (Fixed/Greedy, §6).

**On layout theory (web, ported to cells):**
- *"Start with too much white space… it's a lot more obvious when you need to remove white space than when you need to add it."* — Refactoring UI, "Start with too much white space."
- *"You don't have to fill the whole screen."* — Refactoring UI, Layout & Spacing section.
- *"TUIs earn their power through spatial consistency, keyboard fluency, and information density that respects human attention."* — hyperb1iss `tui-design` skill.
- *"Panels maintain spatial memory — 'branches are always top-left.'"* — hyperb1iss `tui-design` skill (fixed-layout / spatial-memory philosophy).

**Layout engines (the vocabulary that shapes the house styles):**
- ratatui `Constraint`: `Length` / `Percentage` / `Ratio` / `Min` / `Max` / `Fill`; `Flex::{Start,End,Center,SpaceBetween,SpaceAround}`; `Layout::spacing(n)`. Cassowary constraint solver → graceful-degradation resize. — https://ratatui.rs/concepts/layout/ · https://docs.rs/ratatui/latest/ratatui/layout/enum.Constraint.html
- Textual TCSS box model: `padding` / `margin` (margins overlap, per CSS) / `border` / `outline`; `dock`, `layers`, `layout: horizontal|vertical|grid`, fractional `fr` units. — https://textual.textualize.io/ (and dossier lib-textual-rich-textualize-python.md)
- Lip Gloss CSS box model: `Padding(v,h)`, `Margin(v,h)`, `MarginChar`, `JoinHorizontal`/`JoinVertical`. — dossier lib-charm-ecosystem…md
- brick Fixed/Greedy algebra: `hBox`/`vBox`, `hLimit`/`vLimit`, `padLeft…padAll`, `hCenter`/`vCenter`. — dossier lib-brick-haskell.md

**Whitespace / spacing essays (general):**
- Refactoring UI — "Start with too much white space" (PDF): https://refactoring-ui.nyc3.cdn.digitaloceanspaces.com/Refactoring%20UI%20-%20Start%20with%20too%20much%20white%20space.pdf
- "The Power of White Space: How Good UI Breathes": https://medium.com/@g.r.tanny/the-power-of-white-space-how-good-ui-breathes-06ff67737599
- hyperb1iss tui-design skill: https://explainx.ai/skills/hyperb1iss/hyperskills/tui-design

**Cross-referenced app/library dossiers (this corpus):**
- Dense pole: `app-k9s.md`, `app-btop.md`, `app-ncmpcpp.md`, `app-lazygit.md`, `app-aider.md`
- Airy pole: `app-claude-code.md`, `app-superfile.md`, `app-yazi.md`, `app-posting.md`, `lib-charm-ecosystem-lip-gloss-bubbles-bubble-tea-gum-huh-glamour.md`
- Framing / engines: `lib-ratatui-rust.md`, `lib-textual-rich-textualize-python.md`, `lib-brick-haskell.md`, `lib-pterm-go.md`, `lib-nushell-table-theming-approach-rust.md`
- Two-density hybrids: `app-gemini-cli.md`, `app-xai-grok-build-grok-cli-tui.md`
