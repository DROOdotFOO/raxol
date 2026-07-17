# Aesthetic Dossier: lazygit

> A tiled box-drawing cockpit for git. Bordered panes, a single green-bold border that
> tells your eye which panel is live, and a palette that maps git's internal state
> (staged / unstaged / cherry-picked / conflicted) onto color. Version control rendered
> as a spatial control surface rather than a scrolling command log.

- **Repo:** https://github.com/jesseduffield/lazygit (Go, built on the author's fork of `gocui`)
- **Author:** Jesse Duffield (Melbourne). First released 2018 as a "learn Go" project.
- **Category:** industrial-dense / paneled. Siblings: `gitui`, `tig`, `magit`, `lazydocker` (same author, same visual DNA).
- **Clone read for this dossier:** `undefined/lazygit` (shallow). Source paths below are all real.

---

## 1. The one-sentence identity

Lazygit's whole look is built from **one accent decision repeated everywhere**: the
active panel gets a **green, bold** border; everything else gets the terminal's *default*
(un-styled) border. There is no gloss, no shadow, no gradient — the entire "where am I"
signal is a single foreground color on box-drawing characters. That green border is the
brand. When you picture lazygit, you picture a grid of dim rectangles with exactly one
glowing green one.

```
pkg/config/user_config.go:880
  ActiveBorderColor:               []string{"green", "bold"},
  SearchingActiveBorderColor:      []string{"cyan", "bold"},
  InactiveBorderColor:             []string{"default"},
  SelectedLineBgColor:             []string{"blue"},
  OptionsTextColor:                []string{"blue"},
```

**Technique → feeling:**
- *Green + bold on the active border, `default` on all others* → **focus without chrome.**
  The eye is pulled to one rectangle the way a cursor pulls it to one cell. Because
  inactive borders inherit the terminal's own foreground, the app feels like it *belongs*
  to your terminal theme rather than painting over it.
- *Border color swaps to **cyan+bold** the instant you start a search/filter* → **mode you
  can see.** The frame itself becomes a status light; you know you're in "search" because
  the accent shifted hue, not because a label told you.

---

## 2. Screen anatomy — describe it in words

Open lazygit in a repo and you get a **tiled cockpit**, portrait or landscape depending on
terminal size (`PortraitModeAutoMaxWidth: 84`). The canonical landscape layout:

```
┌ Status ────┐┌ Diff / main view ───────────────────────────┐
│ repo ↑2 ↓0 ││  diff of whatever is selected on the left    │
├ Files ─────┤│                                              │
│ M src/a.go ││  + added line          (green)               │
│ ?? new.txt ││  - removed line        (red)                 │
├ Branches ──┤│  @@ hunk header        (cyan)                │
│ * main     ││                                              │
├ Commits ───┤│                                              │
│ 󰜘 fix bug  ││                                              │
├ Stash ─────┤│                                              │
└────────────┘└──────────────────────────────────────────────┘
 files  branches  commits  stash        <-- keybind footer (blue)
 [You can hide/focus this panel by pressing '@']   <-- command log
```

The left is a **stack of narrow side-windows** (Status, Files, Branches, Commits, Stash);
the right is **one wide main window** showing the diff/content of whatever is selected on
the left. This master-detail split is the founding decision — see §7.

**Technique → feeling:**
- *Persistent tiled panels, all borders drawn, nothing hidden behind tabs* → **everything-
  at-once density.** You are looking at a dashboard, not a stream. The feeling is
  "instrument panel": a lot of small readouts, glanceable, spatially stable.
- *Narrow left column + one big right pane* → **the eye has a home.** Left = navigation,
  right = detail. This is the same ergonomic-as-aesthetic as a file-manager or an email
  client; it reads as "serious tool."

---

## 3. Border / box-drawing vocabulary

Lazygit ships **five** border styles, switchable via `gui.border`
(`pkg/gui/views.go:158`):

```go
default : ─ │ ┌ ┐ └ ┘   (single, light)   <- the default
double  : ═ ║ ╔ ╗ ╚ ╝
rounded : ─ │ ╭ ╮ ╰ ╯   (light lines, rounded corners)
bold    : ━ ┃ ┏ ┓ ┗ ┛   (heavy)
hidden  : (all spaces)  (borderless — panes float on whitespace)
```

The default is **single light** — the quietest possible box. The corner runes are the
only place the "shape language" lives, and the defaults keep it neutral so the *color*
(green active border) does the talking.

**Technique → feeling:**
- *Single light lines by default* → **precise, engineered, unfussy.** Heavy or double
  borders would read as retro/BBS; single-light reads as modern-minimal-Unix.
- *`rounded` as a one-word opt-in* → soft/friendly; *`bold`* → assertive/chunky;
  *`hidden`* → airy, "just floating text," the most modern/minimal look. One config key
  moves the whole app across a mood axis from brutalist to soft to weightless.
