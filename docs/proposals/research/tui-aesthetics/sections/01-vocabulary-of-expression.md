# The Vocabulary of Expression

## The complete replacement toolkit: for every GUI expressive device, its character-grid substitutes and the feeling each produces

> **Scope.** A graphical app expresses character through gloss, drop-shadow, corner-radius, font selection, sub-pixel spacing, easing curves, texture, and brand color. A terminal app is handed *none* of these. It has a monospace character grid, 16/256/truecolor, box-drawing and Unicode glyphs, whitespace, motion-via-redraw, and words. This section is a **device catalog**: it takes each GUI expressive tool, names its grid substitute(s), and — for every substitute — states *what it is, what it evokes, who uses it, and how it fails.* Every claim is anchored to a concrete technique and cited to a dossier in this corpus. It is meant to be read as a designer's reference, not an essay.

---

## 0. The core inversion, and the master substitution table

The GUI expresses through **added material**: a shadow is pixels the layout didn't strictly need, gloss is a specular gradient painted over a button, a custom font is a purchased asset. The terminal has no spare material — its native default is wall-to-wall equal-weight monochrome text. So the grid's expressive economy runs the opposite way: **every expressive act is a *subtraction from*, *re-coding of*, or *rhythm imposed on* a uniform field of cells.** Emptiness must be *paid for* (the gap-layout dossier: "spending cells on nothing is the single most expensive-looking move available on a character grid… Emptiness has to be *paid for*; that payment is what reads as confidence"). Color must be *rationed* to stay meaningful. A glyph must be *chosen* from a fixed repertoire. This scarcity is why the terminal reads emotion so loudly: when the whole field is uniform, a single deviation — one warm hue, one rounded corner, one bright cell — carries enormous signal.

The one structural caveat that governs the entire toolkit (from the substrate dossier): **the emulator co-authors roughly half the vibe and the app cannot see or control it** — font, ligatures, glyph raster sharpness, cursor animation, background blur, CRT shaders, window padding all belong to the user's terminal. The devices below are the half the *app* owns: composition, color roles, box style, glyph choice, and content-level motion. Design so the app "reads as intentional under a matte flat terminal, and reads as *gorgeous* when the user's phosphor-glow, frosted-glass, comet-cursor substrate paints it in."

| GUI expressive device | Character-grid substitute(s) | Governing dossier(s) |
|---|---|---|
| **Brand color / logo fill** | one restrained accent on the *inherited* background (brand as a *temperature*); ANSI-16 remap to coerce all output on-brand | Claude Code, Crush, Gemini CLI |
| **Design-system tokens** | semantic role palette generated from a seed (auto light/dark ramps) | Textual, brick, Nushell, k9s |
| **Gloss / specular highlight** | a raised-cosine *shine sweep* across a logo; per-grapheme Hcl gradient | Grok Build, Crush |
| **Drop-shadow / elevation** | surface-lightness layering; alpha overlay planes; darkening depth-gradient; grey-ramp corner-glyph extrusion; whitespace itself | Textual, notcurses, btop, Posting |
| **Corner-radius / card chrome** | rounded `╭╮╰╯` vs sharp `┌┐` vs heavy `┏┓` vs double `╔╗` box-drawing | lazygit, Zellij, Charm, mc |
| **Custom font choice** | bold/dim/italic/reverse as a 4-channel type system; casing; color-as-weight; substrate ligatures | Claude Code, mc, aider |
| **Pixel-perfect spacing** | 1-cell padding ring; density↔airiness dial; tabulated alignment | gap-layout, Charm, pterm |
| **Animation curves / transitions** | spinner glyph×interval; `sin²` breathing; streaming reveal cadence; instant snap | gap-thinking, Grok Build, Claude Code |
| **Texture / material** | block-glyph "material kit"; `hatch` fills; sub-cell braille; tinted-not-black grounds | Posting, notcurses, btop, ncmpcpp |
| **Icons / illustration / imagery** | Nerd-Font/emoji glyphs; geometric `◇◆●○` kits; ASCII/block wordmarks; graphics-protocol pixels | superfile, k9s, Crush, yazi |
| **Personality / brand voice** | whimsical gerunds; emoji-affect; taxi-meter honesty; self-narrating chrome; error tone | Claude Code, k9s, gap-thinking |
| **Sound / notification** | OSC toast, visual-bell color-pulse, completion chime timbre-pair, haptics | gap-sound |

---

# DEVICE FAMILY 1 — COLOR DEPLOYMENT
### (replaces: brand color, gloss-as-hue, design-system palette, texture-via-tint)

Color is the single most information-dense channel on the grid, and every dossier converges on one law: **on the terminal, color is not decoration — it is a second encoding of meaning, and its power comes from scarcity.** The GUI can afford decorative color because it has shape, depth, and imagery to carry meaning; the terminal spends color *only* on meaning precisely because it has so little else.

### 1.1 Semantic / role color — "hue means a thing"
- **What it is.** Assign each color a fixed *role* and never use it decoratively. aider's entire budget: you=green, machine=blue, error=red, warn=orange (`app-aider.md` §2). lazygit turns color into "a type system for git state" — staged=green, unstaged=red, cherry-pick=cyan, rebase=yellow — "once you learn the six colors you can read the whole screen without reading a word" (`app-lazygit.md` §4). Nushell colors cells *by the runtime type of the value*: filesize=cyan, datetime=purple, bool=bright, structural chrome=green (`lib-nushell…md` §3). k9s maps eight pod-lifecycle states to hues so "a screen of 60 pods becomes a heat map you read peripherally" (`app-k9s.md` §3).
- **What it evokes.** Legibility, intelligence, "the app understands its contents." You navigate by color-memory, pre-cognitively.
- **Who uses it.** Every serious tool; it is the terminal's default color discipline. aider, lazygit, Nushell, k9s, mc (green=exec, magenta=archive, white=dir).
- **Failure mode.** Assigning color to too many things ("rainbow puke" `LS_COLORS`, per `lib-nushell…md` §3.1) collapses the scarcity that makes each hue mean something. **Rule: leave the body `default`, accent only the meaningful few** — "color scarcity is legibility" (Nushell).

### 1.2 One accent on the inherited background — "brand as a temperature, not a skin"
- **What it is.** Spend the *entire* color budget on a single warm hue over the user's own (un-overridden) background. Claude Code paints its whole identity in one clay-orange `#D97757`, "on your own background… The brand is a *temperature*, not a skin" (`app-claude-code.md` §2). lazygit's whole look is "one accent decision repeated everywhere" — the green bold active border (`app-lazygit.md` §1). brick lets unspecified channels fall through to the terminal default so "the app belongs to *your* terminal" (`lib-brick…md` §3).
- **What it evokes.** Warmth, restraint, "a person not a product"; the app reads as a considerate houseguest rather than a program that seized the monitor.
- **Who uses it.** Claude Code (single terracotta), lazygit (single green), aider (green/blue two-voice), mc (the CGA blue *is* the brand).
- **Failure mode.** A single accent on a background you *don't* control means legibility depends on the user's theme; pick a hue that survives on both light and dark, or detect the background (Textual/yazi/Grok all query it).

### 1.3 Color as a second encoding of the value — the gradient-by-data move
- **What it is.** Map a value's magnitude to a color ramp so hue *is* the datum. btop expands each metric's 3-stop gradient into 101 interpolated steps indexed by the value's percentage — "a CPU meter at 73% draws itself in `gradient[73]`… the hue tells you the load before you read the digits" (`app-btop.md` §2.1). ncmpcpp maps audio amplitude to a heat ramp so "loudness is encoded as heat" (`app-ncmpcpp.md` §2.2). lazygit hashes each author's name to a stable HSL for the commit graph (`app-lazygit.md` §4). Nushell allows *closure-valued* color (a 4GB file is visibly a different color from a 12KB file, `lib-nushell…md` §3.1).
- **What it evokes.** "The machine glows with its own workload"; instrumentation that runs a fever; the data is alive.
- **Who uses it.** btop (the reference), ncmpcpp, lazygit, Nushell closures, pterm heatmap.
- **Failure mode.** Requires truecolor to look smooth; bands into ugliness at 16-color. btop *degrades* gracefully (256→16 with a dedicated TTY theme) rather than assuming truecolor.

