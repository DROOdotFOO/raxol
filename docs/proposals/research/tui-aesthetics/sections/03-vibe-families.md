# 03 · Vibe Families & Lineages

> **What this section is.** A taxonomy of the recurring *aesthetic families* a TUI can belong to — the discrete "directions" a designer picks between before choosing a single color. Each family is a coherent bundle of moves (palette, borders, density, motion, voice) with a shared history, canonical exemplars, a target feeling, and a characteristic failure mode. This is the map you stand in front of and point at.
>
> **How to read it.** Families are not mutually exclusive skins; they are *centers of gravity* on a small number of axes (§0). Most real apps sit primarily in one family and borrow a modifier from another. Section §10 gives cross-family **modifiers** (palette-tribe, border-weight, voice register, substrate) that can be dropped onto any family. Section §11 is a one-screen selection table.
>
> Every claim names the dossier/app/source it comes from. Evidence is drawn from the app dossiers (`app-*.md`), framework dossiers (`lib-*.md`), the cross-cutting gap dossiers (`gap-*.md`), and the culture/lineage dossiers (`cyber-*.md`, `blogs-*.md`).

---

## 0. The axes underneath the families

Before the families, the coordinate system. Two dossiers state the governing map most cleanly. `cyber-scifi-terminals.md` reduces the whole movie-terminal corpus to two orthogonal dials, and they generalize to the entire field:

1. **Warmth axis — menace ↔ benevolence.** Set by *hue + corner geometry + contrast*. Green/amber-sharp-high-contrast reads as threat/operational (Alien, WarGames, Fallout); pastel-round-warm reads as ally (LCARS); muted-low-contrast reads as uncanny dread (Severance). "Vibe is a parameter set, not a style you either have or lack." (`cyber-scifi-terminals.md` §10)
2. **Energy axis — hush ↔ spectacle.** Set by *motion density + palette saturation*. Idle cursor + sparse telemetry → hush/gravity; cascading rain, sweeping arcs, neon grid → spectacle/aliveness.

To these two, the corpus adds two more dials that separate families as much as warmth and energy do:

3. **Density axis — airy ↔ wall-to-wall** (the `gap-layout-rhythm-*.md` master dial). "What does this app do with the cells it isn't using for content?" A dense tool spends them on more content (k9s, btop, ncmpcpp — "instrument-panel / serious / urgent"); an airy tool spends them on *nothing, deliberately* (Claude Code, Posting, Charm — "calm / warm / designed / expensive-minimal"). Spending cells on nothing "is the single most expensive-looking move available on a character grid."
4. **Era / authorship axis — retro-operator-built ↔ modern-consumer-product.** `cyber-deck-culture.md`: a glossy consumer-OS shell is "aesthetically wrong on a deck… it says 'a corporation decided this.'" The opposite pole (`lib-charm-*.md`) is Charm importing "modern product thinking to the command line." This axis is *who the surface announces built it.*

The eight families below are the durable clusters that recur across the corpus once you plot every app on these four dials. Two clusters sit at the retro/operational end (DOS-retro, Phosphor-cyberdeck, Ops-cockpit, Sci-fi-diegetic); three at the modern/designed end (Charm-glamorous, Zen-minimal, Systematized); and one is a *practice* rather than a fixed look that can dress any of the others (Riced-personal).

---

## 1. Orthodox DOS / BBS Retro — "this already worked in 1994"

**Target feeling.** Calm competence, 2 a.m.-sysadmin nostalgia, institutional seriousness, "a serious tool from before pictures." Recognition-as-homecoming.

**Defining moves.**
- **Palette:** the standard 16 ANSI colors, mostly four of them. Saturated **CGA/EGA background blue** (`color4`) as the resting canvas; **cyan** (`color6`) reserved for "where you are" (cursor bar, menu, F-key labels); **yellow** for marks/hotkeys only; **red exclusively for errors** ("the fire alarm works because the building is normally silent"). Light-gray "paper card" for modal dialogs — an inverted figure/ground index card dropped on the blue desk. (`app-midnight-commander-mc.md` §2)
- **Borders:** **double-line box-drawing `╔═╗ ║ ╚╝`** (code-page-437) for major containers, single `┌─┐` for inner rules — typographic hierarchy from stroke weight alone. The double frame is "*the* IBM PC code-page-437 border — the visual signature of every serious DOS TUI (Norton, Turbo Pascal, QBasic)." (`app-midnight-commander-mc.md` §3)
- **Density:** dense, wall-to-wall, a **fixed four-zone chrome that never rearranges** — menu bar welded to the top row, twin panels filling the middle, command line in the seam, function-key legend welded to the bottom row. "Muscle memory works because the instruments never migrate." (`app-midnight-commander-mc.md` §1, §4)
- **Motion:** ideologically *still*. The only animation is a one-row cursor jump, instant cell replacement, no easing. "Stillness reads as reliability." No splash, instant blue-grid paint. (`app-midnight-commander-mc.md` §5)
- **Voice:** 1990s-Unix-terse, imperative, unsentimental — `Delete`, `Mkdir`, `RenMov`, `File exists. Overwrite?`. No exclamation points, no mascot. The flatness *is* the era. (`app-midnight-commander-mc.md` §7)

**Lineage.** Norton Commander (1986) → Midnight Commander (1994) → the whole orthodox-file-manager family (Far, Volkov, Krusader). Upstream of that: Wang word-processor glyphs → CP437 (IBM PC) → ANSI.SYS 16-color → the BBS cracktro / ACiD-iCE artpack scene, where "a monospace grid is enough to carry tribal identity and rivalry" and "the terminal frame used as a badge" was invented (`blogs-ansi-heritage.md` §2). Parallel dialects feed the same family: **teletext** (2×3 mosaics, 8 flat saturated colors — "chunky, bright, broadcast-cheerful") and **PETSCII** (rounded glyphs + card suits — "round, playful, toy-like"), each a distinct retro mood (`blogs-ansi-heritage.md` §3–4).

**Exemplars.** Midnight Commander (canonical), Far Manager (heavier/more baroque), the `double-lines`/`modarcon16` MC skins; Textual's `double` border and Rich's `DOUBLE` box are the "deliberate retro/formal, DOS-era gravitas" accent inside modern frameworks (`lib-textual-*.md` §6, `lib-charm-*.md` §3).

