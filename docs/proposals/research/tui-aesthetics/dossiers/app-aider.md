# Aesthetic Dossier: **aider**

> "AI Pair Programming in Your Terminal."
> Deliberately austere, terminal-native, chrome-refusing. No alt-screen, no boxes,
> no persistent frame — just pygments-colored git diffs streaming into your real
> scrollback and a single `prompt_toolkit` input line. The *absence* of chrome
> is the aesthetic.

- **Repo:** https://github.com/Aider-AI/aider (shallow-cloned to `undefined/aider/`)
- **Author:** Paul Gauthier (ex-founder, itamar/Inktomi lineage)
- **Category:** austere / industrial-minimal — the honest engineer's tool
- **Language of implementation:** Python, `prompt_toolkit` + `rich` + `pygments`
- **Signature files:** `aider/io.py` (1191 LOC), `aider/mdstream.py`, `aider/waiting.py`, `aider/diffs.py`

---

## 1. The Thesis: Chrome Refusal as Identity

Every terminal AI tool of the 2024–2026 cohort (Claude Code, Codex, Charm's crush,
gemini-cli) reaches for the same move: an **alt-screen full-screen app** with a
persistent bordered frame, a status bar, rounded panels. Aider does the opposite,
and does it on purpose. It never enters the alternate screen buffer. It never draws
a frame around itself. It uses `prompt_toolkit` for exactly ONE widget — the input
prompt — and everything else is `print()`-to-scrollback via `rich.Console`.

The design intent is documented *in a code comment* in `mdstream.py`, which is the
single most revealing sentence in the codebase:

> "Markdown going to the console works better in terminal scrollback buffers.
> The live window doesn't play nice with terminal scrollback."
> — `aider/mdstream.py`, `MarkdownStream.update()` docstring

That is the whole philosophy compressed: **the terminal's own scrollback is the UI.**
Aider refuses to own the screen. It writes lines and lets them scroll away forever,
exactly like `git`, `make`, `gcc`, or a REPL. This is the aesthetic of a tool that
trusts the terminal it lives in rather than replacing it. **Vibe produced:** honesty,
seriousness, "I am a Unix citizen, not an application." The absence of a frame reads
as *I have nothing to hide and nothing to decorate.*

**Concrete technique → feeling:**
- **No alt-screen buffer switch** → the session leaves a permanent, greppable, scroll-back-able transcript in your terminal; feels like a *log*, not an *app*. Trust through auditability.
- **`prompt_toolkit` used only as `PromptSession`, never `Application`** (see `io.py:358`) → a single input line, no persistent chrome; feels like a shell prompt, not a dashboard.
- **`pretty` auto-disables** when output is piped or the terminal is "dumb" (`io.py:279`, `is_dumb_terminal()`) → degrades to plain text without complaint; feels like a well-behaved pipe-friendly CLI.

---

## 2. Color System

Color is the *entire* decorative budget, and it is spent on **semantics, never ornament.**
Aider has no gradients, no theming engine, no accent-color-of-the-week. It has a handful
of role colors, each a bare hex or 16-color name, deployed by *meaning*.

### 2.1 The default palette (`io.py` constructor defaults + `args.py`)

| Role | Default | Hex | Meaning |
|------|---------|-----|---------|
| User input | `blue` (ctor) / `#00cc00` green (CLI default) | green | "this is you talking" |
| Assistant output | `blue` / `#0088ff` | blue | "this is the LLM talking" |
| Tool output | `None` (terminal default fg) | — | neutral machinery |
| Tool **error** | `red` / `#FF2222` | red | stop |
| Tool **warning** | `#FFA500` orange | orange | caution |

### 2.2 Dark vs light mode (`main.py:532`)

The only "theming" is two hardcoded triads. Note the deliberate *saturation lift* for
dark backgrounds — pure-ish neons that survive on black:

