# Benchmark Suite

Benchmark scripts for Raxol. For measured numbers and how they are produced,
see [docs/bench/README.md](../docs/bench/README.md).

## Quick start

```bash
mix run bench/suites/parser/parser_benchmark.exs               # ANSI parser
mix run bench/suites/rendering/render_performance_simple.exs   # rendering
mix run bench/suites/core/performance_summary.exs              # system-wide
mix run bench/suites/comparison/framework_comparison.exs       # the README table
```

## Gates

Most scripts here are reports: they print numbers and exit 0. One is a gate.

```bash
MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs
```

`core/buffer_gate.exs` measures target-only `Raxol.Terminal.Buffer`
fill/read/scroll throughput and per-cell memory against the budgets and
ubuntu-latest provenance declared at the top of the file. It stops with
status 1 on a breach and status 2 on an invalid measurement. The
`scoreboard` job in `.github/workflows/ci-unified.yml` runs it and the
`ci-status` aggregate job fails when that job fails. Read the gate's
sensitivity and budget-change rules before changing a number.

## Scoreboard

```bash
MIX_ENV=test mix raxol.scoreboard
MIX_ENV=test mix run --no-start bench/core/buffer_gate.exs --json buffer.json
MIX_ENV=test mix raxol.scoreboard --include buffer.json --output scoreboard.json
```

`mix raxol.scoreboard` counts deterministic work, not time: the ANSI frame
bytes the engine writes and the BEAM reductions spent per frame of the
playground table and flex-layout demos, driven in-process through the
rendering engine's own stage functions. A terminal with synchronized output
also receives a 16-byte wrapper per frame, not counted.
`test/raxol/scoreboard_test.exs` holds `Raxol.Scoreboard.frames/2` to the
bytes a real engine writes for the same keys, and before measuring, every
frame is replayed through `Raxol.Terminal.Emulator` and must reproduce its own
screen (character and style), so the byte count only falls by sending less
for the same screen. `table.keystroke.work_ratio` is a keystroke's work over
the first frame's: an incremental renderer sits far below 1, and the table
demo is at 0.98 today. Bytes and memory are exact. Reductions are not quite:
runs on one machine agree within a few hundredths of a percent, but two CI runs
of the same commit have differed by up to 0.2%, so reduction metrics count a
change only beyond 0.5%. `table.screen.heap_bytes_per_cell` is the memory of
the screen buffer the engine holds after the table script, per cell.
`--include` merges the buffer gate's memory rows, which measure
`Raxol.Terminal.Buffer`, a different structure from the render path's. Metric
ids, labels and which direction is better are in
`priv/scoreboard/metrics.json`; add a metric there before emitting it.

Each scenario frame's screen is also pinned: its fingerprint (every cell's
character and style) is in `priv/scoreboard/screens.refs`, and the scoreboard
refuses to measure a screen that differs. Replay proves the bytes draw the
screen; the pin proves it is the same screen as before, so the numbers cannot
improve because a demo draws less. When a playground demo the scoreboard uses
(`TableDemo`, `FlexLayoutDemo`) is meant to look different, run
`MIX_ENV=test mix raxol.scoreboard --bless` and commit `screens.refs` in the
same pull request, where the change and its effect on the numbers are reviewed
together.

CI uploads each run's record as the `scoreboard` artifact.
`.github/workflows/scoreboard.yml` comments on the open pull request whose head
is the tested commit, comparing against the nearest recorded ancestor of its
base commit on its base branch (and saying so when that is not the base commit
itself), and appends master's records to `scoreboard/records.jsonl` on the
`gh-pages` branch; releases list the change since the previous tag.

### Agent tasks

`Raxol.Scoreboard.AgentTasks` asks "can an AI use your app?" without a model.
Five playground tasks (sort the table by stars descending, pick an option in a
select list, dismiss a modal, fill a text input, switch tabs) are each solved
twice in a fresh headless session at 80x24 with subscriptions off: once with
the app's derived MCP tools, called on the session's tool registry, and once
with keys through `Raxol.Headless.send_key_and_screenshot/3`, which answers a
screenshot per key. Both must leave the model in the task's goal state. The
metrics `agent.<task>.{tool_calls,tool_bytes,key_calls,key_bytes}` count
calls and what an agent reads and writes, bytes standing in for tokens: the
tool list, requests and results on one side, a first screenshot, requests and
one screenshot per key on the other. They are exact and report-only. A path
that does not reach its goal is printed and left out of the record, which
the comparison shows as not measured. A changed demo screen, tool description
or result text moves the numbers, as it should.

### History

The `gh-pages` history reaches back past the scoreboard itself.
`.github/workflows/scoreboard-backfill.yml` (run by hand) runs
`scripts/scoreboard-backfill.sh` over master's first-parent commits. The script
copies today's `mix raxol.scoreboard` onto each commit and keeps a record only
when the copy reproduces that commit's own engine byte for byte
(`test/raxol/scoreboard_test.exs`) and draws the pinned screens. The first
commit that does is #1133 (2026-09-27), so the records start there. Frame bytes
do not move in that window, but the work does: #1170, which stopped building
log messages on render paths, cut the table demo's work per keystroke from
2,228,840 to 1,728,340 reductions (22%) and the flex first frame from 916,446
to 751,037 (18%), as recorded on CI.

