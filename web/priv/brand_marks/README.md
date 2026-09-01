# Brand marks

Single-path SVG marks for the integrations row on the landing page. Read at
compile time by `RaxolPlayground.BrandMarks`, which extracts the `d` attribute
and inlines it, so the page makes no external request for them.

## Source

[Simple Icons](https://simpleicons.org) version 16.29.0, fetched unmodified.
The collection is licensed CC0-1.0. The trademarks themselves remain the
property of their owners; they appear here as nominative use, to say what
raxol works with, and imply no endorsement.

Every file is a 24 by 24 viewBox with exactly one `path`. A test holds that
shape, because the renderer inlines the path and nothing else.

## Marks the site wears

`github.svg` is not an integration. It is the repository link in the footer,
reached through `BrandMarks.site_path/1` rather than `path/1` and absent from
`known/0`, because that list answers to the provider registry and a mark for
something that is not a provider would read there as one that outlived its
entry. Same source, same version, same licence as the rest.

## Which entry each mark serves

The row's entries are derived from `Raxol.Agent.Backend.Resolver.providers/0`
and from the ACP client list, so this directory is keyed by the display name
those produce:

| Entry       | File                  | Note                                  |
| ----------- | --------------------- | ------------------------------------- |
| Claude      | `claude.svg`          |                                       |
| Anthropic   | `anthropic.svg`       |                                       |
| Kimi        | `kimi.svg`            |                                       |
| OpenRouter  | `openrouter.svg`      |                                       |
| Proton Lumo | `proton.svg`          | Lumo has no mark of its own; this is Proton's, the vendor's |
| Ollama      | `ollama.svg`          |                                       |
| LM Studio   | `lmstudio.svg`        |                                       |
| Zed         | `zedindustries.svg`   |                                       |
| JetBrains   | `jetbrains.svg`       |                                       |
| neovim      | `neovim.svg`          |                                       |
| Emacs       | `gnuemacs.svg`        |                                       |
| Virtuals Protocol | `virtuals.svg`  | Refitted from the official kit, below |

## The one refitted file

`virtuals.svg` did not come from Simple Icons. Its source is
`Logo Mark White Transparent.svg` out of `Virtuals Protocol Logo SVG.zip`, the
official kit linked from
<https://whitepaper.virtuals.io/info-hub/virtuals-protocol-editorial-style-guide-and-brand-kit>.
Their brand guide says to "always use the logo as provided in the official
brand assets", so the kit is the only acceptable origin: an earlier attempt
refitted a copy sitting in the axol repo and was thrown away.

Two of the kit's variants matter here. **Logo Mark** is the symbol without the
wordmark, which is the only shape a 24-square glyph slot can hold. **White
Transparent** is the monochrome variant, which is what makes this row legal at
all: every mark renders in `currentColor`, and recolouring the full-colour
logo to do that would be an alteration the guide does not sanction. Using the
mono variant means the row shows a form the brand ships, not one derived here.

Checked against the guide's six prohibitions: proportions are not distorted
(the source is square, so the fit is a uniform scale and nothing is stretched
or skewed), and nothing adds an outline, a stroke, a shadow, or a mask. The
row's background clears contrast comfortably.

Three mechanical changes were still needed, because the extractor takes
exactly one path in a `0 0 24 24` viewBox:

- the source carries two paths, the symbol and a detached dot, concatenated
  here into one path with two subpaths
- the fit is to the ARTWORK, not to the canvas. The mark sits on a 512 square
  but occupies only `100.997 156.002 310.288 200.0` of it, so scaling the
  canvas put it on screen at 24% of the area of the Simple Icons marks beside
  it, which reads as a mistake rather than as restraint. Fitting the bounding
  box takes it to 64%, which is where a 1.55:1 mark lands in a square slot;
  more would mean stretching it, and the guide forbids that
- that bounding box was measured with `getBBox` in a browser. Curves make it a
  solver problem, and a number that has to be right is worth measuring rather
  than approximating

The clear space the canvas encoded goes with it, which is a real trade. The
row supplies its own: items are spaced on a flex gap, and the marks are set
against a background with nothing else in the gutter.

`fill-rule="evenodd"` is carried through, and it is load-bearing rather than
tidiness. The mark's inner loop is wound the same way as its outer contour, so
under the `nonzero` default it fills in solid and the logo comes out redrawn.
`BrandMarks.fill_rule/1` exists for this one file, and a test holds it.

The transform is exact rather than eyeballed: the source uses only `M`, `L`,
`C` and their relative forms, so scaling absolute pairs while scaling relative
pairs alone is lossless. An arc would not be, because radii and the x-axis
rotation do not survive a naive coordinate scale, so the refit refuses one
rather than emitting a quietly wrong glyph.

The refit was a throwaway script rather than a committed tool: one file does
not earn a build step, and a second one would be better served by taking a
kit's own square mark unchanged.

## Entries with no mark, deliberately

OpenAI, VS Code, Grok, LongCat, and LLM7 are absent from the Simple Icons set.
Checked against the full 3457 icon index for version 16.29.0, not inferred from
a failed download. Simple Icons removes marks at a trademark holder's request,
so the absence is a decision by the owner rather than a gap to route around.

Nothing is substituted for them. `OpenAI Gym` and `VSCodium` exist in the set
and are different products, so using either would name the wrong thing. Those
five entries render their name instead, which is what every entry did before
this directory existed, and a new backend with no mark does the same rather
than disappearing from the row.
