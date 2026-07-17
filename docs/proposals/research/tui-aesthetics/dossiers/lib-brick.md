# Aesthetic Dossier: brick (Haskell)

> A declarative Haskell TUI toolkit whose whole visual identity is a *governance model*:
> widgets never name colors, they name **roles**; a single central `AttrMap` binds roles
> to looks and resolves them through CSS-like hierarchical inheritance. The house style
> that falls out is unmistakable — Unicode box-drawing panels with centered labels, calm
> aligned whitespace produced by a Fixed/Greedy layout algebra, and interactivity signaled
> by a *color/emphasis shift on focus* rather than motion. It is the terminal equivalent of
> a well-run design system: the look is restrained because the machinery makes restraint
> the path of least resistance.

- **Repo:** https://github.com/jtdaugherty/brick (Haskell, built on [`vty`](https://hackage.haskell.org/package/vty) + `vty-crossplatform`)
- **Docs:** [Hackage](https://hackage.haskell.org/package/brick) · [User Guide `docs/guide.rst`](https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst) · [FAQ](https://github.com/jtdaugherty/brick/blob/master/FAQ.md)
- **Author:** Jonathan Daugherty (`jtdaugherty`). First release ~2015; a mature, still-active library at 2.x.
- **Category:** declarative library / framed-panel house style. Philosophical siblings: Elm (pure `view`), CSS (attribute inheritance), Textual (roles→CSS). Contrast with Go's `tview`/`gocui` (imperative widget trees) and `Lip Gloss` (inline style objects).
- **Clone read for this dossier:** shallow clone; source paths below are all real (`src/Brick/AttrMap.hs`, `src/Brick/Themes.hs`, `src/Brick/Widgets/Border/Style.hs`, `src/Brick/Focus.hs`, `docs/guide.rst`).

---

## 1. The one-sentence identity

Brick's aesthetic is not a palette or a border — it is a **rule**: *"Rather than specifying
specific attributes when drawing a widget (e.g. red-on-black text) we specify an attribute
name … We then provide an attribute map which maps those attribute names to actual
attributes."* (`docs/guide.rst`). Every color decision in a brick app is deferred to one
place. That single indirection is the entire personality. It produces apps that look
**coherent, quiet, and re-skinnable**, because nothing in the drawing code can go rogue and
paint an off-palette color inline — the drawing code literally cannot see colors, only names
like `list <> selected` or `border`.

**Technique → feeling:**
- *Widgets request `AttrName`s, never `Attr`s* → **enforced consistency.** Two lists in two
  corners of the app are the same color because they resolve the same name through the same
  map. Visual drift becomes structurally impossible, the way a constraint system makes wrong
  states unrepresentable.
- *The map is a single `App` field (`appAttrMap`)* → **one throat to choke.** "This lets us
  put the attribute mapping for an entire app, regardless of the internal structure of its
  widgets, in one place" (`docs/guide.rst`). Re-theming is a data edit, not a code edit.

---

## 2. Screen anatomy — describe it in words

The canonical brick screen is the README's own four-line demo, and it is worth reading as a
statement of house style:

```
joinBorders $
withBorderStyle unicode $
borderWithLabel (str "Hello!") $
(center (str "Left") <+> vBorder <+> center (str "Right"))
```

renders to:

```
┌─────────Hello!─────────┐
│           │            │
│           │            │
│   Left    │   Right    │
│           │            │
│           │            │
└───────────┴────────────┘
```

Read what this imprints. A **framed rectangle** in light Unicode box-drawing. A **label
inlaid into the top border** (`Hello!` sits *on* the `─` run, not in a separate title bar).
A **vertical divider that fuses into the frame** — note the `┬` where `vBorder` meets the top
edge and `┴` at the bottom: that is `joinBorders` at work, turning two independent widgets'
edges into one continuous drawn line. Content is **centered inside each cell**. There is no
shadow, no gradient, no color in the default — just line, label, and balanced whitespace.

This is the brick "look" a hundred apps inherit: **orderly labeled panels, hairline Unicode
frames, centered or padded content, dividers that connect instead of colliding.** When you
picture a brick app (`bhoogle`, `tetris`, `matterhorn`, `gitHUD`-style tools) you picture
this grid of joined boxes.

**Technique → feeling:**
- *`borderWithLabel` places the label *in* the top rule* → **captioned, filed, official.**
  The panel announces what it is without spending a row on a header. It reads like a labeled
  drawer.
- *`joinBorders` welds adjacent edges into `┬ ┼ ┤` junctions* → **built, not stacked.** The
  UI looks like one fabricated chassis rather than overlapping paper rectangles. The guide
  explicitly calls out the alternative (a "small gap" where borders meet) as the visual
  oddity to be avoided.

---

## 3. The AttrMap: roles inherit like CSS

The heart of the aesthetic is in `src/Brick/AttrMap.hs`. Attribute names are **hierarchical
and composed with `<>` (monoid append)**:

```haskell
attrName "window" <> attrName "border"
attrName "list"   <> attrName "selected"
attrName "header" <> attrName "clock" <> attrName "seconds"
```

Lookup walks *every prefix* of the name (the source literally uses `Data.List.inits`) from
most-specific to root, **merging partial attributes** so a child inherits any foreground /
background / style it doesn't set:

> "the attribute corresponding to a more specific name (`parent <> child`) is successively
> merged with the parent attribute … all the way to the 'root' of the attribute map, the
> map's default attribute. In this way, more specific attributes inherit what they don't
> specify from more general attributes." — `src/Brick/AttrMap.hs`

The guide draws the analogy explicitly: *"In this way, we can create inheritance
relationships between attributes, much the same way CSS supports inheritance of styles based
on rule specificity."* An attribute has three independently-defaulting channels (fg, bg,
style); anything unspecified falls through to the terminal's own colors via Vty's `defAttr`.