No release draws today's screens: v2.6.1 and v2.7.0 drop the dim (faint)
attribute, which #1133 fixed, and v2.6.0 differs in characters and colors too,
so releases get no records. `bench/core/scoreboard_legacy.exs` puts numbers on
them anyway. It feeds today's cells for every scenario frame to each release's
own terminal backend and replays the output through today's emulator. Each
screen has 4,800 cells (120x40).

```bash
MIX_ENV=test mix run --no-start bench/core/scoreboard_legacy.exs v2.6.0 v2.6.1 v2.7.0
```

| Release | Table first frame | Table per keystroke | Flex first frame | Cells drawn differently from today |
| --- | ---: | ---: | ---: | --- |
| today | 5,918 B | 1,195.6 B | 6,537 B | none |
| v2.7.0 | 5,863 B | 1,173.5 B | 6,529 B | table: every frame, up to 641 cells; flex: 162 cells (dim attribute only) |
| v2.6.1 | 5,863 B | 1,173.5 B | 6,529 B | same as v2.7.0 |
| v2.6.0 | 17,901 B | 19,325.9 B | 11,170 B | table: every frame, up to 1,917 cells; flex: 576 cells (characters, colors, bold, dim) |

A release that draws less sends fewer bytes, which is why v2.7.0 sits below
today. v2.6.1 is the first release with incremental frames (#534) and style
batching. Per keystroke it sends 16 times fewer bytes than v2.6.0, which
cleared and redrew the whole screen on every frame. v2.4.0 and v2.5.0 are
missing because their locked dependencies build on neither their pinned OTP 26
(cowlib) nor OTP 29 (meck).

### Canaries

Each file in `bench/scoreboard_canaries/` is a deliberate regression: a patch
with a `Regression:` line saying what it breaks and either `Expect-worse:` (the
metrics the comparison must call worse) or `Expect-refused:` (text the
scoreboard's refusal to measure must contain). The script measures the
checkout, then applies, measures and reverts each patch in turn, and checks
the verdict with the classification the pull request comment uses:

```bash
MIX_ENV=test scripts/scoreboard-canaries.sh [NAME...]   # on a clean tree
```

| Canary | Breaks | Caught by |
| --- | --- | --- |
| `keyframe_every_frame` | every frame redraws every row | bytes per keystroke (+397%) |
| `redundant_reset` | 4 extra bytes on every emitted row | all three byte metrics (+2.5%) |
| `encodes_rows_twice` | every emitted row encoded twice | work per keystroke (+1.7%), first frames |
| `row_rebuilt_twice` | every cell write rebuilds its row twice | all reduction metrics (+14% to +23%) |
| `cell_grows_a_field` | the render path's `%Raxol.Terminal.Cell{}` gains a field | screen memory (+2.6%) |
| `buffer_cell_grows_a_field` | the gate's `%Raxol.Terminal.Buffer.Cell{}` gains a field | buffer gate memory (+3.3% to +3.5%) |
| `skips_a_changed_row` | a diff frame leaves out a changed row | replay check refuses |
| `drops_dim_attribute` | the encoder stops emitting dim (the bug #1133 fixed) | replay check refuses |
| `table_draws_fewer_rows` | the table demo shows three rows, not four | screen pins refuse |
| `tool_results_quoted` | derived-tool results go out `inspect`-quoted | every agent task's tool bytes (+0.17% to +0.29%) |
| `screenshots_keep_trailing_blanks` | text screenshots keep each line's trailing blanks | every agent task's key bytes (+78% to +189%) |

A canary that is not caught, or whose patch no longer applies, fails the run.
CI runs it when a change touches the scoreboard's own files or a file a canary
patches, and gates on it; the nightly runs it every night. A stale patch is
regenerated with `git diff` after making the same edit to today's code.

`encodes_rows_twice` also shows a limit of `table.keystroke.work_ratio`: a
slower first frame lowers the ratio, so that regression reads as a 6.4% better
keystroke cost. Read the ratio next to the reductions it divides.

## Suites

| Directory | Contents |
| --- | --- |
| `suites/parser/` | `parser_benchmark.exs`, `ansi_profile.exs`, `parser_chain_profile.exs`, `sgr_comparison.exs` |
| `suites/terminal/` | `emulator_profiling.exs`, `lite_emulator_test.exs` |
| `suites/rendering/` | `render_performance_simple.exs` |
| `suites/core/` | `performance_summary.exs` |
| `suites/comparison/` | `framework_comparison.exs`, the source of the root README's frame-time table |
| `suites/enhanced/` | `performance_dashboard.exs` |
| `suites/performance/` | Reusable modules: animation, event handling, memory, rendering, reporting |
| `suites/visualization/` | Chart and visualization benchmarks |

Two standalone scripts sit directly in `suites/`:
`kitty_graphics_benchmark.exs` and `protocol_performance_benchmark.exs`, plus
`example_dsl_benchmark.exs` as a template for a new one.

## Other directories

| Directory | What it holds |
| --- | --- |
| `baselines/` | Baseline data for regression comparison |
| `snapshots/` | Performance snapshots |
| `results/` | Benchee run output (`.benchee`, JSON) |
| `output/` | HTML reports and their static assets |
| `scripts/` | Benchmark utilities |
| `core/` | `buffer_gate.exs`, the gate above, plus older per-area scripts |
| `features/`, `memory/`, `live_view/`, `liveview/` | Older per-area scripts kept for reference |
