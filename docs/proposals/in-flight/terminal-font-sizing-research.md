# Terminal Font-Sizing (Larger/Smaller Text) — Capability & Compatibility Research

Status: **research (v1)** · Date: 2026-07-15 · Owner: V + Claude
Scope: research only — no code changes. Feeds a future proposal if we choose to build it.
Related: `f0-capability-detection.md` (the DA1-sentinel probe substrate this would ride on),
`tui-steal-list.md`.

---

## 0. TL;DR (the naming answer)

There are **two distinct capabilities**, and the one you half-remember is the second:

1. **Classic VT100 line renditions — DECDWL / DECDHL / DECSWL.** Double-width line,
   double-height line, single-width line. VT100-era (c. 1978). Whole-line only, **2× only**,
   and double-height requires emitting the *same line twice*. Escape sequences `ESC # 3/4/5/6`.

2. **The kitty "text sizing protocol"** (official name: *The text sizing protocol*), a single
   **OSC 66** escape code. Introduced **kitty 0.40.0, early 2025** (RFC opened 2025-01-18).
   Arbitrary integer scale (1–7×), *fractional* smaller text, superscript/subscript, explicit
   per-run cell width, alignment. **Per-run, not per-line.** This is the "new capability."

**Leading recommendation:** target **OSC 66**, shipped **off by default and capability-gated**,
starting with its **`w=` width-declaration** sub-feature (lowest risk, solves an existing Raxol
width-truth pain, degrades safely), then integer **`s=` scale** for larger text. Treat classic
DECDWL/DECDHL as a small optional legacy path only. **Detection is mandatory for both** — you
cannot safely emit either blind (details in §5).

**Top-3 compatibility takeaways:**
- **Who supports OSC 66:** kitty (full: scale + width + fractional); foot (width only); Ghostty
  (parses it as of 1.3.0, rendering not wired yet). That's it, today.
- **Who doesn't:** WezTerm, iTerm2, Windows Terminal, Alacritty, xterm, Konsole, VTE/GNOME
  Terminal — none implement OSC 66. And, counter-intuitively, the *modern* terminals mostly
  **also reject classic DECDHL** (kitty, iTerm2, Ghostty, Alacritty, VTE all lack it); classic
  double-height survives mainly on xterm, WezTerm, Windows Terminal, Konsole, Apple Terminal.
