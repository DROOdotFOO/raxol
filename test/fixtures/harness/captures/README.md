# `captures/`: capability-capture schema

This directory hosts the capability capture fixtures described in
`docs/proposals/in-flight/harness-ui-testing/04-capability.md` §2 (T1
capability slice + T3 degradation ladder test design). It is prepared
here, ahead of T0/T1, so that unit lands with a stable, documented
directory contract instead of inventing one under time pressure: no
capture files are checked in yet; T0 writes real ones here, and T1
consumes them.

## Producers and consumer

- **T0** (keystone prototype, terminal matrix) runs the real byte-capture
  harness against kitty / iTerm2 / WezTerm / Ghostty / Alacritty /
  GNOME-VTE / Apple Terminal (each bare / tmux / ssh / ssh+tmux) and
  writes one `capture/<terminal>-<context>.json` per run.
- Hand-authored **edge fixtures** use the same schema with
  `"terminal": "synthetic"` and live alongside as `capture/synthetic-*.json`
  (silence, reorder, echo-leak, partial-EOF: the constructed conditions
  a real terminal won't reliably reproduce on demand).
- **T1**'s positive suite (`CAP-P-01` et al.) table-drives over every file
  in this directory with zero code added per new capture; see
  `Raxol.Test.CapabilityFixtures.load!/1` (T1's loader, not built by this
  unit).

## Schema (`raxol.capability.capture/1`)

One JSON file per `<terminal>-<context>`. Control bytes are **lowercase
hex, no separators** in the two `*_hex` fields; the loader decodes them to
binary via `Base.decode16!(s, case: :lower)`.

```jsonc
{
  "schema": "raxol.capability.capture/1",
  "terminal": "alacritty",
  "terminal_version": "0.13.2",
  "context": "bare",                        // bare | tmux | ssh | ssh+tmux
  "env": {                                   // env seed the probe also sees
    "TERM": "alacritty",
    "COLORTERM": "truecolor",
    "TERM_PROGRAM": null,
    "TMUX": null,
    "SSH_TTY": null
  },
  "query_hex": "1b5d31313b3f071b5b3f753...", // exact batched write (reference)
  "reply_hex": "1b5d31313b7267623a...",      // exact bytes read back, in order, sentinel included
  "notes": "DECRQM 2026 value stuck at 2 (never flips to 1 after set).",
  "expected": {                              // golden, asserted by CAP-P-*
    "identity":       ["Alacritty", "0.13.2"],
    "tier":           "modern",
    "unicode":        "wide",
    "truecolor":      true,
    "sync_output":    true,                  // quirk: 2 is 'recognized' => supported
    "grapheme_width": "assumed",
    "in_band_resize": false,
    "lr_margins":     false,
    "theme_events":   false,
    "kitty_keyboard": null,
    "sixel":          false,
    "multiplexer":    "none"
  },
  "expected_tier": "inline_log"              // T3 ladder golden
}
```

Design points (from 04-capability.md §2, reproduced here so this
directory is self-explanatory without cross-referencing the proposal):

- `reply_hex` is the **whole raw read**, exactly as the tty delivered it,
  including any interleaving the capture happened to catch. A capture is
  a complete end-to-end regression, not a curated snippet.
- `expected` is authored once from the first trusted capture and becomes
  the pinned regression; a terminal upgrade that changes replies fails
  loudly against it (the "terminal drift" signal).
- `context` drives which risks a fixture exercises: `tmux` / `ssh+tmux`
  captures are where passthrough-off garble and the conservative clamp
  live.

See `harness-ui-testing/04-capability.md` for the full reply-scanner /
probe-reducer / classifier design this schema feeds.