```python
# --dark-mode
user_input_color     = "#32FF32"   # electric green
tool_error_color     = "#FF3333"   # hot red
tool_warning_color   = "#FFFF00"   # pure yellow
assistant_output_color = "#00FFFF" # cyan
code_theme           = "monokai"

# --light-mode
user_input_color     = "green"
tool_error_color     = "red"
tool_warning_color   = "#FFA500"   # orange
assistant_output_color = "blue"
code_theme           = "default"
```

**Technique → feeling:** the dark palette is **CRT-terminal phosphor** — #32FF32 green,
#00FFFF cyan, #FFFF00 yellow are the colors of a VT220 and an old amber/green monitor's
"color" cousin. Choosing pure primaries+secondaries over designer pastels signals
*retro-engineering honesty*: these are terminal colors, not brand colors. The vibe is
"oscilloscope," "the machine's native palette," not "our design system."

### 2.3 Git-diff green/red as the dominant identity signal — **borrowed convention as vibe**

Aider's single most recognizable visual is the **red/green unified diff**. But it does
not implement diff coloring itself. It emits its file edits as a **markdown fenced code
block tagged ` ```diff `** (`diffs.py:91`), then lets `rich` + `pygments`' diff lexer
color it via the active `code_theme`. Red = removed lines (`-`), green = added lines (`+`).

This is a *cited borrowing*: aider speaks the universal language of `git diff` / patch
files, and inherits forty years of muscle memory for free. **Vibe produced:** instant
legibility and gravitas. You don't learn aider's diff format; you already know it because
you know `git`. Borrowing the convention *is* the identity move — it says "I am part of
the git-native toolchain," the same way a well-made CLI adopts `--help` conventions.

### 2.4 `NO_COLOR` respected (`io.py:279`)

`if NO_COLOR env set: pretty = False`. Honoring the `NO_COLOR` informal standard is
itself an aesthetic statement of the austere family — *I will disappear entirely if you
ask.* Contrast with tools that fight to keep their branding on screen.

---

## 3. Box-Drawing & Borders: **almost none, and that's the point**

Aider's border budget is essentially zero. There is exactly ONE box in the entire
running UI, and it is significant *because* it is the only one:

- **`box.HEAVY` panel around markdown `h1` headings only** (`mdstream.py:69`, `LeftHeading`).
  A heavy (thick `━┃┏┓`) rule box drawn around top-level headers in the LLM's markdown
  response. Everything else — h2, h3, lists, code — gets *no* border.

- **`console.rule()` horizontal line** between conversation turns (`io.py:509`). A single
  full-width horizontal rule, tinted with the user-input color, separates your turn from
  the previous. In non-pretty mode this collapses to a bare `print()` (blank line).

That's the whole vocabulary: **one heavy box for the one most important heading, one thin
rule between turns.** No side borders, no panel around the chat, no framed status bar.

**Technique → feeling:** scarcity of box-drawing makes the *one* heavy `h1` panel land
with real weight — it's the only "loud" typographic gesture, so it functions like a
chapter title. The heavy weight (vs a rounded or single box) reads as **industrial /
structural**, not soft. Rounded corners would say "friendly app"; heavy square corners
say "spec sheet." And `console.rule()` as the only inter-turn divider gives the
transcript a **manuscript / logbook rhythm** — ruled lines between entries, like a lab
notebook.

Also notable: `LeftHeading` (`mdstream.py:61`) **overrides rich's default centered
headings to left-justify them.** Centered headings feel like a title slide / marketing;
left-justified feels like a document / source file. That one override is a deliberate
vote for "code, not brochure."

---

## 4. Density & Whitespace Rhythm

Aider is **dense but ruled.** It doesn't pad generously the way a Charm/Bubbletea app
does (those breathe with 1–2 cell margins everywhere). Instead:

- **`NoInsetCodeBlock`** (`mdstream.py:52`) strips the horizontal padding rich normally
  puts around code blocks (`padding=(1,0)` — vertical only, zero horizontal). Code sits
  flush at the left margin. **Feeling:** code is presented at *full bleed*, like `cat`-ing
  a file — no decorative inset that would say "this is a UI widget wrapping your code."
- **Blank line preserved before `h2`** (`mdstream.py:77`) — the one deliberate breathing
  gesture, giving section breaks air while keeping everything else tight.
- **Column-packed file lists** (`io.py:1138`, `rich.Columns`) — the "Readonly:" / "Editable:"
  file roster above the prompt is laid out in newspaper columns, dense, alphabetized.

The rhythm is: **tight body text, flush-left code, ruled turn breaks, occasional h2 air.**
It reads like a well-typeset README or a man page, not a spacious dashboard.

---

## 5. Motion Language

Aider's motion is minimal and mechanical — three moving parts, each hand-tuned.

### 5.1 The bouncing scanner spinner (`waiting.py`) — the signature animation

This is aider's mascot-equivalent. `Spinner` pre-renders an 18-frame animation of a
**two-cell marker sweeping back and forth** across a 10-column track — a Larson
scanner / Cylon eye / KITT bounce:

```
█░          ░█         (unicode mode, palette "░█")
 ░█           ░█
