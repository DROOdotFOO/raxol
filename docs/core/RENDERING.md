# Rendering: how paint works, and the rules that keep it honest

The *why* lives in [ADR-0029: The Terminal Cell Model](../adr/0029-the-terminal-cell-model.md).
This is the working reference: what to do, what not to do, and the traps that
have actually bitten us.

---

## The model in one paragraph

A terminal is a grid of cells. A cell is `{x, y, grapheme, fg, bg, attrs}` — one
grapheme, one foreground, one background. No alpha. No sub-cell positioning. No
layers. The renderer turns positioned elements into cells, composes them into a
`ScreenBuffer`, and emits one SGR-styled run per contiguous same-style span,
each terminated with `\e[0m`.

---

## The five rules

### 1. A background is optional. A foreground is not.

Text needs a colour, so a foreground falls back to the theme. A background does
not fall back to anything.

```elixir
text(content: "hi", fg: :red)     # fg :red, bg unpainted
box(border: :single)              # fully transparent, border included
box(border: :single, bg: :blue)   # a blue panel
```

### 2. Unpainted (`nil`) means *show what is beneath* — never "black", never "erase"

```elixir
bg: nil      # transparent: the parent's fill, or the terminal
bg: :black   # an actual, opaque black
```

Over a filled parent, an unpainted cell inherits the parent's fill. At the top of
the tree there is nothing beneath, so the terminal shows through. Both come from
the same rule; you do not need to special-case "transparent" widgets.

> **Never** default an unpainted background to `:black`. It renders `\e[40m` — an
> opaque black cell. It looks correct on a black terminal and punches a hole
> through a transparent one.

### 3. Never paint a background equal to the terminal's own

A cell is transparent *precisely because* we emitted no background for it. So
painting the terminal's own colour is not a no-op — it is the destruction of
transparency, disguised as a no-op.

This includes the theme's `background`, which is only an *assumption* about the
terminal's. **Themes colour content** (fg, accents, borders); the terminal owns
the canvas. If an app genuinely wants a different canvas, it sets a background
explicitly.

To adapt to the real background rather than assume it, use
`Raxol.UI.CellDim` — it detects the ground via OSC 11 and solves colours against
it.

**If you want an opaque panel, ask for `:surface`, not `:background`.** They are
different colours doing different jobs:

```elixir
Theme.get_color(theme, :background)  # what we ASSUME the terminal is -- never paint this
Theme.get_color(theme, :surface)     # a raised opaque thing -- painted on purpose
```

A modal is opaque by design: it sits over dimmed content that must not read
through it. It gets that opacity from `:surface`. Reaching for `:background`
looks identical on a default terminal and is wrong everywhere else.

### 4. A box's background fills the whole box, border included

```elixir
box(border: :single, bg: :blue)                            # blue panel, border on the fill
box(border: :single, bg: :blue, border_bg: :red)           # red frame around a blue panel
box(border: :single, bg: :blue,
    background_clip: :padding_box)                         # fill inset; outline sits on what's behind
```

A cell cannot be half-painted, so the border glyph's cell is either inside the
background or outside it. `:border_box` (the default) puts it inside: **a frame
is the panel's edge, not a thing floating beside it.** Leaving it unpainted cuts
a one-cell channel around the box through which the backdrop shows — a seam no
choice of colours can fix.

### 5. The frame owns its geometry — don't hand-roll escape codes

Row joins are `\r\n` (raw output does not cook a bare `\n`), autowrap is disabled
(`\e[?7l`), and every run is `\e[0m`-terminated. If you are writing escape codes
by hand in a component, you are almost certainly in the wrong layer.

> **Never** embed raw ANSI in a string passed to `text/1` or the View DSL. Use
> `text("hi", fg: :cyan, style: [:bold])`, never `text("\e[36mhi\e[0m")`.

---

## Where to put things

| You want | Set it on |
|---|---|
| a colour for text | `fg:` |
| a filled panel | `bg:` on a `box` |
| an *opaque* panel, colour from the theme | `bg:` ← `Theme.get_color(theme, :surface)` |
| a differently-coloured frame | `border_bg:` |
| the frame to *not* be part of the fill | `background_clip: :padding_box` |
| a colour that adapts to the user's terminal | `Raxol.UI.CellDim` / the H-K palette |
| the terminal's canvas to change | nothing — it isn't yours (`:background` is an assumption, not a paint) |

---

## How a frame reaches the terminal

The renderer diffs the grid and emits every frame — keyframe or diff — in one
absolute-CUP vocabulary. `Raxol.Core.Runtime.Rendering.Backends.build_terminal_frame/5`
holds the whole decision:

- The previous frame is already in hand as `state.buffer`, so the grid is its
  own diff basis. `keyframe?/3` is true on the first frame, on a `force_repaint`
  (resume, resize), or when the dimensions change; otherwise the frame is a
  diff.
- A keyframe is a leading `\e[2J` followed by every row. A diff is only the rows
  whose cells changed — `changed_rows/2` compares `prev.cells` against
  `next.cells` row by row.
- Either kind emits each row at its absolute position: `\e[y;1H\e[0m\e[2K` then
  the row's bytes. There are no `\r\n` row-joins and no full-screen clear on the
  common path.