**Technique → feeling:**
- *`list <> selected` inherits `list`'s background, overrides only the fg* → **DRY palettes
  that feel designed.** You set the app's mood once (`attrMap (bg blue) [...]`) and specialize
  by exception. The result is a palette with *family resemblance* — every variant is visibly
  a child of its parent, so the screen feels tonally unified instead of a bag of unrelated
  colors.
- *Unspecified channels fall through to `defAttr` (the user's terminal)* → **belongs to your
  terminal.** A restrained default that sets only what it must lets the app inherit the user's
  own background and foreground. Brick apps look at home in *your* color scheme rather than
  repainting over it — the same "native tenant" feeling lazygit gets from `default` borders,
  but generalized to every element.
- *Third-party widgets ship their *own* attribute names* → **modular theming.** "Provide
  modular attribute behavior for third-party components, where a component may provide an
  attribute name mapping without knowing … the rest of the application's attributes"
  (`docs/guide.rst`). A dropped-in widget re-tints itself through the host's one map. The
  aesthetic contract survives composition.

Escape hatches encode design intent too: `forceAttr` (ignore names, force one look — used for
"this whole subtree is disabled/dimmed"), `withDefAttr` (change the fallback for a subtree),
`overrideAttr` (alias one name to another — "make my widget's `selected` mean the app's
`highlight`"). Each is a way to *bend the system without breaking the single-source rule.*

---

## 4. Themes as a promised contract (`Brick.Themes` + `.ini`)

`src/Brick/Themes.hs` turns the AttrMap from an internal detail into a **user-facing product
surface**. The pattern is a three-step promise:

1. the app ships a built-in default `Theme` (`newTheme (white \`on\` blue) [...]`);
2. it loads user overrides from an INI file at runtime (`loadCustomizations "custom.ini"`);
3. it can save runtime tweaks back out (`saveCustomizations`).

The INI format is deliberately human-legible — two sections, `[default]` and `[other]`,
dotted attribute paths mirroring the `<>` hierarchy:

```ini
[default]
default.fg = blue
default.bg = black

[other]
someAttribute.fg = red
someAttribute.style = underline
otherAttribute.style = [underline, bold]
otherAttribute.inner.fg = white
```

Colors accept the 16 ANSI names, their `bright*` variants, `default`, **or `#RRGGBB` hex**
(the module honestly documents the tradeoff: *"this specification is lossy: terminals can
only display 256 colors, but hex codes can specify 256^3 = 16777216 colors"*). Styles are a
comma-list: `standout, underline, reverseVideo, blink, dim, italic, strikethrough, bold`.
`ThemeDocumentation` lets the app attach human descriptions to each name so a generated theme
file is *self-documenting*.

**Technique → feeling:**
- *Every named role is externally re-tintable at runtime* → **theming as a promise, not a
  fork.** Because the app already routes all color through names, exposing an INI is nearly
  free — and it signals to users "your look is yours." Apps built this way tend to ship a
  *restrained, override-friendly* default precisely because the author knows the palette is a
  starting point, not the final word.
- *Omitted fields inherit the theme default* → **safe, partial customization.** A user edits
  three lines and the rest stays coherent. You can't accidentally break the palette's family
  resemblance because unspecified channels still flow from the parent. The customization
  surface has the *same* inheritance safety as the code-level AttrMap.
- *`saveTheme` / `ThemeDocumentation` emit a commented, human-readable file* → **the theme is
  a document.** The app treats its own look as something worth writing down and handing to the
  user — a curatorial stance that reads as craftsmanship.

---

## 5. Border vocabulary: the framed-panel dialect

`src/Brick/Widgets/Border/Style.hs` is a tiny module that does an outsized amount of the
brand work. A `BorderStyle` is just **eleven characters** — four corners, five intersections,
horizontal, vertical — and brick ships five named sets:

| Style           | Corners        | Line   | Feeling |
| --------------- | -------------- | ------ | ------- |
| `unicode`       | `┌ ┐ ┘ └`      | `─ │`  | **default** — clean, modern, hairline |
| `unicodeBold`   | `┏ ┓ ┛ ┗`      | `━ ┃`  | heavy, emphatic, "this panel matters" |
| `unicodeRounded`| `╭ ╮ ╯ ╰`      | `─ │`  | soft, friendly, contemporary |
| `ascii`         | `+ + + +`      | `- \|` | rugged, universal, retro-safe |
| `borderStyleFromChar c` | all one char | | blocky / stylized novelty frames |

The module's own comments are a statement of values: `unicode` is "a safe bet," and `ascii`
exists *"in addition to the Unicode styles"* because *"your mileage may vary on some of the
fancier styles due to varying support for some border characters in the fonts your users may
be using."* The border module's vocabulary — `border`, `borderWithLabel`, `hBorder`,
`vBorder`, `hBorderWithLabel`, plus the `joinBorders` / `freezeBorders` machinery — is the
compositional grammar of the framed-panel look.

**Technique → feeling:**
- *`unicode` is the default border style* (`defaultBorderStyle = unicode`) → **modern hairline
  as the house baseline.** Every app that doesn't opt out is drawn in the same thin,
  single-line frame. That default is why brick apps share a family face before their authors
  make a single decision.
- *A `BorderStyle` is 11 swappable chars, changed per-subtree via `withBorderStyle`* → **mood
  by frame weight.** Wrapping one panel in `unicodeBold` makes it *shout*; `unicodeRounded`
  makes a dialog feel *soft and non-threatening*; `ascii` throws the whole thing into a
  retro/DOS register. The frame character set is a tone knob.
- *`joinBorders` reports edge info so `─` meeting `│` becomes `┼`/`┬`/`┤`* → **fabricated
  solidity.** Junctions that connect read as engineered; the alternative gap reads as broken.
  `freezeBorders` lets a subtree connect internally but not bleed into neighbors — spatial
  *encapsulation* expressed in line art.
- *`borderWithLabel` truncates the label to the child's width unless you `fill`* → the API
  *nudges* you toward panels sized to their content, reinforcing the tight, tidy look.

---

## 6. Layout algebra: Fixed vs Greedy as whitespace discipline

Brick's calm, aligned feel is a mathematical consequence of one type: `Brick.Types.Size ∈
{Fixed, Greedy}`. Every widget advertises a horizontal and vertical growth policy, and the
`hBox`/`vBox` (`<+>` / `<=>`) algorithm allocates space by rendering the `Fixed` widgets
first and handing the remainder to the `Greedy` ones:

> "the `Fixed` widgets get rendered and their sizes are used to determine how much space is
> left for `Greedy` widgets." — `docs/guide.rst`

`str "Hello"` is `Fixed` (always 1×5). `hCenter` is `Greedy` horizontally (claims the whole
width, then centers within it). `vBorder` is `Greedy` vertically (fills all rows it's given).
The **limiting combinators** `hLimit n` / `vLimit n` convert a `Greedy` widget back into a
`Fixed` box, and the **padding combinators** add controlled whitespace:

```
padLeft · padRight · padTop · padBottom · padLeftRight · padTopBottom · padAll
```

with a two-constructor `Padding = Pad Int | Max` — pad by an exact count, or pad *greedily* to
consume all remaining space (which is how you right-align or bottom-anchor something).

**Technique → feeling:**
- *`Fixed`/`Greedy` growth solved by a deterministic box algorithm* → **calm, never
  crowded.** Alignment isn't hand-tuned pixel math; it *emerges* from declared intent. The
  screen looks composed because the layout engine, not the author, resolves the whitespace —
  and it resolves it the same way every time.
- *`hCenter` / `vCenter` are Greedy and self-centering* → **balanced by default.** Centered
  content in a Greedy cell breathes symmetrically as the terminal resizes. Responsiveness is
  free and it always looks intentional.
- *`Pad Max` for greedy padding, `hLimit`/`vLimit` to cap growth* → **whitespace as a
  first-class material.** You build rhythm by *reserving* space, not by inserting blank
  strings. The interface has air because air is a combinator.
- *Everything is cropped to the available area* ("all widgets are required to render to an
  image no larger than the rendering context specifies … they will be forcibly cropped") →
  **no overflow, ever.** The frame always wins over the content. That guarantee is why brick
  apps never look ragged at odd terminal sizes.

---

## 7. Focus ring: interactivity as a color shift, not motion

`src/Brick/Focus.hs` defines a `FocusRing n` — literally a circular list of resource names
with a current element, rotated by `focusNext`/`focusPrev` (Tab/Shift-Tab). The visually
important piece is `withFocusRing`, whose type *is* the design philosophy:

```haskell
withFocusRing :: (Eq n, Named a n)
              => FocusRing n
              -> (Bool -> a -> b)   -- render fn gets a focused? boolean
              -> a -> b
```

A focus-aware widget (`List`, `Edit`) is handed a **`Bool`: am I focused?** — and it responds
by choosing a *different attribute name* (e.g. `listSelectedAttr` vs
`listSelectedFocusedAttr`, `editAttr` vs `editFocusedAttr`). Which means focus feedback flows
right back through the AttrMap of §3. The library has **no built-in focus animation, glow, or
cursor trail.** Interactivity is communicated by an emphasis/color change resolved from the
theme.

**Technique → feeling:**
- *Focus = a boolean that selects a `*Focused` attribute name* → **quiet, keyboard-native
  personality.** The active widget doesn't move or pulse; it just changes color/emphasis
  (often `standout` or a brighter fg). This is the terminal-native equivalent of a focus ring
  in a GUI — a *state*, rendered as an attribute, not an effect. The whole aesthetic reads as
  "calm, keyboard-driven, no theatrics."
- *Focus feedback routes through the same AttrMap* → **themeable interactivity.** Because
  `listSelectedFocusedAttr` is just another named role, a user's `.ini` can retint what
  "focused" looks like. Even the *feel of interaction* is part of the theming contract.
- *`FocusRing` is a plain rotatable data structure* → **Tab-cycling as the default idiom.**
  The API makes "cycle focus with Tab" the natural way to build multi-widget forms, so brick
  apps converge on the same discoverable, mouse-optional interaction model.

---

## 8. What the API makes easy vs hard (its aesthetic opinion)

A library's defaults *are* its taste. Brick's gradient of ease encodes a house style:

**Easy (therefore common in the wild):**
- Framed, labeled panels (`borderWithLabel` is one call).
- A single coherent palette (the AttrMap makes one-place theming the natural path).
- Centered / padded layouts that resize gracefully (Greedy + `hCenter`).
- User-overridable themes (`Brick.Themes` is batteries-included).
- Tab-driven focus between widgets.

**Hard / discouraged (therefore rare):**
- Per-widget inline colors that drift from the palette — you'd have to fight the name
  indirection to do it.
- Emoji / wide-character decoration. The FAQ is blunt: *"the current recommendation is to
  avoid use of wide characters"* because terminal width calculations disagree. Brick apps
  therefore skew toward **box-drawing and ASCII glyphs over emoji**, giving them a sober,
  engineered texture rather than a playful pictographic one.
- Motion/animation as a core idiom. There's an `AnimationDemo`, but the framework's center of
  gravity is a *pure `appDraw` function* redrawn on state change — the aesthetic is static
  composition, not continuous motion.

The imprint: brick apps look **sober, structured, and terminal-respectful** — closer to a
well-typed config screen than to a demoscene effect. That is a direct shadow of "write a pure
function that describes how your UI should be drawn."

---

## 9. History, lineage, influences

- **Elm / declarative UI.** Brick's core is a pure `appDraw :: s -> [Widget n]` plus an event
  handler — "you write a pure function that describes how your user interface should be
  drawn." The state→view discipline is Elm's, ported to the character grid. This is the deep
  reason the look is so consistent: there is no imperative escape hatch where a stray
  `setColor()` could live.
- **CSS specificity.** The AttrMap inheritance model is explicitly analogized to CSS in the
  guide. Where Lip Gloss borrows *flexbox* terms and Textual borrows *web CSS* wholesale,
  brick borrows CSS's *cascade and specificity* — the idea that a more specific selector
  overrides a general one and inherits the rest.
- **Vty foundation.** Brick sits on `vty` (attribute model, `defAttr`, color types) and
  `vty-crossplatform` (Unix + Windows since 2.0). The three-channel `Attr` (fg/bg/style) with
  terminal-default fallback is inherited straight from Vty and is *why* partial-attribute
  inheritance works at all.
- **Author stance.** Daugherty repeatedly frames brick as *foundational, not maximal*: "Brick
  is not intended to be all things to all people; rather, I want it to provide a good
  foundation for building complex terminal interfaces in a declarative style … all while
  seeing how far we can get with a pure function to specify the interface." The restraint in
  the visual defaults mirrors the restraint in the mission statement.

---

## 10. Community showcase — the vibe in the wild

The README's "Featured Projects" table is a good census of the house style: `bhoogle` (a
Hoogle client), `bollama` (an Ollama TUI), `brewsage` (Homebrew frontend), `Brickudoku`,
`2048Haskell`, `babel-cards` (Anki-like SRS), `cbookview` (chess opening explorer), plus the
big one not in the table, **`matterhorn`** (a Mattermost chat client, also by Daugherty — the
proving ground for much of brick's theming). Across them the family face is consistent:
**joined Unicode panels, a label inlaid in each frame, a restrained ANSI palette that mostly
defers to the user's terminal, a `*Focused` color shift marking the active pane, and Tab/arrow
keyboard navigation.** You can usually recognize a brick app on sight — which is itself the
strongest possible evidence that the AttrMap-plus-border-plus-Fixed/Greedy trio is a genuine
*design system*, not just a widget bag.

---

## 11. Concrete techniques → feelings (index)

| Technique (concrete) | Feeling / vibe |
| --- | --- |
| Widgets name roles (`AttrName`), never colors | enforced consistency; visual drift is unrepresentable |
| Hierarchical names merged via `inits` prefixes | CSS-like family resemblance across the palette |
| Unspecified fg/bg/style fall through to `defAttr` | app belongs to *your* terminal theme; restrained default |
| One `appAttrMap` for the whole app | one-throat-to-choke re-skinning; data edit, not code edit |
| `Brick.Themes` `.ini` with dotted paths + hex/ANSI | theming as a promised contract; override-friendly defaults |
| `unicode` default border style (hairline `┌─┐`) | modern, clean house baseline before any decision |
| `unicodeBold` / `unicodeRounded` / `ascii` swaps | frame-weight as a tone knob (emphatic / soft / retro) |
| `borderWithLabel` inlays label into top rule | captioned, filed, official panels; no wasted header row |
| `joinBorders` → `┬ ┼ ┤` junctions | fabricated one-piece chassis, not stacked paper |
| `Fixed`/`Greedy` box algorithm | calm, self-resolving alignment; never crowded |
| `hCenter`/`vCenter` greedy + centering | symmetric breathing that survives resize |
| `Pad Max`, `hLimit`/`vLimit` | whitespace as a first-class building material |
| Forced crop to available area | no overflow ever; frame always wins, never ragged |
| Focus = `Bool` → `*Focused` attribute name | quiet keyboard-native interactivity, no motion |
| FAQ: "avoid wide characters" | sober box-drawing texture over playful emoji |

---

## 12. Notable quotes (sourced)

- On the core idea: *"Rather than specifying specific attributes when drawing a widget (e.g.
  red-on-black text) we specify an attribute name … We then provide an attribute map which
  maps those attribute names to actual attributes."* — `docs/guide.rst`, *appAttrMap: Managing
  Attributes*.
- On inheritance: *"more specific attributes inherit what they don't specify from more general
  attributes in the same hierarchy … much the same way CSS supports inheritance of styles
  based on rule specificity."* — `docs/guide.rst` / `src/Brick/AttrMap.hs`.
- On single-source theming: *"This lets us put the attribute mapping for an entire app,
  regardless of the internal structure of its widgets, in one place."* — `docs/guide.rst`.
- On border portability: *"Your mileage may vary on some of the fancier styles due to varying
  support for some border characters … Because of this, we provide the `ascii` style … The
  `unicode` style is also a safe bet."* — `src/Brick/Widgets/Border/Style.hs`.
- On layout: *"the `Fixed` widgets get rendered and their sizes are used to determine how much
  space is left for `Greedy` widgets."* — `docs/guide.rst`, *Available Rendering Area*.
- On mission / restraint: *"Brick is not intended to be all things to all people; rather, I
  want it to provide a good foundation for building complex terminal interfaces in a
  declarative style … all while seeing how far we can get with a pure function to specify the
  interface."* — README / project description.
- On wide chars: *"the current recommendation is to avoid use of wide characters."* — `FAQ.md`.

---

## 13. Links

- Repo: https://github.com/jtdaugherty/brick
- User guide: https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst
- Hackage (module docs): https://hackage.haskell.org/package/brick
- `Brick.AttrMap` / `Brick.Themes` / `Brick.Widgets.Border.Style` / `Brick.Focus` source under `src/Brick/`
- Demo gallery: https://github.com/jtdaugherty/brick/tree/master/programs (`AttrDemo`, `BorderDemo`, `ThemeDemo`, `DynamicBorderDemo`, `PaddingDemo`, `FormDemo`, …)
- Vty (foundation): https://hackage.haskell.org/package/vty
- Sibling for contrast: matterhorn (Mattermost TUI) https://github.com/matterhorn-chat/matterhorn