**Execute convincingly.** The identity is *temporal stasis*, not decoration. MC's power move is that it "shipped the single-line look as default while keeping the double-line skin one keystroke away" — it modernized the resting state but refused to destroy the heritage option (`app-midnight-commander-mc.md` §3). Commit to the **fixed four-zone chrome** and the **16-color quotation**; the blue must be the *actual* CGA blue, a quotation not an approximation. The `*root` skin flipping green→red across all chrome when you run as root is the family's one genuinely expressive gesture — "privilege rendered as color" (`app-midnight-commander-mc.md` §7).

**Fails into pastiche when.** You slap a scanline shader or a truecolor gradient over it — that breaks the 16-color quotation that *is* the authenticity. MC's own README calls its truecolor skins optional and keeps the "ugly" 16-color blue as default *because* "compatibility and heritage outrank prettiness" (`app-midnight-commander-mc.md` §9). Nostalgia-cosplay without the muscle-memory rigor (panels that float, chrome that rearranges) reads as a costume, not a lineage.

---

## 2. Hacker Phosphor / Cyberdeck — the operator's green-on-black terminal

**Target feeling.** Operator-authorship, operational seriousness, transgression, "a person built this to do a job and it is doing it right now." Competence, secrecy, focus. (`cyber-deck-culture.md` §4)

**Defining moves.**
- **Palette:** **single-hue phosphor monochrome** against near-black — amber (`#FFB000`, "warm-dark rather than cold-dark," institutional/calm) or green (`#33FF33`/`#00FF41`, "matrix/hacker, slightly aggressive"). Emphasis is *brightness of the same hue*, never a second color family. "Monochrome removes the 'designed by a color team' signal — a single-hue screen looks like it was emitted by hardware, not styled." (`cyber-deck-culture.md` §3.1) A single phosphor color plus one boot ritual "buys enormous identity for zero pixels" (`cyber-scifi-terminals.md` §2).
- **Borders:** **box-drawing as machined bezels** — double-line frames for primary panels, inset `┤ SYSTEM ├` titles. "Borders stop being decoration and become the screen-equivalent of the deck's gunmetal bezel." (`cyber-deck-culture.md` §3.3)
- **Density:** the **dense operator dashboard** — a tmux-quartered screen of live panels (btop braille histograms, log tail, the one purpose-app), "no wasted cells… every cell is telemetry." Produces "a system with many processes running simultaneously," i.e. authority. (`cyber-deck-culture.md` §3.4)
- **Motion:** **CRT skeuomorphism** (scanlines, phosphor bloom, screen-curvature vignette, flicker/afterglow — cool-retro-term is the canonical emulator) plus motion strictly as *instrumentation*: heartbeat cursor, one-column-per-tick sparklines, glitch/scramble reveals. "Idle-but-alive is the exact mood of the fictional deck." (`cyber-deck-culture.md` §3.2, §3.7)
- **Voice:** the **ALL-CAPS readout register** — `PWR: 87%  TEMP: 41C  LINK: UP`, bracketed status tokens `[ARMED]`, colon-aligned numeric columns. "Instrument, not conversation… implies the reader is an operator who already knows the codes." A **boot/login ritual** (ASCII sigil + paced self-check + callsign banner) states ownership in the first three seconds. (`cyber-deck-culture.md` §3.5, §3.6)

**Lineage.** William Gibson's *Neuromancer* (1984) — "deck," "console cowboy," "the matrix," "ICE" — supplies the whole operator-jacks-in fantasy; the DEC VT100 (1978) supplies the amber/green phosphor with a blinking cursor; **cassette futurism** (Alien's Nostromo, NASA/NORAD/submarine command) supplies the used-future hardware language; Jay Doscher's 2019 Recovery Kit launched the modern maker movement; cool-retro-term supplies the CRT emulation (`cyber-deck-culture.md` §5). In games this becomes the fully-realized ASCII vibe system: Cogmind (green-on-black diegetic HUD, "the aesthetic *is* the fiction"), Hacknet (total diegesis — "real, functional shell commands as the entire interface"), Fallout/RobCo ("a color and a font can be a franchise") (`cyber-grid-games.md` §1, §6, §2).

**Exemplars.** The r/cyberdeck maker scene; Cogmind, Hacknet, Fallout terminals; aider sits at the *austere-engineer* edge of this family (its dark palette is deliberate CRT phosphor — `#32FF32` green, `#00FFFF` cyan, "the colors of a VT220," chosen over "designer pastels" to signal "retro-engineering honesty," `app-aider.md` §2.2); ncmpcpp's *riced* green-on-black cyberdecks are "not the binary; they're the config surface" (`app-ncmpcpp.md` §1).

**Execute convincingly.** Every move must "re-affirm operator-authorship and operational seriousness" (`cyber-deck-culture.md` §7). Diegesis carries the weight: a HUD styled as *the machine's own telemetry* beats a HUD styled as a form (`cyber-grid-games.md` §11). Restraint reads as design — Cogmind uses a *small consistent glyph subset*, not all of CP437, because "the eyes need a clear way to trace the picture" (`cyber-grid-games.md` §1). Keep the *single* phosphor hue; emphasis via brightness, not a second color.

**Fails into pastiche when.** A green-on-black filter sits over a Material-Design launcher — the consumer chrome underneath breaks operator-authorship ("a Material-Design launcher would break character," `cyber-deck-culture.md` §4). Sentence-case help text or emoji re-introduce the consumer voice the deck exists to escape (`cyber-deck-culture.md` §3.6). Scanlines-as-gimmick without diegetic coherence is just a costume. And note the accessibility landmine (`blogs-discourse-critique.md` §5): the reactive-canvas spinner that reads "alive" to the eye "spams" a screen reader — the aliveness technique has a cost this family leans on hardest.

---

## 3. Industrial-Dense Ops Cockpit — the instrument panel under load

**Target feeling.** Command-and-control competence, "an instrument under load, and you are its operator." Flatters the user as an expert who can drink from a firehose. (`gap-layout-rhythm-*.md` §2a, §10)

