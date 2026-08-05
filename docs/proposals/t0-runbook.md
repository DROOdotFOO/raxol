# T0 runbook: running the keystone matrix

Date: 2026-07-15 · Status: **v1**. Companion to
`t0-verdict-schema.md` (the file this writes to), and
`scripts/harness/t0/` (everything referenced below lives there).

This is the "Ring B" half of T0: real-terminal measurement a human runs by
hand. Ring A (CI headless) and the automated Ring-B proxy cells (tmux, the
`emu` structural cell) already ran in the sandboxed environment that built
this unit: see §1. Everything past §1 is **not yet run** and needs a human
at a real keyboard in front of each terminal.

---

## 0. Prerequisites

- This repo checked out, `mix deps.get` run once (`packages/raxol_terminal`
  compiles termbox2: normal, not an error).
- `tmux` >= 3.x on `$PATH` (macOS: `brew install tmux`).
- `jq` on `$PATH` (macOS: `brew install jq`; used by every script here).
- `python3` on `$PATH` (used by `lib/read_reply.py` for raw DECRQM capture).
- For SSH cells: a loopback or LAN target reachable via `ssh`, with this
  repo checked out there too (or just the `scripts/harness/t0/` directory
  copied over: the probe scripts have no other dependency).

All commands below assume `cd` to the repo root first, or use the absolute
paths shown.

---

## 1. Reproducing what already ran (Ring A + the tmux/emu proxy cells)

```bash
bash scripts/harness/t0/run_matrix.sh
```

This is a **full rebuild** of `scripts/harness/t0/t0-verdict.json`: it
re-runs every tmux proxy cell (C1/C2/C3/C5/C6×4-exit-classes/C7/
C8×2-algorithms/N06/N07), re-runs the `emu` structural cell via
`MIX_ENV=test mix run`, and re-emits the 224 `planned` placeholder rows for
the real-terminal matrix this environment can't drive. It is idempotent: 
safe to re-run any time; **any real rows a human already appended via
`append_result.sh` (§2 below) get REPLACED by this rebuild**, so if you've
been filling in Ring B results, don't re-run `run_matrix.sh` afterward
without re-appending them (or better: only ever run it once at the start,
then use `append_result.sh` from then on).

To skip either half:

```bash
bash scripts/harness/t0/run_matrix.sh --skip-tmux   # emu only
bash scripts/harness/t0/run_matrix.sh --skip-emu    # tmux only
```

Check the current D-PA resolution at any point:

```bash
elixir scripts/harness/t0/verdict_resolver.exs scripts/harness/t0/t0-verdict.json
```

(As of this unit's first run: `"dpa": "pending"`: zero tier-1 real
terminals measured yet. That is the correct, honest answer until §2 below
adds real rows.)

---

## 2. The one command per Ring-B cell

**The pattern, every time:**

1. Run a probe script (`scripts/harness/t0/probes/*.sh`) inside/against the
   real terminal.
2. Capture via whatever method that terminal supports (native get-text API,
   `tmux capture-pane`, or a screenshot).
3. Judge the capture against the claim's expected shape (§3 of
   `01-t0-matrix.md`, restated in `t0-verdict-schema.md` §3).
4. Record it: `scripts/harness/t0/append_result.sh TERMINAL CONTEXT
   TRANSPORT CLAIM VERDICT OBSERVABLE CAPTURE_METHOD AUTOMATION
   EVIDENCE_PATH [NOTES]`: this auto-appends/upserts the row into
   `t0-verdict.json` (replacing the matching `planned` placeholder).

**Probe scripts available** (all in `scripts/harness/t0/probes/`, all
`bash SCRIPT [HEIGHT] [FOOTER_ROWS] [...]`, defaults 24×3):

