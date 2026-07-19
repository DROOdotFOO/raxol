# Unicode width — derive the table, don't curate it

Status: **draft / design** · Date: 2026-07-19 · Owner: V + Claude
Parent: `raxol-problems-backlog` (width defects) · Depends on nothing
Touches: `packages/raxol_terminal/lib/raxol/terminal/character_handling.ex`,
`lib/raxol/ui/text_measure.ex`
Non-goals of this doc: implementing the generator (follow-up PR); bidi; the
emulator cell model for zero-width codepoints (§7, escalated)

Spine decision: **replace the hand-curated allowlist with a compile-time
generated balanced range tree derived from `EastAsianWidth.txt` +
`emoji-data.txt`, vendored SHA-pinned under `priv/unicode/` with a drift gate,
and split single-codepoint width (generated data) from grapheme-cluster width
(hand-written policy) into two modules behind the existing
`CharacterHandling` facade.** No new runtime dependency, no ETS, no
`persistent_term`, no flag day.

---

## 1. Problem (ground truth)

`packages/raxol_terminal/lib/raxol/terminal/character_handling.ex:16` is an
**allowlist**:

```elixir
def wide_char?(char) do
  wide_ranges = [ {0x4E00, 0x9FFF}, ..., {0x1F300, 0x1FAFF} ]
  Enum.any?(wide_ranges, fn {start, finish} -> char >= start and char <= finish end)
end
```

Three structural properties of that shape, each of which has already produced a
shipped defect:

1. **Every gap defaults to 1.** A codepoint outside a curated range is silently
   narrow. There is no "unknown" state and no way to notice a gap except by
   watching a border move.
2. **The list is rebuilt on every call.** `wide_ranges` is a literal
   constructed inside the function body, then linearly scanned. It is O(n) per
   character on the hottest path in the renderer. `writer.ex:355` already
   carries a hand-rolled `memoized_width/2` map specifically to work around
   this.
3. **`combining_char?/1` is dead code with respect to width.**
   `get_char_width/1` never calls it. Zero-width behavior today is an
   *accident* of `String.graphemes/1` clustering the mark onto its base — which
   is why `get_string_width("Helló") == 5` passes while
   `get_char_width(0x0301) == 1` is wrong.

### Confirmed defects (measured, read off the source)

| Input | Today | Correct | Why the allowlist misses it |
|---|---|---|---|
| `✅` U+2705, `❌` U+274C, `⭐` U+2B50 | 1 | 2 | Emoji range starts at `0x1F300`; the whole pre-Unicode-6 pictograph area (U+2600–27BF, U+2B00–2BFF) is uncovered |
| `❤️` (U+2764 U+FE0F) | 1 | 2 | VS16 is ignored entirely; `❤` and `❤️` are indistinguishable |
| `1️⃣` (U+0031 U+FE0F U+20E3) | 1 | 2 | Keycap sequence; first codepoint is ASCII `1` |
| ZWSP U+200B, lone ZWJ U+200D, SHY U+00AD | 1 | 0 | No zero-width class exists in the width path |
| `🇯🇵` regional-indicator pair | 1 → **2** | 2 | **Already fixed** (`character_handling.ex:83`) — but fixed *only for flags*, as a special case, not as a rule |

The flag fix is the tell. It is a correct patch to one hole in a surface that
is made of holes. The regression that motivated it — a frame border pushed out
by one column — is reachable from every row of that table.

### Verified-correct, must not regress

Skin-tone modifiers · ZWJ family sequences (`👨‍👩‍👧‍👦`) · Hangul syllables ·
fullwidth forms · CJK ideographs · kana · post-2020 emoji (U+1FAF6) ·
box-drawing · arrows · em dash · ellipsis.

### Blast radius (measured)

Production callers of `CharacterHandling`:

| File | Clause used | Consequence of a wrong width |
|---|---|---|
| `terminal/buffer/writer.ex:29,369,450` | binary (grapheme) | Reserves / fails to reserve `Cell.new_wide_placeholder/1` |
| `terminal/screen_buffer/operations.ex:19,75` | binary | Same, plus wide-char fit check at line end |
| `terminal/input/character_processor.ex:53,118` | **integer** | Cursor advance + autowrap in the VT parser |
| `lib/raxol/ui/text_measure.ex` | all three | The repo-wide facade — ~60 files downstream |
| `lib/raxol/performance/caches/font_metrics_cache.ex` | both | Cached, so a wrong value persists |

