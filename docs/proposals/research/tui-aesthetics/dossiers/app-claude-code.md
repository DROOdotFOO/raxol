# Aesthetic Dossier — Claude Code

> **Category:** minimal / warm — the chromeless literate collaborator
> **One-line:** A warm, near-chromeless inline stream that refuses the fullscreen takeover; a single clay-orange hue and whimsical status verbs make it read as a calm, literate collaborator rather than a dashboard.
> **Studied build:** CLI `2.1.212` (CHANGELOG) / launcher pkg `0.2.56`, minified `cli.js` (~5.7 MB) read directly at `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js`. Theme objects, spinner frames, and glyphs below are recovered byte-exact from that bundle.
> **Repo:** https://github.com/anthropics/claude-code (the TUI ships minified; the repo holds plugins, CHANGELOG, scripts — design intent recovered from CHANGELOG + bundle + maintainer interviews).

---

## 1. The core aesthetic thesis: don't own the screen

Almost every TUI of consequence takes the **alt-screen** — it clears your terminal, draws a fullscreen canvas, and hands it back wiped when you quit (vim, htop, lazygit, k9s). Claude Code deliberately does **not**. By default it renders **inline**, printing into your terminal's native scrollback like a very well-dressed `cat`. Your prompt history, the command you typed before, the output above — all stay put. Claude's turns accrete beneath them.

**Technique → feeling:**
- **Inline (non-alt-screen) streaming into native scrollback** → *intimacy and persistence*. The session is a continuous conversation you can scroll up through days later with your shell's own scrollback, not an app you "enter" and "exit." It feels like a colleague talking in your existing workspace, not a program that seized the monitor. Boris Cherny's stated principle — "do the simple thing first… don't stand in front of the model" — is literally rendered here: no chrome standing between you and the text.
- **Opt-in fullscreen only** via `CLAUDE_CODE_NO_FLICKER=1` (flicker-free alt-screen with virtualized scrollback). The takeover is available but off by default — the framework's *rest state* is humble. (CHANGELOG repeatedly fixes fullscreen-only bugs: welcome-splash overflow at 80×24, statusline corruption under nested subagents — telling you fullscreen is the exceptional path, not the home.)
- **Synchronized terminal output under tmux 3.4+** (CHANGELOG: "Fixed rendering flicker … by enabling synchronized terminal output") → *calm*. Even while streaming, redraws are atomic so text never tears. The stream should feel like typing, not like a flickering readout.

This single decision — stay inline — is the aesthetic's spine. Everything warm and quiet below only works *because* the app behaves like literate text in your scrollback rather than a cockpit.

---

## 2. Color: one hue carries the whole brand

The palette is recovered directly from the bundle's theme table. Themes are functions keyed by name: `dark`, `light`, `dark-daltonized`, `light-daltonized`, `dark-ansi`, `light-ansi`, `dark-16`/`light-16`. Truecolor themes use `rgb()`; the `-ansi` fallbacks collapse to the 16-color cube.

### The signature color
```
claude: rgb(215,119,87)   ==  #D97757   (clay / terracotta orange)
```
This one value — **#D97757** — is *the* brand. It is identical in both the **dark** and **light** truecolor themes (only the daltonized variants swap to a purer `rgb(255,153,51)` orange for deuteranopia legibility). It paints: the `✻` in the welcome banner, the Claude sparkle spinner, and Claude's own voice accents. Against a default terminal background (which Claude does **not** override — it inherits your bg), a single warm hue does all the identity work.

**Technique → feeling:** *One restrained warm accent on the user's own background* → *brand as a person, not a skin*. Where a web app would ship a whole design system, Claude Code spends its entire color budget on one clay-orange note. It reads as warm, hand-made, a little retro-analog — the opposite of the cold cyan/green "hacker terminal" cliché or the neon-saturated dashboard.

