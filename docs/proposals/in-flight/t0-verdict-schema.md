# T0 verdict schema (`t0-verdict.json`)

Date: 2026-07-15 · Status: **v1, matches the first real run**. Companion to
`harness-ui-testing/01-t0-matrix.md` §7 (this is that schema, restated
against the actual file `scripts/harness/t0/t0-verdict.json` produces) and
to `t0-runbook.md` (how a human adds rows).

---

## 1. Top-level shape

```json
{
  "schema": "raxol.t0.verdict/1",
  "generated_at": "2026-07-15T15:45:56Z",
  "matrix": [ /* CellResult rows, see §2 */ ]
}
```

`generated_at` is rewritten by every producer (`run_matrix.sh` full
rebuild, `append_result.sh` single-row upsert) — it means "this file was
last touched at," not "this cell was measured at" (each row can carry its
own timestamp in `notes` if that distinction ever matters).

## 2. CellResult row

One row per (terminal, context, transport, claim) — this is
`01-t0-matrix.md` §4's `%CellResult{}` struct, JSON-encoded 1:1:

```json
{
  "terminal":   "kitty | iterm2 | wezterm | ghostty | alacritty | vte | apple | tmux | emu",
  "context":    "plain | tmux",
  "transport":  "local | ssh",
  "claim":      "C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | N06 | N07 | ...",
  "observable": "<claim-specific — see §3>",
  "capture":    "native_gettext | tmux_capture | pty_tee | human_eye | emulator | planned",
  "automation": "ci | scripted | human | unavailable",
  "evidence":   "<path to .cast / screenshot / capture-pane dump, or 'n/a'>",
  "verdict":    "pass | fail | fed | lost | partial | clean | stuck_region | ok | corrupt | n/a | null",
  "notes":      "<optional free text — ALWAYS present when the row needed a caveat>"
}
```

**`verdict: null` means "not yet measured"** (a planned/pending row —
`automation` will be `"human"` or `"unavailable"` in that case). A `null`
verdict must NEVER be treated as a pass, a fail, or counted toward D-PA
resolution (`verdict_resolver.exs` filters these out explicitly — see its
comment on the false-positive this would otherwise cause).

**`capture: "planned"`** is the fourth capture method beyond the three
01-t0-matrix.md §4 names (`native_gettext`/`tmux_capture`/`pty_tee`/
`human_eye`) plus `"emulator"` (the Ring-A reference cell) — it marks a row
this environment could not run at all (no GUI terminal, no tmux). It is
replaced by a real capture method the moment `append_result.sh` upserts a
real measurement over it.