`Raxol.UI.TextMeasure` fans out to roughly 60 files across layout, harness
components, charts, text layout, search, and the paint authority. This module
is the single source of width truth for terminal, LiveView, MCP and harness
surfaces simultaneously.

---

## 2. Decision: vendor UCD extracts, generate a range tree

### 2.1 Data source

**Recommendation: vendor SHA-pinned extracts of `EastAsianWidth.txt` and
`emoji-data.txt` under `packages/raxol_terminal/priv/unicode/`, plus
`DerivedGeneralCategory.txt` for the zero-width classes, and generate an Elixir
module from them with `mix raxol.unicode.gen`. Check the generated module into
`lib/`. Gate drift with `mix raxol.unicode.verify`.**

This is the `packages/raxol_agent_client_protocol/priv/schema-oracle/` pattern
(`PINNED.md` + checksums + `mix acp.schema.verify`) applied to a second
upstream artifact. Reuse the shape verbatim: a `PINNED.md` recording upstream
URL, Unicode version tag, download date, and SHA256 per file; a verify task
that recomputes and fails on mismatch.

Two properties distinguish this from the ACP oracle and must be stated:

- **The generated module ships.** Unlike the ACP schema (dev/test-only,
  excluded from the Hex package), the width table *is* the runtime. The raw
  `.txt` extracts stay dev/test-only and are excluded from `:files` in
  `mix.exs`; the generated `.ex` is normal published source.
- **License.** The UCD is under the Unicode License v3, which is permissive
  and BSD-shaped. Record it in `NOTICE`/`PINNED.md`. It does not create the
  Apache-2.0 propagation concern that motivated the ACP exclusion, but the
  attribution requirement is real and must be honored in the generated file's
  header.

Which files, and what we take from each:

| File | Property extracted | Yields |
|---|---|---|
| `EastAsianWidth.txt` | `W` (Wide), `F` (Fullwidth) | width 2 |
| `EastAsianWidth.txt` | `A` (Ambiguous) | width 1 — see §6 policy |
| `emoji-data.txt` | `Emoji_Presentation=Yes` | width 2 (this is what catches U+2705 / U+274C / U+2B50) |
| `DerivedGeneralCategory.txt` | `Mn`, `Me`, `Cf` | width 0 |
| (hardcoded in generator) | U+1160–11FF Hangul Jamo medial/final, U+200B, U+00AD | width 0 |

`Cf` (format) as zero-width is what gives ZWSP/ZWJ/soft-hyphen their 0. Note
that U+00AD is `Cf`, so it falls out of the rule rather than needing a special
case; it is listed above for clarity only.

#### Rejected: a Hex dependency

Candidates exist (`unicode`, `string_width`-shaped packages). Rejected because
`raxol_terminal`'s dep list is deliberately four packages wide
(`raxol_core`, `uuid`, `jason`, `elixir_make`) and it is published to Hex, so
every dep is inherited by every downstream consumer of the terminal surface. A
width table is ~40KB of generated code with zero ongoing API surface; taking a
dependency to avoid writing a parser we run *once* is a bad trade. It also
surrenders control over the ambiguous-width policy (§6), which is the one
decision here that is genuinely ours to make.

#### Rejected: hand-extending the ranges

This is the status quo with more entries. It fixes the five defects in §1 and
leaves the *shape* — allowlist, silent default, no provenance, no drift
detection — exactly as it is. The next Unicode release reopens every hole. The
whole point of this proposal is that the bug is the curation, not the contents.

#### Rejected: parsing the `.txt` at compile time from `priv/`

Tempting (no generated file to review), rejected because the PR diff becomes
invisible: a pin bump would silently change runtime behavior with nothing to
read in review. Checking in the generated module makes every width change a
reviewable line in a diff. That is the property we are buying.

### 2.2 Representation and lookup

