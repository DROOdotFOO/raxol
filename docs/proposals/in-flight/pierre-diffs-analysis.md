# Pierre `@pierre/diffs` — Port + Visual-Language Analysis

Analysis of [`pierrecomputer/pierre` → `packages/diffs`](https://github.com/pierrecomputer/pierre/tree/main/packages/diffs)
(version `1.2.12`, Apache-2.0) for the purpose of porting its **diff logic** and
reproducing its **visual language** (the diffs.com look) in the Raxol terminal
diff-viewer.

All file references below are relative to `packages/diffs/src/` in the Pierre
repo unless noted. This doc is a spec, not a code change.

---

## 0. TL;DR for the impatient

- **Diff engine**: jsdiff (npm `diff`). Line-level diff comes free from
  `createTwoFilesPatch` (Myers under the hood); Pierre then *parses the unified
  patch text back into a structured model*. Intra-line diff is a **second pass**
  using `diffWordsWithSpace` (word) or `diffChars` (char).
- **Intra-line model**: for each *paired* changed line (i-th deletion vs i-th
  addition, positional pairing), run a word/char diff, collect the
  added/removed sub-ranges as `{line, start, length}` decorations, render them
  as a brighter background span *under* the syntax tokens.
- **The look**: full-row tint (~12% light / ~20% dark of a base add/remove
  color mixed into the bg) + a **brighter emphasis span** (~15–20% alpha) on the
  changed word ranges + a 4px colored gutter bar + Shiki syntax colors layered
  on top + a rounded "N unmodified lines" collapser separator + diagonal-hatch
  filler rows for split alignment.
- **Hardest terminal port**: the *two-level* background (row tint UNDER a
  brighter intra-line span UNDER syntax-colored fg) — terminals give you exactly
  one bg + one fg per cell, so the layered translucency that carries most of the
  diffs.com feel must be flattened into discrete per-cell bg tiers.

---

## 1. Diff algorithm layer

### 1.1 Engine

Pierre does **not** implement its own diff. It depends on jsdiff (`diff` in
`package.json`). Two entry points:

- **File → diff** (`utils/parseDiffFromFile.ts`): calls
  `createTwoFilesPatch(oldName, newName, oldContents, newContents, oldHeader,
  newHeader, options)` to produce a standard **unified-diff patch string**, then
  feeds that string to `processFile` (`utils/parsePatchFiles.ts`). So even when
  diffing raw contents, the internal representation is *always* a parsed patch.
  jsdiff's line differ is Myers diff; Pierre exposes jsdiff's options verbatim
  via `parseDiffOptions` (`CreatePatchOptionsNonabortable`).
- **Patch → diff** (`utils/parsePatchFiles.ts`): parses git/unified patch text
  directly (regexes in `constants.ts`: `HUNK_HEADER`, `GIT_DIFF_FILE_BREAK_REGEX`,
  `FILENAME_HEADER_REGEX`, `INDEX_LINE_METADATA`, etc.). Supports git metadata
  (mode, rename similarity, object ids), `\ No newline at EOF`, merge-conflict
  markers.

**Implication for the port**: you need (a) a line-level diff (Myers is fine) and
(b) a unified-patch parser — OR you skip the patch round-trip and build the
structured model directly from the line diff. The patch round-trip is only
load-bearing when your *input is already a patch string*. For "two buffers →
diff" you can go straight from the line-diff opcodes to the hunk model.

### 1.2 Hunk computation & the data model

The canonical types are in `types.ts`. The model is deliberately **index-based**
(everything points into flat `additionLines[]` / `deletionLines[]` arrays) so it
is JSON-serializable and cheap to window/virtualize.

```
FileDiffMetadata            // one file
  name, prevName?, lang?
  type: 'change'|'rename-pure'|'rename-changed'|'new'|'deleted'
  isPartial: bool           // true = parsed from a patch (only patch lines present)
  deletionLines: string[]   // old file: full contents if !isPartial, else just patch lines
  additionLines: string[]   // new file: same
  hunks: Hunk[]
  splitLineCount, unifiedLineCount   // precomputed rendered-row totals

Hunk                        // one @@ ... @@ block
  collapsedBefore: number   // unchanged lines hidden between prev hunk and this one
  additionStart, additionCount, additionLines, additionLineIndex
  deletionStart, deletionCount, deletionLines, deletionLineIndex
  hunkContent: (ContextContent | ChangeContent)[]   // the run-length structure
  hunkContext?: string      // the "def foo()" text after @@
  hunkSpecs?: string        // raw "@@ -1,5 +1,7 @@"
  splitLineStart, splitLineCount           // rendered-row geometry, split view
  unifiedLineStart, unifiedLineCount       // rendered-row geometry, unified view
  noEOFCRDeletions, noEOFCRAdditions       // "\ No newline at end of file"

ContextContent { type:'context'; lines; additionLineIndex; deletionLineIndex }
ChangeContent  { type:'change'; deletions; additions; deletionLineIndex; additionLineIndex }
```

**Hunk-content grouping** (`utils/parsePatchFiles.ts`, the per-line loop ~L336):
walk the hunk body char-by-first-char. Consecutive `' '` lines accumulate into
one `ContextContent`; consecutive `+`/`-` lines accumulate into one
`ChangeContent` (a change block carries *both* its deletion count and its
addition count — they are not interleaved, deletions then additions). This
run-length encoding is what makes context folding and split pairing trivial
later.

**Context folding / collapsers**: unchanged regions *between* hunks are never
stored as content — they're just the integer `hunk.collapsedBefore` (and a
trailing region on the last hunk). Expansion state lives outside the model as an
`expandedHunks: Map<hunkIndex, {fromStart, fromEnd}>` (or `true` = expand all).
`utils/virtualDiffLayout.ts` (`getExpandedRegion` / `getTrailingExpandedRegion`)
turns a collapsed range + expansion state into "show N from the top, N from the
bottom, keep M collapsed". `collapsedContextThreshold` (default 2 in options, 1
in `constants.ts`) auto-expands tiny gaps so you never collapse 1–2 lines behind
a separator.

