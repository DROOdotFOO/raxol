# ncmpcpp — Aesthetic Dossier

**Repo:** https://github.com/ncmpcpp/ncmpcpp · **Author/maintainer:** Andrzej Rybczak (`andrzej@rybczak.net`) · **License:** GPL-2+ · **Lineage:** "NCurses Music Player Client (Plus Plus)", an expanded rewrite *"inspired by ncmpc"*, itself the ncurses client for MPD (Music Player Daemon). · **Status:** officially in maintenance mode — *"it's feature complete for me."*
**Category:** retro music-player / audio-visualizer TUI. **Stack:** C++, ncurses, boost, optional FFTW3 (spectrum) + TagLib + curl (last.fm/lyrics).

Sources are inline and collected at the bottom. Primary source is the source tree itself (`undefined/ncmpcpp/`), which is the truest record of designer intent — the visualizer glyph tables and default color lists are hardcoded constants.

---

## 1. What ncmpcpp IS, aesthetically

ncmpcpp is a **daemon front-end**, and its whole look flows from that split: MPD holds the music, ncmpcpp is a thin, fast, *keyboard-driven index card* onto it. The identity is **the librarian's terminal** — dense scrolling columns of tags, a single character-row progress bar, a bold now-playing line — fused with **the oscilloscope**: a full-screen real-time audio visualizer that turns the same monospace grid into motion art. It is two personalities in one binary: a **quiet catalog** and a **loud dancing waveform**, toggled with a keypress.

Crucially, ncmpcpp ships almost naked. The default theme is plain (yellow-on-default text, green borders, a `=====>` bar). Its *famous* looks — the green-on-black cyberdecks and rainbow spectrums all over r/unixporn — are **not the binary; they're the config surface**. ncmpcpp's real aesthetic thesis is: *ship a neutral skeleton, expose an obsessively granular theming grammar, let the rice community supply the soul.* One binary, thousands of divergent faces.

---

## 2. Color system

### 2.1 The default palette (from `doc/config`)
Standard 8/16-color ncurses names, deployed semantically rather than decoratively:

| Element | Default | Effect |
|---|---|---|
| `main_window_color` | `yellow` | body text is warm/amber — the "old CRT phosphor" cue without committing to green |
| `color1` / `color2` | `white` / `green` | the two alternating column/tag colors; green is the signature accent |
| `window_border_color` | `green` | inactive panel frames |
| `active_window_border` | `red` | the focused panel's frame flips to red — **attention by hue, not by weight** |
| `empty_tag_color` | `cyan` | missing metadata is a cool, recessive cyan — absence reads as "not filled in", not as error |
| `progressbar_color` | `black:b` | the un-elapsed track is bold-black (dim ghost) |
| `progressbar_elapsed_color` | `green:b` | the elapsed track is bold green — **time literally turns green as it passes** |
| `statusbar_time_color`, `player_state_color`, `state_flags_color` | `default:b` | bold, so the clock/state flags punch above body text |
| `alternative_ui_separator_color` | `black:b` | hairline separators in the alt UI |

The `:b` suffix is the recurring move: **bold as a second brightness channel.** On a 16-color terminal, `black:b` renders as bright-grey and `green:b` as vivid green — so the palette secretly has ~16 usable tones from 8 names.

### 2.2 The visualizer palette — color as amplitude
Two hardcoded defaults ship in the config:
- **16-color rainbow:** `blue, cyan, green, yellow, magenta, red`
- **256-color heat gradient:** `47, 83, 119, 155, 191, 227, 221, 215, 209, 203, 197, 161` (a green→lime→yellow→orange→red ramp)

The engine (`toColor()` in `visualizer.cpp`) maps a bar's **height/energy to its position in this list**: `index = (number * colors_size) / max`. Quiet = first color (blue/green), loud = last color (red). So **loudness is encoded as heat** — a bass drop paints the bottom of the bars cool and the peaks hot red. This is the single most important color decision in the app: color is not chrome, it's a data channel welded to amplitude. The rainbow default makes the spectrum look like a *thermal EQ*.