| script | claim | what it does |
|---|---|---|
| `p01_region_footer.sh` | C1 | region + footer, 40-line stream |
| `p02_scrollback_feed.sh` | C2 | 100-line overflow (**the keystone measurement**) |
| `p03_cursor_protocol.sh` | C3 | print-above + DECSC/DECRC cycles |
| `p04_region_algorithm.sh ALGO` | C8 | `ALGO` = `long_lived` \| `transient` |
| `p05_mode2026_probe.sh [TIMEOUT]` | C5 | DECRQM query + sync-output bracket |
| `p06_teardown.sh MODE` | C6 | `MODE` = `clean` \| `sigterm` \| `crash` (SIGKILL: send `kill -9` to the process directly, don't use a MODE for it) |
| `p07_tmux_marks.sh` | C7 | OSC 133 + region load |
| `n06_keyframe_clear.sh` | N06 | reproduces the `\e[2J` history-wipe bug |
| `n07_inverted_region.sh` | N07 | negative control: region on the wrong (bottom) rows |

### 2.1 kitty (native `kitten @ get-text`)

```bash
kitty @ launch --type=os-window --hold -- bash scripts/harness/t0/probes/p02_scrollback_feed.sh
sleep 3
kitten @ get-text --extent=all > /tmp/t0-kitty-c2.txt
grep -c '^LINE-' /tmp/t0-kitty-c2.txt   # expect 100
# Also count the TAIL WINDOW: how many sealed LINE-* rows are still on the
# VISIBLE screen above the footer (kitten @ get-text without --extent, count
# LINE-* rows). Record it in the observable: D-PA option (B) requires a
# measured non-zero window on every tier-1 terminal; without it the resolver
# can at best answer (A).
bash scripts/harness/t0/append_result.sh kitty plain local C2 fed \
  '{"status":"fed","tail_window_rows":21}' \
  native_gettext scripted /tmp/t0-kitty-c2.txt \
  "kitten @ get-text --extent=all: $(grep -c '^LINE-' /tmp/t0-kitty-c2.txt)/100 lines; 21 sealed rows still on-screen above footer"
```

Note the coherence rule (t0-verdict-schema.md): the `VERDICT` argument and
the observable's `status` must agree (`fed`/`fed`): the resolver excludes
mismatched rows as malformed rather than guessing which field to trust.

Repeat with `p01_region_footer.sh` -> C1 (diff the footer rows before/after
via `kitten @ get-text` on just the footer range), `p03_cursor_protocol.sh`
-> C3 (kitty exposes cursor position via `kitten @ get-text` output or
`kitty @ ls` cursor field), `p05_mode2026_probe.sh` -> C5, `p06_teardown.sh`
-> C6 per exit class, `p07_tmux_marks.sh` (run this one INSIDE a kitty+tmux
window) -> C7, `p04_region_algorithm.sh long_lived`/`transient` -> C8,
`n06_keyframe_clear.sh` -> N06, `n07_inverted_region.sh` -> N07. Same
`append_result.sh` shape each time, `terminal=kitty`, `capture=native_gettext`.

### 2.2 WezTerm (native `wezterm cli get-text`)

```bash
wezterm cli spawn -- bash scripts/harness/t0/probes/p02_scrollback_feed.sh
sleep 3
PANE_ID=$(wezterm cli list --format json | jq '[.[]][-1].pane_id')
wezterm cli get-text --pane-id "$PANE_ID" --start-line -120 > /tmp/t0-wezterm-c2.txt
grep -c '^LINE-' /tmp/t0-wezterm-c2.txt
bash scripts/harness/t0/append_result.sh wezterm plain local C2 fed fed \
  native_gettext scripted /tmp/t0-wezterm-c2.txt "wezterm cli get-text: $(grep -c '^LINE-' /tmp/t0-wezterm-c2.txt)/100"
```

Same probe/claim list as kitty (§2.1), `terminal=wezterm`.

### 2.3 iTerm2 (Python API)

iTerm2's capture is the Python API, not a CLI one-liner. From iTerm2's
Scripts console (or `iterm2` pip package):

```python
import iterm2, subprocess

async def main(connection):
    app = await iterm2.async_get_app(connection)
    window = app.current_terminal_window
    tab = await window.async_create_tab()
    session = tab.current_session
    subprocess.Popen(["bash", "scripts/harness/t0/probes/p02_scrollback_feed.sh"])
    await iterm2.util.async_wait_for(3)  # let it stream
    contents = await session.async_get_screen_contents()
    with open("/tmp/t0-iterm2-c2.txt", "w") as f:
        for i in range(contents.number_of_lines):
            f.write(contents.line(i).string + "\n")

iterm2.run_until_complete(main)
```

Then the same `append_result.sh ... terminal=iterm2 ... native_gettext ...`
call as §2.1, reading `/tmp/t0-iterm2-c2.txt`. `async_get_screen_contents`
only returns the VISIBLE screen by default, for scrollback, iTerm2's API
needs `session.async_get_contents(...)` with a wider range, or fall back to
the tmux-hosted recipe (§2.5) for iTerm2's C2 cell specifically.

### 2.4 Ghostty, Alacritty, VTE (GNOME Terminal): via tmux (§2.5)

Per `01-t0-matrix.md` §2's capture table, none of these three have a stable
get-text API as of 2026: run every probe **inside a tmux session hosted by
that terminal** and capture with `tmux capture-pane`, exactly like the
sandboxed tmux proxy cell this unit already automated, except now tmux's
OUTER terminal is real. This is the only way to get:

- C1/C2/C3/C6/C7/C8/N06/N07 for these three terminals (same commands as
  the sandboxed run, just executed with that terminal as the visible host: 
  see §2.5's generic recipe).
- **The part the sandbox COULD NOT measure**: whether OSC 133 marks and the
  DECRQM 2026 reply reach the outer terminal (C5, C7's
  `osc133_host_visible`/`decrqm_passthrough` fields): this requires
  `allow-passthrough on` in tmux and a REAL terminal above it, which is
  exactly what's available here and wasn't in the sandbox.

```bash
tmux set -g allow-passthrough on   # required for the host-visibility check
```

Provenance caveat (resolver rule, t0-verdict-schema.md §4.1): rows captured
via `tmux capture-pane` are recorded with `context=tmux` and measure tmux's
own emulator: they never count as the host terminal's `plain` cells. For
Ghostty/Alacritty/VTE's **plain**-context C2 (the cells D-PA actually
reads), use the §2.6 human-eye recipe (`capture=human_eye` is accepted
ground truth); Ghostty stays partial/human-verified until someone does that
pass. That is expected, not a process failure.

### 2.5 Generic tmux-hosted recipe (reuse for Ghostty/Alacritty/VTE, and for
### a second independent measurement on kitty/iTerm2/WezTerm inside tmux)

```bash
# Open a tmux session in the target terminal (Ghostty/Alacritty/VTE/etc),
# then from a shell inside that terminal (NOT nested tmux, this new
# session IS your one level of tmux):
tmux new-session -s t0cell -x 80 -y 24 \
  'bash scripts/harness/t0/probes/p02_scrollback_feed.sh; sleep 3'
# from another pane/window, or after it finishes:
tmux capture-pane -p -S -130 -t t0cell > /tmp/t0-ghostty-tmux-c2.txt
tmux kill-session -t t0cell
grep -c '^LINE-' /tmp/t0-ghostty-tmux-c2.txt
bash scripts/harness/t0/append_result.sh ghostty tmux local C2 fed fed \
  tmux_capture scripted /tmp/t0-ghostty-tmux-c2.txt \
  "capture-pane -S -130 inside tmux hosted by Ghostty: $(grep -c '^LINE-' /tmp/t0-ghostty-tmux-c2.txt)/100"
```

Swap `ghostty` for `alacritty`/`vte`/`kitty`/`iterm2`/`wezterm` and rerun in
each terminal for that terminal's `context=tmux` rows. Swap the probe
script per claim per §2's table (C1/C3/C5/C6/C7/C8/N06/N07 all follow the
exact same shape, only the judgment logic per claim differs; see
`scripts/harness/t0/tmux/run_cell.sh`'s `cell_*` functions for the EXACT
judgment logic this unit already validated in the sandbox, port the same
`grep`/diff checks, just against a real host).