### 1.3 Intra-line / word-level diff — the important part

Location: `utils/renderDiffWithHighlighter.ts` (`computeLineDiffDecorations`,
~L259) + `utils/parseDiffDecorations.ts`.

**Granularity** is configurable via `lineDiffType: 'word-alt' | 'word' | 'char'
| 'none'` (default **`word-alt`**):

- `char` → jsdiff `diffChars(deletionLine, additionLine)`
- `word` / `word-alt` → jsdiff `diffWordsWithSpace(deletionLine, additionLine)`
- `none` → skip (also force-disabled for files >1000 rendered lines, and per-line
  when either side exceeds `maxLineDiffLength`, default 1000 chars)

**Which lines get an intra-line diff**: only rows where the change block has a
paired deletion AND addition on the same visual row. In
`renderDiffWithHighlighter`'s iterate callback:
`if (type === 'change' && additionLine != null && deletionLine != null)`. Pairing
is **positional**: the i-th deletion line of a change block is diffed against the
i-th addition line (see `getChangeLineData` in `iterateOverDiff.ts`). There is no
similarity/LCS matching to choose *which* deletion pairs with *which* addition —
it's just index i vs index i. Extra deletions or additions beyond
`min(deletions, additions)` render as pure single-sided rows with no intra-line
highlight.

**How ranges are computed & represented**:

1. Trim trailing newline from both lines (`cleanLastNewline`).
2. Run the jsdiff word/char diff → array of `{value, added?, removed?}` chunks.
3. Walk chunks into two `[flag, text][]` span lists (`deletionSpans`,
   `additionSpans`) via `pushOrJoinSpan`. `flag` is `1` = changed, `0` =
   unchanged. Neutral (unchanged) chunks go to *both* sides; `removed` chunks
   only to the deletion side; `added` only to the addition side.
4. **`word-alt` join rule** (`pushOrJoinSpan`, `parseDiffDecorations.ts`): merge
   a changed span with an adjacent changed span if they're separated by a single
   whitespace chunk — i.e. `foo bar` → `baz bar` highlights `foo` and the space
   as one region instead of leaving a one-space gap. Specifically: a single-char
   neutral chunk gets absorbed into the preceding non-neutral span. This is the
   only difference between `word` and `word-alt`.
5. Convert each changed span into a **decoration** (`createDiffSpanDecoration`):
   ```
   { start: {line, character: spanStart},
     end:   {line, character: spanStart + spanLength},
     properties: { 'data-diff-span': '' },
     alwaysWrap: true }
   ```
   `spanStart` is a running character offset within the line. These decorations
   are handed to **Shiki** (`codeToHast({ decorations })`), which splits tokens
   at the range boundaries and tags the changed sub-token with
   `data-diff-span`. CSS then paints that span (see §2.4).

