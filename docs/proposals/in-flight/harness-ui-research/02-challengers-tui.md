# Challenger TUIs — Forum-First Visual/UX Research

Date: 2026-07-15
Status: Phase 3 brief #2 of the harness-ui cohort research plan (see
`../harness-ui-cohort-research.md`). Scope: TUI/visual layer ONLY — rendering
substrate, flicker/scrollback, layout, diff display, approval UI, status/progress,
theming, input editor, long-session navigation — of six challenger agent CLIs:
Gemini CLI, opencode, Crush, Aider, goose, Amp CLI. Agent logic and pricing are
explicitly out of scope. Six parallel forum-mining passes (GitHub issues, HN,
Reddit, Discord-adjacent, blogs) fed this synthesis; quotes and URLs below are
as-gathered, not paraphrased where possible.

---

## 1. Gemini CLI (Google, Ink/React)

**Ships visually:** Inline-append by default (Ink), with an alt-buffer toggle added
later (Epic [#10673](https://github.com/google-gemini/gemini-cli/issues/10673),
"Ability to quickly toggle between regular and alternate buffer mode"). A Dec 2025
rendering rewrite (v0.15.0+) added sticky headers — confirmations/action summaries
pin to the top, input pins to the bottom. Plan/todo state is an inline `write_todos`
element ("progress indicator above the input prompt"), expandable via **Ctrl+T** to
a full list — not a persistent side panel. Context usage is a footer percentage next
to memory usage, not a meter. Tool output supports **Ctrl+O** expand/collapse
(issue [#20785](https://github.com/google-gemini/gemini-cli/issues/20785)) and
shell output auto-truncates (keeps first 20%/last 80%).

**LOVE:** *"We have overhauled the foundation of how Gemini CLI is rendered to
eliminate the visual noise often associated with terminal applications"* (Google,
via tessl.io, Dec 2025). "feels polished, powerful, and clearly designed for
terminal-loving developers" (dev.to/therealmrmumba). No Reddit praise threads
surfaced despite targeted queries — praise volume is thin and mostly vendor-sourced.

**HATE:**
- *"The Gemini CLI interface keeps flickering every second while idle and also
  during command execution"* — [#14708](https://github.com/google-gemini/gemini-cli/issues/14708),
  **32 👍**, 11 comments, filed 2025-12-08.
- *"Ink's incremental renderer sometimes leaves stale diff artifacts on the screen,
  such as duplicated footers or misaligned text blocks"* — [#22615](https://github.com/google-gemini/gemini-cli/issues/22615),
  2026-03-16, closed not-planned.
- *"the host terminal's native vertical scrollbar becomes ineffective or
  inaccessible once the conversation's output exceeds the visible height"* —
  [#13271](https://github.com/google-gemini/gemini-cli/issues/13271).
- Severe SSH flicker on Windows even with `--screen-reader` —
  [#11305](https://github.com/google-gemini/gemini-cli/issues/11305).
- Multi-line paste *"triggers immediate submission with corrupted formatting and
  repeated text"* — [#13118](https://github.com/google-gemini/gemini-cli/issues/13118),
  one of ~10 duplicate paste-corruption issues spanning #2789→#20293 (Jul 2025–Feb 2026).
- Diff view limited to 4 lines at a time — [#3526](https://github.com/google-gemini/gemini-cli/issues/3526).

**DEMANDED BUT MISSING:** persistent context-window meter ("show context usage %
clearly in toolbar somewhere," [#16130](https://github.com/google-gemini/gemini-cli/issues/16130));
expanded/consistent diff viewport ([#6036](https://github.com/google-gemini/gemini-cli/issues/6036),
[#4739](https://github.com/google-gemini/gemini-cli/issues/4739),
[#8079](https://github.com/google-gemini/gemini-cli/issues/8079)); compact/collapsible
tool + MCP output ([#20508](https://github.com/google-gemini/gemini-cli/issues/20508));
condensed pasted-content display "following the pattern established by tools like
Claude Code" ([#15844](https://github.com/google-gemini/gemini-cli/issues/15844)).

**HORROR:** No single dated mass-rejection, but Epic #10673 ("Flicker-Free Robust
Terminal Rendering," opened 2025-10-07) documents flicker/resize/scrollback as a
systemic, months-long unresolved problem class — fresh duplicates (#22615, #17578)
kept appearing into 2026-03 despite 14/16 sub-issues marked "completed." HN thread
["Gemini CLI sucks. Just use Opencode..."](https://news.ycombinator.com/item?id=46061907)
focused on reliability, not rendering.

**Panels/nav:** No persistent panels; inline todo block (Ctrl+T) + footer %.
Tool-output folding exists (Ctrl+O, shell auto-truncation). Session-level
search/jump exists via `/resume` (keyword filter, restore) but no in-transcript
search within an active session.

---

## 2. opencode (sst/opencode → anomalyco/opencode)

**Ships visually:** Client/server architecture — a JS/Bun backend with swappable
renderer clients (terminal, web, desktop) over one protocol. The TUI was rewritten
off Bubble Tea into a **custom in-house renderer, "OpenTUI"** (`@opentui/core`,
native bindings, TSX/React-style components), described on HN as "an entire custom
TUI backend that supports a good subset of HTML/CSS and the TypeScript ecosystem...
a generic TUI renderer" (dboon, [HN](https://news.ycombinator.com/item?id=46550004)).
Full alt-screen redraws targeting 60fps. Persistent chrome: sidebar (session list,
"Modified Files"/diff panel, loaded-skills panel), status/footer bar (context %,
cost, tokens, Plan/Build mode indicator), themeable dark/light (V1→V2 theme-API
rewrite mid-flight). A community `/layout` command added dense/default presets for
accessibility: *"I am visually impaired... the original hardcoded layout simply
didn't scale"* ([#5020](https://github.com/anomalyco/opencode/pull/5020)).

**LOVE:** *"I have to say, OpenCode's OpenUI has taught me what modern TUIs can be
like. Claude's TUI feels more like it's been grown than designed."* (sshine,
[HN](https://news.ycombinator.com/item?id=47856019)). Fullest praise: *"the
engineering in opencode is so far ahead of Claude Code... They built an entire
custom TUI backend... built the product as client/server... could also build a web
view and desktop view over the same server. It also doesn't flicker at 30 FPS
whenever it spawns a subagent."* (dboon, [HN](https://news.ycombinator.com/item?id=46550004))
— prettiness framed explicitly as *engineering*, not decoration.

**HATE:** Forced `targetFps: 60` vs opentui's default 30 broke VS Code's xterm.js
([#31296](https://github.com/anomalyco/opencode/issues/31296)). Chronic repaint
corruption: garbled text ([#23914](https://github.com/anomalyco/opencode/issues/23914)),
NFS kernel messages leaking into the display ([#34146](https://github.com/anomalyco/opencode/issues/34146)),
Ctrl+Z/resize not repainting ([#16327](https://github.com/anomalyco/opencode/issues/16327)),
tmux hanging 1s/keystroke from an OSC theme-probe ([#24475](https://github.com/anomalyco/opencode/issues/24475)),
Alpine/musl native-lib crash ([#27589](https://github.com/anomalyco/opencode/issues/27589),
**+12**). Anxiety-inducing chrome: *"the running progress bar at the top makes me
extremely anxious and distracted"* ([#21812](https://github.com/anomalyco/opencode/issues/21812))
and *"makes me feel dizzy looking at it"* ([#21657](https://github.com/anomalyco/opencode/issues/21657)).
Sharpest structural critique: *"it feels TUI in appearance only... Copy paste is
hijacked... don't think this would work over SSH... wish they would have made it a
GUI."* (plastic3169, [HN](https://news.ycombinator.com/item?id=47464797)).

**DEMANDED BUT MISSING:** Multi-file `apply_patch` approval only renders one file's
diff — [#17076](https://github.com/anomalyco/opencode/issues/17076), **+18**
(largest single reaction count found across the whole cohort). Scroll buffer
truncates old messages, blocking full-session review/fork —
[#30587](https://github.com/anomalyco/opencode/issues/30587). Native transcript
fold/collapse requested and closed unresolved
([#15935](https://github.com/anomalyco/opencode/issues/15935)); a "Clean Output
Mode" collapse-by-default request remains open
([#37003](https://github.com/anomalyco/opencode/issues/37003)). Reduce-motion
toggle for idle animations ([#21939](https://github.com/anomalyco/opencode/issues/21939)).

**HORROR:** An "interactive burst" logo animation
([#22098](https://github.com/anomalyco/opencode/issues/22098)) landed then drew
**17 thumbs-down + confused reactions** against one "looks beautiful, ship it,"
with immediate "please disable it" / "Extremely annoying" — a small, dated
mass-rejection of pure decorative flourish. Separately, v1.18.1's desktop
"new layout design" shipped and **hid the Plan/Build agent-mode switch entirely**
([#36997](https://github.com/anomalyco/opencode/issues/36997)), requiring a config
flag rollback.

**Panels/nav:** Persistent sidebar/status panels (context %, cost, Plan/Build —
though the last regressed). No native transcript folding despite repeated asks.
In-session search exists (#34297/#36526) with filter bugs in the session switcher
(#31965).

---

## 3. Crush (charmbracelet/crush)

**Ships visually:** Bubble Tea **alt-screen mode**, confirmed by a maintainer
explanation of a no-mouse-text-selection report: *"this tool's UI is using the
alternate screen mode and capturing mouse... as long as this uses bubbletea, you
can't both get scrollback and also get mouse select"* (keen99,
[#373](https://github.com/charmbracelet/crush/issues/373)). Sidebar + main-pane
layout: chat viewport, multi-line editor, attachments panel, and a persistent
sidebar (session/model info, git branch, LSP/MCP status, changed files, a "pills
panel" for active to-dos/prompt queue). **No context-% meter** — explicitly
requested and still missing: *"It would be amazing to know how much context is
left. Cline does it, and so does Claude AI"*
([#875](https://github.com/charmbracelet/crush/issues/875)). Diffs render via a
dedicated DiffView (unified/split) inside the permission dialog. Theming was bolted
on later, not day-one ([#1334](https://github.com/charmbracelet/crush/issues/1334),
15 reactions → shipped [#2731](https://github.com/charmbracelet/crush/pull/2731)
"Charmtone default + Gruvbox Dark"; light theme even later,
[#3139](https://github.com/charmbracelet/crush/pull/3139)/[#3168](https://github.com/charmbracelet/crush/pull/3168)).

**LOVE** (all from the 367-point [HN thread](https://news.ycombinator.com/item?id=44736176)):
ianbutler — *"I am starring this just for aesthetic absolutely nailed it."*
mbladra — *"Woah I love the UI... this feels like the most enjoyable to use so
far."* alixanderwang vs. Claude Code: *"Beautiful UI," "Useful sidebar," "Better UX
for accepting changes (has hotkeys, shows nicer diff)."* LouisvilleGeek —
*"Feels much nicer than Claude Code since the screen does not shake violently."*
bachittle — *"Bubble Tea has always been an amazing TUI... React TUI (which is
what Claude Code uses) [is] buggy."*

**HATE:** jsnell (same thread) pushes back: *"tons of whitespace, line art, ascii
art and gradients, and now apparently animations"* while lacking *"full suite of
expected keybindings, tab completion, consistent scrollback."* breuleux: *"worst
of both worlds... inferior UI in an inferior rendering system."* Colorblind
complaint, **39 reactions**: *"I'm colorblind and unable to distinguish low
contrast colors... very hard for me to read"*
([#755](https://github.com/charmbracelet/crush/issues/755)); milanglacier:
*"The default theme assumes dark mode, making the package effectively unusable for
many terminal users."* Flicker recurs: to-do menu flicker on modifier keys
([#3062](https://github.com/charmbracelet/crush/issues/3062)), logo flicker on
resize ([#1338](https://github.com/charmbracelet/crush/pull/1338)),
completion-menu flicker with multi-byte input
([#1717](https://github.com/charmbracelet/crush/pull/1717)).

**DEMANDED BUT MISSING:** theming (39+15 reactions, ~9 months to land),
context-left indicator (still open), collapsible tool output — *"Hook output
should be collapsed by default... crowds out the actual output and makes the UI
harder to scan"* ([#2917](https://github.com/charmbracelet/crush/issues/2917)). No
in-transcript search or jump-to-message found anywhere in the tracker.

**HORROR:** No dated mass-rejection found — only ongoing minor rendering
papercuts: sidebar corruption on Windows PWSH
([#3022](https://github.com/charmbracelet/crush/issues/3022)), stale-cell repaint
([#1703](https://github.com/charmbracelet/crush/issues/1703)), a CPU-spike-to-53%
report ([#3072](https://github.com/charmbracelet/crush/issues/3072)) with no
diagnosis attached.

**Panels/nav:** Persistent sidebar (files/LSP/MCP/todos), no context-meter, no
fold/collapse, no in-session search. Framed by the community as opencode's
"glow-up" (creator moved to Charm) — more polished split-pane/diff TUI, Charm
proprietary license vs. opencode OSS.

---

## 4. Aider (Aider-AI/aider, Python, prompt-toolkit + Rich)

**Ships visually:** Confirmed strictly inline/scrolling — no alt-screen, no panels,
no sidebar. HN's jsnell (on the Crush thread) put it precisely: *"it looks and
feels the way a REPL is supposed to"* — contrasting Aider with rivals' *"tons of
whitespace, line art, widgets, ascii art and gradients, and now apparently
animations."* Diffs render via `/diff` with Rich/Pygments syntax highlighting
(`--code-theme`, customizable colors — [#2466](https://github.com/Aider-AI/aider/issues/2466)).
Chat modes (`/code`, `/ask`, `/architect`) are plain slash-command state switches,
not visual modes. No default per-edit y/n approval gate (only a Y/N prompt for
including shell-command output in context). A separate opt-in `--browser` web UI
exists as an alternative surface, not an enhancement of the terminal itself.
`--light-mode` toggles exist for terminal theming.

**LOVE:** CuriouslyC ([HN](https://news.ycombinator.com/item?id=43968064)):
*"Aider is designed to work in a console... When we're managing 10-20 AI coding
agents to get work done, the interface for each is going to need to be minimal. A
lot of cursor's functionality is going to be vestigial at that point."* jsnell
([HN](https://news.ycombinator.com/item?id=44737008), 367-pt thread): *"This is one
of the reasons Aider is still my go-to; it looks and feels the way a REPL is
supposed to."*

**HATE:** slinkp blog (Jul 25 2025): *"the diff format used ... is the least
readable diff format I have ever encountered ... There is no visual indication of
which of those lines changed or how."* Also: *"This is actually training me to
ignore the LLM output because there's just too much of it."* Issue #2972: *"It's
hard to read the output text while Aider is still generating because the output
text keeps scrolling up."* `/diff` wraps lines narrower than terminal width
([#3563](https://github.com/Aider-AI/aider/issues/3563)); wants `less`-style paging
([#4332](https://github.com/Aider-AI/aider/issues/4332)) — both near-zero reactions.

**DEMANDED BUT MISSING:** "Is a TUI planned?"
([#4359](https://github.com/Aider-AI/aider/issues/4359), Jul 2025) — **0
reactions, 0 comments, no maintainer reply.** Total silence. By contrast,
**"confirm each change before applying"**
([#649](https://github.com/Aider-AI/aider/issues/649), Jun 2024) — **41 reactions,
38 comments, still open**, no visible maintainer response: the one visual/UX ask
with real sustained traction (for calibration, MCP support got 244 reactions, so 41
is modest-but-real, far above every other diff/TUI-titled issue which sit at 0–3).
Textual/two-console request ([#944](https://github.com/Aider-AI/aider/issues/944))
— 1 reaction, closed unaddressed. No maintainer rationale defending minimalism was
found — the silence on #4359/#4332/#4263 reads as passive deprioritization, not an
articulated philosophy, though the `--browser` escape valve suggests a deliberate
"if you want more, use the browser" split rather than active refusal.

**HORROR:** [#5399](https://github.com/Aider-AI/aider/issues/5399) (Jul 2026):
waiting-animation *"climbs a staircase"* — progressively shifts rightward across
the terminal instead of updating in place, reproduced in tmux/Konsole/xterm, no
maintainer response. PR #3911 (closed unmerged, May 2025): a waiting-indicator fix
caused *"rapid flickering"* / *"a strobe effect"* on Windows Terminal+WSL2.

**Panels/nav:** No folding/collapsing exists. Only Ctrl-Up/Ctrl-Down message-history
recall (not scrollback control). Pager/navigation requests (#4332, #4263) got
near-zero engagement — genuine low demand, unlike #649 (confirmation UI), which
shows real, unaddressed demand. **Net read: the inline restraint itself is
defended/praised reflexively when compared to flashier rivals, but diff-legibility
and edit-approval gaps are real, recurring, unaddressed pain — not resolved
philosophy, just neglect.**

---

## 5. goose (block/goose → aaif-goose/goose)

**Ships visually:** Three separate codebases share the name. **Rust CLI**
(`crates/goose-cli`): a scrolling inline/stream printer, not alt-screen — uses the
`bat` crate for markdown syntax highlighting and `rustyline` for input. On resize,
a maintainer stated: *"Goose deliberately uses `bat` with `NoWrapping` mode... the
terminal emulator wraps the raw output at its current width... If your terminal
isn't reflowing on resize, that's a limitation of the specific terminal emulator
rather than something goose can address."*
([#8177](https://github.com/aaif-goose/goose/issues/8177), closed
working-as-intended). A separate newer **Ink TUI** (`ui/text/`, npx `@aaif/goose`)
exists as its own codebase. A third, "Goose2," is the Electron desktop app's
internal codename (sidebar/panels — out of scope). **No persistent
sidebar/todo/plan panel exists in the terminal surface** — desktop only.
Context-window feedback is deliberately an inline per-turn text note, not a panel:
*"For the CLI, perhaps a small text note at the end of each turn with the
number-of-tokens remaining"* ([#1208](https://github.com/aaif-goose/goose/issues/1208)).

**LOVE:** Thin. Clearest positive signal: the context-window request itself got
**7 👍** and shipped (*"This is live!"*, Jun 2025,
[#1208](https://github.com/aaif-goose/goose/issues/1208)). No forum threads
praising the CLI's aesthetics were found — goose is the lowest-visual-salience tool
in the cohort.

**HATE:** Solarized Dark/Light: *"this is impossible to read"*
([#1905](https://github.com/aaif-goose/goose/issues/1905), 5 👍). *"It would be
better to have an option to use only the terminal defined ANSI colors instead...
Hardcoding `GOOSE_CLI_THEME=light` doesn't work for people who switch themes
regularly."* Windows: *"goose CLI updates are rendered as new lines instead of
updating in place"* ([#8422](https://github.com/aaif-goose/goose/issues/8422)).
*"Pasting into CLI auto executes and creates an infinite prompt loop"*
([#8059](https://github.com/aaif-goose/goose/issues/8059), also #10326 on
Windows). *"CLI shell output streaming too verbose in v1.18.0"*
([#6216](https://github.com/aaif-goose/goose/issues/6216)).

**DEMANDED BUT MISSING:** ANSI-passthrough / auto dark↔light theme switching
(#1905 thread). *"CLI: More clearly highlight model response messages amongst tool
call results"* ([#10419](https://github.com/aaif-goose/goose/issues/10419), open).
Interactive session-resume picker ([#10265](https://github.com/aaif-goose/goose/issues/10265),
only recently merged). `/model`, `/status` mid-session commands
(#9412, #9845) — recent additions suggesting long absence.

**HORROR:** [#10075](https://github.com/aaif-goose/goose/issues/10075):
"Streamed output has O(n²) rendering across all three frontends" (2026-06-28, repro
2026-07-12): with a local 250 tok/s model, *"generation completes, then the UI
keeps 'typing' for minutes afterward... in a long session the UI is only updating
at around 1 tok/s."* Root cause in the Rust CLI: `bat::PrettyPrinter` rebuilt from
scratch per flush, plus a full-buffer rescan on every safe-end check (measured
258ms for a 4000-line block; fixed in PR #10487, 1.19s → 2.4ms). Related: the Ink
TUI's unconditional 300ms animation interval caused unbounded re-renders and a
**JS heap OOM** even at idle ([#8616](https://github.com/aaif-goose/goose/issues/8616),
"FATAL ERROR: Ineffective mark-compacts near heap limit").

**Panels/nav:** No persistent panels in the terminal surface; no confirmed
transcript folding in the CLI (collapse-tool-call UI exists only in Desktop,
#4340); no in-session search/jump anywhere in the CLI tracker — a genuine gap.

---

## 6. Amp CLI (Sourcegraph)

**Coverage caveat:** Amp has very little forum discussion specifically about
terminal visuals. HN threads (spinout announcement, "better than Claude Code,"
free-tier) are dominated by pricing/model-routing talk — zero UI comments in three
fetched threads. The one substantive technical critique comes from a single blog
post (Peter Steinberger), not a forum pile-on. Reddit surfaced no dedicated TUI
threads. Most visual info is Amp's own changelog (ampcode.com/news/*) —
self-reported, not community reaction.

**Ships visually:** Began on Ink and "shared Claude's flickering" (per
steipete.me), then wrote its own renderer and switched to **alt-screen mode** in
Sept 2025. The "Neo" rewrite (ampcode.com/news/neo, later folded back into "Amp"
per ampcode.com/news/drop-the-neo) reframed the CLI as "no longer just a
command-line tool, but a proper terminal user interface" — remote-controllable,
live message steering (↑ to select queued messages, Enter to run, "Esc Esc" to
interrupt), perf gains on long (~5000-message) threads. Single-stream-primary
layout with an optional **thread sidebar** (Ctrl+\\, thread list + per-thread
cost); no persistent todo/plan/context-meter panel — the model instead runs an
inline TO-DO checklist with per-step approval. Tool/reasoning output folds by
default, expandable via Alt+T. Notably, Amp **removed custom themes** in the
rewrite: *"Custom themes made it harder to keep the CLI legible, polished, and
recognizably Amp. We'd rather ship one good interface than support many
broken-looking ones."* (ampcode.com/news/neo) — a deliberate anti-choice stance,
unique in this cohort.

**LOVE:** Forum praise specific to visuals is scarce; strongest is second-hand
comparison-site language ("Amp's TUI is exceptional... probably the best TUI on
the market right now") of uncertain single-source provenance — low confidence.
Amp's own post claims the rewrite delivers "no flicker. No jarring redraws. No
stuttering text," "smooth scrolling while tool calls stream in"
(ampcode.com/news/look-ma-no-flicker) — vendor-sourced, unverified by forum
reaction.

**HATE:** The one concrete, quotable critique, from Peter Steinberger
(steipete.me/posts/2025/signature-flicker): coding agents in general "converged on
alt-screen TUIs — often after fighting flicker — but the results haven't been
great," and specifically for Amp: **"`find` fails unless the text is currently
on-screen,"** **"No native-feeling selection/context menu flow,"** and **"Custom
scrollbar; workable but not quite the terminal."** — a direct indictment of
alt-screen mode breaking native terminal search and text selection.

**DEMANDED BUT MISSING:** Volume too thin for a real pattern — closest is the
implicit ask (via Steinberger) for native terminal find/selection to keep working,
which alt-screen currently breaks.

**HORROR:** The Neo beta shipped unstable enough that Sourcegraph co-founder Quinn
Slack posted: **"We're still seeing and fixing bugs and instability in the Amp Neo
CLI. If you're in the Neo beta, run `amp --take-me-back` to use the non-beta Amp
CLI that is unaffected by these issues... I'm really sorry for these issues."**
(x.com/sqs, quote taken from search-indexed tweet text, moderate confidence). The
existence of a literal `--take-me-back` escape-hatch flag is itself a strong
rollout-instability signal.

**Panels/nav:** No fixed multi-pane dashboard — single-stream-first with a
toggleable sidebar (thread list + cost), not a persistent todo/plan/context panel.
Tool/reasoning output *is* foldable (Alt+T, collapsed by default). No working
in-session full-text search in alt-screen mode (native `find` breaks); only
message-level jump via Tab-then-`e` to edit prior messages, not true search.

---

## Cross-cutting questions

### A. opencode/Crush "prettiness" — specific praise, and does it convert?

What's specifically praised is **never just color**: for opencode it's the
custom renderer + client/server architecture ("built an entire custom TUI
backend... doesn't flicker at 30 FPS whenever it spawns a subagent" — dboon) and
the contrast it draws with Claude Code's Ink reconciler ("Claude's TUI feels more
like it's been grown than designed" — sshine). For Crush it's specifically the
**sidebar** and **diff/approval UX** ("Useful sidebar," "Better UX for accepting
changes (has hotkeys, shows nicer diff)" — alixanderwang) and the *absence* of
Claude Code's visible screen-shake ("the screen does not shake violently" —
LouisvilleGeek). So: layout + diff/approval ergonomics + rendering smoothness, not
theme/color per se.

Conversion is contested, not settled. One camp treats it as substantive
engineering that earns trust (dboon's post reads prettiness as evidence of a more
correct rendering architecture, not decoration). A second camp explicitly rejects
decorative flourish as noise: opencode's own logo-burst animation drew 17
thumbs-down ("Extremely annoying," #22098); progress-bar chrome drew "makes me
extremely anxious and distracted" (#21812) and "dizzy" (#21657). A third camp
argues the visual investment is actively counterproductive: jsnell called Crush
"tons of whitespace, line art, ascii art and gradients, and now apparently
animations" lacking basic keybindings/scrollback; plastic3169 called opencode
"TUI in appearance only" that breaks copy-paste and SSH, wishing it were a GUI
instead. **Verdict: prettiness converts when it demonstrably serves legibility/
diff-review/state-glanceability (sidebar, diff view, no-flicker); it is dismissed
or actively resented when it's decorative-only (animations, gradients, logo
bursts) — the split in this cohort is not "pretty vs. not" but "form that carries
information vs. form that doesn't."**

### B. Persistent panels vs pure stream

**Panels:** opencode (sidebar: sessions, modified files, skills, status bar with
context%/cost/mode), Crush (sidebar: session/model/git/LSP/MCP/todo pills, no
context meter), Amp (toggleable thread sidebar with cost, not persistent, no
context meter). **Pure stream:** Gemini CLI (inline todo block + footer %, no
sidebar), Aider (strictly inline, no panels at all), goose CLI (strictly inline,
panels exist only in the separate Electron desktop app).

Panel reception is genuinely mixed, not uniformly praised. Where panels carry
decision-relevant state (Crush's diff/approval sidebar, opencode's modified-files
list) they're called out by name as loved. Where panels are chrome-only (progress
bars, animated elements) they draw anxiety/dizziness complaints. **No challenger
has a context-% meter that satisfies users** — it's requested-and-missing in
Crush (#875) and requested-and-only-partially-delivered as a footer percentage in
Gemini CLI (#16130 still wants it "clearly in toolbar"). This is a converged,
unmet demand across the cohort, independent of panel-vs-stream philosophy.

### C. Aider's minimalism — praised or resisted?

Both, but asymmetrically. The *restraint itself* is reflexively praised in
comparative contexts: "it looks and feels the way a REPL is supposed to" (jsnell)
and explicitly framed as the right shape for running "10-20 AI coding agents" at
once, where "a lot of cursor's functionality is going to be vestigial" (CuriouslyC).
Nobody in this research produced a quote saying "Aider needs more chrome" in the
abstract. But two concrete complaints under the "minimal" umbrella have real,
unaddressed traction: diff legibility ("the least readable diff format I have
ever encountered... no visual indication of which lines changed" — slinkp) and
edit approval (#649, 41 reactions/38 comments, 18+ months open, no maintainer
response). "Is a TUI planned?" (#4359) got zero engagement — so the demand isn't
"give me panels," it's "make the two things I actually look at during a session —
diffs and approval — legible," while everything else can stay a REPL. Aider's
maintainers have not articulated a minimalism philosophy in public; the silence on
UI issues reads as *neglect*, not *doctrine*, with the `--browser` mode as the
unofficial escape valve for anyone who wants a richer surface.

### D. Transcript folding / search / jump navigation

**Folding exists:** Gemini CLI (Ctrl+O, plus shell auto-truncation), Amp (Alt+T,
folded by default). **Folding requested but not shipped:** opencode (#15935
closed unresolved, #37003 "Clean Output Mode" still open), Crush (#2917, "Hook
output should be collapsed by default... crowds out the actual output"). **No
folding, no forum demand found:** Aider, goose.

**Search:** Gemini CLI has session-level search via `/resume` (keyword filter
across past sessions) but not in-transcript search of the live session. opencode
has in-session search (#34297/#36526) with a buggy session switcher (#31965). Amp
has no working search in alt-screen mode — Steinberger's critique that native
terminal `find` breaks is the sharpest demand signal in the whole cohort for this
category, because it's a *regression* (something the terminal used to give you
for free) rather than a missing feature. Crush, Aider, goose: no search found.

**Jump:** Only Amp has anything jump-like (Tab-then-`e` to edit a prior message),
and it's message-editing, not transcript navigation. No challenger has anything
resembling Warp/Wave "command blocks" jump-to-previous-diff navigation. **This is
the most under-built category across the entire cohort** — folding is inconsistent,
search is either session-level-only or actively broken by alt-screen mode, and true
jump/navigation of a long transcript doesn't exist anywhere in this cohort.

### E. Convergence vs. fragmentation

**Converges (2+ tools):**
- Alt-screen adoption for "serious" TUIs (opencode, Crush, Amp) vs. inline-stream
  for "minimal" tools (Aider, goose CLI, and Gemini CLI's default mode) — a real
  two-camp split, not a spectrum.
- Flicker/repaint-storm bug reports on *every single tool* researched, regardless
  of renderer (Ink: Gemini, early Amp; Bubble Tea: Crush; custom OpenTUI: opencode;
  bat/rustyline: goose Rust CLI). Flicker is not a framework problem, it's a
  category problem.
- Multi-line paste corruption reported independently in Gemini CLI and goose.
- Theming shipped late/reactively, not day-one, in both Crush and Gemini CLI (and
  goose's theme system is actively disliked); Amp is the one outlier that
  deliberately *removed* theme choice.
- Context-window visibility requested-and-unsatisfied in Crush, Gemini CLI, and
  goose (goose's is the most resolved — a shipped inline note — the other two are
  open asks).
- Tool-output folding requested in opencode and Crush, both unresolved or
  half-resolved.

**Fragments (one-off, not replicated elsewhere):**
- opencode's client/server multi-renderer architecture (unique in this cohort).
- Amp's deliberate removal of theme customization ("we'd rather ship one good
  interface" — the only anti-customization stance found).
- goose's three-separate-codebases-under-one-name situation (Rust CLI / Ink TUI /
  Electron desktop) — a fragmentation-of-the-product-itself, not a UI pattern.
- opencode's decorative logo-burst animation and its 17-thumbs-down rejection —
  a one-off experiment, explicitly walked back by user reaction.
- Aider's `--browser` mode as an escape valve for richer visuals without touching
  the terminal surface — no other challenger offers a parallel non-terminal
  surface as pressure release.

---

## Priors check (against `../harness-ui-cohort-research.md` Phase 2)

- **Flicker/scrollback as #1 visual pain [CONFIDENT]** — confirmed, strongly.
  Every tool researched has open, often-duplicated flicker/repaint issues; this is
  the single most consistent complaint category in the entire cohort.
- **Persistent panels as rare/unproven demand [GUESSING]** — partially refuted.
  Panels aren't rare (3 of 6 challengers ship them) and aren't uniformly unproven —
  Crush's sidebar is named directly in "love" quotes. The prior undersold panel
  adoption but was right that *decorative* panel elements (progress bars,
  animations) are actively resented.
- **Long-transcript navigation as a real gap [CONFIDENT-ish]** — confirmed and
  strengthened: this cohort has no jump navigation at all and only inconsistent
  folding/search — worse than the prior assumed.
- **Diff/code rendering quality matters [CONFIDENT]** — confirmed: opencode's
  #17076 (+18, the largest reaction count in this whole research pass) and
  Aider's #649 (41 reactions) both concern diff/approval review, the two highest-
  traction UX issues found in the entire cohort.
- **Terminal-compat degradation as low-volume/silent-bounce [GUESSING
  frequency]** — roughly confirmed: colorblind/light-theme complaints exist
  (Crush #755 at 39 reactions is actually not low-volume) but are outnumbered by
  flicker/paste/diff complaints.
- **New finding not in priors:** alt-screen mode systematically breaks native
  terminal `find`/copy-paste/mouse-select across every alt-screen challenger
  (Crush #373, Amp/Steinberger, opencode/plastic3169) — this is a convergent,
  named cost of the "application you inhabit" shape that the priors did not
  anticipate as its own cluster.