**Defining moves.**
- **Palette:** **color as a second data encoding, not decoration.** btop's per-metric 101-step gradient (green→amber→red traffic-light "indexed by the value's percentage… the machine glows with its workload"); k9s's 8-state lifecycle palette where "a screen of 60 pods becomes a heat map you read peripherally" — cool/blue for calm, hot/orange-red for trouble, gray for "dead, move on." (`app-btop.md` §2.1, `app-k9s.md` §3)
- **Borders:** **single-line box-drawing that recedes** so *color* does the talking. lazygit's whole brand is "a dim grid of single-line boxes, one of them glowing green-bold" — the active-panel border is the entire "where am I" signal (`app-lazygit.md` §1). k9s puts titles + item-counts *in* the border line ("a status rail," `app-k9s.md` §7). Per-subsystem box hues zone the screen into "labeled instrument bays" (`app-btop.md` §2.2).
- **Density:** **wall-to-wall, zero margin, maximum rows per screen** — "information wants to be dense… full-bleed tables that touch the terminal edges" (`gap-layout-rhythm-*.md` §2a). The masthead reads as an instrument cluster: two-tone key/value readout, bracketed `<key>` menu grid that "passively teaches the keyboard vocabulary" (`app-k9s.md` §2).
- **Motion:** the data animates itself — "the screen breathes with the cluster; a rolling deploy visibly ripples down the pod list (blue→green→gray)" (`app-k9s.md` §9). btop's braille waveforms scroll like an oscilloscope (2 samples × 4 sub-rows per cell = "analog-scope fidelity inside a character grid"); domain-inverted delta arrows (red↑/green↓ — "a pressure gauge, not a stock ticker") (`app-btop.md` §4.1, `app-k9s.md` §3).
- **Voice:** terse, telegraphic, angle-bracket tokens (`<pods>`, `<key>`); k9s injects affect via emoji flash-bar (😎/😗/😡) and the wordmark-as-alarm (the ASCII logo recolors red on error — "you feel scolded by the logo"). btop by contrast stays "stone-faced" — the seriousness *is* the sci-fi register. (`app-k9s.md` §4–5, `app-btop.md` §7.4)

**Lineage.** top/htop/glances → the modern GPU-era monitors (btop = bashtop→bpytop→btop++, "the look is the product, the language is an implementation detail"); tig/magit → lazygit's tiled "cockpit" (an emergent layout: "maximize on-screen context → tiled panels"); ratatui/tview supply the framework grammar where "the frame IS the design language" (`app-btop.md` §10, `app-lazygit.md` §8, `gap-layout-rhythm-*.md` §4a).

**Exemplars.** k9s (the "friendly guard-dog HUD"), btop (the flamboyant "sci-fi engineering console"), lazygit (the green-border git cockpit), htop, ratatui apps generally.

**Execute convincingly.** Density is *not self-justifying* — it defaults to noise and must be rescued by a **strong non-spatial hierarchy**: "if you spend the whitespace budget on information, you must pay the legibility debt in another currency — color, weight, or alignment" (`gap-layout-rhythm-*.md` §7). btop triple-encodes every value (position + gradient hue + scrolling waveform) so the panel is "legible at a glance, from across a room, as pure shape and color" (`app-btop.md` §9). Domain-authored color semantics (red-up-is-bad, the 8-state lifecycle) are what make it feel "built by someone who lives in clusters" (`app-k9s.md` §12).

**Fails into pastiche when.** You keep the box-drawing chrome but drop the frugality — "modern TUI apps do unnecessary full-screen refreshes that vintage TUIs have extensive code to avoid… cargo-culting the look while throwing away the frugality (the actual source of the 'fast' vibe)" (`blogs-discourse-critique.md` §5). Density with no salience hierarchy is "a wall of undifferentiated text." Decoration-for-decoration's-sake in a register whose whole claim is that every cell is working.

---

## 4. Sci-Fi Diegetic / Cassette-Futurist Mission-Control

**Target feeling.** *Stakes and gravity* — "you are operating a colored, autonomous thing," not having a conversation. "Scarcity reads as authenticity; authenticity reads as stakes." (`app-xai-grok-build-*.md` §0, `cyber-scifi-terminals.md` intro)

> This family overlaps the phosphor-cyberdeck (§2) and ops-cockpit (§3) but is distinct in *provenance and intent*: it descends from the **movie terminal** (props designed only to make you *feel* something), so it is hardware-agnostic (can be gray, amber, or warm-pastel LCARS), diegetic (the UI *is* the fiction of an operational machine), and organized around *stakes* rather than data density.

**Defining moves.**
- **Palette:** **grayscale chassis, one signal color.** Grok Build's thesis: "the chassis carries zero chroma, so any colored glyph reads as a status light on a control panel" — neutral graphite base (`#141414`) with a single magenta pilot-light accent (`#bb9af7`) marking everything the agent is doing, and the pointed inversion *the human is neutral gray, the machine is the colored actor* (`app-xai-grok-build-*.md` §1.1–1.2). The movie-corpus alternatives: single phosphor (Alien MU/TH/UR green, Fallout), neon dual-accent cyan+magenta on black (TRON — "black is the single strongest signal a surface is 'a computer drawing' not 'a document'"), or the **benevolent counter-pole**, LCARS' warm pastel rounded "elbow" blocks — proof "the same primitives can produce warmth instead of menace purely via hue and corner-rounding." (`cyber-scifi-terminals.md` §1, §4, §6)
- **Borders:** a **weight grammar that reads as a milled instrument panel** — Grok's "heavy `┃` = ownership rail, thin single-line = structure, rounded = ephemeral pop-up." Recursive fullscreen sub-cockpits (a subagent replaces the whole view with a titled bordered frame whose title bar is a status readout) produce "a felt chain-of-command hierarchy." (`app-xai-grok-build-*.md` §2.1, §6)
- **Density:** zoned like a control surface — context bar / scrollback-of-bordered-blocks / turn-status line / prompt / shortcuts bar; "the always-present frame chrome and persistent bottom bar are what make it read as a bounded application window rather than a scrolling log" (`app-xai-grok-build-*.md` §3). The `/dashboard` "Dispatch" roster frames sessions as "agents in flight," state-grouped like an ops console.
- **Motion:** **mathematically-specified breathing** (`sin²` pulse, spatial `wave_brightness` rippling down rows), *speed-encoded urgency* (7.5fps active whirl vs 3.75fps idle "watching" breath — "tempo means state"), and the metallic startup **shine sweep** (a raised-cosine glint across the logo — "the closest a TUI gets to a glossy button") (`app-xai-grok-build-*.md` §4). From the movie corpus: **teletype reveal at human cadence** (MU/TH/UR — "you wait on its schedule, not yours → subordination, suspense"), the **big glowing status word** (WarGames `DEFCON 1` — scale-as-emphasis for civilizational stakes), sweeping arcs/countdowns as the only moving element (`cyber-scifi-terminals.md` §1, §3).
- **Voice:** calm, lowercase, present-participle, ellipsis-terminated — `Thinking…`, `Responding…`, `Waiting on subagent…` — with one deadpan easter-egg (`Tip: never gonna give you up`) as the dry-humor signature. All-caps terse machine replies (`UNABLE TO COMPUTE`) at the cold end. (`app-xai-grok-build-*.md` §8, `cyber-scifi-terminals.md` §1)

