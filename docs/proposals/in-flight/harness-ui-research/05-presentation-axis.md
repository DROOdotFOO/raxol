# Presentation Axis: Where Forum-First Research Under-Samples Visual Failure

Mandate: forum-first cohort research over-indexes on *content* complaints ("it wrote wrong code")
because that's what people write paragraphs about. Presentation failures — bad contrast, tofu
glyphs, flicker, misaligned emoji — are usually followed by silent abandonment, not a bug report.
This brief hunts the places where the presentation reaction DOES surface: Show HN threads, GitHub
issues that are unambiguously about pixels, accessibility writeups, and designer commentary on
terminal aesthetics.

---

## 1. Dated horror stories

| Date | Tool | Failure | Severity |
|---|---|---|---|
| ~Dec 2025 – May 2026 (ongoing, "Claude Chill" HN thread ~Feb 2026) | Claude Code | Full-viewport flicker during streaming ("looks like a slot machine," "giving me a headache"). Root cause: Ink re-renders the entire component tree per state change; no DECSET 2026 synchronized-output batching. | High — quoted user: *"after evaluating Claude vs Codex, this problem alone made me pick Codex"* and *"I had to use Codex today cause claude kept scrolling up."* Anthropic's Chris Lloyd acknowledged on HN: *"we shipped our differential renderer to everyone today... only ~1/3 of sessions see at least a flicker."* That "only 1/3" admission is itself notable — a full third of sessions had a visible defect before the fix shipped. |
| Mar 2, 2026 | Claude Code v2.1.63 | tmux render corruption: text from different render cycles drawn at overlapping screen positions, unreadable, persists until session restart. `Ctrl-L` and tmux's own redraw (`prefix+r`) do **not** fix it — only `/clear` or full restart. GitHub #29937. | High — described by reporter as making the interface unreadable / normal usage impossible. |
| Mar 22, 2026 | Claude Code | Confirmed missing DECSET 2026 (synchronized output) support in the Ink-based renderer while running under tmux, despite tmux 3.4+/iTerm2/Alacritty/kitty/foot/Windows Terminal all supporting it. GitHub #37283. Closed **"not planned."** | Medium-high — a known standard fix, declined. |
| Mar 28, 2026 | Claude Code | Light (ANSI-only) theme uses ANSI white (palette 7) for punctuation, deleted-diff strikethrough text, and some line numbers — invisible on any light palette (Solarized Light, Catppuccin Latte). GitHub #40071. | High for the affected cohort — text is not dim, it is **gone**. |
| Feb–Apr 2026 (issue cluster) | Claude Code | At least 8 distinct open GitHub issues about light-theme/contrast breakage in the same window: #40825 (diff text invisible on macOS light terminal), #26326 (theme-selector text unreadable in VS Code terminal), #49839 (dim/secondary text uses ANSI bright-black, near-invisible on light palettes), #29706 (general color rendering bug), #39352 ("Light Color Scheme Broken on 2.1.77+"), #27782 (bold markdown invisible on iTerm2 light bg), #11371 (Warp light mode unreadable question text), #40905 (color7 reused for both code text and UI backgrounds). | The clustering itself is the finding: this isn't one bug, it's a *systemic* light-theme blind spot that keeps re-surfacing release after release — evidence the team tests almost exclusively on dark themes. |
| Nov 4, 2025 | Claude Code | GitHub #11002 requests a `--screen-reader` flag (disable spinners/color/animation, emit linear text) modeled on Gemini CLI's approach. Comment thread reports NVDA **freezing** during token-stream/spinner updates, forced screen-reader restarts mid-session, and the CLI vocalizing garbage (stray `\|` characters, partial Unicode fragments). Still open, unassigned, no PR, 8+ months later as of this research. | Severe for the affected cohort — total exclusion, not degradation. |
| Undated, recurring | gemini-cli (Ink/Node) | Documented by an accessibility writer (xogium.me, "The text mode lie") as the flagship failure case: constant redraw-driven cursor teleportation makes NVDA read *"Responding... Time elapsed 1s... Responding... Time elapsed 2s... [fragment of chat history]..."* — incoherent word salad. Pasting text can crash NVDA outright from re-render load. | Severe — total exclusion. |
| 2025→2026, recurring across many CLIs | opencode/hermes-agent-style panel renderers | `len()`/code-point counting instead of display-width for CJK/emoji causes ~40% underestimate of visual width (e.g. `"⚠️ 危险命令"` = 7 code points but ~12 terminal columns) → box borders too narrow, content overflowing panel edges. | Medium — cosmetic but recurring across independent projects, meaning it's a systemic gap in TUI framework width-calculation defaults, not a one-off bug. |
| Sep 18, 2025 | OpenCode (original, pre-Charm) | Project archived/made read-only after being folded into Charm's Crush. Not a "revolt" but a discontinuity worth flagging: users who'd built workflows/rice around OpenCode's minimalist off-white/near-black monospace aesthetic had to migrate to Crush's much more decorated "glamourous" style — a forced aesthetic migration, not opt-in. | Low-medium, but relevant to churn-from-redesign question. |

