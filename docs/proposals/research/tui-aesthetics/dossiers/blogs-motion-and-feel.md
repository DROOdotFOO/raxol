# Dossier: Motion and Feel in Terminals

**Slug:** `blogs-motion-and-feel`
**Scope:** How motion, timing, and cadence produce *character* in a medium with no CSS transitions, no easing curves, no compositor. Spinner design, progress-bar aesthetics, streaming-text cadence, spring easing (Harmonica), typewriter effects, cursor behavior, terminal recordings as marketing (asciinema, VHS), and perceived latency as a vibe.
**Mission framing:** Every claim below names a concrete technique AND the feeling it produces. Ergonomics is out of scope except where it doubles as an aesthetic device.

---

## 0. The core constraint (why motion is the ONLY feel-lever the terminal fully owns)

In a GUI, character comes from materials: gloss, shadow, radius, kerning, a hand-picked typeface, a spring-loaded sheet that slides up. Take all of that away and the terminal keeps exactly one thing the GUI also has: **time**. The grid is fixed, the font is the user's, color is quantized to 16/256/truecolor — but *when a cell changes, and to what, and how fast the next change follows* is fully under the app's control.

This is the central thesis of the whole dossier: **in the terminal, motion is not decoration layered on top of a static design — motion is a primary carrier of identity, because it is one of the few expressive channels the app is not sharing with the user's environment.** A spinner is a logo that only exists while it moves. Streaming cadence is a voice. Latency is body language.

The mechanical substrate is ancient and worth stating plainly, because it explains why terminal motion has its particular jittery, frame-swapped character rather than the continuous interpolation of a GPU compositor:

> "Movies, in their essence, are simply a collection of pictures stitched together, put in motion to give us the illusion of something happening in front of our eyes." — odino.org, *Command line spinners: the magic tale of modern typewriters and terminal movies*

> Spinners work by printing a character, sending a carriage return (`\r`) to move the cursor back, and printing the next character in the same position. The illusion is "just a very quick passing of images." — odino.org

**Technique → feeling.** The `\r` overwrite is inherited directly from the typewriter carriage return. So terminal animation is *literally* stop-motion on a fixed cell: no tweening, no sub-pixel motion, no anti-aliasing between frames. The vibe this produces at baseline is **mechanical, discrete, honest** — the medium cannot fake smoothness, so every apparent smoothness is an achievement of frame choice and timing. This is why terminal motion, done well, reads as *craft* rather than *default*: you are watching someone defeat the medium's natural stutter with nothing but a good frame sequence and a good interval.

---

## 1. Spinner design: the throbber as a brand mark

The canonical corpus is `sindresorhus/cli-spinners` — a `spinners.json` of **90 named spinners**, each `{interval, frames[]}`. It is the closest thing the terminal world has to a typeface catalog: a shared vocabulary of "moods you can drop into a wait." Downstream it powers `ora` (Node), `yacspin` / `briandowns/spinner` (Go, 90+), `bash-cli-spinners`, `CLISpinner` (Swift), and R's `cli::make_spinner`. Picking a spinner is the terminal-app equivalent of picking a loading animation *and* a bit of personality in one gesture.

### 1.1 The taxonomy (extracted from spinners.json, 90 total)

Grouping the corpus by the *glyph family* it draws from — because the glyph family, more than anything, sets the vibe:

| Family | Examples (name: interval ms) | Glyph mechanic | Vibe it produces |
|---|---|---|---|
| **Braille dots** | `dots` (80), `dots2` (80), many `dots3..14` | 8-dot braille cells cycled so a "hole" orbits the 2×4 matrix | The default *competent, modern, quiet* look. Sub-cell resolution makes it read as smooth despite being 8 frames. This is the "serious tool" spinner — used by npm-era JS tooling, reads as neutral professionalism. |
| **ASCII line** | `line` (130): `- \ | /` | The original 4-frame teletype throbber | *Retro, unixy, honest.* Instantly signals "this is a real terminal program, maybe old." Deliberately low-res; nostalgia device. |
| **Box-drawing** | `pipe` (100): `┤ ┘ ┴ └ ├ ┌ ┬ ┐`; `arc` (100): `◜◠◝◞◡◟`; `circle` (120) | Rotating box/arc glyphs | *Clean, geometric, architectural.* Feels drawn rather than typed; pairs with box-drawn UIs for a coherent "engineered" look. |
| **Bar fill / bounce** | `bouncingBar` (80) `[=== ]`; `bouncingBall` (80) `( ● )`; `pong` (80) | A token traverses a bracketed track and reverses | *Playful, physical, toy-like.* Implies a bounded space and a moving body — the eye tracks a "thing," which is warmer and more game-like than an abstract cycle. `pong` literally evokes an arcade. |
| **Block growth** | `growVertical` (120) `▁▃▄▅▆▇`; `growHorizontal`; `material` (**17ms!**) | Partial-block glyphs stack up | *Snappy, energetic, "loading bar in a single cell."* `material` at a 17ms interval (~60fps) is by far the fastest in the corpus — deliberately imitating Android's Material indeterminate bar. Fast interval = urgent, alive, premium. |
| **Aesthetic / wave** | `aesthetic` (80) `▰▱▱▱▱▱▱`; `betaWave` (80) `ρββββββ`; `arrow3` (120) `▹▸▹▹▹` | A filled marker sweeps across a row of empty markers | *Sleek, designed, "vaporwave."* The name `aesthetic` is a tell — this is the spinner you pick when you want the wait itself to look intentional and stylish. |
| **Emoji / pictorial** | `moon` (80) 🌑🌒🌓🌔; `earth` (180) 🌍🌎🌏; `clock` (100); `runner` (140) 🚶🏃; `weather`; `christmas` (400) 🌲🎄 | Semantic pictograms cycled | *Charming, human, brand-forward.* These carry the most personality per frame. `moon` phases feel calm and cosmic; `earth` spinning feels global/whimsical; `clock` literally says "time is passing." High risk (font-dependent width, misalignment) high reward (memorable). |
| **Novelty / narrative** | `shark` (120) `▐\|\____▌` → swims across; `grenade` (80); `dqpb` (100) `d q p b`; `balloon` (140) ` .oO@* ` | Tiny scene plays out in the track | *Winking, hacker-humor, "someone had fun here."* `shark` is a whole 2-second short film in one line — pure character, zero information. It exists to make you smile mid-wait. |

### 1.2 Interval as tempo — the single most important aesthetic dial

The `interval` field is the spinner's BPM, and it maps almost linearly to felt urgency:

- **~17ms (`material`)** → 60fps → **urgent, premium, "the CPU is pinned and working hard for you."** The smoothest thing the terminal can do.
- **70–80ms (`dots`, `star`, `aesthetic`, most braille)** → ~12fps → **the sweet spot: alive but calm, competent.** Fast enough to read as continuous, slow enough to read as effortless.
- **100–140ms (`line`, `arc`, `runner`)** → ~7–10fps → **relaxed, deliberate, slightly retro.** You can see individual frames; feels hand-cranked.
- **250–400ms (`toggle`, `simpleDots` `.  .. ...`, `christmas`)** → 2–4fps → **sleepy, patient, "this will take a while, settle in."** A slow blink says "background job," not "hot loop."

**The load-bearing insight from the corpus maintainers themselves:** speed is taste, and speed trades against information.

> "Some animations may look better at a different speed, so play around with the frequency until you find a value you find aesthetically pleasing." — cli-spinners README

> "Some spinners tie the ability to show updated messages to the spinner's animation, which can result in having to trade off animation aesthetics to show 'realtime' information." — cli-spinners ecosystem docs

That trade-off is itself an aesthetic fork: a *fast* spinner with rare message updates feels **energetic but opaque** ("trust me, working"); a *slow* spinner whose frames coincide with status-line updates feels **transparent, conversational, honest** ("here's exactly what I'm doing"). Charm/npm-era tools increasingly pick the latter — spinner-plus-live-substatus — because the vibe of *narrated* work reads as more trustworthy than a fast opaque throb.

### 1.3 Describe-the-screen: `dots` vs `line`

Picture the same 400ms wait rendered two ways. With `dots` (`⠋⠙⠹⠸⠼⠴⠦⠧`, 80ms), a single braille glyph sits before your status text and a dark void seems to *orbit* smoothly clockwise inside an invisible 2×4 grid — it looks like a tiny ball bearing spinning in oil, frictionless, expensive. With `line` (`- \ | /`, 130ms), a lone slash *snaps* through four positions — you can count them — clack, clack, clack, like a railway semaphore or a 1984 install script. Same job, same second of your life; one says "modern SaaS CLI," the other says "I SSH'd into a server and something real is happening." Neither is better. They are two different characters wearing the same wait.