**Lineage.** The "used future" doctrine (Lucas/Star Wars 1977, Scott/Alien 1979 — "legibility of wear is the source of belief," version strings and uptime counters give the machine *history*); the FUI motion-graphics houses (Territory Studio et al. — "decide the feeling and the reference texture first, then pick the glyphs"); DEC terminals and the cassette-futurism hardware canon (`cyber-scifi-terminals.md` §0, §8; `cyber-deck-culture.md` §2). Grok Build grafts TokyoNight-Night accent hues onto a neutral-gray base and presents "as spacecraft-grade mission control, not a chatbot" (`app-xai-grok-build-*.md` §11).

**Exemplars.** Grok Build (agentic mission-control cockpit); btop at its "starship engineering console" register (`app-btop.md` §1); the diegetic-fiction pole (Cogmind, DEFCON's "minimalist schematic dread," Hacknet).

**Execute convincingly.** Reliability-as-aesthetic: Grok's exhaustive width-matched CP437 fallbacks and quantization-safe grays mean "the cockpit reads identically from legacy ConHost to truecolor — the industrial value that everything must work on the oldest unit in the fleet" (`app-xai-grok-build-*.md` §10). Commit to the *scarcity*: "the fewer capabilities a screen shows off, the more we believe it is a real working machine doing a real dangerous job" (`cyber-scifi-terminals.md` intro). A little fidelity heterogeneity strengthens the used-future read ("real fleets never have matching screens," `cyber-scifi-terminals.md` §1).

**Fails into pastiche when.** You reach for glossy animated dashboards — they undercut the "scarcity reads as authenticity" thesis; "a green wall of monospace telemetry feels load-bearing in a way a glossy animated dashboard never does" (`cyber-scifi-terminals.md` intro). Over-unifying fidelity, or spectacle that dilutes stakes, or applying the register to a tool that isn't actually operational (the diegesis has nothing to point at).

---

## 5. Charm Glamorous / Pastel-Cute — "someone designed this for me"

**Target feeling.** Friendly, premium, playful, delightful; "the difference between 'I am configuring a machine' and 'someone designed this for me.'" Warmth and approachability as the whole thesis. (`lib-charm-*.md` §0)

**Defining moves.**
- **Palette:** signature **magenta→violet ("friendly premium")** — Charm pink `#FF06B7`/212 + Charm purple `#7D56F4`, "the least-used quadrant of the color wheel… how a CLI signals 'I am not IBM.'" Never pure white text (warm cream `#FFF7DB`); `AdaptiveColor` that picks a different hue per terminal background ("this app noticed my setup and dressed for it"). The **pastel-cute** sub-dialect uses Catppuccin's soft chalky candy pastels on a plum-grey ground, "cottagecore of terminal themes." (`lib-charm-*.md` §2, `blogs-color-scheme-culture.md` §5)
- **Borders:** **rounded corners `╭╮╰╯` as the default** — "the single most recognizable Charm tell — they read as 'app,' not 'terminal'… the terminal's cheapest signifier of consumer software." Gradient borders (`BorderForegroundBlend`) for "premium chrome." (`lib-charm-*.md` §3)
- **Density:** **airy — whitespace as a material.** The 1-cell interior padding ring (`│ text │` not `│text│`) is "the airy signature"; margins + `Place` centering read as "luxury, print-page composure." superfile transplants the whole Finder mental model (sidebar + panels + metadata + process footer) where "the waste *is* the point" (`lib-charm-*.md` §3, `app-superfile.md` §3).
- **Motion:** the **spinner as a vocabulary of moods** — same wait, different feeling, from serious `Line` through designed braille `MiniDot` to playful `Moon`/`Monkey`; gradient progress-bar fills as "emotional pacing of the wait"; crush's bespoke scrambled-hex shimmer spinner ("a machine thinking / matrix shimmer") and its logo that re-stretches a random letter per launch ("handmade, alive, never a static asset") (`lib-charm-*.md` §5, `app-charm-crush.md` §4–5). Gemini CLI's spinner cycles Google's whole brand wheel over 4s ("waiting = ambient brand animation") plus December snowfall (`app-gemini-cli.md` §3).
- **Voice:** affectionate, femme-coded, tongue-in-cheek — crush's "your new coding bestie," British-spelling *glamourous* as a costume, deadpan `Charm™`; superfile's "Thanks for using superfile!!" with sincere imperfect English and `<3` in every theme file; Gemini's "Agent powering down. Goodbye!" and summonable `/corgi` mascot. "The copy voice primes the user to expect delight, and the software cashes the check." (`app-charm-crush.md` §10, `app-superfile.md` §6, `app-gemini-cli.md` §6, `lib-charm-*.md` §1)

**Lineage.** Elm → Bubble Tea (pure-function-of-state makes motion free, "which is *why* Charm apps feel alive"); CSS → Lip Gloss ("we wanted HTML/CSS on the command line"); the mascot tradition. Charm's decisive move: "import CSS's separation of structure from style, then package that style as copy-paste defaults (Gum, Huh) so even an unstyled shell script inherits the vibe for free — taste as a *default*." (`lib-charm-*.md` §1, §4) Crush descends from OpenCode; superfile is downstream of Charm + Catppuccin, "pushed further toward cute" (`app-charm-crush.md`, `app-superfile.md` §8).

**Exemplars.** The Charm ecosystem (Lip Gloss/gum/Huh/Glamour), crush (the maximalist "synthwave dusk" pole — "1984-Miami-at-night arcade cabinet"), superfile (the pastel-kawaii pole), Gemini CLI (big-tech consumer cheer), Posting's jewel-toned side.

**Execute convincingly.** The house style propagates because "the beautiful thing is the easy thing and the retro-dense thing is the laborious thing" — commit to rounded borders + 1-cell padding + one signature accent + warm voice as the path of least resistance (`lib-charm-*.md` §7). crush's craft-as-identity (Hcl-blended in-gamut gradients, deterministic-but-varied spinner birth) signals "made by people who make the terminal beautiful for a living" (`app-charm-crush.md` §11). The **purple-neutral trick** — even the "neutral" backgrounds carry a violet bias so "the whole frame reads as one continuous mood instead of accent-colors-on-gray" — is what separates a mood from a color-scheme-on-gray (`app-charm-crush.md` §2).

**Fails into pastiche when.** Whimsy overruns and breaks the grid or the seriousness — the Yarn `--no-emoji` retreat is the canonical "we went too cute" cautionary tale; a double-width ✅ that shoves a column reads as "sloppiness — the exact opposite of the intended polish" (`blogs-voice-and-guidelines.md` §6). Gradient-everything with no restraint (clig.dev: "if everything is a different color, the color means nothing"). Mascot noise. The Claude Code spinner-verb bug reports ("unprofessional and dismissive") show whimsy is a *dose* — the answer is a toggle, not removal (`app-claude-code.md` §6).

---

## 6. Zen-Minimal / Chromeless-Literate — the quiet houseguest

**Target feeling.** Calm, warm, literate; "a colleague talking in your existing workspace, not a program that seized the monitor." Intimacy and persistence over ceremony. (`app-claude-code.md` §1)

**Defining moves.**
- **Palette:** **one warm accent on the user's own background.** Claude Code spends its entire color budget on a single clay-orange `#D97757` (identical in light and dark) — "brand as a temperature, not a skin"; desaturated, slightly earthy semantics (error is coral not fire-engine red, success is forest not `#0f0`) — "even failure is delivered in a soft voice." (`app-claude-code.md` §2)
- **Borders:** near-chromeless. Where boxes exist they are **rounded `╭╮╰╯`** ("a speech bubble not a frame," 31× round vs 3× single in the bundle); mostly *no* boxes — dot-and-hang-indent nesting (`⏺` call, `⎿` result) "so a 20-step agent run still reads like a document, not a control panel." aider's whole thesis is *chrome refusal*: no alt-screen, one heavy box for the single most important heading, everything else flush to scrollback (`app-claude-code.md` §3, §7; `app-aider.md` §1, §3).
- **Density:** **airy in Y, generous vertical rhythm.** Blank lines between turns, tool results dimmed and indented; "the page breathes… laid out like well-typeset text, not packed like a TUI trying to use every cell." Content stays left-anchored and *prose-shaped*, flowing down native scrollback rather than taking the alt-screen. (`app-claude-code.md` §7, `gap-layout-rhythm-*.md` §2b)
- **Motion:** **quiet, organic, ephemeral.** Claude's asterisk *blooms* (`· → ✢ → ✳ → ∗ → ✻`) and the palindrome variant *breathes* ("the strongest anthropomorphizing move… alive and calm, not processing"); streaming text then freezes to static ("the page settles"). aider's bounce scanner appears only during real waiting and "erases itself without a trace" — "restraint reads as polish; motion is a courtesy, not a monument." (`app-claude-code.md` §5, `app-aider.md` §5, `gap-the-agent-is-thinking-*.md` §8)
- **Voice:** the personality lives almost entirely in **word choice**. Claude's 187 present-continuous gerunds ("Cogitating," "Percolating," "Booping") "perform an inner life… reframe a wait from system delay into a character beat"; mode-in-the-prompt instead of a status bar (aider's `architect multi> `). Taxi-meter honesty — cost/tokens stated bluntly as trust. (`app-claude-code.md` §6, `app-aider.md` §6–7, `gap-the-agent-is-thinking-*.md` §3)

