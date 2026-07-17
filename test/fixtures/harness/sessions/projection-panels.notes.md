# `projection-panels.jsonl` — contract-shape status + offset table

**Contract-shape status.** This fixture is hand-authored, not recorded from
a live agent run. Every `family: meta, type: extract` envelope here matches
the frozen `extract` entry in `Raxol.Agent.Meta.Registry` (required payload
keys `[:class, :op, :item, :refs]`, scope `:session`) — that much is load-
bearing and verified. The per-class `item` field shapes consumed by
`Raxol.Harness.PanelProjection` (worktracks: `id`/`lane`/`title`/`status`;
memory: `key`/`value`; plan: `id`/`title`/`status`) are **contract-shape
ASSUMPTIONS**, not yet verified against what a real agent-emitted `extract`
event actually puts in `item`. This fixture — and the module folding it —
must not be treated as ground truth for the wire shape until that
verification happens; see `Raxol.Harness.PanelProjection`'s moduledoc for
the same caveat stated on the implementation side.

Line numbers below are 1-based, matching the `offset` field
`Raxol.Harness.Fixture.Envelope` carries after `Fixture.load/1` (line 1 is
the header, so envelope offsets start at 2), mirroring
`adversarial.notes.md`'s convention.

Two loop turns (`t1`, `t2`) each carry the full
`turn_started`/`item_started`/`item_delta`/`item_completed`/`turn_completed`
loop-family sequence (`item_delta` tier `ephemeral`, the rest `durable`),
interleaved with `meta`/`extract` lines exercising `Raxol.Harness.PanelProjection`'s
add/update/remove ops across all three classes, plus three intentionally
tolerant-reading-only lines.

| offset (line) | id | class / op | detail |
|---|---|---|---|
| 4 | 3 | `worktracks` / `add` | `wt-1`, lane `todo`, "Design schema" / `open` |
| 6 | 5 | `worktracks` / `add` | `wt-2`, lane `doing`, "Wire panel" / `in_progress` |
| 8 | 7 | `worktracks` / `update` | `wt-1` → status `done` |
| 9 | 8 | `worktracks` / `remove` | `wt-2` dropped (its lane, `doing`, has no other occupant, so it vanishes from the read-model too) |
| 10 | 9 | `memory` / `add` | `topic` = "harness ui panels" |
| 11 | 10 | `memory` / `add` | `mode` = "build" |
| 12 | 11 | `memory` / `update` | `topic` → "harness ui projection panels" |
| 15 | 14 | `plan` / `add` | `step-1` "Draft read-model" / `todo` |
| 16 | 15 | `plan` / `add` | `step-2` "Draft overlay panel" / `todo` |
| 17 | 16 | `plan` / `add` | `step-3` "Write fixture" / `todo` |
| 18 | 17 | `plan` / `update` | `step-1` → status `done` |
| 19 | 18 | class `scratchpad` / `add` | **unknown class** — outside the worktracks/memory/plan vocabulary. Must be skipped by every kind's `fold/2`, never an error (tolerant-reading rule). |
| 20 | 19 | `worktracks` / `annotate` | **unknown op** — `annotate` is not `add`/`update`/`remove`/`delete`. Must be skipped silently. |
| 21 | 20 | `worktracks` / `add` | **HOSTILE**: `wt-hostile` in lane `security`. `title` embeds a raw ESC control byte (`\x1b`) immediately followed by `[2Jevil` and an embedded newline (`"\x1b[2Jevil\ntitle"`) — a smuggled terminal clear-screen sequence, exactly the class of content `display_string/1`'s clamp and `render_lines/2`'s newline-flatten exist to survive without crashing or corrupting footer row accounting. The same item also carries an unrelated ~600-byte `value` field (over `PanelProjection`'s 512-byte clamp) to exercise the length clamp; `value` is inert for the `worktracks` class (only `memory` reads it), so it has no effect on the worktracks read-model beyond proving extra fields are ignored, not rejected. |

The `turn_completed` at offset 13 (`id=12`) closes turn `t1`; turn `t2`
(offsets 14–25) repeats the full loop sequence and its own
`plan`/unknown-class/unknown-op/hostile meta cluster before closing with its
own `turn_completed` at offset 25 (`id=24`).

## Expected read-models (post-fold)

* **worktracks**: lane `todo` → `[{title: "Design schema", status: "done"}]`;
  lane `security` → `[{title: "␛[2Jevil title" (newline flattened by
  `render_lines/2`, raw in `fold/2`'s output), status: "flagged"}]`. `wt-2`
  and `wt-3` (the unknown-op line) never appear.
* **memory**: `[{key: "topic", value: "harness ui projection panels"},
  {key: "mode", value: "build"}]`.
* **plan**: `[{title: "Draft read-model", status: "done"}, {title: "Draft
  overlay panel", status: "todo"}, {title: "Write fixture", status: "todo"}]`.
