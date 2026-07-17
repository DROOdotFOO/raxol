# Aesthetic Dossier — xAI Grok Build (`grok` CLI/TUI)

**Target:** `xai-org/grok-build` — SpaceXAI's fullscreen, mouse-interactive Rust coding-agent harness and TUI.
**Binary:** ships as `grok`; the pager artifact is `xai-grok-pager` (crate `crates/codegen/xai-grok-pager`, rendering crate `xai-grok-pager-render`).
**Category:** sci-fi / industrial family — *mission control*, not chat log.
**Repo state note:** the public mirror is `Synced from monorepo` (2 squashed commits, `SOURCE_REV` records the real SHA). Git *commit* history is therefore useless for reconstructing intent — but the code is unusually **comment-rich**, and the design rationale lives verbatim in module docs, glyph docstrings, and the `docs/user-guide/` manual. This dossier reconstructs intent from those.

---

## 0. One-paragraph gestalt

Grok Build feels like an **instrument panel for driving an autonomous machine**, not a place you have a conversation. The screen is a fullscreen dark cockpit anchored on a **neutral graphite base (`#141414`)** with a single **magenta pilot-light accent (`#bb9af7`)** that marks everything the agent is *thinking/doing*. Work is framed as *dispatch* and *turns*: a spinner-led status line reads `⠧ Responding… 0.2s … 1m20s ⇣12k [stop]`, subagents open as **bordered fullscreen sub-cockpits nested inside the parent frame**, and a `/dashboard` gives you a NASA-style roster of every agent in flight grouped by state. The typography substitutes are disciplined — a **heavy vertical rail `┃`** marks message authorship, **braille spinners `⠋⠙⠹`** and **breathing diamonds `◆◇`** carry motion, and a hand-drawn **braille-art logo with a sweeping shine** greets you at boot. The voice is calm, lowercase, and ellipsis-terminated (`Thinking…`, `Waiting on subagent…`), with a single deadpan easter-egg (`Tip: never gonna give you up`). Every glyph has a documented CP437/ASCII fallback, so the machine reads the same on a 1990s Windows console as on a truecolor iTerm — the industrial-reliability ethos made visible in the source.

---

## 1. Color system

### 1.1 The palette architecture — "grayscale chassis, one signal color"
Source: `xai-grok-pager-render/src/theme/groknight.rs`. The default theme is **GrokNight**, described in its own module doc as *"neutral gray base with TokyoNight accent colors."* The structural decision (and the whole industrial vibe) is right there:

> Backgrounds and text use a custom grayscale ramp anchored at: `bg = #141414 (20)`, `fg = #f3f3f3 (243)`. Accent colors are the original TokyoNight Night hex values.

So the *chassis* (every background, border, divider, gutter) is pure neutral gray — no hue, no tint — and **color is reserved exclusively for meaning**. This is the single most important aesthetic move: because the frame carries zero chroma, any colored glyph reads as a status light on a control panel.

**The graphite ramp (backgrounds → text):**
| Token | Hex | Role / feeling |
|---|---|---|
| `bg_terminal` / BG | `#0a0a0a` | true black terminal void |
| `bg_dark` | `#0c0c0c` | darkest recess |
| BG_STORM_DARK | `#111111` | scrollbar track, paste blocks |
| `bg_base` (BG_STORM) | `#141414` | **main cockpit surface** |
| code-block bg | `#1c1c1c` | *lighter* than base — code recesses read as inset panels |
| `bg_highlight` | `#242424` | selected row |
| `bg_hover` | `#2c2c2c` | pointer hover (desktop-app tell) |
| `bg_visual` | `#363636` | visual-selection band |
| gray_dim..gray_bright | `#585858`→`#6c6c6c`→`#787878` | three-step muted gray ramp for chrome text |
| text_secondary FG_DARK | `#c8c8c8` | body text |
| text_primary FG | `#e1e1e1` | headings, active |

The ramp is deliberately **tight and near-neutral** so it *survives quantization*: on a 256- or 16-color terminal these grays collapse cleanly to gray, never to a muddy color. That robustness is itself the aesthetic — GrokNight is the only truecolor-optional dark theme; the prettier tinted themes are hidden when the terminal can't do them justice.