- **tmux caveat:** neither works through tmux. tmux has no line-attribute cell model; OSC 66
  passthrough was tried and **did not work** (tmux issue #4461, closed). Under tmux we must force
  the plain fallback regardless of the outer terminal.

---

## 1. Capability #1 — Classic VT100 line renditions (DECDWL / DECDHL / DECSWL)

**What it is.** Per-*line* attributes inherited from the VT100. They alter the width/height of
every glyph on the cursor's line. There is no per-character or per-run granularity, and the only
magnification is 2×.

**Exact escape sequences** (all are `ESC #` + a final digit; `ESC`=`0x1B`, `#`=`0x23`):

| Mnemonic | Sequence | Bytes | Effect |
|---|---|---|---|
| DECDHL (top half) | `ESC # 3` | `1B 23 33` | Line becomes the **top half** of a double-height, double-width line |
| DECDHL (bottom half) | `ESC # 4` | `1B 23 34` | Line becomes the **bottom half** of a double-height, double-width line |
| DECSWL | `ESC # 5` | `1B 23 35` | Line returns to **single-width, single-height** (the reset/normal) |
| DECDWL | `ESC # 6` | `1B 23 36` | Line becomes **double-width, single-height** |

Source: DEC VT510 Programmer Reference — [DECDHL](https://vt100.net/docs/vt510-rm/DECDHL.html),
[DECDWL](https://vt100.net/docs/vt510-rm/DECDWL.html); byte encodings cross-checked against
[terminalguide](https://terminalguide.namepad.de/seq/a_esc_zhash_a4/).

**Key limitations / gotchas:**
- **Double-height needs the line emitted twice** — once with `ESC # 3` (top) and once with
  `ESC # 4` (bottom), each carrying the *same characters*. The terminal shows the top half of
  the glyphs on line N and the bottom half on line N+1.
- **Whole-line only.** You cannot mix normal and large text on one row. Everything right of
  screen-center is lost when a line goes double-width (per the VT spec).
- **2× only.** No 3×, no fractional, no smaller-than-normal.
- **Different content on the two halves is unsupported** even where double-height renders (e.g.
  Konsole explicitly renders top/bottom from the *same* text; see matrix notes).

**Degradation:** on a terminal that ignores `ESC # n`, double-*width* degrades acceptably (text
just prints at normal width). Double-*height* degrades **badly**: because you emitted the line
twice, an unsupporting terminal shows the content **duplicated on two rows**. So double-height
must be capability-gated or it corrupts output.

---

## 2. Capability #2 — kitty text sizing protocol (OSC 66) — the "new" one

**Official name:** *The text sizing protocol.* Single escape code, **OSC 66**.
Spec: [sw.kovidgoyal.net/kitty/text-sizing-protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)
· source [text-sizing-protocol.rst](https://github.com/kovidgoyal/kitty/blob/master/docs/text-sizing-protocol.rst).
**Version/date:** shipped in **kitty 0.40.0** (early 2025); design RFC
[kitty#8226](https://github.com/kovidgoyal/kitty/issues/8226) opened **2025-01-18**.

**Wire format:**

```
OSC 66 ; metadata ; text  ST
```

- `OSC` = `ESC ]` = `0x1B 0x5D`  (note: `]` is `0x5D`, not `0x5B` — some secondary write-ups get
  this wrong; `0x5B` is `[` = CSI).
- `66` = the command number (`0x36 0x36`).
- `metadata` = colon-separated `key=value` pairs (see table).
- `text` = escape-safe UTF-8, **≤ 4096 bytes per escape** (split longer runs into multiple codes).
- `ST` = string terminator: `BEL` (`0x07`) or `ESC \` (`0x1B 0x5C`).

**Metadata keys** (from the spec; ranges + defaults verbatim):

| Key | Range | Default | Meaning |
|---|---|---|---|
| `s` | 1–7 | 1 | **Integer scale.** Text is drawn in a block of `s*w` × `s` cells → *larger* text. |
| `w` | 0–7 | 0 | **Width in cells** the text must occupy (`0` = terminal auto-computes). Solves wcwidth. |
| `n` | 0–15 | 0 | **Numerator** of the fractional scale → *smaller* text. |
| `d` | 0–15 | 0 | **Denominator** of the fractional scale (must be `> n` when non-zero). |
| `v` | 0–2 | 0 | Vertical alignment of fractional text: `0` top, `1` bottom, `2` center. |
| `h` | 0–2 | 0 | Horizontal alignment of fractional text: `0` left, `1` right, `2` center. |

**Examples:**
- Double-size heading: `ESC ] 66 ; s=2 ; Big Title ST`
- Triple-size: `ESC ] 66 ; s=3 ; HUGE ST`
- Half-size text: `ESC ] 66 ; n=1:d=2 ; small ST`
- **Superscript:** `ESC ] 66 ; n=1:d=2 ; 2 ST` (half-size, top-aligned by default)
- **Subscript:** `ESC ] 66 ; n=1:d=2:v=1 ; 2 ST` (half-size, bottom-aligned)
- Explicit width only (no resize): `ESC ] 66 ; w=2 ; 🚀 ST` (tells the terminal "this is 2 cells")

**Cursor semantics:** creating a multicell run advances the cursor `s*w` cells to the right on
the same row; but ordinary cursor-movement commands still move by **single-cell** increments
(you address the scaled block's constituent cells normally).

**Why the `w=` sub-feature matters independently of "big text":** it lets the *application*
declare how many cells a grapheme occupies, ending the perennial disagreement between
`wcwidth`/`Raxol.UI.TextMeasure` and the terminal's own width table. It's an alternative to DEC
mode 2027 and is the part foot chose to implement first (§4/§5). For Raxol this is arguably more
valuable than the scaling itself.

**Degradation — the load-bearing caveat.** The spec's "fully backwards compatible" line means
*a terminal that implements OSC 66 still works with apps that don't use it* — it does **not**
promise that the text *inside* an OSC 66 payload survives on a terminal that doesn't implement
it. Per ECMA-48 OSC parsing, an unrecognized OSC string is consumed up to `ST` and discarded —
so on a non-supporting terminal **the wrapped text can vanish entirely.** Real adopters handle
this app-side: e.g. org-mode/Emacs integrations "fall back to plain heading text in windows that
don't support the protocol" — i.e. they *detect first, then choose* whether to emit OSC 66 or
plain text. **Conclusion: OSC 66 requires runtime detection + an app-side plain-text fallback.
It is not safe to emit blind.** (Sources: kitty spec backwards-compat note; degradation behavior
discussed in the [ratatui integration thread](https://github.com/ratatui/ratatui/discussions/2130)
and [neovide#3047](https://github.com/neovide/neovide/issues/3047).)

---

## 3. Other approaches investigated

- **iTerm2 proprietary sequences.** iTerm2 has a rich proprietary `OSC 1337` family (inline
  images `File=`, badges, etc.) and a [feature-reporting spec](https://iterm2.com/feature-reporting/),
  but **no proprietary "scale this text" escape**. There is no iTerm2-native path to larger/
  smaller cell text; it also does not implement OSC 66 or (per runtime testing, §4) classic
  DECDHL. On iTerm2 the only route to oversized text is rendering an **image** (OSC 1337 / sixel).
- **Sixel / kitty graphics protocol repurposed for big text.** Rasterize the glyphs and emit them
  as an image. Works on a much broader set (xterm, foot, WezTerm, Windows Terminal, kitty, …) and
  Raxol already has `packages/raxol_terminal/lib/raxol/terminal/ansi/sixel_renderer.ex`. But it is
  **not text**: no selection, no copy/paste, no reflow, no theming — and it's heavy. Viable only
  for static banners, not for a component framework's normal text flow.
- **terminal-wg / ecosystem status.** OSC 66 is the de-facto direction the modern-terminal
  community is converging on (kitty authored it; foot + Ghostty are implementing subsets). There
  is no ratified cross-vendor standard yet. Framework-level adoption is *just* starting:
  [ratatui#2130](https://github.com/ratatui/ratatui/discussions/2130) and
  [neovide#3047](https://github.com/neovide/neovide/issues/3047) are open explorations, not
  shipped features. Classic DECDWL/DECDHL is the opposite: old, and the modern terminals are
  actively declining it (kitty [#6816](https://github.com/kovidgoyal/kitty/issues/6816)).

---

## 4. Compatibility matrix

Two rows = the two capabilities. Cells: **Yes / Partial / No / Passthrough**. Every claim is
sourced in the notes. "Modern terminals" (kitty/ghostty/foot/wezterm/alacritty) are the ones
Raxol users are most likely on; note how thin real support still is.

| Terminal | Classic DECDWL/DECDHL | OSC 66 text sizing |
|---|---|---|
| **kitty** | **No** (declined by design) | **Yes — full** (scale `s`, width `w`, fractional `n/d`) |
| **Ghostty** | **No** | **Partial** — OSC 66 *parsed* as of 1.3.0 (2026-03-09), **not rendered yet** |
| **WezTerm** | **Yes** (renders; self-reports cap as 0) | **No** |
| **foot** | Unverified (no citation found) | **Partial** — implements the **`w=` width** part only |
| **iTerm2** | **No** (per runtime test) | **No** |
| **Windows Terminal** | **Yes** (conhost, since Win11) | **No** |
| **Alacritty** | **No** | **No** |
| **xterm** | **Yes** (reference impl) | **No** |
| **Konsole** | **Yes** since 21.08.0 (caveats) | **No** |
| **VTE / GNOME Terminal** | **No** (long-standing) | **No** |
| **Apple Terminal** | **Yes** (per runtime test) | **No** |
| **tmux** | **No** (no line-attr model) | **No / Passthrough fails** (issue #4461) |

**Per-cell sources & notes:**

- **kitty — OSC 66 full:** authored the protocol; shipped 0.40.0; "kitty ≥ 0.40.0 is currently
  the only terminal implementing OSC 66 with scale support"
  ([spec](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)). **Classic No:** kitty declines
  DECDHL/DECSWL — feature *request* [kitty#6816](https://github.com/kovidgoyal/kitty/issues/6816),
  and dgl's runtime test lists kitty as without DECDHL.
- **Ghostty — OSC 66 partial:** parser added, rendering not wired; "parse the Kitty text sizing
  protocol (OSC 66) … not implemented in the GUI yet," shipped as parse-only in
  [1.3.0 release notes](https://ghostty.org/docs/install/release-notes/1-3-0) (2026-03-09);
  tracking [ghostty#10333](https://github.com/ghostty-org/ghostty/issues/10333),
  [discussion#5563](https://github.com/ghostty-org/ghostty/discussions/5563). **Classic No:** dgl
  runtime test.
- **WezTerm — classic Yes:** renders double-width/height (dgl runtime test lists it as
  supported), though it self-reports `DECDHL=0` and has a pixelation report
  [wezterm#5233](https://github.com/wezterm/wezterm/issues/5233). **OSC 66 No:** no changelog
  entry; not in the implementers list.
- **foot — OSC 66 partial (width):** "foot implements the width specification … as an alternative
  to deriving the cell width itself" (kitty spec discussion / ghostty#10333 comparison). Classic
  DECDHL support **unverified** — no citation found; do not assume.
- **iTerm2 — both No:** runtime DECDHL test lists iTerm2 as *without* support
  ([dgl gist](https://gist.github.com/dgl/cfa357ab9f77818e28465e3c9e2435f3)); no OSC 66; only
  proprietary `OSC 1337` (images), no text-scale escape.
- **Windows Terminal — classic Yes:** implemented in conhost by j4james
  ([PR#8664](https://github.com/microsoft/terminal/pull/8664),
  [issue#11595](https://github.com/microsoft/terminal/issues/11595)), ships in Win11. **OSC 66 No.**
- **Alacritty — both No:** no line-attribute rendition support (design/complexity); dgl notes it
  *false-positives* the CPR probe but does **not** actually render double-height. No OSC 66.
- **xterm — classic Yes:** the reference implementation (terminalguide marks `ESC # 4`
  supported, "seems not to work with some fonts"). **OSC 66 No.**