- *Graceful ASCII degradation* — on terminals that can't do Unicode box-drawing, gocui's
  `tcell_driver.go` remaps `┌┐└┘╭╮ → +`, `─═ → -`, `│║ → |`. The cockpit survives on a
  teletype. **Feeling:** ruggedness; it never looks broken, just plainer.

A subtle detail: a one-row-tall view is drawn with **half-line end-caps** `╶ … ╴`
(`gui.go:1226`) instead of full corners — the framing stays proportional even when a panel
collapses to a single line.

---

## 4. Color as git's state machine

This is lazygit's deepest aesthetic move: **color is not decoration, it's a type system
for git state.** Every git concept has a fixed hue, and once you learn the six colors you
can read the whole screen without reading a word.

### File status (`pkg/gui/presentation/files.go`)
Files render with a **two-column X/Y status** exactly like `git status --short`, and each
column is colored independently:

```
getColorForChangeStatus():
  added / staged     → green
  modified           → yellow
  deleted            → red   (UnstagedChangesColor)
  renamed            → cyan
  copied             → magenta
  untracked (??)     → red
```

The **first char = staged state (green)**, the **second char = worktree state (red)**.
So a half-staged file literally shows green-then-red, and line-count deltas append
`+N` in green / `-N` in red (`files.go:207`).

**Technique → feeling:** *staged=green / unstaged=red, side by side* → **a moral color
grammar.** Green = "safe, in the commit," red = "still dangling." Staging a file and
watching its marker flip green is a tiny hit of resolution. The palette makes the
staging area *emotionally legible*.

### Diff view
Standard `+green / −red / @@cyan` diff coloring, and lazygit is **BYO-pager**: drop in
`delta`, `diff-so-fancy`, etc. via `git.paging` (`user_config.go:272`) and the main pane
adopts that tool's richer palette. **Feeling:** lazygit is a *frame* that respects the
diff-aesthetics ecosystem rather than fighting it.

### Mode colors — the palette changes when you change intent
Certain operations recolor the relevant rows:
- **Cherry-picking:** copied commits get **cyan bg / blue fg** (`CherryPickedCommitBgColor: cyan`).
- **Interactive rebase base:** the marked commit gets **yellow bg / blue fg**.
- **Bisect / conflict:** conflict rows show a red `<-- FIXME ---` marker; a commit marked
  for rebase shows a yellow `✓` or marker (`commits.go:426`).

**Technique → feeling:** *entering a mode repaints the rows it affects* → **the UI has
weather.** The screen visibly changes climate when you start cherry-picking or rebasing,
so a dangerous multi-step operation always looks different from resting state. You can
never forget you're mid-rebase because mid-rebase has its own colors.

### The commit graph — the signature flourish
`pkg/gui/presentation/graph/` renders the commit DAG as colored pipe-art
(`│ ├─╮ ╰─┤`), and the pipes are **colored per author**:

```go
// authors/authors.go — deterministic color from author name
hash := md5.Sum([]byte(authorName))
c := colorful.Hsl(randFloat(hash[0:4])*360.0,       // hue: full wheel
                  0.6 + 0.4*randFloat(hash[4:8]),   // saturation 0.6–1.0
                  0.4 + 0.2*randFloat(hash[8:12]))  // lightness  0.4–0.6
```

Each contributor gets a **stable, vivid truecolor** derived from an md5 of their name,
deliberately clamped to **high saturation (0.6–1.0)** and **mid lightness (0.4–0.6)** so it
reads on any dark terminal and never washes out. The selected commit's pipe is
over-painted in **light-white bold** (`graph.go:35 highlightStyle`) so your current
position glows brighter than the colored strands around it. Commit hashes recolor too:
**yellow = cherry-picked, red = unmerged/conflict** (`commits.go:489`).

**Technique → feeling:** *author-hashed HSL pipes* → **the git history becomes a woven
cable, and each teammate is a colored thread.** It's the most "alive" thing on screen —
organic, rainbowed, per-repo unique — sitting against the otherwise austere grid. This is
lazygit's equivalent of a mascot: an emergent, data-driven signature that looks different
in every repository.

---

## 5. Typography substitutes & icons

No fonts to pick, so lazygit leans on the mono toolkit:
- **Bold** = the active border and the selected commit pipe (emphasis = weight).
- **Blue background bar** = selected line (`SelectedLineBgColor: blue`); in an *unfocused*
  panel the selection drops to **bold-only, no background** (`InactiveViewSelectedLineBgColor: bold`)
  — so the "cursor" is loud in the active pane and a whisper in the others. **Feeling:**
  attention has a gradient; inactive panels remember where you were without shouting.