### 2.3 The theming grammar (why one binary has infinite faces)
The format/color mini-language is the identity engine. In any format string:
- `$1..$8` = the 8 colors (black,red,green,yellow,blue,magenta,cyan,white); `$9` = end-color.
- `$b/$u/$i/$r/$a` = bold / underline / italic / reverse / **alternative character set**; `$/x` closes them.
- `$(197_yellow)` = 256-color foreground on a colored background; **colors nest.**
- `$R` = flush-right the remainder of the line.
- `{...}` = conditional group (render only if the tags inside exist); `{a}|{b}` = fallback chain.

Because *every* string — song rows, columns, headers, prefixes, the window title — is written in this grammar, a themer reshapes the entire app without recompiling. `discard_colors_if_item_is_selected = yes` means selection reverses cleanly over any palette. This is the mechanism behind the wild divergence: the binary is a **stencil**, the config is the **ink**.

---

## 3. Layout, borders, density

### 3.1 The classic screen, described
Top: a one-line **header** (screen name + volume). Body: the active screen — usually the **Playlist** in `columns` mode (default `playlist_display_mode = columns`). Bottom: a **progress bar row**, and under it a **status bar** (player state glyph, elapsed/total time, mode flags, song status format). Panels are drawn as ncurses windows with optional single-line borders in `window_border_color`.

The default **column layout** (`song_columns_list_format`):
```
(20)[]{a}  (6f)[green]{NE}  (50)[white]{t|f:Title}  (20)[cyan]{b}  (7f)[magenta]{l}
```
→ Artist (20%, default color) · Year (6 fixed cells, green, empty-marker suppressed) · Title (50%, white, falls back to filename) · Album (20%, cyan) · Length (7 fixed cells, magenta). Widths are **percentages by default, fixed-cells with `f`** — a genuinely fluid grid that reflows on terminal resize. Each column carries its own color, so the playlist reads as a **color-coded spreadsheet**: your eye learns "cyan = album, magenta = duration" and can skim by hue. Right-aligned attribute `r` and empty-suppression `E` are per-column flags.

### 3.2 Now-playing & selection conventions
Three overlapping row-states, each a different typographic device:
- **Now playing:** `now_playing_prefix = $b`, suffix `$/b` → the currently-playing row is simply **bold**. Understated; the audio is the event, the text just thickens.
- **Cursor / current item:** `current_item_prefix = $(yellow)$r` → the highlighted row is **reverse-video yellow** (a solid amber bar). In an inactive column the cursor is `$(white)$r` (reverse white) — dimmer, so you can tell which panel has focus.
- **Selected (marked) items:** `selected_item_prefix = $6` (magenta) — batch-selected rows go magenta.
- **Modified (tag editor):** `modified_item_prefix = $3> ` → a **green `>` gutter marker**, like a diff/dirty indicator.

So a row can simultaneously be bold (playing), reversed (cursor), and magenta (selected) — the states **stack legibly** because each uses a different axis (weight / reverse / hue).

### 3.3 Density
ncmpcpp is **dense by default** — no card padding, no gutters beyond a space between columns, one item per line, header/body/bar/status stacked with zero wasted rows. Whitespace rhythm comes only from `$R` right-alignment (pushing durations to the edge) and column gaps. The feel is **utilitarian, high-information, "everything on one screen"** — the antithesis of a spacious modern app. The alternative UI (`user_interface = alternative`) trades some density for a large centered now-playing block with `$a`-drawn separator rules.

---

## 4. Motion language — the visualizer as pure redraw art

This is ncmpcpp's signature and the reason it lives in the "visualizer" family. MPD writes raw PCM to a FIFO (or UDP sink); ncmpcpp reads it and **redraws the whole main window every frame** at `visualizer_fps` (default **60**). The `windowTimeout()` is literally `1000/fps` while playing. There is no easing library — the motion *is* the audio, sampled and rasterized to the grid.

### 4.1 Four modes, four moods
From `InitVisualization()` / the `Draw*` functions:

