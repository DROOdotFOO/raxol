# F0 — Bundled Terminal Capability Detection

Status: **draft / design (v1)** · Date: 2026-07-13 · Owner: V + Claude
Parent: `tui-steal-list.md` (the keystone the coverage-diff surfaced) · **Gates** everything
modern: sync-output 2026, in-band-resize 2048, explicit-width 2027, left/right-margins 69,
VT pages, kitty keyboard (F1b), styled underlines, truecolor certainty, image pixel-sizing.

Thesis: **one probe pass at startup, not per-feature bolt-ons.** Today Raxol has exactly
one live probe (`driver/background_query.ex`: OSC 11 `?` + a DA fallback) and otherwise
sniffs `$TERM`/`$TERM_PROGRAM` (`advanced_features.ex:85-110`). That's the wrong default —
`$TERM` lies inside tmux/screen, and env sniffing can't see per-terminal mode support.
Generalize the one probe we already have into a batched, DA1-terminated interrogation that
fills a session-immutable capability record.

---

## 1. Why this is the foundation

The coverage-diff against V's modern-terminal list found the misses aren't random features —
they share a missing substrate. You cannot **safely emit** mode 2026/2048/2027/69 without first
knowing the terminal supports them; blind emission either no-ops (best case) or corrupts
(worst case). The one fix — a real detection pass — de-risks the entire adoption backlog. It
also directly serves two things Raxol already cares about:

- **Width truth (mode 2027 / CPR probe).** Raxol fights the emoji/CJK width disagreement
  entirely app-side today (`Raxol.UI.TextMeasure` as the single width authority, CJK
  double-width rules threaded through every layer). Detection lets Raxol either *declare*
  width to the terminal (mode 2027) or *measure* what the terminal actually does (CPR probe)
  and build a correction table — instead of guessing and hoping both sides agree.
- **Light/dark (OSC 11 → mode 2031).** We already detect the ground once via OSC 11; the same
  pass upgrades to the mode-2031 push subscription so themes restyle live when the OS flips.

---

## 2. The one governing rule

**Silence is the failure mode, not a NAK.** A terminal that doesn't support a query says
*nothing*. So every query that can go unanswered is followed by a **Primary DA request
(`CSI c`) as the last byte-group** — DA1 is answered by every VT-class terminal, so its reply
is a sync barrier: read until DA1, and any wanted reply that didn't arrive before it is
"unsupported." This converts an unbounded "did it ignore me?" wait into a bounded
read-to-sentinel. (kitty and notcurses both codify this exact pattern.)

Two corollaries that shape the parser:

- **Parse replies by grammar, not position.** In-order reply is *mostly* true but not
  guaranteed (OSC reordering is a documented terminal bug). Dispatch each reply on its opening
  bytes (`CSI` vs `DCS` vs `OSC` vs `APC`) and echoed parameters — never "the 3rd reply is my
  3rd query."