This is only safe because a row is a pure function of its own cells.
`Raxol.Terminal.Renderer.render_row/2` carries no pen state from the row above —
every run is `\e[0m`-terminated — so a row re-emitted in isolation is
byte-identical to its slice of the full frame, and a diff never has to reason
about what the row above left on the pen.

Two consequences worth knowing:

- A control byte or a standalone zero-width character in a cell is blanked at
  the write boundary (`Backends.sanitize_char/1`). Under incremental rendering
  nothing repaints a corrupted row, so an in-cell `\e`/`\n`/`\t` — which would
  bleed onto the next row — must be made unrepresentable downstream. (A ZWJ
  *inside* an emoji cluster is load-bearing and never reaches here alone, since
  cells hold whole grapheme clusters.)
- Style batching is on for this path (`Raxol.Terminal.Renderer.new/4` with
  batching `true`): adjacent same-style cells merge into one SGR run,
  round-trip-identical (each run still `\e[0m`-terminated) and far fewer bytes
  on a styled UI.

A view may declare a cursor park at the root of its element tree
(`Backends.declared_cursor/1`). When one is present, every frame kind ends with
the park tail — DECTCEM show/hide plus an absolute CUP — because the emitted
rows moved the physical cursor and nothing else puts it back.

---

## Region prominence

Intent colors resolve to literals exactly once, at the render choke point:
`Raxol.UI.ColorResolver` is the single whole-list pass that turns
`Raxol.UI.ColorIntent` structs into concrete colors "as close to the terminal
writer as this codebase gets". Focus-driven region dimming rides that same pass.

- **The policy is pure.** `Raxol.UI.RegionPolicy.region_prominence/4` takes the
  region paths present this frame, the focused path, and any mounted dimming
  overlays, and returns `%{region_path => float}`. The focused region's whole
  lineage — itself, its ancestors, and its descendants — stays at `1.0`, so a
  focused input never dims its own panel; a peer region drops one ladder step
  (`0.8`); each overlay multiplies everything outside its own subtree by `0.45`;
  the product is floored at `0.4`, below which a region reads as a broken
  terminal. With `focus: nil` and no overlays every region resolves to `1.0`, so
  an app that never focuses a region and never opens an overlay renders
  byte-identically to pre-region code.
- **The engine wires it in.** `Raxol.UI.Layout.Engine.stamp_region_prominence/2`
  stamps the resolved float on every positioned element — threading
  `:focused_region` from the render context — as a transient marker the
  `ColorResolver` reads and then strips. It is never a real cell attribute.
- **The fade is closed-form.** Both foreground and background fade apparent
  lightness toward the terminal ground and scale chroma by `p ** @region_gamma`,
  where `@region_gamma = ln(0.65) / ln(0.45)`. That exponent is the exact solve
  that reproduces the existing modal-dim look through the unified formula — the
  modal dialog dim is just the `focus: nil`, single-overlay case of the general
  policy.

This is the same discipline as rule 3 above: prominence is granted by a solver
against the user's real ground, never hand-set in a component.

---

## Traps that have actually bitten us

Each of these shipped. Each was invisible on an opaque black terminal with the
default theme.

**`gap` is not read from `style`.** A literal `:row`/`:column` runs through the
Containers compat map, which reads `gap` from `:attrs` or the **top level** —
never from `:style` — and otherwise defaults it to **1** in layout mode.

```elixir
%{type: :column, style: %{gap: 0}, children: ...}   # ignored -> gap 1, double-spaced
%{type: :column, gap: 0, children: ...}             # correct
```

**An unknown border variant renders as a space.** `BorderRenderer`'s catch-all
maps anything unrecognised to `:none`, whose horizontal run is `" "`. So
`variant: :heavy` (a style that does not exist) renders an *invisible* divider
rather than failing. Resolve unknown variants to a visible default.

**Only `:box` is addressable.** `:flex`/`:row`/`:column` dissolve into their
children's positions and never become positioned elements — they cannot carry an
id, bound their own height, or clip their content. A component that must be
addressable (identity, bounds, clipping, CSS keying, an a11y role) has to render
as a `:box`. See [LAYOUT.md](LAYOUT.md).

**Cells do not composite.** Writing a cell replaces what was there. This is why
rule 2 exists; if you add a new composition point, it must inherit an unpainted
background rather than write `nil` over a fill.

**Stacking two boxes to fake opacity is a workaround, not a design.** The modal
used to render an unbordered fill box behind an identical bordered box, because a
border only paints its own ring and the interior would otherwise show the dimmed
content beneath. Once a box fills its interior (rule 4) the outer box is dead
weight, and a doubled footprint in the layout. If you find yourself relying on
paint order between two elements of the same size, the layer below you is missing
something.

---

## The question to ask

Every bug above passed review, passed tests, and looked right — because it was
tested on the configuration that hides it.

So the review question is not *"does this look right?"* It is:

> **What is this value's one job, and what happens when the user's terminal is
> not mine?**

Every one of these bugs was **one name doing two jobs** — `:black` meaning both
*unpainted* and *black*; `nil` meaning both *transparent* and *erase*; a box's
`bg` meaning both *fill* and *border paint*. The fix was always to split the
meanings apart and make the wrong one unrepresentable.
