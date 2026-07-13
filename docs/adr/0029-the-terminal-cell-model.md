# ADR-0029: The Terminal Cell Model

## Status

Accepted

## Context

A terminal is not a canvas. It is a grid of cells, and a cell holds exactly one
grapheme, one foreground colour, one background colour, and a few attributes.
That is the entire vocabulary. There is no alpha channel, no sub-cell
positioning, no layers, and no compositing step.

Almost every rendering bug this project has shipped came from reasoning as if the
terminal *were* a canvas, and every one of them shared a signature:

> **They were invisible on the default configuration.**

An opaque black terminal running the default theme hides a remarkable number of
mistakes. Painting an opaque black background where you meant "leave it alone"
looks *exactly* correct — until somebody turns on transparency. Draw a
background around a box's border instead of inside it and, on a dark theme, the
result is plausible. The bugs only surface when a user changes something the
author never varied.

The concrete cases, all real:

| What we did | Why it looked fine | What it actually was |
|---|---|---|
| Defaulted an unpainted background to `:black` | black on black | every "unpainted" cell painted `\e[40m`; opaque rectangles on a transparent terminal |
| Painted the theme's background (= the terminal's own) on every cell | identical output | destroyed transparency, overrode the user's terminal |
| A box's background painted the border ring, never the interior | dark outline on a dark theme | `box(bg: :blue)` drew a blue *outline* around a hollow middle |
| An unpainted cell overwrote the cell beneath it | nothing beneath, usually | a button drawn on a modal **erased** the modal and showed the desktop through itself |
| Joined frame rows with a bare `\n` | the shell used to cook it into CRLF | in raw output mode every row drifted a column right |

None of these are exotic. They are what happens when the cell model is treated as
an implementation detail instead of the thing the whole renderer is built on.

## Decision

Five invariants. Everything in the paint path follows from them.

### 1. The cell is the atom of paint

You cannot paint half a cell. This is not a limitation to work around; it is a
fact to design against.

Its sharpest consequence is that a **border glyph occupies a whole cell**, so a
background cannot stop halfway through it. The border cell is either inside the
background or outside it — which is a genuine choice, and CSS already named it:

- `background_clip: :border_box` **(default)** — the background extends under the
  border. A box that declares a background is a filled panel, and its frame is
  that panel's edge.
- `background_clip: :padding_box` — the background stops at the border's inner
  edge, so the fill is inset and the outline sits on whatever is behind it.

`:border_box` is the default because the alternative cuts a one-cell channel
around the box's own frame, through which the backdrop shows. No choice of
colours fixes that; the more the box and the backdrop differ, the worse it looks.

### 2. Transparency is an absence, not a value

There is no alpha. A cell is transparent **precisely when we emit no background
SGR for it**. Transparency is therefore not something you set — it is something
you *refrain from doing*.

It follows that **you must never paint a background equal to the terminal's own**.
On an opaque terminal it is a no-op; on a transparent one it is an opaque
rectangle. This is exactly why the bug survived: the failure is invisible in the
configuration its author was running.

The theme's `background` is an *assumption* about the terminal's background.
Painting it is the same mistake one layer up.

### 3. "Unpainted" means *show what is beneath*

Cells do not composite. Writing a cell **replaces** what was there. So an
unpainted background cannot simply be written, or it will *erase* the background
already at that coordinate — punching a hole through a filled parent.

An unpainted background therefore **inherits the background already at that
coordinate**. One rule; both cases fall out of it:

- over a filled parent → the parent's fill (a button on a modal stays on the modal)
- at the top of the tree → nothing beneath → still unpainted → the terminal shows through

Enforced at both composition points: `CellManager.merge_cells/2` and the
cells-to-buffer write. A painted background still overrides, as always.

### 4. The terminal owns the canvas; the application colours the content

The user chose their terminal's background. We adapt to it rather than replace
it. This is already the premise of the H-K colour work: `Raxol.UI.CellDim`
detects the real ground via **OSC 11** and *solves* colours against it.

So: **themes colour content** — foreground, accents, borders. They do not paint
the canvas. Foreground keeps a theme fallback (text needs a colour); background
does not (a background is optional). An application that genuinely wants a
different canvas sets a background explicitly, and that still paints.

That forces a distinction the theme did not previously make, between a canvas we
only *assume* and a surface we deliberately *paint*:

| theme colour  | what it is                                        | painted? |
| ------------- | ------------------------------------------------- | -------- |
| `:background` | this theme's assumption about the terminal's own canvas | **no**   |
| `:surface`    | a raised opaque thing — a dialog, a panel          | **yes**  |

A modal needs to be opaque: it sits above dimmed content and that content must not
read through it. But it cannot get its opacity from `:background`, because
`:background` is precisely the colour we have decided never to paint. It needs a
colour whose *job* is to be painted. Hence `:surface`.

Opaque is right; the literal is not. A component that wants a solid panel asks the
theme for `:surface` — not for `:background`, and not for a hard-coded `:black`.

### 5. The frame owns its own geometry

The driver runs `prim_tty` with raw output, so nothing cooks the frame's bytes on
our behalf:

- Rows are joined with `\r\n`, never a bare `\n`. In raw mode a lone LF advances
  the line without returning to column 0, so every row after the first drifts one
  column right.
- **DECAWM (autowrap) is disabled** (`\e[?7l`). With autowrap on, the last cell of
  a full-width row advances the cursor by itself and the row separator advances
  it *again* — every content row costs two physical lines, halving the visible
  frame.
- Each styled run is terminated with `\e[0m`. This is what makes invariant 2 safe:
  emitting no background code cannot leak the previous run's background.

## Consequences

**Positive.** Transparent terminals work. Themes compose with the user's terminal
instead of fighting it. A modal is a solid panel sitting on the desktop, and the
widgets inside it sit on the modal. The rules are few and they compose.

**Negative.** Contributors must internalise that *unpainted is not black*, and
that a background is optional in a way a foreground is not. The compositing rule
(invariant 3) means cell writes are no longer a pure overwrite, which is a small
cost in the hot path.

**Related.** The layout counterpart to this ADR is that **only `:box` produces a
positioned element** — `:flex`/`:row`/`:column` dissolve into their children's
positions. Anything that must be addressable (identity, bounds, clipping, CSS
keying, an accessibility role) has to be a box. See `docs/core/LAYOUT.md`.

## The failure mode this ADR exists to prevent

Every bug above is an instance of one pattern:

> **One name doing two jobs.**

- `:black` meant *unpainted* **and** *black*
- `nil` meant *transparent* **and** *erase what's beneath*
- a box's `bg` meant *fill* **and** *border paint*
- `gap` was read from `attrs` **and** the top level — but not from `style`, where
  people naturally put it
- a border `variant` was *a known style* **and** *silently invisible* (an
  unrecognised value fell through to `:none`, whose horizontal run is a space)
- the theme's `:background` meant *the canvas we assume* **and** *the colour a
  panel paints itself with* — which is why a modal reached for it, and why
  invariant 4 could not hold until `:surface` split them

In each case the two meanings were indistinguishable by the time they reached the
renderer, and the wrong one was *silently* wrong. The fix was always the same
move: **split the meanings apart, and make the wrong one unrepresentable.**

The last entry in that list was found *in review of this ADR*, by someone reading
the invariants against the code they were supposed to describe. That is the
intended use.

When adding to the paint path, the question to ask is not "does this look right?"
— on the default configuration it will. The question is: **what is this value's
one job, and what happens when the user's terminal is not mine?**
