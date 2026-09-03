# Network marks

The chain logos the hero's network row renders, inlined at compile time by
`RaxolPlayground.NetworkMarks` so the page makes no external request for one.

## Where they came from

Seven of the eight were taken from the Xochi repo (`src/assets/chains/`), the
same author's solver front end, where they already serve the same purpose:
naming the chains a transfer can route across. `arc.svg` came from Circle's
own brand kit instead, for reasons the section below records. They are each
chain's own logo, used to identify that chain. No mark here is modified,
recoloured, or presented as raxol's.

| File            | Chain            | Chain id    | Reached by |
| --------------- | ---------------- | ----------- | ---------- |
| `ethereum.svg`  | Ethereum         | 1           | Xochi      |
| `optimism.svg`  | Optimism         | 10          | Xochi      |
| `polygon.svg`   | Polygon          | 137         | Xochi      |
| `robinhood.svg` | Robinhood Chain  | 4663        | Xochi      |
| `arc.svg`       | Arc              | 5042002     | Not yet    |
| `base.svg`      | Base             | 8453        | Xochi      |
| `arbitrum.svg`  | Arbitrum One     | 42161       | Xochi      |
| `tron.svg`      | Tron             | 728126428   | Relay rail |

## Arc, whose terms are stricter than the rest

`arc.svg` is byte-for-byte Circle's `Arc Network Icon/Arc_network.svg`, out of
`Arc_Logos.zip` in the Circle brand kit (<https://www.circle.com/pressroom>).
It is copied, not refitted: the Arc partner toolkit says not to "recreate or
approximate the logo", so the only acceptable file is the one Circle ships.

Circle publishes two disc icons and they are not interchangeable. The navy
disc with the white arch is the NETWORK mark, and the guidelines say it
"should not be used to reference the ARC token"; the yellow disc with the
navy arch is the token mark, carrying the mirrored restriction. This row
names chains, so the network mark is the correct one and the token mark
would be wrong here even though it is the more recognisable of the two.

Two conditions ride on it that no other file here carries:

- **Eligibility.** "Only use the Arc logo if you are actively building on Arc
  or have a signed partnership agreement with Circle." The venue settles on
  Arc testnet today, which is the predicate this entry rests on. If that ever
  stops being true, this row is the thing to revisit.
- **No alteration.** The logo guidelines (V1.0, 08.12.25) prohibit rotating,
  stretching, recolouring, adding effects, and low-contrast placement, and
  illustrate a faded logo as a thing not to do. The row's chain marks render
  at `opacity: 0.7`, which is closer to that than the rest of this directory
  gets. Kept deliberately: the hold-back is what makes eight chain logos sit
  at the row's weight instead of shouting over the currentColor marks beside
  them, and singling Arc out would read as a partner mark given louder
  placement than its neighbours. See `.integrations-mark--chain`.

Arc feels it more than the others do. Every other field here is bright, so
0.7 reads as dimmed-but-present; Arc's is navy on a near-black row, and the
white arch is the only thing separating it from the background.

The stated minimum size is 50px height and the stated clear space is the
height of the inner arch on all sides. Both are given for the full lockup
(arch plus wordmark); the standalone network icon carries neither in the
guidelines. The row renders marks at 1.5em of `--text-xs`, so about 18px.

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