- **Konsole — classic Yes (21.08.0+):** before 21.08 it treated top/bottom halves identically;
  from 21.08 it honors the correct half sequences but **different text on top vs bottom half is
  still unsupported** ([terminalguide](https://terminalguide.namepad.de/seq/a_esc_zhash_a4/)).
  No OSC 66.
- **VTE / GNOME Terminal — classic No:** long-standing non-support, GNOME
  [bug 118939 "double-height and -width lines not supported"](https://bugzilla.gnome.org/show_bug.cgi?id=118939);
  dgl runtime test lists VTE-based terminals as without. (Note: LeoNerd's *libvterm* ≠ GNOME
  *VTE* — libvterm/pangoterm added it; GNOME VTE did not.) No OSC 66.
- **Apple Terminal — classic Yes:** dgl runtime test lists it supported (with a cursor-report
  quirk requiring env heuristics). No OSC 66.
- **tmux — both No:** tmux's grid has no per-line rendition attribute, so classic sequences are
  dropped; for OSC 66, [tmux#4461](https://github.com/tmux/tmux/issues/4461) (closed) reports that
  even DCS `\ePtmux;…` passthrough **does not work** — tmux still accounts cells at 1× so wrapping
  the raw bytes corrupts geometry. Treat tmux as a hard "force fallback" boundary.

---

## 5. Runtime feature detection

**The blunt truth: none of these features are advertised by Device Attributes or terminfo.** You
must probe *behaviorally*.

- **Primary DA (`CSI c`) / Secondary DA (`CSI > c`)** identify the terminal class and version
  (e.g. secondary DA distinguishes kitty/WezTerm and gives a version number). Useful as an
  **allowlist heuristic** ("kitty ≥ 0.40 → OSC 66 scale"), but DA does *not* report either
  capability directly. Raxol already parses DA in
  `packages/raxol_terminal/lib/raxol/terminal/commands/device_handler.ex` and
  `.../command_server/device_ops.ex`.
- **DECRQM (`CSI ? Ps $ p`)** does **not** apply — neither capability is a DEC private mode, so
  there is nothing to query. (DECRQM is still the right tool for the *adjacent* modes in
  `f0-capability-detection.md`: 2026 sync, 2027 width, 2048 in-band resize.)
- **OSC 66 — the official CPR-measurement probe** (from the kitty spec). Emit, reading cursor
  column via CPR (`CSI 6 n`) between steps:
  1. `CR`, then `CPR` → baseline column.
  2. `ESC ] 66 ; w=2 ;␠ ST` (draw a space in 2 cells), then `CPR`.
  3. `ESC ] 66 ; s=2 ;␠ ST` (draw a space in a 2×2 block), then `CPR`.
  Interpretation: **all three columns equal → no support**; column advanced by 2 after step 2 →
  **width supported**; advanced by another 2 after step 3 → **scale supported**. This yields a
  three-state result (`:none | :width | :scale`).
- **Classic DECDHL — CPR-measurement probe** (from
  [dgl's checker](https://gist.github.com/dgl/cfa357ab9f77818e28465e3c9e2435f3)): apply `ESC # 3`,
  fill the line, request `CSI 6 n`, and infer support from whether the cursor wrapped. **Known
  unreliable** — Alacritty false-positives, Apple Terminal needs env heuristics. Prefer a
  DA/`$TERM`-based allowlist for classic if we bother with it at all.
- **Sync barrier (the governing rule from `f0-capability-detection.md`):** a terminal that
  doesn't support a query answers with *silence*, so every probe batch must end in a **Primary DA
  request (`CSI c`)** as a sentinel — read until DA1, and any expected reply that didn't arrive is
  "unsupported." The OSC 66 CPR probe slots straight into that one batched startup pass; it needs
  **no new I/O machinery**, just three extra query groups before the DA1 terminator. Today the
  only live probe is `packages/raxol_terminal/lib/raxol/terminal/driver/background_query.ex`
  (OSC 11 + DA fallback); f0 generalizes it, and this rides along.

**Graceful degradation when absent:**
- **OSC 66 absent →** emit the run as **plain text** (never emit the OSC wrapper — remember the
  payload can be swallowed, §2). Effective scale = 1.
- **Classic absent →** never emit `ESC # 3/4` (avoid the duplicate-line corruption); fall back to
  plain single-height text.
- **Under tmux →** force the plain fallback unconditionally, regardless of the outer terminal.

---

## 6. Integration sketch for Raxol (research-level, not a build plan)

**Direction of use.** This is about **Raxol-as-client** emitting to a *host* terminal (not about
Raxol's own emulator consuming these codes). So the emit point is the ANSI output stage and the
detection target is the host terminal.

**Emit stage — `Raxol.Terminal.Renderer`**
(`packages/raxol_terminal/lib/raxol/terminal/renderer.ex`). This stage already does the exact
shape we need: it chunks a row into runs and **wraps each run in an OSC pair** — see
`maybe_wrap_hyperlink/2` emitting `ESC ] 8 ; ; URL ST … ESC ] 8 ; ; ST` around a run. An OSC 66
run is structurally identical: chunk cells that share a *text-size* attribute, then wrap the
run's characters in `ESC ] 66 ; <meta> ; <chars> ST`. Concretely:
- Add an optional `:text_size` (or `:scale`/`:size`) field to the cell style, carried like any
  other SGR attribute.
- In `render_row_optimized/3`, add a `chunk_by` dimension on that field (alongside the existing
  hyperlink and style chunking), and wrap non-default runs via a new `maybe_wrap_text_size/2`.
- The existing per-run chunking keeps each payload well under the **4096-byte** OSC 66 limit for
  free.
- Default cells (scale 1, no explicit width) emit **byte-identical** output to today — zero cost
  when the feature is unused.

**Capability gate (off by default).**
- Extend the session capability record (the one `f0-capability-detection.md` fills) with a
  `text_sizing: :none | :width | :scale` field, populated by the OSC 66 CPR probe (§5).
- Add a config knob, e.g. `text_sizing: :off | :auto | :force` (default **`:off`**, or `:auto`
  once the probe lands). `:auto` emits OSC 66 only when `text_sizing != :none`; `:off` always
  emits plain text; `:force` for testing on a known-good terminal.
- The **layout decision must happen before layout, gated on caps.** Whether a heading occupies
  `s×` cells has to be resolved in the Preparer/LayoutEngine using the *effective* scale
  (=1 when unsupported), so geometry stays consistent with what the terminal actually draws. This
  is the same width-authority concern `Raxol.UI.TextMeasure` already owns — the `w=` value we
  emit and the width we lay out against must be the same number.

**Fallback render when unsupported.** Effective scale collapses to 1: the run is emitted as plain
styled text (drop the OSC 66 wrapper), and layout reserves normal-size cells. No corruption, no
vanished text. For classic double-height, fallback = single normal line (never the twice-emitted
form).

**Two lower-risk entry points worth calling out:**
1. **Width-declaration first (`w=`).** Even with zero "big text," emitting `w=` for
   emoji/CJK/grapheme clusters on kitty+foot lets Raxol *declare* width instead of guessing —
   directly retiring part of the CJK/emoji width fight threaded through `Raxol.UI.TextMeasure`.
   Smallest, safest, independently useful.
2. **The LiveView/browser surface is the *easy* place to scale text.** On the
   `raxol_liveview` surface Raxol controls pixel rendering; a scaled run is just a CSS transform,
   no host-terminal capability needed. If "big text in the browser terminal" is the actual goal,
   that surface can support it unconditionally while the native terminal path stays gated. (Would
   live in `TerminalBridge`, analogous to how it already emits animation CSS.)

**Out of scope / future.** Whether Raxol's *own* emulator (`raxol_terminal`, for its LiveView/SSH
rendering targets) should *parse and honor* incoming OSC 66 is a separate, larger question — most
relevant for the browser surface where scaling is trivial.

---

## 7. Recommendation

**Build OSC 66, not classic DECDWL/DECDHL, and phase it:**

1. **Phase 1 — `w=` width declaration** behind the capability gate. Lowest risk, degrades
   cleanly, solves an existing Raxol width-truth problem, supported by kitty **and** foot. This
   is worth doing even if we never ship "big text."
2. **Phase 2 — integer `s=` scale** for larger headings/banners, capability-gated, plain-text
   fallback. Real payoff on kitty today; Ghostty and others are on the way.
3. **Phase 3 (optional) — fractional `n/d` + super/subscript.** Nice-to-have; kitty-only for now.

**Why OSC 66 over classic:**
- The terminals Raxol targets (kitty/Ghostty/foot) are converging on OSC 66 and **explicitly
  decline classic** DECDHL (kitty, iTerm2, Alacritty, VTE, Ghostty all lack it) — so classic
  buys little reach among modern users.
- OSC 66 is **per-run, arbitrary-scale, and includes smaller text/super/subscript**; classic is
  whole-line, 2×-only, same-content-both-halves.
- Classic double-height's **duplicate-line degradation** is an active corruption risk;
  whole-line granularity is too coarse for a component framework.

**Keep a small optional classic path only if** we specifically want double-height banners to reach
xterm / WezTerm / Windows Terminal / Konsole where OSC 66 is absent — low priority, and only with
detection (never blind, because of the duplicate-line failure).

**Non-negotiables regardless of choice:**
- **Off by default, capability-gated.** Ship the detection probe (rides `f0-capability-detection.md`)
  before the emitter.
- **App-side plain-text fallback** — OSC 66 payloads can vanish on non-supporting terminals.
- **Force fallback under tmux** until tmux gains a cell model for it (not on any roadmap today).

---

## 8. Sources

Specs & standards:
- kitty text sizing protocol — https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
- kitty spec source (.rst) — https://github.com/kovidgoyal/kitty/blob/master/docs/text-sizing-protocol.rst
- kitty RFC #8226 (opened 2025-01-18) — https://github.com/kovidgoyal/kitty/issues/8226
- kitty #6816 (decline classic DECDHL/DECSWL) — https://github.com/kovidgoyal/kitty/issues/6816
- DEC VT510 ref — DECDHL https://vt100.net/docs/vt510-rm/DECDHL.html · DECDWL https://vt100.net/docs/vt510-rm/DECDWL.html
- terminalguide `ESC # 4` (byte encodings, xterm/Konsole notes) — https://terminalguide.namepad.de/seq/a_esc_zhash_a4/

Terminal support:
- Ghostty 1.3.0 release notes (OSC 66 parse-only) — https://ghostty.org/docs/install/release-notes/1-3-0
- Ghostty #10333 (implement OSC 66) — https://github.com/ghostty-org/ghostty/issues/10333
- Ghostty discussion #5563 — https://github.com/ghostty-org/ghostty/discussions/5563
- WezTerm #5233 (double-height pixelation) — https://github.com/wezterm/wezterm/issues/5233
- Windows Terminal PR #8664 (j4james, conhost DECDWL/DECDHL) — https://github.com/microsoft/terminal/pull/8664
- Windows Terminal #11595 — https://github.com/microsoft/terminal/issues/11595
- GNOME VTE bug 118939 (double-height/width not supported) — https://bugzilla.gnome.org/show_bug.cgi?id=118939
- dgl DECDHL support checker + per-terminal results — https://gist.github.com/dgl/cfa357ab9f77818e28465e3c9e2435f3
- iTerm2 feature-reporting spec — https://iterm2.com/feature-reporting/

Multiplexer & framework adoption:
- tmux #4461 (OSC 66 support; closed, passthrough fails) — https://github.com/tmux/tmux/issues/4461
- ratatui #2130 (text-sizing integration exploration) — https://github.com/ratatui/ratatui/discussions/2130
- neovide #3047 (support kitty text sizing) — https://github.com/neovide/neovide/issues/3047

Raxol code referenced (integration points):
- `packages/raxol_terminal/lib/raxol/terminal/renderer.ex` (ANSI emit stage; OSC 8 run-wrapping precedent)
- `packages/raxol_terminal/lib/raxol/terminal/driver/background_query.ex` (existing OSC 11 + DA probe)
- `packages/raxol_terminal/lib/raxol/terminal/commands/device_handler.ex`, `.../command_server/device_ops.ex` (DA/DSR/CPR)
- `docs/proposals/in-flight/f0-capability-detection.md` (batched DA1-sentinel probe substrate)