### 1.2 The accent (semantic) layer — TokyoNight Night hues as status lights
Each accent is a **role**, not a decoration. This is the "control-panel legend":

| Semantic token | Hex | Glyph/where | Feeling produced |
|---|---|---|---|
| `accent_assistant` / `accent_thinking` / `accent_running` | **`#bb9af7` magenta** | the agent's rail, spinner, "running" | **the signature color** — Grok's pilot light; magenta = "the machine is alive/working" |
| `accent_user` | `#c8c8c8` (gray!) | your prompt rail | *you are neutral chrome; the agent is the colored actor* — a pointed inversion |
| `accent_system` / `accent_skill` / `fuzzy_accent` | `#7aa2f7` blue | system notices | cool, informational |
| `accent_tool` | `#787878` gray | tool calls | tools are plumbing, muted |
| `accent_success` | `#9ece6a` green | ✓ done | resolved |
| `accent_error` | `#f7768e` red | ✗ fail, [stop] hover | alarm |
| `command` / `warning` | `#e0af68` yellow | slash-commands | attention |
| `path` | `#ff9e64` orange | file paths | tactile "this is a filename" |
| `running` | `#7dcfff` cyan | live token stream | electric, in-motion |
| `accent_plan` | `#FFDB8D` golden | Plan Mode chrome | a distinct "you are in the planning room" hue |
| `accent_verify` | `#bb9af7` violet | Verifying… phase | ties verification to the agent's own color |
| `accent_model` | `#1abc9c` teal | model name badge | identity chip |
| `accent_remember` | `#8BC34A` Material light-green | memory writes | "committed to long-term" |

The move worth stealing: **the human's accent is gray, the machine's accent is magenta.** In a chat app the human is usually the colored/primary voice; Grok inverts it, which instantly reframes the surface from "conversation" to "you operating a colored, autonomous thing."

### 1.3 Five themes, tiered by terminal honesty
Source: `theme/mod.rs`, `docs/user-guide/06-theming.md`. GrokNight (default, magenta accent, quantization-safe), GrokDay (light), and three truecolor-only mood palettes — **TokyoNight** (blue-tinted), **RosePineMoon** (mauve, muted), **OscuraMidnight** (deep purple). The picker *hides the truecolor themes on non-truecolor terminals* because "they lose their character when quantized" — a designer refusing to ship a degraded version of a mood. `auto`/`system` follows OS light/dark, polling every 5s; SSH falls back to an **OSC 11 background query**. Every RGB value is quantized at startup through one pipeline (`color_support::quantize`) so syntax highlighting and blends match the chrome.

### 1.4 Signature environmental touch: the cursor *becomes* Grok
Source: `06-theming.md` + `theme/mod.rs`. On startup Grok sets your **terminal cursor color to `accent_user` via OSC 12**, and resets it via **OSC 112** on exit. *"To indicate an active Grok session."* Your blinking cursor is repainted the moment you enter the cockpit — a tiny, physical "engine on" signal that leaks Grok's identity into the terminal chrome itself. On Basic/legacy terminals a whole ANSI16 chrome-override path pins the grays to named colors so the panel never collapses to a single black slab.

---

## 2. Box-drawing, borders & structural glyphs

### 2.1 The weight system — heavy rails, light frames, rounded pop-ups
There is a deliberate **three-tier border weight vocabulary**, each mapped to a role:

- **Heavy vertical `┃` (U+2503)** — `glyphs::accent_bar()`. The **left authorship rail** painted beside every scrollback block and modal panel. Heavy weight = "this whole block belongs to X." It is the primary way authorship is shown; the block's identity color (magenta agent / gray user / blue system) lives *in this bar*, so the eye scans a colored ribbon down the left margin. Falls back to light `│` on CP437.
- **Light single-line frame `┌─┐ │ └┘`** — the default `render_bordered_frame` (`views/picker.rs`) and the subagent frame. Structural containers use *thin* lines so they recede; the header is joined to the body with **T-junctions `├`** (explicitly patched into the buffer) — a small carpentry detail that makes a titled panel look milled from one piece rather than two stacked boxes.
- **Rounded `╭─╮ ╰─╯` (`BorderType::Rounded`)** — reserved for **transient pop-ups / overlays** (image preview, line-viewer popup; `agent_view/render.rs:3390,3667`) and the **dashboard dispatch input**. Rounded corners = "soft, temporary, floating above the panel," a gentler register than the milled structural frames.