**C5/C7 host-visibility, specifically** (the thing the sandbox flagged as
untestable, `t0-verdict-schema.md` §4): after the tmux session above exits,
check whether `kitten @`/`wezterm cli`/etc. on the HOST (outside tmux) saw
the OSC 133 marks or the DECRQM reply, if the host terminal's own log/API
shows nothing, that confirms R-04 §D's expectation (`:inert`); if it does,
that's new information worth flagging back to the roadmap owner before T1
finalizes its tmux quirk table.

### 2.6 Alacritty / VTE without tmux (no get-text at all)

Fall back to a PTY tee + human screenshot:

```bash
script -q /tmp/t0-alacritty-c2.cast bash scripts/harness/t0/probes/p02_scrollback_feed.sh
# then, by hand: scroll the terminal back, visually confirm LINE-0001
# through LINE-0100 are all present and in order; take a screenshot.
bash scripts/harness/t0/append_result.sh alacritty plain local C2 fed fed \
  human_eye human /tmp/t0-alacritty-c2.cast \
  "manual scroll-back + screenshot; LINE-0001..0100 confirmed present by eye"
```

### 2.7 Apple Terminal (AppleScript, visible-only)

```applescript
tell application "Terminal"
    do script "bash scripts/harness/t0/probes/p02_scrollback_feed.sh" in front window
    delay 3
    set output to contents of front window
end tell
```