- **Wave** (`visualizer_look[0]`, default `●`): a single scrolling oscilloscope line of bullet glyphs. `DrawSoundWave` computes a mean per column, then **fills intermediate cells between adjacent points** so the line stays continuous instead of dotty — a deliberate "make the wave watchable" hack (the code slows scroll ×10 for the same reason). Feeling: **a living heartbeat / seismograph.**
- **Wave-filled** (`visualizer_look[1]`, default `▮`): the area under the wave is solid-filled with half-block bars, colored by height. Feeling: **a chunky, VU-meter solidity** — more "loud" than the thin line.
- **Spectrum** (FFTW only): the marquee mode. FFT → frequency bars. Feeling: **a graphic equalizer dancing** — the classic hi-fi rack image rendered in text.
- **Ellipse / Lissajous:** samples plotted around an ellipse; in stereo the two channels form **concentric colored rings** that pulse and warp. A song panned hard-right collapses to a vertical line. Feeling: **an oscilloscope in X-Y mode, hypnotic and organic.**

Toggling cycles Wave → Filled → Spectrum → Ellipse (`ToggleVisualizationType`, prints the new mode to the status bar).

### 4.2 Block vs braille — how frequency becomes glyph height
The spectrum's sub-cell smoothness is the most carefully engineered aesthetic detail in the codebase. With `visualizer_spectrum_smooth_look = yes`, bars are drawn not with a flat block but with an **8-level partial-block ramp** (hardcoded in the constructor):
```
SMOOTH_CHARS         = "▁▂▃▄▅▆▇█"   // U+2581..2588, one-eighth steps
SMOOTH_CHARS_FLIPPED = "▔🮂🮃🮄🬎🮅🮆█"   // top-anchored, from Symbols for Legacy Computing (U+1FB00 block)
```
A bar of fractional height picks the glyph whose fill matches the remainder: `idx = (size*h) % size`. This gives each bar **8× the vertical resolution of the cell grid** — bars appear to move smoothly instead of snapping row-to-row. The FLIPPED set exists purely for **stereo mode**, where the top (right-channel) bars descend *from* the top of the screen, so they need glyphs filled from the top edge down (`▔🮂🮃…`). When the exotic legacy-computing glyphs aren't available, the code falls back to reversing fg/bg on the standard ramp — same visual, different mechanism (`visualizer_spectrum_smooth_look_legacy_chars`). Comment in source points to `https://unicode.org/charts/PDF/U1FB00.pdf`, evidence of the author hand-hunting the exact glyphs.

Under the hood the smoothness is doubled by **DSP, not just glyphs**: a **Blackman window** on the FFT input (chosen in-comment "for low sidelobes and fast sidelobe rolloff"), **log-scaled frequency axis** (so bass and treble get perceptually fair width), optional **log-scaled Y** (dB-like), and **cubic Hermite interpolation** between computed bars so the spectrum reads as a continuous curve, not a picket fence. `visualizer_spectrum_dft_size` lets you widen the time slice for "less jumpy" output. All of this is aesthetic labor: making raw FFT *look pleasant*, which the CHANGELOG repeatedly notes ("Improve look of the frequency spectrum visualizer", "adjusted to look more pleasant").

### 4.3 The FIFO-reset flicker
On entering the visualizer, `update()` toggles the MPD output off/on (`usleep(50000)`) "to get rid of the difference between audio and visualization." A tiny sync ritual — the visualizer **locks to the beat** rather than drifting. That lockstep is what makes it feel like the terminal is *hearing* the music, not replaying a recording of it.

### 4.4 Elsewhere: the clock
The **Clock** screen (`clock.cpp`) is a second motion moment: BSD-tty-clock-style **giant digits**, encoded as octal bitmaps (`disp[11] = {075557, 011111, …}`) and drawn as **reverse-video double-spaces** — i.e. solid blocks of the foreground color, 8 rows tall. It animates digit transitions bit-by-bit (an XOR morph between `older`/`newer` masks). Pure retro-terminal furniture; a nod to the ancient `clock` from BSD games.

---

## 5. Progress bar — a whole timeline in one row

`Progressbar::draw` builds the bar from three characters of `progressbar_look` (default `=>`, i.e. `[0]='='`, `[1]='>'`, `[2]=none`):
- fill the whole width with the **empty** char — if none is set (the default), it uses ncurses `mvwhline` = the ACS horizontal line `─`;
- overwrite `width*elapsed/time` cells with the **elapsed** char `=` in bold green;
- draw the **head** char `>` at the boundary.