#=          =#         (ASCII fallback, "#=" scanning)
```

Key techniques and their feelings:
- **`░█` two-cell "bright head + dim tail"** → gives the scanner *direction* and a sense
  of momentum/inertia; it feels like a physical shuttle, not a spinning glyph. ASCII
  fallback `#=` preserves the same head/tail idea on limited terminals.
- **Bounce, not spin** → back-and-forth on a fixed track reads as *scanning / searching*
  ("the machine is looking for something"), which is exactly the semantic during "Waiting
  for LLM." A rotating braille spinner would feel generic; the scanner feels *diagnostic.*
- **0.5s delay before it appears** (`waiting.py:113`) → fast responses never flash a
  spinner; motion only appears when there's real waiting. Restraint reads as polish.
- **Cursor hidden while spinning, restored on end** (`show_cursor(False/True)`) → no
  blinking cursor fighting the animation.
- **Cursor parked ON the scanner char via backspaces** (`\r` + computed `\b` count,
  `waiting.py:158`) → the hardware cursor rides the bright head of the scanner, so even
  the cursor participates in the animation. A tiny, obsessive touch.
- **In-place redraw with `\r` + trailing-space padding** (never a newline) → the spinner
  lives on ONE line and erases itself completely on `end()` (`\r` + spaces + `\r`),
  leaving *no trace* in scrollback. Motion is ephemeral; the transcript stays clean.

### 5.2 Streaming markdown (`mdstream.py`) — the "live window over stable scrollback" split

This is the cleverest motion design in the app and the direct expression of the
chrome-refusal thesis. As the LLM streams:
- The **last 6 lines** (`live_window = 6`) live in a `rich.Live` region that repaints as
  tokens arrive (they may reflow as markdown resolves).
- Lines that scroll *above* those 6 are considered **stable** and are `print()`-ed into
  **real terminal scrollback**, permanently, never to be repainted.

So text *flows upward out of a small live buffer into permanent history* — like a printer
feeding paper. **Feeling:** the response materializes with a subtle "settling" motion at
the bottom while everything above it is already frozen and scroll-back-able. You get live
feedback without sacrificing a durable transcript. This is the mechanical opposite of a
full-screen app that repaints the whole viewport.

- **Adaptive frame rate** (`min_delay = clamp(render_time*10, 1/20, 2)`, ~20fps cap) →
  the stream throttles itself based on how expensive the markdown is to render, so it
  never thrashes on huge responses. Smoothness through backpressure, not fixed timing.

### 5.3 Streaming-edit progress bar (`diffs.py:26`)

During file edits, aider shows a block progress bar built from `█`/`░`:

```
  42 / 100 lines [████████████░░░░░░░░░░░░░░░░░░] 42%
```

30 cells, filled `█` + empty `░`, with a `n / total lines` counter and a percentage.
Rendered *inside the diff stream* so you watch the patch fill in. **Feeling:** the same
industrial block-glyph vocabulary as the spinner — consistent material. A loading bar made
of the same bricks as the scanner tail says "one designer, one palette of parts."

