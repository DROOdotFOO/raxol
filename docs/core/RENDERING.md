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