Width is queried per grapheme on every buffer write and every layout
measurement. Ranges after derivation: roughly 600 (≈120 wide, ≈80 emoji-
presentation, ≈400 zero-width), after merging adjacent runs.

**Recommendation: an ASCII fast-path clause, then a compile-time generated
balanced binary decision tree of guard clauses.**

```elixir
# Generated. Tier 0 — one comparison, covers >95% of real traffic.
def width(cp) when cp >= 0x20 and cp <= 0x7E, do: 1

# Tier 1 — balanced tree over the merged range table, depth ~10.
def width(cp) when cp < 0x1100, do: w_0(cp)
def width(cp), do: w_1(cp)

defp w_0(cp) when cp < 0x0300, do: ...
# ... generated to leaves:
defp w_37(cp) when cp >= 0x2B50 and cp <= 0x2B59, do: 2
defp w_37(_cp), do: 1
```

Why this and not the alternatives:

| Option | Verdict |
|---|---|
| **Balanced guard tree (recommended)** | O(log n) ≈ 10 integer comparisons, worst case. Zero runtime state. No app-start ordering hazard — works in escripts, releases, and during `Code.ensure_loaded?` probing from `TextMeasure`. Compiles to a few hundred clauses; compile cost is sub-second. |
| Flat generated clauses (one per range, linear) | Simple to generate, but BEAM does not build a jump table for *range* guards (only for exact literal matches), so it degrades to a 600-deep linear scan. Strictly worse than the tree for the same generator effort. |
| Binary search over a tuple/binary in `:persistent_term` | Comparable speed, but requires a startup hook to populate, which introduces an init-order dependency on a module that `TextMeasure` probes with `Code.ensure_loaded?/1` and that must work before the application tree is up. Keep as the documented fallback if the generated module ever becomes a compile-time problem. |
| ETS | Rejected. Per-lookup term copy out of the table, plus a table owner process, plus init ordering — all three costs, on the hottest path, to store data that is constant at compile time. |
| Status quo (`Enum.any?` over a rebuilt literal list) | Rejected: O(n) *and* allocates the range list per call. |

`writer.ex`'s existing `memoized_width/2` map stays. It is still worth having
for the grapheme path (which does cluster classification, not just a table
lookup), and it is orthogonal to this change.

### 2.3 Module split

Three layers, with a hard seam between generated data and hand-written policy:

```
Raxol.Terminal.CharacterWidth.Table      # GENERATED. Pure single-codepoint. width/1 -> 0 | 1 | 2
Raxol.Terminal.CharacterWidth            # Hand-written. Cluster policy. Public API.
Raxol.Terminal.CharacterHandling         # Existing facade. Delegates. Contract unchanged.
```

The generated module must contain **no policy** — no ambiguous-width decision,
no cluster rules, nothing a human would want to argue about. Everything
arguable lives in the hand-written middle layer where it can carry a comment
explaining itself. This is the property that keeps the pin bumpable: a Unicode
version bump regenerates Table and touches nothing else.

### 2.4 Grapheme-cluster rules (what a table cannot express)

These are properties of a *cluster*, not a codepoint, and belong in
`CharacterWidth`, applied over `String.graphemes/1` output:

| Rule | Behavior | Note |
|---|---|---|
| Base + VS16 (U+FE0F) | 2 | Emoji-presentation promotion. Fixes `❤️`. |
| Base + VS15 (U+FE0E) | 1 | Text-presentation demotion. The inverse; cheap to add at the same time. |
| Regional-indicator **pair** | 2 | Already implemented; move it here. A *lone* RI stays 1 — preserve that, it is deliberate and tested. |
| Keycap: base + FE0F + U+20E3 | 2 | Subsumed by the VS16 rule if VS16 is checked anywhere in the cluster rather than only in position 2. Prefer the general form. |
| ZWJ sequence | 2 | Width of the leading emoji, not the sum. Already correct by accident (first codepoint lands in the emoji range); make it explicit. |
| Skin-tone modifier U+1F3FB–FF | contributes 0 | Absorbed into the cluster. Already correct via clustering. |

Implementation shape: scan the cluster's codepoints once; if any is VS16 → 2;
if the first two are both regional indicators → 2; otherwise take
`Table.width/1` of the first codepoint and, if that is 0, fall back to the
first non-zero-width codepoint in the cluster.