---

## 6. Typography Substitutes (no fonts, so: weight, case, glyph)

Aider has no Nerd Font icons, no emoji in the running TUI (emoji live only in the README
badges — a web surface). Its typographic tools are austere:

- **Bold via `reverse` video** (`io.py:1009`): `tool_output(..., bold=True)` sets
  `style["reverse"] = bold` — i.e. "bold" is implemented as **inverse video** (swap fg/bg),
  not font-weight bold. Commit messages, subjects of confirm prompts, and important notices
  get a reverse-video block. **Feeling:** a hard, blocky highlight — like a highlighter
  marker or a selected line — that's more emphatic and more *terminal-idiomatic* than bold
  weight. It reads as "the machine is stamping this."
- **Bold-italic for string literals in YOUR input** (`io.py:409`):
  `pygments.literal.string → bold italic {user_input_color}`. As you type, quoted strings
  in your own prompt turn bold-italic green. Subtle but signature.
- **Nerd Fonts: deliberately absent.** No `` file icons, no `` branches. Identity via
  *color role*, not glyph. This is a pointed austere-family choice — icons would be chrome.
- **Block-glyph "material":** `█` (full block) and `░` (light shade) are the only decorative
  glyphs, reused across spinner tail, progress bar fill, and progress bar empty. A tiny,
  coherent glyph kit.
- **Case:** the brand is lowercase **`aider`** everywhere (logo, prompt, docs). Lowercase
  reads as humble, unix-tool, `git`/`make`/`grep` company — not `Aider™`.

### The prompt itself (`io.py:545`)

```
architect multi> ▊
```

The prompt prefix is *informational typography*: it prepends the active **edit format**
(`diff`, `architect`, `ask`, `help`, `context`…) and the word `multi` when in multiline
mode, then `> `. The mode indicator IS the prompt — no separate status bar. **Feeling:**
you always know what mode you're in because it's the last thing before your cursor, exactly
like a shell showing `(venv)` or a git branch in `$PS1`. Mode state lives in the prompt,
not in chrome. This is the whole "minimal mode indicator" strategy: **the prompt string is
the status line.** The continuation line for wrapped/multiline input repeats the same prefix.

- **Input is syntax-highlighted as Markdown as you type** (`io.py:350`,
  `PygmentsLexer(MarkdownLexer)`) → your typing is live-lexed; `# headers`, `` `code` ``,
  `**bold**` colorize under your cursor. Feeling: the input line is treated as *source*,
  reinforcing "you are writing a document to the machine," not filling a chat box.

---

## 7. Voice & Copywriting Tone

Terse, factual, engineer-to-engineer. No exclamation-mark cheer, no "Great question!",
no anthropomorphic assistant persona in the tool's own chrome (the LLM's persona is
whatever model you loaded; aider's *own* voice is flat and mechanical).

Sampled tool copy from the source:
- **Announcements** (`base_coder.py:207`): plain declarative lines, no art:
  ```
  Aider v0.x.y
  Main model: gpt-4o with diff edit format, prompt cache
  Git repo: .git with 1,234 files
  Weak model: gpt-4o-mini
  ```
  A **spec sheet**, not a splash. Version, model, edit format, repo stats. This is the
  entire "startup banner" — no ASCII-art logo, no mascot. The logo exists only as an SVG
  on the website. **Feeling:** boot-up diagnostics, like a BIOS POST or a compiler
  version string. Serious, informational, zero theater.
- **Commit confirmation** (`repo.py:313`): `Commit a1b2c3d Fix off-by-one in parser` (reverse-video bold).
  Terse, git-shaped: short SHA + message. The few "decorative" touches in aider are these
  **auto-commit / file-add confirmations**, and they're decorated only with reverse-video.