**Intra-line range data model** (what a port must reproduce):
`{ side: 'addition'|'deletion', lineIndex, charStart, charLength }`. Note it is
**character offsets on the already-computed line string**, not byte offsets, not
token indices.

Key subtlety: Shiki does the actual token-splitting so the diff-span boundary
can fall *inside* a syntax token; the token is cloned into
before/inside/after pieces (`box-decoration-break: clone`) each keeping the
token's fg color. A terminal port must do this token-splitting itself.

---

## 2. Visual language (the diffs.com look)

All values below are extracted verbatim from `style.css` (the single source of
visual truth) and `constants.ts`. Colors use CSS `light-dark()` and
`color-mix(in lab, …)`. `lab` is used deliberately (comment at L85) to dodge an
oklch `color-mix` bug in the Chromium builds shipped by VS Code / Cursor.

### 2.1 Base palette (`:host`, style.css L23–28)

| Semantic | Light | Dark |
|---|---|---|
| Added (green)   | `#0dbe4e` | `#5ecc71` |
| Modified (blue) | `#009fff` | `#69b1ff` |
| Deleted (red)   | `#ff2e3f` | `#ff6762` |

`--diffs-bg` defaults to `#fff` / `#000`; `--diffs-fg` to `#000` / `#fff`;
`--diffs-mixer = light-dark(black, white)` (the "toward the opposite end"
direction used for all subtle tints).

### 2.2 Row background tints (the add/remove wash)

Computed in the `[data-background]` block (L484–668). The row bg is
`color-mix(in lab, <base-row-bg> <mix%>, <target-color>)` where target is the
add/remove base color:

| Element | Light mix (→ % color) | Dark mix (→ % color) |
|---|---|---|
| Changed **line body** (`[data-line]`) | `88%` bg → **12% color** | `80%` bg → **20% color** |
| Changed **gutter/number** | `91%` bg → **9% color** | `85%` bg → **15% color** |
| Line body, hovered | `80%`/**20%** | `75%`/**25%** (add), `75%` (del) |

So an added line is `~12–20%` of the green base washed over the page bg; the
number gutter is a slightly weaker wash. Deletion uses the red base, addition
the green base. Merge-conflict "current" reuses the addition color, "incoming"
reuses the modified/blue color.

### 2.3 Intra-line emphasis span (the brighter changed-word chunk)

`--diffs-bg-*-emphasis` (L184–205) and the `[data-diff-span]` rules (L1478–1489):

```css
--diffs-bg-deletion-emphasis: light-dark(
  rgb(from var(--diffs-deletion-base) r g b / 0.15),   /* 15% alpha light */
  rgb(from var(--diffs-deletion-base) r g b / 0.2));   /* 20% alpha dark  */
--diffs-bg-addition-emphasis: /* same, addition base, 0.15 / 0.2 */;