That last fallback matters and is easy to miss: a cluster whose *first*
codepoint is zero-width (a defective combining sequence, or text beginning with
a lone mark) must not measure the whole cluster as 0.

---

## 3. Public contract and the `0 | 1 | 2` problem

`get_char_width/1` is specced `1 | 2`. Correct zero-width widening makes it
`0 | 1 | 2`. **This is not a uniform change across the two clauses**, and
conflating them is the main way this project could break the emulator.

| Clause | Consumer | Safe to return 0? |
|---|---|---|
| **binary** (grapheme) | `writer.ex`, `operations.ex`, `TextMeasure` → layout | **Yes.** A zero-width *grapheme* (ZWSP, lone ZWJ) reserves no cell; nothing downstream reserves a placeholder for it. Layout summing 0 is exactly right. |
| **integer** (codepoint) | `character_processor.ex` — the VT parser | **No, not yet.** This path is a *stateful codepoint stream*: a combining mark arrives as its own codepoint *after* its base has already been written and the cursor advanced. Returning 0 makes the emulator not advance — which is correct — but leaves undefined where the mark's glyph lands in the cell model. |

So the phasing (§4) fixes zero-width on the grapheme path and defers it on the
codepoint path. `@spec` widens to `0 | 1 | 2` in Phase 2 with the integer
clause documented as "never returns 0 today; see Phase 3."

### Intentional changes vs. regressions

| Change | Class |
|---|---|
| U+2600–27BF / U+2B00–2BFF emoji-presentation chars 1 → 2 | **Intentional.** The headline fix. |
| `❤️` (VS16) 1 → 2 | Intentional |
| Keycap `1️⃣` 1 → 2 | Intentional |
| ZWSP / lone ZWJ / SHY 1 → 0 (grapheme path) | Intentional |
| Combining marks 1 → 0 (codepoint path) | **Deferred** to Phase 3 (§7) |
| East Asian Ambiguous stays 1 | Intentional no-op — see §6 |
| Anything in §1's "verified-correct" list changing | **Regression.** Hard fail. |
| A character that is `N`/`Na`/`H` in EAW measuring 2 | Regression. |

---

## 4. Migration — no flag day

**Phase 0 — differential harness (no behavior change).**
A test that enumerates the full range `0x0..0x10FFFF`, computes old-impl vs
new-impl width for each, and emits a categorized diff report. Commit the report
as a reviewed artifact — the *intentional-change ledger*. Every row in it is
either in §3's intentional list or is a bug in the new implementation. Nothing
lands until that ledger is empty of surprises.

This is the single highest-value step. It converts "did we break anything?"
from a judgement call into a diff review.

**Phase 1 — land Table + CharacterWidth; delegate.**
`CharacterHandling.wide_char?/1`, `get_char_width/1`, `get_string_width/1`,
`split_at_width/2`, `combining_char?/1` keep their exact signatures and
delegate. `wide_char?/1` becomes `Table.width(cp) == 2`. `combining_char?/1`
becomes `Table.width(cp) == 0` restricted to `Mn`/`Me` — note this *widens* it
from five curated ranges to the full derived set, which is a fix in its own
right but is unobserved by width (it is dead code there today) and observed
only by `get_bidi_type/1`. Flag it in review.

Zero-width is **not** enabled in Phase 1: `CharacterWidth` clamps `0` to `1` so
Phase 1 is a pure "wide set gets bigger" change. This keeps the Phase 1 diff
reviewable against the ledger without the cell-model question in play.

**Phase 2 — enable zero-width on the grapheme path.**
Remove the clamp for the binary clause only. Widen the `@spec`. Update
`TextMeasure.char_display_width/1`'s spec (`1 | 2` → `0 | 1 | 2`) and its
fallback branch.

**Phase 3 — zero-width on the codepoint path.** Gated on §7. Separate PR.

**Phase 4 — retire the pin-bump ritual into CI.** `mix raxol.unicode.verify`
joins `mix raxol.check`.

Each phase is independently revertable and independently shippable. There is no
point at which both implementations are live behind a runtime flag — the
differential test *is* the flag, evaluated at CI time instead of runtime.