So the default reads: `==========>────────────` — bold-green filled, a `>` playhead, a dim `─` remainder. **A single 1×N row conveys absolute position, direction, and proportion at a glance.** Ricers swap `=>` for `▓▒░`, `━╾─`, or Nerd-Font arrows to change the entire mood of the bar from "typewriter" to "hi-fi slider" — one string, total re-skin. The bar is stateful color: **the left half is the past (green), the right half is the future (grey)**, and the boundary crawls right in real time.

---

## 6. Typography substitutes

With one monospace face, ncmpcpp leans on every non-glyph lever:
- **Bold (`$b`) as emphasis + as a brightness channel** (`:b` doubles the palette). Now-playing = bold; state flags/time = bold.
- **Reverse video (`$r`) as the "solid highlight bar"** — the cursor, the selection, the clock digits are all reverse-video fills. Reverse is ncmpcpp's answer to "a colored button."
- **Italic (`$i`) and underline (`$u`)** available but sparingly defaulted — reserved for themers.
- **Alternative character set (`$a`)** switches ncurses into ACS line-drawing so headers can draw box rules (`qqu` = horizontal-line + tee) inline with text — this is how the alt UI draws its separators.
- **Glyph choice as instrument:** the wave bullet `●`, filled half-block `▮`, the 8-step block ramp, the progressbar `=>` — each is a chosen character standing in for a rendered widget. Nerd-Font users substitute `` `` `` icons for player-state flags, giving the same binary a modern-icon feel.
- **Casing / prefixes:** semantic gutters like `modified_item_prefix = $3> ` (green `>`) and `browser_playlist_prefix = "$2playlist$9 "` (a red literal word "playlist" tag) act as inline labels.

---

## 7. Voice & copy

ncmpcpp barely speaks — and that terseness *is* the voice. Status-bar messages are printf-terse and technical: `Visualization type: %1%`, `Couldn't open "%1%" for reading PCM data: %2%`, `There is no output named "%s"`. No personality, no apology, no emoji — the register is **Unix daemon operator**: report the fact, name the file, name the errno, move on. Errors surface `strerror(errno)` verbatim. Empty/absent metadata is handled by *format grammar* (`{%t}|{%f}` falls back title→filename; empty tags render in recessive cyan) rather than by chatty "no data" copy. The app trusts you to read a terminal. That deadpan, man-page tone is the copywriting identity: **it feels like a tool, not a product.**

---

## 8. Identity moments

- **No splash / no banner.** ncmpcpp boots straight into the playlist (or the visualizer if configured as initial screen) — the *absence* of a startup animation is itself a retro-Unix statement: instant, no ceremony.
- **The signature color is green** — inherited border/accent green (`window_border_color=green`, `color2=green`, elapsed bar green) — but the *emotional* signature is the **rainbow/heat spectrum**, the thing people screenshot.
- **The red focus border** — the one hue that jumps — is the app's way of pointing.
- **The visualizer toggle** is the identity *gesture*: press a key and the whole window flips from library to living waveform. That transformation-in-place is what people remember.
- **The Clock screen** is a deliberate piece of nostalgia furniture.
- **Error personality = none, on purpose.** The fail state is a one-line `errno` string in the status bar; dignity through minimalism.

---

## 9. What makes it FEEL different from its siblings

- **vs `ncmpc` (its ancestor):** ncmpc is minimal and fixed; ncmpcpp is **maximalist and infinitely themeable** — columns, media-library trees, tag editor, four visualizers, the format grammar. ncmpcpp's feel is "power-user cockpit," ncmpc's is "appliance."
- **vs `cava` (pure visualizer):** cava is *only* the spectrum, gorgeous but blind to your library. ncmpcpp welds the spectrum onto a full catalog, so the visualizer feels **embedded in a workstation**, not floating alone. And ncmpcpp's spectrum does its own DSP artistry (Blackman window, log axes, cubic interpolation, 8-level blocks) rather than delegating.
- **vs `cmus` / `mpv` TUIs:** those are single-process players with baked-in themes. ncmpcpp's **daemon architecture + naked default + deep config grammar** is the differentiator: it's the TUI that becomes whatever the rice community makes it. Its true aesthetic is *configurability as a design value* — the binary is a canvas.
- **The two-personality trick:** quiet color-coded spreadsheet ↔ loud rainbow oscilloscope, in one keypress. Few TUIs hold both a *reference-tool* mood and a *screensaver* mood and let you flip between them.

