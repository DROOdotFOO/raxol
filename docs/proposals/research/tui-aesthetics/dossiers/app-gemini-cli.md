# Aesthetic Dossier — `gemini-cli`

**Target:** Google Gemini CLI (`@google/gemini-cli`)
**Repo:** https://github.com/google-gemini/gemini-cli
**Category:** Agentic coding CLI / AI chat harness (sibling of Claude Code, OpenAI Codex CLI, opencode)
**Stack:** TypeScript + [Ink](https://github.com/vadimdemedes/ink) (React-for-CLI) over the Yoga flexbox layout engine; `ink-gradient` 3.0.0 + `tinygradient` 1.1.5 for color interpolation.
**One-line identity:** *A big-tech brand stamp in a terminal* — a filled-block ASCII `GEMINI` wordmark washed left-to-right in the Google blue→purple→rose gradient, before a single token of model output.

---

## 0. The thirty-second read (describe-the-screen)

You type `gemini` and press enter. The screen clears and eight rows of **solid box-drawing block letters** bloom into place spelling `GEMINI` — not outlined, *filled*, each glyph built from `█` and its shaded siblings `░▟▛▀▖`. Across those letters runs a single continuous color wash: the leftmost columns are a confident Google blue (`#4796E4`), the middle drifts through a soft periwinkle-violet (`#847ACE`), and the right edge lands on a warm dusty rose (`#C3677F`). The gradient is computed *per character column*, so the wordmark reads as one poured ribbon of color rather than six separately-tinted letters.

Below it, a few lines of plain-text "Tips for getting started," then an **input channel** — not a full box, just a single rounded horizontal rule (`╭─…`) above and below the prompt, leaving the sides open so the cursor line feels like a slot you drop text into rather than a caged field. A footer strip runs along the bottom in muted grays: model name, context %, git branch, sandbox status. When the model thinks, a braille dot-spinner spins — and its color is *not fixed*; it slowly cycles through the entire Google brand wheel (purple→blue→cyan→green→yellow→red and back) on a 4-second loop. In December, snow falls over the logo and three tiny Christmas trees sprout beneath it.

The whole thing feels **friendly, corporate-confident, and quietly playful** — Google's Material-design cheerfulness compressed onto a character grid.

---

## 1. The wordmark — the load-bearing identity move

Source: `packages/cli/src/ui/components/AsciiArt.ts`, `Header.tsx`, `ThemedGradient.tsx`.

### 1.1 The glyph technique
The logo is a **figlet-style filled block font** (the maintainers' own description in community threads calls it "an homage to Claude Code's filled-in ASCII art style"). It is not the hollow outline figlet look; it uses the full shade ramp — `█` (full block), `░` (light shade), and half/quadrant blocks `▟ ▛ ▀ ▖ ▜ ▝ ▙ ▗` — so the letters have *weight and interior*, reading as printed type rather than ASCII art. The effect is **substantial, branded, expensive-looking** — the terminal equivalent of a vector logo with proper letterforms.

### 1.2 Three responsive width tiers (the wordmark survives narrow terminals)
`Header.tsx` measures `terminalWidth` and picks one of three hand-drawn sizes:
- **`longAsciiLogo`** — full-width `GEMINI`, ~59 cols, shown when the terminal is wide.
- **`shortAsciiLogo`** — a tighter cut of the same wordmark for mid widths.
- **`tinyAsciiLogo`** — a compact stacked glyph (a stylized `G`/`C` mark) for cramped terminals.

There is also a whole parallel set — `shortAsciiLogoCompactText`, `longAsciiLogoCompactText`, `tinyAsciiLogoCompactText` — drawn entirely in **quadrant half-blocks** (`▟▛▀▖▜▝▙▗`) at roughly half the vertical footprint. **Vibe:** the brand is *typeset for every viewport* — it never wraps, never garbles; it gracefully steps down in size, which reads as polish and care rather than a fragile splash.

### 1.3 The gradient engine — where a wordmark becomes a mood
`ThemedGradient.tsx` wraps the ASCII in `<Gradient colors={theme.ui.gradient}>` from `ink-gradient`. `ink-gradient` → `tinygradient` interpolates the stop list across the printed width and emits a truecolor SGR escape per character cell. The default stops (`theme.ts`, both `lightTheme` and `darkTheme`):

```
GradientColors: ['#4796E4', '#847ACE', '#C3677F']
//                blue        violet     rose
```

- **`#4796E4` blue** → trust, "Google," technology.
- **`#847ACE` periwinkle violet** → the AI/"Gemini" signature; softer than pure blue, a little dreamy.
- **`#C3677F` dusty rose** → warmth, humanity, the un-corporate note that keeps it friendly.

The **left-to-right blue→purple→rose sweep is the single most identity-defining pixel decision in the app.** It says "Google product" (blue), "AI" (violet), and "approachable" (rose) in one gesture, and it is reused *everywhere* a highlight is needed. **Feeling produced:** a warm dawn-sky wash — optimistic, premium, unmistakably a consumer-Google artifact.

---

## 2. Color system

Source: `packages/cli/src/ui/themes/theme.ts` (`darkTheme` / `lightTheme`), `colors.ts`, `semantic-colors.ts`.

### 2.1 Default dark palette (pastel-on-black)
```
Background   #000000   pure black
Foreground   #FFFFFF   pure white
AccentBlue   #87AFFF   pale cornflower
AccentPurple #D7AFFF   lilac
AccentCyan   #87D7D7   pale teal
AccentGreen  #D7FFD7   mint
AccentYellow #FFFFAF   pale butter
AccentRed    #FF87AF   salmon-pink (NOT alarm red)
Gray/Comment #AFAFAF   soft gray
```
Every accent is a **high-value pastel** — nothing is saturated or harsh. Even the "red" is a salmon-pink (`#FF87AF`). **Vibe:** calm, soft, non-aggressive; a designer deliberately dialed down the aggression that terminals default to. Errors don't scream; they blush. Pure-black background gives the pastels maximum luminous pop — the palette *glows* rather than shouts.

The light theme inverts to **fully saturated dark inks on white** (`AccentBlue #005FAF`, `AccentRed #AF0000`, `AccentPurple #5F00FF`) — a completely different, more "serious document" mood, while keeping the *same* blue→violet→rose gradient stops so the wordmark identity carries across both.

### 2.2 Nineteen themes, and each re-skins the whole identity
Every built-in theme carries its **own `GradientColors` stop list**, so the launch wordmark literally changes personality per theme:
| Theme | Gradient | Mood shift |
|---|---|---|
| **Default** | `#4796E4 · #847ACE · #C3677F` | Google blue→rose |
| **Dracula** | `#ff79c6 · #8be9fd` | hot-pink → cyan, vaporwave |
| **Shades of Purple** | `#4d21fc · #847ace · #ff628c` | electric indigo → hot pink |
| **Ayu** | `#FFB454 · #F26D78` | amber → coral, warm sunset |
| **Tokyo Night** | blue · magenta · cyan | neon-city |
| **Holiday** | `#FF0000 · #FFFFFF · #008000` | **Christmas** red/white/green |
| **GitHub Dark** | `#79B8FF · #85E89D` | blue → green, calm dev |
| **ANSI** | `cyan · green` | 16-color safe, retro |

Changing the theme via `/theme` doesn't just re-tint code blocks — it **re-pours the gradient through the brand wordmark**, so identity is a slider. **Vibe:** the app's face is customizable but the *structure* of the face (gradient-washed block wordmark) is constant — brand-as-template.

---

## 3. Motion language

### 3.1 The brand-cycling spinner (`GeminiSpinner.tsx`)
The thinking indicator is a `cli-spinners` braille `dots` animation — but its **color is animated independently** of the glyph. A `tinygradient` is built from all six brand accents wrapped into a loop:
```
[purple, blue, cyan, green, yellow, red, purple]
```
A `setInterval` at **30 ms (~33 fps)** advances a `time` counter; the color is sampled at `progress = (time % 4000) / 4000`, i.e. **one full trip around the Google color wheel every 4 seconds.** So while Gemini "thinks," the spinner isn't just spinning — it's slowly breathing through Google's entire brand palette. **Feeling:** *alive, patient, on-brand.* The waiting state is turned into a tiny ambient brand animation instead of dead time. (Respects screen readers: when SR is on, the animation stops and an `altText` string is shown instead.)

### 3.2 Streaming text & redraw cadence
Because Ink is a React reconciler over the terminal, model output streams token-by-token with React re-renders — Yoga reflows the flexbox layout each frame. The result reads like a **live document reflowing**, not a teletype dump, giving the whole surface an "app-like," managed feel rather than raw stdout scroll.

### 3.3 The snowfall easter egg (`hooks/useSnowfall.ts`)
In **December or January only** (`getMonth() === 11 || === 0`), the header logo gets:
- Falling snow: characters `['*', '.', '·', '+']` drift down over the wordmark at a **150 ms frame rate**, with randomized x positions.
- Three centered Christmas trees drawn in ASCII (`*/***/*****`… with a `|_|` trunk) planted beneath the logo.
- The whole effect runs for **15 seconds** after launch, then quietly stops (`setTimeout(() => setShowSnow(false), 15000)`), and pairs with the seasonal **Holiday theme** (red/white/green gradient).
**Vibe:** delight-for-delight's-sake; a big serious Google tool that still winks at you in December. Signals a team that cares about *feel*, not just function.

---

## 4. Structure, borders & density

### 4.1 The open input "channel" (`InputPrompt.tsx`)
The prompt is **deliberately not a closed box.** It draws `borderStyle="round"` but sets `borderTop={true}, borderBottom=false, borderLeft=false, borderRight=false` (and a mirror element with only a bottom rule). The result: a **single rounded horizontal rule above and below the text, sides open.** The rounded corners (`╭ ╮ ╰ ╯`) give it a soft, modern feel; the open sides make it feel like an *editable channel* the text flows through rather than a caged form field. When shell mode is focused, the rule color shifts to the accent/focus color — border-as-status. **Vibe:** soft, contemporary, un-boxy; the CLI equivalent of a borderless Material text field with just an underline.

### 4.2 The bordered notice/summary boxes (`Banner.tsx`, stats)
Notices, warnings, and the exit summary *do* get a full closed box — always `borderStyle="round"` (never sharp `┌`, never double `╔`, never heavy `┏`). The exit screen renders a rounded box containing **"Agent powering down. Goodbye!"** with session stats. **Consistency rule:** rounded corners are the house style everywhere a border appears — sharp/double/heavy corners are entirely absent from the design language. Rounded = friendly, approachable, non-industrial.

Warning banners break the gradient rule on purpose: line 0 of a *warning* banner is bold in `theme.status.warning` (solid amber) instead of the brand gradient — gradient is reserved for *welcome/identity*, solid warning color for *alarm*. Semantic separation of "brand voice" vs "system voice."

### 4.3 Density
Generous vertical whitespace around the launch banner (the header is padded top and bottom); the tips block uses `marginTop={1}`. The footer, by contrast, is a **dense single-line status strip** with ` · ` middot separators between fields. Two densities coexist: airy hero region up top, compressed instrument panel along the bottom. Note the *evolution* here — PR #18713 ("redesign header to be compact with ASCII icon") pushed toward a **denser 4-line header** with the tiny logo + inline version/email/tier, trading hero-banner drama for at-a-glance info density. The giant wordmark and the compact identity strip now coexist as a scale spectrum.

---

## 5. Typography substitutes & glyph vocabulary

- **Weight:** `bold` for labels (`GEMINI.md`, tip numbers), `dim`/gray (`#AFAFAF`) for secondary/comment text, `italic` for code comments (via highlight.js theme mapping). No real font control, so bold/dim/italic *are* the type hierarchy.
- **Casing:** lowercase slash-commands (`/help`, `/theme`, `/corgi`), sentence-case copy — casual, not shouty.
- **Icons:** the shade-ramp block glyphs are the signature typographic material. The corgi/bear face uses `▼ ᴥ ´ \`` combined into an emoticon. Snow uses `* . · +`.
- **Syntax highlighting:** full highlight.js class→color map per theme; in Default dark, keywords are cornflower blue, strings pale yellow, variables lilac, comments italic gray — a **coherent, low-contrast pastel code aesthetic** that matches the calm palette rather than a garish rainbow.

---

## 6. Identity moments (the personality beats)

1. **Startup banner** — the gradient block `GEMINI` wordmark. The single biggest brand stamp; establishes "premium Google AI product" before any output.
2. **Corgi mode** (`/corgi`, `corgiCommand.ts`, hidden command) — toggling it plants a little corgi face **`▼(´ᴥ\`)▼`** in the footer (the `CorgiIndicator`, ears + snoot in accent-red, face in white). A pure whimsy easter egg; Google's beloved office-corgi lore rendered in five characters. **Vibe:** insider playfulness, a mascot you have to summon.
3. **Snowfall + trees + Holiday theme** — seasonal delight (see §3.3).
4. **Color-cycling spinner** — waiting-as-brand-animation (§3.1).
5. **Exit voice** — **"Agent powering down. Goodbye!"** in a rounded stats box. Slightly sci-fi, gently anthropomorphizing the tool ("Agent," "powering down") without overplaying it.
6. **Tips copy** — "Tips for getting started: 1. Create **GEMINI.md** files to customize your interactions / … / Be specific for the best results." Encouraging, teacherly, concise — Google Docs help-panel voice.
7. **Warning voice** — measured and precautionary: *"Note: Command contains redirection which can be undesirable. Tip: Toggle auto-edit to allow redirection in the future."* Labels are space-padded to align (`Note: ` / `Tip:  `) — fussy typographic tidiness even in warnings.

**Overall voice:** friendly-professional, lightly anthropomorphic ("Agent"), encouraging, with sanctioned pockets of whimsy (corgi, snow). It is the tonal opposite of a hacker-grunge terminal — this is Google's consumer cheerfulness ported to monospace.

---

## 7. Graceful degradation — does the brand survive?

This is a *documented, contested* design surface (Issue #13373, PR #13374):

- **Truecolor terminal:** full smooth per-column blue→violet→rose interpolation. Full brand.
- **256-color:** `ink-gradient` → `chalk` auto-downsamples truecolor SGR to the nearest xterm-256 index. The gradient becomes a *stepped* approximation — banded but still a recognizable wash. Brand mostly survives.
- **16-color:** chalk collapses further to the 16 ANSI slots — the gradient degrades to a coarse blue-ish/magenta-ish smear. The `ANSI`/`ANSI Light` themes exist precisely for this, defining `GradientColors: ['cyan','green']` / `['blue','green']` in *named* ANSI colors so the wordmark still gets *some* two-tone life.
- **No gradient / `NO_COLOR`:** `ThemedGradient` originally rendered the wordmark as **plain uncolored text** — the brand vanished entirely. Issue #13373 flagged this as a regression; the fix (PR #13374) makes it **fall back to `theme.text.accent`** so the wordmark stays at least single-color-branded instead of naked white. The `no-color.ts` theme goes all the way: every color field is `''`, stripping the design to pure monochrome structure for accessibility/`NO_COLOR` compliance.

**Design intent recovered:** the team treats the gradient as *progressive enhancement* — the block-letter *shape* is the irreducible brand (always present), color is layered on as the terminal allows, and there's an explicit fallback ladder (truecolor gradient → stepped → 2-tone ANSI → single accent → monochrome). The brand identity is engineered to *fade gracefully, not shatter.*

---

## 8. Why it feels different from its siblings

- **vs Claude Code:** Both use Ink and a filled-block ASCII wordmark (Gemini's is openly "an homage"). But Claude Code leans warm-terracotta/single-accent and restrained; Gemini goes **multi-hue gradient + brand-cycling spinner + seasonal snow** — more overtly *branded and playful*, less minimalist. Gemini wears Google's consumer cheer on its sleeve.
- **vs OpenAI Codex CLI / opencode:** those trend toward sparse, monochrome, hacker-serious. Gemini is the **most decorated, most colorful, most "consumer product"** of the cohort — pastel palette, rounded-only borders, easter eggs.
- **The differentiator in one phrase:** *big-tech brand warmth on a character grid.* Where siblings say "developer tool," Gemini says "friendly Google product that happens to live in your terminal."

---

## 9. Lineage & influences

- **Ink / React-for-CLI** (`ink`, `ink-gradient`) — same lineage as Claude Code; the virtual-DOM + Yoga-flexbox model is what gives all of these their "app-like," reflowing, componentized feel versus raw ANSI printf.
- **figlet / block-letter ASCII-banner tradition** — the giant startup wordmark descends from `figlet`/`toilet` terminal-banner culture; Gemini's filled-shade variant + per-column gradient is the modern "brand-gradient banner" family (also seen in Claude Code, and generalized by tools like `oh-my-logo` which explicitly cites "Claude Code or Gemini CLI" as the look to reproduce).
- **Google brand system** — the blue→violet→rose gradient and the six-color accent wheel are the terminal translation of Google/Gemini's marketing gradient identity.
- **Material Design sensibility** — rounded corners everywhere, soft pastels, generous whitespace, encouraging copy: Material's cheerfulness under a monospace constraint.

---

## 10. Notable quotes & sources

> "return `<Text color={theme.text.accent} {...props}>{children}</Text>`" — proposed fallback so the brand survives on non-gradient terminals. *(Issue #13373 / PR #13374)*

> "The changes aim to provide users with essential application and account details at a glance, improving the overall clarity and user experience." — rationale for the compact-header redesign. *(PR #18713)*

> "Gemini CLI's logo appears to be an homage to Claude Code's filled-in ASCII art style." — community characterization of the wordmark lineage.

Code fixtures (canonical, in-repo):
- Signature gradient: `GradientColors: ['#4796E4', '#847ACE', '#C3677F']` — `packages/cli/src/ui/themes/theme.ts`
- Exit voice: `"Agent powering down. Goodbye!"` — `SessionSummaryDisplay.tsx`
- Corgi face: `▼(´ᴥ\`)▼` — `Footer.tsx` `CorgiIndicator`

**Links:**
- Repo: https://github.com/google-gemini/gemini-cli
- Themes doc: https://google-gemini.github.io/gemini-cli/docs/cli/themes.html
- Issue #13373 (gradient fallback): https://github.com/google-gemini/gemini-cli/issues/13373
- PR #13374 (keep header colored on non-gradient terminals): https://github.com/google-gemini/gemini-cli/pull/13374
- PR #18713 (compact header redesign): https://github.com/google-gemini/gemini-cli/pull/18713
- `oh-my-logo` (reproduces the look): https://github.com/shinshin86/oh-my-logo
- Ink: https://github.com/vadimdemedes/ink

---

## 11. Techniques → feelings (quick-reference table)

| Concrete technique | Feeling produced |
|---|---|
| Filled shade-ramp block figlet wordmark (`█░▟▛`) | substantial, typeset, premium brand |
| Per-column blue→violet→rose gradient interpolation | warm dawn wash; "Google + AI + friendly" in one sweep |
| Three responsive logo widths + half-block compact set | polish; brand never garbles or wraps |
| Pastel accents on pure black; red = salmon-pink | calm, non-aggressive, luminous glow |
| Per-theme `GradientColors` re-skin | identity-as-slider; face is customizable, structure constant |
| Spinner color-cycling all 6 brand hues over 4s | waiting = ambient brand animation; alive, patient |
| Round-border top/bottom-only input | soft open "channel," Material text-field feel |
| Rounded corners only, everywhere (no sharp/double/heavy) | friendly, approachable, non-industrial |
| Gradient for welcome, solid amber for warnings | brand-voice vs system-voice separation |
| December snowfall + trees + Holiday theme (15s) | delight-for-delight's-sake; a team that cares about feel |
| `/corgi` mascot `▼(´ᴥ\`)▼` | insider whimsy; summonable mascot |
| "Agent powering down. Goodbye!" exit | gentle sci-fi anthropomorphism |
| Fallback ladder: truecolor→256→ANSI→accent→mono | brand fades gracefully, never shatters |