**Lineage.** The Unix "no news is good news" tradition, softened by the clig.dev "output is a conversation" reframe and the Elm "compilers as assistants, not adversaries" ethos ("even failure is delivered as help") (`blogs-voice-and-guidelines.md` §1, §3a). Boris Cherny's stated principle for Claude Code — "don't stand in front of the model… do the simple thing first" — is literally rendered as the refusal of chrome (`app-claude-code.md` §1). aider's austere pole is in the lineage of `git`, `less`, the REPL — "a terminal program, not an app that happens to run in a terminal" (`app-aider.md` §9).

**Exemplars.** Claude Code (warm/literate pole), aider (austere/industrial-minimal pole — colder, more terminal-native, bridges to §2 phosphor), Pure/Starship-lean shell prompts (the "clean sheet of good paper" register, `gap-shell-prompt-*.md` §9).

**Execute convincingly.** "Spend the whitespace budget on the *one* thing streaming" — at any instant exactly one thing is live and everything else dims; "this is how you get 'calm' without 'empty' — the space isn't wasted, it's directing attention" (`gap-layout-rhythm-*.md` §recs). Reserve the *one* loud gesture (aider's single heavy `h1` box) so it lands. Semantic-only color, four-channel typographic code (bold/dim/italic/color each meaning exactly one thing) so "the restraint is the sophistication" (`app-claude-code.md` §8).

**Fails into pastiche when.** Airiness with nothing to say — "airiness with nothing to say reads as a landing page wasting your terminal," too precious for a tool you live in for hours (`gap-layout-rhythm-*.md` §2b). Refusing chrome when the content genuinely needs framing (an approval prompt should still get its one soft-cornered box — "a box in a chromeless stream reads as 'stop and look here'"). Whimsy that curdles into cloying when the register is supposed to be quiet.

---

## 7. Systematized / Flat-Material Web-Import — "designed by a system"

**Target feeling.** Coherent, calm, layered, legible, "a flat-design web app from ~2018" — soft cards floating on a lighter surface, one accent doing all the call-to-action work. "Designed by a system, not by hand." (`lib-textual-*.md` §1)

**Defining moves.**
- **Palette:** **semantic color *roles*, not hues, expanded by a generator.** Textual's 11 base colors (`$primary`, `$accent` "used sparingly to draw attention," `$surface`, `$panel`, `$boost`…), each auto-spawning 3 light + 3 dark shades so "hover = `-lighten-1`, pressed = `-darken-1`… every interaction state is a mathematical offset of the same seed." Contrast-aware `$text` (never pure `#fff`; auto-flips per background); muted-bg + matching text-color engineered as a legible pair. "Wrong-looking combinations become hard to express — the terminal equivalent of a Figma design-token file." (`lib-textual-*.md` §2–4)
- **Borders:** **rounded `round` as the house default** ("soft, cushioned, 'app not console'"), with `ascii`/`double` held in reserve as the deliberate retro register. Rich's default `HEAVY_HEAD` table (heavy header → light body) gives "editorial typographic hierarchy for free"; the `MINIMAL`/`SIMPLE` box styles (whitespace + one rule) are "the designer's secret… refined, expensive, whisper-quiet." (`lib-textual-*.md` §6–7)
- **Density:** airy and layered; **depth faked without shadows** — `$background` < `$surface` < `$panel` lightness steps make cards "float above the void," `$boost` alpha overlays "accumulate on overlap (frosted glass)," `hatch` texture fills give a surface "grain," `opacity`/`tint` dims a backdrop into a modal scrim. (`lib-textual-*.md` §9)
- **Motion:** often deliberately **`none`** — Posting bans animation by default, "snappiness as an aesthetic… easing reads as lag; instantaneous redraw reads as native, fast, keyboard-speed" (`app-posting.md` §10). Where motion exists it's flicker-free/synchronized (Charm's "Cursed Renderer," the ncurses diff algorithm — "predictability produces calm").
- **Voice:** systematic and intentional; color "always *means* something (accent = focus, success = 2xx, error = 5xx), never decoration" (`app-posting.md` §2). Brick enforces this at the API level: widgets name *roles* (`AttrName`), never colors, so "visual drift becomes structurally impossible" (`lib-brick-*.md` §1).

