# Cohort Research: TUI/Visual Layer — Claude Code vs. Codex CLI

Scope: rendering, flicker, scrollback, layout, colors, diff display, status
indicators, input area, navigation, resize, terminal compatibility. Agent
logic, pricing, and model quality are explicitly out of scope. Forum-first:
GitHub issues, HN, Reddit, blog post-mortems. Vendor docs are supplementary
only (none cited as primary evidence below — all claims trace to a forum/issue
URL).

Date of research: 2026-07-15. "Recent" issue timestamps below are as they
appear in the tracker at that date.

---

## 1. Claude Code (Ink/React → custom renderer)

### 1.1 What it ships visually

Claude Code is a full interactive TUI built on React, originally on the `Ink`
library (react-for-terminal), later replaced by a from-scratch renderer that
an Anthropic engineer described as running "closer to a small game engine
than a standard terminal app": React scene graph → layout (Yoga/flexbox) →
rasterize to a 2D cell buffer → diff against the previous frame → generate
ANSI sequences, on a ~16ms frame budget
([HN #46701013](https://news.ycombinator.com/item?id=46701013),
[blog: CLAUDE_CODE_NO_FLICKER](https://slyapustin.com/blog/claude-code-no-flicker.html)).
Two render modes coexist: a default mode that reprints/scrolls with the
terminal's native scrollback, and an opt-in (later default-on) alt-screen mode
gated by `CLAUDE_CODE_NO_FLICKER=1` / `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT`
that uses the alternate screen buffer (like vim/htop) with a fixed input bar
pinned at the bottom and a **virtualized scrollback** (only visible messages
stay in the render tree, so memory is constant)
([#69619](https://github.com/anthropics/claude-code/issues/69619),
[blog](https://slyapustin.com/blog/claude-code-no-flicker.html)). Layout
elements: banner/mascot header, scrolling conversation feed with collapsed
tool-output blocks ("+N lines"), inline diff cards, a bottom status/spinner
line ("thinking" + elapsed time + esc-to-interrupt), and a bottom input box.
Detailed transcript / subagent view is reachable via Ctrl+R or Ctrl+O.

### 1.2 What users LOVE

- On the flicker fix landing: *"Possibly the greatest contribution to Claude
  code in months. I am rushing to my terminal to test and update."* and
  *"THANK YOU! that flickering is giving me a headache."*
  ([HN #46699072](https://news.ycombinator.com/item?id=46699072))
- The alt-screen/no-flicker mode is praised specifically for behaving like
  familiar full-screen tools (vim/htop) rather than Claude Code's older
  reprint-based mode — commenters frame this as the *correct* rendering
  substrate, just arriving very late
  ([blog](https://slyapustin.com/blog/claude-code-no-flicker.html)).

### 1.3 What users HATE

**Flicker (the single most reported visual issue in the tracker's history).**
- *"Terminal Flickering"* — [#1913](https://github.com/anthropics/claude-code/issues/1913) (duplicate-marked, June 2025).
- *"the entire terminal buffer redraws with each update of the status
  indicator, causing the screen to flash text from earlier in the session
  instead of only refreshing the status line"* —
  [#769](https://github.com/anthropics/claude-code/issues/769) (Apr 2025; linked to an upstream Ink PR, `bcherny/ink#8`, as the likely fix, never merged upstream in time).
- *"screen started to seem to scroll looping endlessly"* while running in WSL
  under Windows Terminal — same thread, user `Cheffromspace`
  ([#769](https://github.com/anthropics/claude-code/issues/769)).
- G-Sync monitors dropping from 119Hz to ~40Hz from bursty frame delivery —
  [#72405](https://github.com/anthropics/claude-code/issues/72405).
- High-rate flicker specifically correlated with Claude's active/streaming
  state in Windows Terminal — [#60440](https://github.com/anthropics/claude-code/issues/60440).
- HN, a year-plus later: *"I have not used Claude Code in a couple months.
  THEY HAVEN'T FIXED THIS YET?"* — top comment,
  [HN #46700008](https://news.ycombinator.com/item?id=46700008), 2026.
- Root-cause blame from the same thread: *"The problem is they are using the
  Ink library which clears and redraws for each update."* / *"They would have
  to switch how their TUI is rendered on their side."*
  ([HN #46700008](https://news.ycombinator.com/item?id=46700008)).
- Even after the rewrite, Anthropic's own stated number was met with
  skepticism: *"only ~1/3 of sessions see at least a flicker... after many
  months, for such a visible bug, is such a crazy thing to say."*
  ([HN #46699072](https://news.ycombinator.com/item?id=46699072)).
- A community-built proxy fix, **claude-chill**, intercepted output to
  suppress flicker independent of Anthropic — enough demand existed for a
  third party to ship a workaround
  ([HN #46699072](https://news.ycombinator.com/item?id=46699072)).
- Also spawned a competing product, **Nori CLI** ("no flicker" as its lead
  selling point), whose author attributes the root cause to Claude Code
  reprinting *"full terminal history without using alt screen mode"* on top
  of Ink ([HN #46616562](https://news.ycombinator.com/item?id=46616562)).

**Scrollback destruction / can't-scroll-while-streaming.**
- *"v2.1.89 regression: flicker-free rendering destroys terminal scrollback"*
  — the opt-in no-flicker mode shipped default-on and re-renders the whole
  banner+conversation from scratch once output exceeds ~24 rows, wiping
  scrollback each time (repro table showing banner printed 3× in one session)
  — [#41965](https://github.com/anthropics/claude-code/issues/41965), 26👍/5❤️.
  Comment thread: confirmed on Windows 11 + Windows Terminal even with the
  documented env-var workaround (*"downgrading to 2.1.87 restores normal
  behavior"*), and on macOS Terminal.app (*"Destruction of terminal scrollback
  is inconsistent... will begin evicting old lines of conversation data
  only"*).
- *"older messages in a conversation become invisible and cannot be scrolled
  back to, even before context compression kicks in... Claude Code uses the
  alternate screen buffer, which bypasses terminal scrollback entirely"* —
  [#28077](https://github.com/anthropics/claude-code/issues/28077), **73👍**
  (highest-reaction issue found in this whole survey). Follow-up comment (22👍)
  explicitly disputes the auto-triage bot marking it a duplicate of
  compaction-related issues: *"My issue is fundamentally different... The
  root cause is that Claude Code's TUI uses the terminal's alternate screen
  buffer... The terminal's scrollback-limit setting... has zero effect."*
- *"Terminal randomly scrolls to top and auto-scrolls to bottom during
  output, breaking scrollback navigation"* —
  [#34845](https://github.com/anthropics/claude-code/issues/34845), 45👍.
- *"CC Terminal display corrupted with garbled characters throughout every
  single session"* after repeated `/goal` commands, Opus 4.7 1M context —
  [#59539](https://github.com/anthropics/claude-code/issues/59539).
- *"scrolls up far away, and I struggle to scroll it down again... only a
  fresh session"* fixes it — [HN #46699072](https://news.ycombinator.com/item?id=46699072).
- tmux specifically breaks scroll routing: mouse wheel scrolls **input
  history** instead of the conversation viewport, scrollbar disappears
  entirely, `tmux set -g mouse on/off` doesn't help; same reporter notes
  *"This also affects... OpenAI Codex CLI [with] the same issue in tmux"* —
  [#38810](https://github.com/anthropics/claude-code/issues/38810).
- SSH: *"Terminal scrollback no longer works... when connected via SSH, as
  scroll events are captured by the TUI and interpreted as command history
  navigation"* — [#37387](https://github.com/anthropics/claude-code/issues/37387).
- *"scrollback not working in long sessions (alternate screen buffer)"* —
  [#42002](https://github.com/anthropics/claude-code/issues/42002).
- VS Code integrated terminal: mouse wheel scroll-up is blocked while Claude
  is thinking, scrollbar jumps back to bottom —
  [#11537](https://github.com/anthropics/claude-code/issues/11537).

**Copy/paste breakage.**
- *"Copy-paste within Claude sessions stopped working... OSC 52 messages
  appearing but the clipboard not being set"* —
  [#66192](https://github.com/anthropics/claude-code/issues/66192), 29👍.
- *"Text cannot be copied from Claude Code's output using Ctrl+Shift+C or
  right-click context menu"* — [#62699](https://github.com/anthropics/claude-code/issues/62699).
- Copy includes unwanted leading indentation/trailing spaces matching visual
  indent — [#18170](https://github.com/anthropics/claude-code/issues/18170).
- Right-click/copy stops working mid-session, temporarily fixed only by
  restarting — [#71823](https://github.com/anthropics/claude-code/issues/71823).
- *"Can no longer easily select text to copy and paste"* —
  [#61021](https://github.com/anthropics/claude-code/issues/61021), 7👍.
- Bracketed paste through SSH+tmux specifically broken when Claude Code spawns
  a child PTY (e.g. via Ctrl-G to vim): *"the way it sets up the child PTY
  doesn't correctly propagate the bracketed paste mode through the SSH + tmux
  layers"* — [#30239](https://github.com/anthropics/claude-code/issues/30239).

**Buried/unreadable approval and diff UI, light-theme contrast.**
- Plan-review code blocks render white-on-light-gray in light VS Code themes,
  fully unreadable — [#65279](https://github.com/anthropics/claude-code/issues/65279).
- Diff text invisible in macOS light terminal mode —
  [#40825](https://github.com/anthropics/claude-code/issues/40825).
- Warp light mode: question text same color as background —
  [#11371](https://github.com/anthropics/claude-code/issues/11371).
- Agent status color (orange-grey) has *"extremely poor contrast"* on light
  cyan backgrounds — [#16514](https://github.com/anthropics/claude-code/issues/16514).
- `/cost`/`/model` output white-on-white in light theme —
  [#4948](https://github.com/anthropics/claude-code/issues/4948).
- A named theme is simply broken: *"light-daltonized Theme is Unreadable"* —
  [#416](https://github.com/anthropics/claude-code/issues/416).

**Spinner-with-no-info / can't tell working vs. hung.**
- *"Claude Code hangs mid-execution with spinner spinning indefinitely"* —
  [#41683](https://github.com/anthropics/claude-code/issues/41683).
- *"static spinner, unresponsive input, ignores SIGTERM"* —
  [#20572](https://github.com/anthropics/claude-code/issues/20572).
- *"[URGENT!!!] ...hanging / freezing / stuck on heaps of prompts for
  5-20minutes or more"* — [#26224](https://github.com/anthropics/claude-code/issues/26224).
- *"Processes hang indefinitely with no timeout or progress indication"* —
  [#38258](https://github.com/anthropics/claude-code/issues/38258).
- *""Befuddling" spinner, terminal becomes completely unresponsive"* —
  [#24688](https://github.com/anthropics/claude-code/issues/24688).

**Repaint/perf architecture pains (see §3.A for the deep dive).**
- *"Persistent TUI render lag: entire-screen React model conflicts with
  keystroke responsiveness"* — full root-cause writeup arguing the whole
  screen buffer is rebuilt every frame, blocking/starving keystroke
  processing, backspace disproportionately affected —
  [#31194](https://github.com/anthropics/claude-code/issues/31194) (auto-closed
  stale, never directly answered by a maintainer).
- *"Terminal re-renders entire conversation output repeatedly during
  sequential tool calls"* — every previous response block reprinted on each
  new tool result — [#52866](https://github.com/anthropics/claude-code/issues/52866), 10👍.

### 1.4 What's DEMANDED but missing (feature requests, with reactions)

- **Native scroll-back / expand-in-place for tool output**, without losing
  cursor position, specifically to support the tmux copy-mode workflow —
  [#50313](https://github.com/anthropics/claude-code/issues/50313) (0 reactions logged but detailed, concrete design proposal).
- **Collapsible/pinned output sections** for large responses —
  [#51624](https://github.com/anthropics/claude-code/issues/51624).
- **Collapse/minimize tool output (diff views)** toggle —
  [#17043](https://github.com/anthropics/claude-code/issues/17043).
- **Configurable collapse threshold** (lines before "+N lines" folds) —
  [#12589](https://github.com/anthropics/claude-code/issues/12589),
  [#27577](https://github.com/anthropics/claude-code/issues/27577).
- **Expand All / Collapse All** buttons for diffs (desktop app) —
  [#48744](https://github.com/anthropics/claude-code/issues/48744), 4👍 (shipped 2026-04-14 per changelog reference).
- **Lock input to bottom of terminal** — *"It's a big inconvenience to have
  to scroll up and down"* — [HN #46699072](https://news.ycombinator.com/item?id=46699072).
- **Detailed transcript / subagent navigation via Ctrl+R** with per-subagent
  filtering — [#7378](https://github.com/anthropics/claude-code/issues/7378)
  (closed as duplicate of #6007 without resolution).
- **Ctrl+R conflict**: users want traditional shell-style reverse history
  search back; Claude Code repurposed the shortcut for transcript view —
  [#9270](https://github.com/anthropics/claude-code/issues/9270),
  [#2241](https://github.com/anthropics/claude-code/issues/2241),
  [#15422](https://github.com/anthropics/claude-code/issues/15422) (arrow-key
  nav inside Ctrl+R search is broken).
- **Full message/prompt search** across session history —
  [#8053](https://github.com/anthropics/claude-code/issues/8053).
- **Status bar for the Desktop app** matching CLI behavior —
  [#41456](https://github.com/anthropics/claude-code/issues/41456).
- **Customizable syntax-highlighting theme** to fix contrast for custom
  terminal color schemes — [#48636](https://github.com/anthropics/claude-code/issues/48636).

### 1.5 HORROR stories (dated)

- **v2.1.89 "flicker-free" regression (2026-04-01 reports)**: the very fix
  meant to solve flicker shipped default-on and ate scrollback, with reports
  across Windows Terminal, iTerm2, xterm.js, and Terminal.app the same day —
  [#41965](https://github.com/anthropics/claude-code/issues/41965).
- **v2.0.1 "SHOW-STOPPER"** (2025-10-01): *"Every character typed causes the
  display to scroll upward and/or status line to scroll right-wards... UI
  becomes unusable despite Claude functionality working correctly"* — marked
  Critical severity by reporter — [#8618](https://github.com/anthropics/claude-code/issues/8618).
- **Total text corruption after repeated `/goal` commands**: *"Command
  prompts... appear as random symbols... every line of assistant response...
  renders as gibberish... no readable sections"* on Opus 4.7 1M context —
  [#59539](https://github.com/anthropics/claude-code/issues/59539).
- **The flicker bug's longevity itself is the horror story**: described on HN
  as *"the single most reported issue in Claude Code's history"*, present for
  over a year before Anthropic's public rewrite post, motivating at least two
  third-party products (claude-chill, Nori CLI) built specifically to route
  around it ([blog](https://slyapustin.com/blog/claude-code-no-flicker.html),
  [HN #46616562](https://news.ycombinator.com/item?id=46616562)).
- **Full-screen "jump to bottom" overlay leaves color-block artifacts on wide
  characters** (wcwidth-unaware clipping) —
  [#56622](https://github.com/anthropics/claude-code/issues/56622) — a
  narrower but illustrative case of Unicode-width bugs in the custom
  renderer.

---

## 2. OpenAI Codex CLI (Rust, ratatui)

### 2.1 What it ships visually

Codex CLI renders via ratatui with an **inline viewport** (fixed-height
region drawn in-place with the rest of the terminal, full terminal width) —
not a full alt-screen app by default, which is the core visual/philosophical
difference from Claude Code
([ratatui docs](https://docs.rs/ratatui/latest/ratatui/enum.Viewport.html),
[PR #21450](https://github.com/openai/codex/pull/21450)). Layout: streamed
response text, a working/"shimmer" status line (`• Working (Ns • esc to
interrupt)`), inline approval widgets for patches/commands showing a
truncated diff (historically ~3 visible lines), and transcript mode via
Ctrl+T. Separately, "Codex Desktop"/"Codex App" is a distinct Electron-style
GUI surface (not the terminal CLI) — several of the flicker/UI reports found
in search results are filed against that surface rather than the ratatui CLI;
this brief separates them where the distinction was clear from the issue body.

### 2.2 What users LOVE

- Comparative praise from Claude Code's own HN flicker thread: *"Apparently
  OpenAI Codex is rust+ratatui which does not have this issue."* / *"The
  biggest strength in OpenAI's codex vs claude code is that it's written in
  Rust and smooth as butter."* / *"Literally no other CLI tool has these
  issues: opencode, codex, gemini, droid, etc."*
  ([HN #46700008](https://news.ycombinator.com/item?id=46700008)).

### 2.3 What users HATE

**Flicker exists too, but concentrated in the Desktop app, not (as clearly) the ratatui CLI.**
- *"The ui flickers a lot while codex is working"* — filed against **Codex
  App version 26.212.1823**, macOS, not the CLI —
  [#11901](https://github.com/openai/codex/issues/11901), 14👍.
- Windows Codex Desktop sidebar flicker tied to GPU acceleration —
  [#24904](https://github.com/openai/codex/issues/24904).
- macOS Codex Desktop flickers generated text during streaming —
  [#22860](https://github.com/openai/codex/issues/22860).
- Switching threads/projects causes the work area to *"violently
  flicker/shake for ~5 seconds"* — [#20788](https://github.com/openai/codex/issues/20788).
- The CLI itself is not immune: *"Regression: Codex CLI 0.133.0 hides/flickers
  text in Windows Terminal; 0.130.0 works"* —
  [#24421](https://github.com/openai/codex/issues/24421) — and *"Codex
  flickering issue on running npm build"* after sandbox access is granted —
  [#19535](https://github.com/openai/codex/issues/19535).

**Buried/truncated approval diffs — arguably Codex's sharpest visual complaint.**
- *"The 'Do you want to make these changes?' code changes prompt is
  absolutely useless... displaying only 3 lines of the code at the same time
  with no option to enlarge or fullscreen the diff widget. How TF am I
  supposed to review and approve changes if I can only read them 3 (short)
  lines at a time?"* — [#13561](https://github.com/openai/codex/issues/13561), 4👍.
- *"Patch approval diff is empty in app-server-backed TUI Ctrl+A review"* —
  the fullscreen diff review pane sometimes shows nothing at all —
  [#18122](https://github.com/openai/codex/issues/18122).
- Cannot enter transcript mode or scroll while an approval prompt is up:
  *"Transcript shortcut not working while waiting for user confirmation"* —
  combined with inability to scroll, *"makes it impossible to read the
  changes before they are made"* —
  [#22263](https://github.com/openai/codex/issues/22263).
- Approval-fatigue as a visual/interaction complaint: prompted on almost every
  command post-upgrade, "don't ask again" doesn't persist —
  [#14936](https://github.com/openai/codex/issues/14936),
  [#15205](https://github.com/openai/codex/issues/15205).

**Resize corruption.**
- *"Output width remains truncated after resizing Codex CLI window back to
  full size"* — resizing narrower then back to full leaves subsequent output
  wrapped at the old narrow width — [#5576](https://github.com/openai/codex/issues/5576), **19👍**.
- *"Terminal output formatting breaks (tables collapse, worse on resize)"* —
  column alignment degrades further with each resize —
  [#9141](https://github.com/openai/codex/issues/9141).
- *"Respect terminal width"* — [#2012](https://github.com/openai/codex/issues/2012), 16👍 (closed).
- Reflow-on-resize was patched at the scrollback level, implying prior
  behavior left already-printed scrollback shaped for the old width even
  after a later resize — [PR #18575](https://github.com/openai/codex/pull/18575).
- Narrow terminal specifically: *"Option description wrapping and hidden
  options... wraps one character per line when the terminal is narrow"* —
  [#11418](https://github.com/openai/codex/issues/11418).

**Scroll/mouse compatibility.**
- *"Mouse wheel scrolling doesn't work in legacy Windows console (conhost.exe)
  due to alternate screen buffer"* — content renders as overwrite/overlay
  with no way to scroll back — [#12457](https://github.com/openai/codex/issues/12457).
- tmux: confirmed (by a Claude Code reporter) to share the same mouse-capture
  regression as Claude Code — [#38810](https://github.com/anthropics/claude-code/issues/38810) (cross-tool note).

**Status ambiguity ("working" vs. done/hung).**
- *"Still working, but no still working / progress indication, making it
  look finished/idle"* — [#10534](https://github.com/openai/codex/issues/10534).
- *"Loading spinner not showing when starting codex with initial prompt"* —
  the `• Working (1s • esc to interrupt)` indicator silently absent —
  [#7017](https://github.com/openai/codex/issues/7017).
- Desktop-side equivalent: *"can remain stuck showing 'thinking/running' even
  after the task has completed"* — [#20754](https://github.com/openai/codex/issues/20754).
- Stale busy spinner surviving subagent completion on Linux/tmux —
  [#16905](https://github.com/openai/codex/issues/16905).

### 2.4 What's DEMANDED but missing

- Fullscreen/enlargeable diff widget for approvals (direct ask embedded in
  the #13561 complaint above — no dedicated tracking issue found separate
  from the bug report itself).
- Scrolling and transcript access **during** an open approval prompt
  ([#22263](https://github.com/openai/codex/issues/22263)).
- Persisted "don't ask again" approval memory so the UI doesn't re-prompt per
  command ([#14936](https://github.com/openai/codex/issues/14936)).
- Respect-terminal-width fixes that survive live resize, not just at launch
  ([#2012](https://github.com/openai/codex/issues/2012), 16👍 — closed but the
  narrower resize-recovery bug, #5576, reopened the underlying complaint with
  19👍).

### 2.5 HORROR stories (dated)

- *"Latest npm Codex CLI renders raw ANSI/control sequences in Windows
  Terminal"* — the TUI becomes filled with literal escape codes instead of
  formatted text, described as making the *"TUI unusable"* —
  [#23740](https://github.com/openai/codex/issues/23740).
- *"CLI TUI remains visually corrupted after stream disconnect, while
  resumed session renders normally"* — a network interruption leaves the live
  view stuck in a corrupted state though the session itself recovered —
  [#22726](https://github.com/openai/codex/issues/22726).
- *"Double Esc rewind can leave terminal rendering broken after exit"* —
  [#21345](https://github.com/openai/codex/issues/21345).
- *"Codex v0.131.0 terminal corruption after codex_apps MCP startup on
  Windows"* — [#23512](https://github.com/openai/codex/issues/23512).
- *"Truncated / corrupted CLI output with visual glitches and issues
  resuming"* — [#17484](https://github.com/openai/codex/issues/17484).

---

## 3. Cross-cutting questions

### A. Did Claude Code stay with Ink? Documented rendering-architecture pains?

No — Claude Code moved off vanilla Ink to a **custom, from-scratch renderer**,
per an Anthropic engineer's own HN comment thread
([HN #46701013](https://news.ycombinator.com/item?id=46701013)) and the
technical post-mortem
([blog](https://slyapustin.com/blog/claude-code-no-flicker.html)). Documented
pains, in the engineer's own words:

- *"Since we no longer have `<Static>` components the app re-renders much
  much more frequently with larger component trees"* — i.e., removing Ink's
  static-region optimization (the mechanism meant to separate immutable
  scrollback from the actively-updating region) was itself a source of
  repaint storms, not a fix for one.
- *"We were seeing unusual GC pauses because of having too much JSX...
  Better memoization has largely solved that."*
- *"The new renderer double buffers and blits similar cells between the front
  and back buffer to reduce memory pressure"* — i.e. they built their own
  diff/blit layer rather than relying on Ink's.
- Root architectural claim from the blog: *"terminals have no concept of
  atomic frame updates. Every escape sequence is processed immediately, so if
  you're updating the cursor position, streaming text, updating a spinner,
  and rendering the input box all at once — the terminal shows each
  intermediate state as a flash."*
- Cited historical fix attempt that never fully landed: an upstream Ink PR,
  [`bcherny/ink#8`](https://github.com/bcherny/ink/pull/8), referenced as far
  back as [#769](https://github.com/anthropics/claude-code/issues/769)
  (Apr 2025) as the likely fix for redraw-on-status-tick — the underlying
  flicker persisted through 2026, well past that PR.

Net: the "static vs. dynamic region" distinction (Ink's `<Static>` component)
is the crux — Claude Code needed to separate append-only scrollback from a
live-updating status/input region, lost that separation at some point, and
spent roughly a year rebuilding an equivalent (alt-screen + virtualized
scrollback + double-buffered diffing) from scratch.

### B. Codex's ratatui + inline viewport vs. Claude Code's feel

Direct external comparisons are sparse but consistent: Claude Code's own bug
threads volunteer Codex as the counter-example — *"Apparently OpenAI Codex is
rust+ratatui which does not have this issue"*, *"smooth as butter"*
([HN #46700008](https://news.ycombinator.com/item?id=46700008)). However,
the research here shows Codex is **not flicker-free** — it has its own
regressions (`#24421`, `#19535`), just seemingly less severe/pervasive than
Claude Code's, and concentrated more in the separate Electron Desktop app
(`#11901`, `#22860`, `#20788`, `#24904`) than the ratatui CLI itself. Codex's
sharpest complaints are structurally different from Claude Code's: less
about flicker, more about **information starvation during approval**
(3-line diff windows, #13561) and **resize-state loss** (#5576, #9141) —
i.e., ratatui's inline-viewport model avoids full-screen redraw flicker but
inherits its own class of bugs around reflow and viewport truncation.

### C. "Agent working vs. hung vs. waiting for me" — missing/buried states

Both tools show a spinner + elapsed timer as the primary "alive" signal
(Claude Code's animated status line; Codex's `• Working (Ns • esc to
interrupt)` shimmer), and both have extensive bug histories of that signal
lying: Claude Code spinners that keep animating while the process is
genuinely hung with SIGTERM ignored (`#20572`), 5–20 minute stalls with no
token-count movement (`#26224`); Codex spinners that vanish even though work
continues (`#7017`, `#10534`) or persist after work is actually done
(`#20754`, `#16905`). Neither tool has a documented secondary liveness signal
(e.g., a heartbeat distinct from the decorative spinner) that surfaced in
this search — the complaint pattern in both trackers is "the only state
indicator is cosmetic and it desyncs from ground truth."

### D. Long-session navigation

Claude Code has Ctrl+R "detailed transcript" and Ctrl+O, but this collides
with users' expectation of shell-style reverse-history search bound to the
same chord (`#9270`, `#2241`, `#15422` — arrow-key nav broken inside it), and
the underlying transcript itself is capped by the alt-screen's virtualized
scrollback (`#28077`, 73👍 — the single highest-reaction issue in this
survey). A subagent-aware jump/filter feature was requested (`#7378`) and
closed as a duplicate without resolution. Full-conversation search was
requested (`#8053`) and not shipped per search results. Codex has Ctrl+T
transcript mode, but it is explicitly disabled at the exact moment users need
it most — while an approval prompt is open (`#22263`).

### E. 80-col / light themes / tmux+SSH compatibility

Consistently the worst-served configurations for Claude Code: narrow-terminal
wrapping issues appear repeatedly in Codex too (`#11418` — option text
wrapping one character per line at narrow widths; `#9141`/`#5576` — resize
breaks table/width state). Light themes are a distinct, large complaint
cluster unique to Claude Code in this search (7+ separate issues,
`#11371` `#40825` `#16514` `#65279` `#4948` `#416` `#6597`) — no comparable
light-theme complaint volume surfaced for Codex, though this may reflect
search-term bias rather than an actual absence. tmux+SSH is bad for both:
Claude Code's mouse-capture-steals-scroll bug (`#38810`) explicitly names
Codex CLI as sharing the exact same defect ("This also affects other similar
TUI tools (e.g. OpenAI Codex CLI has the same issue in tmux)"), and Codex has
its own legacy-Windows-console mouse-scroll failure under the alt-screen
buffer (`#12457`). Bracketed-paste-through-SSH+tmux is a Claude-Code-specific
three-way interaction bug (`#30239`).

---

## Sources index (all URLs cited above)

GitHub — anthropics/claude-code: #1913, #769, #52866, #72405, #60435, #45966,
#41965, #60440, #36476, #69619, #34845, #51393, #42002, #28077, #11537,
#37387, #43643, #63545, #59093, #38810, #66192, #62699, #48247, #18170,
#72617, #71823, #61021, #64915, #29281, #69704, #7378, #15422, #9270, #2241,
#65858, #8053, #2724, #24751, #30239, #29479, #62350, #8762, #13613, #29937,
#76175, #37345, #6072, #11371, #40825, #16514, #65279, #48636, #4948,
#26326, #6597, #416, #13523, #41683, #54297, #24999, #26292, #43573,
#25979, #20572, #26224, #38258, #24688, #31194, #50313, #51624, #17043,
#12589, #27577, #48744, #43305, #41456, #25776, #61280, #69403, #29388,
#37584, #33932, #11411, #56622, #8618, #59539, #59239, #14750, #46411,
#59163, #3045, #52235.

GitHub — openai/codex: #24904, #11901, #22860, #19535, #20788, #17035,
#19677, #20850, #18463, #9141, #5576, #2012, #18575 (PR), #22799, #14323,
#11418, #25010, #2857, #17213, #22263, #14936, #4152, #18122, #2998, #11857,
#12457, #15205, #13561, #11915, #21450 (PR), #10534, #11046, #19437, #20754,
#7017, #19803, #10701 (PR), #20564 (PR), #7150, #16905, #24421, #22726,
#17484, #23740, #21345, #23512.

Hacker News: [46699072](https://news.ycombinator.com/item?id=46699072),
[46700008](https://news.ycombinator.com/item?id=46700008),
[46616562](https://news.ycombinator.com/item?id=46616562),
[46701013](https://news.ycombinator.com/item?id=46701013).

Blog: [CLAUDE_CODE_NO_FLICKER: The Fix a Year in the Making](https://slyapustin.com/blog/claude-code-no-flicker.html).

Other: [ratatui Viewport docs](https://docs.rs/ratatui/latest/ratatui/enum.Viewport.html),
[bcherny/ink#8](https://github.com/bcherny/ink/pull/8).