### The pattern under the pattern
Every dated Claude Code horror story above is Ink-architecture-shaped: full-tree redraw (flicker,
tmux corruption), no synchronized-output escape sequences (cursor jumps), color choices tuned to
one theme family (dark) and shipped without light-theme test coverage. This is not four unrelated
bugs, it's one architectural decision (declarative virtual-DOM-style re-render onto a raw terminal)
producing four distinct symptom families. Direct relevance to Raxol: the render pipeline described
in this repo's CLAUDE.md (diff-based `ScreenBuffer` → `Terminal.Renderer`, not full-tree redraw)
is structurally the fix for the single largest cluster of complaints found in this research.

---

## 2. First-impression evidence, per tool

**Claude Code** — First reaction to the *concept* is often skeptical ("a terminal interface for
chat-based code editing… sounds like a step backward"), converting to appreciation once people use
it, particularly framed as "made the terminal accessible to people like me" (non-hardcore-terminal
users). But the *rendering itself* draws visible-on-screen complaints once used heavily: flicker,
light-theme invisibility, tmux corruption (all above). No Show HN thread specifically for Claude
Code's TUI was found (it launched via blog post, not Show HN) — the entry point for first
impressions is mostly YouTube walkthroughs and blog "how Claude Code's terminal UI works" posts,
which describe the interface as spinners/notifications/prompts that read as "noise" until learned.

**Crush (Charm, ex-opencode-successor)** — Show HN thread (news.ycombinator.com/item?id=44736176)
is the single richest first-impression data point found. Split reaction:
- Enthusiasts: *"ridiculously pretty,"* 5-star rating "based on appearance alone," *"Woah I love the
  UI... this feels like the most enjoyable to use so far"* (explicit contrast with Claude Code's
  screen "shaking violently" — i.e., the flicker problem above is being used by competitors as a
  differentiator in the wild).
- Skeptics: *"tons of whitespace, line art, widgets, ascii art and gradients"* combined with
  animation was called out as **not** how "fullscreen Unix TUIs normally would" feel, with an
  explicit unfavorable contrast to Aider ("looks and feels the way a REPL is supposed to"). One
  commenter called the glamour styling *"a marketing gimmick"* — "slick and powerful and scifi and
  cool" over substance. Another noted concrete functional gaps behind the polish: missing
  keybindings, tab completion, consistent scrollback, "even flicker-free text rendering."
This thread is the clearest evidence in this research that **aesthetic polish and functional
polish are judged as separate axes** by the same commenters in the same breath — pretty does not
buy a pass on missing tab-completion.

**opencode (original, pre-archive)** — Reviewers: "super clean and intuitive," "clean TUI," "one of
the simplest and fastest setups." Design described independently (opendesign.cc catalog) as
deliberately minimalist: strict monochrome, off-white background / near-black ink, fully monospace
typographic system — i.e., restraint-as-aesthetic, the inverse of Crush's later "glamourous" pivot
under Charm. The project's archival (Sep 2025) after merging into Crush is the closest thing found
to a documented aesthetic-lineage discontinuity.

