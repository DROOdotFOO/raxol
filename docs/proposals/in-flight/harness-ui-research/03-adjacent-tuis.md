# Adjacent Power-TUIs: Layout/Visual Patterns an Agent Harness Can Steal

Research brief 03 for harness-ui. Forum-first cohort research (GitHub issues/discussions, HN,
Reddit where reachable, blog writeups) on layout containers from adjacent tools that solved
"supervise a live system from a terminal." NOT about the tools' agent/AI features — only the
layout/visual container models, and users' actual verdicts on them.

Method note: Reddit (r/commandline, r/unixporn) was blocked for direct fetch in the research
environment; HN threads, GitHub issues/discussions, and practitioner blogs were the primary
forum sources. Every claim carries a URL. Judgment calls are explicitly marked
**TRANSFER JUDGMENT**.

---

## 1. Warp (command blocks)

### Layout container model

Window → Tabs → Split Panes → scrolling stack of **Blocks**. A Block is the atomic visual
unit: "Blocks group your command and command output" — prompt + typed input + output grid in
one container, architecturally a `BlockList`, "an ordered list of blocks: typed, self-contained
units of content that stack vertically and scroll together," virtualized (only in-viewport
blocks render) via a SumTree index ([Warp blog](https://www.warp.dev/blog/block-model-behind-warps-agentic-development-environment)).
Blocks grow bottom-to-top, are color-coded (non-zero exit = red sidebar/background), and a
"Sticky Command Header" pins the originating command line at top when output scrolls off-screen
([docs](https://docs.warp.dev/terminal/blocks/block-basics/)). Rich content (agent conversation
views) appears as a distinct block type interleaved with ordinary command blocks in the same
scroll stream — no separate chat pane. Panes are draggable by header into other tabs or torn
out ([docs](https://docs.warp.dev/terminal/windows/split-panes/)).

### LOVE

- "The _block_ system where you could navigate up and down without scrolling the whole buffer
  rigidly" + "The tabbing system that actually works and doesn't feel clunky" — touristtam,
  [HN](https://news.ycombinator.com/item?id=47972161)
- "most of Warp is really centered around trying to make a terminal interface not anchored to
  legacy assumptions, like the blocks functionality" — crooked-v,
  [HN](https://news.ycombinator.com/item?id=47978172)
- Blocks called "one of the biggest Warp features" the author "love[s] and take[s] advantage
  of ... all the time" — kills `| more`/`| grep` piping because block output stays "selectable,
  filterable, and modifiable" post-execution; block bookmarking (⌥-↑); live search inside
  running `htop`/`tail -f` — [scottwillsey.com](https://scottwillsey.com/warp-blocks/)
- "Block sharing ... has completely replaced screenshotting and copy-pasting terminal output in
  our team" — David Stern, [Warp blog](https://www.warp.dev/blog/how-warp-uses-warp)
- Decade-plus iTerm user switched after "I saw Warp's use of blocks" —
  [Product Hunt reviews](https://www.producthunt.com/products/warp/reviews)

### HATE

- "Please let me disable blocks (the big red squares)": "I have no idea what blocks are for.
  They have offered no benefit to me so far" — block click steals keyboard focus from the
  active command line; **closed as not planned** —
  [Warp#3189](https://github.com/warpdotdev/Warp/issues/3189)
- "I have no use case for blocks. All I want is a simple pane that shows all historical
  results ... they crowd the UI ... I already have tabs and panes, why do I need another
  subdivider?" — rated 5/5 importance, **closed as not planned** —
  [Warp#3227](https://github.com/warpdotdev/Warp/issues/3227)
- Block-selection-on-click "very frustrating when switching windows" —
  [Warp#5195](https://github.com/warpdotdev/warp/issues/5195)
- With Claude Code producing long output in one active block: "Every keystroke causes the
  terminal to scroll up to the top of the conversation history and then back down ... creating
  a strobing/flashing effect" at ~5-6 pages scrollback; doesn't occur in iTerm2 —
  [Warp#8089](https://github.com/warpdotdev/warp/issues/8089)
- Per-block scrollback limit drove a user back to iTerm2 for long server logs; **closed as not
  planned** — [Warp#2463](https://github.com/warpdotdev/Warp/issues/2463)
- "Right now blocks and input don't work within tmux sessions" (maintainer); heavy tmux users
  abandon Warp over it; unresolved since 2021 —
  [Warp discussion #501](https://github.com/warpdotdev/Warp/discussions/501)
- Copy-on-select broken inside vim/less/git-log ([Warp#2758](https://github.com/warpdotdev/warp/issues/2758));
  no keyboard-only selection inside blocks comparable to tmux copy-mode
  ([Warp#3436](https://github.com/warpdotdev/Warp/issues/3436))

### TRANSFER JUDGMENT (Warp)

Grouping each agent tool-call + output into a visually distinct, collapsible block is
high-value, low-risk — it's the use case users praised most concretely (jump to a unit, re-run
a unit, copy/share a unit), and tool-call boundaries are already semantically discrete, so
blocks map onto real structure instead of an imposed abstraction. Three hard warnings:
(1) never let a single tool-call's streaming stdout become one giant re-rendering block
(Warp#8089 strobing is the exact failure mode for long agent builds/tests); (2) never let
block-selection intercept keystrokes meant for the live approve/deny prompt (#3189/#3227 root
cause); (3) keep a coherent flat raw transcript underneath the block chrome for users who want
blocks off.

---

## 2. Wave (blocks-as-tiles)

### Layout container model

Workspace → tiled mosaic of typed **Blocks** (not tabs+panes): terminal, AI chat, file/CSV/
image/PDF preview, web embed, sysinfo — drag-and-drop resizable tiles; layouts saveable/named
(e.g. "infra debugging" = 3 SSH terminal blocks + logs block + AI chat block) and restored
after reboot with scrollback intact ([docs](https://docs.waveterm.dev/layout),
[README](https://github.com/wavetermdev/waveterm)). Critical wrinkle: Wave's *per-command*
blocks (auto-created per executed command, individually re-runnable, with execution metadata)
were a defining pre-v0.8 feature that was **removed** in the v0.8 rewrite in favor of
"block = pane/widget."

### LOVE

- Inline previews: "Open a CSV, get a real table. Open a PDF, get a real PDF" —
  [moltamp.com review](https://moltamp.com/blog/wave-terminal-review-2026/)
- Keeping AI as its own block: "the boundaries between 'your shell' and 'the AI' are explicit
  instead of fused" — same review
- Founder pitch: "command blocks, output renderers, persistent sessions, and universal
  history" — sawka, [Show HN](https://news.ycombinator.com/item?id=38869559)

### HATE

- v0.8 removal of per-command blocks: "You can't relaunch them, they aren't created
  automatically with each command, you don't get info about execution ... Without this, it's
  pretty much like any other terminal emulator out there" — users switched back to Warp when
  restoration slipped through v0.9–v0.11 —
  [waveterm discussion #1084](https://github.com/wavetermdev/waveterm/discussions/1084)
- "Wave's blocks feel like extra work for the first few days ... by day five users have either
  adapted or given up — there is no middle ground"; CLI coding agents inside a Wave terminal
  block cause "visual glitches (orphaned cursor, stuck redraws, status bar artifacts)";
  "resize lag, occasional jank, memory footprint in the 400-800MB range" —
  [moltamp.com](https://moltamp.com/blog/wave-terminal-review-2026/)
- Layout customization requests closed as not planned —
  [waveterm#609](https://github.com/wavetermdev/waveterm/issues/609)

### TRANSFER JUDGMENT (Wave)

The single clearest cautionary tale in this research: **"block = semantic re-runnable unit"
and "pane/tile = spatial arrangement" are orthogonal concepts — don't collapse them.** Wave
did, and its own users said the product became "like any other terminal emulator." For a
harness, one tool call = one block with status/exit/duration metadata is the differentiator;
tiling mechanics are secondary. Wave's typed-block idea (distinct block types for terminal vs
AI chat vs preview) transfers directly as "tool-call blocks and agent-reasoning blocks as
visually distinct types in one chronological stream."

### Cross-cutting A verdict: command blocks — beloved, gimmick, or table stakes?

Neither pure gimmick nor universal table-stakes. The evidence puts blocks in a precise middle:
**a beloved differentiator when they solve a concrete pain (scrollback navigation, sharing
discrete output, re-running one unit), and active friction whenever they fight the terminal's
baseline input model** (focus stealing, tmux/vim clashes, unbounded-output performance).
Strongest pro signal: Wave users saying losing per-command blocks made it "pretty much like any
other terminal emulator" (blocks ARE the product). Strongest anti signal: Warp's own users
filing "let me disable blocks" at 5/5 importance. Nobody called blocks a gimmick outright — the
harshest framing was "I have no idea what blocks are for," a discoverability complaint.
Ghostty's minimalist crowd isn't asking for blocks, so not market-wide table stakes — but
functionally table stakes for anything marketing itself as an IDE-like/"reimagined" terminal,
which an agent harness is.

---

## 3. k9s (resource dashboard)

### Layout container model

Architecturally a **single-view drill-down stack**, not a multi-panel grid. Each view
(cluster → namespace → deployment → pod → container → logs) pushes onto a `PageStack`; `Esc`
pops back — browser-like navigation with a breadcrumb trail at the bottom
([cheatsheet](https://ahmedjama.com/blog/2025/09/the-complete-k9s-cheatsheet/),
[palark](https://palark.com/blog/k9s-the-powerful-terminal-ui-for-kubernetes/)). A fixed
header at top shows logo, cluster/context, resource counts, and the full list of active
keybindings for the current view (hideable via `Ctrl+e`). Command mode `:` jumps directly to
any resource type bypassing the drill-down; `/` filters the current view. Detail views
(describe/YAML/logs/shell) replace the table full-screen. Keys are context-sensitive per
resource type (`l` = logs on pods, `s` = scale dialog on deployments); destructive actions
split confirm-delete (`Ctrl-d`) from immediate-delete (`Ctrl-k`).

### LOVE

- "K9s has almost completely replaced 'kubectl' for me ... not much is faster than: 'k9s' -
  '/myservice' - 'l' (open the logs)" — mac-chaffee,
  [HN](https://news.ycombinator.com/item?id=36781077)
- "It's like Norton/Midnight commander for Kubernetes." — emersonrsantos, same thread
- "an interactive environment that allows for discoverability and real-time inspection ... dig
  into all corners of the cluster with a few keystrokes and get instant feedback" — perrygeo,
  same thread
- Faster than GUI alternatives (Octant) — mccabe,
  [HN](https://news.ycombinator.com/item?id=23364208)

### HATE

- "it's not exactly easy to use; it could have menus that are selectable by arrows or mouse" —
  throwawaaarrgh, [HN](https://news.ycombinator.com/item?id=36781077)
- Keybinding-budget exhaustion: "26*3=78 shortcuts total," 59 used by built-ins, 19 left for
  users — [k9s#2793](https://github.com/derailed/k9s/issues/2793)
- `Ctrl-d` conflicts with terminal/tmux bindings — [k9s#625](https://github.com/derailed/k9s/issues/625)
- Header too tall on split terminals; "The only information being important at all time in the
  header is the context" — [k9s#270](https://github.com/derailed/k9s/issues/270)
- Fluency erosion: "I've lost my fluency in kubectl, which is occasionally a hinderance" —
  lkozloff, [HN](https://news.ycombinator.com/item?id=36785801)

---

## 4. lazygit (multi-panel + keybar)

### Layout container model

The inverse of k9s: a **persistent multi-panel grid** — five always-visible side panels
(Status, Files, Branches, Commits, Stash) plus a main diff/detail panel. "Most views are
generally visible, always, no matter what operation you are doing"
([bwplotka.dev](https://www.bwplotka.dev/2025/lazygit/)). Focus moves via Tab/arrows/number
keys; a **bottom keybar** shows keys valid for the focused panel, changing per context.
Popups/modals handle confirmations (hard reset, force push) and a discoverable actions menu.
Design rule: "No global keybindings should have context-specific overrides"
([lazygit#1712](https://github.com/jesseduffield/lazygit/issues/1712)). `+`/`_` toggles
normal/half/fullscreen for the focused panel. Every underlying git command executed is echoed
to a visible command log. `?` opens context-sensitive keybinding help.

### LOVE

- "All commands are printed and rather complicated rebases become a breeze." — EinLama,
  [HN](https://news.ycombinator.com/item?id=36782018)
- "lazygit works very smoothly with the keyboard" vs VSCode's git UI which "really wants me to
  click" — williamdclt, same thread
- "lazygit somehow manages to show you all of this without visually overwhelming you";
  "after some time ... I was using shortcuts unconsciously" —
  [bwplotka.dev](https://www.bwplotka.dev/2025/lazygit/)
- "You land in a UI with five panels ... It sounds crowded — it's not." / "The speed-up isn't
  about the tools being fast. It's about your brain not having to switch contexts." —
  [configcrate.com](https://configcrate.com/lazygit-git-interface.html)

### HATE

- "how do I discover a command? In a GUI client you'd have a menu" — eviks,
  [HN](https://news.ycombinator.com/item?id=36782018)
- "I hadn't selected any files, and lazygit has processed each key-press as a command, and my
  repo is some bizarre state." — austinjp, same thread (accidental-keypress hazard)
- "Although we currently have the available keys shown in the options view at the bottom of
  the screen, it's not very obvious." —
  [lazygit#1712](https://github.com/jesseduffield/lazygit/issues/1712)
- Request for VSCode-style searchable command palette to fix keybinding discovery —
  [lazygit#4846](https://github.com/jesseduffield/lazygit/issues/4846)
- Panel real estate on small terminals: "the side panel takes up too many space"
  ([lazygit#4740](https://github.com/jesseduffield/lazygit/issues/4740)); no runtime panel
  resize ([discussion #2383](https://github.com/jesseduffield/lazygit/discussions/2383),
  [#2571](https://github.com/jesseduffield/lazygit/issues/2571))

### Cross-cutting B verdict + TRANSFER JUDGMENT (k9s/lazygit)

The two are structurally opposite (drill-down stack vs persistent grid), and that's the key
finding. Agent supervision is not a clean hierarchy like k8s resources — it's a handful of
concurrent state axes (what's the agent doing now, what diff is it touching, what process is
running, what's pending approval) you glance across simultaneously. **That argues for
lazygit's persistent-panel grid as the base shape, not k9s's drill-down stack.**

What users in BOTH ecosystems call essential, never clutter: the **context-sensitive action
bar** — the always-present list of "what can I do right now against the focused thing." k9s
users defend the header's context info while asking to strip everything else (k9s#270);
lazygit's keybar is what enables the "shortcuts became unconscious" experience. Second
essential, explicitly trust-building: lazygit's echo of the literal underlying command — for a
harness, show the raw tool call/shell command the agent executed, never a paraphrase.

What users call clutter: decorative chrome (k9s ships logoless/crumbsless/headless modes;
lazygit ships fullscreen-panel toggles precisely because users shed chrome on small
terminals). Build an explicit focus mode (collapse to focused panel + action bar) from day
one. Two risk patterns: (1) single-key-per-action collapses at scale — k9s hit a literal 78-
shortcut ceiling and lazygit users beg for a command palette; an agent harness has MORE
action types, so build a `:`-command/palette layer from day one. (2) accidental-input hazard —
a stray keystroke in lazygit put a repo in "some bizarre state"; in a harness a stray key
could approve a destructive tool call, so confirmation friction must scale with blast radius
(k9s's Ctrl-d confirm vs Ctrl-k immediate is the pattern).

---

## 5. Zellij (panes/tabs/floating + resurrection)

### Layout container model

Session → tabs → panes in a tiled tree, plus **floating panes** — full terminal panes that
overlay the tiled layout rather than occupying a grid slot: "first-class citizens... toggled
on and off with `Alt f`... persistent" — hide one and whatever ran in it keeps running
([zellij.dev/features](https://zellij.dev/features/)). Panes can convert tiled↔floating and
can be "stacked" (accordion where only the focused one expands). The entire chrome — tab bar,
status bar, session manager, welcome screen, file picker — is itself WASM **plugin panes**. A
bottom status bar is **mode-aware**: it shows only the keybindings valid for the current mode
(Normal/Pane/Tab/Resize/Scroll/Session...), rewriting itself as you enter each mode
([JPK.io](https://jpk.io/dev-tools/zellij-terminal-multiplexer-review/)). Because default
bindings collide with terminal apps, a **Locked mode** suspends all interception ("an escape
hatch" per the maintainer, [zellij#1399](https://github.com/zellij-org/zellij/issues/1399));
0.41 added an "Unlock-First" preset that starts locked
([tutorial](https://zellij.dev/tutorials/colliding-keybindings/)).

### LOVE

- Floating panes: "pop up over your layout instead of squeezing into the tiled grid ... used
  constantly for quick tasks like checking git status ... they don't disrupt the main layout
  like tmux pane splitting would" — [JPK.io](https://jpk.io/dev-tools/zellij-terminal-multiplexer-review/);
  even a user who reverted to tmux: tmux-floax "doesn't feel as native as Zellij's
  implementation" — [marceloborges.dev](https://marceloborges.dev/posts/4/)
- Mode-aware status bar as discoverability: "it has a lot of UI affordances to discover
  features without me having to memorize keystrokes ... With Zellij, I don't have to [look up
  the manual]." — kstrauser, [HN](https://news.ycombinator.com/item?id=46167242); "Rather than
  remembering that `Ctrl+p c` allows me to rename a pane, I simply have to look down" —
  [Keyhole Software](https://keyholesoftware.com/zellij-the-impressions-of-a-casual-tmux-user/);
  JPK.io calls the status bar "the decisive feature that made Zellij stick"
- Cross-device reattach: "ssh in from my phone, run `zellij attach`, and check on the status
  of those processes. Once home ... continue where I left off earlier." — kstrauser,
  [HN](https://news.ycombinator.com/item?id=46167242)

### HATE

- Keybinding collisions — the biggest, most-upvoted friction: maintainer-filed
  [zellij#1399](https://github.com/zellij-org/zellij/issues/1399) (83 reactions): defaults
  "collide with many terminal applications," Alt broken on mac ("Zellij is _not_ meant for
  me" — rhoen)
- Plugins have hardcoded keybinds you can't rebind — "you're F'd if those conflict"; user
  couldn't even use the session-manager because its picker key collided — imbnwa,
  [HN](https://news.ycombinator.com/item?id=44458727)
- No clean way to stay locked-by-default in the classic scheme —
  [discussion #3428](https://github.com/zellij-org/zellij/discussions/3428)
- Status bar as chrome scope-creep for power users: "A statusbar is just a plugin that runs on
  a 1-row layout. You can hide it by switching to a different layout, that sounds overly
  complicated" — [phaazon.net](https://phaazon.net/blog/zellij-2024); "Inability to show/hide
  status bar is the most annoying" — xvilka, [HN](https://news.ycombinator.com/item?id=44455787),
  re [zellij#694](https://github.com/zellij-org/zellij/issues/694)
- Missing basics drove reverts: no focused-pane indicator
  ([Keyhole](https://keyholesoftware.com/zellij-the-impressions-of-a-casual-tmux-user/)),
  copy-mode weaker than tmux ("I found tmux copy selection mode and I found my home" —
  [marceloborges.dev](https://marceloborges.dev/posts/4/))
- Floating panes specifically: **no conceptual detractors found in the corpus** — only rough
  edges (fullscreen scaling of TUIs inside floats,
  [zellij#3477](https://github.com/zellij-org/zellij/issues/3477); can't maximize a float,
  [zellij#4231](https://github.com/zellij-org/zellij/issues/4231))

### TRANSFER JUDGMENT (Zellij)

Floating panes are the one pattern in this whole corpus with essentially zero detractors —
even tmux-reverters kept missing them. What wins isn't "floating" as visual style but **task
isolation without layout disruption**: a summonable scratch surface that doesn't renegotiate
everyone else's geometry and persists in the background when dismissed. For a harness: keep
the agent's live stream in the main tiled view; make ad hoc inspection surfaces (diff viewer,
log tail, "why did it do that" trace, approval prompt) summonable floats that keep running
when dismissed. Avoid Zellij's own failure: the summon keybinding must be unambiguous from
every mode, and overlay-internal keys must be rebindable. The mode-aware status bar is the
same "context-sensitive keybar" finding as lazygit/k9s, independently confirmed — with the
same power-user caveat (must be hideable).

---

## 6. btop (dense live dashboard)

### Layout container model

A dense live-dashboard grid: independently-updating widget panels (CPU per-core scrolling
time-series graphs, memory with cache broken out, network per-interface, disk I/O, process
list), each owning its own data lifecycle and rendering — the "Widget Dashboard" pattern:
"these are all about the same system" rather than "the same item"
([Hyperbliss](https://hyperbliss.tech/blog/2026.04.04_terminal-renaissance/)). Panels are
toggleable via an Esc menu; graphs use Unicode braille for higher resolution than block chars
([terminal.guide](https://www.terminal.guide/tools/system-monitor/btop/)); the process list is
a scrollable/sortable/tree-mode sub-panel; theming via ini files with a large third-party
ecosystem (Catppuccin, Rose Pine).

### LOVE

- "My favorite part about btop is how smooth the color gradient is from the top of the process
  list to the bottom." — ashton314, [HN](https://news.ycombinator.com/item?id=45856987)
- "Btop really captures that '90s warez group feel." — aidenn0, same thread; "90's rave
  scene!" — DonHopkins, [HN](https://news.ycombinator.com/item?id=39689882)
- "there are visual graphs for various metrics, you can filter process names by substring, get
  detailed stats of a specific process, see the tree view ... easily show/hide various parts
  of the UI" — d3Xt3r, [HN](https://news.ycombinator.com/item?id=43477810)
- Overhead surprisingly low: "Seems to be on par with regular top, despite showing much more
  information." — nasretdinov, [HN](https://news.ycombinator.com/item?id=45856987)

### HATE

- "I do have to nitpick the weird titlebars on the sections... creating clutter, in an already
  cluttered interface." — mixmastamyk, [HN](https://news.ycombinator.com/item?id=45856987)
- RAM/CPU creep over days: 443MB RAM, 47-52% of a core after a week —
  [btop#1738](https://github.com/aristocratos/btop/issues/1738)
- Process-list scrolling slower than htop despite fancy rendering (Draw 800-1500μs vs Collect
  ~200μs): "much much slower for interactive use than htop" —
  [btop#1085](https://github.com/aristocratos/btop/issues/1085)
- Hard minimum-size wall: below 80x24 you can't even quit with 'q' —
  [btop#926](https://github.com/aristocratos/btop/issues/926); layout corrupts after long
  uptime — [btop#667](https://github.com/aristocratos/btop/issues/667)

### TRANSFER JUDGMENT (btop)

The widget-per-independent-datastream grid maps directly onto "N agent-run panels, each with
its own status/log-tail/sparkline, in a togglable grid." Braille graphs transfer for compact
token-throughput/latency sparklines. Two hazards to budget for: draw cost dominating collect
cost when N live widgets redraw (btop#1085/#1738 is the failure mode for many concurrent
runs), and the small-terminal hard-fail (btop#926) — design a graceful degradation to a
compact single-column list instead of a minimum-size wall, since harnesses live inside tmux
panes.

---

## 7. Yazi (miller columns + async preview)

### Layout container model

Three-pane Miller columns — parent (left), current (center), preview (right): "You see where
you came from (left), where you are (center), and where you're going (right)"
([Grokipedia](https://grokipedia.com/page/Yazi_file_manager)). All I/O async (Rust):
directory listing, image/PDF/archive preview, and highlighting run as background tasks with
real-time progress and cancellation in a dedicated task manager; progress bars render
independently of the pane redraw ([yazi docs](https://yazi-rs.github.io/)). Status/header bar
shows path and metadata; search/filter/rename/help appear as floating input popups over the
grid, position configurable ([input docs](https://yazi-rs.github.io/docs/configuration/yazi#input)).

### LOVE

- vs ranger freezing: "ranger stalls. The whole interface freezes ... Yazi is async all the
  way down ... I opened a folder with about 90,000 files in it and Yazi just rendered it
  instantly." — [jpk.io review](https://jpk.io/dev-tools/yazi-terminal-file-manager-review/)
- "Selecting a 50MB PDF doesn't block; the preview appears when ready. nnn either skips
  preview or blocks." — [mqdir.com](https://mqdir.com/blog/file-management/nnn-vs-yazi)
- "it apparently starts displaying file content, while you navigate ... in order to never
  block the ability to navigate" — zelphirkalt,
  [HN](https://news.ycombinator.com/item?id=37531434)

### HATE

- PDF preview too small even after config; needed a maintainer PR to fix —
  [yazi discussion #2271](https://github.com/sxyazi/yazi/discussions/2271); preview bleed into
  status bar — [yazi#2115](https://github.com/sxyazi/yazi/issues/2115)
- "Even figuring out that you can press `?` to open the help panel took me way too long
  because it is not referenced" — 7839284023, [HN](https://news.ycombinator.com/item?id=37531434)
- "I used Yazi for about a day and loved it, but there's just enough ergonomics missing that I
  ended up switching back to nnn" — BaculumMeumEst, same thread
- Filter popup obscures content by default: "It block the items behind usually" —
  [yazi discussion #1118](https://github.com/sxyazi/yazi/discussions/1118)
- Fixed 3 columns felt limiting on wide terminals — [yazi#2459](https://github.com/sxyazi/yazi/issues/2459)

### TRANSFER JUDGMENT (Yazi)

Miller columns fit browsing tool-call history / diff trees: left = list of past tool calls,
center = selected call summary, right = live-rendered diff/output preview — the exact spatial
memory reviewers praise. The single most transferable idea is **async preview generation with
visible progress**: large diffs and long tool outputs must render as cancelable background
tasks, never blocking the UI thread (the ranger-freeze class of bug is exactly what a harness
hits rendering a several-thousand-line diff synchronously). Avoid Yazi's default of floating
popups obscuring the content they filter (#1118). If adopting rich chord keybindings, ship a
which-key/help affordance far more discoverable than Yazi's — praised users abandoned it over
that gap alone.

---

## 8. Helix / kakoune (modal minimalism, inline pickers)

### Layout container model

Minimal chrome: a single bottom status/mode line (mode, file, selection count/position, LSP
diagnostics) and no permanent side panels. Discoverability via transient inline popups: a
WhichKey-style key-sequence popup, and fuzzy pickers (file `Space+f`, buffer, symbol,
jumplist) as compositor-pushed overlay windows — filterable list pane + preview pane,
dismissed on select/Escape ([DeepWiki](https://deepwiki.com/helix-editor/helix/3.2-ui-components-and-pickers)).
Kakoune shares the selection→action grammar with dense status-line context
([kakoune#4445](https://github.com/mawww/kakoune/issues/4445)).

### LOVE

- "Since you 'see' the selections, you can select first and then decide what to do ... You
  have this nice visual feedback." — [Helix discussion #7210](https://github.com/helix-editor/helix/discussions/7210)
- "Kakoune's grammar is object followed by verb, combined with instantaneous feedback ... you
  always see the current object before you apply your change"; "Being able to see what a
  'sentence' is going to do as you're typing it is a huge improvement on vim" —
  [HN](https://news.ycombinator.com/item?id=13165919)
- Built-in pickers replace plugin scaffolding (vs Neovim needing telescope + which-key):
  "Helix ships with LSP, autocompletion, treesitter, fuzzy search ... by default" —
  [tqwewe.com](https://tqwewe.com/blog/helix-vs-neovim/)

### HATE

- "Not being able to browse the file structure from within the editor is a big deal for me" —
  users stitch zellij+yazi floating panes to fake a sidebar —
  [Helix discussion #8314](https://github.com/helix-editor/helix/discussions/8314)
- Picker overlay too cramped: "I think the picker should cover the whole screen given that it
  needs to display so much information" — [Helix discussion #3531](https://github.com/helix-editor/helix/discussions/3531)
- "[Helix] lacks tree view (like neotree)" — [Helix discussion #3388](https://github.com/helix-editor/helix/discussions/3388)
  (maintainers accept the tradeoff explicitly: "Don't try to be everything for everyone")

---

## 9. tig (view-stack drill-down)

### Layout container model

Status line pinned at bottom; per-view title line showing view name, current commit, and
position (`[main] c622eefa... - commit 1 of 61 (1%)`, elapsed-time suffix on slow ops, bold =
active view). Default single view; Enter on a commit splits into top log + bottom diff pane
(Tab toggles, `q` collapses). Deeper navigation (tree, blame) pushes a **view stack**; `q`
pops back — drill-down/pop-back rather than tabs or fixed panels
([tig manual](https://jonas.github.io/tig/doc/manual.html)).

LOVE/HATE: direct forum commentary thin (tool is old/stable; HN thread
[#25442510](https://news.ycombinator.com/item?id=25442510) was rate-limited during research —
flagged as a gap, not fabricated). What users rely on implicitly: drill log → diff → blame →
tree and pop back without losing place; the `commit N of M` position counter gives orientation
plain `git log | less` lacks.

---

## 10. fzf / Television (overlay pickers)

### Layout container model

The archetype summonable overlay: invoked via shell keybinding (`Ctrl-T`/`Ctrl-R`/`Alt-C`) or
piped from anything, takes over full screen or a bottom-anchored region, live-filters a list
as you type, optional preview pane, exits on Enter/Escape returning the selection to stdout —
"read lines from stdin, let the user pick one, write it to stdout"
([Red Hat](https://www.redhat.com/en/blog/fzf-linux-fuzzy-finder-tool),
[fzf README](https://github.com/junegunn/fzf/blob/master/README.md)). Television is a Rust
reimplementation "inspired by the neovim telescope plugin," with pluggable Channels each with
its own preview ([Terminal Trove](https://terminaltrove.com/television/)).

### LOVE — evidence this pattern won broadly

- "fzf was life changing when I first stumbled on it"; "I use fzf _everywhere_, it's greatly
  enhanced my workflow" — [HN](https://news.ycombinator.com/item?id=30736518)
- The pattern generalized past its origin: fzf-tab replaces zsh's whole completion menu
  ([Aloxaf/fzf-tab](https://github.com/aloxaf/fzf-tab)); telescope.nvim adopted fzf's matching
  algorithm directly ([telescope-fzf-native](https://github.com/nvim-telescope/telescope-fzf-native.nvim));
  Television re-implemented the shape standalone; convergent with Alfred/rofi/dmenu across
  environments ([thevaluable.dev](https://thevaluable.dev/fzf-git-integration/))

### HATE

- Preview lag: "preview switching is super slow" (~1s for dynamic content); 5-15s for large
  files — [fzf#2417](https://github.com/junegunn/fzf/issues/2417),
  [discussion #3604](https://github.com/junegunn/fzf/discussions/3604); fzf waits for stale
  preview renders instead of canceling — [fzf#3134](https://github.com/junegunn/fzf/issues/3134)
- `Ctrl-R` muscle-memory collisions — [fzf#3115](https://github.com/junegunn/fzf/issues/3115),
  [Warp#6126](https://github.com/warpdotdev/Warp/issues/6126)
- Dissent: "it's _too_ fuzzy, and makes it impossible to find anything" —
  [HN](https://news.ycombinator.com/item?id=30736518)

---

## 11. atuin (history search overlay)

### Layout container model

Rebinds `Ctrl-R`/`Up` to a full-screen overlay replacing native history search: live-filtered
fuzzy list where **each item carries a context row** — exit code (red/green), timestamp,
duration, directory — plus a scope toggle cycling `[GLOBAL]`/`[HOST]`/`[SESSION]`/`[DIRECTORY]`
and an Inspector sub-view (`Ctrl-O`) for full per-command metadata
([atuin](https://github.com/atuinsh/atuin)). Unlike fzf's generic pipe overlay, atuin's is
purpose-built with fixed per-item context baked in.

### LOVE

- "Atuin records context with each command — exit code, duration, working directory ... The
  exit-code coloring is the small detail many didn't expect to care about. Failed commands are
  red." — [jpk.io](https://jpk.io/dev-tools/atuin-shell-history-review/)
- Context as first-class queryable data: `atuin search --exit 0 --after "yesterday 3pm" make`
  ([docs](https://docs.atuin.sh))

### HATE

- Sync opacity: entry counts diverging across machines after repeated forced syncs
  ([atuin#2691](https://github.com/atuinsh/atuin/issues/2691)); ranking worse than prior
  zsh+fzf ([atuin#2351](https://github.com/atuinsh/atuin/issues/2351)); missing recent history
  ([atuin#2483](https://github.com/atuinsh/atuin/issues/2483),
  [#2375](https://github.com/atuinsh/atuin/issues/2375))
- Full-screen takeover "feels far removed from a teletype interface" — some users want history
  search to stay inline/lightweight (the Helix minimalism tension in reverse)

### TRANSFER JUDGMENT (Helix/tig/fzf/atuin group)

1. **One reusable fzf-style overlay picker Component** for run/session/tool-call selection —
   highest-confidence transfer; build once, reuse everywhere, and cancel stale preview renders
   on selection move (fzf#3134's lesson).
2. **atuin-style per-item context row** (success/failure, duration, working context) on every
   tool-call row in a log — atuin's most-praised feature is per-row context, which beats a
   single global "last status" line.
3. **Helix-style minimal status line scoped to mode/state only** (thinking / awaiting-approval
   / executing tool X). Helix users defended mode-state chrome and revolted when minimalism
   swallowed structural navigation — don't route "which session am I in / what's the run tree"
   through the status line or overlays; that's an always-on element.
4. **tig's view-stack push/pop for hierarchical drill-down** (run → step → tool-call → diff)
   with a persistent "item N of M" position line. Reserve overlays for flat filtered selection;
   reserve the view stack for drill-down within one selected thing.
5. If the harness syncs run history across sessions/machines, surface sync status/staleness
   explicitly — atuin's worst complaints were "I can't tell why history doesn't match," a
   trust-eroding failure for an agent harness where history = past runs/decisions.

---

## Cross-cutting findings

### A. Command blocks verdict

See section 2 above. Summary: beloved differentiator where blocks map to real semantic units;
friction where they fight the terminal input model; not universal table stakes, but
functionally table stakes for IDE-like/agent-oriented terminals. Wave's regression proof:
users said losing per-command blocks made it "like any other terminal emulator."

### B. The persistent multi-panel shape

Agent supervision is concurrent state axes, not a hierarchy → lazygit grid over k9s stack as
base shape. The non-negotiable element in both ecosystems: the context-sensitive action
bar/keybar. Second: raw command echo for trust. Clutter = decorative chrome; both projects
shipped chrome-shedding modes and still have open panel-resize requests. Both are straining
against single-key-per-action at scale → command palette from day one.

### C. Summon-and-dismiss overlays vs persistent panels

Overlays won decisively — **for selection and side-check tasks**. Every list-picking tool
converged independently on the same shape (fzf → telescope → Television → atuin → Helix
pickers), the pattern generalized across domains (shell completion, editors, launchers), and
Zellij's floating panes — the "summonable pane that persists when hidden" variant — are the
one pattern in the entire corpus with zero conceptual detractors, even among users who
reverted to tmux. But overlays lose for **orientation tasks**: users explicitly complain when
something that should be always-visible (file tree, mode state, position) is forced into
overlay form (Helix #8314). Rule: overlay for "pick one of N" and quick side-checks,
always-on chrome for "where am I / what state / what's the tree."

### D. What earns permanent screen real estate

1. **Mode/selection state** (Helix/kakoune status line) — the single most defended chrome
   across all tools ("you always see the current object before you apply your change").
2. **Context-sensitive available-actions bar** (lazygit keybar, k9s header bindings) — called
   essential in both ecosystems, never clutter.
3. **Positional/progress info** (tig's "commit N of M (%)", elapsed-time on slow ops).
4. **Per-item outcome context** (atuin's exit/duration/cwd row) — permanence per row, not just
   one global line.
5. Context identity (k9s: "The only information being important at all time in the header is
   the context") — for a harness: which agent/session/project.
   Everything else (logos, crumbs, titlebars) users shed the moment terminals get small.

### E. Session resurrection UX

**Mechanics (Zellij):** layout + per-pane running command serialized on exit/crash; optionally
pane content/scrollback (`pane_viewport_serialization`, `scrollback_lines_to_serialize`). On
reattach, resurrected commands sit behind a per-pane **"Press ENTER to run..."** banner — a
deliberate gate so a resurrected `rm -rf` doesn't auto-fire. Exited sessions show in the
session-manager under an EXITED section. Docs admit "command discovery ... can sometimes be
inaccurate" ([zellij docs](https://zellij.dev/documentation/session-resurrection.html)).

**Praise:** cross-device attach-to-peek (kstrauser's laptop→phone→desktop narrative,
[HN](https://news.ycombinator.com/item?id=46167242)); "it comes back with its full tab and
pane layout ... a major advantage over tmux's default behavior"
([JPK.io](https://jpk.io/dev-tools/zellij-terminal-multiplexer-review/)).

**Complaints — the substance:**

- Wrong command re-run: `get_all_cmds_by_ppid` silently overwrites when one parent has
  multiple children — "whichever child appears last in `ps` output wins" — reproduced with
  literally `claude --resume foo` as the example —
  [zellij#4873](https://github.com/zellij-org/zellij/issues/4873)
- Quotes stripped / args mangled — [zellij#4727](https://github.com/zellij-org/zellij/issues/4727),
  [#2925](https://github.com/zellij-org/zellij/issues/2925)
- Total silent session loss on quit/reboot in some configs —
  [zellij#4413](https://github.com/zellij-org/zellij/issues/4413)
- Partial restoration: wrong cwd on first pane, `less` comes back with no input —
  [zellij#4129](https://github.com/zellij-org/zellij/issues/4129)
- "Resurrected sessions need to be restored manually via somewhat lagging session manager,
  there's no cli api for that" — kartoshechka, [HN](https://news.ycombinator.com/item?id=46163377)
- tmux-resurrect baseline: conservative program whitelist (`vim less htop ...`), idempotent
  restore that becomes a UX trap — "the status line reports success. However no changes are
  made" — [tmux-resurrect#513](https://github.com/tmux-plugins/tmux-resurrect/issues/513),
  [#98](https://github.com/tmux-plugins/tmux-resurrect/issues/98)

**The finding:** the dominant failure mode is not "resurrection doesn't work" — it's
**"resurrection reports success while doing the wrong thing."** Every concrete complaint
(wrong child process, stripped quotes, false-success no-ops, silent deletion) is a
trust/legibility failure. **TRANSFER JUDGMENT:** a harness reattach screen must treat "what
actually got restored" as first-class UI: (1) show a restoration diff, not a success toast —
enumerate what resumed vs what's uncertain, showing the exact resumed command/args; (2) never
auto-run a resurrected side-effecting action — Zellij's ENTER gate transfers directly to
"resume this in-flight tool call/write," where blind replay stakes are higher; (3) make the
session list previewable before committing (last N lines of reasoning, current tool, elapsed
since disconnect) with a scriptable API path alongside the picker; (4) render "resumed but
possibly stale" / "nothing found to resume — starting fresh" as explicit states, never a UI
that looks resumed when it silently isn't.

### F. "New since you looked away"

**Nobody solved it.** None of btop/bottom/procs/lnav implement a purpose-built unread
badge/flash system. State of the art is: (a) generic user-notification queues (lnav's
`lnav_user_notifications` top-bar table — [lnav docs](https://docs.lnav.org/en/latest/ui.html));
(b) manual attention jump-lists (lnav's `e`/`Shift+e` next/prev-error hotkeys, user-marked
lines — [hotkeys](https://docs.lnav.org/en/latest/hotkeys.html)); (c) passive
color-by-magnitude gradients (lnav spectrogram green→yellow→red, procs/bottom thresholds);
(d) continuous sort-to-top as an implicit "what's hot" signal (btop). bottom even ships the
opposite: a freeze key (`f`) to stop the display shuffling under you
([wezm.net](https://www.wezm.net/v2/posts/2020/rust-top-alternatives/)). **TRANSFER JUDGMENT:**
this is white space — an agent harness wanting real "came back after 10 minutes, what changed"
semantics should borrow badge/unread-divider models from chat UIs, not from monitoring TUIs;
none of these tools is a reference implementation.

---

## Layout-container taxonomy and verdicts

| Container | Exemplars | Verdict | Attribution |
|---|---|---|---|
| Semantic block (1 action = 1 unit w/ metadata) | Warp, Wave pre-0.8 | **Loved** where units are real; friction where imposed | Wave #1084 ("like any other terminal" without it); Warp #3189/#3227 (disable requests) |
| Persistent multi-panel grid | lazygit, btop | **Loved** for concurrent state axes | "It sounds crowded — it's not" (configcrate); cramped-terminal complaints (lazygit #4740) |
| Context-sensitive keybar/action bar | lazygit, k9s, Zellij | **Loved / essential** — the one universally defended element | k9s#270, lazygit workflow quotes |
| Summonable overlay picker (list+preview) | fzf, Television, Helix, atuin | **Won its category** (selection tasks) | Cross-tool convergence; HN "life changing" |
| Drill-down view stack | k9s, tig | **Tolerated-to-loved** for true hierarchies only | k9s HN praise; wrong shape for concurrent axes |
| Floating/summonable panes (persist when hidden) | Zellij | **Loved — zero conceptual detractors found** | JPK.io; tmux-reverters still miss it (marceloborges.dev) |
| Mode-aware keybinding status bar | Zellij | **Loved by casuals, chrome to power users** — must be hideable | kstrauser HN vs phaazon.net / zellij#694 |
| Auto-replay of resurrected commands | Zellij/tmux-resurrect | **Failed** (wrong command, false success) — ENTER-gate is the fix | zellij#4873/#4413; tmux-resurrect#513 |
| Miller columns + async preview | Yazi | **Loved** (async is the love; 3-pane is liked) | jpk.io 90k-files quote; #2459 wants more columns |
| Dense widget dashboard | btop | **Loved aesthetically, tolerated interactively** | HN gradient/rave praise vs #1085 scroll slowness |
| Per-command blocks collapsed into tiles | Wave v0.8+ | **Failed** (regression, users left) | waveterm discussion #1084 |
| Hard minimum-size walls | btop | **Failed** | btop#926 (can't even quit) |
| Full-screen takeover for lightweight tasks | atuin (for some) | **Tolerated** | "far removed from a teletype interface" |

## Top 5 stealable patterns for an agent harness

1. **Semantic blocks for tool calls** — one tool call = one collapsible block with
   status/exit/duration metadata, distinct block types for tool-call vs agent-reasoning,
   interleaved in one chronological stream; flat raw transcript preserved underneath.
   (Warp/Wave; Wave's regression is the proof of value.)
2. **Context-sensitive action bar, always on** — the single universally-defended chrome
   element; shows exactly what keys act on the focused thing (approve/reject/kill/expand),
   plus a command palette from day one because single-key bindings demonstrably collapse at
   scale (k9s#2793, lazygit#4846).
3. **One reusable overlay picker** (fzf shape: live filter + preview, cancel stale previews)
   for every "pick one of N" task — sessions, runs, tool calls, files touched.
4. **Per-row outcome context** (atuin): every tool-call row carries success/failure color,
   duration, and working context inline — plus async preview rendering with visible progress
   (Yazi) so big diffs never block the UI.
5. **Confirmation friction scaled to blast radius + legible resurrection** (k9s Ctrl-d vs
   Ctrl-k; lazygit modals; Zellij's "Press ENTER to run" gate on resurrected commands) —
   never auto-replay a side-effecting action after reattach, never let block/panel selection
   steal keystrokes from the live approval prompt (Warp #3189's root cause), and show a
   restoration diff on reattach instead of a success toast (the entire resurrection corpus'
   failure mode is "reports success while doing the wrong thing").
