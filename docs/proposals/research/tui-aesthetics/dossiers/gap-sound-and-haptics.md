# Aesthetic Dossier — Sound, Bell & Non-Visual Feedback (GAP dossier)

**Category:** Cross-cutting *modality* — the audio / haptic / non-visual channel of terminal UX (not an app; a dimension every app inherits and almost every rice setup silences)
**Scope:** the ASCII BEL (`\a` / 0x07) and its cultural baggage · visual-bell substitutes · task-completion chimes & custom sounds · silence-as-a-deliberate-aesthetic · OSC 9 / OSC 777 / OSC 99 desktop notifications · tmux/kitty activity & bell markers · data/log **sonification** · modem/BBS connect-sound nostalgia · mobile-terminal **haptics** (Termux, a-Shell, Blink) · watch-surface buzz.
**Why this dossier exists:** the modality is essentially *unrepresented* in the dossier set — only Zellij appears incidentally, and only for turning the bell into "a color pulse, not a beep" (see `app-zellij.md` §5). For a long-running coding agent, the moment it **finishes a task in a background terminal** is a canonical identity beat, and it is carried almost entirely by *sound* (or its deliberate absence). This is the one channel that reaches you when your eyes are on another window.
**Researched from:** terminal-bell history (Wikipedia, anarcat), tmux/kitty/screen bell & notification docs, r/commandline & practitioner blogs on completion chimes, Claude Code stop-hook write-ups, data-sonification literature, Termux bell/vibrate issues, BBS/modem nostalgia sources. Full list at the end.

---

## 0. One-sentence identity

Sound is the terminal's **off-screen channel** — the only device it has to reach past the character grid into the room — and its entire aesthetic history is a pendulum between one harsh default (the 0x07 beep that everyone born after 1995 associates with *error*) and the many quiet, warm, or ceremonial substitutes people build to replace it: a soft glass chime on `done`, a screen-flash instead of a screech, a phone buzz in your pocket, or the loudest statement of all — **deliberate silence**.

The thesis of the whole modality: **on a monospace grid, timbre is the one dimension you cannot draw.** Everything else — color, box glyphs, motion — lives inside the rectangle. Sound is the only feedback that works when the rectangle isn't being looked at. That makes it the highest-stakes, most-personality-laden, and most-often-muted channel in the terminal.

---

## 1. Vibe words

`jarring` · `retro/DOS-era` · `attention-yank` · `calm-substitute` · `ceremony` · `satisfying-closure` · `sober/monastic` · `ambient-presence` · `sci-fi/instrument` · `scene-nostalgia` · `embodied/tactile`

---

## 2. The ASCII BEL — anatomy of the most hated byte in the terminal

