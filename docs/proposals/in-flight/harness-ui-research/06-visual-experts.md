# 06 — Visual Domain Experts + Multi-Agent Supervision UIs

Forum-first survey (GitHub issues, HN, Reddit, official docs) of two cohorts:
**Part 1** — single-purpose visual experts (diff renderers, markdown renderers, status
lines, log navigators) that are widely loved for doing one visual thing extremely well.
**Part 2** — the emerging "supervise N agents" UI category, still fragmenting rather
than converging.

Research date: 2026-07-15.

---

## Part 1: Single-thing visual experts

### delta (`dandavison/delta`)

**Ships visually (compressed):** syntax-highlighted pager for `git diff`/`grep`/`blame`.
Side-by-side mode with independent line-numbers + syntax highlighting in both panes,
word-level (not just line-level) highlight of changed spans, themeable via the same
syntax themes as `bat`, configurable "style strings" per element (`--foo-style`,
`--foo-decoration-style` for box/underline/background).

**LOVE:**
- "Delta has been one of those set and forget things, it's been a while since I've
  seen 'bare' git grep/diff/blame output." — HN, [Delta launch thread](https://news.ycombinator.com/item?id=42091365)
- "Delta can show in the terminal a diff that looks like the GitHub one. You can
  compare side by side what was changed." — same thread
- "I've been using Delta for a few years now and absolutely love it. Huge
  improvement to my command line diff viewing!" — same thread
- diff-so-fancy's own creator: "I created diff-so-fancy and I migrated to Delta a
  few years back." (paulirish) — same thread

**HATE:**
- "I want to like this having used regular `git diff` tool with colours, but this
  is just too busy." — commandersaki, HN
- "Delta seems more like a chaos I can't make sense of than default git diffs." —
  tionis, HN
- "Delta is great for what it does, but I consistently hit an issue where it
  truncates long lines." — CGamesPlay, HN