---

## 2. Progress bars: the aesthetics of a filling rectangle

A progress bar is a spinner with an axis and a promise (it will end, and you can see how far). Its expressive dials:

- **Fill glyph.** Full/empty blocks `█░`, `█▁`, ASCII `#-` or `=·`, or the eighth-block ramp `▏▎▍▌▋▊▉█` for **sub-cell precision.** ASCII `#---` reads *sysadmin, portable, no-nonsense*; solid `██░░` reads *clean, modern*; the eighth-block ramp reads *premium/smooth* because it fakes fractional cells the grid shouldn't be able to show — the same "defeat the medium" flex as braille spinners.
- **Cap/leading edge.** A distinct head glyph (an arrow `>`, a bright cell, a spinner *riding the front* of the bar) turns a static fill into something with **momentum and a face.** The eye locks to the moving edge; the bar feels *driven* rather than *poured*.
- **Color gradient across the fill.** Truecolor lets the bar run a hue ramp (Charm's Bubbles progress does gradient fills). A green→cyan or pink→purple sweep along the completed portion reads as **designed, lush, contemporary** — it's the single biggest "this is a 2020s tool not a 1999 tool" signal a bar can send.
- **Spring-eased advance (see §3).** Whether the fill *jumps* to the new value or *glides* to it. Jump = mechanical/honest; glide = polished/alive.

**Technique → feeling summary:** ASCII hash bar = *trust through plainness*; solid block bar = *clean competence*; eighth-block + gradient + spring glide = *this product has a design team.* The information is identical; the character spans thirty years of computing.

---

## 3. Spring easing in the terminal: Charm Harmonica (the "no transitions" medium gets transitions anyway)

The terminal has no easing curves. Charm's **Harmonica** smuggles them in as a physics simulation you sample once per frame.

> "A simple, efficient spring animation library for smooth, natural motion" — harmonica README

> "A fairly straightforward port of Ryan Juckett's excellent damped simple harmonic oscillator originally written in C++ in 2008." — harmonica README

The lineage matters aesthetically: this is the *same* damped-spring math that powers iOS/Material motion, ported down onto the character grid. So a Bubble Tea progress bar can overshoot and settle exactly like a native mobile sheet — an unmistakably "app-like" feel achieved with monospace blocks.

The two knobs, and their feelings:

- **Angular frequency** — how fast it wants to move. Higher = **snappier, more eager.**
- **Damping ratio** — the character of arrival:
  > Under-damped (< 1): "overshoots and will continue to oscillate as its amplitude decays over time" → **bouncy, organic, playful, alive.**
  > Critical damping (= 1): "reach equilibrium as fast as possible without oscillating" → **crisp, efficient, decisive.**
  > Over-damped (> 1): "never oscillate, but reaches equilibrium at a slower rate" → **heavy, deliberate, weighty, serious.**

> "This physics-first approach explains why springs feel 'natural' — they model real-world oscillatory systems rather than artificial easing curves."

**Technique → feeling.** Under-damped spring on a progress bar that overshoots 100% and bounces back = *cute, toy-like, delightful* (great for a consumer CLI, wrong for a backup tool). Over-damped glide = *this is a serious operation, arriving with gravity.* The genius is that the terminal's per-frame redraw is *exactly* the sample loop a spring needs — the medium's stop-motion nature, which fights smoothness everywhere else, is a perfect fit for "evaluate spring, print current position, `\r`, repeat."

---

## 4. Streaming text cadence as personality (the LLM era's new expressive channel)

Before LLMs, terminal text mostly appeared all-at-once (a `printf`) or scrolled (a log). Streaming — printing token by token with `end="", flush=True` — turned the *rate of arrival of words* into a personality channel, and the ecosystem has explicit theory about it now.

### 4.1 Streaming feels faster than it is — and feels like *thinking*

> "The 'typewriter effect' creates a sense of the AI 'thinking,' which paradoxically increases trust, and users perceive streaming interfaces as 40% faster than buffered responses, even when total time is identical." — streaming-LLM UI guides (dev.to / muddyterrain)

This is the single richest technique→feeling mapping in modern terminal motion: **the same total latency, revealed incrementally instead of all at once, reads as (a) faster and (b) alive.** A buffered response that lands complete after 3s feels like a slow machine; the identical 3s streamed feels like a mind composing in real time. Cadence *manufactures* presence.

### 4.2 Cadence is content-dependent — the same tok/s is not the same feel

The `tokenspeed` toy (Mike Veerman) makes this visceral:

> Rates: 5 tok/s = "Raspberry-Pi-class local model"; 60 tok/s = "typical hosted Claude or GPT"; 800 tok/s = "Cerebras-class, where the bottleneck is your eyeballs."

> "The same speed feels slower" for code than prose. "English prose averages ~1.3 tokens per word, so 30 tok/s ≈ 23 words/s." Switching between code and text modes at the same rate produces "a striking" difference.

**Technique → feeling.** Slow stream (5–15 tok/s) = **labored, local, humble, "little engine trying"** — sometimes endearing, sometimes frustrating. Mid stream (~60 tok/s) = **conversational, natural reading pace, the "default modern assistant" cadence** — you read along with it, which produces companionship. Firehose (800 tok/s) = **superhuman, slightly overwhelming, "the bottleneck is you"** — impressive but you stop reading and start skimming; the intimacy of watching-it-think is lost. There is a *Goldilocks cadence for presence* right around human reading speed, and going faster is not strictly better — it trades wonder for throughput.

### 4.3 Chunk granularity is a voice

Character-by-character, word-by-word, and line-by-line reveals are three different personalities. The macarthur.me TypeIt writeup notes the word-by-word style "is the most similar to the one used by ChatGPT." Char-by-char = **intimate, suspenseful, retro-terminal** (you feel each keystroke); word-by-word = **natural, conversational, the current default of the assistant era**; line-by-line = **brisk, report-like, machine dictating results.** Flowtoken and peers now offer fade/blur-in per token — softening the hard cell-swap into something gentler, importing GUI polish into the stream.

---

## 5. The typewriter effect: suspense, retro, and hand-typed intimacy

Distinct from LLM streaming: the *deliberately paced* character reveal used in intros, splash text, and narrative CLIs. Rooted directly in the carriage-return mechanic of §0.

**Technique → feeling.** A fixed ~30–60ms/char reveal of a banner or prompt = **suspense and ceremony** (something is being *told* to you); a slightly randomized inter-character delay = **human, hand-typed, "a person is at the keyboard"** (constant timing reads as robotic; jittered timing reads as alive — the same principle that makes drum machines add "swing"). Add a trailing block cursor `█` that the text emerges from and you get the full **1983 BBS / hacker-movie** vibe: the screen is *addressing* you. This is almost pure character, near-zero information — which is exactly why it's reserved for first-impression moments (splash screens, onboarding, error dramatics) where identity matters more than speed.

---

## 6. The cursor as a heartbeat

The blinking block cursor is the terminal's idle animation — the one piece of motion present even when nothing is happening.

**Technique → feeling.** A **steady ~530ms blink** (the classic VT/terminal rate) reads as *calm, ready, waiting patiently* — a resting heartbeat. A **solid non-blinking block** reads as *focused, modal, "capturing input now."* A **bar/beam cursor** `|` reads as *modern, text-editor, GUI-adjacent*; a **block** `█` reads as *classic terminal, retro, whole-character presence*. Hiding the cursor during animation (a spinner, a redraw) and restoring it after is itself an aesthetic move: a visible cursor jittering inside a spinner reads as *broken/amateur*, while a cleanly hidden one reads as *someone tended this.* The cursor is small, but because it's the *only* motion during a pause, it disproportionately sets the app's resting mood.

---

## 7. Perceived latency as a vibe: snappiness = respect

Dan Luu's latency work is the intellectual backbone for treating *responsiveness itself* as an aesthetic — the terminal's version of "how solid does the door feel when it closes."

> "20ms feels fine, 50ms feels laggy, and 150ms feels unbearable" (VR framing, applied to input). — danluu.com/term-latency

> "Computers from the 70s and 80s commonly have keypress-to-screen-update latencies in the 30ms to 50ms range, whereas modern computers are often in the 100ms to 200ms range." — danluu.com/input-lag

> "I type at 120wpm ... 10 characters per second ... I'd expect to see the 99.9% tail (1 in 1000) every 100 seconds!" — danluu.com/term-latency (you *will* feel the tail)

> "The idea that computers respond quickly to input, so quickly that humans can't notice the latency, is the most common performance-related fallacy [Luu] hears from professional programmers."

**Technique → feeling.** Sub-frame echo of a keystroke to the screen = **snappy, respectful, "the machine is standing at attention for you."** This is a genuine aesthetic, not just ergonomics: a terminal app that echoes and repaints in <16ms *feels premium* the way a well-damped car door does — you can't name it, but you trust the whole product more. Conversely, 100ms+ input lag reads as **sluggish, disrespectful of your time, "this thing is thinking about itself, not about you."** The vibe axiom: **latency is the app's body language.** A snappy CLI is one that looks you in the eye; a laggy one keeps checking its phone. This is why Charm-era tools, alacritty, kitty, etc. treat frame budget as a *feature you can feel*, and why the felt difference between a 5ms-median terminal (terminal.app, emacs-eshell) and a laggy one is a difference in *character*, not just speed.

Corollary — **motion must never cost latency.** A spinner or animation that blocks input, or a redraw that stutters the whole screen, inverts its own purpose: the thing meant to say "alive and working" instead says "stuck." Smoothness of animation and snappiness of input are the same virtue (frame discipline) wearing two hats.

---

## 8. Terminal recordings as marketing: asciinema and Charm VHS

If motion is the terminal's identity channel, the *recording* is how that identity is broadcast. Two lineages, two philosophies, two vibes.

### 8.1 asciinema — the honest artifact

asciinema records the actual session as timed text (a `.cast` JSON of `[delay, "output"]` events), replayable as *selectable text*, not pixels. Vibe: **authentic, real, "this actually happened at my keyboard."** The preserved human timing — the pauses, the typos, the hesitations — reads as *documentary*. It's the terminal equivalent of a live-recorded demo: slightly rough, therefore credible. (To make a GIF you must pipe through `agg`; asciinema itself stays text-native.)

### 8.2 VHS — the directed film

Charm's VHS scripts a recording from a **`.tape` file** of `Type`, `Enter`, `Sleep` statements, rendered to GIF/MP4/WebM.

> "GIFs have long been the go-to in technical docs, capturing real-time terminal output and letting readers watch workflows unfold as if sitting beside you." — Anchore, *Tonight's Movie: The Terminal (of your laptop)*

> The craft goal: output "that looks pleasing (to me), doesn't distract from the tool being demonstrated, and doesn't visibly stutter." Themed with "BlexMono Nerd Font Mono" and "Catppuccin." — Anchore

> "It also allowed us to discuss the demos with interested conferencegoers without busting out a laptop and crouching around it. We just pointed to the screen as a terminal appeared and talked through it." — Anchore (the recording as *prop*)

**Technique → feeling.** Because VHS `Sleep` values are *authored*, the demo has **direction and rhythm** — deliberate pauses before the payoff, no fumbling, no typos, a controllable typing cadence. This reads as **polished, confident, cinematic, "brand."** The `Set Theme`, `Set FontSize`, `Set TypingSpeed` directives make the same commands render as a crisp social-media clip or a calm docs GIF. VHS *is* the Charm aesthetic weaponized: the pastel theme, the rounded-feeling padding, the unhurried keystroke rhythm — a whole company's personality compressed into a looping GIF at the top of a README.

The philosophical fork, stated by practitioners:

> VHS is "nicer than asciinema for many applications since you can avoid typos and fumbling, and can easily re-render recordings." — HN discussion

That "avoid typos and fumbling" is the exact axis: **asciinema = documentary realism (credible because imperfect); VHS = art-directed advertisement (compelling because perfect).** Choosing between them is choosing whether your tool's public motion-identity should feel *lived-in* or *designed.* The modern Charm-influenced norm leans hard toward VHS — the animated README GIF, timed to loop seamlessly, has become the single most important piece of TUI marketing, and its whole persuasive power is *motion the reader can watch unfold "as if sitting beside you."*

---

## 9. Synthesis: the grammar of terminal motion-as-character

Pulling every mapping into one structure — the concrete dials, and the feeling each end produces:

| Dial | One end → feeling | Other end → feeling |
|---|---|---|
| **Spinner glyph family** | ASCII `- \ | /` → retro/unix/honest | braille/gradient/emoji → modern/premium/charming |
| **Spinner interval** | 17ms → urgent, premium, pinned-CPU | 400ms → sleepy, patient, background |
| **Progress fill** | ASCII `#--` → portable, plain, trustworthy | eighth-block + truecolor gradient → designed, lush |
| **Progress edge** | flat fill → poured, static | leading cap/rider → momentum, driven, alive |
| **Spring damping** | over-damped → heavy, serious, deliberate | under-damped → bouncy, playful, delightful |
| **Stream cadence** | 5 tok/s → labored, humble, local | 800 tok/s → superhuman, overwhelming |
| **Stream chunk** | char-by-char → intimate, suspenseful | line-by-line → brisk, report-like |
| **Typing jitter** | constant delay → robotic | randomized delay → human, hand-typed |
| **Cursor** | blinking block → calm heartbeat, ready | hidden/solid → focused, modal, tended |
| **Input latency** | <16ms → snappy, respectful, premium | 150ms+ → sluggish, disrespectful, absent |
| **Recording** | asciinema → documentary, credible, real | VHS → cinematic, art-directed, brand |

**The three meta-principles that recur across every technique:**

1. **Defeat the medium's stutter and it reads as craft.** Braille sub-cell spinners, eighth-block gradient bars, spring easing sampled per frame — every one takes the terminal's discrete stop-motion nature and produces apparent smoothness. The achievement *is* the aesthetic; users read "smooth in a place that shouldn't be smooth" as "someone cared."
2. **Timing manufactures presence and respect.** Streaming feels 40% faster and alive; snappy echo feels respectful; jittered typing feels human; a slow patient blink feels calm. None of this adds information — it adds *character*, and character in the terminal is almost entirely a function of *when*, not *what*.
3. **Motion is the identity channel the app doesn't share.** Font, size, color depth, and window chrome belong to the user's terminal. The *choreography* — which glyph, which interval, which damping, which cadence — belongs wholly to the app. So the terminal app that wants a face grows one out of motion, because motion is the one canvas the environment can't repaint.

---

## Sources

- odino.org — *Command line spinners: the magic tale of modern typewriters and terminal movies* — https://odino.org/command-line-spinners-the-amazing-tale-of-modern-typewriters-and-digital-movies/
- sindresorhus/cli-spinners (spinners.json, 90 spinners, interval+frames) — https://github.com/sindresorhus/cli-spinners
- charmbracelet/harmonica (spring/damped-harmonic-oscillator, Ryan Juckett lineage) — https://github.com/charmbracelet/harmonica
- charmbracelet/bubbles (progress meter with Harmonica animation) — https://github.com/charmbracelet/bubbles
- charmbracelet/vhs (`.tape` scripted terminal GIFs) — https://github.com/charmbracelet/vhs
- Charm blog — *VHS GIF Hosting!* — https://charm.land/blog/vhs-publish/
- Anchore — *Tonight's Movie: The Terminal (of your laptop)* (VHS as demo/marketing craft) — https://anchore.com/blog/tonights-movie-the-terminal-of-your-laptop/
- HN — *VHS: CLI home video recorder* (asciinema vs VHS, "avoid typos and fumbling") — https://news.ycombinator.com/item?id=33357956
- Dan Luu — *Terminal latency* — https://danluu.com/term-latency/
- Dan Luu — *Computer latency: 1977-2017* — https://danluu.com/input-lag/
- Dan Luu — *Keyboard latency* — https://danluu.com/keyboard-latency/
- Alex MacArthur — *Streaming Text Like an LLM with TypeIt (and React)* (word-by-word = ChatGPT-like) — https://macarthur.me/posts/streaming-text-with-typeit/
- Mike Veerman — *tokenspeed* (feel of 5 / 60 / 800 tok/s; code vs prose cadence) — https://mikeveerman.github.io/tokenspeed/
- muddyterrain — *The 'Typewriter Effect': Optimizing UI for Streaming LLMs* (streaming feels ~40% faster, "thinking" = trust) — https://muddyterrain.com/blog/optimize-ui-streaming-llm-unreal-engine
- Ephibbs/flowtoken (fade/blur-in/typewriter per-token stream animations) — https://github.com/Ephibbs/flowtoken