### The full dark theme (recovered, `GP4`)
| role | value | feeling |
|---|---|---|
| `claude` (accent) | `rgb(215,119,87)` #D97757 | warm identity |
| `text` | `rgb(255,255,255)` | plain, high-contrast body |
| `secondaryText` | `rgb(153,153,153)` | quiet grey for meta/thinking |
| `permission` | `rgb(177,185,249)` periwinkle | calm "may I?" |
| `autoAccept` | `rgb(175,135,255)` lavender | a distinct mode color |
| `bashBorder` | `rgb(253,93,177)` pink | bash mode signals with pink, not red-alarm |
| `success` | `rgb(78,186,101)` | muted forest green, not #0f0 neon |
| `error` | `rgb(255,107,128)` | **coral**, not fire-engine red |
| `warning` | `rgb(255,193,7)` amber | |

**Technique → feeling:** *desaturated, slightly earthy semantic colors* → *low-anxiety*. Note the error color is a **coral** (`rgb(255,107,128)`), not pure red. Success is a **forest green** (`rgb(78,186,101)`), not `#00ff00`. The palette refuses the high-alarm terminal defaults; even failure is delivered in a soft voice. The `-ansi` fallback themes *do* snap back to the harsh cube (`claude:"#cdcd00"` ANSI-yellow, `success:"#00ff00"`, `error:"#ff0000"`) — proving the truecolor palette is a deliberate softening away from what the terminal gives you for free.

### Diffs: two-tier, muted
```
dark:  added bg rgb(34,92,43)   removed bg rgb(122,41,54)      (dim, low-sat plates)
       addedWord rgb(56,166,96) removedWord rgb(179,89,107)    (brighter, for changed spans)
light: added bg rgb(105,219,124) removed bg rgb(255,168,180)   + *Dimmed variants
```
**Technique → feeling:** *dim full-line background + a brighter word-level highlight on the actual change* → *scannable calm*. The whole changed line gets a quiet colored plate; only the bytes that actually changed get the saturated word color. Your eye lands on the edit, not on a wall of green/red. The `*Dimmed` companion colors let context lines around a hunk fade further back. This is diff rendering tuned for *reading*, not for GitHub-style maximal contrast.

---

## 3. Shape language: everything is rounded

The bundle's border usage is lopsided and deliberate:
```
borderStyle:"round"   × 31
borderStyle:"single"  ×  3
borderStyle:"solid"   ×  1
```
Rounded corners (`╭ ╮ ╰ ╯`) are the near-universal box style — the prompt input, permission dialogs, panels, tips. Sharp corners are the rare exception.

**Technique → feeling:** *rounded box-drawing corners as the default* → *softness, approachability, a "bubble" not a "frame"*. In a medium made of right-angled character cells, choosing the rounded glyphs is the single strongest way to signal "friendly." Heavy/double borders (`┃ ═`) would read institutional and loud; single sharp corners read utilitarian; Claude Code's rounded boxes read like speech bubbles. The prompt input box is a rounded rectangle you type into — a soft container, colored by mode (`secondaryBorder` grey at rest, `permission` periwinkle, `warning` amber, or risk-scored colors for dangerous ops).

---

## 4. The signature glyph: the six-petal asterisk `✻`

Claude Code's mascot is not a picture — it's **one character**: `✻` (U+273B, "teardrop-spoked asterisk"), rendered in clay-orange. It is simultaneously the brand mark, the spinner, the thinking indicator, and the welcome sigil.

Recovered from the bundle:
- **Welcome banner:** `✻` (in `claude` orange) + ` Welcome to ` + **Claude Code** (bold) + ` research preview!`. The asterisk *is* the logo; the wordmark is just bold body text beside it.
- **Thinking indicator:** `✻ Thinking…` in `secondaryText` grey + *italic*. Same glyph, but greyed and slanted — the mark literally dims and leans when Claude is in its own head.