[data-diff-span] { border-radius: 3px; box-decoration-break: clone; }
[data-line-type='change-addition'] [data-diff-span] { background: var(--diffs-bg-addition-emphasis); }
[data-line-type='change-deletion'] [data-diff-span] { background: var(--diffs-bg-deletion-emphasis); }
```

So the changed *words* get an **additional** translucent color block (15–20%
alpha of the same base) on top of the already-tinted row → the changed range
reads as a brighter/denser bar within the softer full-row wash. Rounded 3px,
`clone` so wrapped fragments each get rounded ends.

### 2.4 Layering order (syntax UNDER diff, emphasis BETWEEN)

Bottom → top:
1. **Row tint** — `--diffs-line-bg` on `[data-line]` (opaque, from §2.2).
2. **Emphasis span bg** — translucent block on `[data-diff-span]` (§2.3), sits
   over the row tint (alpha lets the row tint show through).
3. **Syntax token fg** — `[data-line] span { color: … }` from Shiki
   (`--diffs-token-light` / `--diffs-token-dark`). Tokens normally have
   *no* bg (`background: inherit`), so the diff bg shows through; a Shiki theme
   *could* set a token bg but Pierre's themes don't.

The crucial trick: **syntax highlighting is never overridden by diff coloring.**
Foreground stays theme-colored; add/remove is expressed purely through
background. That is the core of the "blends with your theme" claim.

### 2.5 Gutter / line numbers

- Two-column CSS **subgrid**: `[data-gutter]` (col 1) + `[data-content]` (col 2),
  grid `minmax(min-content,max-content) 1fr` (L279).
- Numbers: `[data-column-number]`, right-aligned, fg `--diffs-fg-number` =
  `color-mix(in lab, fg 65%, bg)` (dimmed to 65%). On a changed line the number
  fg switches to the full add/remove base color (L516, L558).
- Min width `3ch`, `padding-left: 2ch`, `border-right: 2px solid bg` separating
  gutter from content.
- `disableLineNumbers` collapses the number column to a 4px stub.

### 2.6 Diff indicators (`diffIndicators`, default `bars`)

Three modes (`DiffIndicators = 'classic' | 'bars' | 'none'`):

- **`bars`** (default, L1369): a **4px vertical bar** drawn as `::before` on the
  number cell. Addition = solid `--diffs-addition-base`. Deletion = a *dashed*
  bar — `linear-gradient(0deg, bg-deletion 50%, deletion-base 50%)` repeated at
  `~2px` (rounded to line-height) so it reads as a dashed/ticked red bar vs the
  solid green.
- **`classic`** (L1327): a `+` / `-` char prefix inside the content
  (`content: '+'` colored addition-base; `'-'` colored deletion-base),
  content padded `2ch` to make room.
- **`none`**: nothing.

### 2.7 Hunk separators / "N unmodified lines" collapser

`HunkSeparators = 'simple' | 'metadata' | 'line-info' | 'line-info-basic' |
'custom'`, default **`line-info`**. Built in `utils/createSeparator.ts`, styled
L966–1318.

- **`line-info`** (default): a 32px-tall rounded (6px) pill, bg
  `--diffs-bg-separator` (light `mix(bg 96%)` → 4%; dark `mix(bg 85%)` → 15%),
  containing an **expand button** (32px, a chevron icon) + the text
  **"`N unmodified line[s]`"** (`getModifiedLinesString`, L1506 — literally
  ``${lines} unmodified line${plural}``). Expand direction: `both` chevrons for
  interior hunks, `down` for the first, `up` for the last. When the collapsed
  range exceeds `expansionLineCount` (default 100) it's "chunked" → adds an
  "Expand all" button and separate up/down buttons.
- **`line-info-basic`**: same minus some container-query niceties.
- **`metadata`**: shows the raw `@@ -a,b +c,d @@` hunkSpecs instead of a count.
- **`simple`**: a 4px bg strip, no text.
- **`custom`**: emits a `<slot>` so the host app renders it.

Separators are duplicated across the gutter and content columns (and across both
split columns) with CSS hiding the redundant copies so the pill spans correctly.

### 2.8 Split vs unified filler / buffer rows

- **`[data-content-buffer]`** (L950): the alignment filler on the shorter side
  of a split change block. It's painted with a **diagonal hatch**:
  `repeating-linear-gradient(-45deg, transparent … var(--diffs-bg-buffer) …)`,
  `--diffs-bg-buffer = mix(bg 92%)` → 8% wash. Stripe period ~`3–4px * √2`. This
  is the classic "this side has no corresponding line" texture.
- **`--diffs-bg-context`** (unchanged/expanded context rows): light `mix(bg
  98.5%)` → 1.5%; dark `mix(bg 92.5%)` → 7.5% (barely-there gray so context
  reads as slightly recessed vs true unchanged code).

### 2.9 Word-wrap

`overflow: 'scroll' | 'wrap'` (default `scroll`). `scroll`: `white-space: pre`,
horizontal scroll, sticky gutter. `wrap` (L1412): `white-space: pre-wrap;
word-break: break-word`. Split-wrap uses a 4-column subgrid
(`repeat(2, code-grid)`) so both sides wrap independently while staying aligned
per logical row.

### 2.10 Header & change summary

`[data-diffs-header='default']` (L1571): filename (with rtl-ellipsis so the tail
is preserved), a rename arrow + dimmed `prevName`, and a metadata cluster with
`+N` in addition-base green / `-N` in deletion-base red, plus a change-type icon
colored per `ChangeTypes` (blue modified / green new / red deleted).

---

## 3. Split / unified layout logic

### 3.1 Row model (`utils/iterateOverDiff.ts`)

One `iterateOverDiff({diff, diffStyle: 'unified'|'split'|'both', callback})`
walks the whole diff and emits one callback per rendered row. Each hunk is walked
as: leading expanded context → `hunkContent[]` (context blocks + change blocks) →
trailing expanded context. The callback receives `{type, deletionLine?,
additionLine?, collapsedBefore, collapsedAfter, …}` where each `*Line` carries
`{lineNumber, lineIndex, unifiedLineIndex, splitLineIndex, noEOFCR}`.

### 3.2 Pairing in split mode

A `ChangeContent` with `D` deletions and `A` additions produces
**`max(D, A)` split rows**. On row `i` (`getChangeLineData`):
- deletion side present iff `i < D` → `deletionLines[deletionLineIndex + i]`
- addition side present iff `i < A` → `additionLines[additionLineIndex + i]`
- rows where both are present (`i < min(D,A)`) are the ones that get the
  positional intra-line word diff (§1.3).
- rows where one side is missing (`min(D,A) ≤ i < max(D,A)`) render a real line
  on one side and a **filler buffer** on the other
  (`createEmptyRowBuffer(1)`, pushed at DiffHunksRenderer L1137/L1165 — a
  `grid-row: span 1` hatch cell).

Context rows always occupy both sides with the same line (different line
numbers). `splitLineCount = Σ over content(context.lines + max(D,A))`;
`unifiedLineCount = Σ(context.lines + D + A)`. Both are precomputed per hunk.

### 3.3 Unified mode

Same walk, but a change block emits `D + A` rows: all deletions first, then all
additions (`splitLineIndex` still tracked so a row can be located in either
coordinate space). No filler rows.

### 3.4 Column geometry (CSS)

- Unified: single `[data-code]` grid, `number 1fr`.
- Split scroll (L759): outer `grid-template-columns: 1fr 1fr`; left
  `[data-deletions]`, right `[data-additions]`, 1px `bg` divider between.
- Split wrap (L873): `grid-auto-flow: dense; grid-template-columns: repeat(2,
  code-grid)` (4 tracks: del-gutter, del-content, add-gutter, add-content), each
  half a `display: contents` wrapper.
- Gutter is `position: sticky; left: 0` in scroll mode so numbers stay pinned.

### 3.5 Responsive / auto-switching

There is **no automatic unified↔split switch** based on width. `diffStyle` is an
explicit option (default `split`). Responsiveness is limited to: container
queries (`@supports (width: 1cqi)`) tuning separator geometry, `pointer: coarse`
vs `fine` tweaking expand-button hit targets and hover backgrounds, and
`prefers-reduced-motion`. Layout switching, if wanted, is the host app's job.

---

## 4. Terminal translation notes

Raxol cells give you: one bg color, one fg color, and attributes (bold, dim,
italic, underline, reverse) per cell. Pierre's model is "layered translucent
backgrounds under theme-colored fg", which must be *pre-flattened* to opaque
per-cell colors. Map the CSS `color-mix` at the documented percentages against
your actual terminal bg to get concrete RGB, then quantize to the terminal's
color depth (truecolor if available, else nearest 256-color).

| Pierre feature | CSS mechanism | Terminal mapping | Loss / approximation |
|---|---|---|---|
| Row add/remove tint | `color-mix(bg 88%/80%, base)` line bg | Precompute opaque bg per cell; set on **every cell of the row** incl. trailing padding to end-of-width | Faithful if truecolor; on 256-color, quantize — subtle 12% washes may collapse to the same swatch, bump toward ~18–22% for separability |
| Number-gutter tint | `mix(bg 91%/85%, base)` + base-colored number fg | Gutter cells: dim bg tint + set number fg to the add/remove base color | Fine |
| Intra-line emphasis span | translucent `rgb(base / .15-.2)` over row tint, rounded | **Second, brighter bg tier** on changed-word cells: flatten (row-tint ⊕ 0.15–0.20 base) to opaque; apply to exactly those cells | The 3px rounding and alpha translucency are gone; you get a hard-edged brighter block. This is the single biggest visual delta |
| Syntax under diff | token fg from Shiki, diff only touches bg | Keep your syntax-highlighter fg per cell; only ever set **bg** for diff state | Faithful — this is actually *easier* in a terminal (fg/bg are already orthogonal) |
| `bars` indicator (4px bar) | `::before` 4px gradient bar in gutter | Reserve 1 gutter column: `▎`/`█` (U+258E/2588) in add-base green (solid) or a dashed glyph run (`╎`, or alternating `█`/space) in del-base red | 4px→1 cell; dashed-gradient → a dashed glyph or dim variant |
| `classic` indicator (+/-) | `::before` colored `+`/`-` | Literal `+`/`-`/` ` first content column, colored | Faithful (and cheapest) |
| Hunk collapser "N unmodified lines" | 32px rounded pill + chevron button | One full-width row, bg `--diffs-bg-separator` flattened, text `⋯ N unmodified lines`, a `▲▼`/`⌄` affordance | Rounded pill → flat bar; expansion is a keybind/click on the row |
| Split filler (diagonal hatch) | `repeating-linear-gradient(-45deg…)` | Fill the empty side with a dim hatch glyph run (`╱` repeated, or `░` light-shade) in `--diffs-bg-buffer` tone | `░`/`╱` is a good stand-in; exact 45° period is lost |
| Context (unchanged) rows | `mix(bg 98.5%/92.5%)` | Very slight bg tint, or just default bg | The 1.5% light wash is below terminal quantization — likely drop it in light mode, keep the 7.5% dark wash |
| Split side-by-side | CSS grid `1fr 1fr` + sticky gutter | Two half-width panes with a 1-col `│` divider; each pane = its own gutter+content | Horizontal room is the constraint; below ~120 cols, prefer unified |
| Word-wrap | `pre-wrap; word-break` | Raxol `ScrollContent` soft-wrap or horizontal scroll | Feasible; wrapped intra-line spans need per-fragment bg (already how cells work) |
| Hover / selection bg | `pointer: fine` hover mixes | Optional: reverse-video or a brighter tier on the focused row | Fine |
| `light-dark()` theming | CSS auto | Pick light vs dark base set from the active Raxol theme's luminance | Fine |
| Rounded corners, box-shadow, `√2` hatch spacing, opacity gradients | CSS | — | **Cannot map**; drop |

**Cannot map at all**: sub-cell geometry (3px/4px/6px radii, the 4px bar vs a
full cell), true alpha compositing (all translucency must be flattened to
opaque), the diagonal hatch angle/period, sticky-scroll physics, container
queries. Everything else has a defensible terminal analogue.

---

## 5. Port plan (ordered)

Build bottom-up; each step is independently testable against Pierre's own model
as an oracle (the structured `FileDiffMetadata` is JSON and byte-stable).

1. **Line-level diff engine** — Myers over the two line arrays. Elixir options:
   port a compact Myers (~150 LOC), or wrap an existing lib. Output: opcodes
   (`:eq | :del | :ins` runs). Skip the patch-string round-trip for the
   two-buffer case; keep a separate unified-patch parser only if you must accept
   patch text as input (regexes are all in Pierre's `constants.ts`).

2. **Structured hunk model** — from opcodes build the equivalent of
   `FileDiffMetadata` / `Hunk` / `ContextContent` / `ChangeContent`: run-length
   group consecutive eq lines (context) and consecutive del/ins (change),
   compute `collapsedBefore` per hunk, and precompute `split_line_count` /
   `unified_line_count`. Keep it index-based (flat `deletion_lines` /
   `addition_lines`) so rendering and folding stay cheap. This is the port's
   spine — mirror the type names in §1.2.

3. **Intra-line ranges** — for each *paired* change row (i-th del vs i-th ins,
   positional), run a word diff (split on word boundaries incl. whitespace, à la
   `diffWordsWithSpace`) or char diff, emit
   `{side, line_index, char_start, char_len}` ranges. Implement the `word-alt`
   join (merge changed spans across a single-space gap). Guard with
   `max_line_diff_length` (1000) and a whole-file `:none` fallback above ~1000
   rows. Use `Raxol.UI.TextMeasure` for column math (CJK = 2 cells) — Pierre
   uses JS char offsets, which are wrong for wide chars; the terminal port must
   use display-width offsets.

4. **Hunk folding / expansion** — represent expansion as
   `expanded_hunks :: %{hunk_index => {from_start, from_end}} | :all`, port
   `getExpandedRegion` / trailing-region math, honor
   `collapsed_context_threshold` (auto-expand ≤2-line gaps), and render the
   collapser row with `"N unmodified lines"` + an expand affordance and
   `expansion_line_count` (100) chunking.

5. **Row iterator** — port `iterateOverDiff` as a reducer/stream that yields one
   render-row per callback for `:unified` / `:split`, including filler rows on
   the short side of a split change block. This decouples model from renderer
   and is where split/unified diverge (§3.2–3.3).

6. **Visual spec → terminal styles** — implement the table below as the styling
   layer. Precompute opaque colors once per (theme, terminal-bg); cache.

### 5.1 Visual spec table (Pierre CSS → Raxol terminal style)

| Token | Pierre value (light / dark) | Terminal style |
|---|---|---|
| add base | `#0dbe4e` / `#5ecc71` | fg for `+N`, addition bar, addition number |
| del base | `#ff2e3f` / `#ff6762` | fg for `-N`, deletion bar, deletion number |
| modified base | `#009fff` / `#69b1ff` | headers, selection, merge "incoming" |
| addition row bg | `mix(bg 88%, add)` / `mix(bg 80%, add)` (12% / 20%) | opaque cell bg, whole row |
| deletion row bg | `mix(bg 88%, del)` / `mix(bg 80%, del)` | opaque cell bg, whole row |
| gutter row bg | `mix(bg 91%, base)` / `mix(bg 85%, base)` (9% / 15%) | gutter cell bg |
| addition emphasis | `rgb(add / .15)` / `.20` over row | 2nd-tier brighter opaque bg on changed cells |
| deletion emphasis | `rgb(del / .15)` / `.20` over row | 2nd-tier brighter opaque bg on changed cells |
| context row bg | `mix(bg 98.5%)` / `mix(bg 92.5%)` (1.5% / 7.5%) | none (light) / faint bg (dark) |
| separator bg | `mix(bg 96%)` / `mix(bg 85%)` (4% / 15%) | collapser row bg |
| buffer/filler bg | `mix(bg 92%)` (8%) + `-45°` hatch | dim hatch glyph (`░`/`╱`) fill |
| number fg (normal) | `mix(fg 65%, bg)` | dim gutter fg |
| number fg (changed) | add/del base | colored gutter fg |
| indicator (default) | 4px bar; add solid, del dashed | 1-col `▎`/dashed glyph, colored |
| collapser text | `"N unmodified line[s]"` | `⋯ N unmodified lines` |
| syntax tokens | Shiki fg, no bg | keep highlighter fg; diff sets bg only |