`contents of` only returns the VISIBLE screen (per §2's capture table): 
Apple Terminal's C2 cell needs either the tmux-hosted recipe (§2.5, which
gives you real scrollback via `capture-pane`) or a manual scrollback check
+ screenshot (§2.6's pattern), recorded with `capture=human_eye` if manual,
`capture=tmux_capture` if via tmux.

### 2.8 SSH transport (any terminal, `transport=ssh`)

Identical recipes, prefixed with `ssh`:

```bash
ssh myhost 'bash ~/raxol/scripts/harness/t0/probes/p02_scrollback_feed.sh'
```

Capture from the LOCAL terminal (the one you're physically looking at: 
SSH transport tests whether the round-trip adds latency/corruption, not a
different terminal). Record with the same `append_result.sh` call, setting
`TRANSPORT=ssh`. Also time the DECRQM round-trip for C5
(`time bash probes/p05_mode2026_probe.sh 2.0` over the SSH session) and
note the added latency in the `NOTES` field: this feeds T1's SSH-widened
timeout constant.

---

## 3. C-4 (resize): the one claim this unit's automation does not cover

Neither the tmux proxy cell nor the `emu` cell can produce C4 evidence
(tmux resize doesn't reproduce a real terminal's SIGWINCH reflow policy;
the emulator has no scrollback to corrupt, both documented `n/a` in
`t0-verdict-schema.md` §4). This is a Ring-B-only claim on every real
terminal:

```bash
# In the target terminal, 80 columns:
bash scripts/harness/t0/probes/p02_scrollback_feed.sh 24 3 30 &
sleep 1
# Resize the terminal window: 80 -> 120 -> 60 columns (drag, or your
# terminal's keybind/menu). Then:
kitten @ get-text --extent=all > /tmp/t0-kitty-c4.txt   # or the terminal's own capture method
```

Judge: `reflow` (text re-wraps cleanly to the new width) / `freeze_clean`
(stays at the old width, no corruption) / `ghost` (stale-width fragments
visible) / `flood` (near-duplicate frames appear). Record:

```bash
bash scripts/harness/t0/append_result.sh kitty plain local C4 reflow reflow \
  native_gettext human /tmp/t0-kitty-c4.txt "80->120->60 resize during stream; clean reflow, no ghosting"
```

(`automation: human` even though capture is native: the JUDGMENT here
needs a human's eyes on the resize transition, not just the final grid.)

---

## 4. Once >= 2 tier-1 terminals have real C2 + C4 rows

```bash
elixir scripts/harness/t0/verdict_resolver.exs scripts/harness/t0/t0-verdict.json
```

The resolver enforces its own floors in code (see t0-verdict-schema.md
§4.1): fewer than 2 measured tier-1 terminals → `dpa: "pending"` with no
provisional at all; 2-3 measured → still `"pending"` but with a
`provisional` suggestion; a definitive `"A"/"B"/"C"` plus the §7.4
`go: "go"/"no_go"` gate only comes from the fully measured tier-1 set
(kitty/iTerm2/WezTerm/Ghostty). A terminal only counts as measured when it
has BOTH a ground-truth C2 row and a C1 row: remember to record C1 first
or the terminal stays in `missing` no matter how good its C2 evidence is.
Paste the resolver's JSON output into the roadmap's D-PA decision record
once tier-1 is complete: the `reason` field is written to be pasted
verbatim.

The resolver's own regression suite (13 synthetic fixtures locking the
soundness rules: run after any resolver change):

```bash
elixir scripts/harness/t0/test/resolver_test.exs
```

---

## 5. Capability captures (feeds T1, separate from the verdict matrix)

Every DECRQM-style probe (C5) also writes a capability capture:

```bash
bash scripts/harness/t0/capture_writer.sh kitty bare "0.32" \
  "$(printf '\x1b[?2026$p' | xxd -p | tr -d '\n')" \
  "<reply hex from read_reply.py>" \
  "kitty 0.32, plain local, DECRQM 2026 replies ;1 (set)"
```

These land in `scripts/harness/t0/capture/<terminal>-<context>.json`
(schema: `harness-ui-testing/04-capability.md` §2): T1's builder copies or
symlinks this directory in once `Raxol.Test.CapabilityFixtures.load!/1`
exists (that doc's §10.3 recommends T0 write there directly; this unit's
write-set does not include `test/fixtures/`, so captures stay under
`scripts/harness/t0/capture/` until T1 lands and copies them over).