**Defining move variants across the corpus.** Posting is the reference "desktop-grade app inside a character grid" — jewel-toned galaxy palette, `border: round $accent 40%→100%` panels that *ignite on focus* ("a dimmer-switch interaction… the work that glow, shadow, and elevation do in a GUI"), colored status pills welded into border titles, generous asymmetric padding as "the single strongest 'this is an application' signal" (`app-posting.md` §1, §4, §5). Nushell brings the *table* into the system — one `table.mode` token re-skins every table globally, type-aware `color_config` (filesize=cyan, datetime=purple) so "the table understands its contents," and `none`/`plain` as a *named, first-class* data-first-brutalist stance (`lib-nushell-*.md` §2–3, §6). pterm is the "template not blank canvas" pole — semantic Printers (`Success.Println`), equal-width badges that self-tabulate, "beauty as the default with zero styling code" defined at the ANSI-16 floor (`lib-pterm-*.md` §2, §4).

**Lineage.** The web's HTML/CSS/flexbox tradition ported under constraint — Textual is "a web framework wearing a terminal as a costume," McGugan's thesis that "advancements from two decades of web frameworks weren't coming back to the terminal, so cherry-pick them" (`lib-textual-*.md` §10). Brick borrows CSS's *cascade and specificity* (the AttrMap `inits`-prefix inheritance); PowerShell → Nushell brings "structured data down the pipe" and adds rendering taste; Warp extends the theme to the whole GPU-rendered UI (surface overlays, accent color, gradients — "app, not terminal") (`lib-brick-*.md` §9, `lib-nushell-*.md` §9, `blogs-practitioner-essays.md` §3).

**Exemplars.** Textual + Rich (the substrate and its house style), Posting (the jewel-toned flagship), brick (the Haskell governance-model variant), Nushell (data-table variant), pterm (template variant), Warp (GPU variant).