### 5.2 Open decisions for the Raxol side (flag before coding)

- **Truecolor vs 256**: the whole aesthetic assumes ≥24-bit. Detect via
  capabilities; on 256-color, widen the 12%→~20% washes so tiers stay distinct.
- **Default `diffStyle`**: Pierre defaults `split`; in a terminal, split needs
  ~2× width — consider auto-choosing unified below a width threshold (Pierre
  itself does *not* auto-switch; this would be a deliberate Raxol addition — a
  scope decision, not a port of existing behavior).
- **Emphasis tier**: decide whether the brighter intra-line block is a distinct
  bg tier or (fallback) `bold`/`underline` on the changed word run when only 8/16
  colors are available.
- **Word tokenizer**: match `diffWordsWithSpace` semantics (whitespace is its own
  token so it can be shared/split) and use display-width, not codepoint, offsets.

---

## Appendix: key source files

| Concern | File |
|---|---|
| Data model / all types | `src/types.ts` |
| File→patch→model | `src/utils/parseDiffFromFile.ts` |
| Patch parser + hunk grouping | `src/utils/parsePatchFiles.ts` |
| Intra-line diff + decoration build | `src/utils/renderDiffWithHighlighter.ts` |
| Span join / `word-alt` rule | `src/utils/parseDiffDecorations.ts` |
| Row iterator, split/unified pairing | `src/utils/iterateOverDiff.ts` |
| Fold/expansion math | `src/utils/virtualDiffLayout.ts` |
| Collapser separator markup | `src/utils/createSeparator.ts` |
| Split filler row | `src/utils/createEmptyRowBuffer.ts` |
| DOM/HAST renderer, separators, buffers | `src/renderers/DiffHunksRenderer.ts` |
| **All visual values** (colors, mixes, layout) | `src/style.css` |
| Constants, default themes, regexes | `src/constants.ts` |
