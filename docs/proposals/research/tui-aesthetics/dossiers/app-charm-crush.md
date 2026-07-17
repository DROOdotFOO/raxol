# Charm Crush — Aesthetic Dossier

> "The glamourous AI coding agent for your favourite terminal 💘"
> "Your new coding bestie, now available in your favourite terminal."

**What it is:** Charm's flagship agentic coding TUI (Go, Bubble Tea v2 / Lip Gloss v2). Descends from OpenCode, which joined Charm in summer 2025 and was rebranded Crush. It is the most overtly *cosmetic* agent on the market: soft rounded panes, per-character indigo→magenta gradients, a living stretch-on-launch wordmark, and a scrambled-hex shimmer spinner. Where Claude Code is monochrome-austere, Crush is **synthwave dusk** — a purple-tinted near-black room lit by hot-pink and electric-violet neon.

Repo cloned to `undefined/crush`. Palette source: `github.com/charmbracelet/x/exp/charmtone` (Charm's house named-color package). Theme lives in `internal/ui/styles/{themes,quickstyle,styles,grad}.go`, logo in `internal/ui/logo/`, spinner in `internal/ui/anim/anim.go`, diff in `internal/ui/diffview/style.go`.

---

## 1. The identity in one sentence

Crush takes the character grid and dresses it like a **1984-Miami-at-night arcade cabinet**: violet-to-pink neon gradients painted *per grapheme*, aqua-mint accents as the cool counterpoint, soft rounded borders that read as "glossy," and a wordmark built from half-block glyphs that quietly re-stretches a random letter on every launch so the brand never sits perfectly still. It is the only agent whose *neutral grays are secretly purple*.

---

## 2. Color palette — the synthwave encoding

All hues are `charmtone` named RGBA truecolor values. Semantic roles are assigned in `themes.go :: CharmtonePantera()` (the default dark theme — "Pantera" = panther/black-cat). The mapping IS the identity:

| Role | charmtone name | Hex | Feeling it produces |
|------|----------------|-----|---------------------|
| **primary** | Charple | `#6B50FF` | Electric indigo-violet. The Charm signature ("Char"+purple). Cursors, focus rails, spinner start, logo end. |
| **secondary** | Dolly | `#FF60FF` | Hot magenta. The neon sign. Gradient endpoints, Charm™ mark, logo start. |
| **accent** | Bok | `#68FFD6` | Mint/aqua. The cool complement that keeps the pinks from cloying — a splash of 80s teal. |
| **keyword** | Blush | `#FF84FF` | Soft candy pink. Syntax keywords, emphasis. |
| **onPrimary** | Butter | `#FFFAF1` | Warm off-white text sitting *on* violet — never pure `#fff`, always a hair cream. |
| **fgBase** | Sash | `#ECEBF0` | Body text: a faintly lilac white, not neutral gray. |
| fg subtle ramp | Squid→Smoke→Oyster | `#858392` `#BFBCC8` `#605F6B` | Purple-tinted grays for de-emphasis. |
| **bgBase** | Pepper | `#201F26` | Near-black, but plum-shifted (R20<B26). The dusk. |
| bg ramp | BBQ→Char→Iron | `#2D2C36` `#3A3943` `#4D4C57` | Elevation layers, all warmed toward purple. |
| destructive | Coral | `#FF577D` | Warm rose-red, softer than alarm-red. |
| error | Sriracha | `#EB4268` | Hotter pink-red for real failures. |
| warning / subtle | Mustard / Zest | `#F5EF34` / `#E8FE96` | Acid yellow / pale lime. |
| denied | Tang | `#FF985A` | Orange. |
| busy | Citron | `#E8FF27` | Electric lime "working." |
| info | Malibu | `#00A4FF` | Bright cyan-blue. |
| success | Julep | `#00FFB2` | Neon spring-green, near-Bok. |

**The key aesthetic decision:** the *neutrals are not neutral*. Pepper `#201F26`, BBQ, Char, Iron all carry a blue-purple bias (B channel ≥ R). Even the "empty" chrome — backgrounds, separators, dim text — glows faintly violet. This is what makes Crush read as *a mood* rather than *a color scheme applied to a gray app*. The synthwave is in the shadows, not just the highlights.

The two provider themes: `CharmtonePantera()` (default) and `HypercrushObsidiana()` (provider id `"hyper"`) — the latter currently aliases Pantera, i.e. a reserved hook for a future distinct look. `ThemeKeyForProvider` exists purely so the app can *skip the expensive style rebuild* when switching providers wouldn't change the theme (commit `173b2be perf(ui): skip theme rebuild when provider keeps the same theme`).

---

## 3. Gradients — the signature move

Crush's single most recognizable technique is the **per-grapheme horizontal gradient** (`styles/grad.go`).

- `ForegroundGrad` splits the string into grapheme clusters via `uniseg` (so emoji/CJK stay intact), builds a color ramp with `lipgloss.Blend1D(n, c1, c2)`, and paints each cluster its own color. The result: a word where each letter is a slightly different hue along an indigo→magenta sweep. **Feeling:** liquid, iridescent, "airbrushed" — the closest a monospace grid gets to a chrome-and-neon gradient decal.
- Blending happens in **Hcl space** (`anim.go :: makeGradientRamp` uses `colorful.BlendHcl`). This is the craft detail: Hcl interpolation stays in-gamut and perceptually even, so the violet→pink ramp has no muddy brown-gray midpoint the way naive RGB lerp would. The gradient *feels* smooth because it mathematically is.

Where gradients are deployed (from `quickstyle.go`), each direction chosen deliberately:

- **Working spinner:** `WorkingGrad` = primary→secondary = Charple→Dolly (indigo→magenta), with `CycleColors: true` so the ramp *scrolls* — a shimmering neon crawl.
- **Big logo wordmark:** secondary→primary = Dolly→Charple (pink→violet).
- **Dialog title `╱╱╱`:** primary→secondary.
- **Queue pill:** error→secondary = Sriracha→Dolly (red→pink, "urgent but still cute").
- **Session dialog states as gradient semantics:** *deleting* = destructive→primary (red→violet), *renaming* = warningSubtle→accent (Zest→Bok). The gradient endpoints themselves encode the mode.

---

## 4. The logo — a wordmark that breathes

`internal/ui/logo/logo.go` + `letterforms.go`. This is the biggest first-impression brand moment.

- **Letterforms are hand-built from half-block glyphs** — `▄ ▀ █` assembled per-letter via `heredoc`. Example, `LetterC`:
  ```
  ▄▀▀▀▀
  █
   ▀▀▀▀
  ```
  Big, chunky, arcade-marquee capitals — not a font, a *bitmap sculpted in Unicode blocks*.
- **Diagonal neon "fields":** the wordmark is flanked by ramps of `╱` diagonal slashes (const `diag = "╱"`), colored `primary` (Charple). The left field is a fixed 6-wide block; the **right field steps down one cell per row** (`width = rightWidth - i`), making a right-leaning parallelogram of slashes. **Feeling:** speed-lines, a synthwave sun's rays, motion frozen into the masthead.
- **The living detail — random stretch on launch:** `cachedRandN(len(letterforms))` picks *one* letter per process run and stretches it horizontally (7–12 cells). So the "CRUSH" you see this session is subtly proportioned differently from last session — the logo is *alive but stable within a run*. `Unstable: true` mode re-picks every render (jitters on resize; "mainly for testing"). This is intentional whimsy: the brand refuses to be a static asset.
- **The meta row:** `Charm™` (with the deadpan trademark) + version, right-aligned above the wordmark, in secondary/primary. The ™ is a joke — glam-corporate irony.
- **Compact `SmallRender` (sidebar):** collapses to a one-liner — `Charm™ Crush ╱╱╱╱╱…` — gradient wordmark then diagonals filling the remaining width. Same identity, one row tall.

**Describe the screen:** On launch you get a violet room. Chunky pink-to-purple block letters spelling CRUSH sit inside a cage of electric-indigo diagonal slashes that fan out and step down to the right like a setting-sun grid. Above them, tiny, `Charm™  v0.8x`. One of the letters is a touch wider than you'd expect — you won't consciously notice, but it's why it feels handmade.

---

## 5. Motion language — the shimmer spinner

`internal/ui/anim/anim.go` is a bespoke spinner, not the stock `bubbles/spinner`. 20 FPS (`fps = 20`, 50ms/frame). Anatomy:

- **Scrambled-rune cycling region:** a band of characters drawn from `0123456789abcdefABCDEF~!@#$£€%^&*()+=_` — deliberately **hex + code punctuation**, so it reads as "a machine thinking / compiling." Each column is colored along the Charple→Dolly ramp; with `CycleColors` the ramp scrolls → a **neon shimmer that flows left-to-right through scrambling glyphs**. The single most "this is an AI working" gesture in the app.
- **Staggered birth (fade-in):** columns don't all appear at once. Each column has a deterministic random `birthStep` (0–20 frames, ~1s); until its birth it shows a dim `.` initial char, then "pops" into the scramble. **Feeling:** the spinner *materializes* rather than switching on — organic, staggered, alive.
- **Determinism as craft:** birth schedule and glyph choice are seeded from `id + settingsHash` (xxh3). Two spinners with the same label/identity stagger *identically* (byte-stable, golden-testable); different labels ("Thinking" vs "Generating") or different tool calls fade in with *different* patterns — so the screen has visual variety without chaos.
- **Animated ellipsis:** after the scramble settles, the label gets a cycling `.`/`..`/`...`/`` ellipsis every 400ms (`ellipsisAnimSpeed = 8` frames). Classic "…thinking" punctuation, hand-timed.
- **Elapsed-time suffix:** optional `Suffix func()` renders live elapsed seconds (`dc16099 feat: elapsed seconds timer`) — the spinner doubles as a stopwatch.
- **`NoScramble` mode:** removes the cycling glyphs entirely, leaving just label + ellipsis. Used where scrambled hex would *wrongly* imply "thinking" (non-LLM work). The team distinguishes "running" from "reasoning" *visually*.

Other motion: Bubble Tea's diff-based redraw (only changed cells repaint); Glamour-rendered streaming markdown from the model; smooth diff-pane scrolling backed by a `syntaxCache` so chroma highlighting doesn't re-run per scroll frame.

---

## 6. Borders & box-drawing — soft = glamourous

Two border vocabularies, each with a job:

- **Rounded borders everywhere structural** (`uv.RoundedBorder()` / `lipgloss.RoundedBorder()`): dialogs, compact detail panes, pills, the quit confirmation frame. The `╭ ╮ ╰ ╯` soft corners are *the* "glamourous" cue — rounded reads as friendly/glossy/cushioned, where sharp `┌┐` reads as utilitarian. This is the deliberate anti-austerity choice versus siblings.
- **Minimal left-rail for chat messages** (`quickstyle.go`): instead of boxing every message, Crush uses a custom `lipgloss.Border{Left: "▌"}` — a single **thick half-block rail** down the left edge. Focus state swaps a thin `│` (`NormalBorder`) for the thick `▌`, colored `primary` (user) or `successMostSubtle` (assistant/tool). **Feeling:** selection is signaled by a rail *thickening and lighting up*, tactile and quiet, no heavy chrome. User turns get a violet rail; assistant turns a muted mint rail — role legible at a glance by hue.
- Glyph kit (`styles.go` consts) leans **geometric/diamond**: model = `◇`, hypercredit = `◆`, radio `◉`/`○`, tool states `●`/`✓`/`×`, check `✓`, loading `⟳`, spinner `⋯`, scrollbar `┃`/`│`, skill `▲`, text `≡`. The diamond `◇◆` motif is the model-identity signature.

---

## 7. Diff pane — a reusable signature surface

`internal/ui/diffview/style.go`. The diff view is one of Crush's most-praised surfaces ("dedicated diff view," "split-pane"). Both unified and split layouts; chroma syntax highlighting cached for smooth scroll. The color decision is telling:

- **Dark theme inserts:** fg `Turtle #0ADCD9` (aqua) on subtle green `#303a30`.
- **Dark theme deletes:** fg `Cherry #FF388B` (hot pink) on subtle red `#3a3030`.
- **Divider/filename banners:** `Smoke` on `Sapphire #4949FF` / `Ox #3331B2` — a blue neon strip.

Note the intent: additions aren't terminal-green, they're **aqua**; deletions aren't terminal-red, they're **hot pink**. Even the diff — the most conventionally color-coded surface in any coding tool — is pulled onto the synthwave palette. Light theme mirrors this with pastel `#e8f5e9` / `#ffebee` washes, keeping the soft look in daylight.

---

## 8. Coercing the whole terminal on-brand (ANSI-16 remap)

`quickstyle.go` builds a full `[16]color.Color` ANSI map, and bang-mode (`!` shell) output is **rendered through it** (commits `1c2da89 feat(bang): remap ansi 16 colors`, `ce2dc1e chore(bangmode): adjust ANSI16 colors`). ansiRed→Coral, ansiGreen→Guac, ansiBlue→Charple, ansiMagenta→Dolly, ansiCyan→Malibu, brightMagenta→Blush. **Effect:** even *external tool output* — `ls`, `git`, a compiler — gets recolored into the Crush palette. The app refuses to let raw terminal colors break the mood. This is the most aggressive expression of the identity: the whole surface, including foreign content, wears the same makeup.

---

## 9. Adaptive rendering & graceful degradation

- **Capability detection** (`Capabilities` struct): truecolor / 256-color, Kitty & Sixel graphics protocols, OSC 99 notifications.
- **Truecolor → 256 → 16 degradation** is automatic via Lip Gloss's color profile: charmtone hexes are truecolor RGBA; on a 256-color terminal Lip Gloss down-maps each to the nearest cube color. The pastel gradients coarsen but the violet/pink identity survives because the *endpoints* are far apart in hue.
- The gradient ramp count is computed from render width, so gradients stay smooth at any pane size rather than banding at fixed steps.

---

## 10. Voice & copywriting

Deliberately affectionate, femme-coded, tongue-in-cheek:

- **"Your new coding bestie."** — friend, not tool.
- **"Glamourous agentic coding for all 💘"** — British spelling *glamourous* / *favourite* as an affect choice (Charm is US-based; the spelling is a costume). Heart-with-arrow 💘, not a plain heart.
- **`Charm™`** — deadpan trademark as ongoing gag.
- Community-reported register: "playful," "refreshing," "friendly and futuristic," "developer delight." Charm's whole thesis is that the CLI can be *glamorous*; Crush is that thesis pointed at agents.

---

## 11. What makes it FEEL different from its siblings

- **vs. Claude Code / Codex (austere monochrome):** Crush is maximalist neon where they are minimalist ink. Gradients, mint accents, rounded corners, a breathing logo.
- **vs. Aider / plain agents:** Crush treats the *first 200ms* as a brand moment (animated stretch-logo, materializing spinner) — siblings drop you at a prompt.
- **The purple-neutral trick:** its restraint is still colored. Even "off" pixels glow violet, so the whole frame reads as one continuous mood instead of accent-colors-on-gray.
- **On-brand coercion:** the ANSI-16 remap means nothing on screen — not even `git status` — escapes the palette. Total art direction.
- **Craft-as-identity:** Hcl-blended gradients, deterministic-but-varied spinner birth, cached-random logo stretch. The polish itself is the personality; it signals "made by the people who make the terminal beautiful for a living."

---

## Techniques → feelings (quick index)

- Per-grapheme Hcl gradient on wordmark/spinner → *iridescent, airbrushed, luxe*.
- Purple-biased "neutral" background ramp (Pepper `#201F26` etc.) → *ambient synthwave dusk, mood not scheme*.
- Rounded `╭╮╰╯` borders on dialogs/pills → *glossy, cushioned, friendly*.
- Thick `▌` left-rail that lights up on focus (vs thin `│`) → *tactile selection, quiet not boxy*.
- Half-block `▄▀█` marquee letterforms + `╱` diagonal fields → *arcade cabinet, frozen speed-lines*.
- Random letter-stretch per launch → *handmade, alive, never a static asset*.
- Scrambled hex/punct spinner glyphs on scrolling neon ramp → *a machine thinking, matrix shimmer*.
- Staggered deterministic column birth → *materializes organically, varied but stable*.
- Aqua inserts / hot-pink deletes in diff → *even code review is on-brand*.
- ANSI-16 remap of raw shell output → *total art direction, nothing escapes the palette*.
- Mint (Bok `#68FFD6`) accent against pink/violet → *80s teal counterpoint keeps it from cloying*.

---

## Sources

- Repo: https://github.com/charmbracelet/crush (cloned to `undefined/crush`) — `internal/ui/styles/{themes,quickstyle,styles,grad}.go`, `internal/ui/logo/{logo,letterforms}.go`, `internal/ui/anim/anim.go`, `internal/ui/diffview/style.go`
- charmtone palette hexes: `github.com/charmbracelet/x/exp/charmtone` (`charmtone.go` colors map)
- Docs site: https://charmbracelet-crush.mintlify.app/ ("Glamorous Agentic Coding for All")
- DeepWiki styling-system page: https://deepwiki.com/charmbracelet/crush/5.8-styling-system
- Tessl, "Does Developer Delight Matter in a CLI? The Case of Charm's Crush": https://tessl.io/blog/does-developer-delight-matter-in-a-cli-the-case-of-charm-s-crush/
- XDA, "I got a Crush on this new Terminal-based AI coding tool" (synthwave styling): https://www.xda-developers.com/moved-to-crush-from-claude-code/
- Charm: https://charm.land/
- Design-relevant commits: `173b2be` (skip theme rebuild), `1c2da89`/`ce2dc1e` (ANSI-16 remap of bang output), `dc16099` (elapsed timer), `1ef42ef` (queue pill border), `5e611a7` (free-text "pop")
