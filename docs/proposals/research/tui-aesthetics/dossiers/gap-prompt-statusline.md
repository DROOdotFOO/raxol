# Dossier: Shell Prompt & Statusline Culture

**Slug:** `gap-shell-prompt-statusline-culture-starship-powerlevel10k-oh-my-posh-tmux-powerline-p10k-transient-prompts`
**Scope:** The aesthetic identity of the shell-prompt and statusline layer — the single most-seen TUI surface on earth, and the direct ancestor of a coding-agent harness's status/footer line. Covers Starship, Powerlevel10k, oh-my-posh, Pure/Spaceship zsh prompts, tmux status bars, powerline / tmux-powerline, lualine/airline (vim), and the Nerd-Font-driven segment prompt. How a monospace line of text acquires *character*: segment grammar, two-line/one-line/right-prompt rhythm, transient collapse, glyph/icon culture, palette-as-tribe, and the prompt as a *designed frame* around output.
**Mission framing:** Every claim names a concrete technique AND the feeling it produces. Ergonomics is out of scope except where it doubles as an aesthetic device.

---

## 0. The core constraint (why the prompt is where terminal identity concentrates)

The prompt is the terminal's front door, seen thousands of times a day, and — crucially — it is the one piece of the screen the user *authored themselves*. Every other TUI (an editor, a pager, a TUI app) is someone else's design that you visit. The prompt is the design you wear. This makes it the terminal's equivalent of a **signature, a business card, and a uniform** all at once, and it is why the prompt layer sustains an obsessive ricing subculture (r/unixporn) around a surface that is, functionally, "shows me where I am and waits for input."

The expressive budget is brutally small: one to two lines of a monospace grid, 16/256/truecolor, box-drawing plus Nerd-Font private-use glyphs, whitespace, and — because the prompt redraws every command — a little motion. And yet within that budget the culture has produced a genuinely wide range of *personalities*, from Unix-monk austerity to airline-cockpit maximalism. The whole dossier is about the concrete levers that span that range.

The central thesis: **a prompt is a frame, and the frame's styling tells you how to read everything inside it.** A heavy powerline ribbon says "this is an instrument panel, treat output as telemetry." A single dim `❯` says "this is a quiet workshop, treat output as your own thoughts on paper." The agent-harness relevance is direct — the harness footer/status line *is* a prompt-descendant, and it inherits this entire vocabulary of framing.

---

## 1. Segment grammar: the powerline ribbon vs. the unix-honest plain line

The foundational aesthetic fork in the entire prompt world is **filled-background segments vs. plain-text tokens.** Everything else is downstream of this choice.

### 1.1 The powerline ribbon

The powerline style — born in the Vim `powerline` / `vim-airline` plugins and carried into Powerlevel10k's "Classic"/"Rainbow" styles, oh-my-posh's "powerline" segments, and tmux-powerline — chains colored background blocks together with a single connecting glyph. Each segment paints a solid background color; between two segments sits **U+E0B0** (), a right-pointing filled triangle that takes *the previous segment's background as its foreground and the next segment's background as its own background.* The result is that the arrow appears to be a seamless bevel where one colored panel hands off to the next.

> "Powerline: makes use of a single symbol to separate segments, taking the background color of the previous segment and the foreground of the current one." — oh-my-posh docs, Segment

**Technique → feeling.** The background-color chaining plus the arrow-bevel produces a **seamless machined ribbon — an airline-cockpit / instrument-panel feel.** The eye reads it as a single fabricated object, injection-molded, with beveled edges catching light. It signals "this is an engineered dashboard; the information is instrumentation." It is the terminal's way of faking the *material* GUI has (panels, bevels, shadows) out of nothing but flat color fields and one triangle. Powerlevel10k's own docs describe the Classic style as segments "with connecting glyphs that create a flowing visual effect" — *flowing* is the exact felt quality; the segments melt into one another rather than sitting apart.

The variant separator glyphs are their own micro-language of mood — the Powerline Extra Symbols set (now folded into Nerd Fonts) ships a whole taxonomy, and each family carries a distinct vibe:

| Separator family | Glyph (codepoints) | Vibe it produces |
|---|---|---|
| **Arrows** (original) |  U+E0B0 / U+E0B1 | The default: sharp, aerodynamic, "cockpit HUD," corporate-slick |
| **Curvy** |  U+E0B4–E0B7 | Rounded, soft, friendly — the "pill/bubble" look; approachable, toy-adjacent |
| **Angly** | U+E0B8–E0BF | Slanted/chevron — dynamic, italic-feeling, "in motion," sporty |
| **Flames** (flamey) | U+E0C0–E0C3 | Jagged fire edge — aggressive, gamer, "l33t," hot-rod |
| **Pixelated** (pixey) | U+E0C6 | Dithered fade between panels — retro-digital, glitch, lo-fi CRT |
| **Lego / blocky** | U+E0CE–E0CF | Stepped square teeth — brutalist, blocky, Minecraft-ish, chunky |

**Technique → feeling.** Simply swapping the connector glyph re-skins the *entire personality* of an otherwise identical prompt: the same segments read as corporate cockpit (arrows), friendly capsule (curvy), or aggressive gamer rig (flames). This is the closest the prompt world gets to "pick a typeface" — the separator is the prompt's letterform.

### 1.2 The diamond and the cap (segment terminators)

oh-my-posh's "diamond" style wraps a segment in a leading and trailing rounded cap (**U+E0B6**  and **U+E0B4** , the half-circle "left/right half circle thick") so the segment floats as a self-contained **pill/lozenge** rather than chaining into its neighbor.

> "Diamond style displays segments with diamond symbols where the diamond symbols take the segment background as their foreground color." — oh-my-posh docs