- **Nerd Font glyphs**, opt-in via `nerdFontsVersion` (off by default — plain text first).
  `pkg/gui/presentation/icons/`: branch `󰘬`, commit `󰜘`, merge `󰘭`, tag ``, stash ``,
  worktree `󰌹`, and **per-host remote icons** — GitHub ``, GitLab ``, Bitbucket ``,
  Codeberg ``, plus Debian/Arch/GNOME/KDE/kernel.org and friends. File-type icons color
  each filename by language.

**Technique → feeling:** *icons ship off, glyphs are a reward for a configured terminal*
→ **progressive richness.** Bare installs look clean and universal; a "riced" setup with
a Nerd Font blooms into a glyph-dense, colorful workstation. The per-remote-host icons are
a wink — your GitHub remote *looks* like GitHub. Same app, two aesthetic tiers, chosen by
the user's font.

---

## 6. Motion & popups

- **Spinner:** the classic ASCII barber-pole `| / - \` at 50 ms (`user_config.go:924`).
  Deliberately retro, four bytes, works on any terminal. **Feeling:** honest "computer is
  working" — no fancy braille dots by default, just the oldest spinner in the book.
- **Popups float and grow to fit.** Menus, confirmations, prompts and tooltips are
  centered dialogs sized to their content and clamped:
  ```
  confirmation_helper.go:124
    x0 = width/2 - panelWidth/2 ;  y0 = height/2 - panelHeight/2
    panelWidth  = min(4*width/7, maxWidth)     // never wider than 4/7 screen
    panelHeight = min(contentHeight+2, height*3/4)  // never taller than 3/4
  ```
  **Technique → feeling:** *a dialog that opens dead-center, no larger than it must be* →
  **modal focus.** The tiled background stays visible and dim behind the crisp centered
  box, so a confirmation feels like a spotlight, not a page change. Tooltips can even
  nest, offset `+2` from their parent popup, so help stacks diagonally like sticky notes.
- **Redraw cadence:** gocui repaints the whole grid on change; there's no easing or
  sliding. Transitions are instantaneous cuts. **Feeling:** snappy, mechanical,
  zero-latency — "terminal users *expect* TUIs to be fast" (Duffield, §7).

---

## 7. Voice, copy & self-documentation

- **The always-on keybind footer.** The bottom line lists the keys valid *right now* for
  the focused panel, in **blue** (`OptionsTextColor`). The in-code style guide is explicit
  about restraint (`options_map.go:31`):
  > "STYLE GUIDE: we use the default options fg color for most keybindings. We can only use
  > a different color if we're in a specific mode where the user is likely to want to press
  > that key. For example, when in cherry-picking mode, we want to prominently show the
  > keybinding for pasting commits."

  **Technique → feeling:** *a context-sensitive cheatsheet nailed to the floor, mostly
  monochrome, coloring exactly one key when it matters* → **calm confidence.** The app
  teaches itself without a manual, but refuses to rainbow the footer; the single
  highlighted key in cherry-pick mode is a pointed finger.
- **The command log panel** (bottom, `command_log_panel.go`) prints **the real git
  commands lazygit runs**, with the header *"You can hide/focus this panel by pressing
  '%s'."* Transparency is treated as a design feature, not a debug dump.
  > "Lazygit works around [git anxiety] by logging all the git commands that it runs so
  > that you know what's happening under the hood." — Duffield, *Lazygit 5 Years On*

  **Technique → feeling:** *showing the CLI it's driving* → **trust through glass walls.**
  The magic TUI never fully hides the git underneath; you can watch the machinery. It
  reads as respect for the power user.
- **Copy tone:** terse, functional, quietly friendly. Tooltips are full sentences of genuine
  help (the interactive-rebase tooltip runs three lines explaining base commits). Strings
  like `RandomTip`, `Donate`, and helpful empty-state guidance ("Nothing to stage: the
  parent repo can only stage a new submodule commit… Commit inside the submodule first.")
  are patient and instructive, never jokey or mascot-voiced. **Feeling:** a competent
  senior dev pair-programming with you, not a cartoon.
- **Easter egg:** a hidden **Snake game** view rendered in green (`views.go: Snake.FgColor
  = ColorGreen`) — the same signature green as the active border. Even the joke is on-brand.

---

## 8. Design intent — reconstructed from source, commits & interviews

The layout was **not** the product of visual experimentation; it fell out of one goal plus
one accident:

> "I wanted to show as much context on the screen as possible and that naturally led to
> having the side windows for files, branches, etc, and the main window for viewing the
> currently selected item." — Jesse Duffield, Q&A, *Looking at Computer*

> "The library he originally used for handling keybindings was **termbox**, and that didn't
> support shift+tab, so instead of using tab/shift+tab to navigate up and down side
> windows, he used **left/right arrows** instead… It's a pretty bizarre scheme when you
> think about it but it's stuck."

> "I optimized for speed of development and that meant just picking something that seemed
> sensible and then releasing it… there are some cases where more forethought would have
> spared me some pain!"

> "Terminal users *expect* TUIs to be fast… space constraints lead to compact designs with
> little in the way of superfluous clutter." — *Lazygit 5 Years On*

So the aesthetic is **emergent, not composed**: maximize on-screen context → tiled panels;
tool-library limitation → left/right navigation; "ship fast" → minimal single-line borders
with color doing the heavy lifting. The green active border, the blue selection bar, and
the state-color grammar are the few deliberate visual choices layered onto that pragmatic
skeleton. The theme system (`pkg/theme/theme.go` + `ThemeConfig`) exposes exactly those
knobs — border colors (active/inactive/searching), selection bg, cherry-pick and
rebase-base fg/bg, unstaged color, default fg — which is a precise map of *which* decisions
the author considered aesthetic load-bearing.

**Lineage / influences:** descends from the tradition of `tig` and Emacs `magit`
(git-as-interactive-surface), but pushes further into the multi-panel "cockpit" idiom.
Its own visual language then propagated: `lazydocker` (same author) is a near-identical
green-bordered cockpit, and the pattern spawned frameworks (`gocui`, `lazycore`,
third-party `lazytui`) explicitly built to reproduce "panels, modals, tabs like LazyGit."
The green-bold-active-border-plus-blue-selection combo is now a recognizable *genre*.

---

## 9. What makes it FEEL different from its siblings

- **vs `gitui` (Rust/ratatui):** gitui is flatter and more uniformly colored; lazygit's
  **author-hashed truecolor commit graph** and **mode-recoloring** give it more visual
  "temperature" and event. gitui feels like a form; lazygit feels like a console.
- **vs `tig`:** tig is a mostly-monochrome pager with one focused view at a time; lazygit's
  **simultaneous tiled panels + the always-visible command log** make it a dashboard, not a
  reader.
- **vs `magit`:** magit lives inside Emacs's typography and section-folding; lazygit is a
  **bordered spatial grid** where position, not indentation, encodes structure.

The distilled signature: **a dim grid of single-line boxes, one of them glowing
green-bold, a blue cursor-bar inside it, a rainbow author-colored commit cable down the
left, and the real git commands scrolling honestly along the bottom.** Austere frame,
vivid data, visible machinery.

---

## 10. Techniques → feelings (quick index)

| Concrete technique | Vibe produced |
|---|---|
| Green+bold active border, `default` inactive | focus without chrome; belongs to your terminal |
| Border hue → cyan when searching | mode you can *see* on the frame |
| Single-light box-drawing default; 5 styles configurable | precise/minimal, with a brutalist↔soft↔weightless mood dial |
| ASCII fallback (`┌→+`, `│→\|`) | rugged; never looks broken |
| staged=green / unstaged=red two-column status | moral color grammar; staging feels like resolution |
| Mode recoloring (cherry=cyan-bg, rebase=yellow-bg) | the UI has weather; dangerous ops look different |
| Author-hashed HSL commit pipes (sat .6–1, light .4–.6) | living rainbow cable; emergent per-repo signature |
| Selected line: blue bar active, bold-only inactive | attention gradient across panels |
| Nerd Font glyphs opt-in, per-host remote icons | progressive richness; riced tier as reward |
| ASCII `\| / - \` spinner @50ms | honest, retro "working…" |
| Centered grow-to-fit popups over dim tiled bg | spotlight modality |
| Always-on blue keybind footer, one key colored in-mode | self-teaching yet calm |
| Command log of real git commands | trust through glass walls |

---

## Sources

- Repo (cloned & read): https://github.com/jesseduffield/lazygit — `pkg/theme/theme.go`,
  `pkg/config/user_config.go`, `pkg/gui/views.go`, `pkg/gui/presentation/{files,commits}.go`,
  `pkg/gui/presentation/graph/`, `pkg/gui/presentation/authors/authors.go`,
  `pkg/gui/presentation/icons/`, `pkg/gui/options_map.go`,
  `pkg/gui/controllers/helpers/confirmation_helper.go`, `pkg/gui/command_log_panel.go`,
  `pkg/gocui/{gui,tcell_driver}.go`, `pkg/i18n/english.go`
- Jesse Duffield, *Lazygit Turns 5: Musings on Git, TUIs, and Open Source* — https://jesseduffield.com/Lazygit-5-Years-On/
- *Q&A with Jesse Duffield*, Looking at Computer (Zachary Rice) — https://lookingatcomputer.substack.com/p/q-and-a-with-jesse-duffield
- theme package docs — https://pkg.go.dev/github.com/jesseduffield/lazygit/pkg/theme
- lazygit-theme topic (community palettes) — https://github.com/topics/lazygit-theme
- lazytui (framework built to reproduce the look) — https://github.com/DokaDev/lazytui