**DEMANDED-missing:** [delta#205](https://github.com/dandavison/delta/issues/205)
is a whole RFC of diff-so-fancy/diff-highlight parity requests: independent
foreground-color control (for minimal/reverse-video modes), differentiated styling
of lines with vs. without an emphasized span, background-color overrides (for light
themes on dark terminals), and decoration control (box/underline) per element. Delta
resolved it with a general "style string" grammar rather than one-off flags —
a **generalize-the-primitive** move, not a fixed feature.

**Transfers to harness TUI (judgment):**
1. Side-by-side is the loved default when terminal width allows; the busyness
   complaints are almost always about *too many simultaneous style dimensions*
   (color + bold + box + line-number gutter all at once), not about side-by-side
   itself. A harness diff view should default to word-level highlight inside
   line-level diff, and treat "box drawing around headers" as opt-in, not default.
2. The RFC pattern (users ask for N specific style knobs, maintainer ships one
   general style-string grammar) is the right shape for a harness's diff-render
   config — don't add flags per feature request, add one composable style spec.
3. Long-line truncation is a top complaint — any harness diff pane needs
   horizontal scroll or wrap toggle, not silent truncation.

---

### difftastic (`Wilfred/difftastic`)

**Ships visually (compressed):** structural (AST/tree-sitter) diff instead of
line diff — reformatting and variable renames collapse to "unchanged," moved
blocks render as moves, real before/after line numbers instead of hunk headers.

**LOVE:**
- "Unlike a line-oriented text diff, difftastic understands that the inner
  expression hasn't changed" when code is merely reformatted across lines. —
  [HN thread](https://news.ycombinator.com/item?id=39778412)
- Praise for real line numbers: it "shows the actual line numbers from your files,
  both before and after" rather than cryptic hunk headers. — same thread
- "Just dropped it in and did a git diff.. works like a charm!" — same thread
- "I've been using a mix of delta and difftastic both are amazing... Delta looks
  clean, and is super fast" — kjuulh, HN (delta thread)

**HATE:**
- Perf: diffing "a large JSON file" or large static test fixtures (single huge
  structures spanning many lines) is noticeably slow.
- Binary-file misfire: difftastic attempts to render "thousands of changed lines
  of text" for files `file` correctly identifies as ELF binaries.
- Styling: "modified attributes in bold green" are "difficult to detect visually"
  in XML diffs, with no documented customization.
- Adoption friction: "makes it hard to go back and use other diff tools when I
  don't have difft available" — workflow lock-in complaint.

**DEMANDED-missing:**
- No merge support: FAQ states flatly "AST merging is a hard problem that
  difftastic does not address."
- GitHub-web integration ("wish GitHub's web diff did structural diffing instead
  of a giant add & remove for indentation changes").
- No VS Code extension (SemanticDiff offered as a partial substitute).
- More configurable colors/output closer to diff-so-fancy conventions.

**Transfers (judgment):** A harness that renders diffs of *agent-authored* code
changes is exactly the case structural diff wins hardest — agents reformat/rename
constantly, and line diffs make small semantic edits look enormous. Worth a
"structural mode" toggle even if line-mode stays default (structural diff parse
failures on partial/invalid syntax — common mid-generation — are a real risk, so
this should degrade to line diff on parse failure, not error out).

---

### diff-so-fancy (`so-fancy/diff-so-fancy`)

**Ships visually (compressed):** a `git diff` post-processor: cleans up hunk
headers, highlights changed words within a line, strips the `a/`/`b/` prefixes,
renders `+`/`-` more legibly. Predates delta; lighter-weight, shell-script-friendly
(pipes into `less`).

**Status relative to cohort:** effectively the "legacy default" that delta absorbed
— its own author moved to delta, and delta shipped an explicit
diff-so-fancy/diff-highlight *emulation mode* (the #205 RFC above) rather than
users maintaining both. Ecosystem integration requests for it are mostly *other*
tools asking "should we shell out to diff-so-fancy" (lazygit#190, gitui#2180) —
i.e. diff-so-fancy is now referenced as a rendering-convention name ("fancy-style
diff") more than an actively-chosen tool.

**Transfers (judgment):** the fact that delta had to build an explicit
compatibility mode for diff-so-fancy conventions confirms there's a converged
"fancy diff" visual vocabulary (word highlight, cleaned headers, no a/b prefix) —
a harness diff renderer should just implement that vocabulary as its baseline,
not treat it as one of several equally-valid styles.

---

### glow (`charmbracelet/glow`) + streaming markdown (streamdown et al.)

**Ships visually (compressed):** glow renders GitHub-flavored Markdown in a TUI —
real table borders, syntax-highlighted code fences, styled headers/lists, pager
navigation. Designed for *static, complete* documents (READMEs), not streaming.

**LOVE:**
- "The first time a markdown file rendered perfectly inside the terminal, it
  looked completely transformed." — user review, Medium/ConfigCrate coverage
- "for straightforward prose and code documentation... glow does the job well."

**HATE / demonstrated bugs (glow issue tracker, 2026):**
- [#941](https://github.com/charmbracelet/glow/issues/941) — "Table column
  collapsed to width 0 (header dropped, cells blank) when sibling has long
  unbreakable tokens" — the single most damning table-rendering bug.
- [#983](https://github.com/charmbracelet/glow/issues/983) — "Text wrapping
  failure, blank screen on resize, and text duplication in viewport."
- [#942](https://github.com/charmbracelet/glow/issues/942) — feature request:
  auto-detect terminal width (still open — glow doesn't reliably adapt).
- [#970](https://github.com/charmbracelet/glow/issues/970, closed *not planned*)
  — long URLs that wrap lose click-through on the wrapped portion.
- General: "Wide tables can wrap awkwardly in narrow terminals, with no
  horizontal scrolling in the TUI"; heavy raw-HTML READMEs render imperfectly
  since glow renders Markdown, not HTML.

**Streaming markdown — hard problems (from streamdown.ai docs, HN
[discussion](https://news.ycombinator.com/item?id=44182941), and dev.to writeups):**

1. **Incomplete-construct flash** — a closing `**`, backtick, link `]()`, or math
   delimiter that hasn't arrived yet gets rendered as *literal* raw syntax until
   it closes ("flash of incomplete markdown"). The core tension, quoted directly:
   > "you can only start buffering tokens once you see a construct, for which
   > there are continuations, that once completed, would lead to the previous
   > text being rendered differently... you don't want to keep buffering for too
   > long, since this would defeat the purpose of streaming, and you never know
   > if the potential construct will actually be generated."
2. **Re-parse cost** — naive implementations re-parse the *entire* document on
   every new token, an O(n²) blowup over a long response; the fix category is
   incremental/streaming parsers that only re-evaluate the tail.
3. **Context-sensitivity** — e.g. "within code blocks, you'll never want to
   render links for `[]()` constructs" — markdown semantics change depending on
   what block you're inside, and that state must be tracked incrementally.
4. **Out-of-order references** — link/footnote *definitions* can arrive after
   their *uses* in a stream; streamdown's answer is "optimistic references" that
   render provisionally and resolve when the definition lands.
5. **Model inconsistency** — "Almost every model has a slight but meaningfully
   different opinion on what markdown is and how creative they can be with it.
   Doing it well is a non-trivial problem" — i.e. the renderer must be lenient/
   forgiving of malformed markdown, not just fast.

Streamdown's shipped answer: a preprocessing pass (`remend`) that scans the raw
string, detects unclosed constructs, and *temporarily* auto-closes them for
rendering only, without mutating the underlying buffer — so the next token can
still complete the real construct.

**Transfers (judgment):** A harness rendering an agent's streaming natural-language
output (not just tool/diff output) will hit every one of these five problems
verbatim. The `remend`-style "provisional auto-close, never mutate source" pattern
is the correct primitive to port — do NOT attempt full re-parse per token in a
terminal renderer, and do NOT let unclosed code fences leak raw backticks onto
screen. Tables are the single riskiest widget to stream (glow's #941 shows even
*static* table rendering breaks under adversarial content) — a harness likely
wants to buffer whole table blocks (detect start, don't render row-by-row) rather
than stream them cell-by-cell.

---

### starship / powerlevel10k (status-line information design)

**Ships visually (compressed):** both are shell prompts assembling small
"segments" (git branch/dirty-state, language version, exec time, exit code,
directory) into one or two lines, conditionally shown only when relevant (e.g.
git segment invisible outside a repo).

**LOVE / configuration philosophy:**
- Segment conditionality is the core loved mechanic: "allows for a prompt that
  provides just the right context, preventing unnecessary clutter while saving
  you time." One user: configuring git info to show *only inside a git
  directory* meant "it didn't clutter my prompt when I wasn't in a git
  directory."
- On latency: results are contested and configuration-dependent —
  [starship/starship discussion #580](https://github.com/starship/starship/discussions/580)
  reports powerlevel10k 25× faster in one Linux git-repo benchmark, while another
  benchmark found powerlevel10k ~20-40% *slower* than starship depending on
  context. Net consensus: "both are very fast in absolute terms and any
  difference is imperceptible on modern hardware" *once configured comparably* —
  the real latency sensitivity is to segments that shell out (git status, version
  managers), not the renderer itself.

**HATE / demanded discipline:**
- "no matter how carefully you curate your prompt, 90% of the information shown
  will be irrelevant 90% of the time... your brain will start perceiving this as
  visual clutter and filter it out" — the core objection to permanent status-line
  real estate for anything.

**What earns permanent pixels (synthesized rule):** information that is (a)
binary/rare-state (dirty git tree, nonzero exit code, active venv) shown
*conditionally*, never a permanently-reserved slot for state that's usually
empty; (b) cheap to compute — anything that forks a subprocess must be
async/cached or it becomes the dominant latency cost, which is what the
p10k-vs-starship flame wars are actually about.

**Transfers (judgment):** A harness status line (model, cost, turn count,
context %, blocked/waiting state) should follow the same rule — conditional
segments, not a fixed-width bar that always shows all fields. The "async instant
prompt" trick p10k uses (render a cached prompt immediately, patch in live values
async) is directly reusable for a harness header line that needs to show
live cost/token counters without blocking the next render frame.

---

### lnav / toolong (log navigation)

**lnav (`tstack/lnav`)** ships: automatic format detection (syslog, nginx, apache,
journalctl, etc. — no config), time-based interleaving of multiple log files into
one chronological view, live tailing with rotation tracking, regex search +
highlighting of identifiers (IPs, PIDs), and the standout feature: press `;` and
the logs become a **queryable SQLite virtual table** for ad hoc filtering/
aggregation.

**LOVE (HN [thread](https://news.ycombinator.com/item?id=34243520)):**
- "I used this extensively when working in a cloud support role, incredible
  tool."
- "This tool saved me weeks of work once. You gotta try it."
- "I'm using every day on multiple server and application. It a MUST"
- Reddit-adjacent sentiment cited by secondary coverage: trust earned by
  substance not marketing — "no login, no ads, just the tool" and "4,615
  commits, 74 contributors, first commit from 2009."

**HATE:** default theme is "overly colorful... distracting or hard to read" for
some; no cross-platform GUI (terminal-only); some documentation gaps (format
support not prominently listed).

**toolong (`Textualize/toolong`)** ships: fast open of multi-gigabyte files "as
quickly as tiny text files," live tail with per-format syntax highlighting,
JSONL pretty-printing, automatic `.bz`/`.bz2` decompression, and timeline-merge
across multiple files by auto-detected timestamp.

**DEMANDED-missing across both:** neither tool's marketing/issue surface strongly
emphasizes a "new since last look" mark — this is a **gap**, not a solved
pattern; the closest analog found is lnav's live-tail + highlight-of-changed
lines, not an explicit unread-marker concept.

**Transfers (judgment):** the SQLite-virtual-table trick is the single most
transferable idea in this whole survey — a harness reviewing tool-call/log
history could expose the transcript as a queryable table (filter by tool name,
error, file touched) instead of only linear scroll + regex search. Auto-format-
detection (don't make the user declare "this is a Claude Code transcript" vs.
"this is a shell log") is the right default posture. The missing "new since last
look" mark is a genuine opportunity: a harness resuming a session or returning to
a background agent has exactly this need and no incumbent has nailed it visually.

---

## Part 2: Multi-agent supervision UIs (the frontier — fragmenting, not converged)

### Claude Code's own answer: Agent View + Agent Teams (most authoritative single
data point, since it's the vendor's own dogfooded design)

**Agent View** (`claude agents`, research preview, v2.1.139+) — full-terminal
dashboard, not a split pane:

- Layout: header (version/model/cwd/summary count) → **session table grouped by
  state** (Pinned → Needs input → Working → Ready for review → Completed, folded
  as `… N more`) → dispatch input at the bottom → footer with keybinds.
- Per-row info: icon (shape = process-alive vs. exited vs. sleeping loop; color =
  state) + name + **one-line summary generated by a Haiku-class model** ("what is
  this session doing/asking/producing") + optional PR number + elapsed duration.
  Direct quote: "The one-line summary in each row is generated by a Haiku-class
  model so the row can tell you what the session is doing, what it needs, or what
  it produced without opening the transcript."
- Attention mechanism, layered: priority position (needs-input group sorts to the
  top, above working), yellow icon color, **terminal tab title rewrite** (`2
  awaiting input · claude agents`), OS-level notification via configured channel
  when a session starts needing input/finishes/fails (v2.1.198+), and an inline
  prompt-footer counter (`← 2 agents`) when you're in a *different* regular
  session.
- Non-committal inspection: `Space` opens a **peek panel** — question text, any
  linked PR, `waiting 3m` elapsed, inline reply field — "Most of the time the peek
  panel is enough and you don't need to open the full transcript." This is the
  clearest "approval inbox" implementation found in the entire survey.

**Agent Teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, experimental) — a
different axis: teammates that message each other directly, not just report to a
lead.

- In-process mode (default): teammates live in an **agent panel below the prompt
  input** in the lead's single terminal; arrow keys select, Enter opens
  transcript + lets you message directly, Escape interrupts. >3 idle teammates
  collapse into one `N idle agents` row.
  - working/failed/viewed teammates always keep dedicated rows; idle rows hide
    after 30s and reappear on next turn — an explicit anti-clutter rule.
- Split-pane mode: one tmux/iTerm2 pane per teammate — literal one-pane-per-agent,
  requires tmux or iTerm2's `it2` CLI; explicitly **not supported** in VS Code's
  integrated terminal, Windows Terminal, or Ghostty.
- Plan-approval gate: a teammate can be required to submit a plan; lead
  approves/rejects with feedback before implementation proceeds — a structured
  approval step distinct from ad hoc permission prompts.
- Explicit documented limitation: "Teammate permission prompts appear in the lead
  session" — i.e. even with N teammates, approval funnels to *one* inbox (the
  lead), not N separate prompts. This is a deliberate design choice worth noting.

### Desktop/GUI cohort: Conductor, Crystal/Nimbalyst

**Conductor** (Mac app, [HN launch](https://news.ycombinator.com/item?id=44594584)):
one workspace = one isolated repo copy + branch + agent + state; the pitch is
literally "see at a glance what they're working on, then review and merge."

- LOVE: "I can easily bounce between tasks I have the agents working on during
  these natural lulls. Overall I'm able to get more done"; visual design praised
  directly ("I absolutely love this aesthetic," "functional, visually subtle, and
  chromatically warm").
- HATE: requires GitHub OAuth + clones repos rather than working an existing local
  checkout ("simple git worktree management for an already-checked-out repo on my
  machine, no Github permissions" was the explicit ask); initial OAuth scope was
  "full read-write access to all your Github account's repos," called "INSANE" by
  a commenter; new worktrees mean reinstalling deps/copying `node_modules`/`.env`
  by hand; **no notification system for agents needing attention or approval**
  was noted as missing.
- Crystal (renamed Nimbalyst) is repeatedly cited as the alternative specifically
  *because* it works with already-checked-out local repos — i.e. the market has
  bifurcated on "cloud-clone-first" vs. "local-worktree-first" and users have
  clear, opposite preferences with no convergence.

### Terminal-native cohort: claude-squad, tmux-based dashboards (amux,
agent-dashboard, tmux-agent-sidebar, tmuxcc, NTM)

**claude-squad** (`smtg-ai/claude-squad`): tmux sessions + git worktrees per
agent, one instance list + preview/diff tab toggle. Keymap: `n`/`N` new session,
`↑/↓` navigate, `↵/o` attach, `s` commit+push, `c` checkout+pause, `r` resume,
`tab` switch preview/diff, experimental `--autoyes` auto-accept flag (a blunt
instrument for the approval problem — skip it entirely rather than surface it).

**The tmux-wrapper micro-cohort is real evidence of fragmentation, not
convergence** — half a dozen independently-built tools (amux, agent-dashboard,
tmux-agent-sidebar, tmuxcc, NTM, agent-tmux-manager) all solve "which of my tmux
panes has an agent that's stuck," each with its own status taxonomy and its own
half-built notification story. `agent-dashboard`'s docs describe a *typed,
persistent* status field ("blocked/waiting/running/done/PR/merged") that "stays
on the row until you act on it" and "powers the attention list, the title-bar
bell, and attention navigation" — structurally identical in spirit to Claude
Code's own Agent View, independently reinvented. Its notification implementation,
however, is comparatively primitive: desktop-only (macOS `osascript` / Linux
`notify-send`) triggered by a hook after each state change, off by default, with
only `enabled`/`sound`/`silent_events` as knobs — no OSC 9, no terminal-native
path.

### GUI-IDE cohort (contrast case: what a GUI adds that no TUI can)

**Cursor 3's "Agents Window"** (April 2026 relaunch): a dedicated full-screen
agent workspace replacing the old Composer pane. Because Cursor owns the whole
editor chrome (not a VS Code extension sandboxed from internals), it can render
**diffs, tables, and interactive dashboards inline in a side panel alongside the
terminal, browser, and source control** simultaneously — i.e. the GUI's actual
advantage over a TUI isn't "prettier," it's *multiple rich views open at once
without modal switching* (diff view + terminal + browser preview + agent chat all
visible together). A TUI fundamentally cannot do this without tmux-style panes,
and even then can't embed a rendered browser preview.

**Warp's Agent Management Panel**: centralized view across *all* running agents
in *all* tabs — status, cancel-in-progress, "review agents waiting for input or
with errors," jump-to-pane. Notification path: floating in-app toast (auto-dismiss,
hover-to-pause, click-to-jump) *plus* OS-level desktop notification when Warp is
backgrounded. This is the most complete "notification queue" implementation found
— toast + persistent panel + OS escalation, tiered by whether the app has focus.

### Cross-cutting Show HN signal

[Show HN: AgentsMesh](https://news.ycombinator.com/item?id=47252334) (fleet
command center) — thread fetch was rate-limited (HTTP 429) and could not be
retrieved for direct quotes within this pass; flagged as a follow-up fetch if a
future pass needs its specific comments. Its existence alongside amux, Pushary,
agent-dashboard, Grok's Agent Dashboard (June 2026), and Claude Code's own Agent
View — five to six independently-branded "watch my fleet of agents" products
shipping within roughly the same 12 months — is itself the strongest signal:
**this category is in active, unconverged land-grab, not consolidation.**

### Question answered directly: what do people supervising 1-10 agents actually
need on screen?

Cross-referencing every tool above, the recurring, independently-reinvented
primitives are:

1. **A status-grouped list, not a status grid.** Every serious implementation
   (Agent View, agent-dashboard, Warp's panel, Conductor) groups/sorts by state
   (needs-input first) rather than a fixed N×1 grid of equal-weight tiles. Nobody
   converged on a "grid of tmux-like thumbnails" despite it being the visually
   obvious idea — probably because thumbnail *content* (scrolling text) isn't
   parseable at a glance the way a color/icon + one-line summary is.
2. **One generated one-line summary per agent**, not a raw log tail. Claude
   Code's Haiku-generated row summary is the most sophisticated version of this;
   even the crudest tools (claude-squad) at minimum show a name + diff-changed
   indicator.
3. **A peek/preview layer cheaper than full-attach.** Agent View's peek panel and
   claude-squad's preview/diff tab are the same idea at different fidelity: don't
   force a full context-switch to answer "does this need me."
4. **Approval funneling to one place**, even across many agents. Agent Teams'
   explicit design (all teammate permission prompts surface in the lead session)
   and Agent View's dispatch-input-at-the-bottom-of-one-table both refuse to
   scatter approval decisions across N separate contexts.
5. **Tiered, focus-aware notification**: in-app indicator always; OS-level
   desktop/toast notification specifically *when unfocused/backgrounded*
   (Warp, Claude Code, agent-dashboard, opencode's OSC 9 proposal all converge
   on this exact tiering independently).

**Not converged:** local-worktree vs. cloud-clone repo model (Conductor vs.
Crystal), tmux-pane-per-agent vs. single-table-with-panel (dozen of competing
tmux wrappers vs. Agent View), and — the clearest gap — **nobody has good
multi-agent approval-queue triage UI beyond "list sorted with needs-input on
top."** No tool found here does approval *batching*, diff-based approval
grouping across agents, or risk-scored ordering of pending decisions.

---

## Cross-cutting answers

### A. Diff rendering: converged best-practice set

From the delta/difftastic/diff-so-fancy issue threads, the converged vocabulary is:
- Word-level (not just line-level) highlight of the changed span within a
  changed line.
- Real syntax highlighting of the diffed code itself (not just the +/- markup),
  themed consistently with the user's existing syntax theme.
- Side-by-side as the loved *option*, not forced default — busyness complaints
  are about stacking too many simultaneous style dimensions (box + bold + color +
  gutter), not about side-by-side layout itself.
- Cleaned-up hunk headers / no `a/`,`b/` path prefixes (the diff-so-fancy legacy
  now folded into delta's default).
- One composable style-string grammar rather than per-feature flags (delta's
  answer to the #205 RFC) — the generalizable lesson for any harness diff config.
- Structural (tree-sitter-based) diff is a genuinely different, complementary
  mode for reformatting-heavy or renamed-heavy changes — valuable but must
  degrade gracefully on parse failure (agents produce syntactically invalid
  intermediate states constantly) and is not a line-diff replacement.
- Long-line handling (wrap vs. horizontal scroll, never silent truncation) is
  the most common unresolved complaint across the whole cohort.

Agent-CLI users piping to delta: not directly quoted in this pass (no thread
specifically comparing an agent's own diff rendering to piped delta was
surfaced), but the broader pattern — every terminal-native agent supervisor
(claude-squad, agent-dashboard, Conductor) exposes a **diff tab/preview** as a
first-class view alongside the agent transcript — confirms diff review is
considered a *distinct* view from the conversational transcript, not an inline
artifact buried in scrollback.

### B. Streaming markdown: known-hard-problems list

1. Incomplete-construct flash (unclosed bold/italic/code-fence/link/math shown as
   literal raw syntax until closed).
2. O(n²) full-document re-parse per token as responses grow long.
3. Context-sensitivity (e.g. link syntax inside code fences must not render as a
   link) requiring incremental state tracking, not stateless regex.
4. Out-of-order reference/definition arrival (footnotes, link defs).
5. Model inconsistency in what "valid markdown" even means, requiring lenient/
   forgiving parsing over strict-spec parsing.
6. (Static-but-still-broken, from glow's own bug tracker) table rendering with
   long unbreakable tokens collapsing columns to zero width, and no terminal-width
   auto-adapt — proof that even *non-streaming* markdown-in-terminal isn't fully
   solved, so a harness should treat tables as the highest-risk widget.

Who solved what: streamdown's `remend` preprocessing (scan, detect-incomplete,
provisionally auto-close *without mutating source*) is the most complete public
solution for problem 1 and composes with problem 3/4 handling ("optimistic
references"). Nobody in this survey has a public solved answer for problem 6 in a
terminal context specifically (glow's own tables still break).

### C. Multi-agent supervision: convergence or fragmentation?

**Fragmentation on mechanism, convergence on a handful of principles.** No
agreement on: repo/workspace model (clone vs. worktree), rendering surface
(one-table-with-drilldown vs. one-tmux-pane-per-agent vs. full GUI panels),
or branding (six-plus independently named products in ~12 months: Agent View,
Agent Teams, Conductor, Crystal/Nimbalyst, claude-squad, amux, agent-dashboard,
Warp's panel, Grok's Agent Dashboard, AgentsMesh, Pushary). Convergence, found
independently across nearly every serious implementation: state-grouped list
(needs-input sorts to top) + one generated summary line per agent + a cheap
peek/preview short of full attach + approval funneled to a single place even
across many agents + focus-aware tiered notification. **Strongest demand
signal: the approval/attention surface** — every tool treats "which agent needs
me right now" as the organizing question of the entire UI (it's the sort key,
the notification trigger, and the thing every dashboard leads with) — stronger
than either a generic status glance or a diff-review queue, both of which exist
but are secondary views hung off the attention-sorted list.

### D. Notification/attention patterns

Converged tiering across Claude Code Agent View, Warp's Agent Management Panel,
opencode's OSC 9 proposal, and agent-dashboard, all independently:

1. **In-app/in-list indicator always on** (color, icon, sort position) — zero
   cost, always active, the baseline.
2. **Title-bar / tab-title rewrite** when something needs input (`2 awaiting
   input · claude agents`) — cheap, visible even when the terminal is merely
   unfocused-but-visible (e.g. another tab).
3. **Terminal-native escalation (OSC 9 / BEL)** when the terminal itself isn't
   focused — supported by kitty, iTerm2, and proposed for opencode explicitly
   because "Codex TUI and Claude Code both send notifications so users know when
   an agent has finished or needs attention"; BEL is the documented fallback for
   terminals lacking OSC 9, typically surfaced by the terminal as a taskbar flash
   or system alert sound.
4. **OS-level desktop notification** (native `osascript`/`notify-send`, or Warp's
   toast+OS pairing) when the whole application is backgrounded — the top tier,
   reserved for true out-of-view attention.

What users tolerate: escalation strictly gated on *focus state* — every
implementation above triggers OS-level notification only when unfocused/
backgrounded, never while the user is actively looking at the session (that
would be noise, matching the starship/p10k "90% irrelevant" clutter complaint
transplanted to notifications). Sound is opt-in everywhere it's implemented
(agent-dashboard defaults `sound=false`; notifications themselves default off).
Auto-dismiss + hover-to-pause + click-to-jump (Warp's toast) is the most
user-friendly concrete implementation found — transient by default, but
recoverable and actionable, not just an ephemeral flash.

**Judgment for a single-agent harness TUI:** even a *single*-agent harness should
implement the same four-tier escalation (in-view state indicator → tab-title
→ OSC 9/BEL → OS notification-if-backgrounded) gated purely on focus, since the
"is the user looking right now" problem is identical whether there's 1 agent or
10 — the multi-agent tools didn't invent new notification tiers for scale, they
just added the sorted-list/attention-navigation layer on top of the same
single-agent tiering.