**Technique → feeling.** Where the powerline arrow says *continuous ribbon*, the diamond cap says **discrete jewel / button.** Each segment becomes a rounded tab you could imagine clicking. The vibe is softer, more "app-like," more modern-web (rounded corners are the 2015+ web's signature). lualine leans on this heavily — its default themes render mode/branch/filename as separated rounded "bubbles," giving Neovim its characteristic soft, contemporary look versus airline's harder chained ribbon.

### 1.3 The plain-text line (unix-honest)

The opposite pole: no backgrounds at all. Colored *foreground* text tokens separated by spaces or a slash. Starship's default, Pure, Powerlevel10k's "Lean" style, and Spaceship's default all live here.

> "Lean: A modern, lightweight design without background colors. Saves horizontal space compared to alternatives and works well with monospace fonts." — Powerlevel10k README

**Technique → feeling.** No fill, no bevel, just text — this reads as **unix-honest, quiet, text-first.** It respects the monospace grid instead of fighting it; nothing pretends to be a physical panel. The vibe is "I am a serious tool that trusts you to read words," a Dieter-Rams-in-a-terminal restraint. It also reads as *portable and humble* — plain foreground colors degrade gracefully to any terminal, any font, no Nerd Font required. The powerline ribbon flexes "I configured a patched font and a 256-color theme"; the lean line flexes "I need none of that." Both are status signals; they signal opposite tribes (maximalist ricer vs. minimalist purist).

---

## 2. The rhythm of lines: one-line, two-line, and the right prompt

Beyond segment styling, the single biggest lever on a prompt's *feeling* is its **vertical and horizontal rhythm** — how it uses the blank space of the line.

### 2.1 The two-line prompt with a leading blank line — editorial calm

Pure's defining move: the prompt is two lines, and there is a **blank line above every prompt.** Line 1 carries context (path, git, async status); line 2 is a lone `❯` awaiting input.

**Technique → feeling.** The blank leading line is pure **breathing room / editorial calm.** It visually chunks scrollback into paragraphs — each command-and-output becomes its own stanza separated by whitespace, instead of a dense wall. The felt quality is *unhurried, spacious, expensive* (whitespace is the oldest luxury signal in typography). Putting the prompt character alone on its own line means your cursor always sits at the same left-column position regardless of how long the path/git info is — a subtle *stability/groundedness*, your input always begins from the same home base. This is the "designed calm" end of the spectrum, and it is why Pure feels like a well-set page rather than a control panel.

Powerlevel10k's own docs note the two-line rationale bluntly: it "offers increased horizontal space for command entry without reducing scrollback density" — but the *feel* is the point: room to breathe while typing a long command, without the prompt crowding your text.

### 2.2 The one-line prompt — dense, immediate, terse

Everything on one line, prompt char at the end. **Technique → feeling:** **dense, fast, no-ceremony.** Maximizes scrollback history per screen; reads as "get to work." Terse and efficient, but can feel cramped when path + git + versions overflow toward the right and shove your cursor to mid-screen.

### 2.3 The right prompt (RPROMPT / right_format) — the balanced dashboard

zsh/fish/starship support a **right-aligned prompt** rendered on the same line as input, hugging the right margin.

> "Some shells support a right prompt which renders on the same line as the input." — Starship advanced-config

Convention: put *ambient, glanceable* data on the right — timestamp, command duration, git state, node/python version — while the left stays lean.

**Technique → feeling.** The right prompt produces a **balanced, dashboard-like symmetry.** The typing zone sits in a calm left-anchored gutter while status floats to the far margin like a car's speedometer cluster — present but out of your way. It's the terminal discovering *justified layout*: content pushed to both edges with a void between reads as *composed, intentional, framed.* Starship formalizes this with the **`fill` module**, which stretches a repeated character (often a space, sometimes a dotted `┄` leader) to push right-hand content to the margin — the same device as a table-of-contents dot-leader, and it carries the same *typeset ledger* feel.

### 2.4 The continuation prompt — the quiet second voice

For multi-line input, Starship's default continuation prompt is a dim `[∙](bright-black)` — a single dark-gray dot. **Technique → feeling:** the dimmed dot is a **deferential, whispering "keep going"** — it marks continuation without competing with the primary prompt glyph. A small thing, but it shows the design instinct: the *live* line speaks in full color, subordinate lines whisper in bright-black.

---

## 3. The transient prompt: discipline made visible

The most conceptually interesting motion in the prompt world. A **transient prompt** renders the full, ornate prompt *while you are typing*, then — the instant you hit Enter — **rewrites that past prompt into a minimal stub** (often a lone `❯` or `$`), keeping only the live prompt ornate.

> "Powerlevel10k will trim down every prompt when accepting a command line." — Powerlevel10k README

> "Your command prompt is normally rendered in all its helpful glory, but is collapsed into a more minimalistic representation of itself once you execute a command." — nevkontakte.com

The motivation is explicitly aesthetic-cum-practical:

> "The additional information is very handy, but it also clutters the terminal scrollback. More than that, at work I often need to copy and paste my terminal logs... Editing the fluff from my prompt gets annoying fast." — nevkontakte.com

**Technique → feeling.** Transient collapse produces **clean scrollback / disciplined / tidied-up-after-yourself.** Scrolling back through history, you don't wade through fifty repetitions of a fat rainbow ribbon — you see a clean column of terse `❯ git status` / `❯ make` stubs, each command a single quiet line, with full ornamentation reserved for the *now*. It creates a **visual "present tense"**: the live prompt glows with context, the past fades to minimalism, so the screen enforces a hierarchy of *now vs. done*. The felt quality is *self-cleaning, monastic, respectful of the record.* It resolves the maximalist-vs-minimalist tension by letting you have the ornate prompt *only in the moment it's useful* and the clean prompt *everywhere it would otherwise be noise.* This is arguably the single most important idea to steal for a coding-agent harness (see §8).

Pairing note from the culture: "sparse prompts also work great in combination with transient prompt" and two-line prompts pair especially well — the transient stub collapses the two-line prompt back to one, so history stays dense while the live prompt stays roomy.

---

## 4. The prompt character as personal sigil

Strip a prompt to one element and it's the **prompt character** — the glyph that says "type here." It is the smallest possible brand mark, and the culture treats it as a personal signature.

The canon:
- `$` / `#` / `%` / `>` — the classic POSIX sigils. `$` = user, `#` = root (danger), `%` = csh/zsh. **Vibe:** *institutional, default, Bell-Labs-honest.* Root's `#` turning the prompt implicitly dangerous is the original "ambient telemetry."
- `❯` (U+2771, heavy right-angle bracket) — Pure's signature, now the de-facto "modern minimal" prompt char. **Vibe:** *sleek, sharp, contemporary, designed.* A chevron leaning forward — momentum without ornament. Its ubiquity in Pure/Starship/spaceship made it the "I use a nice prompt" secret handshake.
- `❱`, `»`, `➜` (oh-my-zsh's arrow), `λ` (lambda — "I'm a functional-programming person"), `§`, `∴`, `→`. **Vibe:** each is a **personal sigil / brand signature.** `λ` announces a tribe; `➜` is instantly "oh-my-zsh robbyrussell default"; a bare `>` is austere.

**Technique → feeling.** A single well-chosen prompt glyph is **minimal-cool / personal-sigil** — maximum identity per character. And the culture layers *state* onto it: the near-universal move is **the prompt char turns red on the last command's failure** (Pure, Starship, p10k all do this).

> "When your last command failed, the prompt turns red." — sindresorhus/pure

**Technique → feeling.** The color-shifting prompt char is **ambient telemetry with zero footprint** — you feel the exit code in your peripheral vision before you read anything. Green/default `❯` = all well; red `❯` = something broke. Powerlevel10k extends this to *vi mode*: `❯` (insert), `❮` (command), `V` (visual), `▶` (replace), each also reddening on error — so the prompt char alone encodes both editing mode and last-command health. The glyph becomes a **status light**, the terminal's idiom for a car dashboard's warning lamps.

---

## 5. Glyph and icon culture: Nerd Fonts as the terminal's emoji

Nerd Fonts patch programming fonts with 10,000+ private-use-area icon glyphs (Devicons, Font Awesome, Octicons, Material, Powerline Extra, Font Logos). This is the substrate that lets a prompt show a Python logo, a Git branch, an AWS mark, an OS logo.

> "Shell prompts like Starship, Powerlevel10k, or Oh My Posh use Powerline symbols for segment separators and Nerd Font icons for Git status, language versions, and system information." — nerdfonts ecosystem

The vocabulary of prompt icons and their feelings:
- **Language devicons** ( Python,  Node,  Rust,  Go) shown next to detected version. **Vibe:** *toy-playful, branded, "my tools have mascots."* A folder full of little logos makes the prompt feel like a game HUD with equipped items. It's the terminal's most *fun* register — colorful, recognizable, slightly showing-off.
- **Git branch glyph** ( U+E0A0, the powerline branch mark) before the branch name. **Vibe:** *fluent, insider* — the branch icon is so standardized it reads as "of course you know what this is." Paired with dirty/clean status symbols (`�“`, `±`, `⇡⇣` ahead/behind arrows, `?` untracked, `!` modified) it becomes a **compact git dashboard.**
- **OS / distro logos** ( Apple,  Linux,  Arch,  Ubuntu,  Windows). **Vibe:** *tribal identity, belonging* — the Arch logo in your prompt is a flag. Font Logos exists purely for this flex.
- **Folder / lock / cloud / container / battery** icons. **Vibe:** *at-a-glance instrumentation, "smart-watch complications for your shell."*

**Technique → feeling.** Nerd-Font icons convert the prompt from *text* to **iconography** — the felt shift is from "reading a status string" to "scanning a HUD." It's warmer, faster to parse, and unmistakably *2020s.* But it carries a tribal cost/signal: icons require the patched font, so an icon-heavy prompt is also a declaration "I have configured my environment," and it renders as tofu boxes (□□□) on any machine without the font — the aesthetic is *conditional*, which is itself part of its exclusivity vibe. Starship's philosophy explicitly hedges this: *"You should see useful information, not noise... no hard-coded colors or emojis unless you explicitly enable them"* — the minimalist's counter-position that icons are opt-in ornament, not default.

---

## 6. Palette as tribe: nord / gruvbox / catppuccin / tokyonight

Prompts and statuslines are the most visible place a **named colorscheme** shows itself, and adopting one is an act of belonging.

The big tribes (each with an emotional register):
- **Nord** — "an arctic, north-bluish clean and elegant color theme." **Vibe:** *cool, calm, muted, Scandinavian, professional restraint.* Low saturation, frosty blues/grays — a prompt in Nord feels composed and adult.
- **Gruvbox** — warm retro browns, oranges, mustard, olive. **Vibe:** *cozy, analog, 70s-den, warm-lamp.* The anti-cyberpunk; feels like worn leather and paper.
- **Catppuccin** (Latte/Frappé/Macchiato/Mocha) — soft pastel lavender/pink/teal on deep navy. **Vibe:** *soft, cute, dreamy, gentle, "aesthetic."* The dominant 2020s ricing palette; a Catppuccin prompt reads as *tasteful and current.* Its four named flavors are themselves a belonging system.
- **Tokyo Night / Dracula / Rosé Pine** — neon-on-dark, high-contrast purples/pinks. **Vibe:** *nocturnal, moody, cyberpunk-lite, "coding at 2am."*

**Technique → feeling.** Choosing a palette for your prompt is choosing a **tribe and a mood in one gesture** — the exact colors are secondary to the *belonging* they signal. The tell is that these palettes ship coordinated across the whole stack: the same Catppuccin Mocha lands in the prompt, tmux status bar, lualine, and editor, so the *entire terminal reads as one designed object.* tmux-powerkit ships "43 themes with 71 variants"; Catppuccin's tmux port supports all four flavors with a matching "Style Guide." The aesthetic payoff is **coherence** — the felt quality of a fully-themed rig is "someone art-directed this entire environment," which is the ricing subculture's core pleasure. A prompt that matches its tmux bar which matches its editor is the terminal equivalent of a matched suit.

---

## 7. The tmux status bar: the persistent frame

If the prompt is transient (redrawn per command), the **tmux status line** is the *permanent* frame — a full-width bar pinned to the screen edge, always present, wrapping every prompt and app inside it.

Anatomy: left block (session name, often in a colored "tab"), center (window list — each window a tab, current window highlighted), right block (host, date/time, battery, CPU, weather, music). Powerline-styled, it chains these into a continuous ribbon edge-to-edge.

**Technique → feeling.** The tmux bar is a **chrome / OS-shell / cockpit surround.** Because it never disappears, it converts the whole terminal from "a scrolling teletype" into "an application window with a title bar and status bar" — it *frames* everything, and the frame's styling sets the ambient mood of the entire session. A powerline tmux bar with a colored session-name tab on the left and a clock on the right makes the terminal feel like a **standalone OS**, a self-contained instrument you inhabit for hours. The current-window highlight (an inverted or brighter tab) is the "you are here" — the same ambient-telemetry idiom as the prompt's error-red, scaled up to a persistent surface. This is the closest ancestor to a coding-agent harness's persistent footer: a always-present, full-width, themed strip that frames the working area.

---

## 8. The vim/neovim statusline: mode-color as ambient state

lualine/airline are the prompt idea applied to an editor. Sections **A B C … X Y Z** run left-to-right (A = mode, B = git branch, C = filename … Z = position), each a powerline or bubble segment.

The signature technique: **the leftmost section (A) changes background color by editor mode.** Normal = blue/gray, Insert = green, Visual = orange/purple, Replace = red.

> "To create a custom theme you need to define a colorscheme for each of vim's modes... section A colors change whenever you switch between normal, insert, visual, replace." — lualine wiki

**Technique → feeling.** Mode-colored section A is **ambient telemetry as a mood ring** — you feel your editing mode as a *color wash* in peripheral vision, never needing to read the word "INSERT." The felt quality is *the interface breathing with you*: it goes green when you type, red when you're about to overwrite. The whole-left-edge color flip is dramatic enough to register subconsciously — it's the statusline equivalent of a stage light changing with the scene. This is the richest single idea the vim-statusline layer contributes: **map a discrete state to a whole-segment color, and the user absorbs the state without reading.**

---

## 9. Describe-the-screen: three prompts, same directory

Picture the same moment — you've `cd`'d into `~/dev/raxol` on a dirty `main` branch, last command succeeded — rendered three ways.

**Powerlevel10k Rainbow.** A fat ribbon of stacked colored panels marches across the line: a blue panel with a home-folder icon and `~/dev/raxol`, an arrow-bevel handing off to a green panel with the git branch glyph and `main`, then a yellow diamond flagging `±` uncommitted changes, the whole thing beveled and continuous like the side of a jetliner, a clock floating far right. Line two: a lone `❯`. It feels like *sitting down at a lit instrument panel* — powerful, busy, a little proud of itself.

**Pure.** A blank line. Then, in dim gray, `~/dev/raxol`, and in muted magenta ` main*`. Another line. A single magenta `❯` and your cursor. Vast whitespace around it. It feels like *a clean sheet of good paper* — calm, roomy, confident enough to show almost nothing.

**Starship default (lean).** One line: `~/dev/raxol` in bold cyan, `on  main` in purple with a tiny `[!]`, ` v20.1.0` node icon in green if the repo has a package.json, then `❯` in green (it'd be red if the last command failed). No backgrounds, colored words on the void. It feels like *a well-labeled workbench* — informative, text-honest, unpretentious but clearly designed.

Same three facts. Three completely different *characters* — cockpit, atelier, workbench — built from nothing but background-fill choice, whitespace rhythm, and color.

---

## 10. Lineage and influences

- **The POSIX `$PS1`** — the primordial prompt. `\u@\h:\w\$` (user@host:path$). Escape codes and raw ANSI. **Vibe:** institutional Unix, seen on every server. The thing all the others are reacting against.
- **oh-my-zsh (2009)** & the `robbyrussell` theme (`➜` arrow) — democratized the "nice prompt" and the git-branch-in-prompt for a generation; made prompt customization a mainstream dev-culture activity.
- **vim-powerline → powerline (Python, 2013)** — invented the arrow-bevel segment ribbon and the U+E0Bx glyph convention; the origin of the entire "machined ribbon" aesthetic across shells, tmux, and editors.
- **Pure (sindresorhus, ~2015)** — the minimalist counter-reformation; two-line, blank-line, `❯`, async git; defined "modern minimal."
- **Powerlevel9k → Powerlevel10k (romkatv, 2019)** — maximalism perfected + the performance obsession (instant prompt, transient prompt); proved ornate could also be *fast*.
- **Nerd Fonts (ryanoasis)** — the icon substrate that made language logos / OS marks / git glyphs universal.
- **Starship (Rust, 2019)** — cross-shell, TOML-configured, minimal-by-default; the "just works everywhere, quietly" position.
- **oh-my-posh** — brought the whole segment/theme culture cross-platform (PowerShell-first, then everywhere) with a theme *gallery* and drag-drop visual configurator — prompt design as a browsable catalog.
- **Catppuccin/Nord/Gruvbox eras (2020s)** — the palette-as-coordinated-system phase; the whole rig themed as one object.

---

## 11. Notable quotes

> "You should see useful information, not noise. No hard-coded colors or emojis unless you explicitly enable them." — Starship philosophy

> "Lean: A modern, lightweight design without background colors." / "Classic: ...connecting glyphs that create a flowing visual effect." — Powerlevel10k README

> "Powerline: makes use of a single symbol to separate segments, taking the background color of the previous segment and the foreground of the current one." — oh-my-posh docs

> "Your command prompt is normally rendered in all its helpful glory, but is collapsed into a more minimalistic representation of itself once you execute the command." — nevkontakte.com, on transient prompts

> "The additional information is very handy, but it also clutters the terminal scrollback... Editing the fluff from my prompt gets annoying fast." — nevkontakte.com

> "When your last command failed, the prompt turns red." — sindresorhus/pure

> "❯, ❮, V, ▶ for insert, command, visual and replace mode respectively; turns red on error." — Powerlevel10k README (prompt char as status light)

> "Nord: an arctic, north-bluish clean and elegant color theme." — tmux theme docs

---

## 12. Synthesis: the grammar of prompt-as-identity

| Dial | One end → feeling | Other end → feeling |
|---|---|---|
| **Segment fill** | plain-text tokens → unix-honest, quiet, portable | powerline background ribbon → machined cockpit, instrumented |
| **Separator glyph** | curvy/diamond  → soft pill, friendly, app-like | flames/arrows / → aggressive/aerodynamic, gamer/corporate |
| **Line count** | one line → dense, terse, get-to-work | two lines + blank → editorial calm, breathing room |
| **Horizontal balance** | left-anchored only → immediate, cramped | left + right prompt / fill → balanced dashboard, composed |
| **Prompt char** | `$`/`%` → institutional, default | `❯`/`λ`/`§` → personal sigil, minimal-cool |
| **Prompt-char state** | static → mute | red-on-error / mode-colored → ambient telemetry, status light |
| **History treatment** | every prompt stays ornate → cluttered, loud scrollback | transient collapse → clean, disciplined, present-tense |
| **Icons** | text words → honest, universal, tofu-proof | Nerd-Font devicons/logos → toy-playful, branded, HUD, tribal |
| **Palette** | terminal default 16-color → neutral, native | Catppuccin/Nord/Gruvbox → tribe + mood, art-directed coherence |
| **Statusline persistence** | prompt only (transient frame) → lightweight | tmux/lualine bar (permanent frame) → OS-shell cockpit surround |
| **Mode signaling** | text label ("INSERT") → read it | whole-section color wash → mood-ring, felt not read |

**The meta-principles that recur across every technique:**

1. **Fill vs. no-fill is the master fork.** Background color turns text into *material* (panels, bevels, ribbons → cockpit); its absence keeps text as *text* (words on the void → workbench). Almost every other choice inherits its register from this one.
2. **State should be felt, not read.** The best prompt techniques encode information as *color and glyph shifts in peripheral vision* — red-on-error, mode-color washes, dirty-git symbols, the current-window highlight. The user absorbs status without a saccade. This is ambient telemetry, and it's the prompt world's signature contribution.
3. **The prompt is a designed frame, and the frame tells you how to read the contents.** Heavy ribbon → treat output as instrumentation; quiet `❯` on whitespace → treat output as your own workshop notes. The styling of the container sets the reading mode for everything inside it.
4. **Reserve ornament for the present.** The transient prompt is the deepest idea here: full character *now*, minimal stub *in the past*. It dissolves the maximalist/minimalist war by making richness a function of *tense*.
5. **Coherence is the ricing payoff.** A prompt themed to match tmux themed to match the editor reads as one art-directed object; the pleasure is *system*, not any single segment.

---

## 13. Implications for a coding-agent harness status/footer line

The harness footer *is* a prompt-descendant — a persistent, full-width, themed strip framing streaming agent output. Direct extractions:

- **Choose the master fork deliberately.** A filled-background footer ribbon reads as *instrument panel / the agent is a machine you're monitoring*; a plain-text footer reads as *quiet collaborator / notes alongside your work.* Pick the register that matches the product's desired relationship. For an agent that should feel like a calm pair-programmer, lean plain-text (Starship/Pure register) beats a rainbow cockpit; for a "mission control" framing, the powerline ribbon earns its weight.
- **Encode agent state as ambient color, not words.** Steal the red-on-error prompt char and the mode-colored section-A: map agent phase (thinking / editing / running / waiting-for-you / errored) to a **whole-segment color wash or a single sigil color** so the user feels the state peripherally. Don't make them read "STATUS: RUNNING" when a color can carry it.
- **Adopt the transient-prompt discipline for scrollback.** The agent will emit hundreds of turns. Render each *completed* turn's status line as a **collapsed minimal stub** (a dim glyph + one-line summary) and reserve the full ornate status for the *live* turn. This keeps transcript scrollback clean and copy-paste-friendly — exactly the pain nevkontakte.com names — and creates a felt "present tense" so the user's eye lands on the active turn.
- **Use a two-line / breathing rhythm for the live prompt.** A blank line before the active input/status block chunks the transcript into readable stanzas (editorial calm) rather than a wall — high value when output is dense.
- **Right-align ambient metadata.** Token count, elapsed time, model name, cost — push these to the right margin via a `fill`-style justify so the left stays a calm reading gutter and metadata floats out of the way (balanced dashboard).
- **A single sigil is your brand.** One well-chosen prompt/spinner glyph in a signature color is more identity-per-pixel than any amount of chrome — the `❯` lesson. Let the harness have *one* recognizable mark.
- **Theme coherently or not at all.** If the footer, any panels, and diff coloring don't share one palette, the tool reads as unfinished. Coherence *is* the polish; pick one named palette register and hold it across every surface.
- **Icons are conditional — degrade gracefully.** Nerd-Font glyphs are toy-playful and branded but render as tofu without the font. Gate them behind capability detection with text fallbacks, or the "designed" look inverts into "broken" on a bare terminal.

---

## Sources

- Starship — presets & philosophy — https://starship.rs/presets/
- Starship — advanced config (right_format, fill, transient, continuation) — https://starship.rs/advanced-config/
- starship/starship (README, "minimal, blazing-fast, infinitely customizable") — https://github.com/starship/starship
- romkatv/powerlevel10k (README: Lean/Classic/Rainbow/Pure, transient, instant, prompt char, powerline separators) — https://github.com/romkatv/powerlevel10k/blob/master/README.md
- Terminal Guide — Powerlevel10k styles overview — https://www.terminal.guide/tools/shell-enhancement/powerlevel10k/
- oh-my-posh — Segment styles (powerline / diamond / plain / accordion) — https://ohmyposh.dev/docs/configuration/segment
- oh-my-posh — Transient prompt — https://ohmyposh.dev/docs/configuration/transient
- oh-my-posh — powerline diamond hybrid discussion (color chaining) — https://github.com/JanDeDobbeleer/oh-my-posh/issues/1099
- sindresorhus/pure (two-line, ❯, red-on-fail, async git) — https://github.com/sindresorhus/pure
- Hardscrabble — *sindresorhus/pure is such a good zsh prompt* — https://www.hardscrabble.net/2021/pure-prompt/
- nevkontakte — *Custom transient prompt in Fish* (scrollback clutter, collapse rationale) — https://nevkontakte.com/2025/transient-fish.html
- ryanoasis/powerline-extra-symbols (arrows/curvy/angly/flames/pixelated/lego glyph families + codepoints) — https://github.com/ryanoasis/powerline-extra-symbols/blob/master/README.md
- ryanoasis/nerd-fonts (Devicons, Octicons, Font Logos, Powerline Extra; icon culture) — https://github.com/ryanoasis/nerd-fonts
- nerdfonts.com — glyph aggregator — https://www.nerdfonts.com/
- Powerline — ArchWiki (U+E0B0/E0B1 separators, patched-font requirement, ecosystem) — https://wiki.archlinux.org/title/Powerline
- nvim-lualine/lualine.nvim — Writing a theme (per-mode section colors) — https://github.com/nvim-lualine/lualine.nvim/wiki/Writing-a-theme
- nvim-lualine/lualine.nvim — Introduction (A–Z sections) — https://github.com/nvim-lualine/lualine.nvim/wiki/Introduction
- Tmux Powerline Bar — Catppuccin/Nord/Gruvbox/Dracula theme set — https://armando-rios.github.io/tmux/
- fabioluciano/tmux-powerkit — 43 themes / 71 variants — https://github.com/fabioluciano/tmux-powerkit