**Codex CLI (OpenAI)** — Least presentation-focused reaction found. Coverage is functional
("rubber duck that talks back"), with one aside that the terminal interface "removes the
possibility of a chat-like conversation in a beautiful environment... though terminal interfaces
are charming." No Show HN visual-first-impression thread surfaced. Also built on Ink/React — it
inherits the same architectural family as Claude Code, so the same flicker/redraw risk class
applies, though no equivalent horror-story cluster surfaced in search (could be under-reported
rather than absent — matches the brief's own thesis about silent bounce).

**GitHub CLI (`gh`)** — Not an agent CLI but the explicit positive accessibility counter-example:
GitHub publishes a dedicated screen-reader usage guide (accessibility.github.com) and the CLI's
plain, non-animated, non-full-screen output model means it doesn't trigger the redraw/cursor-jump
failure mode at all. It wins on presentation-for-accessibility by *not* doing a TUI.

---

## 3. Accessibility: what happens when a screen reader meets an agent TUI

Findings converge on one mechanism: **any framework that treats the terminal as a redrawable 2D
canvas (Ink, Bubble Tea, tcell) is structurally hostile to screen readers**, independent of how
polished it looks sighted. The failure isn't a missing ARIA-equivalent — screen readers are reading
the literal cursor-controlled character stream — so every spinner tick or timer update that moves
the hardware cursor produces an audible interruption or a scrambled read-out.

- **gemini-cli** is the named flagship failure: NVDA reads fragmented garbage during streaming
  (*"Responding... Time elapsed 1s... Responding... Time elapsed 2s... [fragment]..."*), and pasting
  text can crash NVDA from render load.
- **Claude Code**: NVDA freezes during token-stream/spinner updates, forces mid-session
  screen-reader restarts, vocalizes stray characters (`|`, partial Unicode). A `--screen-reader`
  flag has been requested since Nov 2025 (#11002, modeled explicitly on what Gemini CLI already
  attempts) and remains open/unassigned 8+ months later.
- **What's demanded, consistently**: a flag to fully disable spinners/animation/color and fall back
  to a flat, linear, append-only text stream — i.e., degrade the "TUI" all the way back to a "CLI."
  This is the same fallback direction as the light-theme and low-color degradation asks below; there
  is no accessibility-specific innovation being asked for, just an escape hatch to the older, dumber
  mode.
- **Tools cited as doing it right**: nano/vim (can disable cursor tracking entirely), menuconfig
  (single-column focus, no cursor scatter), Irssi (VT100 scrolling regions + hardware-level line
  append rather than character-by-character full redraw). None of these are agent CLIs — the
  accessible precedents all predate the LLM-agent-TUI wave, which suggests the current generation of
  agent CLI authors did not consult prior art before picking Ink/Bubble Tea.
- Direct quote worth keeping as a design constraint: *"a dumb, linear CLI stream is infinitely
  superior [for accessibility] to reactive TUIs causing lag and cursor chaos."*

---

## 4. Degradation matrix (evidence-backed)

| Surface / constraint | What breaks | Evidence | Tools handling gracefully |
|---|---|---|---|
| **tmux / multiplexers** | Flicker, cursor-jump, and full render corruption (text overwritten at wrong coordinates, unrecoverable without restart) | Claude Code #29937, #37283, #9935 (4,000–6,700 scroll events/sec reported); "Claude Chill" HN thread | Irssi (VT100 scroll regions); tools using DECSET 2026 synchronized output (kitty, Alacritty, foot natively support it — the *terminal* is ready, the *TUI framework* often isn't) |
| **Light terminal themes** | Text set to ANSI white (palette 7) or bright-black (palette 8) becomes near-invisible; affects punctuation, diffs, dim/secondary text, line numbers | 8 distinct Claude Code GitHub issues, Feb–Apr 2026 window (#40825, #26326, #40071, #49839, #29706, #39352, #27782, #11371, #40905) | None found explicitly praised; the fix pattern requested everywhere is "use terminal default foreground, don't hardcode a semantic ANSI slot whose luminance flips between theme families" |
| **Nerd Font / box-glyph availability** | Tofu (empty boxes) when PUA glyphs aren't in the active font; version skew between font and consuming tool drops specific glyphs | ryanoasis/nerd-fonts #445, #1190, #844 (box-draw glyphs unrenderable outside a real terminal) | SymbolsOnly fallback variant + OS font-fallback is the documented safe pattern; Nerd Font **Mono** variant avoids double-width surprises |
| **256-color / no-truecolor fallback** | Vim/agent syntax highlighting slows or mis-renders under mosh (which only advertises 8/256 color even when the underlying terminal does 24-bit); `TERM=xterm-direct` unsupported by mosh | mobile-shell/mosh #487, #928 | N/A — root cause is protocol-level (mosh doesn't propagate true `TERM`/color depth), not app-level; agent CLIs inherit whatever the shell reports |
| **Windows Terminal / emoji width** | Wide emoji width miscalculated → cursor lands one cell off after typing/rendering an emoji; independent recurrence in Microsoft Terminal (#4345, #5910, #529, #16852), Lipgloss/Bubble Tea (#562), fish-shell (#10461), neovim (#4976) | Six independently-filed issues across unrelated projects, all the same root cause (code-point count vs. wcwidth-style display width) | wcwidth-based width calculation is the universally cited fix; none of the surveyed agent CLIs were reported as having solved it project-wide |
| **80-column / width detection failure** | `$COLUMNS`/`$LINES` report 0 or stale → Ink renderer silently falls back to 80-col default even in a much wider real terminal, leaving most of the screen blank | Claude Code #45556 | — |
| **SSH generally** | Mostly propagates `TERM` correctly (per mosh docs); breakage is downstream of `TERM`/color-depth mismatch, not SSH itself | mosh.org docs | — |

**Reading the matrix**: every row traces to the same two root causes — (1) width/position
calculated by code-point count instead of true display width, and (2) full-buffer redraw instead
of diff/append. Raxol's architecture (per this repo's CLAUDE.md: `Raxol.UI.TextMeasure` as a single
display-width facade, `ScreenBuffer` diffing before `Terminal.Renderer`, and the newly-landed
incremental/diff terminal render path) is already structurally aligned against both root causes —
this is corroborating field evidence that those design choices target the actual failure modes
competitors are hitting in production, not hypothetical ones.

---

## 5. "Looks hostile" vs. "looks trustworthy"

No rigorous study was found (this axis is thin in the literature); what surfaced is designer
intuition plus one directly relevant empirical proxy:

- **Charm's stated philosophy** (charm.land blog, secondary sources): "respect for the craft, and
  respect for the end-user — even when that user is another developer staring at a blinking
  cursor." Their commercial bet (Crush) is that *decoration signals care*, not laziness — directly
  opposed to...
- **The "AI design slop" empirical finding** (adriankrebs.ch, n=1,590 Show HN submissions): gradient
  backgrounds, glow/box-shadow, glassmorphism, and colored card borders are the exact visual
  vocabulary that reads as "generic AI-generated defaults, not deliberate design" to a
  developer-heavy audience — 22% of submissions triggered 4+ such flags. This is the empirical
  version of the Crush-thread skeptic's complaint almost verbatim ("scifi and cool... as a marketing
  gimmick").
- **Synthesis**: the same visual vocabulary (heavy color, gradients, glow, dense ornament) reads as
  *trustworthy craft* to one audience segment and *hostile/lazy AI slop* to another, in the **same
  population** (HN commenters) within the **same thread** (the Crush Show HN). The variable isn't
  the amount of decoration, it's whether decoration is perceived as *substituting for* missing
  functional polish (tab completion, keybindings, flicker-free rendering) or *accompanying* it.
  Restraint (Aider, original opencode's monochrome) reads as trustworthy by default because it
  can't be accused of compensating for anything. Decoration (Crush) has to *earn* trust by shipping
  the boring functional stuff too, or it gets read as marketing.
- No direct evidence was found on motion/animation specifically as a trust signal beyond "flicker
  reads as broken" — that's a reliability signal more than an aesthetic one, but the two blur:
  several Crush-thread comments used "shakes violently" (Claude Code) as shorthand for "feels
  unreliable," not just "looks bad."

---

## Cross-cutting answers

**A. Severity × irreversibility — which failures cause silent, unfiled loss?**
Best candidates, ranked by how likely the user never files anything:
1. Screen-reader users hitting gemini-cli/Claude Code's redraw chaos — this population is smallest,
   most likely to just leave the tool entirely and not file (filing itself may be hard via a
   broken screen-reader session), and the one confirmed 8-month-old unfixed open ask (#11002)
   suggests low org attention even when it IS filed.
2. Light-theme users hitting invisible text on first run — the sheer number of independently-filed,
   overlapping issues (8+ in a 3-month window) for what's fundamentally one root cause strongly
   implies many more users just switched to a dark theme or a different tool without ever filing.
   Filing requires recognizing "the text is there, just invisible," which not everyone diagnoses.
3. Non-nerd-font / tofu-glyph users on first run — silently unreadable box-drawing chrome reads as
   "broken tool," most likely abandoned in the first 30 seconds, before any investment in filing a
   report has accrued.
The one directly-confirmed case of *visible* loss (not silent) is the flicker-driven Claude→Codex
switch quoted in section 1 — valuable precisely because it's the rare case where the silent-bounce
became a vocal, dated, attributable data point.

**B. Does "pretty" (Crush/opencode) actually win users from "plain" (Aider/Claude Code)?**
Evidence is mixed and this is the most important finding for the "pretty vs plain" debate: pretty
*attracts* first-look attention and *some* explicit preference ("most enjoyable to use so far,"
5-star-for-looks-alone), but does not appear to purchase forgiveness for functional gaps — the same
thread that praised Crush's looks also flagged its missing keybindings/tab-completion/flicker-free
rendering as unresolved, and independently the "AI slop" framing shows dense ornamentation can
actively read as *lower* credibility to a technical audience. The strongest form of the claim
supportable by this research: **prettiness wins the first 10 seconds of attention (Show HN
upvotes, screenshot shares) but restraint (Aider, plain CLI-style tools) wins the "is this a serious
tool" credibility check** for a developer audience specifically. Plain isn't being dismissed; it's
the default trust position that decorated tools have to actively earn their way past.

**C. Emoji/unicode width breakage — how often does it surface as visible corruption?**
More often than the forum corpus would suggest, and clearly **systemic rather than tool-specific**:
independently filed against Microsoft Terminal (4 issues), Bubble Tea/Lipgloss, fish-shell, neovim,
and at least one custom agent-CLI panel renderer (hermes-agent, ~40% width underestimate on
CJK/emoji causing panel-border overflow). The consistent root cause (code-point count vs.
true display width) recurring across five-plus unrelated codebases is strong evidence this isn't
one team's bug — it's the default trap in most string-length APIs, and any renderer that doesn't
explicitly route through a wcwidth-equivalent will eventually hit it. Directly validates this
repo's `Raxol.UI.TextMeasure` single-facade rule as the correct structural guard, not
over-engineering.

---

## Sources

- https://github.com/anthropics/claude-code/issues/40825
- https://github.com/anthropics/claude-code/issues/26326
- https://github.com/anthropics/claude-code/issues/40071
- https://github.com/anthropics/claude-code/issues/49839
- https://github.com/anthropics/claude-code/issues/29706
- https://github.com/anthropics/claude-code/issues/39352
- https://github.com/anthropics/claude-code/issues/27782
- https://github.com/anthropics/claude-code/issues/11371
- https://github.com/anthropics/claude-code/issues/40905
- https://github.com/anthropics/claude-code/issues/29937
- https://github.com/anthropics/claude-code/issues/37283
- https://github.com/anthropics/claude-code/issues/9935
- https://github.com/anthropics/claude-code/issues/37076
- https://github.com/anthropics/claude-code/issues/66795
- https://github.com/anthropics/claude-code/issues/45556
- https://github.com/anthropics/claude-code/issues/11002
- https://news.ycombinator.com/item?id=46699072 ("Claude Chill" flicker fix)
- https://news.ycombinator.com/item?id=44736176 (Crush Show HN)
- https://news.ycombinator.com/item?id=44482504 (OpenCode Show HN)
- https://xogium.me/the-text-mode-lie-why-modern-tuis-are-a-nightmare-for-accessibility
- https://www.osnews.com/story/144892/the-text-mode-lie-why-modern-tuis-are-a-nightmare-for-accessibility/
- https://github.com/ryanoasis/nerd-fonts/issues/445
- https://github.com/ryanoasis/nerd-fonts/issues/1190
- https://github.com/ryanoasis/nerd-fonts/issues/844
- https://github.com/mobile-shell/mosh/issues/487
- https://github.com/mobile-shell/mosh/issues/928
- https://github.com/microsoft/terminal/issues/4345
- https://github.com/microsoft/terminal/issues/5910
- https://github.com/microsoft/Terminal/issues/529
- https://github.com/microsoft/terminal/issues/16852
- https://github.com/charmbracelet/lipgloss/issues/562
- https://github.com/fish-shell/fish-shell/issues/10461
- https://github.com/neovim/neovim/issues/4976
- https://github.com/NousResearch/hermes-agent/issues/20621
- https://charm.land/blog/100k/
- https://www.adriankrebs.ch/blog/design-slop/
- https://www.xda-developers.com/moved-to-crush-from-claude-code/
- https://thenewstack.io/terminal-user-interfaces-review-of-crush-ex-opencode-al/
- https://accessibility.github.com/documentation/guide/cli/
- https://blog.tymek.dev/claude-code-flickering-in-tmux/