---

## 5. Test strategy

### 5.1 Golden corpus

One fixture list, categorized, with a rationale per entry — a data file, not
scattered assertions:

```elixir
%{category: :emoji_presentation, input: "✅", width: 2,
  why: "U+2705 Emoji_Presentation=Yes; pre-U+1F300, missed by the old allowlist"}
```

Categories (minimum): ascii · latin-1 · combining · cjk-ideograph · kana ·
hangul-syllable · hangul-jamo-conjoining · fullwidth · halfwidth ·
east-asian-ambiguous · emoji-presentation · emoji-text-presentation ·
vs16-promoted · vs15-demoted · keycap · regional-indicator-pair ·
regional-indicator-lone · zwj-sequence · skin-tone · zero-width-format ·
box-drawing · arrows · punctuation · post-2020-emoji.

Every entry in §1's two tables becomes a corpus row. The corpus is the
regression net; it should outlive any particular implementation.

### 5.2 Property tests

1. **Additivity.** `get_string_width(s) == sum(map(String.graphemes(s), &get_char_width/1))`
   for generated strings. This is the law `get_string_width/1` is written to
   satisfy; assert it rather than assuming it.
2. **Split conservation.** `split_at_width(s, w)` returns `{a, b}` with
   `a <> b == s` and `get_string_width(a) <= w`. Currently `do_split_at_width/4`
   iterates *codepoints*, not graphemes — which means it can split a cluster in
   half. The property will find that. It is a pre-existing bug this work should
   fix while it is in the file.
3. **Table totality.** `Table.width/1` returns `0 | 1 | 2` for every codepoint
   in `0x0..0x10FFFF`, including surrogates and unassigned. No fallthrough
   crash, ever.
4. **Monotone concatenation.** `get_string_width(a <> b) >= get_string_width(a)`.
   Catches sign and accumulator errors cheaply.

### 5.3 The structural invariant that keeps biting

**Writer-reserved width must equal renderer-painted width.**

`writer.ex` reserves a `Cell.new_wide_placeholder/1` when width is 2;
`renderer.ex:245` drops placeholder cells when painting. If those two disagree
about a character, the row's painted width diverges from the buffer's width and
every border downstream of it moves. That is precisely the flag bug.

`packages/raxol_terminal/test/raxol/terminal/renderer_test.exs:360` already
encodes this over a five-string list. **Generalize it into a property over the
entire golden corpus:**

```elixir
# For every corpus entry, for a buffer of known width:
#   get_string_width(visible(rendered_row)) == buffer.width
```

This is the assertion that would have caught the flag defect, the ✅ defect, and
the VS16 defect, without anyone having to think of them in advance. It should
be treated as the acceptance gate for this work, not as one test among many.

Add the symmetric check on the emulator path: after feeding a corpus string
through `character_processor.ex`, the cursor column must equal
`get_string_width/1` of the string.

---

## 6. Scope boundaries

### Out of scope, deliberately

