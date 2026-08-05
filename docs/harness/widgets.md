# Harness Widgets: the transcript, blocks, tool renders, diffs

## The transcript law

Every transcript body record renders inside an
`Raxol.UI.Components.Harness.Indication` container (a glyph-as-gutter left bar
at column 0 with content at a 2-cell indent) or inside a declared
`Raxol.UI.Components.Harness.IndentationException`. There is no third state; the
transcript normalizer refuses to paint an unwrapped record. The reason is
reviewability: a reviewer grepping `IndentationException` finds every full-bleed
surface in the transcript, and a new widget cannot skip the icon-column
convention by accident, only by writing that name.

The `Indication` gutter is one unit rendered down the content's full height,
with a small strategy vocabulary: a speaker sigil (top corner only), a bracketed
thought (`∵` … `∴`, top and bottom), a single top marker, a vertical rule, or
plain. A new visual is a new gutter clause, never a structural change. That is
the whole point of making the left bar one unit. The legitimate exceptions
today are the Pierre diff rows (the diff's own gutters and line numbers are its
left contour; a second gutter would misalign the panes) and the blank pad rows
the window inserts.

## The block model

One tool call, message, or reasoning step is one collapsible block.
`Raxol.UI.Components.Harness.Block.from_events/3` folds durable journal events
into a `%Block{}`:

- `kind` is one of `:message | :reasoning | :tool_call | :diff | :approval`, or
  `:opaque` for anything unrecognized: a new kind renders safely instead of
  crashing.
- `seal` is `:live | :sealed`, monotonic and one-way; `fold` is
  `:expanded | :folded` and is surface-local. `outcome` carries exit code,
  duration, and cost; `content` is the kind-specific projection, never the raw
  events.

`from_events/3` is pure (the same events always produce the same block) so
the transcript is deterministic from offset 0. Expanded bodies mount through
`Raxol.UI.Components.Harness.BodyProvider`, which validates a per-kind content
schema and rescues a crashing body to an error block: a schema-valid but
crashing body must never escape into the render loop. A flat, linear mode is a
first-class rendering (the accessibility and pipe answer at once).

## Tool renders

A tool is one low-prominence line that says what the agent is *doing to what*: 
`reading ./mix.exs`, never `read_file path: mix.exs`. The verb map lives in
`Block`:

| tool | render |
|---|---|
| `read_file` | reading *path* |
| `list_dir` | looking through *path* |
| `file_stat` | checking metadata of *path* |
| `grep` | searching for "*pattern*" (in *path*) |
| `glob` | looking for *pattern* |
| `run_shell` | execute *command* |
| `write_file` / `edit_file` | writing / editing *path* |

An unknown tool or a missing referent falls back to the raw name-and-args
gloss: honest, never a verb with a hole in it. The line updates in place and
carries its receipt on the same row (`· ✓ · duration`); there is no separate
tool-result block. A running tool line carries the braille spinner in its
column-0 margin cell, riding the existing tick (never a new timer), replaced by
the final state glyph on completion. Reasoning collapses to one dim `∴` line,
peekable. The receipt is the evidence surface: a running line with no receipt
attached is falsifier class 5.

## Widget doctrine

Any widget work honors these:

1. **Read-only projection.** A widget is a pure mapping from a *declared* data
   source to a view built from the primitive vocabulary. An unbound widget is
   unrepresentable.
2. **Request, never claim.** A widget declares intrinsic content and a semantic
   role; flex grants space and the salience solver grants prominence. Two
   solvers, one economy, no widget sets its own brightness.
3. **Lifecycle.** grown → live (breathes with its source, event-clocked) →
   completion blink → settled (dies into the log as a fact line with its
   receipt) → optionally pinned. Nothing accretes unboundedly.
4. **The rim is earned.** `Raxol.UI.Components.Harness.StatusStrip` is the one
   persistent rim lane, and it is itself a grown instrument: it renders only
   while the session has something true to say (a live turn, an approval wait,
   a stall alarm, an animating activity) and yields to silence between turns.
   An idle `Stage: - | Ctx: - | Cost: -` frame is the airiness the doctrine
   bans.

## Diff rendering

`Raxol.UI.Components.Harness.DiffViewer` renders a file diff *before* the edit
applies: a "Proposed change" header and a "Not yet applied" caption, always
present-tense: the framing reads as "this will change", never past tense.

- **Side-by-side when width allows.** `:auto` chooses the split view when both
  panes fit and unified otherwise, so the reader compares old and new by
  eye-line rather than by scrolling. Split mode is borderless and label-less (
  the red and green gutters carry the old/new identity) and the unpaired side
  of a change stays blank to keep the panes vertically aligned.
- **Diff paints the background only.** Syntax tokens own the foreground and are
  never overridden: added rows get a green wash, removed rows red, with a
  brighter tier on the word-level-changed sub-ranges. A `▌` gutter bar replaces
  the `+`/`-` marker. Long unchanged runs fold to a single "N unchanged lines"
  row; long lines never silently truncate. Line differencing is
  `Raxol.UI.Components.Harness.LineDiff` (LCS), intra-line ranges
  `Raxol.UI.Components.Harness.WordDiff`, syntax `Raxol.UI.SyntaxHighlighter`.
- **The sealed identity is a fact line.** A settled diff folds to a compact
  path-first line, `± path · +N -M`, with counts from the same `LineDiff` LCS as
  the expanded body, so the two can never disagree. It is expandable toward
  full-screen review from the approval prompt.