- **File adds** (`repo.py:395`): `Added src/foo.py` — three words.
- **Confirm prompts** (`io.py:831`): `(Y)es/(N)o/(A)ll/(S)kip all/(D)on't ask again [Yes]:`
  — capital-letter accelerators inline, default in `[brackets]`. Classic Unix `y/n` idiom.
- **Cost footer** (`commands.py:532`): `$0.0042 1,234 tokens total` and
  `1,000 tokens remaining in context window` — money and tokens stated bluntly, right-aligned.
  **Feeling:** a *meter running*. Aider never hides cost; the taxi-meter honesty is part of
  the trust aesthetic.
- **Empty/error personality:** minimal. `Empty response received from LLM. Check your
  provider account?` (a rare wry aside). Errors are red, one line, no stack-trace drama
  unless it's a real exception.

**Overall voice:** the tone of a **competent colleague reading you the facts** — the
pair-programming stance made textual. Gauthier's repeated public line, *"Aider is an AI
pair programming tool"* (not an autonomous agent), is mirrored in the UI: it does one
step, prints the result, and waits at the `>` prompt. The interface *is* the philosophy.

---

## 8. Identity Moments (what makes it FEEL like aider)

- **The scanner spinner** — the closest thing aider has to a mascot. Bounce, not spin.
- **Red/green unified diffs in scrollback** — the dominant recurring image; borrowed git idiom.
- **The `format> ` mode-in-the-prompt** — you always read your mode off the prompt line.
- **The `console.rule()` between turns** — ruled-notebook rhythm.
- **The one heavy `h1` box** — the single loud typographic gesture in an otherwise flat page.
- **The taxi-meter cost line** — `$0.0042 … tokens total`, honesty as identity.
- **Signature color:** terminal green (`#00cc00`/`#32FF32`) for the human, blue/cyan for the
  machine — a clear two-voice call-and-response palette.
- **Empty state:** there isn't a designed one. You just get the announcements spec sheet and
  a blinking `>`. The *lack* of an onboarding wizard or hero screen is itself the empty state.
  Feeling: "the tool is ready; start typing," like opening `python` or `psql`.

---

## 9. What Makes It Different From Its Siblings

Within the terminal-AI-tool category, aider is the **austere / industrial-minimal** pole:

| Axis | aider | Charm-style (crush, gum) | Claude Code / Codex |
|------|-------|--------------------------|---------------------|
| Screen ownership | none — writes to scrollback | full alt-screen app | full alt-screen app |
| Borders | one heavy h1 box + turn rules | rounded panels everywhere | boxed panels, status bar |
| Persistent chrome | none | header/footer/status | header/footer/status |
| Icons | none (color roles only) | Nerd Fonts, emoji | emoji, glyphs |
| Motion | scanner + live-window stream | animated components, transitions | spinners, animated boxes |
| Diff rendering | ` ```diff ` → pygments, into scrollback | custom styled diff widget | custom boxed diff |
| Transcript | permanent, greppable, real scrollback | ephemeral (alt-screen wiped on exit) | ephemeral |
| Personality | flat, factual, git-native | playful, designed, branded | polished, product-y |

The differentiator in one line: **aider is the only major one that treats the terminal's
scrollback as the canvas instead of painting over it.** Everything follows from that.
Rounded-panel tools feel like *apps that happen to run in a terminal*; aider feels like
*a terminal program*, in the lineage of `git`, `vim` (input only), `less`, and the REPL.
Its austerity is not laziness — the code shows obsessive craft (cursor-riding-the-scanner,
adaptive stream FPS, flush-left code, heavy-box-for-h1-only). It's austerity as a
*designed value*: **chrome would imply the tool doesn't trust the terminal or the user.**
Aider trusts both, and the plainness communicates exactly that.

---

## 10. Describe-the-Screen-in-Words

> You run `aider` in a repo. No splash. Three or four plain lines print in default terminal
> foreground — `Aider v0.x`, `Model: gpt-4o with diff edit format`, `Git repo: .git with 1,204
> files` — like a compiler announcing itself. Below, a green `>` waits. Above the newest prompt,
> a thin colored horizontal rule marks where your last turn ended. You type; your words are
> faintly Markdown-lexed as you go, backticked spans tinting. You hit enter. For half a second
> nothing — then a small two-cell block, bright head and dim tail, begins sweeping left-right
> across a short track: `░░░█░░` … `░░█░░░`, the cursor itself riding the bright cell. When the
> model answers, text starts *flowing up out of the bottom six lines* into your real scrollback,
> permanent, the newest lines still settling and reflowing while everything above has already
> frozen. A top-level heading arrives wrapped in a single heavy `━━━` box — the only box on the
> screen. Then a ` ```diff ` block: red `-` lines, green `+` lines, in monokai, flush to the left
> margin, and a little `██████░░░░ 60%` bar ticking as the patch fills in. When it's done: a
> reverse-video stamp — `Commit 9f2a1c Fix parser off-by-one` — and a quiet meter, `$0.0041
> 1,180 tokens total`. The scanner erases itself without a trace. The green `>` returns. Nothing
> is framed. Nothing is centered. It looks like `git log` had a conversation.