The result is a legible grammar: *heavy = ownership, thin = structure, rounded = ephemeral.*

### 2.2 The status/indicator glyph legend
From `xai-grok-pager-render/src/glyphs.rs` — every glyph is chosen and documented for a feeling:

| Glyph | Code | Role | Feeling |
|---|---|---|---|
| `❯ ` | U+276F | prompt prefix | forward-lean, "command entry" (vs a plain `>`) |
| `┃` | U+2503 | authorship rail | solid ownership |
| `◉ / ◎` | U+25C9/U+25CE | voice record light (fisheye/bullseye) | *"reads like a studio recording light"* (its own docstring) |
| `◆ ◇ ◈` | U+25C6/7/8 | diamonds — status/pending | jewel-like state markers |
| `○ ◎ ◉ ◎` | monitor pulse | idle "watching" cue | *"a concentric circle that breathes open → shut like a scanning scope"* |
| `⠋⠙⠹⠸⠼⠴⠦⠧` | braille | active turn spinner | dense, fast, mechanical rotation |
| `⋅ : ⸬ ⁙` | dot spinner | subagent/task rows | *"a quiet dot cycle"* — calmer than the braille whirl |
| `● / ○` | U+25CF/U+25CB | dashboard state dots | filled = active, hollow = idle |
| `▸ / ▾` | U+25B8 | disclosure triangles | fold/expand |
| `✓ / ✗` | U+2713/U+2717 | done / kill | resolution |
| `⧉ ↗ ⇣` | copy / open / tokens | affordance icons | desktop-app iconography |

Note the **two-speed spinner design** (a genuinely sophisticated motion choice, §4): the *primary* turn uses the busy braille whirl; *background* subagents/tasks use the quiet 4-glyph dot pulse. Foreground urgency vs background calm, encoded in glyph density.

