# Network marks

The chain logos the hero's network row renders, inlined at compile time by
`RaxolPlayground.NetworkMarks` so the page makes no external request for one.

## Where they came from

All seven were taken from the Xochi repo (`src/assets/chains/`), the same
author's solver front end, where they already serve the same purpose: naming
the chains a transfer can route across. They are each chain's own logo, used
to identify that chain. No mark here is modified, recoloured, or presented as
raxol's.

| File            | Chain            | Chain id    | Reached by |
| --------------- | ---------------- | ----------- | ---------- |
| `ethereum.svg`  | Ethereum         | 1           | Xochi      |
| `optimism.svg`  | Optimism         | 10          | Xochi      |
| `polygon.svg`   | Polygon          | 137         | Xochi      |
| `robinhood.svg` | Robinhood Chain  | 4663        | Xochi      |
| `base.svg`      | Base             | 8453        | Xochi      |
| `arbitrum.svg`  | Arbitrum One     | 42161       | Xochi      |
| `tron.svg`      | Tron             | 728126428   | Relay rail |

## Why these are not brand marks

`priv/brand_marks/` holds a different kind of file and answers to a different
contract: one 24x24 path, rendered in `currentColor`, for the integrations
row. A chain logo is several elements in its own viewBox carrying its own
fills, and flattening one to a single monochrome path leaves a shape nobody
recognises. `RaxolPlayground.NetworkMarks` inlines the whole SVG body and
keeps each file's viewBox instead, which is why the two modules stay apart.

## Adding one

Drop the SVG here and add its `{chain id, name, file}` row to `@sources` in
`RaxolPlayground.NetworkMarks`. The file needs a `viewBox` or the build fails,
since the row sizes every mark to one box. A test holds every EVM chain that
carries a token in `Raxol.Payments.Assets` against `@sources`, so a corridor
added without a mark fails rather than rendering a row that quietly omits a
chain the product settles on.