**Bidirectional (RTL) text.** `get_bidi_type/1` and `process_bidi_text/1` stay
exactly as they are. They are a different Unicode property (`Bidi_Class`), a
different algorithm (UAX #9, which is stateful and paragraph-scoped), and the
current implementation is a coarse approximation that nothing in the render
path depends on for correctness. Deriving `Bidi_Class` from the UCD is a
natural follow-on once the generator exists, but bundling it here doubles the
review surface for zero width-correctness gain.

**Terminal disagreement on ZWJ sequence width.** Terminals genuinely disagree
on whether `👨‍👩‍👧‍👦` is 2 columns or 8 — it depends on whether the terminal's font
stack actually ligates the sequence. No table can resolve this; it is a
property of the *renderer*, not the text. We take 2 (the leading emoji's
width), which matches the majority of modern terminals and matches current
behavior. Cross-terminal reconciliation belongs with the capability-detection
work, not here.

### Ambiguous width — stated policy

East Asian **Ambiguous** (`A`) characters — Greek, Cyrillic, some box-drawing,
`±`, `°`, `×`, and a long tail — are 2 columns in a legacy CJK locale and 1
column everywhere else. The correct answer depends on the user's terminal
configuration, which we do not have.

**Policy: East Asian Ambiguous is width 1, unconditionally. No configuration
knob in v1.**

Reasoning:

1. It is the default in every modern terminal on a UTF-8 non-CJK locale.
2. It is **what we do today** — every `A` codepoint is outside the current
   allowlist and therefore already measures 1. Choosing 1 makes this a
   zero-regression decision and keeps the entire `A` class out of the Phase 0
   ledger.
3. Choosing 2 would move hundreds of very common characters (`°`, `±`, `×`,
   Cyrillic) to double-width, which would be the single largest behavioral
   change in this project — for a minority-locale benefit, in a codebase whose
   box-drawing and chart glyphs live partly in that class.

The escape hatch, if it is ever needed, is a compile-time config
(`config :raxol_terminal, ambiguous_width: 1 | 2`) selecting between two
generated tables, because a *runtime* knob would make width non-deterministic
across processes and break the writer/renderer invariant in §5.3. Design it
that way; do not build it now.

---

## 7. Risks, and the one escalation

### Risk register

| Risk | Blast radius | Mitigation |
|---|---|---|
| A character's width changes 1 → 2 | Buffer diffs (the row hashes differently → full-row repaint), cursor math, table column sizing, wrap points | Phase 0 ledger; §5.3 invariant |
| Golden/recorded fixtures containing affected characters | Harness golden tests, asciinema `.cast` fixtures, any snapshot with an emoji in it | Expect rebaselining. Grep the fixture corpus for the affected ranges *before* Phase 1 and budget for it. |
| `font_metrics_cache.ex` holds pre-change values | Stale widths surviving a deploy | Cache is process-local/ETS-backed; confirm no persistence across restarts. Verify during Phase 1. |
| LiveView and terminal disagree | The two surfaces render the same model at different widths | Both go through `TextMeasure`; single source holds. The risk is only if LiveView's CSS-side measurement diverges — out of scope, but worth an explicit check. |
| Generated module bloats compile time | Developer experience | Measure in Phase 1. Fallback is the `:persistent_term` representation (§2.2). |
| Pin bump silently changes behavior | Anything | Generated file is checked in; every bump is a reviewable diff, gated by `mix raxol.unicode.verify`. |

### Escalation — needs the repo owner

**Where does a combining mark's glyph land in the cell model?** (Phase 3.)

The VT parser (`character_processor.ex`) consumes codepoints, not graphemes. If
`get_char_width(0x0301)` starts returning 0, the emulator correctly stops
advancing the cursor — but `writer.ex:179`'s `update_row/6` has no defined
behavior for width 0. Three options, and this is a cell-model decision, not a
Unicode one:

1. **Append to the previous cell's character** — `Cell` holds a grapheme
   string, so `"e"` becomes `"é"`. Most correct visually; requires `Cell` to
   tolerate multi-codepoint content and requires the renderer's width
   accounting to agree.
2. **Drop the mark.** Lossy but safe; matches what several terminals do.
3. **Keep the status quo (width 1)** on the codepoint path indefinitely, and
   accept that the emulator advances a column for a combining accent.

Option 1 is probably right, but it touches the cell model, which sits under
ADR-0029 — so it should not be decided inside a width proposal. **Phases 0–2
are unblocked and do not depend on this answer.** Phase 3 needs it.

---

## 8. Acceptance

This work is done when:

- `mix raxol.unicode.verify` passes in `mix raxol.check`.
- The Phase 0 differential ledger contains only rows classified as intentional
  in §3.
- The §5.3 invariant holds as a property over the full golden corpus, on both
  the writer/renderer path and the emulator/cursor path.
- Every §1 defect row measures correctly, and every §1 verified-correct entry
  still does.
- `character_handling.ex` contains no codepoint range literals.

That last one is the real test. If a range literal survives in a hand-written
file, the curation problem survives with it.

## 9. Prior art — what other agent harnesses actually do

Surveyed 2026-07-19: `xai-org/grok-build`, `NousResearch/hermes-agent`, and the
`openclaw` org (`openclaw/openclaw` plus its vendored `@earendil-works/pi-tui`).
All three are agentic coding harnesses with terminal UIs — the closest peers to
Raxol's problem. The question asked was narrow: **has anyone actually solved
this, or is everyone running the same compromises?**

**Nobody has solved it. Three for three.**

| | grok-build | hermes-agent | openclaw |
| --- | --- | --- | --- |
| Width source | `unicode-width` 0.2 | hand-rolled + `get-east-asian-width` | hand-rolled + `get-east-asian-width` |
| Ambiguous width | 1, hardcoded | 1, hardcoded | 1, hardcoded |
| Config knob | none | none | none |
| Probes the terminal **for width** | no | no | no |
| Cluster-safe truncation | partial | no | yes |
| Single width facade | no | no | partial (two impls) |

### 9.1 The consistent finding: the instrument exists, unwired

Each project built terminal-capability probing and **connected none of it to
width**:

- **grok-build** implements a real `XTVERSION` probe (`\x1b[>0q`) with a brand
  allowlist (JediTerm excluded — it "renders the query as garbage"), multiplexer
  interception detection, and dedicated PTY tests. `xtversion::detected()` has
  exactly two consumers: a diagnostics view and telemetry.
- **hermes-agent** defines `cursorPosition()` (DECXCPR) and never calls it;
  `decrqm(2027)` appears only in a usage doc-comment, with no call site. Its
  XTVERSION probe drives xterm.js wheel-scroll compensation.
- **openclaw** does no width probing at all. It sniffs `TERM_PROGRAM` and uses
  it to **delete emoji entirely** on unrecognised terminals
  (`stripDecorativeEmojiForTerminal`) — sidestepping measurement rather than
  performing it.

This is the strongest available evidence that the runtime-adaptation loop
(§6, "Out of scope") is unclosed *industry-wide*, not just here.

### 9.2 The architectural finding: the defect is the missing facade

Every surveyed project exhibits the same failure mode this repo hit — a width
call site gets fixed where someone tripped over it, and its neighbours are left
alone:

- **grok-build**: the input editor segments grapheme clusters correctly; three
  other functions *in the same file* measure per-codepoint and will bisect a
  ZWJ cluster.
- **hermes-agent**: the TypeScript TUI is grapheme-aware; the Python surfaces
  use raw `len()`. Their issue #20621 ("CJK/Emoji characters overflow and
  misalign panel borders due to len()-based width calculation") has **six
  independent open PRs**, each fixing a different render path.
- **openclaw**: two width implementations run in one process and **disagree on a
  lone regional indicator** — `terminal-core` says 1, the vendored `pi-tui` says
  2. Both are documented and reasoned; neither is reconciled.

Raxol is the only one of the four with a single mandated facade
(`Raxol.UI.TextMeasure`, enforced by CLAUDE.md). That is the structural
advantage worth protecting, and it is what makes this proposal a table swap
behind one module rather than an N-call-site migration.

The cautionary half: openclaw's *terminal-core* width bugs get found, fixed and
regression-tested, while their CJK bugs that stay open live in adjacent layers
(token estimation, truncation caps, markdown flanking) where nobody routed
through the abstraction. A facade only helps where it is adopted — see the
`String.length`-for-display-width audit in §9.4.

### 9.3 Techniques worth adopting

Ordered by value. Marked with whether they belong to this proposal or were
taken immediately.

1. **DA1 sentinel barrier** (hermes-agent, `terminal-querier.ts`) — *this
   proposal, §6 revisit*. Capability queries normally need timeouts, which are
   slow and unreliable over SSH. Instead, append DA1 (`CSI c`) after each query
   batch: every terminal since the VT100 answers DA1, and terminals answer in
   order. If the feature response arrives before DA1, it is supported; if DA1
   arrives first, it is not. **Zero timeouts, one round-trip, works for any
   query.** This is the unlock that makes runtime width adaptation — mode 2027
   negotiation and CPR probing — cheap enough to be practical. It materially
   weakens the §6 argument for leaving adaptation out of scope, and is the first
   thing to reconsider when this proposal is picked up.

   Note: their DECXCPR uses `CSI ? 6 n`, with the `?` mandatory because a plain
   `CSI 6n` reply is ambiguous with a modified F3 keypress. Raxol's
   `Raxol.Terminal.InlineDriver.CursorReport` already documents and handles that
   exact collision, so the receiving half exists.

2. **Normalise rather than measure** (hermes-agent, `ensureEmojiPresentation`) —
   *this proposal, §2.4*. Inject VS16 after text-default emoji codepoints before
   rendering, so the glyph is unambiguously two columns instead of a coin-flip.
   Makes width deterministic at the source rather than measuring an ambiguous
   input. Their implementation is applied at a single markdown call site, so it
   is a fix rather than an invariant; done properly it belongs in the sanitize
   boundary.

3. **Consumer-level width invariants** (openclaw, `table.test.ts`) — *partially
   taken*. They assert `visibleWidth(rendered_row) == expected_width` on every
   rendered table row, not only on the measure function. This catches width bugs
   at the component that suffers them. §5.3 already proposes the buffer-width
   form; the component-level form is a cheap addition.

4. **Old implementation as a differential oracle** (grok-build,
   `segment_differential.rs`) — *this proposal, §4*. They embed the previous
   line-splitter verbatim as a test-only reference and assert byte-identical
   output so the rewrite "cannot drift". Their PTY harness additionally parses
   real output with `alacritty_terminal`, checking layout against an actual
   emulator grid rather than a reimplementation of the same rules. Both directly
   validate the Phase 0 differential ledger.

5. **Pin the chrome palette** (grok-build, `glyphs.rs`) — *taken immediately*.
   Every chrome glyph is a function with a documented column count and a
   fallback, with tests asserting both measure identically, and spinner frames
   chosen so "every frame in both sets is exactly 1 column so the trailing label
   never shifts as the icon animates." Inverts the problem: instead of making
   the measurer handle arbitrary input, constrain the chrome to a vetted set and
   make width-stability a test invariant. Especially relevant here because
   Raxol's borders are box-drawing characters, which are East Asian Ambiguous
   and therefore the class most at risk if the §6 policy is ever revisited.

6. **ANSI controls counted against the truncation budget** (openclaw,
   `truncateToVisibleWidth`) — *noted, not scheduled*. They charge
   control characters executing inside a CSI sequence to the visible budget and,
   once the budget is spent, keep emitting zero-width sequences so trailing SGR
   resets and OSC-8 closes still land. Treats width and ANSI-injection safety as
   one budget. Novel framing; no evidence Raxol needs it today.

7. **Emoji-capability gating** (openclaw,
   `stripDecorativeEmojiForTerminal`) — *rejected for now*. Deleting emoji on
   unrecognised terminals is honest but degrades content rather than layout.
   Worth revisiting only if adaptation (item 1) proves impossible.

### 9.4 Open questions this survey raised

**Lone regional indicator: 1 or 2, under streaming?** Raxol currently measures a
lone regional indicator as 1 (a narrow letter tile) and a pair as 2 (a flag),
on Unicode-correctness grounds. `pi-tui` deliberately chooses **2** for the lone
indicator, reasoning that during token streaming a half-arrived flag is a real
intermediate frame, so the width guess should bias toward what the terminal will
actually do rather than toward what the standard says:

> "Regional indicator symbols are often rendered as full-width emoji in
> terminals, even when isolated during streaming. Keep width conservative (2)
> to avoid terminal auto-wrap drift artifacts."

Raxol streams LLM markdown into a character grid via `Harness.MarkdownBody`, so
this is precisely their case, and our current value was chosen without
considering the partial-input frame. This is a live decision, not a settled one.

**Facade adoption audit.** Per §9.2, find any display-width computation that
bypasses `TextMeasure` — particularly `String.length/1` used as a proxy for
columns. Grapheme-index uses (cursor positions into a cell buffer) are correct
and must not be "fixed"; only display-width uses are defects.

### 9.5 Provenance and confidence

This survey was produced by three parallel research agents reading source (not
READMEs — documentation in this area routinely overclaims). Findings are dense
with `file:line` citations and internally consistent, but **were not
independently verified against the upstream repositories.** Before building on
any single claim — the DA1 barrier especially, since it is load-bearing for
item 1 — confirm it against the source directly.