- **Drain through the sentinel, then flush.** Any reply left unconsumed leaks to the shell as
  literal keystrokes later. We already consume-unmapped-CSI (the #443 hardening) — extend that
  discipline to draining past DA1 before the event loop starts.

---

## 3. What we probe (one batched write, this order)

Env seed first (free, no I/O): `$TERM`, `$COLORTERM`, `$TERM_PROGRAM(_VERSION)`, `$NO_COLOR`,
`$TMUX`. Load the `$TERM` terminfo entry as the Core-tier baseline. Then one raw-mode write:

| # | Query bytes | Detects | Reply to accept |
|---|-------------|---------|-----------------|
| 1 | `OSC 11 ; ? ST` | background → theme + luminance | `OSC 11 ; rgb:R/G/B` (BEL **or** ST) |
| 2 | `CSI ? u` | kitty keyboard (F1b gate) | `CSI ? <flags> u` before DA1 |
| 3 | `CSI ? 2026 $ p` | sync output | `CSI ? 2026 ; 1\|2 $ y` |
| 4 | `CSI ? 2027 $ p` | grapheme-cluster width | `; 1\|2 $ y` (absence → CPR probe, §6) |
| 5 | `CSI ? 2048 $ p` | in-band resize (primary; SIGWINCH fallback) | `; 1\|2 $ y` |
| 6 | `CSI ? 69 $ p` | left/right margins (DECLRMM) | `; 1\|2 $ y` |
| 7 | `CSI ? 2031 $ p` | theme-change push | `; 1\|2 $ y` |
| 8 | `CSI ? 1004/2004/1049/1006/1016 $ p` | focus / paste / alt / SGR-mouse / pixel-mouse | `; 1\|2 $ y` each |
| 9 | `CSI > 0 q` | terminal identity (XTVERSION) | `DCS > \| <name ver> ST`, prefix-match |
| 10 | `DCS + q 524742 ; 544e ; 536d756c78 ST` | truecolor `RGB`, name `TN`, styled-underline `Smulx` | `DCS 1 + r <hex>=<hex> ST` |
| 11 | `CSI 16 t` (+ `14 t`, `18 t`) | cell pixel size (image sizing, 2048 px fallback) | `CSI 6 ; h ; w t` |
| 12 | `CSI ? 1 ; 1 S` (XTSMGRAPHICS) | Sixel color registers | `CSI ? 1 ; 0 ; <n> S` |
| 13 | `APC _ G i=31,s=1,v=1,a=q,t=d,f=24;AAAA ST` | kitty graphics | `APC _ G i=31;OK ST` |
| 14 | `CSI c` | **DA1 SENTINEL — must be last** | `CSI ? … c` (VT level + attrs `4`=sixel, `22`=color) |

Truecolor is decided in priority order, not from one probe: `$COLORTERM ∈ {truecolor,24bit}`
(free) → XTGETTCAP `RGB` (#10) → SGR `48:2:R:G:B` + DECRQSS round-trip fallback. `$COLORTERM`
alone is untrusted — it doesn't survive ssh/sudo/tmux.

Per-terminal quirks to hardcode around (from the catalog): **Alacritty** reports 2026 support
but its DECRQM value is stuck at `2`; **Windows Terminal** answers no XTVERSION, no pixel
geometry, no 2048 (gate win32-input on platform, not DECRQM); **foot** 2048 is TODO → `0`;
DECRQM `Pm ∈ {1,2}` = supported, `{0,3,4}`/silence = not (no modern terminal false-positives).

---

## 4. Reply parser

A proper VT500 state machine (Paul Williams), not regex-on-a-buffer — because replies span
four framings (`CSI`/`DCS`/`OSC`/`APC`) and OSC/DCS terminate with **either** BEL (`0x07`)
**or** ST (`ESC \`); a parser that accepts only one lets a reply swallow the next. Raxol
already has CSI parsing (the #443 total-CSI hardening) and OSC handling (`osc_handler.ex`);
F0 adds DCS (`ESC P … ST`) and APC (`ESC _ … ST`) response parsing and a dispatch-by-grammar
router. This is the same parser the emulator side needs anyway to *host* guest apps that use
these sequences (the sync-output 2026 emulator-parse gap the audit flagged).

---

## 5. The capability record + tiers

Session-immutable, computed once, cached in `:persistent_term` (same mechanism the H-K solver
already uses for `:terminal_background`):

```elixir
defmodule Raxol.Terminal.Capabilities do
  defstruct [
    :identity,        # {name, version} from XTVERSION | DA2 fallback | nil
    :tier,            # :core | :modern | :rich  (terminfo.dev classification)
    :unicode,         # :none | :wide | :grapheme  (orthogonal axis)
    :truecolor,       # bool
    :sixel,           # bool + color_register_count
    :kitty_graphics,  # bool
    :kitty_keyboard,  # flag bitset | nil
    :sync_output,     # bool  (mode 2026)
    :grapheme_width,  # :mode_2027 | :measured | :assumed  (see §6)
    :in_band_resize,  # bool  (mode 2048)
    :lr_margins,      # bool  (mode 69)
    :theme_events,    # bool  (mode 2031)
    :cell_px,         # {w, h} | nil
    :styled_underline,# bool  (Smulx)
    :multiplexer,     # :none | :tmux | :screen  (clamps tier)
    width_table: nil  # correction table when grapheme_width == :measured
  ]
end
```

Tiers reuse terminfo.dev's published classification as *output labels* (not the probe):
**Core** (SGR/cursor/alt-screen floor) · **Modern** (truecolor, bracketed paste, focus, mouse)
· **Rich** (kitty keyboard/graphics, hyperlinks, semantic prompts), with **Unicode** as an
orthogonal axis (a terminal can be Rich but Unicode-weak). Bucket the runtime probe result into
a tier; never trust a static table for a live session (tmux/version-drift defeats it).

---

## 6. Width detection (the mode-2027-independent path)

If #4 (DECRQM 2027) says supported → `grapheme_width: :mode_2027`, declare widths to the
terminal, done. If **unsupported** (can't be inferred from absence), run a *tiny* CPR battery
on a scratch off-screen line: for each of {wide CJK, VS-16 emoji `❤️`, ZWJ family `🧑‍🌾`,
regional-indicator flag `🇺🇸`, combining mark}, print the grapheme → `CSI 6 n` → width =
`reported_col − start_col`. Compare to `TextMeasure`'s table; store a correction table
(`grapheme_width: :measured`). Keep the battery ~5 graphemes — the full ucs-detect suite is one
round-trip *per grapheme* and "super cursed." This feeds `Raxol.UI.TextMeasure` directly — the
correction table is exactly what its single-source-of-width promise needs to stay honest across
terminals that disagree.

---

## 7. Algorithm

```
0. If stdout not a TTY → assume Core-minus, skip probing entirely (CI/pipe path).
   Enter raw mode BEFORE any query. Read env seed. If $TMUX set → multiplexer: :tmux.
1. Compose the one batched write (§3), DA1 (CSI c) LAST.
2. Read with the VT500 state machine; dispatch each reply by grammar (§4).
   Stop at the DA1 sentinel; then DRAIN residual bytes.
3. Timeout guard: no first byte within T (~100ms local; ~1s if $SSH_* / remote) →
   abort, mark unanswered caps unsupported, fall back to XTVERSION/DA2 identity table
   for whatever partial identity arrived. Extend once if first byte seen, sentinel not.
4. tmux: if :tmux and allow-passthrough available, re-issue identity + color queries
   wrapped as DCS tmux ; <ESC-doubled payload> ST to reach the OUTER terminal; keep
   each payload < ~60 chars. If passthrough off (default since tmux 3.3a) → clamp to a
   conservative Modern-minus tier, do NOT trust $TERM=screen.
5. If grapheme_width unresolved and exact widths needed → CPR battery (§6).
6. Classify → Capabilities struct → :persistent_term. Immutable for the session.
7. Subscribe to mode-2031 theme events if theme_events; else keep the OSC 11 one-shot.
```

Runs in the driver's `init`/`handle_continue` **before** the app subscribes to input events —
never mid-frame, or replies interleave with user keypresses.

---

## 8. What it replaces / wires into (grounded)

- **Replaces** the `$TERM`/`$TERM_PROGRAM` sniffing in `advanced_features.ex:85-110,168-178`
  with real probes; keeps env as the free first-pass seed only.
- **Generalizes** `driver/background_query.ex` (today: OSC 11 `?` + `\e[c` DA fallback,
  `scan/1`) into the full batched pass — same shape, more queries, one sentinel.
- **Feeds** `Raxol.UI.TextMeasure` the width correction table (§6).
- **Gates emitters**: only emit `CSI ?2026h` sync-frames, `CSI ?2048h` in-band resize,
  `Smulx` styled underlines, kitty-keyboard negotiation (F1b) when the cap is present.
- **Unblocks the SGR colon-subparam fix**: `sgr_processor.ex:78` splits params on `;` only, so
  all colon-form SGR (`4:3` underline styles, colon-form colors) silently drops today — F0's
  `styled_underline` cap is meaningless until that parser bug is fixed; bundle the fix here.
- **In-band resize** (`driver.ex:108` currently polls `:io.rows()`): when `in_band_resize`,
  consume `CSI 48 ; rows ; cols ; ph ; pw t` from the input stream as the primary resize path;
  **keep SIGWINCH as the fallback** (V's call — 2048-primary, SIGWINCH-fallback is the robust
  pairing, and it also yields cell-pixel size for free).

---

## 9. Risks

- **tmux passthrough is off by default (≥3.3a)** and truncates long payloads (~60 chars);
  DCS *responses* aren't always forwarded. Over SSH-into-tmux (a real Raxol deployment via the
  SSH surface) we must degrade gracefully to a conservative tier, not hang.
- **SSH latency**: the 100ms local timeout is too tight remotely; detect `$SSH_*` and widen.
- **Echo-leak**: a terminal that echoes an unknown query as literal input corrupts the prompt
  if we don't drain past the sentinel. Mitigated by the existing consume-unmapped discipline,
  but the drain-past-DA1 step is mandatory.
- **Windows Terminal** is the biggest blind spot (no XTVERSION / pixel geometry / 2048) — the
  pure-Elixir IOTerminal path must not assume any of it; gate on platform.

---

## 10. Effort + sequence

Effort **4** (self-contained in raxol_terminal; no cross-package integration, unlike F1/F2).

1. VT500 reply parser: add DCS + APC response handling + grammar-dispatch router (extends the
   #443 CSI work). Property-test against recorded fixtures per terminal.
2. `Capabilities` struct + `:persistent_term` cache + tier classifier.
3. Batched query composer + read-to-sentinel + timeout + drain. Mock-terminal unit tests for
   the no-reply / partial-reply / echo-leak paths (CI runs with `SKIP_TERMBOX2_TESTS=true`, so
   this MUST be a pure mock test, not a real-terminal test).
4. tmux passthrough wrap + conservative clamp.
5. Wire consumers: TextMeasure correction table, emitter gates, 2048 resize path (+ SIGWINCH
   fallback), 2031 theme events.
6. Fix the SGR colon-subparam parser (unblocks styled underlines).

---

## 11. Open questions for V

- **G-width-eagerness**: run the CPR width battery *always* at startup (adds ~5 round-trips,
  ~tens of ms), or *lazily* only when the app actually renders wide/emoji content? Startup cost
  vs first-render correctness.
- **G-tier-policy**: does Raxol *gate features* by detected tier (refuse to emit Rich sequences
  below Rich), or always attempt + rely on graceful no-op? The former is safer over SSH/tmux;
  the latter is simpler.
- **G-detection-scope**: driver-as-client detection (what the host terminal supports) is clearly
  in scope. Do we *also* want the emulator-as-host side to advertise these caps to guest apps
  (answer DECRQM/XTVERSION/XTGETTCAP for 2026/2027/…), so Raxol-hosting-Raxol works? That's a
  second, larger workstream — flag now, decide later.