**Execute convincingly.** Theme by *semantic role*, not ANSI slot, so "one file reskins the entire app coherently — a theme feels like a complete identity swap" (`lib-textual-*.md` §8). Ship contrast-correct light *and* dark where accents are *re-chosen* per background, not merely inverted (Nushell's real perceptual discipline, `lib-nushell-*.md` §5). Coherence *is* the polish — "you can spot a Rich/Textual app the way you can spot a Bootstrap website."

**Fails into pastiche when.** You stop at the framework default — "Textual's out-of-the-box look is competent but blue-corporate; taste is the differentiator" (`app-posting.md` §13). Coherence without an identity accent reads as bland framework boilerplate. And note the shared warning: the very consistency that reads as "designed" can read as *generic* if nothing on screen carries a signature (Posting's purple, pterm's cyan-magenta duotone are what rescue each from anonymity).

---

## 8. Riced-Personal / Palette-Tribe — the themed self-portrait

**Target feeling.** Self-expression, belonging, ownership — "this machine is MINE." "A rice is not a UI; it is a self-portrait rendered in config files, and the screenshot is its gallery frame." (`cyber-ricing-culture.md` §0)

> This is a *practice and a modifier layer* as much as a fixed look — ricing can dress any of the families above. It earns a family slot because "adopt a palette" is a genuine, discrete direction a designer picks, and because the corpus tools that expose deep theming (nushell, yazi, superfile, k9s, ncmpcpp) are explicitly *built for* this practice — "ship a neutral skeleton, expose an obsessively granular theming grammar, let the rice community supply the soul" (`app-ncmpcpp.md` §1).

**Defining moves (the three levers of identity, `cyber-ricing-culture.md` §2).**
- **Palette = who you are, in hue.** A **named colorscheme is a tribe** with a documented emotional register: Gruvbox (warm retro earth, "craftsman who lives in the terminal"), Nord (desaturated arctic, "minimalist who finds loud highlighting vulgar"), Tokyo Night (neon-noir night-city), Catppuccin (cozy pastel, "wants ONE palette across every app"), Dracula (playful goth brand-empire), Solarized (CIELAB color-theory-nerd). Choosing one is "choosing a tribe and a mood in one gesture" (`blogs-color-scheme-culture.md` §1–7, `cyber-ricing-culture.md` §2, `gap-shell-prompt-*.md` §6).
- **Negative space = who you are, in what you omit.** Gaps, rounded corners, transparency+blur (the "cockpit floating over the city" cyberdeck vibe) — "wasted space signals I have enough screen and enough taste to spend it on air" (`cyber-ricing-culture.md` §2 Lever 2).
- **The totem = who you are, declared.** The **fetch card** (neofetch/fastfetch: distro ASCII logo + key/value spec table + a strip of `███` color-swatches advertising its own palette) — "the rice's business card / ID badge, pure signature, zero function," directly descended from the ANSI-scene group tag (`cyber-ricing-culture.md` §2 Lever 3, `blogs-ansi-heritage.md` §6).

**The implicit design system (converged, no central authority — `cyber-ricing-culture.md` §4).** Palette-first; **one accent threaded everywhere** (consistency of accent = perceived design maturity); **near-black, never pure black** ("`#1a1b26` reads designed; `#000000` reads unconsidered"); **whole-system palette coherence** (terminal + bar + prompt + editor all one scheme — "the strongest single move"); Nerd-Font glyph vocabulary; the totem is mandatory; reproducibility (published dotfiles) is part of the art.

**Lineage.** Etymology from car culture ("Race Inspired Cosmetic Enhancement" — "peacocking, bragging rights, subcultural signaling"); r/unixporn (2013) as the gallery with its reproducible-recipe "Setup Info" convention; aesthetic ancestors in demoscene, cyberpunk/cyberdeck, Japanese *ma*. The palette families each carry their own origin myth that "converts a bag of 16 hex codes into an identity" — science story (Solarized/CIELAB), landscape story (Nord's Polar Night/Frost/Aurora), character story (Dracula's vampire + merch), community story (Catppuccin's cats + coffee-flavors), architecture story (base16's 16 fixed slots) (`cyber-ricing-culture.md` §1, `blogs-color-scheme-culture.md` §8). The prompt/statusline layer is where this identity concentrates most — "the one piece of the screen the user authored themselves… a signature, a business card, and a uniform all at once" (`gap-shell-prompt-*.md` §0).

**Exemplars.** The ricing practice itself; tools built as theming stencils — ncmpcpp ("the binary is a canvas"), yazi (flavor/theme cascade, tmTheme-unified code+chrome), superfile (21-theme wardrobe with `<3` credits), k9s (~45 skins + hot-reload + Oklch inversion — "skin culture"), Nushell (base16-native), btop (40+ designer-palette theme shelf, "dresses for the screenshot").

**Execute convincingly.** Ship first-class named-palette themes so an app can "declare a tribe in one line — the palette carries 80% of the vibe"; one-accent discipline; near-black grounds; **wallpaper/context-derived accent** (pywal-style) as an "adaptive theme" mode that makes the app "feel alive — reads its environment and adapts" (`cyber-ricing-culture.md` §6). Expose a fetch-card primitive (ASCII sigil + spec table + live palette-swatch strip) as an instant identity totem.

**Fails into pastiche when.** The screenshot-self diverges from the working-self — "it is very easy to assemble a desktop that photographs beautifully and is unusable as an actual workspace" (`cyber-ricing-culture.md` §0). Auto-extracted (pywal) palettes that fail contrast — "effortlessly environmental but sometimes illegibly moody." Incoherent palette across surfaces reads as *unfinished* ("a rice without a coherent totem is 'half a rice'"). A totem with no substance behind it. Icons that require a patched font render as tofu on a bare machine — "the designed look inverts into broken" (`gap-shell-prompt-*.md` §13).

---

## 9. The retro ↔ modern spectrum, as one picture

The eight families are not eight equidistant points; they cluster on the era/authorship axis, and a designer usually chooses a *cluster* first:

- **Retro / operational cluster** (reads: honest, serious, operator-built, dense) — §1 DOS-retro, §2 Phosphor-cyberdeck, §3 Ops-cockpit, §4 Sci-fi-diegetic. Shared DNA: near-black or saturated-blue grounds, box-drawing frames that carry weight, color-as-data or color-as-signal, ALL-CAPS/terse voice, motion as instrumentation, "constraint read as honesty" (`blogs-discourse-critique.md` §1). The lineage runs CP437 → ANSI scene → DOS TUI → cassette-futurism → cyberdeck.
- **Modern / designed cluster** (reads: friendly, calm, crafted, consumer-product) — §5 Charm-glamorous, §6 Zen-minimal, §7 Systematized. Shared DNA: rounded corners, generous padding, one warm/jewel accent, adaptive/semantic color, warm-conversational voice, motion as delight-or-none, "web design under extreme constraint" (`blogs-practitioner-essays.md` §7). The lineage runs HTML/CSS + iOS product thinking → Rich/Textual/Lip Gloss.
- **§8 Riced-personal** is the modifier that lets a user *re-skin either cluster* into a personal tribe.

The single sharpest fork inside each cluster is the one `gap-shell-prompt-*.md` §12 names the "master fork": **filled-background segments vs. plain-text tokens.** Filled background "turns text into material (panels, bevels, ribbons → cockpit)"; its absence "keeps text as text (words on the void → workbench)." Powerline-ribbon = instrument-panel/§3-§4 register; lean plain-text = zen/§6 register. Almost every other choice inherits its register from this one.

---

## 10. Cross-family modifiers (drop onto any family)

These are dials that cut across the taxonomy — a designer sets each *within* a chosen family.

**Border-weight grammar** (the tone knob, per `blogs-ansi-heritage.md` §9, `app-lazygit.md` §3, `lib-charm-*.md` §3, `lib-textual-*.md` §6):
- single `─│` → quiet, structural, engineering-modern-Unix
- rounded `╭╮` → soft, friendly, contemporary consumer-software (Charm/§5, Systematized/§7, Zen/§6)
- double `╔═╗` → formal, retro-DOS, officious (DOS-retro/§1)
- heavy `┃━` → emphatic, weight, brutalist/alarm (Ops-cockpit ownership rails/§3–4)
- diagonals `╱╲` → motion, energy, instability
- hidden/none → weightless, airy, "2020s app"
"One config key moves the whole app across a mood axis from brutalist to soft to weightless" (`app-lazygit.md` §3).

**Palette-tribe overlay** (§8): any family can wear Gruvbox / Nord / Tokyo Night / Catppuccin / Dracula / Solarized as a sub-identity; the palette carries an imported emotional key without changing the family's structural moves. base16's 16-fixed-slot contract is the "Esperanto" that makes this portable (`blogs-color-scheme-culture.md` §7).

**Voice register** (the "facial expression," `blogs-voice-and-guidelines.md` §8) — an independent axis with poles: silence↔narration, warmth↔precision, restraint↔glamour, plain↔decorated, author's-look↔user's-canvas, help-dose-high↔low. "Tone is a dose, not a virtue — the same technique reads as warmth or condescension depending on audience and restraint." A DOS-retro app with a Charm voice, or a glamorous app with a terse voice, is a deliberate cross.

**Motion cadence** (the identity channel the app fully owns, `blogs-motion-and-feel.md` §9, `gap-the-agent-is-thinking-*.md`): spinner glyph-family + interval (17ms urgent → 400ms sleepy), spring damping (under-damped playful → over-damped serious), stream cadence (char-by-char intimate → line-by-line brisk), typing jitter, cursor temperament. "Motion is a primary carrier of identity, because it is one of the few expressive channels the app is not sharing with the user's environment."

**The substrate co-author** (`gap-terminal-emulator-substrate-*.md`): "the substrate owns the physics and the app owns the content." Font/ligatures, cursor animation, background blur, CRT shaders, and graphics protocols co-author ~half the vibe *outside the app's control* — a phosphor-glow shader can retexture a §6 zen app into a §2 cyberdeck; bright bold colors that read punchy on matte "bloom into illegible halos under a glow shader." Design posture: "compose so well within the guaranteed grid that the app reads as intentional under a matte flat terminal, and gorgeous when the user's phosphor-glow substrate paints it in. Design for the floor; be a gift on the ceiling."

**Sound / haptic role** (`gap-sound-bell-*.md`): completion is a load-bearing identity beat carried by the off-screen channel — a chosen restrained chime (Glass=done, Funk=needs-input), not the jarring `\a` beep, gated on duration+focus. "One semantic event, many surface-native quiet expressions" (desktop OSC toast, watch haptic, tab-color pulse). Timbre becomes a theme dimension the way color is.

---

## 11. Family-selection quick reference

| Family | Palette signature | Border | Density | Motion | Voice | Target feeling | Fails when |
|---|---|---|---|---|---|---|---|
| **§1 DOS/BBS Retro** | CGA blue + cyan + yellow; 16-color | double `╔═╗` | dense, fixed 4-zone | still (1-row jump) | terse imperative | 1994-sysadmin nostalgia, stasis | truecolor/scanline breaks the 16-color quotation |
| **§2 Phosphor / Cyberdeck** | single amber/green on black | box-as-bezel + CRT | dense operator dashboard | instrumentation + CRT glow | ALL-CAPS readout + boot ritual | operator-authorship, transgression | consumer chrome under the phosphor filter |
| **§3 Ops Cockpit** | color-as-data heat-map | single-line, recessive | wall-to-wall | data animates itself | telegraphic + affect-emoji | competence under load | density with no salience hierarchy = noise |
| **§4 Sci-Fi Diegetic** | gray chassis + 1 signal color | weight grammar (heavy/thin/round) | zoned mission-control | `sin²` breathing, tempo=state | lowercase present-participle | stakes, operating a machine | glossy dashboards undercut scarcity=authenticity |
| **§5 Charm Glamorous** | magenta→violet / Catppuccin pastel | rounded `╭╮` | airy, padded | mood-spinner + gradient | warm, femme-coded, mascot | "designed for me," delight | over-cute breaks grid/seriousness |
| **§6 Zen-Minimal** | one warm accent on user bg | chromeless / rare round | airy Y, prose-shaped | organic bloom, ephemeral | word-choice personality | calm literate houseguest | airiness with nothing to say = precious |
| **§7 Systematized** | semantic role tokens + shade ramps | round default | airy, fake-elevation layers | often none (snappy) | color always means something | "designed by a system," coherence | stops at framework default = generic |
| **§8 Riced-Personal** | named palette-tribe + one accent | user's choice | user's choice | user's choice | dotfiles-as-autobiography | belonging, "this is MINE" | screenshot-self ≠ working-self; incoherent = unfinished |

**The one-paragraph decision guide.** Pick a *cluster* first (retro/operational vs modern/designed, §9), set by whether the product wants to read *serious/frugal/operator-built* or *friendly/crafted/consumer*. Then pick the master fork (§9): filled-background material (→ cockpit/diegetic families) vs plain-text-on-void (→ zen/lean families). Then choose warmth (hue + corner geometry) and energy (motion density + saturation) on the §0 axes to land the exact family. Then layer the §10 modifiers — a palette-tribe for identity, a border weight for tone, a voice register for disposition, a motion cadence for the channel you fully own. The families are the coarse direction; the modifiers are where a designer signs their name.

---

### Provenance
Synthesized from the primary corpus in `../dossiers/` (app dossiers: aider, btop, charm-crush, claude-code, gemini-cli, k9s, lazygit, midnight-commander, ncmpcpp, posting, superfile, xai-grok-build, yazi, zellij; library dossiers: brick, charm-ecosystem, notcurses, nushell, pterm, textual-rich; gap dossiers: layout-rhythm, sound-bell, terminal-substrate, agent-thinking) and the lineage/culture corpus in `docs/proposals/research/tui-aesthetics/dossiers/` (cyber-deck-culture, cyber-ricing-culture, cyber-scifi-terminals, cyber-grid-games; blogs-ansi-heritage, blogs-color-scheme-culture, blogs-voice-and-guidelines, blogs-motion-and-feel, blogs-practitioner-essays, blogs-discourse-critique; gap-shell-prompt-statusline).