### 2.3 The reliability ethos as aesthetic — universal CP437/ASCII fallbacks
The entire `glyphs.rs` module exists to guarantee **every chrome glyph has a legacy-safe stand-in** (`❯→>`, `✗→x`, `✓→√`, `┃→│`, braille→`|/-\`, dots→`.:·`), because *"ConHost does no font fallback, so missing glyphs render as tofu."* Each fallback is width-matched so **layout never shifts**. This is industrial-design values made literal: the instrument must read correctly on the oldest hardware in the fleet. The braille *logo* is the one exception — it has "no ASCII stand-in," so it's simply hidden on legacy consoles rather than degraded.

---

## 3. Zoning & density — "app, not conversation"

### 3.1 The three zones
The fullscreen frame is partitioned into fixed zones, top to bottom:
1. **Context/top bar** — session name, model chip, token meter.
2. **Scrollback** — the transcript, but rendered as *stacked bordered blocks* each wearing a left `┃` authorship rail, generous `outer_hpad` margins, a right-edge scrollbar, and **sticky headers** (`sticky_headers = true`: a user prompt pins to the top as you scroll past its output). Blocks fold/unfold; the header stays anchored on fold (`anchor_on_fold`).
3. **Turn-status line** — a single row that *appears only during a turn* (0 height when idle) between scrollback and prompt.
4. **Prompt widget** — the input, with `❯` prefix, a bordered box, and an **info line** below reading e.g. `grok-3 · yolo` (model · mode).
5. **Shortcuts bar** — context-sensitive key hints at the very bottom.

Whitespace does real work: configurable `outer_vpad`/`outer_hpad` gutters, a `block_pad_left` gap between the accent rail and content, and a **compact mode** that strips all outer padding for small screens. The margins + the always-present frame chrome + the persistent bottom shortcut bar are what make it read as a *bounded application window* rather than a scrolling log that runs off the top of the terminal.

### 3.2 The prompt as a defined instrument, not a line
`views/prompt_widget/mod.rs` documents the intended look:
```
                                           ← top vpad (configurable)
 ❯ type here, text wraps                   ← prefix + TextArea
   continuation of long input...
 grok-3 · yolo                             ← info line (model · mode)
```
The `❯` chevron, the wrapped multiline body, and the model/mode info line make the input a **cockpit console field** with its own status readout, not a shell `$`.

---

## 4. Motion language

Motion is one of Grok's strongest identity carriers, and it's mathematically specified in the source.

### 4.1 The breathing engine — `sin²`
`theme/tokyonight.rs` exports two shared brightness functions used everywhere:
- `pulse_brightness(tick, speed) = sin²(tick·speed)` — a temporal pulse, period π. Documented tuning: *"at 30fps, speed = 0.08 ≈ 1.3s per cycle."* Used for every **"waiting on you" diamond** (`USER_WAITING_PULSE_SPEED = 0.08`) so plan-approval, pending-input, and drain-blocked cues all breathe in unison at ~1.3s.
- `wave_brightness(tick, row, wave_rows, speed) = sin²(t + phase)` — a *spatial* wave that ripples brightness **down the rows** of a block, so a long running block shimmers top-to-bottom rather than pulsing as one flat slab.

The `sin²` choice is deliberate: it's a smooth, always-positive raised curve — the light never fully dies, it *breathes*. This is the difference between "alive/idling" and "blinking/alarm."

### 4.2 Multi-cadence spinners (frame-rate-aware)
`views/turn_status.rs` pins each animation to a divisor of the ~30fps tick so speeds read as *character*:
- Turn spinner: `SPINNER_DIVISOR = 4` → **~7.5 fps** braille whirl (brisk, working).
- Idle monitor pulse: `MONITOR_PULSE_DIVISOR = 8` → **~3.75 fps** `○◎◉◎` — *"should breathe calmly rather than read like the active turn spinner… roughly half the speed."*

So *urgency is encoded in animation speed*: active = fast whirl, idle-watching = slow breath. A user can feel whether the machine is grinding or merely alert without reading a word.

### 4.3 The startup shine (the signature motion moment)
`views/welcome/logo.rs` renders the braille logo with a **raised-cosine shine band that sweeps bottom-left → top-right** across the glyphs, plus a gentle global breathing underneath. Tuned constants (in the source): `CYCLE = 4.0s` per sweep+rest, `SWEEP_FRAC = 0.32` (*"~1.3s glint, rest idles"*), `SHINE = 0.33` peak, `PULSE = 0.06` breath. It throttles to `SHIMMER_FPS = 12` and only repaints when the quantized frame advances — a glossy, deliberately *slow* metallic sheen crossing the wordmark, like light raking across a machined surface. This is the closest a TUI gets to a "glossy button" — a specular highlight faked with per-glyph blend-toward-`text_primary`.

### 4.4 Streaming & redraw discipline
Token output streams live in **cyan `running`**; the turn-status phase timer ticks `Xs`. PTY e2e tests enforce redraw hygiene as a felt quality: `wheel_flood_paints_no_ghost_frames`, `misclassified_wheel_flood_does_not_teleport_viewport`, `edit_hl_inplace_refresh` — the aesthetic goal being a **rock-steady, ghost-free panel** even under input floods. Jank is treated as a bug against the industrial feel.

---

## 5. Typography substitutes

With only one font weight available, Grok leans on a strict SGR + casing + glyph vocabulary:
- **Bold (`Modifier::BOLD`)** — subagent titles, active headings, markdown H1–H5, hovered close buttons. Bold = "focus / this is a label."
- **Three-step gray ramp** (`gray_dim/gray/gray_bright`) does the work italic/small-caps would do on the web: metadata, timers, badges recede to dim gray; the eye sorts hierarchy by *lightness*, not size.
- **Markdown heading color-ladder** (GrokNight): H1 teal, H2 blue, H3 purple, H4 bright-gray, H5 mid-gray, H6 unbold gray — headings *desaturate and dim as they descend*, a color-coded outline level.
- **Lowercase, spaced-dot separators** — `grok-3 · yolo`, `8 tools · 1.2k tok`, `reviewer · audit token flow`. The middot `·` is the connective tissue of the whole UI; lowercase keeps the register calm and technical.
- **Nerd/Dingbat iconography** — `⧉` copy, `↗` open-link, `⇣` tokens, diamonds, chevrons — a coherent icon set that reads as app affordances, each with a legacy fallback.
- **Compact numeric formatting** — token counts as `8.5K / 1.0M`, percentages fixed-width `42.0%` / `MAX %`, so status readouts never jitter their width (`views/context_bar.rs`). Fixed-width numerics = instrument-gauge feel.

---

## 6. The subagent view — the core "mission control" device

This is what most distinguishes Grok from its chat-log siblings. Source: `app/agent_view/render.rs::draw_subagent_fullscreen`, `docs/user-guide/16-subagents.md`.

**Concept:** the agent can `spawn_subagent` up to **8 concurrent children, each in its own git worktree/branch**, working in parallel. Each is a full independent session with its own context window.

**The visual framing** (from the render code): pressing Enter on a subagent block **replaces the ENTIRE parent view** with a fullscreen bordered sub-cockpit. The frame is a single-line box (`render_bordered_frame`, border color = dim `selection_border` gray) whose **title bar is a status readout**:

```
┌ ⠧ researcher  audit token flow          gpt · 32k ctx · Responding · 2m30s [✗] ┐
├────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   (the child agent's OWN full agent-view renders here, recursively)              │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```
The title assembles: **spinner/✓/✗ icon** (magenta running / green done / red failed) · **type label** · **bold description** · **model meta** (gray) · **context badge** (dim) · **activity label** (`Responding`/`Waiting`) · **elapsed timer** · a **`[✗]` close button that brightens on hover**. Inside the frame, the child's `AgentView::draw()` is called **recursively** — a real window-within-a-window.

**Vibe produced:** *drilling into a subordinate machine.* The nesting + the dim-gray outer frame + the child owning the whole interior = a clear **authority hierarchy**: you zoom from the commander's console down into one crew member's console and back. Because subagents are *not* listed in the top-level dashboard (they "run under their parent"), the mental model is strictly hierarchical — a chain of command, not a flat swarm. Border weight reinforces it: the sub-cockpit's thin frame recedes so the child's own heavy `┃` authorship rails read at full strength inside.

---

## 7. The Agent Dashboard — the roster screen

Source: `docs/user-guide/23-dashboard.md`. Opened with `grok dashboard`, `/dashboard`, or `Ctrl+\`. The manual's own mockup is the perfect "describe the screen" artifact:

```
 Grok Build · Dashboard — 4 agents · 2 awaiting
▌● reviewer · audit token flow    Awaiting your input            2m
 ● implementer · fix login bug    Running: cargo test           12m
 ⋅ refactor · feat/login          Responding…                   24m
 ○ housekeeping                   idle                           1h
 ● implementer · add login tests  8 tools · 1.2k tok            14m
╭─────────────────────────────────────────────────────────────────╮
│ ❯ Dispatch a new agent                                          │
╰─ dispatch ──────────────────────────────────────────────────────╯
 ↑/↓ select (peek) · Enter open · Ctrl+R rename · Ctrl+T pin · Ctrl+X stop · ? help · Esc new
```

Every design signature is in this one screen: the **state-dot column** (`●` active / `⋅` responding / `○` idle), rows sorted **by state** (Needs input → Working → Idle → Inactive → Completed → Failed) so like sits with like, a **selection `▌` bar**, the middot-joined metadata, the **rounded `dispatch` input** with `❯`, and the bottom hint strip. The word **"Dispatch"** and the framing "4 agents · 2 awaiting" are the whole thesis in miniature: *you command a fleet of agents from a control screen.* Inactive sessions start collapsed as "background noise"; idle folds to an "N more" row — the roster actively curates attention like an ops console.

---

## 8. Voice & copywriting

Tone: **calm, lowercase, technical, present-participle.** Status labels are `Thinking…`, `Responding…`, `Verifying…`, `Waiting on subagent…`, `Waiting on task output…`, `Paused (no progress)`, `Paused (verification blocked)`, `Starting session…` — every one ellipsis-terminated to signal *in-progress, unhurried*. Prompts read `Dispatch a new agent`, `Type a message...`. Instructional hints are terse and middot-joined (`Input cleared · ctrl+z to undo`). The mode names carry personality: the always-approve mode is nicknamed **`yolo`** (shown right in the info line `grok-3 · yolo`) — a wink of swagger inside an otherwise sober panel.

**Identity moments:**
- **Startup:** the **braille-art logo** (`assets/logo/logo07.txt`, a hand-plotted `⣿`/`⠿` glyph portrait of the SpaceXAI mark) with the sweeping metallic shine (§4.3), a hero box, and subtitle *"Thanks for trying Grok Build, give feedback with /feedback!"* Two logo sizes tier by window height; below 22 rows it's dropped entirely.
- **Empty state:** Plan Mode with no plan shows a *"clear empty-state message so you can approve and start implementing"*; minimal mode commits `No plan written yet` into scrollback.
- **Error personality:** failures are red `✗` + gray reason; the `[stop]`/`[✗]` kill buttons turn red on hover. Sober, no exclamation.
- **Easter egg:** the tips carousel contains `Tip: never gonna give you up` — a single deadpan rickroll buried in an otherwise earnest system. That one line is the personality signature: this machine has a dry sense of humor.

---

## 9. Mouse & pointer — the desktop-app drift

Source: `docs/user-guide/21-terminal-support.md`, `app/mouse.rs`, hit-region fields throughout render code (`hit_subagent_frame_close`, `timeline_hover`, `bg_hover`). Grok is **"full-screen, mouse-interactive"** as a headline feature. Concretely:
- **Hover states** — a dedicated `bg_hover` (`#2c2c2c`) background and `hover_border`; the subagent close `[✗]` brightens to bold `text_primary` on hover; the context meter *swaps tokens for a progress bar on hover with no layout shift*. Hover feedback is the single strongest "this is a desktop app" tell a TUI can give.
- **Click regions** — clickable subagent blocks, timeline ticks (with hover preview of that turn), fold triangles, dispatch rows.
- **Double/triple-click** — double-click toggles fold or selects a word/URL; triple-click selects a line; double-click a past prompt enters **inline edit**.
- **Wheel scrolling** with heavy anti-jank guarantees (§4.4).

**Vibe shift:** pointer support pulls Grok away from *terminal-native keyboard modality* toward **windowed-application character** — hover highlights, clickable chrome, drag-select, a close button in the corner of a panel. It feels less like `vim` and more like a native IDE panel that happens to be drawn in cells.

---

## 10. What makes it FEEL different from its siblings

Against Claude Code, Codex, Gemini CLI, Aider (same category):
1. **Gray chassis + one magenta signal color**, with the *human rendered as neutral gray and the machine as the colored actor* — a deliberate inversion of chat-app color logic that reframes the whole surface as operating-a-machine.
2. **Recursive fullscreen subagent windows** — siblings show subagents as inline log lines; Grok gives each a nested sub-cockpit with its own titled frame and status bar, producing a felt chain-of-command hierarchy.
3. **The Dashboard/"Dispatch" roster** — a state-grouped fleet-ops screen, framing sessions as agents-in-flight rather than chat tabs.
4. **Mathematically-specified breathing motion** (`sin²` pulse + spatial wave) with *speed-encoded urgency* (7.5fps working whirl vs 3.75fps idle breath) and the metallic startup shine — a motion identity, not just a spinner.
5. **Border-weight grammar** (heavy `┃` ownership / thin structural / rounded ephemeral) that reads as *milled instrument panel*.
6. **Reliability-as-aesthetic**: exhaustive width-matched CP437 fallbacks and quantization-safe grays mean the cockpit reads identically from legacy ConHost to truecolor — the industrial value that everything must work on the oldest unit in the fleet, expressed in the theme code itself.
7. **The cursor-repaint (OSC 12)** — Grok physically claims your terminal's cursor color while active; no sibling brands the chrome outside its own frame like this.

---

## 11. Lineage & influences
- **ratatui**, forked into house crates `xai-ratatui-inline` and `xai-ratatui-textarea` — they needed inline-render and a richer textarea than upstream, and vendored them.
- **TokyoNight (Night variant)** — the accent hues are *literally* the TokyoNight Night hex values (`#7aa2f7`, `#bb9af7`, `#9ece6a`, `#f7768e`…), grafted onto a custom neutral-gray base to make GrokNight. Rosé Pine Moon and an "Oscura" purple round out the mood themes.
- **Rust toolchain governance** — `rustfmt.toml`, `clippy.toml`, pinned `rust-toolchain.toml`, DotSlash hermetic tools; the codebase's uniform formatting and `#[allow(clippy::too_many_arguments)]` on the big render fns show a house style that prizes one consistent surface — the same disciplined-instrument value the UI projects.
- **SpaceXAI "universe" framing** — the hero screenshot is `universe-tui-screenshot`, the brand mark is the SpaceXAI symbol; the product presents as spacecraft-grade mission control, not a chatbot.
- **Agent Client Protocol (ACP)** — it also embeds in editors, so the TUI is one surface of a headless engine (leader process + pager over a socket), reinforcing "the TUI is an instrument attached to a machine."

---

## 12. Notable quotes (from source & docs)

> "GrokNight theme — neutral gray base with TokyoNight accent colors. … Backgrounds and text use a custom grayscale ramp anchored at bg = #141414, fg = #f3f3f3. Accent colors are the original TokyoNight Night hex values."
> — `xai-grok-pager-render/src/theme/groknight.rs`

> "GrokNight uses neutral grays that survive quantization cleanly. TokyoNight uses blue-tinted backgrounds that lose their character when quantized, which is why the theme picker hides them on non-truecolor terminals."
> — `theme/mod.rs` / `06-theming.md`

> "Grok sets your terminal cursor to the current theme's `accent_user` color using the OSC 12 escape sequence, to indicate an active Grok session."
> — `docs/user-guide/06-theming.md`

> "a dot inside a ring … FISHEYE on the bright half and BULLSEYE on the dim half, which together with a smooth color fade reads like a studio recording light."
> — `glyphs.rs`, `record_dot`

> "a concentric circle that breathes open → shut like a scanning scope."
> — `glyphs.rs`, `monitor_icon_frames`

> "The idle 'watching' cue should breathe calmly rather than read like the active turn spinner, so its `○ ◎ ◉ ◎` cycle runs at roughly half the speed."
> — `views/turn_status.rs`

> "a raised-cosine band sweeps bottom-left → top-right and parks off-screen between sweeps; a gentle global pulse breathes underneath it."
> — `views/welcome/logo.rs`, `shine_opacity`

> "ConHost does no font fallback, so missing glyphs render as tofu."
> — `glyphs.rs` module doc

> "Grok Build is SpaceXAI's terminal-based AI coding agent. It runs as a full-screen TUI that understands your codebase … interactively, headlessly for scripting/CI, or embedded in editors via the Agent Client Protocol."
> — `README.md`

> "a centralised, agent-native overview of every top-level session you have in flight … grouped by state, with peek, attach, and dispatch from one screen."
> — `docs/user-guide/23-dashboard.md`

---

## 13. Links
- Repo: https://github.com/xai-org/grok-build
- Theme source: `crates/codegen/xai-grok-pager-render/src/theme/{mod,groknight,tokyonight}.rs`
- Glyphs: `crates/codegen/xai-grok-pager-render/src/glyphs.rs`
- Subagent render: `crates/codegen/xai-grok-pager/src/app/agent_view/render.rs`
- Logo + shine: `crates/codegen/xai-grok-pager/src/views/welcome/logo.rs`, `assets/logo/logo07.txt`
- Docs: `crates/codegen/xai-grok-pager/docs/user-guide/` (06-theming, 16-subagents, 19-plan-mode, 21-terminal-support, 23-dashboard)
- Product page: https://x.ai/cli · Docs: https://docs.x.ai/build/overview
- Coverage: https://www.marktechpost.com/2026/07/15/spacexai-open-sources-grok-build-the-rust-agent-harness-tui-and-tool-layer-behind-its-coding-cli/ · https://mer.vin/2026/05/grok-build-cli-xai-terminal-coding-agent-with-plan-mode-subagents-and-headless-ci/
