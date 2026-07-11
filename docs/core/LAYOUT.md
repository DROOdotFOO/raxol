# Flex & Text Layout
-->

This page is the supported-property reference for `:flex` containers and
`Raxol.UI.Components.Display.Text`. It documents what Raxol actually does
today (verified against source), not the CSS spec Raxol approximates.

## 1. Flex properties

A `:flex` container's own properties are read from its `style:` map when
present, falling back to legacy top-level/`attrs` forms. Item properties
(`flex`, `width`, `margin`, ...) are always read from the *child's*
`style:` map (`Raxol.UI.Layout.FlexItem.resolve/5`).

### Container properties

| Property           | Values                                                                 | Where                                                                                     | Notes |
|---------------------|-------------------------------------------------------------------------|---------------------------------------------------------------------------------------------|-------|
| `direction`         | `:row`, `:column` (`:row_reverse`/`:column_reverse` accepted, see divergences) | `attrs.flex_direction`; the `row`/`column` do-block macros set this for you | Default `:row`. NOT read from `style:` -- `Engine.enrich_flex_attrs/1` only translates `style.justify_content`/`align_items`/`gap`/`padding`, not direction. |
| `justify_content`   | `:flex_start`, `:flex_end`, `:center`, `:space_between`, `:space_around`, `:space_evenly` | `style: %{justify_content: ...}` or `attrs.justify_content` | Default `:flex_start`. All variants distribute leftover space via exact integer splits (largest-remainder / Bresenham) -- spacing always sums exactly to the free space, no cells lost to `div/2` truncation. |
| `align_items`       | `:flex_start`, `:flex_end`, `:center`, `:stretch`                       | `style: %{align_items: ...}` or `attrs.align_items`                                        | Default `:stretch`. No `:baseline` (see divergences). |
| `align_self`        | same values as `align_items`, or `nil` (inherit)                        | child's `style: %{align_self: ...}`, or legacy `child.attrs.align_self`                     | Overrides the container's `align_items` for one child. |
| `align_content`     | `:flex_start`, `:flex_end`, `:center`, `:space_between`, `:space_around` | `attrs.align_content` only                                                                  | No `style:` translation exists for this key; set it directly in `attrs` if you're not going through the `row`/`column`/`flex` builders. Only matters when wrapping (`flex_wrap: :wrap`). |
| `flex_wrap`         | `:nowrap`, `:wrap` (anything non-`:nowrap` multi-lines)                 | `attrs.flex_wrap` only                                                                      | Default `:nowrap`. `:wrap_reverse` is accepted as a value but is not distinguished from `:wrap` -- lines are not reversed. |
| `gap`                | integer, or `%{row: r, column: c}`                                      | `style: %{gap: ...}` or `attrs.gap`                                                         | Default `0`. Subtracted from the container's main-axis size before flexible-length resolution runs, and included in `MinContent` row aggregation (`sum(child min) + gap * (n - 1)`). |
| `padding`            | integer, `{v, h}`, `{t, r, b, l}`, or `%{top:, right:, bottom:, left:}` | `style: %{padding: ...}` or `attrs.padding`                                                 | Parsed by `Raxol.UI.Layout.LayoutUtils.parse_padding/1`. Applied to the container's space before children are measured or laid out; `:prepared_cache` and other extra space keys are preserved through the padding step (previously dropped silently, forcing every flex child to measure uncached). |

### Item (child) properties

