# Aesthetic Dossier — The "Agent Is Thinking" Waiting State

> **Category:** cross-cutting / temporal — the aesthetics of the pause
> **One-line:** In a coding-agent TUI the user spends *most of every turn* staring at a "working…" indicator, so the waiting state is not chrome — it is the app's face at rest, and every choice of glyph, cadence, verb, and reveal-rhythm is a statement of character.
> **Scope:** the vocabulary of the pause — spinner glyph-sets and their intervals, the whimsical present-participle verb beside them, elapsed/token/cost meters, streaming-token reveal cadence, progress bars, skeleton/shimmer, breathing dim-bright loops, and the deliberate *absence* of motion.
> **Studied artifacts:** `cli-spinners/spinners.json` (90 spinners, read byte-exact from the scratchpad copy), `sindresorhus/ora`, `charmbracelet/bubbles/spinner`, and the four coding-agent CLIs already dossiered here (Claude Code, aider, Gemini CLI, Grok Build) — cross-read for how each renders "the model is working."

---

## 0. Why the pause is the signature moment

Every other UI surface is transient — you look at a diff, a result, a prompt, and move on. The **waiting state is where the eyes actually live.** LLM latency means that between pressing Enter and reading a reply, several seconds to several minutes elapse, and during that entire stretch the only thing on screen that *moves* is the thinking indicator. It is, functionally, the app's screensaver, its heartbeat, and its personality reel — all in the two or three cells next to a verb.

This is why the pause carries a disproportionate share of a coding agent's character. A web app can express itself in a thousand pixels of chrome the user glances past; a terminal agent has one animated glyph and one word, held in front of the user for the majority of the session. **The waiting state is the highest-leverage aesthetic real estate in the entire medium** — and, remarkably, it is the one most often left to a default `cli-spinners` import.

The core thesis of this dossier: *waiting is not dead time to be disguised; it is a performance to be authored.* The concrete lever is the pairing of **(glyph vocabulary × frame interval × verb × instrumentation × reveal cadence)** — and each axis maps to a nameable feeling.

---

## 1. Lineage — where the throbber comes from

The animated "I'm busy" mark predates the terminal renaissance by decades, and the coding agents inherit two distinct ancestral lines.