---

## 10. Reconstructed decision history (from CHANGELOG + source)

The visualizer's look was refined over many releases, and the commit trail reads as a **sustained pursuit of "watchable" / "pleasant" motion**, not features:
- Early: `new screen: music visualizer with sound wave/frequency spectrum modes` → `support for stereo visualization` → `make characters used in visualizer customizable` → `support for custom visualization color` → `Visualizer now supports multiple colors (list of colors)` + `two more modes: sound wave filled and sound ellipse`.
- Tuning passes: *"Visualizer's frequency spectrum was adjusted to look more pleasant"*, *"Improve look of the frequency spectrum visualizer"*, *"Reduce CPU usage of the frequency spectrum visualizer."*
- The smoothness project: `Add visualizer_spectrum_smooth_look, visualizer_spectrum_dft_size, visualizer_spectrum_gain, hz_min, hz_max`; later `Add visualizer_spectrum_smooth_look_legacy_chars (enabled by default) for potentially improved bottom part of the spectrum visualizer in terminals` — i.e. the author added an *entire config option* just to get the top-descending stereo bars filled correctly with obscure Unicode. That is aesthetic obsession in the changelog.
- Color-theming grew in parallel: `Support for 256 colors and customization of background colors`, `Format information can now be attached to selected color variables`, `main_window_highlight_color deprecated in favor of current_item_prefix/suffix` (moving highlight from a fixed color to the composable prefix grammar — a deliberate shift toward *themer control*).

Designer intent, plainly: **a neutral, dense, keyboard-first catalog** as the baseline, plus **a hand-tuned DSP-backed visualizer** as the showpiece, plus a **format/color grammar granular enough that the community owns the final look.** Maintenance-mode README confirms the philosophy — it's "feature complete," a finished instrument rather than an evolving product.

---

## Notable quotes

- **README:** *"ncmpcpp – featureful ncurses based MPD client inspired by ncmpc."*
- **README (status):** *"The project is officially in maintenance mode. I (Andrzej Rybczak) still use it daily, but it's feature complete for me… No new, substantial features should be expected."*
- **visualizer.cpp (source comment, `toColor`):** *"a scaling function for coloring. For numbers 0 to max this function returns a coloring from the lowest color to the highest, and colors will not loop from 0 to max."* — color explicitly bound to amplitude.
- **visualizer.cpp (source comment, `DrawSoundWave`):** *"if the gap between two consecutive points is too big, intermediate values are needed for the wave to be watchable."* — legibility of motion as an explicit goal.
- **visualizer.cpp (source comment, `ApplyWindow`):** *"Use Blackman window for low sidelobes and fast sidelobe rolloff… don't care too much about mainlobe width."* — DSP choices made for *look*.
- **CHANGELOG:** *"Visualizer's frequency spectrum was adjusted to look more pleasant."*
- **Addy (blog, self-deprecating on the default look):** *"My theme is pretty simple & ugly"* — pointing readers to r/unixporn for the good-looking configs; confirms the "binary is neutral, community supplies the look" dynamic.

## Sources
- ncmpcpp source (cloned): `undefined/ncmpcpp/src/screens/visualizer.cpp`, `src/screens/clock.cpp`, `src/statusbar.cpp`, `doc/config`, `README.md`, `CHANGELOG.md`
- https://github.com/ncmpcpp/ncmpcpp
- https://github.com/ncmpcpp/ncmpcpp/blob/master/doc/config
- https://wiki.archlinux.org/title/Ncmpcpp
- https://man.archlinux.org/man/extra/ncmpcpp/ncmpcpp.1.en
- https://unicode.org/charts/PDF/U1FB00.pdf (Symbols for Legacy Computing — the flipped block ramp)
- https://addy-dclxvi.github.io/post/configuring-ncmpcpp/
- https://bbs.archlinux.org/viewtopic.php?id=66488&p=4 (Arch forums "Show your .ncmpcpp/config" screenshot thread)
- https://en.wikipedia.org/wiki/Cubic_Hermite_spline (interpolation cited in source)