| Property                      | Values                                                                 | Where (child's `style:` map)          | Notes |
|--------------------------------|---------------------------------------------------------------------------|------------------------------------------|-------|
| `flex`                        | integer `n`; `{grow, shrink, basis}`; `%{grow:, shrink:, basis:}`         | `style: %{flex: ...}`                    | Integer shorthand `flex: n` expands to `grow: n, shrink: 1, basis: 0` **and** `min_main: 0` (terminal-pragmatic sugar, D2 -- see divergences). Tuple/map forms set grow/shrink/basis only, no min override. Legacy `child.attrs.flex` (map form) is honored at lowest precedence for back-compat. |
| `flex_grow`                   | non-negative integer                                                     | `style: %{flex_grow: ...}`               | Default `0`. Ignored if `flex:` shorthand is also set. |
| `flex_shrink`                 | non-negative integer                                                     | `style: %{flex_shrink: ...}`             | Default `1`. |
| `flex_basis`                  | non-negative integer, `{:pct, n}`, or `:auto`                            | `style: %{flex_basis: ...}`              | Default `:auto` -- resolves to the content main size (measured), or the explicit `width`/`height` when set. |
| `width` / `height`            | non-negative integer, `{:pct, n}`, or `:auto`/unset                      | `style: %{width: ...}` (or top-level `child.width`) | Explicit main-axis size wins over an `:auto` basis. On the cross axis it sets `cross_size` and disables the stretch guard (see below). |
| `min_width` / `min_height`    | non-negative integer, `{:pct, n}`, or `:auto`/unset                      | `style: %{min_width: ...}`               | Explicit value always wins over the `flex: n` sugar's `min_main: 0` override. Unset (`:auto`) falls back to the automatic minimum size (Section 3). |
| `max_width` / `max_height`    | non-negative integer, `{:pct, n}`, or `:auto`/unset                      | `style: %{max_width: ...}`               | `:auto`/unset means unbounded (`:infinity`). |
| `{:pct, n}`                   | any dimension/margin field above                                         | (tuple value, not a separate key)        | Resolves against the container's *definite* dimension only. Against an indefinite (`nil`) dimension it behaves as `:auto` per spec, EXCEPT margin percentages, which always resolve against the container **width** regardless of which side or axis. |
| `margin`                      | integer; `{h, v}`; `{t, r, b, l}`; `:auto` (whole value or per-side)      | `style: %{margin: ...}`                  | Sides may independently be `:auto`. `:auto` counts as `0` during sizing; main-axis auto margins absorb positive free space before `justify_content` runs; cross-axis auto margins center (both sides) or push (one side) and disable stretch. |
| `align_self`                  | see container `align_items`                                              | `style: %{align_self: ...}`              | See container table row above. |

## 2. Intentional CSS divergences

These are deliberate, not bugs -- Raxol targets a monospace cell grid, not
a pixel box model, and some CSS corners aren't worth the complexity on a
terminal. Source: `Raxol.UI.Layout.FlexItem` moduledoc (decisions D2, D6,
D7, D8).

| CSS behavior | Raxol behavior | Why |
|---|---|---|
| `flex: 1` keeps each item's own `min-width`/`min-height: auto` (min-content) floor, so equal-`flex:1` columns don't always equalize if content differs. | `flex: n` sugar also sets `min_main: 0`, so equal-`flex` items *always* equalize -- an explicit `min_width`/`min_height` in `style:` still overrides the sugar. | Terminal-pragmatic (D2): equal columns that actually equalize is the common case terminal UIs want; the CSS min-content floor is opt-in via an explicit min. |
| `row-reverse` / `column-reverse` reverse visual order and flip the start/end edges for `justify-content`. | `:row_reverse`/`:column_reverse` are accepted as `flex_direction` values but map to the *same* axis pair as `:row`/`:column` (`get_axes/1`) -- no actual reversal of child order or edges happens. | Not implemented. Documented divergence -- do not rely on reverse directions; they silently behave like the non-reversed direction. |
| `align-items: baseline` aligns items along their text baseline. | Not implemented. `Positioner.align_cross/4` has no `:baseline` clause; passing it falls through to a no-op catch-all (the child keeps whatever cross position it already had, effectively broken, not "close enough"). | No font metrics/baseline concept on a monospace cell grid worth the complexity. Use `:center` or `:flex_start` instead. |
| The fractional-flex-factor rule: if `sum(flex-grow) < 1`, only that fraction of free space is distributed, the rest stays unfilled. | Not implemented -- grow/shrink factors are non-negative integers, so a fractional sum can't occur; all free space is always distributed among items with non-zero factors. | Documented as N/A rather than a gap: the precondition (fractional factors) can't arise given the integer-only factor type. |
| Percentages parse from CSS-like strings (`"50%"`) or numbers with a unit. | Only the `{:pct, n}` tuple is accepted; no string parsing. | D7 -- one unambiguous representation, no parser/locale edge cases. |
| Margin percentages resolve against the *containing block's inline-axis size* per side semantics some engines special-case. | Margin percentages always resolve against the container's **width**, for all four sides, matching the CSS spec's actual (if surprising) rule. | Explicitly called out in `FlexItem` moduledoc because it trips people up even in browsers -- Raxol matches spec here rather than "fixing" it. |
| Pixel box model: fractional/subpixel sizes, box-sizing modes. | Everything is whole cells; sizes are non-negative integers (or `{:pct, n}` rounded to a whole cell). No box-sizing switch -- padding/border/margin math is always "content-box"-shaped in cells. | No subpixel concept on a terminal grid. |
| Invalid CSS values are ignored (the property falls back to its previous/initial value, per CSS's error-handling rule). | Invalid values (negative sizes, negative flex factors, malformed percentages/margins) are clamped to the nearest valid value (usually `0`) and reported via the `[:raxol, :layout, :invalid_style]` telemetry event. Layout never raises on style input. | D8 -- fail-soft with observability instead of silent CSS-style ignoring; a clamp is easier to spot in a telemetry dashboard than a silently-dropped property. |
| Overflow (`sum(min-size) > container`) is handled per `overflow` property (default `visible`, content spills out / overlaps). | Content clips at the container's main-end edge; siblings never overlap. Pairs with the text-overflow affordances in Section 4 so clipping degrades gracefully instead of silently truncating mid-glyph. | D6. |

## 3. Automatic minimum size

CSS's `min-width: auto` / `min-height: auto` default (an item never
shrinks below its own minimum content size) is implemented via
`Raxol.UI.Layout.MinContent`, wired into `FlexItem.resolve/5` as the
`auto_min_fun` callback (`Flexbox.calculate_single_line_layout/5`):

- **Inline axis** (main axis is `:horizontal`, i.e. `flex_direction: :row`):
  the automatic minimum is `MinContent.width/1` -- the width of the
  *longest unbreakable segment*, not the full content width. Text and
  labels break at spaces, after hyphens, and between CJK ideographs (each
  CJK grapheme is its own break opportunity), so a long sentence's
  min-content is just its longest word, not the whole sentence. A
  `:divider` has min-content `1` (not the available width -- this was bug
  class L6: a full-width divider used to inflate the measured container
  width and rob fixed-width siblings during shrink). A `:spacer` has
  min-content `0`.
- **Block axis** (main axis is `:vertical`, i.e. `flex_direction: :column`):
  the automatic minimum is the item's already-measured content size on
  that axis (no separate min-content pass -- vertical wrapping isn't
  modeled, so "min content height" and "content height" coincide).
- Items **never shrink below** their automatic minimum; if the sum of
  minimums exceeds the container, the excess overflows per the D6 clip
  rule (Section 2) rather than content vanishing or items overlapping.
- An **explicit `min_width`/`min_height`** in `style:` always overrides the
  automatic minimum (and overrides the `flex: n` sugar's `min_main: 0`,
  per `FlexItem.resolve/5`'s `{explicit_min, flex.min_main_override}`
  precedence).
- **`flex: n`** (the integer shorthand) opts out of the automatic minimum
  entirely by setting `min_main: 0` directly (D2) -- use `flex: {n, s, b}`
  or explicit `flex_grow`/`flex_shrink`/`flex_basis` keys if you want the
  automatic-minimum floor to still apply.

## 4. Text layout

`Raxol.UI.TextLayout` is the canonical wrapping entry point, unifying
code that used to be scattered across `Input.TextWrapping` and ad-hoc
Component logic. `Raxol.UI.Components.Display.Text` exposes it via props.

### `white_space` (CSS Text Module Level 3)

| Value       | Newlines  | Space/tab collapsing | Wraps at width? |
|-------------|-----------|-----------------------|------------------|
| `:normal`   | collapse  | collapse              | yes |
| `:nowrap`   | collapse  | collapse              | no |
| `:pre`      | preserve  | preserve              | no |
| `:pre_wrap` | preserve  | preserve              | yes |
| `:pre_line` | preserve  | collapse              | yes |

`:normal` is the default and is deliberately bit-identical to the
pre-existing greedy word-wrap (including its non-CJK-safe character-count
line-fit check), matching existing production output exactly. The other
four modes are new, CJK-width-safe code paths
via `Raxol.UI.TextMeasure`. A single grapheme wider than `width` is never
split mid-grapheme; it's emitted alone on its own line even if it exceeds
`width`.

```elixir
alias Raxol.UI.Components.Display.Text

# Preserve blank lines and leading indentation (like <pre>), but still wrap
# long lines to the container width.
Text.init(content: "  def foo do\n\n  end", white_space: :pre_wrap, width: 20)
```

### `text_overflow: :ellipsis` (single-line truncation)

Only takes effect when `white_space` is `:nowrap` or `:pre` (the two
non-wrapping cases); at any other combination it's a no-op. Never splits
a double-width grapheme -- the cut lands one column early instead.

```elixir
Text.init(
  content: "a very long single line that must not wrap",
  white_space: :nowrap,
  text_overflow: :ellipsis,
  width: 12
)
# => "a very lo…"
```

### `line_clamp` (CSS Overflow Module Level 4)

Caps wrapped output at `max_lines`, appending a block-ellipsis (`…`) to
the last kept line only if something was actually cut. Overrides the
legacy `wrap`/`truncate` props entirely when set; `white_space` still
selects the wrapping mode underneath it.

```elixir
Text.init(
  content: "Raxol is a multi-surface application runtime for Elixir built on OTP.",
  width: 20,
  line_clamp: 2
)
# => ["Raxol is a", "multi-surface Raxol…"]  (illustrative; exact break
#     points depend on TextMeasure/greedy wrap)
```

### `text_wrap: :pretty` (Knuth-Plass, `Raxol.UI.TextLayout.Pretty`)

`:auto` (default) is the existing greedy wrapper. `:pretty` runs a
Knuth-Plass-style dynamic program that minimizes total raggedness
(`sum(abs(width - line_width) ** 2)`) plus an orphan penalty for a
paragraph's last line containing a single word -- avoiding the ugly
"one long word alone on the last line" greedy artifact. Break
opportunities: whitespace runs, after a hyphen, and between CJK
ideographs. Only applies when `white_space: :normal` (the only mode with
freely chosen break points); other modes ignore it. `:pretty` never
produces more lines than `:auto` for the same input.

```elixir
Text.init(
  content: "the quick brown fox jumps over the lazy dog",
  width: 15,
  text_wrap: :pretty
)
```

## 5. Changes from the previous implementation

The previous `:flex` implementation silently diverged from its own stated
behavior in several places, now corrected:

- **Default shrink now actually works.** The previous single-pass
  distribution lost free space to integer `div/2` truncation; the new
  `Flexbox.Solver` uses largest-remainder apportionment so every
  round distributes cells exactly, with no silent loss.
- **Explicit box `width`/`height` on a flex child is honored** as the
  main-axis size input (via `FlexItem.resolve/5`'s `explicit_main`),
  instead of being overridden by content measurement.
- **Padding tuples are honored end-to-end**, including through the
  `apply_padding` step that previously dropped `:prepared_cache` (and any
  other extra space keys) -- flex children now measure with cache intact
  instead of falling back to an uncached path on every render.
- **`gap` is included in main-axis measurement**: the container's usable
  main size is `container_main - total_gaps` before flexible-length
  resolution runs, and `MinContent`'s row aggregation adds
  `gap * (n - 1)` to the summed child minimums -- gap no longer causes
  under- or over-fitting against the container.

## See also

- `docs/core/ARCHITECTURE.md` -- where layout sits in the render pipeline.