### 1.4 The neutral that is secretly tinted — mood in the shadows
- **What it is.** Make the "neutral" grays and near-blacks carry a hue bias so even the empty chrome glows. Crush's Pepper `#201F26` and its whole neutral ramp are plum-shifted (B ≥ R) — "the synthwave is in the shadows, not just the highlights… what makes Crush read as *a mood* rather than *a color scheme applied to a gray app*" (`app-charm-crush.md` §2). Posting's ground is indigo-tinted black, never `#000000` — "a pure-black background reads as 'terminal/void,' a tinted one reads as 'designed surface'" (`app-posting.md` §1; gap-layout §9).
- **What it evokes.** Ambient atmosphere; "designed surface" over "raw void"; premium nocturnal cohesion at zero information cost.
- **Who uses it.** Crush (purple-neutrals), Posting (indigo-black), superfile (`#1e1e2e` not pure black), Grok Build (graphite `#141414`).
- **Failure mode.** Over-tinting the neutrals fights the accent; keep the bias imperceptible-as-color but perceptible-as-warmth.

### 1.5 The period palette — quotation as identity
- **What it is.** Deliberately restrict to the 16 ANSI colors — or to CRT-phosphor primaries — to *quote* an era. mc's canonical face is built from four colors, and "the blue is `color4` — pure IBM CGA/EGA/VGA background blue… not a decorative choice; it is a *quotation*" (`app-midnight-commander-mc.md` §2). aider's dark palette (`#32FF32` green, `#00FFFF` cyan) is "CRT-terminal phosphor… the machine's native palette, not our design system" (`app-aider.md` §2.2). The cyber/CRT lineage (green/amber phosphor) is documented in `gap-terminal-emulator-substrate…md` §4.
- **What it evokes.** Retro-engineering honesty, sysadmin nostalgia, "this already worked in 1994," phosphor warmth.
- **Who uses it.** mc (DOS blue), aider (phosphor dark mode), the ricing/cassette-futurism subculture.
- **Failure mode.** Reads as *dated* rather than *heritage* unless the whole system commits (mc's stasis is deliberate); half-committing looks like neglect.

### 1.6 Reserved red / color scarcity — "the alarm works because the room is silent"
- **What it is.** Withhold a color entirely from the resting UI so its appearance is genuinely startling. mc reserves red *exclusively* for errors — "a red box tearing open across the blue is genuinely startling… the fire alarm works *because* the building is normally silent" (`app-midnight-commander-mc.md` §2). k9s inverts the intuition (red=up, green=down) because rising resource use is *bad* (`app-k9s.md` §3).
- **What it evokes.** Calm during normal operation; unmissable alarm when it breaks; the palette has emotional grammar.
- **Who uses it.** mc, k9s, Textual/Charm semantic error roles.
- **Failure mode.** Softening the alarm color for aesthetics (Claude Code deliberately uses *coral* not red, `app-claude-code.md` §2 — a valid *low-anxiety* choice) trades startle for calm; know which register you want.

### 1.7 Generated semantic-token systems — the design-system replacement
- **What it is.** Define ~9–11 *role* colors and machine-generate the rest (light/dark shades, muted variants, contrast-safe text). Textual's 11-color model generates 3 light + 3 dark shades per seed and a contrast-aware `$text` that "auto-flips black or white depending on which has better contrast," engineering muted-bg + matching text as a legible pair (`lib-textual-rich…md` §2–4). brick's `AttrMap` resolves hierarchical role names (`list <> selected`) through CSS-like inheritance so "visual drift becomes structurally impossible" (`lib-brick…md` §1,3). Zellij themes by *semantic slot* (`ribbon_selected`, `frame_selected`, `exit_code_error`) not ANSI index, so "one file reskins the entire multiplexer coherently" (`app-zellij.md` §6). k9s YAML anchor-palettes + Oklch inversion for perceptually-balanced light/dark (`app-k9s.md` §8).
- **What it evokes.** "Designed by a system, not by hand"; coherence you can't point at because nothing was chosen independently.
- **Who uses it.** Textual (the reference), brick, Zellij, Nushell, pterm's central `Theme` struct, k9s skins.
- **Failure mode.** None aesthetic; the *risk* is homogeneity — you can spot a Textual app "the way you can spot a Bootstrap website" (`lib-textual-rich…md` §12). Identity then has to come from the *accent choice* and content.

### 1.8 Graceful degradation as taste — the fallback ladder
- **What it is.** Design truecolor-first and *step down* automatically (truecolor → 256 → 16 → mono), treating the degradation as tailoring rather than compromise. Charm's `AdaptiveColor`/`CompleteColor` "auto-downsamples… sold not as compat glue but as *tailoring*" (`lib-charm…md` §2). Gemini's explicit ladder: truecolor gradient → stepped → 2-tone ANSI → single accent → monochrome, "engineered to *fade gracefully, not shatter*" (`app-gemini-cli.md` §7). Grok *hides* its truecolor themes on non-truecolor terminals because "they lose their character when quantized" (`app-xai-grok…md` §1.3). pterm defines beauty "at the ANSI-16 floor, treats TrueColor as garnish" so it never betrays you in a CI log (`lib-pterm…md` §2).
- **What it evokes.** "This app noticed my setup and dressed for it"; engineering honesty; beauty that survives the worst terminal reads as *engineered*, not merely decorated.
- **Who uses it.** Charm, Gemini, Grok, pterm, notcurses (the whole blitter/degrade ethos), btop.
- **Failure mode.** Committing so hard to truecolor that the app *breaks* on a 16-color TTY (Posting deliberately refuses ANSI fallback, `app-posting.md` §14 — a valid but exclusionary bet).

### 1.9 ANSI-16 remap — total art direction
- **What it is.** Recolor even *foreign* output (shell commands, `git`, compilers) through your palette so nothing escapes the mood. Crush builds a full `[16]color` map and renders bang-mode shell output through it — "even *external tool output* gets recolored into the Crush palette… the app refuses to let raw terminal colors break the mood" (`app-charm-crush.md` §8).
- **What it evokes.** Absolute cohesion; the most aggressive possible expression of identity.
- **Who uses it.** Crush (the extreme case).
- **Failure mode.** Overrides the user's carefully-riced colors; reads as hostile to power users who *chose* their scheme.

---

# DEVICE FAMILY 2 — BORDER & BOX-DRAWING SEMANTICS
### (replaces: corner-radius, drop-shadow, card chrome, elevation, window frame)

Box-drawing is the terminal's structural language, and the corpus is unanimous that **the border does the work drop-shadow, corner-radius, and elevation do on the web.** ratatui: "the frame IS the design language" (`gap-layout…md` §4a). The choice is loud because on a flat grid the frame is the *only* chrome available.

### 2.1 The corner/weight mood dial — the single loudest one-glyph decision
- **What it is.** The same box swapped between glyph sets is an entire mood axis. lazygit ships five and the dossier maps each: single-light `┌─┐` = "precise, engineered, unfussy"; rounded `╭─╮` = "soft/friendly, `border-radius: 6px`"; double `╔═╗` = "retro/BBS/DOS-nostalgic"; bold `┏━┓` = "assertive, chunky, institutional"; hidden = "weightless" — "one config key moves the whole app across a mood axis from brutalist to soft to weightless" (`app-lazygit.md` §3; `gap-layout…md` §4c).
- **What it evokes.** **Rounded** is the near-universal *deliberate* modern choice — "the terminal's cheapest signifier of consumer software, not sysadmin tool." Claude Code uses `borderStyle:"round"` ×31 vs `"single"` ×3 (`app-claude-code.md` §3); Charm/Crush/superfile/Posting/pterm/Zellij all default rounded. **Sharp** reads engineered/CAD; **heavy** reads brutalist; **double** reads DOS-authority.
- **Who uses it.** Rounded: the entire modern cohort. Double: mc's DOS-authentic `double-lines.ini`, Nushell's `double` mode. btop toggles rounded↔sharp as "the app's biggest tonal dial" (`app-btop.md` §3.1).
- **Failure mode.** Rounded glyphs (`╭`) may not exist in console fonts — btop forces sharp corners in TTY mode; always have an ASCII/sharp fallback (lazygit remaps `┌→+`, `│→\|`).

### 2.2 Border color as focus / mode / state — the frame as status light
- **What it is.** Color the border to signal which region is live and what mode you're in, *without motion*. lazygit's active pane gets green-bold, everything else the terminal default — "the entire 'where am I' signal is a single foreground color on box-drawing characters," and it swaps to cyan-bold the instant you search — "a mode you can *see*" (`app-lazygit.md` §1). k9s recolors the whole ASCII wordmark red on error — "the branding is wired into the nervous system… you feel scolded by the logo" (`app-k9s.md` §4). Zellij: unfocused frame = gray 238, focused = accent green; "focus becomes a *warm glow*… color-as-attention" (`app-zellij.md` §3). ncmpcpp flips the focused panel's border to red (`app-ncmpcpp.md` §2.1). lazygit's *mode recoloring* (cherry-pick=cyan-bg, rebase=yellow-bg) means "the UI has weather" (`app-lazygit.md` §4).
- **What it evokes.** Ambient mode-awareness; attention directed without a blink; "the frame is a status rail."
- **Who uses it.** lazygit (green active), k9s (wordmark-as-alarm), Zellij, ncmpcpp, superfile (per-region accent hues).
- **Failure mode.** If unfocused ≈ focused, focus is invisible; the gray-vs-accent gap must be large.

### 2.3 Titles inlaid into the border — window-chrome mimicry
- **What it is.** Draw the panel's label *into* the top rule (`╭─┤ path ├──╮`) and info into the bottom rule. brick's `borderWithLabel` places the label *on* the `─` run — "captioned, filed, official… like a labeled drawer" (`lib-brick…md` §2). superfile inlays title in the top and file-count in the bottom — "the whitespace inside the panel is never spent on labels" (`app-superfile.md` §1). btop insets titles as bracketed engraved labels with superscript nav numbers — "each box is a labeled equipment bay with a stamped part number" (`app-btop.md` §3.1). k9s rides the item count in the border (`Pods(default)[12]`, `app-k9s.md` §7).
- **What it evokes.** A GUI title-bar transplanted to cells; the interior stays clean; "the border earns its cells."
- **Who uses it.** brick, superfile, btop, k9s, Zellij (pane title = command, corner color = exit code).
- **Failure mode.** Long titles must truncate or the frame breaks; brick truncates to child width.

### 2.4 Border fusion — "drafted, not stacked"
- **What it is.** Where two panels meet, merge their edges into tees/crosses (`┬ ┼ ┤`) instead of doubling the lines. brick's `joinBorders` welds edges — "the UI looks like one fabricated chassis rather than overlapping paper rectangles" (`lib-brick…md` §2,5). ratatui's `merge_borders` (`gap-layout…md` §4a).
- **What it evokes.** Engineered solidity; a milled instrument vs a pile of boxes.
- **Who uses it.** brick, ratatui, mc's two-tier line grammar (double outer wall + single inner rules = hierarchy from stroke weight, `app-midnight-commander-mc.md` §3).
- **Failure mode.** A visible *gap* where borders meet reads as broken; the guide calls it the oddity to avoid.

### 2.5 The left-rail / thick bar — selection & authorship without a box
- **What it is.** A single thick vertical rail (`┃`/`▌`) that lights up on focus, replacing a full border. Crush uses a `Border{Left:"▌"}` rail that thickens and colors on focus (violet=user, mint=assistant) — "selection is signaled by a rail *thickening and lighting up*, tactile and quiet" (`app-charm-crush.md` §6). Grok Build's heavy `┃` is the "authorship rail" carrying each block's identity color — magenta agent / gray user (`app-xai-grok…md` §2.1). Posting drops the box entirely for a `border-left: wide $accent` — "the 'active line' marker of a code editor… it says *editor*, and it costs one column" (`app-posting.md` §4).
- **What it evokes.** Tactile, quiet, editor-native; authorship legible as a colored ribbon down the margin.
- **Who uses it.** Crush, Grok Build, Posting, mc's selection bar (full-cell cyan inversion).
- **Failure mode.** Too subtle a rail (thin `│`) reads as a divider, not a selection; the thickening is what sells it.

### 2.6 Framed vs chromeless — the ontological fork
- **What it is.** Whether to enclose regions in boxes at all. Framed = "the cockpit" (ratatui's "wall of labeled instrument panels"); chromeless = "the literate stream" (Claude Code's dot-and-hang-indent `⏺`/`⎿` nesting, no panels — "so a 20-step agent run still reads like a document, not a control panel," `app-claude-code.md` §7). yazi uses a single gray hairline `│` between columns, "no boxes… a quiet way of saying 'this is a 2020s app'" (`app-yazi.md` §13). aider refuses chrome entirely, one heavy `h1` box the only box on screen (`app-aider.md` §1,3).
- **What it evokes.** The deepest framing insight (`gap-layout…md` §4b): **"Framed = 'I am a place.' Chromeless = 'I am a voice in your existing place.'"** Chrome converts a *stream* into an *application*.
- **Who uses it.** Framed: k9s, lazygit, ratatui, brick, btop. Chromeless: Claude Code, aider, yazi.
- **Failure mode.** Framing everything in a *streaming* context (a coding agent) makes it read as a control panel you monitor, not a colleague you read; chromeless in a *dashboard* context loses the "every region captioned" reassurance.

### 2.7 Depth without shadow — faking elevation on a flat grid
The GUI's drop-shadow has *five* distinct grid substitutes, and the corpus documents each:
- **Surface-lightness layering.** `$background` (darkest) → `$surface` (a step lighter = the card) → `$panel` — "a widget on `$surface` *appears to float above* the void — pure figure-ground via lightness" (`lib-textual-rich…md` §9). Posting's raised slabs on indigo-black (`app-posting.md` §1).
- **Alpha overlay.** Textual's `$boost` (accumulates on overlap = frosted panes); notcurses' per-cell `NCALPHA_BLEND`/`TRANSPARENT`/`HIGHCONTRAST` planes give genuine drop-shadow panels and translucent modals — "the single most GUI-like quality a TUI can have… comes free" (`lib-notcurses…md` §4).
- **Darkening depth-gradient.** btop fades its process list toward `inactive_fg` down the rows — "the list has a light source; the top is 'in focus/near,' lower rows fall into shadow… btop's answer to the drop-shadow — depth without a shadow layer" (`app-btop.md` §6).
- **Grey-ramp corner-glyph extrusion.** btop's logo uses `╗╔` shading in a descending grey ramp to look "3-D extruded with a shadow falling down-right — a genuine drop-shadow effect built purely from box-corner glyphs" (`app-btop.md` §7.1).
- **Dimming / occlusion.** WezTerm's inactive-pane HSB dimming ("cinematic depth-of-field," `gap-terminal-emulator…md` §3d); lazygit's centered popup over a dim tiled background ("spotlight modality," `app-lazygit.md` §6); Posting's `black 33%` command-palette scrim ("z-depth simulated with a translucent wash," `app-posting.md` §11). Zellij fakes layering with "occlusion + a pin badge, not fake shadows" (`app-zellij.md` §7).
- **What it evokes.** Cards on a table; modals floating; the world receding into focus.
- **Failure mode.** Transparency destroys contrast control — "text legibility now depends on what's behind the window" (`gap-terminal-emulator…md` §3a); keep foreground contrast self-sufficient.

---

# DEVICE FAMILY 3 — WHITESPACE & DENSITY RHYTHM
### (replaces: pixel-perfect spacing, padding/margin, the drop-shadow's air, "luxury")

The gap-layout dossier is the definitive treatment: **"Layout is the first thing you read, before you read anything."** The eye clocks a screen's *silhouette* — packed vs. spacious — in 200 ms, before resolving a word. Whitespace is the terminal's single strongest luxury signal because the medium's default is wall-to-wall text, so *every empty cell is a choice*.

### 3.1 Padding as the drop-shadow — "whitespace is the terminal's drop-shadow"
- **What it is.** A ring of blank cells inside a container. The canonical unit is the **1-cell ring**: `│ text │` vs cramped `│text│` — "cramped reads as a system utility; one cell of breathing room reads as confident, un-cramped" (Charm, `lib-charm…md` §3; `gap-layout…md` §3). Posting's exact spec — header `1 3`, body `0 2`, modals `1 2` — "**the padding numbers ARE the composition**," and "deliberate padding is the single strongest 'this is an application' signal… A script prints flush-left to column 0; an app insets its content" (`app-posting.md` §5; `gap-layout…md` §3).
- **What it evokes.** Product-grade poise; "I am not in a hurry, I have room for you" (superfile, `app-superfile.md` §3).
- **Who uses it.** Posting, Charm/Lip Gloss (`Padding(0,1)`), superfile, pterm, Claude Code.
- **Failure mode.** Uneven padding across containers reads as a grab-bag; *identical* padding everywhere "sells it as one designed system" (superfile).

### 3.2 The density↔airiness master dial
- **What it is.** The governing axis. **Dense pole** (k9s, btop, ncmpcpp): full-bleed to the edges, one record per line, columns separated by a single space — "information wants to be dense… competence under pressure" (`gap-layout…md` §2a). **Airy pole** (Claude Code, Posting, superfile): generous margins, blank lines between units, single-column measure — "hospitality and confidence… you don't have to fill the whole screen" (`gap-layout…md` §2b).
- **What it evokes.** Dense = industrial/instrument-panel/urgent; airy = calm/warm/expensive-minimal.
- **Failure mode.** Density with *no* salience hierarchy reads as noise; the dense masters rescue legibility with **another** channel — color-temperature, depth-fade, or alignment (`gap-layout…md` §7): "if you spend the whitespace budget on information, you must pay the legibility debt in another currency."

### 3.3 Density as a dial, not a fixed choice — self-aware design
- **What it is.** Offering *both* densities as an explicit toggle. Posting's `--compact` (border:none, padding:0), Grok's compact mode, yazi's per-row line-modes — "density is a dial… the user chooses between airy and information-dense" (`gap-layout…md` §2c).
- **What it evokes.** "This app has a designer who thought about whitespace as a value."
- **Who uses it.** Posting, Grok Build, yazi, Zellij (compact-bar).

### 3.4 Alignment / tabulation — "the cheapest luxury signal"
- **What it is.** Right-align numerics against left-aligned strings; pad labels to equal width. pterm pads every badge to exactly 7 chars "so all messages line up… alignment is the cheapest luxury signal on a character grid" (source comment, `lib-pterm…md` §4). Nushell right-aligns filesize/number columns — "columns of numbers line up on their ones-digit like a ledger; accounting-grade, precise, trustworthy" (`lib-nushell…md` §7). ncmpcpp's `$R` right-alignment is its *only* whitespace rhythm.
- **What it evokes.** Engineered rigor; "someone cared." Ragged flush-left = "reading matter, not data" (deliberate for prose, per Claude Code).
- **Who uses it.** pterm (equal-width badges), Nushell, ncmpcpp, k9s (right-aligned deltas).
- **Failure mode.** Justifying *prose* makes it read as data; tabulate numbers, keep prose ragged — "the switch between tabulated and ragged *is* the switch between 'here is data' and 'here is a voice'" (`gap-layout…md` §10 recommendation 5).

### 3.5 Centered vs left-anchored — ceremony vs work
- **What it is.** Horizontal placement as register. Centered = "ceremony, arrival, landing-page, a stage" — reserved for identity moments (Gemini's `GEMINI` banner, pterm's centered wordmark, ncmpcpp's now-playing hero). Left-anchored = "terminal-native, working, in the medium's idiom" (`gap-layout…md` §8). "The tasteful apps center exactly once (the splash) and left-anchor everything after."
- **Failure mode.** Constant centering of *working* content reads as brochure; never centering anything reads as raw script.

### 3.6 Textured / tinted negative space — "emptiness is designed, not broken"
- **What it is.** Fill voids with a faint repeating texture or a tinted ground so nothing reads as "not loaded." Posting fills empty regions with a diagonal `hatch` — "it turns 'nothing here' from a bug-like gap into a *designed surface*… blueprint crosshatch" (`app-posting.md` §6). Textual's `hatch` "material grain" (`lib-textual-rich…md` §9). Lip Gloss's `MarginChar('░')` (`lib-charm…md` §3).
- **What it evokes.** Luxury, intention, a drafting-table precision.
- **Who uses it.** Posting, Textual, Charm.
- **Failure mode.** Heavy texture competes with content; keep it low-opacity.

---

# DEVICE FAMILY 4 — GLYPH & SYMBOL LANGUAGE
### (replaces: icons, illustration, logos, texture, imagery)

With no pixels (by default), meaning-as-picture is carried by glyph *choice*. The corpus shows a spectrum from a single austere asterisk to real embedded photographs.

### 4.1 The block-glyph "material kit" — one coherent set of parts
- **What it is.** Restrict decorative glyphs to a small block family (`█ ░ ▓ ▁▂▃▄▅▆▇ ▌▐`) reused across spinner, bar, and fill so everything looks made of one material. aider uses only `█`/`░` across scanner tail, progress bar fill, and empty — "one designer, one palette of parts" (`app-aider.md` §5.3). pterm's `█`-on-`░` progress bar (`lib-pterm…md` §7).
- **What it evokes.** Industrial cohesion; a tiny obsessive glyph kit reads as craft.
- **Who uses it.** aider, pterm, ncmpcpp (`=>` progress, `●`/`▮` visualizer).
- **Failure mode.** Mixing glyph families (block + emoji + Nerd-Font) fragments the "one material" read.

### 4.2 Sub-cell density — braille & the blitter ladder
- **What it is.** Pack multiple data points below the cell resolution. A braille cell is a 2×4 dot matrix = 2 samples × 4 sub-rows, giving "8× the vertical resolution… analog instrument fidelity inside a character grid" (btop, `app-btop.md` §4.1). notcurses formalizes a whole **ladder** — 1×1 → half-blocks → quadrants → sextants(U13) → octants(U16) → braille → true pixels — "choosing a blitter is choosing a point on a continuum from retro ASCII art to photograph… pick a *mood*, not fight the grid" (`lib-notcurses…md` §2). ncmpcpp's 8-level partial-block ramp `▁▂▃▄▅▆▇█` for smooth spectrum bars (`app-ncmpcpp.md` §4.2).
- **What it evokes.** Braille = oscilloscope/engineering-readout; half/quadrant = "chunky videogame pixel"; sextant/octant = "downsampled photo, a modern terminal."
- **Who uses it.** btop (braille waveforms), ncmpcpp (spectrum), notcurses (the reference), aider's block progress.
- **Failure mode.** Braille needs a font with the glyphs; degrade to block/tty tiers (btop's three symbol tiers = "modern scope → retro game → mainframe").

### 4.3 The single-glyph mascot & the wordmark logo
- **What it is.** Identity carried by *one* recurring character, or a hand-built block-letter wordmark. Claude Code's mascot "is not a picture — it's one character: `✻`… the asterisk *is* the logo" (`app-claude-code.md` §4). Contrast the **block-letter wordmark** tradition: Gemini's filled shade-ramp `GEMINI` (`app-gemini-cli.md` §1), Crush's half-block `▄▀█` marquee letters with a random per-launch letter-stretch (`app-charm-crush.md` §4), k9s's slant-block ASCII `K9s` (`app-k9s.md` §2b), pterm's `█`-block BigText, Grok's braille-art logo with a shine sweep (`app-xai-grok…md` §4.3), btop's gradient-filled extruded `BTOP` (`app-btop.md` §7.1).
- **What it evokes.** Single glyph = lightweight, literate, "a friendly signature doodle." Block wordmark = "the app has arrived, here is its NAME"; substantial, branded, demoscene-splash heritage.
- **Who uses it.** Single-glyph: Claude Code (`✻`), Charm (mascots). Wordmark: Gemini, Crush, k9s, btop, pterm, Grok.
- **Failure mode.** A wordmark sprayed everywhere is kitsch — "deployed once at startup it's a confident brand stamp; sprayed everywhere it would be kitsch" (pterm, `lib-pterm…md` §6).

### 4.4 Nerd-Font / emoji iconography vs the austere refusal
- **What it is.** Whether to use pictographic glyphs at all. **Rich-iconography pole:** superfile's per-filetype *colored* Nerd-Font glyphs (`app-superfile.md` §3), yazi's Material-hex icons + open-folder-on-hover (`app-yazi.md` §4), k9s's emoji `🐶 🐩 😎 😗 😡` (`app-k9s.md` §10). **Austere refusal:** aider has "no Nerd Font icons, no emoji… identity via *color role*, not glyph… icons would be chrome" (`app-aider.md` §6); mc "predates and pointedly ignores the Nerd Font era… the absence of icons *is* the statement" (`app-midnight-commander-mc.md` §6); brick's FAQ recommends *avoiding* wide characters, giving "a sober box-drawing texture over playful emoji" (`lib-brick…md` §8).
- **What it evokes.** Icons = warm, modern-app, approachable. Refusal = serious, text-mode purist, "close to the metal."
- **Who uses it.** Icons: superfile, yazi, k9s, lazygit (opt-in). Refusal: aider, mc, brick.
- **Failure mode.** Icons are progressive richness — ship them *off* by default (lazygit) so bare installs look clean; forced icons tofu on terminals without the font.

### 4.5 Geometric glyph kits & the angle-bracket convention
- **What it is.** A small vocabulary of geometric marks as a semantic alphabet. Crush's diamond motif `◇◆` = model identity, `●✓×` = tool states (`app-charm-crush.md` §6). Grok's documented legend — `◉◎` record-light, `◆◇◈` status diamonds, `○◎◉◎` breathing monitor, `▸▾` disclosure, `✓✗` resolution (`app-xai-grok…md` §2.2). The **`<token>` angle-bracket convention**: k9s wraps keys/crumbs (`<pods>`, `<d>`) — "you learn that `<…>` means interactive/navigable" (`app-k9s.md` §10); Zellij's `<key>` tiles; brick.
- **What it evokes.** A consistent typographic dialect the user learns in seconds; instrument-panel precision.
- **Who uses it.** Crush, Grok Build, k9s, Zellij.
- **Failure mode.** Undocumented glyph kits read as arbitrary; consistency is what makes them legible.

### 4.6 Graphics-protocol pixels — escape velocity
- **What it is.** Blit real raster images into the cell grid (Kitty/iTerm2/Sixel). yazi treats the terminal "as a framebuffer that happens to also hold text" — real photo/video/PDF previews, "GUI broke into terminal" (`app-yazi.md` §2). The moment a TUI shows a real image "it crosses a line from *tool to app*… escape velocity" (`gap-terminal-emulator…md` §5). notcurses' `NCBLIT_PIXEL` (`lib-notcurses…md` §3).
- **What it evokes.** Transgressive delight; "this doesn't feel like a terminal anymore."
- **Who uses it.** yazi (the reference), notcurses, chafa/timg.
- **Failure mode.** Protocol support is "wildly non-uniform and often un-detectable" — pixels are "a progressive enhancement, never a floor" (`gap-terminal-emulator…md` §5c). Degrade down the ladder: kitty → sixel → half-block → ASCII.

---

# DEVICE FAMILY 5 — MOTION TIMING
### (replaces: animation curves, transitions, hover, gloss/specular, "aliveness")

Motion via redraw is the terminal's only self-generated dynamic channel, and because an agent user "spends *most of every turn* staring at a 'working…' indicator, the waiting state is not chrome — it is the app's face at rest" (`gap-thinking…md` §0). The governing law: **"same wait, different feeling"** (Charm) — the wait is identical; the motion is the entire message.

### 5.1 Spinner glyph × interval = timbre × tempo
- **What it is.** The frame-set is the timbre, the interval the tempo. Braille `dots ⠋⠙⠹` at 80 ms = "smooth, refined, quietly premium… the serious-but-designed default"; ASCII `line - \ | /` at 130 ms = "utilitarian, mechanical, sober"; `moon`/`earth`/`clock` emoji = "whimsical, cute, toy-like"; `material` 92 frames at 17 ms = "hyper-smooth, showy real-animation-engine" (`gap-thinking…md` §2). **Interval is the emotional register:** ≤50 ms = "urgent/anxious," ~80 ms = "brisk-but-calm sweet spot," ≥250 ms = "motion becomes a resting pulse, not a spin" (`gap-thinking…md` §2.1).
- **Who uses it.** aider's bounce-scanner (bright-head/dim-tail = "diagnostic, searching" not generic spin, `app-aider.md` §5.1), Claude Code's *blooming* asterisk (`·→✢→✳→∗→✻→✽`, "organic growth, not rotation," `app-claude-code.md` §5), Charm/pterm/bubbles catalog.
- **Failure mode.** "An undifferentiated default `ora` import… says nothing, in the one place the user looks the longest" (`gap-thinking…md` §12).

### 5.2 The whimsical gerund — voice-in-motion (the coding-agent signature)
- **What it is.** A present-participle verb cycling beside the spinner. Claude Code ships 187 gerunds (`Cogitating…`, `Percolating…`, `Flibbertigibbeting…`) — "with no font, no illustration, no sound, the agent carries its entire personality in *word choice at the moment of waiting*… latency reframed from a system delay into a character beat" (`app-claude-code.md` §6; `gap-thinking…md` §3).
- **What it evokes.** Warmth, wit, a mind at work; "Loading… says a process is running; Percolating… says a personality is thinking."
- **Who uses it.** Claude Code (whimsical), Grok Build (sober key: `Thinking…`, `Verifying…`, `Waiting on subagent…`).
- **Failure mode.** Polarizing — bug #23430 calls them "unprofessional"; Anthropic made them *customizable, not removable*. **Ship the opt-out up front.**

### 5.3 The instrumentation cluster — honest-machine motion
- **What it is.** Live-ticking elapsed/token/cost meters. Claude Code's `(12s · ↑ 2.3k tokens · esc to interrupt)`, aider's taxi-meter `$0.0042 1,234 tokens total`, Grok's fixed-width `1m20s ⇣12k` — "a rising number is proof the process is alive and proof of respect for your time" (`gap-thinking…md` §4; `app-aider.md` §7). Fixed-width numerics so the gauge "never jitters its width."
- **What it evokes.** Transparency, mission-control, engineering honesty. Pairs with §5.2: "the verb makes you smile while the numbers make you trust."
- **Failure mode.** None; the two poles (whimsy + instrumentation) are strongest worn *at once* (Claude Code).

### 5.4 Streaming reveal cadence — the rhythm of a thought appearing
- **What it is.** How generated text materializes. Char-by-char (teletype) = "alive, intimate, a thought forming"; word-chunked = "natural, ChatGPT-native"; line-buffered = "composed, editorial"; instant-paste = "cold, machine, transactional — the single fastest way to make an agent feel like a tool" (`gap-thinking…md` §5). The craft move is **buffer-then-flush** on a ~0.1 s timer — "smoothness of cadence, not speed, reads as composure." **Stream-then-freeze:** live shimmer → static rendered prose = "the page settles" (Claude Code, aider both do this; `app-claude-code.md` §5, `app-aider.md` §5.2).
- **Who uses it.** Claude Code, aider (live-window over stable scrollback), Gemini (Ink reflow), Grok (ghost-free, test-enforced).
- **Failure mode.** Tearing/ghosting/viewport-jump "read as cheapness"; enforce atomic redraw with PTY tests (Grok's `wheel_flood_paints_no_ghost_frames`).

### 5.5 Breathing / pulse / shimmer — the calm-aliveness register
- **What it is.** A slow dim→bright loop or spatial brightness wave. Grok's `pulse_brightness = sin²(tick·speed)` — "a smooth always-positive raised curve — the light never fully dies, it *breathes*… the difference between 'alive/idling' and 'blinking/alarm'"; `wave_brightness` ripples down rows "so a running block shimmers top-to-bottom" (`app-xai-grok…md` §4.1; `gap-thinking…md` §7). Claude Code's `alt-stars` palindrome `·…✽…·` = "breathing, a slow inhale/exhale" (`app-claude-code.md` §5).
- **What it evokes.** Serene, alive, the lowest-anxiety "I'm working" signal; the terminal's answer to the web shimmer.
- **Failure mode.** A flat single pulse reads mechanical; the *phase gradient* (wave) is what reads organic.

### 5.6 Two-cadence tempo-as-state
- **What it is.** Encode state in *speed*. Grok runs the active turn spinner at ~7.5 fps (busy braille whirl) and the idle monitor pulse at ~3.75 fps (`○◎◉◎`) — "foreground urgency vs background calm, encoded in glyph density… tempo means state" (`app-xai-grok…md` §4.2; `gap-thinking…md` §7).
- **What it evokes.** A motion *grammar*; "fast = acting now, slow = watching, ready" — learned in seconds.
- **Who uses it.** Grok Build (the reference).

### 5.7 The gloss substitute — the metallic shine sweep
- **What it is.** A raised-cosine highlight band sweeping across a logo — the closest a TUI gets to a specular gloss. Grok's startup logo: shine sweeps bottom-left→top-right, `SWEEP_FRAC=0.32` (~1.3 s glint then rest), each glyph blended toward `text_primary` — "the closest a TUI gets to a 'glossy button'… light raking across a machined surface" (`app-xai-grok…md` §4.3; `gap-thinking…md` §7). Crush's per-grapheme Hcl gradient = "iridescent, airbrushed, luxe" (`app-charm-crush.md` §3).
- **What it evokes.** Glossy, premium, specular brand-polish.
- **Failure mode.** On a status word it reads as luxury-overkill; reserve for the boot logo.

### 5.8 Stillness / snap — motion absence as a statement
- **What it is.** Deliberately *not* animating. Posting sets `animation: none` — "snappiness as an aesthetic… in a TUI, easing reads as lag; instantaneous redraw reads as native, fast, keyboard-speed. The stillness is the polish" (`app-posting.md` §10). mc's motion is "deliberately, ideologically still… stillness reads as reliability" (`app-midnight-commander-mc.md` §5). yazi's async instant-swap: "weightlessness… a spinner is an apology for waiting" (`app-yazi.md` §8). The austere spinner-absence pole: "a static 'Thinking' word says I don't need to reassure you with a dancing glyph" (`gap-thinking…md` §8).
- **What it evokes.** Sober, confident, fast; senior/severe.
- **Failure mode.** Silence *fails the background-completion use case* — a muted still app can't tell you it's done when your eyes are elsewhere; pair with §5.9/sound.

### 5.9 Ephemeral motion, permanent text
- **What it is.** Redraw the spinner in place (`\r`, width-matched frames so layout never shifts) and erase it cleanly on completion. aider's scanner "erases itself without a trace; the transcript stays clean… restraint reads as polish" (`app-aider.md` §5.1; `gap-thinking…md` §8).
- **What it evokes.** Courtesy, not monument; the motion was a service during the wait.

---

# DEVICE FAMILY 6 — CASING & TYPOGRAPHY SUBSTITUTES
### (replaces: font choice, font-weight, size, italic, letterforms)

There is one monospace face and no size control, so **meaning that a GUI carries in typography is carried by four SGR channels — bold, dim, italic, reverse — plus casing and color-as-weight.** (Ligatures and raster sharpness belong to the substrate, §0.)

### 6.1 The four-channel type system
- **What it is.** A strict code where each channel means exactly one thing. Claude Code: "**Bold** = structural importance; **Dim** = supporting/ignorable; **Italic** = Claude's private introspective voice (`✻ Thinking…` is grey *and* italic); **Color** = a role system, never decoration — a strict four-channel typographic code… the restraint is the sophistication" (`app-claude-code.md` §8). btop: "bold=structure, italic=signature, dim=depth, superscript=gauge-markings — a full type hierarchy from four text attributes" (`app-btop.md` §5). k9s's clean two-weight hierarchy (bold=control/label, plain=data).
- **What it evokes.** Legible literacy; "you learn in thirty seconds that grey-italic is thinking, orange is identity."
- **Failure mode.** Overloading a channel (bold for three different meanings) destroys the code; assign one meaning per channel.

### 6.2 Reverse-video as "bold" / highlight / button
- **What it is.** Swap fg/bg to make a solid block. aider implements "bold" as *reverse video* — "a hard, blocky highlight… more emphatic and more terminal-idiomatic than font-weight bold — the machine stamping this" (`app-aider.md` §6). mc's selection bar is full-cell cyan inversion; ncmpcpp's cursor/selection/clock digits are all reverse-video fills — "reverse is ncmpcpp's answer to a colored button" (`app-ncmpcpp.md` §6). yazi's reversed-video hover row = "native OS list-selection, not a text caret" (`app-yazi.md` §5). pterm's solid-background badges (black-on-cyan) = "a paint chip glued to the left margin, reads as UI not log text" (`lib-pterm…md` §4).
- **What it evokes.** A physical highlighter bar; a tactile selection; a candy-colored button.
- **Who uses it.** aider, mc, ncmpcpp, yazi, pterm, k9s (cursor row inversion).
- **Failure mode.** Reverse-video en masse is garish; reserve for the *one* selected/stamped thing.

### 6.3 Dim as opacity — the three-tier text ramp
- **What it is.** Dim is the terminal's only "opacity"; a three-step text ramp = the GUI's typographic hierarchy. Textual's `$text` → `$text-muted` → `$text-disabled` is "the single most recognizable Textual signature… your eye is led down a gradient of importance… information triage done for you" (`lib-textual-rich…md` §4). ncmpcpp's `:b` suffix "as a second brightness channel" doubles an 8-color palette to ~16 tones (`app-ncmpcpp.md` §2.1). lazygit's inactive-pane selection drops to bold-only, no bg — "attention has a gradient" (`app-lazygit.md` §5).
- **What it evokes.** Calm hierarchy; the screen tells you what matters before you read a word.
- **Who uses it.** Textual, Claude Code (`secondaryText` grey for meta), ncmpcpp, lazygit.

### 6.4 Casing as voice
- **What it is.** Case choice carries register. **lowercase** = humble/unix-tool/soft — aider's `aider`, superfile's mandated lowercase wordmark ("stripe/figma/npm convention," `app-superfile.md` §5), Grok's `grok-3 · yolo` lowercase-technical, k9s's forced-lowercase breadcrumbs ("shell-native, unpretentious"). **UPPERCASE** = labels/system-state — Zellij's `PANE`/`RESIZE`/`-- INTERFACE LOCKED --` ("caps read as system-state, instrument-panel authority," `app-zellij.md` §8), pterm's badge labels, yazi's `NOR`/`SEL` mode badge. **Title Case** = menu/heading (mc's `File`/`Command`).
- **What it evokes.** lowercase = approachable/humble; UPPERCASE = authoritative/system; the case is a tone knob.
- **Failure mode.** Inconsistent casing reads as sloppy; pick a convention per element class.

### 6.5 Color-as-weight
- **What it is.** Where there's no bold guarantee, use color for emphasis. mc: "the yellow hotkey letter, the white directory name, the bright-green executable — each is a 'font weight' expressed chromatically" (`app-midnight-commander-mc.md` §6).
- **Who uses it.** mc, and every 16-color-era tool.

---

# DEVICE FAMILY 7 — VOICE & COPYWRITING AS FACIAL EXPRESSION
### (replaces: personality, microcopy, brand voice, mascot facial expression)

With no face to emote and no illustration, **words carry the personality a GUI carries in its mascot's expression and its microcopy.** The corpus shows a clean spectrum from terse-imperative to affectionate-whimsical, and voice is where identity is *least* fakeable.

### 7.1 The register spectrum: terse-imperative ↔ affectionate-whimsical
- **Terse-imperative pole.** mc's 1990s-Unix flatness — `Delete`, `Mkdir`, `File exists. Overwrite?` — "a competent colleague who doesn't waste your time — the anti-mascot… mc has no cheerful voice *because* the era it quotes had no cheerful voice" (`app-midnight-commander-mc.md` §7). aider's spec-sheet boot banner ("like a BIOS POST," `app-aider.md` §7). ncmpcpp's deadpan `errno` strings — "dignity through minimalism" (`app-ncmpcpp.md` §7).
- **Affectionate-whimsical pole.** superfile's "**Thanks for using superfile!!**" with two exclamation marks and `<3` in every theme file — "a host welcoming a guest, not a man page… endearing imperfect English as personality" (`app-superfile.md` §6). Crush's "your new coding bestie," British-spelled *glamourous* as costume (`app-charm-crush.md` §10). Claude Code's 187 whimsical gerunds.
- **What it evokes.** Terse = serious instrument; whimsical = delightful companion. "Where an agent sits between them is most legible in the pause" (`gap-thinking…md` §8).
- **Failure mode.** Whimsy is polarizing (bug reports call Claude's verbs "unprofessional") — ship the switch. Terse read as cold to newcomers — pair with self-narration (§7.4).

### 7.2 Emoji / glyph as affect — the tool that emotes
- **What it is.** Give the tool facial expressions via emoji or glyph. k9s's flash bar: `😎` info / `😗` warn / `😡` error — "the tool has *facial expressions*… k9s never says 'Error:' primly; it goes 😡" (`app-k9s.md` §5), plus the 🐶/🐩 mascot in the command cursor ("a Kubernetes power-tool greeting you with a puppy… disarming"). Gemini's summonable `/corgi` `▼(´ᴥ\`)▼` (`app-gemini-cli.md` §6).
- **What it evokes.** Warmth and humor injected into a cold domain; the tool has a mood.
- **Who uses it.** k9s (the reference), Gemini (corgi/snow easter eggs).
- **Failure mode.** Emoji width/tofu issues; k9s allows `NoIcons` for "the buttoned-up crowd."

### 7.3 The taxi-meter — honesty as voice
- **What it is.** State cost/tokens bluntly and continuously. aider's `$0.0042 1,234 tokens total` — "money and tokens stated bluntly; the taxi-meter honesty is part of the trust aesthetic" (`app-aider.md` §7).
- **What it evokes.** Transparency reads as trust; "the tool never hides cost."
- **Who uses it.** aider, Claude Code, Grok token meters.

### 7.4 Self-narrating chrome & visible machinery
- **What it is.** The interface teaches itself and shows its work. Zellij's status bar "rewrites its entire vocabulary on mode switch… a teacher leaning over your shoulder, not a manual on a shelf," reading keys from the *actual* config and labeling absence `UNBOUND` — "honesty as aesthetic" (`app-zellij.md` §4). lazygit's command-log prints "the real git commands it runs… trust through glass walls" (`app-lazygit.md` §7).
- **What it evokes.** Discoverability rendered as beauty; "an interface being discoverable and looking good is the same design move" (Zellij thesis, `app-zellij.md` §1).
- **Who uses it.** Zellij (the reference), lazygit (command-log), Grok (shortcut bar).

### 7.5 Error personality — how the app raises its voice
- **What it is.** The failure state is a designed register, not a raw dump. Options: **soften** (Claude Code delivers errors in *coral* not red, connection drops preserve the partial response — "failure handled like a colleague apologizing," `app-claude-code.md` §9); **shout** (mc's white-on-red modal, k9s's 😡, superfile's `■ ERROR:` red-square bullet with the offending value in cyan — "even the error is *styled*," `app-superfile.md` §6); **deadpan** (ncmpcpp's one-line `strerror`); **standing warning** (mc's root-user skin flips all chrome green→red — "a klaxon you can't ignore… privilege rendered as color," `app-midnight-commander-mc.md` §7). Posting's blinking-red `PRODUCTION` host badge = "personality via *dread management*" (`app-posting.md` §12).
- **What it evokes.** The error's register *is* the app's temperament under stress.
- **Failure mode.** Raw stack-trace dumps break every carefully-built register; even failure should speak the system's color grammar (Posting's `border-left: thick $error`).

### 7.6 Ceremony — welcome, exit, and identity moments
- **What it is.** The framing beats. **Splash/boot:** k9s's ASCII title card ("a half-second of ceremony before the cockpit slams in," `app-k9s.md` §9), Gemini's gradient wordmark, Grok's shine-sweep logo. **Exit voice:** Gemini's "Agent powering down. Goodbye!" ("gentle sci-fi anthropomorphism," `app-gemini-cli.md` §6). **The refusal of ceremony** as its own statement: aider/Posting/ncmpcpp boot straight in with no splash — "the app just *is there*… it opens like an installed application, not a script announcing itself" (`app-posting.md` §12).
- **What it evokes.** Ceremony = arrival/brand; its refusal = tool-like competence, "the tool is ready; start typing" (aider).
- **Failure mode.** Over-produced ceremony on a tool you live in for hours reads as brochure; reserve the loud beat for boot.

---

## Cross-family: how devices compound into one identity

No device works alone; identity is the *coherence* across families. Four worked examples from the corpus:

- **Claude Code = calm literate collaborator.** Chromeless inline stream (2.6) + single terracotta accent (1.2) + blooming asterisk motion (5.1) + whimsical gerunds (5.2/7.1) + coral-not-red errors (7.5) + four-channel type code (6.1) + vertical breathing (3.1). Every family votes "warm, quiet, a person."
- **k9s = friendly guard-dog HUD.** Dense full-bleed tables (3.2) + 8-state lifecycle color (1.1) + wordmark-as-alarm border (2.2) + emoji-affect voice (7.2) + skin culture (1.7). Serious density wrapped around a puppy in the cursor.
- **Grok Build = mission-control cockpit.** Graphite-neutral + one magenta signal, human-as-gray inversion (1.4/1.1) + heavy/thin/rounded border-weight grammar (2.1/2.5) + `sin²` two-cadence motion (5.5/5.6) + shine-sweep gloss (5.7) + CP437 reliability fallbacks. Every family votes "you are operating an autonomous machine."
- **mc = the unbroken thread to 1994.** CGA blue period palette (1.5) + reserved red (1.6) + two-tier line hierarchy (2.1/2.4) + ideological stillness (5.8) + terse-imperative voice (7.1) + no-icons refusal (4.4). Every family votes "stasis as identity."

The lesson for a designer: **pick a register per family and make every family vote the same way.** Incoherence — a whimsical voice under a brutalist frame, or airy padding around anxious dense data — is the one failure that no single beautiful device can rescue.

## The non-visual coda (the channel that reaches past the grid)

One expressive device has no visual grid substitute at all: **sound**. "On a monospace grid, timbre is the one dimension you cannot draw… the only feedback that works when the rectangle isn't being looked at" (`gap-sound…md` §0). The vocabulary: raw `\a` BEL = "jarring, DOS-era, error-coded" (the most-disabled feature); visual-bell / tab color-pulse (Zellij) = "keep the signal, lose the interruption"; a **two-timbre completion language** (Glass = "I finished" / Funk = "I need you") = "emotionally-legible closure"; OSC 9/777 desktop toast = "the terminal talks to the OS, ambient presence"; deliberate **silence** = "sober, monastic, respectful"; watch **haptics** = "embodied, private." The doctrine: one semantic "task complete" event, translated into each surface's *native* quiet idiom, gated on duration + focus — "the agent finishing in a background terminal is a moment of ceremony; give it a chosen, restrained, surface-native voice." Sound is a *theme role* the same way color is.

---

## Master technique → feeling index

| Device | Concrete move | Feeling | Exemplar |
|---|---|---|---|
| Semantic color | hue = role/type, body left `default` | legible, "understands its contents" | aider, lazygit, Nushell |
| Single accent | one hue on inherited bg | brand-as-temperature, a person | Claude Code, lazygit |
| Color-as-data | value → gradient ramp | machine glows with its workload | btop, ncmpcpp |
| Tinted neutral | plum-shifted "grays" | designed surface, ambient mood | Crush, Posting |
| Period palette | 16-color CGA/phosphor | retro-honest, heritage | mc, aider |
| Reserved red | withhold from resting UI | alarm works because room is silent | mc, k9s |
| Semantic tokens | 9–11 roles → generated ramps | "designed by a system" | Textual, brick, Zellij |
| Degrade ladder | truecolor→256→16→mono | tailored, engineered, unbreakable | Charm, Gemini, pterm |
| Rounded corners | `╭╮╰╯` vs `┌┐`/`┏┓`/`╔╗` | soft/modern vs severe/brutalist/DOS | lazygit, Charm, mc |
| Border-color focus | green active / gray idle | attention without a blink | lazygit, Zellij |
| Inlaid title | label in the top rule | window-chrome, clean interior | brick, superfile, btop |
| Border fusion | `┬┼┤` merged edges | drafted not stacked | brick, ratatui |
| Left-rail | thick `┃`/`▌` lights on focus | tactile, quiet, editor-native | Crush, Grok, Posting |
| Framed vs chromeless | box vs whitespace-only | "a place" vs "a voice in your place" | k9s vs Claude Code |
| Surface layering | lighter bg = higher card | elevation from value alone | Textual, Posting |
| Depth-fade | darken down rows | atmospheric depth, a light source | btop |
| 1-cell padding | `│ text │` ring | un-cramped, product-grade | Posting, Charm |
| Density dial | full-bleed vs airy vs toggle | instrument vs hospitality | k9s vs Claude Code |
| Tabulation | right-align numbers, equal-width badges | accounting-grade, "someone cared" | Nushell, pterm |
| Textured void | `hatch` fill, tinted ground | "emptiness is designed" | Posting, Textual |
| Block material kit | reuse `█░` across widgets | one material, craft | aider, pterm |
| Sub-cell braille | 2×4 dots, blitter ladder | analog fidelity / pick-a-mood | btop, notcurses |
| Single-glyph mascot | `✻` recurring | lightweight literate signature | Claude Code |
| Block wordmark | `█`-letter splash | branded, substantial, arrival | Gemini, Crush, k9s |
| Icons vs refusal | Nerd-Font vs none | warm-modern vs text-purist | superfile vs aider/mc |
| Graphics pixels | real image in grid | escape velocity, "not a terminal" | yazi, notcurses |
| Spinner timbre×tempo | glyph-set × interval | premium/mechanical/whimsical; urgent/calm | gap-thinking |
| Whimsical gerund | cycling present-participle verb | latency as personality | Claude Code |
| Instrumentation | live elapsed/token meter | mission-control honesty | aider, Claude Code |
| Stream cadence | teletype/word/line/paste | alive/composed/cold | Claude Code, aider |
| `sin²` breathing | slow dim→bright pulse/wave | serene aliveness, not alarm | Grok Build |
| Tempo-as-state | fast active / slow idle fps | motion grammar | Grok Build |
| Shine sweep | raised-cosine glint on logo | glossy, specular, premium | Grok Build |
| Stillness/snap | `animation: none`, instant swap | fast, native, keyboard-speed | Posting, yazi, mc |
| Ephemeral motion | `\r` erase, clean transcript | courtesy not monument | aider |
| Four-channel type | bold/dim/italic/reverse, 1 meaning each | legible literacy | Claude Code, btop |
| Reverse-video | fg/bg swap = solid block | stamped highlight / button | aider, mc, pterm |
| Dim ramp | `$text`→muted→disabled | information triage, calm | Textual |
| Casing | lowercase / UPPERCASE / Title | humble / system / heading | superfile / Zellij / mc |
| Voice register | terse ↔ whimsical | instrument vs companion | mc vs superfile |
| Emoji-affect | 😎😗😡 in status | the tool emotes | k9s |
| Taxi-meter | blunt cost/token line | transparency = trust | aider |
| Self-narration | mode-reactive hint bar, command-log | discoverability as beauty | Zellij, lazygit |
| Error register | coral / shout / deadpan / standing-red | temperament under stress | Claude Code, mc, superfile |
| Sound role | timbre-pair, OSC toast, silence, haptics | ceremony / calm / embodied | gap-sound |

---

## Sources (this corpus)
Apps: `app-aider.md`, `app-btop.md`, `app-charm-crush.md`, `app-claude-code.md`, `app-gemini-cli.md`, `app-k9s.md`, `app-lazygit.md`, `app-midnight-commander-mc.md`, `app-ncmpcpp.md`, `app-posting.md`, `app-superfile.md`, `app-xai-grok-build-grok-cli-tui.md`, `app-yazi.md`, `app-zellij.md`.
Libraries: `lib-brick-haskell.md`, `lib-charm-ecosystem-lip-gloss-bubbles-bubble-tea-gum-huh-glamour.md`, `lib-notcurses-c.md`, `lib-nushell-table-theming-approach-rust.md`, `lib-pterm-go.md`, `lib-textual-rich-textualize-python.md`.
Cross-cutting gap dossiers: `gap-layout-rhythm-spatial-composition…`, `gap-sound-bell-and-non-visual-feedback…`, `gap-terminal-emulator-substrate-aesthetics…`, `gap-the-agent-is-thinking-waiting-state-aesthetic…`.
