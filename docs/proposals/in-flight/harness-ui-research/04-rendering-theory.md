# Rendering Theory: What the TUI Cohort Teaches About Streaming Chat

Forum-first survey of Ink, Ratatui, Bubble Tea, Textual, and terminal-protocol
theory (inline vs alt-screen, OSC 133, kitty OSC 66, synchronized output mode
2026, DECSTBM scroll regions), aimed at one design question: **an Elixir TUI
framework with a retained-mode component tree and its own layout engine is
building a streaming agent-harness chat surface — what does the cohort's
documented pain teach?**

Sources are forum/primary where available: GitHub issues (fetched via `gh
api` where a WebFetch summary needed verification), maintainer writeups,
HN threads, framework docs. Several claims below were cross-checked against
raw issue JSON rather than trusted from a single summarized fetch, because
a couple of early WebFetch summaries contained suspiciously precise
numbers — the important ones (Claude Code issue #37283, the
`CLAUDE_CODE_NO_FLICKER` blog post) were re-fetched raw and confirmed
genuine.

---

## A. Documented failure modes, per framework

### Ink (React reconciler → ANSI) — Claude Code, Gemini CLI, Qwen Code, OpenCode, Amp

Root cause, confirmed at the code level (`test-ink-flickering/INK-ANALYSIS.md`,
cross-referencing Ink's own `reconciler.ts`, `ink.tsx`, `log-update.ts`):

- **Every commit triggers a full redraw.** `resetAfterCommit()` fires
  unconditionally after *any* React commit (prop or state change) and calls
  `rootNode.onRender()` — there is no subtree-level dirty tracking. A single
  timer tick walks the entire component tree.
- **Full virtual buffer per frame.** Each render allocates a complete 2D
  character array for the whole terminal (80×60 = 4,800 cells) even when one
  status line changed.
- **Erase-and-redraw, not diff-and-patch.** `log-update.ts` does
  `stream.write(ansiEscapes.eraseLines(previousLineCount) + output)` —
  it erases N previous lines and rewrites the full block every time. This
  erase step is the visible flicker; it is not a corner case, it is the
  steady-state render path. An HN commenter tracing the actual Ink source
  independently confirmed this: Ink's `clearTerminal`/`eraseLines` calls are
  what flicker, "even the eraseLines here will cause flicker" — and pushed
  back hard on Anthropic's "16ms game engine, terminals have no atomic
  frames" framing as an after-the-fact rationalization for what is really an
  unconditional-clear bug ([HN #46850188](https://news.ycombinator.com/item?id=46850188)).
- **`<Static>` is append-only and doesn't scale.** For streaming chat, the
  natural pattern is "finished turns go into `<Static>`, the in-flight turn
  re-renders." But Qwen Code's own design doc documents that at ~1000 turns,
  Ink's default behavior still re-renders the *entire* history through
  `<Static>` on each state change (1000 `HistoryItemDisplay` renders + Yoga
  layout passes per keystroke), causing observable flicker/lag/scroll storms
  ([qwen-code virtual-viewport design doc](https://qwenlm.github.io/qwen-code-docs/en/design/virtual-viewport/README/)).
- **32ms throttle is a band-aid, not a fix.** Ink throttles renders to
  ~30fps max; this reduces *frequency* of the erase-redraw, not its
  visibility or cost.
- **Yoga (flexbox) recompute couples unrelated components.** Because layout
  is global, changing one leaf can shift others; there's no cheap way to
  know a subtree's change didn't propagate, which is part of why partial
  redraw is hard to bolt onto Ink after the fact.

Real-world blast radius, per Anthropic's own year-long incident (see §C):
GitHub issues #1913 (314 upvotes), #769 (291 upvotes / 298 comments, closed
"completed" in May 2025, then downvoted 33 times because it recurred), #3648
(282 upvotes, "terminal scrolling uncontrollably"), plus #10794/#9158/#10619/
#16614/#18708 as duplicates — over 1,000 upvotes in aggregate. One user
measured 4,000–6,700 scroll events/sec; VS Code's and Cursor's integrated
terminals froze/crashed after 10–20 minutes; photosensitive users flagged it
as an accessibility issue. A third-party fix (`claude-chill`, a Rust proxy
that filters Claude Code's output to only real changes) got HN traction
before Anthropic's own fix shipped.

### Ratatui (immediate mode) — Codex CLI

- **Immediate mode means "redraw everything, every frame, by design."**
  Official docs: "you 'draw' your UI from scratch in every frame based on
  the current application state" and "the onus of triggering rendering lies
  on the programmer" ([ratatui.rs/concepts/rendering](https://ratatui.rs/concepts/rendering/)).
  This is presented as a feature (no UI/state sync bugs possible) not a bug,
  and Ratatui does do cell-level diffing before writing bytes — the "redraw"
  is logical, not literally re-emitting every cell every frame. Codex's own
  docs describe this explicitly: "every frame redraws all visible widgets
  from scratch using intermediate buffers — gives sub-millisecond response
  times with no retained state to go stale" (DeepWiki/Zread codex-rs TUI
  writeups).
- **Inline viewport is the leaky abstraction.** Ratatui's `Viewport::Inline`
  mode (draw into a fixed-height region above which output scrolls into
  native scrollback) has multiple open/historical issues:
  - `insert_lines_before` / `insert_before` — inserting scrolled content
    above a live inline viewport without flicker needed a dedicated API
    ([#1426](https://github.com/ratatui/ratatui/issues/1426)).
  - Resize handling for inline viewports is documented as broken/incomplete
    across two issues ([#984](https://github.com/ratatui/ratatui/issues/984),
    [#2086](https://github.com/ratatui/ratatui/issues/2086)) — the inline
    viewport doesn't reflow cleanly when the terminal width changes.
  - Frame cutoff/corruption when the app exits mid-frame in an inline+termion
    setup ([#954](https://github.com/ratatui/ratatui/issues/954)).
  - Codex itself shipped a resize-reflow fix
    ([openai/codex PR #18575](https://github.com/openai/codex/pull/18575))
    and has an open scrollback-corruption report specific to mobile SSH
    clients (Termius) ([#24235](https://github.com/openai/codex/issues/24235)),
    plus a `--no-alt-screen` mode where Zellij scrollback interaction is
    "still broken" ([#10331](https://github.com/openai/codex/issues/10331))
    and a separate report that mouse/scroll in Zellij can't reach earlier
    TUI conversation turns when alt-screen is active
    ([#2836](https://github.com/openai/codex/issues/2836)).
- Net: Ratatui's failure mode isn't reconciler flicker (immediate mode +
  diffed writes avoids that class entirely) — it's **viewport-boundary
  bugs**: resize reflow, inline/scrollback handoff, and multiplexer
  (tmux/Zellij) interaction at the edges of the inline region.

### Bubble Tea (Elm architecture) — opencode, Crush

- v1's renderer and Lip Gloss "would often fight over i/o" — no single
  owner of terminal writes, which is the structural reason v2 exists
  ([v2 discussion #1374](https://github.com/charmbracelet/bubbletea/discussions/1374),
  [charm.land/blog/v2](https://charm.land/blog/v2/)).
- v2 ships the **Cursed Renderer**, an ncurses-algorithm rewrite, explicitly
  optimized for bandwidth over SSH (Wish/remote TUI use case gets "orders of
  magnitude" lower bandwidth) — i.e., the redesign target was *diff quality*,
  not just local flicker.
  scroll regions: the renderer's `insertTop` uses `changeScrollingRegion`
  (DECSTBM) to scroll new lines in above the live view, then resets the
  region to full-height after — this is the same DECSTBM technique covered
  in §C, used specifically to avoid a full-screen repaint when new history
  lines arrive.
- v2 also centralizes all terminal I/O inside Bubble Tea itself (Lip Gloss
  becomes a pure styling library with no I/O), removing the write-ownership
  race that caused v1's artifacts.
- No public postmortem was found quantifying v1 flicker/bug counts the way
  Anthropic's was; the failure mode is inferred from the "what changed and
  why" framing of the v2 docs rather than a dedicated incident writeup.

### Textual (Python, CSS-like) — general TUI, not agent-chat-specific in the found sources

- Documented perf story is a *positive* architecture writeup, not an
  incident: the Compositor treats content as **segments** (string + style),
  not characters or pixels, sidestepping variable-width glyph complexity
  entirely, and a **spatial map** (grid-indexed, ~100×20-cell tiles) makes
  "which widgets are visible" queries scale with screen area, not widget
  count ([Textual: Algorithms for high-performance terminal apps](https://textual.textualize.io/blog/2024/12/12/algorithms-for-high-performance-terminal-apps/)).
- Real bottlenecks are narrower and component-specific, not architectural:
  `DataTable` render cost is O(m²) in column count due to redundant
  `console.options.update` calls per cell
  ([discussion #5953](https://github.com/Textualize/textual/discussions/5953));
  widget-level input testing is reported as ~15s for typing one short string,
  traced to polling/thread-coordination in the test harness, not the render
  path itself ([issue #5065](https://github.com/Textualize/textual/issues/5065)).
- Lesson for Raxol: Textual is the cohort's example that **choosing the
  right diffing primitive (segments, not cells or pixels) is more load-bearing
  than clever algorithms on top of the wrong primitive** — directly
  transferable to a Raxol renderer that already works at the cell/style-run
  level.

### Failure-mode table

| Framework | Primary documented failure | Where it bites | Fix direction taken |
|---|---|---|---|
| Ink | Unconditional full-tree redraw + erase-and-rewrite on every commit; `<Static>` re-renders entire history | Streaming chat with 100s–1000s of turns; multi-pane tmux | Custom renderer rewrite (Claude Code), virtualized viewport port from gemini-cli (Qwen Code), alt-screen escape hatch (`CLAUDE_CODE_NO_FLICKER`) |
| Ratatui | Inline-viewport edge bugs: resize reflow, insert-before-viewport flicker, multiplexer scrollback interaction | Resizing while streaming; tmux/Zellij + inline mode | Dedicated `insert_before` API, per-issue resize-reflow patches (Codex) |
| Bubble Tea | v1 renderer/Lip Gloss shared-I/O races; scroll-region misuse | SSH/remote (Wish) bandwidth; any scrolling history | v2 "Cursed Renderer" rewrite, centralized I/O ownership |
| Textual | Non-architectural: O(m²) per-widget-type bottlenecks (DataTable), test-harness slowness | Wide tables; widget test suites | Per-component caching (memoize row renderables) |

---

## B. Inline (scrollback-native) vs alt-screen — the actual tradeoffs, and who regretted what

This is the most contested axis in the cohort, and unlike the failure-mode
survey it produced an explicit comparative writeup: Peter Steinberger's
"[The Signature Flicker](https://steipete.me/posts/2025/signature-flicker)"
compares Claude Code, Codex, Gemini CLI, Amp, OpenCode, and `pi` head to head
on exactly this axis.

**Documented tradeoffs, both directions:**

- *For alt-screen*: simpler to implement correctly (no interleaving with
  scrollback state you don't control), gives full mouse support (click to
  position cursor, click to expand/collapse tool output, wheel-scroll),
  keyboard paging (PgUp/PgDn, Ctrl+Home/End), and can synthesize its own
  in-app "transcript mode" with search (Claude Code's `Ctrl+O` after
  `CLAUDE_CODE_NO_FLICKER`).
- *Against alt-screen*: breaks native text selection and terminal search;
  scrollback is either entirely inaccessible or only available through an
  app-reimplemented scroll widget, which does not support the terminal's own
  search/copy. Multiple independent bug reports treat this as a regression,
  not a preference: Gemini CLI's alt-screen mode was rolled back after users
  rejected the non-native selection/copy workflow (per Steinberger's
  comparison); a `cmux` feature request explicitly asks for alt-screen
  output to be preserved to scrollback "like iTerm2" after the fact
  ([manaflow-ai/cmux #2334](https://github.com/manaflow-ai/cmux/issues/2334));
  Codex users in Zellij report that alt-screen (or `--no-alt-screen` still
  doing a full-buffer redraw) blocks reaching earlier turns via
  mouse/pane-scroll ([openai/codex #2836](https://github.com/openai/codex/issues/2836),
  [#10331](https://github.com/openai/codex/issues/10331)).
- *For inline*: preserves every terminal-native feature (search, select,
  copy, scrollback across sessions, works uniformly over SSH without a
  custom scroll roundtrip). Cited as the reason to prefer it even when it's
  harder to get flicker-free: "terminal scrollback benefits outweigh sidebar
  benefits in most cases... TUI programs with custom scroll widgets require
  roundtrips for each scroll unit over SSH" ([tilde.town "On TUIs"](https://tilde.town/~dzwdz/blog/tui.html)).
- *Against inline*: much harder to avoid flicker (must never touch
  already-scrolled-off rows, must never redraw more than the live region),
  and resize reflow of a growing scrollback is unsolved in general (see §E).

**Where the cohort actually landed, with attribution:**

- Claude Code: inline by default; shipped `CLAUDE_CODE_NO_FLICKER=1` in
  v2.1.88 (2026-03-30) as an **opt-in escape hatch to alt-screen**, explicitly
  described by its author as "the nuclear option" — a concession after a
  year of inline-mode patching (differential renderer v2.0.72, TypedArray
  GC fixes, tmux/VS Code synchronized-output upstream patches) failed to
  fully kill flicker. Confirmed via raw fetch of the blog HTML and the
  underlying GitHub issue JSON, not just a summarized fetch.
- Codex CLI: inline via Ratatui's `Viewport::Inline`, "sometimes overwrites
  text but retains terminal feel" per Steinberger's comparison — regressions
  are viewport-boundary bugs (§A), not a rejection of inline as a strategy.
- Gemini CLI: tried alt-screen, rolled it back — a documented regret in the
  alt-screen direction.
- Amp: started on Ink (inline), struggled, moved to alt-screen — a documented
  regret in the inline direction (gave up on making inline flicker-free).
- OpenCode: alt-screen (TypeScript/Zig hybrid renderer) — reported terminal
  compatibility issues and "unusual scrolling behavior," an open, not fully
  resolved, regret.
- `pi`: inline with fine-grained differential rendering — called out by
  Steinberger as the "industry gold standard combining smoothness with
  native features," i.e. proof inline-without-flicker is achievable, not
  just theoretically preferable. But `pi`'s own issue tracker shows the
  cost of that choice: no way to keep the input/footer anchored while
  scrolling history, because "pi's TUI uses a forward-growing line buffer
  written to stdout... there are no fixed regions" — an open feature request
  to adopt DECSTBM scroll regions specifically to fix this
  ([earendil-works/pi #1891](https://github.com/earendil-works/pi/issues/1891),
  mirrored at [badlogic/pi-mono #1891](https://github.com/badlogic/pi-mono/issues/1891)),
  plus a related ask for a scroll-lock/reading mode during active streaming
  ([#4679](https://github.com/earendil-works/pi/issues/4679)) and Android/Termux
  regressions where scrolling during streaming doesn't work at all
  ([discussion #4575](https://github.com/earendil-works/pi/discussions/4575)).

**Verdict for the brief:** there is no consensus winner. The cohort's revealed
preference, weighted by who shipped and stuck with which choice, favors
**inline + fine-grained diffing** when it can be made to work (Codex, `pi`),
with alt-screen as the fallback when the team runs out of engineering budget
to make inline flicker-free (Claude Code's `NO_FLICKER` escape hatch, Amp).
Every alt-screen adopter has an open issue asking for scrollback-native
behavior back in some form; no inline adopter has an issue asking to switch
to alt-screen. That asymmetry is the strongest signal in this survey.

---

## C. Streaming text + stable chrome: technique catalog

| Technique | Used by | What it buys | Documented complaint / praise |
|---|---|---|---|
| **Bottom-anchored inline viewport + printed history** (`Viewport::Inline`, draw a fixed-height footer region, let finished content scroll into native scrollback above it) | Codex CLI (Ratatui) | Sub-ms redraw of the live region only; history is real terminal scrollback (searchable, copyable) | Praised for feel; documented failure at the *boundary* — resize reflow (#18575, #2086, #984), insert-before-viewport ordering (#1426) |
| **Ink `<Static>`** (append-only component, meant to "print once and forget") | Ink-based CLIs (Claude Code pre-rewrite, Gemini CLI, Qwen Code, OpenCode) | Simple mental model: finished turns never re-render | Doesn't scale — re-renders full history on any state change unless the app builds its own virtualization on top (Qwen Code's port of gemini-cli's `VirtualizedList`) |
| **Custom differential/cell-diffing renderer** (replace Ink's erase-redraw with typed-array double buffering + cell-level diff + escape-sequence merge) | Claude Code (post-Ink-rewrite v2.0.10+), `pi` | Removes the erase-and-redraw flicker source at the root; keeps inline mode viable | This is the option Claude Code spent a year on before also adding the alt-screen escape hatch — expensive to get fully right (spinner jitter, blank-after-idle, input-disappears-after-submit were all separate follow-up bugs in v2.1.19–v2.1.83) |
| **DECSTBM scroll-region pinning** (set a scroll region excluding N bottom/top rows so history scrolls without disturbing a pinned status bar/footer) | Bubble Tea v2 `insertTop` (used to scroll new lines in above the live view without repainting the whole screen); vim/tmux status bars; the `vibe-local` project's explicit AI-output streaming layout (output scrolls in the upper region, 3-row footer fixed) | Native terminal scrolling does the work — cheapest possible "pinned chrome" technique, no app-side redraw of scrolled content at all | Requested but *not yet implemented* by `pi` specifically to solve the anchored-input-during-scroll problem (#1891) — i.e. a framework can ship for a long time inline without this and only hit the wall when users want to scroll history while composing |
| **Synchronized-output framing (mode 2026)** (wrap a frame's writes in `\e[?2026h ... \e[?2026l` so the terminal buffers and flushes atomically) | Proposed fix for Claude Code's tmux flicker (#37283, closed "not planned" — cosmetic, not implemented); native support already in Kitty/Alacritty/WezTerm/foot/Windows Terminal/iTerm2, tmux ≥3.4 passthrough | Eliminates *visible* half-painted frames regardless of how many escape sequences a render emits — orthogonal to whether you diff or full-redraw | Confirms the earlier full-redraw approach (Ink, and Claude Code pre-rewrite) could have been made non-flickering without a renderer rewrite at all, *if* the emitter wrapped writes in 2026 — the HN thread's skepticism (§A) argues this, not the "16ms game engine" framing, is the real story |
| **Full alt-screen with app-owned scrollback** | `CLAUDE_CODE_NO_FLICKER=1`, OpenCode, (rolled back) Gemini CLI | Total control; simplest to implement without flicker | Sacrifices native select/search/copy; every adopter has an open ask to get some scrollback-native behavior back (§B) |

Net picture for C: the cohort converges on **diff-at-the-right-granularity
plus a pinned region**, with synchronized-output as underused insurance.
Nobody has both (a) inline scrollback-native history, (b) a truly anchored
input/footer via scroll regions, and (c) synchronized-output framing, in one
shipped system — `pi` has (a) and wants (b); Codex has (a)-ish via
`Viewport::Inline` but not real DECSTBM pinning; Bubble Tea has the DECSTBM
mechanism but as an internal scrolling implementation detail, not exposed
for app-level "pin the composer" use. That combination is a documented,
currently-unfilled gap in the cohort, not a solved problem to copy.

---

## D. OSC 133 semantic zones: adoption state and answer to "is this the standards-track answer to command blocks?"

- **Protocol**: OSC 133;A/B/C/D marks prompt-start, prompt-end/input-start,
  command-execution-start, command-end(+exit code) — the "FinalTerm shell
  integration" convention, now also documented at
  [Contour](https://contour-terminal.org/vt-extensions/osc-133-shell-integration/),
  [Ghostty](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking),
  and [Otty](https://docs.otty.sh/vt/osc/osc-133) as terminal-side
  implementations.
- **Terminal support**: iTerm2, WezTerm, Kitty, VS Code, Windows Terminal,
  Ghostty, Contour, Otty all implement the terminal side. **tmux does not
  natively re-emit it** — there's a multi-year-old open feature request to
  forward OSC 133 to the outer terminal ([tmux #3064](https://github.com/tmux/tmux/issues/3064),
  [#5237](https://github.com/tmux/tmux/issues/5237)) — meaning any agent CLI
  run inside tmux loses prompt-jump/collapse features today regardless of
  whether the CLI itself emits the sequences.
- **What UIs do with it**: jump-to-previous/next-prompt navigation, command
  duration display, exit-status coloring, and **output folding/collapse** —
  i.e. exactly the "collapsible block" primitive the harness needs, but
  scoped to *shell command* blocks, not arbitrary agent-turn or tool-call
  blocks.
- **Agent-CLI adoption is nascent, not settled**: this is a live gap, not a
  finished standard. Open asks exist on both ends — Claude Code
  ([anthropics/claude-code #32635](https://github.com/anthropics/claude-code/issues/32635))
  and GitHub Copilot CLI
  ([github/copilot-cli #2572](https://github.com/github/copilot-cli/issues/2572))
  both have open issues asking to *emit* OSC 133;C/D around agent turns so
  host terminals can jump/notify. Separately, Warp has built its own
  higher-level protocol (OSC 777) that Claude Code, Gemini CLI, and OpenCode
  already emit to signal turn-completion with a JSON payload, which Warp
  routes into a sidebar — a proprietary superset of what OSC 133 gives you,
  shipping *ahead* of OSC 133 agent-turn adoption.
- **Answer to D**: OSC 133 is the standards-track answer for **shell
  command blocks** (prompt/command/output/exit-code), and is reasonably
  mature there across terminal emulators. It is **not yet** the standards-
  track answer for **agent-turn or tool-call blocks** in a chat-style
  harness — that layer is still being invented ad hoc (Warp's OSC 777,
  various open feature requests to reuse OSC 133;C/D for agent turns). A
  harness that wants terminal-native jump/collapse for its own blocks (as
  opposed to the shell commands it might spawn) cannot lean on OSC 133 alone
  today; it would either need to emit OSC 133 opportunistically for actual
  shell executions it runs and build its own in-app equivalent for agent/
  tool blocks, or bet on wherever Warp's OSC 777-style convention (or a
  successor) standardizes.

---

## E. Resize + reflow of already-printed history

- **The general failure mode is well-documented and not fully solved by
  anyone in the cohort.** Symptoms cataloged across multiple projects:
  layout tearing/misalignment, "ghost columns" of stale-width wrapped text
  left behind after resize, blank-line accumulation, and — the worst case —
  every intermediate width during a drag-resize getting written as a full
  new frame into scrollback, flooding it with near-duplicate frames at each
  width ("hermes-agent" reports, [#25418](https://github.com/NousResearch/hermes-agent/issues/25418),
  [#17975](https://github.com/NousResearch/hermes-agent/issues/17975); Claude
  Code [#49086](https://github.com/anthropics/claude-code/issues/49086)
  "repeated banner/content duplication... per-frame redraw leak" and
  [#51828](https://github.com/anthropics/claude-code/issues/51828) "scrollback
  duplication on terminal resize" still open in 2.1.116).
- **Root-cause pattern, per a Claude Code issue analysis**: a TUI that
  redraws on SIGWINCH by writing the new frame directly into the *normal*
  scrollback buffer, without having isolated itself via the alternate
  screen first, corrupts scrollback on every resize — "well-behaved
  fullscreen TUI apps use the alternate screen buffer to isolate redraws
  from scrollback." This is a second, independent argument in alt-screen's
  favor beyond flicker (§B): **inline mode makes resize-safety strictly
  harder**, because there is no clean boundary to redraw within.
- **Who handles it acceptably**: Windows Terminal implements real
  "resize-with-reflow" (reflows wrapped lines to the new width rather than
  truncating) as a first-class terminal feature
  ([microsoft/terminal #4200](https://github.com/microsoft/terminal/issues/4200),
  [PR #4354](https://github.com/microsoft/terminal/pull/4354) "don't remove
  lines from scrollback on resize") — i.e. the most robust answer found is
  **push reflow down into the terminal emulator**, not the application.
  Codex CLI ships an app-level partial fix
  ([PR #18575](https://github.com/openai/codex/pull/18575), "reflow
  scrollback on resize") that clears stale pending history lines on resize
  with a configurable max-row limit, rather than re-emitting old-width wrapped
  output.
- **Accepted answer for an inline/scrollback-native design**: there isn't
  a clean one. The two real strategies in the wild are (1) alt-screen, which
  sidesteps the problem by not touching real scrollback at all, or (2) accept
  that already-scrolled-off history is frozen at its original width forever
  and only reflow the live viewport — which is what a resize-safe inline
  design has to settle for, because you cannot rewrite bytes the terminal
  has already scrolled away. No cohort member has solved "reflow scrollback
  the app already printed" without either owning the whole screen (alt-
  screen) or relying on the terminal emulator's own reflow (Windows
  Terminal-style, which is emulator-specific and not something an app can
  assume).

---

## F. Perceptual prominence (dimming, focus contrast, attention tiers) in TUIs — prior art?

**Answer: genuinely thin to empty in the cohort surveyed.** Two distinct,
non-overlapping things showed up under this search, neither of which is
what the design question is really asking:

1. **Generic dim-for-metadata convention** — real but shallow: TUI design
   guides describe "metadata in dim + muted foreground," "~80% of content in
   default foreground, headers bold, metadata dimmed," and layered
   background-lightness steps (~5–8% per layer) for depth. This is static,
   role-based dimming (this *kind* of text is always dim), not
   attention/recency-driven dimming (this *specific* content is dim *because*
   it scrolled out of focus or because a newer turn arrived).
2. **NLP "salient history attention"** — a real research area, but it's
   about which *tokens* a model attends to across dialogue turns for
   language understanding, not about what a human's eye should see rendered
   dimmer on screen. Different domain entirely; not transferable prior art
   for a rendering layer.

No framework in the cohort (Ink, Ratatui, Bubble Tea, Textual) or any
agent-CLI examined (Claude Code, Codex, Gemini CLI, OpenCode, Amp, `pi`,
Warp) has a documented feature, issue, or writeup describing **recency- or
focus-driven perceptual-tier rendering of chat history** — e.g. "the last N
turns render at full contrast, older turns progressively dim," or "the
in-focus panel gets full saturation, background panels desaturate." The
closest adjacent, and still not quite it, is `pi`'s open request for a
"scroll lock / reading mode during active agent output" (#4679) — that's an
*interaction-mode* toggle (freeze auto-scroll while reading), not a
perceptual-contrast technique.

This is a real, empty spot in the cohort — not a search miss. If Raxol
ships attention-tiered dimming for its harness chat surface (fading
completed turns, keeping the active/streaming turn at full salience), it
would be ahead of the documented cohort, not catching up to it. Given
Raxol's own design-science work already has a salience/H-K tier color model
(see project memory: darcula-fixture salience solver), this is a plausible
place to originate rather than borrow, and worth flagging as differentiator
material rather than a research gap to keep chasing in more forums.

---

## Sources

- Claude Code / Ink flicker incident: [Sergey Lyapustin, "CLAUDE_CODE_NO_FLICKER: The Fix a Year in the Making"](https://slyapustin.com/blog/claude-code-no-flicker.html) (raw HTML fetched and verified); GitHub issue JSON for [anthropics/claude-code#37283](https://github.com/anthropics/claude-code/issues/37283) (fetched via `gh api`, closed `not_planned`); [#1913](https://github.com/anthropics/claude-code/issues/1913), [#769](https://github.com/anthropics/claude-code/issues/769), [#3648](https://github.com/anthropics/claude-code/issues/3648), [#49086](https://github.com/anthropics/claude-code/issues/49086), [#51828](https://github.com/anthropics/claude-code/issues/51828), [#32635](https://github.com/anthropics/claude-code/issues/32635)
- Ink internals: [test-ink-flickering/INK-ANALYSIS.md](https://github.com/atxtechbro/test-ink-flickering/blob/main/INK-ANALYSIS.md); [vadimdemedes/ink#359](https://github.com/vadimdemedes/ink/issues/359); [ink/src/reconciler.ts](https://github.com/vadimdemedes/ink/blob/master/src/reconciler.ts)
- Qwen Code virtual viewport: [qwenlm.github.io design doc](https://qwenlm.github.io/qwen-code-docs/en/design/virtual-viewport/README/)
- HN discussion (raw, via Algolia API): [item 46850188](https://news.ycombinator.com/item?id=46850188) — thread tracing Ink's `clearTerminal`/`eraseLines` as the literal flicker source, disputing the "game engine" framing
- Peter Steinberger, ["The Signature Flicker"](https://steipete.me/posts/2025/signature-flicker) — cross-tool comparison (Claude Code, Codex, Gemini CLI, Amp, OpenCode, `pi`)
- Ratatui: [ratatui.rs/concepts/rendering](https://ratatui.rs/concepts/rendering/); inline viewport issues [#1426](https://github.com/ratatui/ratatui/issues/1426), [#954](https://github.com/ratatui/ratatui/issues/954), [#984](https://github.com/ratatui/ratatui/issues/984), [#2086](https://github.com/ratatui/ratatui/issues/2086)
- Codex CLI: [DeepWiki TUI overview](https://deepwiki.com/openai/codex/4.1-terminal-user-interface-(tui)); resize fix [PR #18575](https://github.com/openai/codex/pull/18575); [#24235](https://github.com/openai/codex/issues/24235), [#2836](https://github.com/openai/codex/issues/2836), [#10331](https://github.com/openai/codex/issues/10331)
- Bubble Tea v2: [discussion #1374](https://github.com/charmbracelet/bubbletea/discussions/1374); [charm.land/blog/v2](https://charm.land/blog/v2/); [renderer.go](https://github.com/charmbracelet/bubbletea/blob/v0.12.4/renderer.go)
- Textual: ["Algorithms for high-performance terminal apps"](https://textual.textualize.io/blog/2024/12/12/algorithms-for-high-performance-terminal-apps/); [discussion #5953](https://github.com/Textualize/textual/discussions/5953); [issue #5065](https://github.com/Textualize/textual/issues/5065)
- Inline vs alt-screen: [manaflow-ai/cmux#2334](https://github.com/manaflow-ai/cmux/issues/2334); [tilde.town "On TUIs"](https://tilde.town/~dzwdz/blog/tui.html); `pi` anchored-input [earendil-works/pi#1891](https://github.com/earendil-works/pi/issues/1891) / [badlogic/pi-mono#1891](https://github.com/badlogic/pi-mono/issues/1891); [#4679](https://github.com/earendil-works/pi/issues/4679); [discussion #4575](https://github.com/earendil-works/pi/discussions/4575)
- OSC 133: [Contour docs](https://contour-terminal.org/vt-extensions/osc-133-shell-integration/); [Ghostty DeepWiki](https://deepwiki.com/ghostty-org/ghostty/9.3-osc-133-prompt-marking); [Otty docs](https://docs.otty.sh/vt/osc/osc-133); [tmux#3064](https://github.com/tmux/tmux/issues/3064), [tmux#5237](https://github.com/tmux/tmux/issues/5237); [github/copilot-cli#2572](https://github.com/github/copilot-cli/issues/2572); Warp OSC 777 reverse-engineering write-up (Yiğit Konur)
- kitty text-sizing protocol (OSC 66): [sw.kovidgoyal.net spec](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/); [kovidgoyal/kitty#8226](https://github.com/kovidgoyal/kitty/issues/8226); [ghostty-org/ghostty#10333](https://github.com/ghostty-org/ghostty/issues/10333)
- Synchronized output (mode 2026): [WezTerm escape sequences doc](https://wezterm.org/escape-sequences.html); [charmbracelet/bubbletea#850](https://github.com/charmbracelet/bubbletea/issues/850); [tmux PR #4744](https://github.com/tmux/tmux/pull/4744); [gist: Terminal Spec — Synchronized Output](https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036)
- Resize/reflow: [microsoft/terminal#4200](https://github.com/microsoft/terminal/issues/4200), [PR #4354](https://github.com/microsoft/terminal/pull/4354); [NousResearch/hermes-agent#25418](https://github.com/NousResearch/hermes-agent/issues/25418), [#17975](https://github.com/NousResearch/hermes-agent/issues/17975)
- DECSTBM: [Ghostty DECSTBM docs](https://ghostty.org/docs/vt/csi/decstbm); vibe-local project (streaming AI output with DECSTBM-pinned footer)