**`automation: "unavailable"`** (fourth value beyond `ci`/`scripted`/
`human`) marks a row that COULD have been scripted (tmux was one of the
cell's requirements) but wasn't, because the tool itself was missing in
this environment (e.g. `tmux` not on `$PATH`) — distinct from `"human"`,
which marks a row that fundamentally requires eyes/hands (Ring C, or any
terminal with no capture API).

## 3. `observable` per claim (matches 01-t0-matrix.md §4 exactly)

| claim | observable shape | example |
|---|---|---|
| C1 | `"pass" \| "fail"` | `"pass"` |
| C2 | `"fed" \| "lost" \| "partial"` | `"fed"` |
| C3 | `"pass" \| "fail"` | `"pass"` |
| C4 | `"reflow" \| "freeze_clean" \| "ghost" \| "flood"` | `"reflow"` |
| C5 | `{"decrqm": "none\|replied\|<value>", "torn": bool\|"n/a"}` | `{"decrqm":"none","torn":"n/a"}` |
| C6 | `"<exit-class>:<clean\|stuck_region>"` (one row per exit class: clean/sigterm/crash/sigkill) | `"sigkill:stuck_region"` |
| C7 | `{"region":"fed\|lost", "osc133_host_visible":"...", "decrqm_passthrough":"..."}` | see capture below |
| C8 | `"<algorithm>:<ok\|corrupt>"` (one row per algorithm) | `"long_lived:ok"` |
| N06 | `{"live_view_wiped":"yes\|no","tmux_scrollback_survives":"yes\|no"}` | see capture below |
| N07 | `"yes" \| "no"` (did the out-of-region footer survive) | `"yes"` |

Deviation from the 01 design's exact struct (documented, not silent): the
design's single `%CellResult{}` assumed one row per claim; **C6 and C8 are
actually FAMILIES of sub-cases** (4 exit classes; 2 algorithms) that each
need their own pass/fail, so this implementation emits one row per
sub-case with `claim` held constant and the sub-case folded into
`observable` (`"sigkill:stuck_region"` rather than a `C6a`/`C6b` claim
split) — cheaper to add sub-cases later without a schema migration.

**Tail-window convention (C2 rows, feeds §7.2's second conjunct):** a C2
row SHOULD record how many sealed rows remained on-screen above the footer
before native scroll consumed them, measured in the P-02 run — either as a
top-level `"tail_window_rows": <int>` on the row, or inside a map-shaped
observable: `{"status": "fed", "tail_window_rows": 21}`. D-PA option (B)
requires a measured NON-ZERO window on every tier-1 terminal; C2 rows
without it can at best yield (A).

**Coherence rule (C1..C4 rows):** `verdict` and the observable's status
must agree (`"fed"`/`"fed"`, `"pass"`/`"pass"`, …). A row where they
disagree (e.g. `verdict:"fed"` with `observable:"lost"`) is malformed:
the resolver excludes it from every computation and reports it in its
`malformed` output — it is never counted in either direction. A C1..C4
row whose observable carries NO status (e.g. `observable: null`) is
*unmeasured*: it contributes nothing, and in particular is never read as
a lost/fail signal.

## 4. What a real run actually produced (2026-07-15, this environment)

`scripts/harness/t0/t0-verdict.json` as committed has **242 rows**:

- **13 real rows, terminal `tmux`** — every claim except C4 (resize was not
  exercised this pass; the tmux cell driver has the plumbing, see
  `t0-runbook.md` §4 for the follow-up command). All produced by actually
  running `scripts/harness/t0/probes/*.sh` inside a real detached tmux 3.7b
  session and reading back `tmux capture-pane`/`display-message` — not
  guessed.
- **5 real rows, terminal `emu`** — C1/C3/C6 structural pass, C2
  correctly `n/a` (never `pass` — see `01-t0-matrix.md` §3.2), N06 the
  permanent Ring-A regression-net pairing (`fail_as_expected` on the
  keyframe-clear fixture, no false positive on the clean stream).
- **224 planned rows** — the full 7-terminal × {plain,tmux} ×
  {local,ssh} × 8-claim grid, `verdict: null`, `automation: "human"`,
  waiting on `t0-runbook.md`'s Ring B commands.

**D-PA is `"pending"`** (`verdict_resolver.exs`'s honest output): zero of
the four tier-1 terminals (kitty/iTerm2/WezTerm/Ghostty) have been measured
yet. The tmux and emu rows are real, useful data (they validate the probe
scripts, the detector logic, and the emulator's structural half) but
**neither is a tier-1 real terminal**, so per §7.2 they cannot resolve D-PA
by themselves — resolving it early from proxy data would be exactly the
false positive the whole document warns against.

### 4.1 Resolver output contract

`elixir scripts/harness/t0/verdict_resolver.exs [file]` prints one JSON
object (exit 0; unreadable/malformed input exits 1 with
`cannot resolve: <reason>`):

```json
{
  "dpa": "A | B | C | pending",
  "reason": "<paste-able explanation of the computation>",
  "go": "go | no_go | partial",
  "go_reason": "<§7.4 gate result>",
  "tier1_terminals_measured": ["..."],
  "tier1_terminals_missing": ["..."],
  "proxy_rows_excluded": 0,
  "malformed": ["<excluded incoherent rows, one line each>"],
  "provisional": null
}
```

Soundness rules the resolver enforces in code (each locked by a fixture in
`scripts/harness/t0/test/resolver_fixtures/`, run via
`elixir scripts/harness/t0/test/resolver_test.exs`):

- **Measured** = a terminal with BOTH a ground-truth C2 measurement and a
  C1 measurement; a terminal present only via other claims stays missing
  (closes the measured-inflation hole: kitty-C2 + wezterm-C4-only must
  never produce a "B").
- **C1∧C2 join** — C2=fed only counts as fed when that terminal's C1
  (footer pinned) also passed.
- **Provenance** — plain-context rows captured via `tmux_capture` are
  proxy evidence, excluded and counted in `proxy_rows_excluded`. Ground
  truth for plain context: `native_gettext | pty_tee | human_eye`.
  Ghostty (no native get-text as of 2026) legitimately reaches ground
  truth only via `human_eye` — it stays partial/human-verified until that
  pass happens.
- **Transport aggregation** — multiple C2 rows for one terminal (local +
  ssh) aggregate conservatively: any `lost` → lost; all `fed` → fed; the
  tail window is the MINIMUM across rows. C1/C3: any fail → fail.
- **Two-terminal floor** — with fewer than 2 measured tier-1 terminals,
  `dpa` is `"pending"` and `provisional` is `null`, structurally. With
  2–3 measured, `dpa` stays `"pending"` but `provisional` shows what the
  subset suggests. Only a fully measured tier-1 set (all four) yields a
  definitive `"A"/"B"/"C"`.
- **GO gate (§7.4)** — `go: "go"` requires every tier-1 terminal to pass
  C1+C3 with C2=fed (joined, aggregated); any C1/C3 failure or C2=lost →
  `"no_go"`; anything else → `"partial"`.
- **Idempotence** — output is invariant under row reordering and row
  duplication.

## 5. Fallback-trigger registry

Kept as a separate, hand-maintained object (not yet emitted by any script —
`run_matrix.sh` v1 focuses on the matrix; a future pass can compute
`triggers` from the matrix mechanically, mirroring `verdict_resolver.exs`).
Until then, consult `01-t0-matrix.md` §7.3 directly; the triggers this run
already has evidence for:

- `keyframe_clear_leak` — **confirmed** (N06 row, tmux + emu agree): the
  live view is wiped by `\e[2J`; T2c's "forbid `\e[2J`" invariant is
  justified by measurement, not just the roadmap's prior art citation.
- `sigkill_stuck_region` — **confirmed** (C6 sigkill row): documented
  residual, not a bug — matches T0-N-05's expected/accepted outcome
  exactly.
- All other triggers: no tier-1 evidence yet (same gate as D-PA).

## 6. File layout this schema lives beside

```
scripts/harness/t0/
  t0-verdict.json               # this schema, generated by run_matrix.sh
  run_matrix.sh                 # full matrix rebuild (idempotent)
  append_result.sh              # single-row upsert (a human's Ring B result;
                                # validates terminal/context/transport enums)
  verdict_resolver.exs          # CLI: file -> resolver output (§4.1)
  lib/verdict_resolver_core.exs # the pure resolver module (all logic)
  test/resolver_test.exs        # discrimination fixture suite (13 fixtures)
  test/resolver_fixtures/*.json # synthetic verdicts locking each rule
  capture_writer.sh             # writes capture/<terminal>-<context>.json
                                # (separate schema: 04-capability.md §2)
  capture/*.json                # capability captures (NOT this schema)
  capture/evidence/*.txt        # raw capture-pane/get-text dumps this
                                # schema's `evidence` field points at
```