- **The browser throbber (1993–94).** NCSA Mosaic animated its logo while a page downloaded; Netscape Navigator 1.0 shipped a big blue **"N" that expanded and contracted** — and the *throbbing* is literally what named the whole genre "throbber." The meteor-shower "N" that followed "almost became an unofficial symbol of the World Wide Web." **Feeling inherited:** the throbber established the convention that *a logo in motion = the system is alive and working*, which is exactly what Claude Code's breathing asterisk and Grok's shining braille logo revive. ([Throbber — Wikipedia](https://en.wikipedia.org/wiki/Throbber))
- **The teletype / typewriter.** Character-by-character stream reveal is a direct descendant of the physical teletype hammering glyphs one at a time. Streaming token output *re-summons* that machine — see §5. The typewriter is the ancestral metaphor for "a thought being committed to the page in real time."
- **The braille counter (terminal-native).** The ubiquitous `⠋⠙⠹` braille spinner has a specific origin story: someone mapped the bits of 8-bit numbers onto the eight dots of a braille cell and counted `0→255`, arranging it so "the left column changes quickly and the right column changes slowly in an appealing way." The genre's densest, smoothest spinner was born as a *number visualization*. ([cli-spinners readme](https://github.com/sindresorhus/cli-spinners/blob/main/readme.md))
- **The skeleton screen (web, 2013).** Luke Wroblewski coined "skeleton screen" for the Polar app, arguing designers should "eschew the use of spinners in favor of visual placeholders" — grey boxes that appear instantly where content will land. Facebook/Google's **shimmer** wave over those boxes is "perceived as shorter in duration than skeletons that pulse." This is the web ancestor of the terminal shimmer/breathing loop (§7). ([Skeleton screens — UX Collective](https://uxdesign.cc/what-you-should-know-about-skeleton-screens-a820c45a571a))

The through-line: humans read *motion as aliveness* and *reveal-cadence as thought*. Every technique below is a way of dialing those two perceptions.

---

## 2. The spinner glyph vocabularies — which frame-set feels like what

`cli-spinners` is the de-facto library; `ora` ("Elegant terminal spinner," default `dots`) and Charm's `bubbles/spinner` are the two dominant wrappers. The **frame-set is the timbre and the interval is the tempo** — together they set the mood before a single word is read. Frames and intervals below are byte-exact from `spinners.json`.

| Spinner | Frames | Interval | Reads as |
|---|---|---|---|
| **dots** (braille) | `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` | **80 ms** (~12 fps) | **smooth, refined, quietly premium.** Braille's 2×4 dot grid is the *highest spatial resolution the character cell offers*, so the motion looks near-analog. The default "serious but designed" pick. |
| **line** | `- \ \| /` | 130 ms (~8 fps) | **utilitarian, mechanical, neutral** — "a computer is working." The ASCII-safe, no-personality pick; reads as sober and old-school. |
| **dqpb** | `d q p b` | 100 ms | **witty/typographic** — a single letterform rotating through its mirror/flip states. Reads as a designer's in-joke; playful without being cute. |
| **arc** | `◜◠◝◞◡◟` | 100 ms | **soft, light, calm** — a thin arc orbiting; airier than the dense braille whirl. |
| **circleHalves** | `◐◓◑◒` | 50 ms (~20 fps) | **fast, hypnotic, toy-like** — a filled half-disc spinning near the flicker threshold; energetic, almost frantic. |
| **bouncingBar** | `[= ]`→`[====]`→`[ =]` | 80 ms | **engineered, contained** — motion boxed inside brackets; reads like a VU meter or a scanning instrument. |
| **aesthetic** | `▰▱▱▱▱▱▱`→`▰▰▰▰▰▰▰` | 80 ms | **progress-flavored ambient** — a bar that fills then resets; feels like "loading" even though it's indeterminate. |
| **point** | `∙∙∙ ●∙∙ ∙●∙ ∙∙●` | 125 ms | **gentle, minimal, patient** — a single dot walking; the calmest legible motion. |
| **toggle** | `⊶ ⊷` | **250 ms** | **slow, deliberate, almost sleepy** — two frames at a quarter-second read as a slow blink, not a spin. Restraint as tone. |
| **moon** | `🌑🌒🌓🌔🌕🌖🌗🌘` | 80 ms | **whimsical, cosmic, cute** — an emoji phase-cycle; unmistakably "this app wants to charm you." |
| **earth** | `🌍🌎🌏` | 180 ms | **playful, global, toy** — three-frame spinning planet; reads as friendly consumer software. |
| **clock** | `🕛🕐🕑…🕚` | 100 ms | **literal, patient, honest** — a ticking clock face saying "time is passing," a small joke about the wait itself. |
| **material** | 92 frames of `█▁` block flows | **17 ms** (~60 fps) | **hyper-smooth, engineered, expensive** — a 92-frame indeterminate bar at near-video framerate; the most "we built a real animation system" flex in the catalog. |
| **bouncingBall** | `( ●    )`→`(●     )` | 80 ms | **kinetic, physical, playful** — Pong physics inside parentheses; suggests a lightweight, fun tool. |
| **grenade / weather / runner / christmas** | narrative emoji sequences | 80–400 ms | **maximum whimsy / seasonal delight** — the "we do not take ourselves seriously" end of the dial. |

**The governing law — same wait, different feeling.** Charm's docs state it precisely: because a functional-render TUI makes redraw free, *"the spinner choice is pure characterization — same wait, different feeling."* The wait is identical; the spinner is the entire message. ([bubbles/spinner](https://github.com/charmbracelet/bubbles/blob/master/spinner/spinner.go))

### 2.1 Interval as tempo — the 80 ms / 130 ms / 250 ms register

The frame interval is a knob most people never touch, and it changes the *emotional register* more than the glyph does:

- **≤ 50 ms (≥ 20 fps)** → **snappy, urgent, almost anxious.** The motion is at or past the persistence-of-vision threshold; it reads as a machine working *hard*. `material` (17 ms) and `circleHalves` (50 ms) live here.
- **~80 ms (~12 fps)** → **the sweet spot: brisk but calm.** This is the braille `dots` default and Charm's 12-fps recommendation — fast enough to read as active, slow enough to read as composed. The industry consensus "working, unhurried."
- **~130 ms (~8 fps)** → **mechanical, deliberate.** The ASCII `line` spinner's cadence; each frame is individually perceptible, so it reads as a *clunk-clunk* machine rather than a smooth flow.
- **~250 ms+ (≤ 4 fps)** → **calm-heartbeat / breathing.** At this tempo motion stops reading as "spinning" and starts reading as *pulsing* — a resting vital sign. `toggle` (250 ms) and every breathing dim-bright loop (§7) live here. This is the tempo of *serenity*.

The same braille glyphs at 80 ms read "snappy/mechanical"; slowed toward 200 ms they read "calm-heartbeat." **Tempo is the difference between a machine hurrying and a mind resting.**

---

## 3. The whimsical verb — the coding-agent signature move

The single most distinctive aesthetic invention of the coding-agent era is not a glyph at all. It is the **present-participle gerund cycling beside the spinner** — Claude Code's `✻ Divining…`, `✻ Percolating…`, `✻ Cogitating…`. With no font, no illustration, and no sound, the agent carries its entire personality in *word choice at the moment of waiting.*

Claude Code ships **187 baked-in gerunds** (leaked and catalogued by the community), shown in `secondaryText` grey beside live instrumentation:

```
✻ Cogitating… (12s · ↑ 2.3k tokens · esc to interrupt)
```

The vocabulary is deliberately literary and cross-register — the community-built dictionaries sort it into **Culinary** (Brewing, Marinating, Simmering, Fermenting, Percolating — *patience reframed as cooking*), **Cerebral** (Divining, Elucidating, Perusing, Cogitating), **Kinetic**, and **Whimsical** (Booping, Canoodling, Dilly-dallying, Flibbertigibbeting, Tomfoolering). ([187 verbs — DeepakNess](https://deepakness.com/raw/claude-spinner-verbs/) · [spinner-verbs-dictionary, 191 entries w/ IPA](https://github.com/claude-code-book/spinner-verbs-dictionary))

**Technique → feeling:**
- **A rotating literate gerund instead of "Loading…"** → *warmth, wit, and a mind at work.* "Loading…" says *a process is running*; "Percolating…" says *a personality is thinking, and it finds this amusing.* The wait is reframed from a system delay into a character beat. It humanizes latency — the model isn't stalling, it's *marinating*.
- **Present-continuous / ellipsis-terminated** (`Thinking…`, `Divining…`) → *in-progress, unhurried, ongoing.* The `-ing` + `…` is grammatically the tense of "still happening," which is exactly the reassurance a waiting user needs. Grok Build uses the same grammar in a soberer key: `Thinking…`, `Responding…`, `Verifying…`, `Waiting on subagent…` — every label ellipsis-terminated to signal "in-progress, unhurried."
- **Randomized selection per turn** → *liveliness, non-repetition.* Because the verb changes each turn, the app never feels like a looping animation; it feels like it has moods.

**The contest is itself evidence of the stakes.** The verbs are polarizing: a GitHub bug report (#23430) calls them "unprofessional and dismissive"; a feature request (#27976) asks to disable them; the community answered by building 3,000+ verb packs across 106 themed categories. Anthropic's response was to make them **customizable, not removable** — keeping whimsy as the *default personality* while letting the buttoned-up opt out. That so much heat gathers around a single grey word is proof of how much identity the waiting-verb carries. ([wynandw87/claude-code-spinner-verbs](https://github.com/wynandw87/claude-code-spinner-verbs) · [Miessler on customizing](https://danielmiessler.com/blog/customized-spinner-verbs-in-claude-code))

---

## 4. The instrumentation cluster — elapsed timers, token & cost meters

Beside (or instead of) the whimsical verb sits the opposite personality pole: **honest numeric instrumentation.** Claude Code's `(12s · ↑ 2.3k tokens · esc to interrupt)` and Grok's `⠧ Responding… 0.2s … 1m20s ⇣12k [stop]` both tick live during the wait.

**Technique → feeling:**
- **A live-incrementing elapsed-second counter** (`12s`, `1m20s`) → *honest reassurance, mission-control.* A rising number is proof the process is alive and proof of respect for your time — it says "I know you're waiting and I'm not hiding the cost." It converts anxious ambiguity ("is it stuck?") into legible progress. The clock is the anti-anxiety device.
- **A token meter ticking up** (`↑ 2.3k tokens`, `⇣12k`) → *transparent instrumentation, "the engine gauge."* Watching tokens accumulate is watching the machine breathe. It reads as engineering honesty — the same impulse as aider's blunt cost footer `$0.0042 1,234 tokens total`, which this dossier's aider entry nicknames the **"taxi-meter"** ("money and tokens stated bluntly… honesty as identity").
- **Fixed-width numeric formatting** (`8.5K / 1.0M`, `42.0%`) → *instrument-gauge stability.* Grok pads its numbers so the readout "never jitters its width" — a gauge that stays still while its value changes reads as precision hardware, where a reflowing number reads as flimsy.
- **A gentle interrupt affordance** (`esc to interrupt`, `[stop]`) → *calm control.* Lowercase, un-alarming, always present. It says "you're in charge, no panic required."

**The two poles.** The whimsical verb (§3) and the instrumentation cluster (§4) are the two personalities a waiting state can wear — *literate companion* vs *honest machine* — and the strongest designs (Claude Code) wear **both at once**: a playful gerund carrying an honest meter. Warmth and transparency are not in tension; the verb makes you smile while the numbers make you trust.

---

## 5. Streaming-token reveal — the cadence of a thought appearing

Once the model starts producing, the waiting state hands off to the **stream**, and the *rhythm of reveal* is its own major aesthetic axis — arguably the most emotionally loaded one, because it is the closest a TUI gets to watching something think out loud.

**The perception fact that makes this matter:** users perceive streaming interfaces as **~40% faster than buffered responses even when total time is identical**, and the incremental reveal "creates a sense of the AI *thinking*, which paradoxically increases trust." The stream is not just faster-feeling; it reads as *alive.* ([Streaming AI Responses — Chanl](https://www.channel.tel/blog/streaming-ai-responses-sse-websockets-real-time) · [Complete Guide to Streaming LLM Responses](https://dev.to/pockit_tools/the-complete-guide-to-streaming-llm-responses-in-web-applications-from-sse-to-real-time-ui-3534))

**Technique → feeling, by cadence:**
- **Character-by-character reveal (teletype)** → *alive, present, intimate, a thought forming.* The purest typewriter feel — you watch each glyph land as if a mind were committing it. Maximum "conversational presence," the strongest anti-machine signal.
- **Chunked / word-by-word reveal** → *natural, readable, ChatGPT-native.* Word-granularity is "the most similar to the one used by ChatGPT"; it preserves the alive feeling while avoiding the jitter of raw token boundaries (which split mid-word and read as glitchy).
- **Line-buffered reveal** → *composed, editorial, calmer.* Holding until a full line resolves trades intimacy for steadiness; reads as "considered prose" rather than "live thinking." Good for code, where mid-line reflow is ugly.
- **Instant paste (no stream)** → *cold, machine, transactional.* A block of text materializing at once reads as a database dump. It is the single fastest way to make an agent feel like a tool instead of a collaborator. The absence of stream is a *choice* that signals "I am software, not a voice."

**The decoupling craft — buffer then flush.** The professional move is to *not* repaint on every token: buffer the incoming stream and flush to the UI on a fixed timer (~0.1 s), "which decouples the network stream from UI rendering and guarantees smooth framerates." Raw token-rate rendering stutters (tokens arrive in bursts); a metered flush makes the reveal read as a *steady, deliberate hand* rather than a stuttering wire. **Smoothness of cadence, not speed, is what reads as composure.** ([Enhancing AI Apps with Streaming — Focused](https://focused.io/lab/enhancing-ai-apps-with-streaming))

**Cursor-follows-stream.** When the terminal cursor (or a synthetic block/underscore) trails the last streamed character, the effect is a live pen-tip — the eye is led along the forming text. Its presence reads as *handwriting in progress*; its absence reads as *text arriving from elsewhere.*

**Reveal-then-freeze.** Claude Code and aider both stream markdown *live* then swap to a **static, fully-rendered** version once the message completes (Claude freezes finished subtrees; aider runs a "live window over stable scrollback" that adapts its FPS to render cost). **Feeling:** *the page settles.* Live turns shimmer and reflow; finished turns become calm, permanent, re-readable prose. The transition from motion→stillness is itself the punctuation that says "this thought is done."

**Redraw discipline as felt quality.** Grok Build enforces ghost-free streaming with named PTY tests (`wheel_flood_paints_no_ghost_frames`, `…does_not_teleport_viewport`); Claude Code enables *synchronized terminal output* under tmux so "text never tears." Tearing, ghosting, and viewport-jump during a stream read as *cheapness and instability*; atomic redraw reads as *solidity*. Jank is treated as a bug against the feel, not just against correctness.

---

## 6. Progress bars — determinate precision vs indeterminate motion

When the agent *can* quantify work (files scanned, tests run, a streaming edit filling in), the bar replaces the spinner and the vocabulary shifts from "alive" to **"engineered/precise."**

**Technique → feeling:**
- **Block-ramp fill `█████░░░░░`** → *solid, engineered, honest.* Full/empty block cells are the terminal's most literal quantity display; the hard boundary between filled and empty reads as *measured precision.* aider renders a streaming-edit progress bar in this same block vocabulary "inside the diff stream, so you watch the patch fill in" — the industrial block-glyph material tying spinner, bar, and fill into one coherent look.
- **Sub-cell / gradient fill** (partial blocks `▏▎▍▌▋▊▉`, or braille sub-cell progress) → *high-resolution, refined.* Using the eighth-block glyphs to render fractional cells gives 8× the horizontal resolution of whole blocks — the bar moves *smoothly* instead of jumping a full cell at a time. Reads as "this was built with care." Rich/Textuale ship exactly this "flicker-free animated progress" as part of their "delight" surface.
- **Indeterminate barber-pole / scanning bar** (`bouncingBar`, aider's back-and-forth scanner) → *searching, diagnostic, actively hunting.* When there's no known total, a marker sweeping a fixed track reads as *scanning* rather than *filling.* aider's signature 18-frame bright-head/dim-tail scanner is explicitly "diagnostic — searching," not the generic rotating whirl; the two-cell marker (bright leading cell, dim trailing) fakes motion-blur so the sweep reads as a physical probe.
- **The `material` 92-frame flow** → *hyper-engineered ambient.* At 60 fps it's the most "real animation engine" a terminal bar can look like — impressive, slightly showy, reads as "serious tooling."

**Determinate vs indeterminate is a truth-claim.** A determinate bar *promises* it knows how much is left; using one when you don't (a bar that hangs at 90%) reads as a *lie* and poisons trust. An honest indeterminate scanner ("I'm working but can't estimate") is more sincere than a fake-precise fill. The choice encodes how honest the tool is about its own uncertainty.

---

## 7. Breathing, shimmer, and the pulse register

Between "spinning" (rotation) and "filling" (progress) lies a third motion family: **the pulse** — a status word or block that brightens and dims on a slow loop. This is the terminal's answer to the web shimmer, and it reads as *calm aliveness* rather than *busy work.*

**Technique → feeling:**
- **Dim→bright→dim opacity loop on a status word** (`Thinking…` fading between `secondaryText` and `text`) → *breathing, serene, a resting vital sign.* At ~250 ms+ per cycle this reads as inhale/exhale, not as a spinner. It says "alive and unhurried" where a fast spin says "busy." The lowest-anxiety possible "I'm working" signal.
- **Spatial brightness wave down rows** — Grok Build's `wave_brightness = sin²(t + phase)` ripples brightness *down the rows* of a running block "so a long running block shimmers top-to-bottom rather than pulsing as one flat slab." → *organic, liquid, alive.* A single flat pulse reads mechanical; a wave with a phase gradient reads like breath moving through a body. This is the terminal shimmer, mathematically specified.
- **Speed-encoded urgency (two-cadence motion)** — Grok runs its *active* turn spinner at ~7.5 fps (busy braille whirl) and its *idle* monitor pulse at ~3.75 fps (`○◎◉◎`), because "the idle watching cue should breathe calmly rather than read like the active turn spinner… roughly half the speed." → *a motion grammar where tempo means state.* Foreground urgency and background calm are encoded purely in frame-rate. Fast = "acting now," slow = "watching, ready."
- **Skeleton placeholders** (dim `░`/grey block rectangles where streamed content will land, optionally with a shimmer sweeping across) → *anticipation, structure-before-content.* Rare in terminal agents but native to the medium; it says "the shape of the answer is already known, the words are arriving." Perceived as faster than a spinner because the layout is already committed.
- **The metallic shine sweep** — Grok's startup logo runs a raised-cosine highlight band sweeping bottom-left→top-right across the braille glyphs (`SWEEP_FRAC = 0.32`, ~1.3 s glint then rest). → *glossy, premium, specular.* "The closest a TUI gets to a glossy button" — a fake highlight raking across a machined surface. Applied to a *logo* at boot it reads as brand polish; the same technique on a status word would read as luxury.

---

## 8. The austere pole — spinner absence as a statement

Not every agent animates. A **still "thinking" word with no motion at all** is a deliberate aesthetic choice, and it is the strongest possible signal of a certain kind of seriousness.

**Technique → feeling:**
- **A static status word, no spinner** (`Thinking` sitting motionless) → *sober, austere, confident, unshowy.* It refuses the entertainment of motion. It says "I don't need to reassure you with a dancing glyph; I'll be done when I'm done." Reads as senior, minimal, almost severe — the terminal equivalent of a plain typeface with no animation.
- **Motion only on real waiting, erased without a trace** — aider shows its scanner *only* while genuinely blocked, redraws in place with `\r` (never a newline), and when done "the scanner erases itself without a trace; the green `>` returns; nothing remains." → *restraint reads as polish.* Ephemeral motion + permanent text is a discipline: the animation is a courtesy during the wait, not a monument. The transcript stays clean.
- **The single quiet glyph** — Claude Code's `✻ Thinking…` in grey **italic** dims and *leans* the brand mark when the model is "in its own head." A minimal tilt carries the whole introspective register without a full animation. → *quiet interiority.*

Absence is not the failure to animate; it is a claim that the work speaks for itself. The austere pole and the whimsical pole (§3) are the two ends of the character dial — *"I am a serious instrument"* vs *"I am a delightful companion"* — and where an agent sits between them is most legible in exactly this moment of the pause.

---

## 9. Four agents, four waiting-state personalities

The same problem — "show the model is working" — is solved four ways, and each choice is a self-portrait.

- **Claude Code — the literate companion.** A clay-orange asterisk `✻` that *blooms* (`· → ✢ → ✳ → ∗ → ✻ → ✽`, an organic growth, not a rotation) beside a randomized whimsical gerund and an honest `(12s · ↑ 2.3k tokens · esc to interrupt)` meter, streamed inline into native scrollback, then frozen to calm static markdown. **Signals:** warm, witty, transparent, a colleague thinking out loud. Whimsy *and* honesty at once.
- **aider — the diagnostic craftsman.** A pre-rendered 18-frame bright-head/dim-tail **scanner** that bounces (not spins), shown only during real waiting and erased without a trace, over an adaptive-FPS live-window stream, closed by a blunt taxi-meter cost line. **Signals:** austere, industrial, honest-to-a-fault, motion-as-tool-not-decoration.
- **Gemini CLI — the branded consumer product.** A standard braille `dots` spinner whose *glyph is generic but whose color cycles through Google's entire brand wheel* (purple→blue→cyan→green→yellow→red) on a 4-second loop at ~33 fps, over an Ink/React live-reflowing document, with December snow over the logo. **Signals:** alive, patient, on-brand, playful — the wait turned into ambient brand animation. Cheerful big-tech polish.
- **Grok Build — the mission-control cockpit.** A **two-cadence** system: a busy braille whirl `⠋⠙⠹` at ~7.5 fps for the active turn, a calm `○◎◉◉` pulse at ~3.75 fps for idle/background agents, magenta pilot-light accent, `sin²` brightness waves down running blocks, a `⠧ Responding… 0.2s … 1m20s ⇣12k [stop]` status line with fixed-width numerics, all ghost-free by test-enforced redraw discipline. **Signals:** industrial, precise, instrument-panel, *you are operating an autonomous machine.*

The spread is the whole thesis: **identical latency, four irreconcilable personalities, expressed almost entirely in the pause.**

---

## 10. Vibe words

`alive` · `breathing` · `patient` · `honest` · `whimsical` · `mechanical` · `diagnostic` · `serene` · `snappy` · `austere`

---

## 11. Technique → feeling table (condensed)

| Technique | Feeling produced |
|---|---|
| Braille `dots ⠋⠙⠹` at 80 ms | smooth, refined, quietly premium (the "serious but designed" default) |
| ASCII `line - \ \| /` at 130 ms | utilitarian, mechanical, sober, old-school |
| `moon`/`earth`/`clock` emoji cycles | whimsical, cute, consumer-friendly, toy-like |
| `material` 92 frames at 17 ms (~60 fps) | hyper-smooth, engineered, showy "real animation engine" |
| Interval ≤ 50 ms | urgent, anxious, working-hard |
| Interval ~80 ms | brisk-but-calm sweet spot ("working, unhurried") |
| Interval ≥ 250 ms | calm-heartbeat; motion becomes a resting pulse, not a spin |
| Rotating whimsical gerund (`Percolating…`) | warm, literate, playful; latency reframed as personality |
| Present-continuous + ellipsis (`Thinking…`) | in-progress, unhurried, ongoing, reassuring |
| Live elapsed-second counter | honest reassurance; anti-anxiety proof-of-life |
| Ticking token/cost meter, fixed-width | transparent instrumentation, mission-control, taxi-meter honesty |
| Char-by-char stream reveal (teletype) | alive, present, intimate — a thought forming |
| Word-chunked stream (buffered flush ~0.1 s) | natural, composed, ChatGPT-native; steady hand |
| Instant paste, no stream | cold, machine, transactional — "software, not a voice" |
| Cursor-follows-stream | live pen-tip; handwriting in progress |
| Stream-then-freeze to static | the page settles; live shimmer → permanent prose |
| Block-ramp progress `█████░░░░░` | solid, engineered, measured precision |
| Sub-cell/braille fractional fill | high-resolution, refined, careful |
| Indeterminate barber-pole / scanner | searching, diagnostic, honest about not-knowing |
| Breathing dim→bright opacity loop | serene, alive, lowest-anxiety "I'm working" |
| `sin²` brightness wave down rows | organic, liquid, breath moving through a body |
| Two-cadence motion (fast active / slow idle) | tempo-as-state grammar; urgency vs calm encoded in fps |
| Metallic shine sweep on logo | glossy, premium, specular — the TUI "glossy button" |
| Skeleton/shimmer placeholder | anticipation; structure-before-content, feels faster |
| Spinner *absence* (static word) | sober, austere, confident, unshowy |
| Motion erased without a trace (`\r`, clean transcript) | restraint-as-polish; courtesy not monument |

---

## 12. Recommendations for a coding-agent harness's thinking/streaming state

Concrete, opinionated, ranked. The waiting state is the app's face — author it deliberately.

1. **Default to braille `dots` at ~80 ms, but make the spinner a theme token.** It is the "serious but designed" baseline. Expose glyph-set + interval as config so a project can dial toward whimsy (`moon`) or austerity (static word) without touching code. Same wait, different feeling — let the user pick the feeling.
2. **Pair the spinner with BOTH a verb AND a meter.** This is Claude Code's winning combination: a rotating present-continuous gerund (warmth) *and* a live `elapsed · tokens · esc-to-interrupt` cluster (honesty). Warmth and transparency are not in tension. Ship a small default verb list, make it swappable, and make the "boring mode" (`Thinking…` only) a one-flag opt-out — the community *will* fight about the verbs, so give them the switch up front.
3. **Ellipsis-terminate every status label** (`Thinking…`, `Running tests…`, `Waiting on subagent…`). Free grammatical signal that work is ongoing and unhurried.
4. **Stream tokens; never instant-paste.** Buffer the wire and flush on a ~0.1 s timer for a steady cadence — smoothness reads as composure, raw token-rate reads as jitter. Word-granularity avoids mid-word glitch. The 40%-faster perception is real and free.
5. **Stream-then-freeze.** Render live (streaming, possibly reflowing) then swap the completed turn to a static, fully-rendered block. The motion→stillness transition is the punctuation that says "done." Keep off-screen finished turns frozen so an upstream spinner never repaints the viewport.
6. **Enforce redraw hygiene as a felt quality, with tests.** Synchronized/atomic output, no tearing, no ghost frames, no viewport-teleport under input floods. Jank is a bug against character, not just correctness — write the PTY tests Grok writes.
7. **Encode state in tempo, not just glyph.** If you have foreground vs background work (subagents, parallel tasks), run the active indicator fast (~7.5 fps) and the idle/watching one slow (~3.75 fps breathing pulse). Users learn the grammar in seconds: fast = acting, slow = ready.
8. **Be honest about determinacy.** Use a determinate block-bar *only* when you truly know the total; otherwise use an indeterminate scanner. A bar stuck at 90% reads as a lie and poisons trust more than an honest "still working."
9. **Make motion ephemeral, text permanent.** Redraw the spinner in place (`\r`, width-matched frames so layout never shifts) and erase it cleanly when done. The transcript that remains should be pure prose — the animation was a courtesy, not a monument.
10. **Decide where you sit on the whimsy↔austerity dial, and commit.** The pause is where that decision is most visible. A blooming asterisk with a `Flibbertigibbeting…` verb and a color-cycling planet are all valid; so is a single motionless grey `Thinking`. What is *not* valid is an undifferentiated default `ora` import — that is the one choice that says nothing, in the one place the user looks the longest.

---

## Sources

- `cli-spinners/spinners.json` (read byte-exact, 90 spinners) — https://github.com/sindresorhus/cli-spinners/blob/main/spinners.json
- cli-spinners readme (braille-counter origin, intervals) — https://github.com/sindresorhus/cli-spinners/blob/main/readme.md
- sindresorhus/ora ("Elegant terminal spinner," default `dots`) — https://github.com/sindresorhus/ora
- charmbracelet/bubbles spinner catalog ("same wait, different feeling") — https://github.com/charmbracelet/bubbles/blob/master/spinner/spinner.go
- Throbber history (Mosaic/Netscape "N") — https://en.wikipedia.org/wiki/Throbber
- Skeleton screens & shimmer (Wroblewski 2013, Facebook wave) — https://uxdesign.cc/what-you-should-know-about-skeleton-screens-a820c45a571a
- Streaming perception "~40% faster," "sense of thinking increases trust" — https://www.channel.tel/blog/streaming-ai-responses-sse-websockets-real-time
- Complete Guide to Streaming LLM Responses (SSE, buffer-and-flush) — https://dev.to/pockit_tools/the-complete-guide-to-streaming-llm-responses-in-web-applications-from-sse-to-real-time-ui-3534
- Enhancing AI Apps with Streaming (decouple stream from render, timed flush) — https://focused.io/lab/enhancing-ai-apps-with-streaming
- Streaming text with TypeIt (typewriter cadence) — https://macarthur.me/posts/streaming-text-with-typeit/
- Claude Code 187 spinner verbs (leaked) — https://deepakness.com/raw/claude-spinner-verbs/
- spinner-verbs-dictionary (191 entries, IPA, categories) — https://github.com/claude-code-book/spinner-verbs-dictionary
- claude-code-spinner-verbs (3,000+ across 106 categories) — https://github.com/wynandw87/claude-code-spinner-verbs
- Customizing Claude Code spinner verbs — https://danielmiessler.com/blog/customized-spinner-verbs-in-claude-code
- Sibling dossiers (waiting-state passages): `app-claude-code.md`, `app-aider.md`, `app-gemini-cli.md`, `app-xai-grok-build-grok-cli-tui.md`, `lib-charm-ecosystem-*.md`, `lib-textual-rich-textualize-python.md`