**Technique → feeling:** *a single Unicode asterisk as recurring identity glyph* → *a lightweight, literate mascot*. No ASCII-art robot, no logo splash — just a sparkle that shows up in orange when Claude greets you, greys out when it thinks, and animates when it works. It's the typographic equivalent of a friendly signature doodle.

---

## 5. Motion: a blooming, breathing sparkle

The spinner is not a rotating dot-ring (the ubiquitous braille `⠋⠙⠹`). It's the asterisk **growing**. Exact frame arrays from the bundle:

```
default (darwin):  ["·", "✢", "✳", "∗", "✻", "✽"]
default (other):   ["·", "✢", "*", "∗", "✻", "✽"]
"alt-stars":       ["·", "✢", "✳", "∗", "✻", "✽", "✻", "∗", "✳", "✢", "·"]   ← in-and-out
another set:       ["·", "✶", "✸", "✹", "●", "✺", "✹", "✷"]
"tools":           ["⚒", "⚔", …]                                             ← task-flavored
```

**Technique → feeling:**
- **A dot that blooms into a full asterisk** (`· → ✢ → ✳ → ∗ → ✻ → ✽`) → *organic growth, a thing coming to life*. It reads like a spark catching, a flower opening — not a machine's rotating "busy" token. The metaphor is generative, not mechanical.
- **The `alt-stars` palindrome** (`·…✽…·`) grows *and shrinks* → *breathing*. A slow inhale/exhale. This is the strongest anthropomorphizing move in the motion language: the app appears to be *alive and calm*, not "processing."
- **Platform-forked frames** (darwin gets `✳`, others get `*`) → pragmatic glyph-availability care, but the effect is the same bloom.
- **Streaming markdown then freezing to static** — text streams token-by-token live, then, when a message completes, the component swaps to a static Markdown renderer (full GFM). Off-screen messages are cached and their subtrees frozen so a spinner three messages up doesn't repaint the viewport. → *the page settles*. Live turns shimmer; finished turns become calm, permanent, re-readable prose.

---

## 6. Voice through words alone: the 187 gerunds

With no font, no illustration, no sound, Claude Code carries personality almost entirely in **word choice**. The spinner label is a randomly chosen **present-continuous gerund** — 187 of them baked in — shown beside elapsed seconds, a token count, and `(esc to interrupt)`:

```
✻ Cogitating… (12s · ↑ 2.3k tokens · esc to interrupt)
```