---

## 11. Notable Quotes & Sources

- **Design intent, in the source itself** — `aider/mdstream.py`:
  > "Markdown going to the console works better in terminal scrollback buffers. The live
  > window doesn't play nice with terminal scrollback."
- **Spinner intent** — `aider/waiting.py`:
  > "Minimal spinner that scans a single marker back and forth across a line. The animation
  > is pre-rendered … If the terminal cannot display unicode the frames are converted to
  > plain ASCII."
- **Pair-programming stance** (self.md profile of Gauthier):
  > "Aider is an AI pair programming tool." / "Aider executes one step, waits for feedback,
  > then proceeds. Like real pair programming, there's a driver and a partner watching the
  > code in real-time."
- **Context-control UX** (self.md): "You decide exactly what the LLM sees" — via `/add`,
  `/read`, `/drop`.
- **Git-centric safety** (self.md): "Every change Aider makes gets a git commit with a
  descriptive message."

**Links:**
- Repo: https://github.com/Aider-AI/aider
- Website / screencast: https://aider.chat/
- Gauthier profile & philosophy: https://self.md/people/paul-gauthier-aider/
- Internal-architecture discussion: https://github.com/Aider-AI/aider/issues/181
- Key source: `aider/io.py`, `aider/mdstream.py`, `aider/waiting.py`, `aider/diffs.py`,
  `aider/args.py` (color defaults), `aider/main.py:532` (dark/light palettes)

---

## 12. Transferable Techniques (for a Raxol / TUI designer)

1. **Scrollback-native rendering** — a "stable lines flush to scrollback + small live
   window at the bottom" split gives streaming feedback *and* a durable transcript. Reads
   as honest/log-like.
2. **Mode-in-the-prompt** — encode app mode as a prefix on the input line (`architect multi> `)
   instead of a status bar. Kills chrome, keeps state legible.
3. **One loud gesture in a flat field** — reserve heavy box-drawing for the single most
   important element (h1) so it lands; flatten everything else.
4. **Semantic-only color** — assign each color a *role* (you=green, machine=blue, error=red,
   warn=orange) and never use color decoratively. Two-voice green/blue call-and-response.
5. **Borrow a universal convention wholesale** — red/green unified diff — to inherit
   legibility and gravitas for free.
6. **A scanning bounce spinner with a bright-head/dim-tail two-cell marker** feels
   *diagnostic* (searching) where a rotating spinner feels generic.
7. **Reverse-video as "bold"** — a blockier, more terminal-idiomatic emphasis than font weight.
8. **Ephemeral motion, permanent text** — animations (spinner, progress) erase themselves
   completely (`\r` + spaces), leaving scrollback clean.
9. **Taxi-meter honesty** — surface cost/tokens plainly; transparency reads as trust.
10. **Degrade loudly-gracefully** — respect `NO_COLOR`, detect dumb terminals, auto-plainify
    when piped. Willingness to disappear IS the austere aesthetic.