**The byte:** decimal `7`, hex `0x07`, C escape `\a` (the `a` is for *alert / audible* — `\b` was already taken by backspace, per C's 1972 escape table), keyboard `Ctrl-G`, caret notation `^G`. You can ring it from a shell with `printf '\a'` or `echo -e '\a'`.

**The lineage** (this history *is* the vibe): BEL predates ASCII. It rode in on **Baudot code in the 1870s** (figures-shift #11 / 0x0B) to ring a literal electromechanical bell on telegraph tickers and teleprinters so a human operator would look up. The **Teletype Model 33** carried the metaphor into the computer age with an actual bell inside the chassis: when code 7 arrived, a **solenoid struck a physical bell** — a real *ding*, mechanical and warm. Video display terminals (VDTs) inherited the code but swapped the bell for a **speaker/buzzer**, and that is where the warmth died: the mechanical *ding* became a synthesized square-wave **BEEP** out of a PC speaker.

> "Originally sent to ring a small electromechanical bell on tickers and other teleprinters and teletypewriters to alert operators… of an incoming message."
> — *Bell character*, Wikipedia

| Technique | Vibe it produces |
|---|---|
| **Raw `\a` → default PC-speaker/system BEEP** (unshaped square-ish tone, fixed pitch, ~⅛-second) | **Jarring, retro, DOS-era, error-coded.** For most users the sound is *literally the tab-complete-no-match / backspace-on-empty-line / invalid-command noise* — it has been trained into meaning "you did something wrong." It reads as a slap, not a signal. This is why it is the single most-disabled feature in ricing. |
| **The BEL as involuntary attention-yank** — it fires from *anything* writing 0x07 to the tty (a `cat` of a binary file, a crashing program, an over-eager prompt) | **Loss of control / anxiety.** Because any process can ring it, the bell feels like the terminal *betraying* you at random volume in a quiet room. The unpredictability is the negative vibe. |
| **`^G` visible in the buffer** when the tty can't sound it (e.g. piped, logged) | **Retro/telegraphic residue** — the caret notation is a little fossil, a reminder that this is a *control code* older than the transistor. Aesthetes who love it love it *because* it's a ghost of teletype. |

The cultural verdict is near-unanimous and quotable:

> "The terminal bell is an audible beep that interrupts your workflow… Originally a relic of physical teletype terminals… this sound is now more annoyance than utility for most users."
> — dotlinux, *Turn Off Beep/Bell on Linux Terminal*

> "Not loading the pc speaker module is the only reliable way I have found of turning off the beeps."
> — commenter, anarcat's *modern bell urgency*

So the default vibe of terminal sound is **"turn it off."** Everything interesting in this modality is a reaction against that byte.

---

## 3. The visual bell — silencing the screech without losing the signal

The first and most universal substitute: keep the *event*, kill the *sound*. Route BEL to a **visual** event instead.

**Concrete forms:**
- **Screen flash** — the whole terminal briefly inverts/flashes (classic xterm `visualBell`, the `Visual-Bell mini-Howto` of Linux lore).
- **Titlebar / window-manager urgency hint** — xterm's `bellIsUrgent: true` + `xset b off` converts the bell into an **ICCCM urgency hint**; the window manager (i3, etc.) highlights the workspace/tab. The alert leaves the terminal entirely and becomes a *quiet glow on your taskbar*.
- **Tab-color / tab-marker pulse** — tmux (`visual-bell on`, `monitor-bell on`) and kitty flash a message or tint the tab; **Zellij** pulses the tab foreground to `emphasis_3` (its "bell as a color pulse instead of a beep," `app-zellij.md` §5).

| Technique | Vibe it produces |
|---|---|
| **Full-screen invert flash** (`visualBell`) | **Abrupt-but-silent.** Solves the "quiet office" problem but trades an ear-slap for an eye-slap; many find the flash as jarring as the beep, just in a different organ. Reads as *utilitarian, slightly harsh*. |
| **WM urgency hint** (`bellIsUrgent`) — alert migrates to the taskbar/workspace | **Calm, ambient, non-intrusive, peripheral.** This is the connoisseur's move: the signal survives, the interruption doesn't. It reads as *respectful of attention* — "I'll wait for you in the corner of your eye." |
| **Tab-color pulse** (Zellij/tmux/kitty tab tint) | **Contemporary, app-like, quiet.** Attention without noise; the same register as a browser tab quietly bolding when a page finishes loading. The dominant *modern* substitute. |
| **Bell propagation through the multiplexer** (`screen: bell_msg 'Bell in window %n^G'`; `tmux: bell-action any`) | **Ambient presence.** A bell inside pane 3 surfaces a marker on the status bar even while you're in pane 1 — the multiplexer becomes a *switchboard of quiet who's-ringing lights*. Feels like a control room, not a single screen. |

The through-line: **flash = keep the interruption, lose the sound; urgency hint = keep the signal, lose the interruption.** The second is the more sophisticated vibe.

---

## 4. Task-completion chimes — sound as ceremony and closure

This is where sound turns *positive*. Instead of BEL-as-error, a **deliberate, chosen, pleasant** sound marks the end of a long job. It is the terminal equivalent of a microwave's *ding* or a Slack *knock-brush* — a small ceremony of completion.

**Concrete forms & the canonical vocabulary:**
- **macOS system sounds** via `afplay` — `/System/Library/Sounds/{Glass,Funk,Ping,Hero,Submarine,Blow}.aiff`. These are *named, characterful* sounds with cultural connotations:
  - **Glass** — a bright, clean, ascending *tink*. The de-facto "success / done" sound of a generation of Mac dev tooling. Reads as **friendly, satisfying, resolved.**
  - **Funk** — a lower, two-note *bwup* with a slightly comic edge. Widely used for "needs your input / attention," reads as **quizzical, gentle nudge.**
  - **Hero / Submarine** — grander, longer; reserved for bigger moments. Read as **ceremonial, heavier weight.**
  - **Blow / Ping** — short, dry, neutral. Read as **matter-of-fact tick.**
- **The generic pattern:** `long_command; afplay …Glass.aiff` or a shell hook (`PROMPT_COMMAND`, zsh `precmd`) firing a sound after any command exceeding N seconds.
- **Linux:** `aplay foo.wav`, `paplay`, `mpg123`, or `canberra-gtk-play -i complete` (freedesktop sound theme — there's literally a standard `complete` event sound).
- **Cross-tool:** build tools, test runners, and agent CLIs increasingly ship a "play a sound on done" option; the Claude Code **Stop hook** playing `Glass.aiff` has become a small folk-standard.

The Claude Code hook config is now practically a meme in dev blogs:

```json
{ "hooks": {
    "Stop":         [{ "hooks": [{ "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff &" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "afplay /System/Library/Sounds/Funk.aiff &" }] }]
}}
```

The semantic split is itself an aesthetic: **Glass = "I finished," Funk = "I need you."** Two timbres, two meanings — a two-note *language*.

| Technique | Vibe it produces |
|---|---|
| **Named pleasant chime on completion** (Glass on `done`) | **Friendly, satisfying-closure, ceremony.** The sound rewards you; it converts "the build finished" into a tiny hit of resolution. This is the opposite pole from BEL: *chosen* sound as gift, not *ambient* sound as slap. |
| **Distinct timbres for distinct states** (Glass=done, Funk=needs-input, Hero=big-milestone) | **Legible instrument / language.** You learn to identify the event *without looking* — the terminal gains a small vocabulary of leitmotifs. Reads as *thoughtful, designed*. |
| **Duration-gated sound** (only chime if the command ran > 10s) | **Respectful / non-nagging.** Fast commands stay silent; only the ones you actually walked away from ring. The restraint *is* the polish — it signals the tool understands your attention budget. |
| **Custom `.wav` / voice sample** (a sampled "task complete", a game SFX, a personal jingle) | **Playful, identity-stamped, warez-adjacent.** The sound becomes a signature — your terminal has a *voice*. High personality, high risk of annoying open-plan neighbors. |
| **Success vs. failure sound pair** (rising major chime on exit 0, falling/buzzy tone on non-zero) | **Emotionally legible closure.** You *hear* whether the build passed. A falling minor-third for failure lands in the body before you read the log — the terminal has a mood about your exit code. |

**Describe-the-sound (completion):** you're reading a PR in another window. Ninety seconds pass. From the background terminal comes a single bright *tink* — Glass, an ascending glassy arpeggio maybe 400ms long, clean attack, quick decay, no reverb. You don't even have to switch windows to know: it's done, and it passed. If instead you'd heard the lower two-note *bwup* of Funk, you'd know it stopped to ask permission. That two-sound alphabet is the entire UI, and it reached you with your eyes elsewhere.

---

## 5. Silence as a deliberate aesthetic — the monastic default

The most opinionated position in the whole modality is to make **no sound at all**, on purpose. Not "I forgot to configure it" but "quiet is the design."

**Why it's an aesthetic, not just a mute:**
- The default beep is coded as *error/interruption*; refusing it signals **competence and calm** — "this tool does not flinch."
- In the ricing / unixporn tradition, a silent terminal pairs with the *visual* austerity (muted palettes, generous whitespace, no chrome). Sound would break the vow.
- It aligns with **calm-technology / deep-work** design values: notifications belong on the periphery, and the terminal's periphery is *the taskbar tab*, not *the room*.

> "Silence is a feature, not a bug… designers should embrace calm technology and craft experiences that respect human attention."
> — Figr, *The UX of Silence*

> "Notifications should live on the periphery, not the center, so the main task stays primary."
> — same

| Technique | Vibe it produces |
|---|---|
| **`xset b off` / `set bell-style none` / `set -g visual-bell off` + no completion sound** | **Sober, focused, monastic, respectful.** The terminal makes zero noise ever; feedback is entirely visual/spatial. Reads as *disciplined* — the tool of someone who does not want to be pinged, who treats interruption as the enemy. |
| **Silence + a single peripheral visual marker** (tab dot, WM urgency) as the only "alert" | **Zen / ambient.** Nothing shouts; you *go check* when you're ready. The absence of sound becomes a statement of trust in the user's own rhythm. |
| **"Loud room" inversion** — the quietest terminal in an open office reads as the most senior | **Understated authority.** Not needing an audible ping to keep track is a flex; silence signals mastery. |

The tension a harness must resolve: **silence is respectful but *fails the background-completion use case*.** A muted terminal cannot tell you it's done when your eyes are elsewhere — which is precisely when an agent most needs to. Silence is a beautiful default and a bad *only* option (see §10).

---

## 6. OSC notifications — the modern, structured successor to BEL

The bell says "something happened" with zero payload. The modern successor is the **OSC (Operating System Command) notification**, which carries a *title and body* and hands off to the OS notification center — a real toast, not a beep.

**The escape-sequence family:**
- **OSC 9** — `\e]9;<message>\a` — the simple form (popularized by iTerm2, honored by others): fire a desktop notification with a plain body string.
- **OSC 777** — `\e]777;notify;<title>;<body>\a` — urxvt/others; title + body.
- **OSC 99** — kitty's rich protocol: `\e]99;i=<id>:c=1;<body>\e\\` with support for identity, actions, updates, icons.
- **BEL-as-urgency** (§3) is the degenerate zero-payload ancestor of all of these.

| Technique | Vibe it produces |
|---|---|
| **OSC 9 / 777 desktop toast on completion** (`printf '\e]9;build done\a'`) | **Ambient presence, integrated, "the terminal talks to the OS."** The feedback leaves the rectangle and joins your real notification stream, alongside Slack and calendar. Reads as *grown-up, first-class citizen of the desktop* — the terminal is no longer a walled box. |
| **kitty OSC 99 with an identity/action** | **Instrument-grade, app-like.** Notifications can update in place, carry an icon, offer a click action. The terminal gains the notification vocabulary of a native app — high polish, "this was engineered." |
| **tmux `monitor-activity` / `monitor-silence 30`** — status-bar markers when a pane changes *or goes quiet for N seconds* | **Switchboard / control-room ambient presence.** `monitor-silence` is the poetic inversion: it alerts you when a stream *stops* (a hung build, a finished tail). Silence itself becomes a signal. Reads as *vigilant, situational-awareness*. |

The vibe arc across §2→§6: **BEL (blunt, zero-payload, room-loud) → visual bell (silent, in-rectangle) → OSC toast (structured, in-OS, peripheral).** Each step trades rawness for legibility and moves the alert further from the ear and closer to the periphery.

---

## 7. Sonification — data and log severity mapped to tone

The exotic, sci-fi end of the modality: don't just *signal an event*, **continuously encode a stream** into sound. Map log severity, CPU load, network throughput, or test progress to **pitch, loudness, tempo, or timbre** so you can *monitor by ear* while looking elsewhere.

**Concrete mappings (from sonification literature):**
- **Pitch** — the most salient auditory dimension; high value → high frequency. Map ERROR→high shrill, WARN→mid, INFO→low hum. You *hear* an error spike before you read it.
- **Tempo / rhythm** — request rate as a click-track; a busy server ticks fast, an idle one slows to a heartbeat.
- **Timbre / instrument** — assign each log source or severity its own instrument, so a mixed stream becomes a small ensemble; a new instrument entering = a new kind of event.
- **Loudness** — magnitude → volume.

> "Pitch is by far the most used auditory dimension in sonification mappings and is known to be the most salient attribute in a musical sound."
> — Data Sonification literature (parameter mapping)

| Technique | Vibe it produces |
|---|---|
| **Log severity → pitch** (errors shrill, info low) | **Sci-fi, instrument, situational.** The terminal becomes a **sonar / EKG** — you develop an ear for "the sound of things going wrong." Reads as *cinematic ops room*, the beeping bridge of a starship. |
| **Throughput → tempo click-track** | **Alive, machinic, ambient.** The system has a *pulse*; you feel its health as rhythm. A stall is a silence, a spike is a stutter. Deeply immersive, borderline musical. |
| **Progress → rising arpeggio** (pitch climbs 0→100%) | **Anticipatory, satisfying.** You *hear* the bar fill; completion is a resolved cadence. The build has a melody with an ending. |
| **Per-source timbre ensemble** | **Orchestral / uncanny.** Multiple streams become polyphony; expert operators read the "chord" of system state. Rare, virtuosic, unmistakably a *statement* piece. |

Sonification is almost never a *default* (it's fatiguing and office-hostile), but as an **opt-in "monitor mode"** it is the most character-forward thing sound can do in a terminal — pure sci-fi-instrument vibe. It doubles as accessibility (eyes-free monitoring), which here is a genuine aesthetic device, not a compliance checkbox.

---

## 8. Nostalgia payloads — the bell as scene-culture artifact

Sound in the terminal carries a thick nostalgia layer that the demoscene / BBS / warez world weaponizes for *vibe*.

**Concrete forms:**
- **The modem connect handshake** — the DTMF dial, the carrier screech, the training-sequence warble resolving into hiss. An entire generation can *hum* it. Re-created in intro screens, telnet BBSes, and retro-terminal theme packs, it instantly signals **"you have connected to something clandestine and old."**
- **Telnet BBSes still online** (e.g. thekeep.net, up since the early '80s, still answering both a real modem *and* telnet) — dialing in is a nostalgia ritual; the connect sequence is the ceremony.
- **BEL easter eggs** — ANSI/ASCII art scene intros that fire `\a` in rhythm, `cowsay`/joke programs that beep, `telnet towel.blinkenlights.nl` (ASCII Star Wars) territory where the *retro-ness* is the whole point.
- **PC-speaker music** (`beep` command chaining `\a` at pitched frequencies) — coaxing melodies out of the one-bit speaker; pure demoscene flex.

| Technique | Vibe it produces |
|---|---|
| **Modem-handshake / carrier sample on connect** | **Warez-glam, scene-nostalgia, clandestine.** Instantly places you in the BBS/underground era; the sound *is* the aesthetic. Reads as *hacker-cool, illicit, analog-warmth*. |
| **Rhythmic `\a` / PC-speaker melody** (the `beep` package) | **Demoscene flex, playful, retro-virtuosic.** Squeezing music from a control code is a show of craft-for-its-own-sake — the terminal *performing*. |
| **Deliberate use of the "ugly" default beep as camp** | **Ironic-retro.** Some rice setups *keep* the harsh beep precisely because it's DOS-era; the ugliness is reclaimed as period-authentic texture. |

This layer is the reason sound in the terminal will never be *neutral*: the beep is a cultural object with 150 years of baggage, and half its aesthetic power is nostalgic.

---

## 9. Mobile & embedded — haptics as the tactile bell

On phones and watches the bell **grows a body.** The 0x07 event, which was a mechanical *strike* in 1963 and a square-wave beep by 1985, becomes a **vibration against your skin** in 2020. Haptics are the tactile analog of the bell — attention delivered through touch instead of ear.

**Concrete forms:**
- **Termux** (`~/.termux/termux.properties`): `bell-character = vibrate | beep | ignore`. The BEL can *buzz the phone*. Termux:API adds `termux-vibrate` for scripted haptics. (Notably, Termux's *extra-keys* also vibrate on every press — a controversial forced haptic that users have fought to disable, showing how loaded the tactile channel is.)
- **a-Shell / Blink (iOS):** iOS haptic engine (Taptic) can be wired to bell/notification events; Blink leans on iOS notifications + haptics for background session alerts.
- **Watch surfaces:** a debounced buzz + glanceable one-line summary (the pattern Raxol's own `raxol_watch` package embodies — APNS/FCM push, "tap-to-event," glanceable summaries).

| Technique | Vibe it produces |
|---|---|
| **BEL → phone vibration** (Termux `bell-character = vibrate`) | **Attentive, embodied, private.** The alert reaches you silently, in your pocket, in a meeting. The most *intimate* form of the bell — no one else hears it. Reads as *personal, discreet, present*. |
| **Distinct haptic patterns for distinct events** (short tick = done, double-buzz = needs input) | **Tactile language.** Like the Glass/Funk timbre split (§4) but felt, not heard — you read the event through your wrist without pulling the phone out. *Embodied, ambient*. |
| **Watch buzz + one-line glance** (raxol_watch: debounced push, tap-to-approve) | **Calm, ambient, respectful-of-attention.** The agent taps your wrist, shows one line, offers one action. The bell has become a gentle, minimal, wearable nudge. Deeply *attentive* without being *loud*. |
| **Over-eager forced haptics** (Termux extra-keys buzz on every keypress) | **Cheap, nagging, fidgety** — the cautionary tale. Haptics overused become as hated as the beep; the negative vibe of "device won't stop twitching." |

The embodied channel closes the loop: sound started as a *physical* strike (Teletype solenoid), decayed into a synthetic beep, and on mobile returns to *physical* sensation — the bell has come home to the body.

---

## 10. How sound interacts with the harness's multi-surface story

A coding-agent harness like Raxol renders one TEA app to **terminal, LiveView/browser, SSH, watch, telegram, MCP**. Completion is the load-bearing moment, and each surface has a *native* non-visual channel:

| Surface | Native completion signal | Vibe target |
|---|---|---|
| **Terminal (foreground)** | Nothing needed — the render *is* the signal; optionally a soft OSC-9 toast | Quiet; don't double-signal what the user is already watching |
| **Terminal (backgrounded / other window)** | **OSC 9/777 desktop toast** > **visual-bell/tab pulse** > *optional* opt-in chime | Ambient presence; peripheral, not room-loud |
| **Watch (`raxol_watch`)** | **Debounced haptic buzz + one-line glance + tap-to-approve** | Embodied, attentive, minimal |
| **Telegram (`raxol_telegram`)** | Message = the platform's own push/sound; **the harness should stay silent and let Telegram's chime carry it** | Don't re-invent a notification the platform already owns |
| **SSH** | Propagate BEL/OSC up the channel to the *client's* terminal (that's where the human is) | Reach the human, not the server |

**The key architectural insight (and the aesthetic one):** the harness should emit a **single semantic "task complete" event** and let each surface translate it into its *native* non-visual idiom — an OSC toast on the desktop, a haptic tap on the watch, a Telegram push, a color pulse in the tab — rather than hardcoding a beep. This is exactly the Zellij "bell as color pulse" move (`app-zellij.md` §5) generalized across surfaces: **one event, many quiet expressions.** Timbre/haptic-pattern becomes a *theme dimension* the same way color is — a `sound_role` palette (`complete`, `needs_input`, `error`) mapping to Glass/Funk/falling-tone or short/double/long-buzz.

---

## 11. Recommendations — should a coding-agent harness signal completion audibly?

**Yes — but opt-in, semantic, restrained, and surface-native. Never a raw `\a`.**

1. **Default to silent-but-visible.** Ship with *no* audible bell (respect §5's monastic default and the open-office reality). The foreground terminal's render is already the signal.
2. **Emit a structured event, not a byte.** Prefer **OSC 9 / OSC 777** desktop notifications (title = "Raxol · task complete", body = the summary) over BEL — carry payload, land in the OS notification center, sit on the periphery. Fall back to **visual-bell / tab-color pulse** where OSC isn't honored.
3. **Offer an opt-in chime with a two-note vocabulary.** Let users enable sound; when they do, give **two distinct timbres**: `complete` (bright, resolved — Glass-like ascending) and `needs_input` (softer, quizzical — Funk-like two-note). Optionally a third `error` (falling minor tone). This is the emotionally-legible closure of §4 without the annoyance of §2.
4. **Gate on duration and focus.** Only sound/notify when (a) the task ran longer than ~10s *and* (b) the terminal is **not focused** — the "notify me only when I'm not looking" pattern. This restraint is the single biggest determinant of whether the sound reads as *thoughtful* or *nagging*.
5. **Make sound a theme role, not a constant.** A `sound`/`haptic` palette (`complete`/`needs_input`/`error` → files or synth tones / buzz patterns) that swaps with the visual theme. Identity should be *hearable*: a Raxol session could have a recognizable completion signature the way it has a signature accent color.
6. **Let each surface speak its own body.** Watch → haptic tap; Telegram → platform push (stay silent yourself); SSH → propagate to the client tty; desktop terminal → OSC toast. One semantic event, many native quiet expressions.
7. **Consider an opt-in sonification "monitor mode"** for long streaming runs (test progress as a rising arpeggio, error-rate as pitch) — the highest-personality, most sci-fi-instrument option, strictly opt-in.
8. **Never** hard-fire the default system beep, never sound on every command, never force haptics on every keypress (the Termux cautionary tale). The negative vibes in this modality all come from *involuntary, undifferentiated, too-frequent* signals.

The one-line doctrine: **the agent finishing in a background terminal is a moment of ceremony; give it a chosen, restrained, surface-native voice — and make silence the honest default for everyone who's already watching.**

---

## Notable quotes

- "Originally sent to ring a small electromechanical bell on tickers and other teleprinters and teletypewriters to alert operators… of an incoming message." — *Bell character*, Wikipedia
- "This sound is now more annoyance than utility for most users." — dotlinux, *Turn Off Beep/Bell on Linux Terminal*
- "Not loading the pc speaker module is the only reliable way I have found of turning off the beeps." — commenter, anarcat, *modern bell urgency*
- "I use systematic bell signals on command completion… to receive urgency hints when long-running processes finish — enabling focus retention without audible disruption." — anarcat, *Using the bell as modern notification* (paraphrased from setup)
- "Silence is a feature, not a bug… embrace calm technology and craft experiences that respect human attention." — Figr, *The UX of Silence*
- "Pitch is by far the most used auditory dimension in sonification mappings and is known to be the most salient attribute in a musical sound." — Data Sonification parameter-mapping literature
- "The Stop hook fires every time Claude finishes a turn and returns control to you." — Recombobulate, *Play a Sound When Claude Finishes with a Stop Hook*

---

## Sources

- *Bell character* — Wikipedia: https://en.wikipedia.org/wiki/Bell_character
- anarcat, *Using the bell as modern notification* (OSC 9/777, urgency hints, screen/tmux propagation): https://anarc.at/blog/2022-11-08-modern-bell-urgency/
- dotlinux, *Turn Off Beep/Bell on Linux Terminal*: https://www.dotlinux.net/blog/turn-off-beep-bell-on-linux-terminal/
- *Visual Bell mini-Howto* (Alessandro Rubini / TLDP): https://tldp.org/HOWTO/pdf/Visual-Bell.pdf
- Rosetta Code, *Terminal control/Ringing the terminal bell*: https://rosettacode.org/wiki/Terminal_control/Ringing_the_terminal_bell
- kitty, *Desktop notifications* (OSC 99 / OSC 9 protocol): https://sw.kovidgoyal.net/kitty/desktop-notifications/
- tmux/tmux Wiki, *Advanced Use* (monitor-activity/bell/silence, visual-bell): https://github.com/tmux/tmux/wiki/Advanced-Use
- tmuxai, *How to set up alerts and monitoring in tmux*: https://tmuxai.dev/tmux-alerts-monitoring/
- rickstaa/tmux-notify (libnotify + visual bell on process finish): https://github.com/rickstaa/tmux-notify
- josh8, *Command-line Audio on a Mac (Without Installing Anything)* (`afplay`, system sounds): https://josh8.com/blog/commandline-audio-mac.html
- flaviocopes, *How to play a sound from the macOS command line*: https://flaviocopes.com/how-to-play-a-sound-from-the-macos-command-line/
- Recombobulate, *Play a Sound When Claude Finishes with a Stop Hook*: https://recombobulate.dev/tips/play-a-sound-when-claude-finishes-with-a-stop-hook
- Jesse Waites, *Get notified when Claude Code finishes a task*: https://jessewaites.com/blog/post/get-notified-when-claude-code-finishes-a-task/
- alexop.dev, *How I Added Sound Effects to Claude Code with Hooks* (Glass/Funk split): https://alexop.dev/posts/how-i-added-sound-effects-to-claude-code-with-hooks/
- Boris Buliga, *Claude Code Notifications That Don't Suck*: https://www.d12frosted.io/posts/2026-01-05-claude-code-notifications
- Figr, *The UX of Silence: Designing Quiet Moments*: https://figr.design/blog/the-ux-of-silence
- Hostragons, *Data Sonification: Representing Data with Sound* (parameter mapping: pitch/loudness/tempo/timbre): https://www.hostragons.com/en/blog/data-sonification-representing-data-with-sound/
- *Data Sonification Toolkit — Methods*: https://www.sonificationkit.com/data-sonification/methods
- Termux, *bell-character = vibrate/beep/ignore* & forced-vibration issues: https://github.com/termux/termux-app/issues/3029 · https://github.com/termux/termux-app/issues/24
- Hackaday, *How A Dial-up Modem Handshake Works* (connect-sound nostalgia): https://hackaday.com/2013/01/31/how-a-dial-up-modem-handshake-works/
- Hackaday, *A Handy Guide To The Humble BBS*: https://hackaday.com/2022/11/29/a-handy-guide-to-the-humble-bbs/
- Cross-reference (in this dossier set): `app-zellij.md` §5 — "bell as a color pulse instead of a beep"; `raxol_watch` package (this repo) — glanceable haptic watch surface.