The vocabulary is curated into tonal families (community-catalogued; sample from the bundle's list):
- **Cerebral:** Cogitating, Pondering, Ruminating, Contemplating, Deliberating, Musing, Philosophising
- **Whimsical / nonsense:** Booping, Canoodling, Lollygagging, Flibbertigibbeting, Dilly-dallying, Razzle-dazzling, Shenaniganing, Tomfoolering, Whatchamacalliting, Discombobulating
- **Culinary:** Simmering, Caramelizing, Marinating, Fermenting, Julienning, Sautéing, Whisking, Proofing
- **Scientific:** Photosynthesizing, Sublimating, Nucleating, Crystallizing, Osmosing, Precipitating
- **Self-referential:** **Clauding**, Manifesting, Reticulating (a nod to SimCity's "reticulating splines")

**Technique → feeling:** *anthropomorphizing whimsy via a single rotating word* → *a collaborator with a sense of humor, not a progress bar*. "Cogitating" and "Booping" both mean "the model is running," but they perform an *inner life*. Every word is a **gerund** — present tense, ongoing, in-the-room-with-you — which is why it lands as *someone doing something now* rather than a status code. The whimsy is load-bearing: it is the primary device that turns a wait into charm.

It's also contested — which is itself evidence of how much identity these words carry. A GitHub bug report (#23430) calls them "unprofessional and dismissive"; a feature request (#27976) asks to disable/customize them; the community has spun up entire dictionaries (the "Claudionary," 3,000+ community verb packs, a 191-entry "spinner-verbs-dictionary" with IPA phonetics). Anthropic's response was to make them **customizable**, not to remove them — keeping the whimsy as the default personality while letting the buttoned-up opt out.

---

## 7. Structure: quiet nesting instead of boxes

Multi-step tool work is the thing most likely to turn a stream into noise. Claude Code tames it with two glyphs and near-zero chrome, instead of loud bordered panels.

Recovered from the bundle:
- **Tool-call marker:** `⏺` (macOS) / `●` (other) — a colored filled dot at the head of each tool invocation. State is carried by the dot's *color* (running / success / error), not by a badge or a box.
- **Result nesting connector:** `  ⎿  ` — an L-bracket that indents a tool's *result* underneath its *call*. The output hangs off the call like a reply, one level in.

So a tool turn reads as:
```
⏺ Bash(git status)
  ⎿  On branch main
     nothing to commit, working tree clean
```

**Technique → feeling:** *dot-and-hang-indent nesting instead of drawn boxes* → *preserved reading rhythm*. Where a dashboard would wrap every tool call in a heavy bordered panel (loud, screen-hungry), Claude Code summarizes work into a quiet bullet with a dim, indented result. Long output collapses; the eye keeps moving down the page. The whole layout stays **prose-shaped** — a dot, a hang-indent, a return to the left margin — so a 20-step agent run still reads like a document, not a control panel. Large markdown tables are truncated ("… N more rows" after 200) for the same reason: protect the reading cadence over completeness.

**Density → feeling:** the vertical rhythm is generous — blank lines between turns, tool results indented and dimmed (`secondaryText` grey), Claude's prose in plain white with orange only at accent points. The page *breathes*. Nothing competes for attention except the one thing currently streaming. This whitespace cadence is what lets it feel "literate" — it's laid out like well-typeset text, not packed like a TUI trying to use every cell.

---

## 8. Typography substitutes

No real fonts exist here, so meaning is carried by the terminal's four weapons — **bold, dim, italic, color** — used with restraint:
- **Bold** — the wordmark ("**Claude Code**"), headings in rendered markdown, emphasized keywords. Bold = structural importance.
- **Dim / `secondaryText` grey** — thinking text, tool results, meta (elapsed time, token counts). Dim = "supporting, ignorable."
- **Italic** — reserved for the introspective register: `✻ Thinking…` is grey **and** italic. Italic = Claude's private voice.
- **Color as semantics** — orange = Claude/brand, periwinkle = permission, pink = bash mode, coral = error, forest = success. Color is a *role system*, never decoration.
- **Glyph choice** as icon substitute — `✻` (identity), `⏺`/`●` (tool state), `⎿` (nesting), rounded corners (containers). No Nerd Font dependency for the core experience; the semantics survive on a plain Unicode terminal.

**Technique → feeling:** *a strict four-channel typographic code* → *legible literacy*. Because each channel means exactly one thing, the interface reads like a well-edited page: you learn in thirty seconds that grey-italic is Claude thinking, orange is Claude's identity, a dot is a tool. The restraint is the sophistication.

---

## 9. Identity moments

- **Startup:** `✻ Welcome to **Claude Code** research preview!` — orange sparkle, bold wordmark, warm greeting; then a rounded **"Tips for getting started"** box ("Ask Claude to create a new app or clone a repository", "Ask Claude to make a plan with thinking mode: just say 'think'"), and the cwd. There *is* welcome splash art (CHANGELOG fixed it "overflowing the default 80×24 macOS Terminal window") — sized to fit the smallest common terminal, i.e. deliberately modest.
- **Empty prompt:** a rounded input box with `> ` and rotating placeholder tips (`Try "Always use descriptive variable names"`). The empty state teaches by example, in Claude's own suggesting voice.
- **Working:** the breathing orange sparkle + a whimsical gerund + `(esc to interrupt)`. Even the interrupt affordance is gentle lowercase.
- **Error personality:** delivered in **coral, not red**; connection drops auto-retry and *preserve the partial response* rather than dumping a raw stack trace (CHANGELOG). Failure is handled like a colleague apologizing, not a system alarming.
- **Accessibility as aesthetic honesty:** `--ax-screen-reader` / `CLAUDE_AX_SCREEN_READER=1` drops to plain-text rendering — the whimsy is a layer *over* clean semantic text, not a replacement for it.

---

## 10. What makes it feel different from its siblings

Same minimal/warm family (Aider, Codex CLI, Gemini CLI, plain REPLs), but Claude Code diverges on four axes:

1. **It stays inline.** Aider and most agents also live in scrollback, but many coding TUIs grab the alt-screen. Claude Code's refusal to own the screen is the root of its "quiet houseguest" feel.
2. **It spends its whole color budget on one warm hue.** No cyan/green hacker palette, no multi-color dashboard — just clay-orange #D97757 on your own background. The brand is a *temperature*, not a skin.
3. **It anthropomorphizes through words and a breathing sparkle, not through a mascot or ASCII art.** The 187 gerunds and the bloom-and-shrink asterisk make it feel alive without a single drawn face.
4. **It renders work as prose, not panels.** Dot-and-hang-indent nesting + generous whitespace keep even long agent runs shaped like a document you read, versus a cockpit you monitor.

The net personality: a **calm, literate collaborator** who happens to be typing in your terminal — warm, a little playful, never loud, and gone without a trace the moment you scroll up to yesterday's work.

---

## Notable quotes & sources

**Maintainer / design intent (Boris Cherny, Head of Claude Code):**
- "The CLI is the fastest way to release and the easiest to iterate… the terminal window doesn't need anyone's approval and doesn't need to go through any app stores." — via WorkOS / Lenny's Newsletter takeaways
- "Many programming products stand in front of the model, building scaffolds by adding UI elements and other clutter. Claude Code does the opposite… do the simple thing first… keep things as scrappy as possible." — paraphrase of Cherny, Lenny's Podcast / 36Kr profile
- Agentic search "is based on glob and grep… the simplest way to understand the codebase works amazingly well" — the Unix-philosophy ethos that also governs the chromeless UI.

**Bundle-recovered facts (byte-exact from `cli.js` 2.1.212):**
- Accent `claude: rgb(215,119,87)` (#D97757) in both dark & light themes; daltonized → `rgb(255,153,51)`.
- Spinner frames `["·","✢","✳","∗","✻","✽"]` (darwin) and palindrome `alt-stars` `["·","✢","✳","∗","✻","✽","✻","∗","✳","✢","·"]`.
- `✻ Welcome to` banner and `✻ Thinking…` (secondaryText, italic).
- `borderStyle:"round"` ×31 vs `"single"` ×3.
- Tool marker `⏺`/`●`; nesting connector `  ⎿  `.

**Community as evidence of personality reach:**
- "The Claudionary" — claudionary.com — a definitive guide to spinner verbs.
- `claude-code-book/spinner-verbs-dictionary` — 191 entries, IPA phonetics, "taken far too seriously."
- Bug #23430 "Spinner Status Words feel unprofessional and dismissive"; feature #27976 "customize or disable whimsical spinner text" — Anthropic made them customizable rather than removing them.

**Links:**
- Repo: https://github.com/anthropics/claude-code
- Docs — Terminal UI: https://code.claude.com/docs/en/terminal-config
- DeepWiki UI/UX: https://deepwiki.com/anthropics/claude-code/3.9-uiux-and-terminal-integration
- Spinner verbs list: https://deepakness.com/raw/claude-spinner-verbs/
- Claudionary: https://claudionary.com/
- Boris Cherny on Lenny's Newsletter: https://www.lennysnewsletter.com/p/head-of-claude-code
- WorkOS takeaways: https://workos.com/blog/boris-cherny-claude-code-acquired-interview-takeaways
- Terminal UI reverse-engineering: https://dev.to/minnzen/i-studied-claude-codes-leaked-source-and-built-a-terminal-ui-toolkit-from-it-4poh
