# Capability capture fixtures

One JSON file per `<terminal>-<context>`, each a complete end-to-end
regression for the capability slice: the exact bytes a probe wrote, the exact
bytes that terminal wrote back, and the classification those bytes must
produce.

`Raxol.Test.CapabilityFixtures` (`../../../support/capability_slice_fixtures.ex`)
loads them, and one table-driven test iterates `all/0`, so dropping a new
capture into this directory adds a regression with zero code.

## Producers

- The T0 terminal matrix (`scripts/harness/t0/`) runs the real byte-capture
  harness against kitty, iTerm2, WezTerm, Ghostty, Alacritty, GNOME VTE, and
  Apple Terminal, bare or under tmux, and writes one file per run.
- Hand-authored edge fixtures use the same schema with
  `"terminal": "synthetic"` and cover the conditions a real terminal will not
  reproduce on demand: silence, reorder, echo leak, keystroke interleave,
  partial-then-EOF, tmux garble.

## Schema (`raxol.capability.capture/1`)

Control bytes are lowercase hex with no separators in every `*_hex` field; the
loader decodes them with `Base.decode16!(s, case: :lower)`.

```jsonc
{
  "schema": "raxol.capability.capture/1",
  "terminal": "alacritty",
  "terminal_version": "0.13.2",
  "context": "bare",                         // bare | tmux
  "env": {                                   // env seed the probe also saw
    "TERM": "alacritty",
    "COLORTERM": "truecolor",
    "TERM_PROGRAM": null,
    "TMUX": null,
    "SSH_TTY": null
  },
  "query_hex": "1b5d31313b3f07...",          // exact batched write
  "reply_hex": "1b5d31313b7267623a...",      // exact bytes read back, in order
  "expected_leak_hex": "...",                // optional: bytes that leaked to the app
  "notes": "DECRQM 2026 value stuck at 2 (never flips to 1 after set).",
  "expected": {                              // the pinned classification
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
  "expected_tier": "inline_log"              // degradation-ladder golden
}
```

## Design points

- `reply_hex` is the whole raw read, exactly as the tty delivered it,
  interleaving included. A capture is a complete end-to-end regression, not a
  curated snippet.
- `expected` is authored once from the first trusted capture and becomes the
  pinned regression. A terminal upgrade that changes replies fails loudly
  against it, which is the terminal-drift signal.
- `context` decides which risks a fixture exercises. The `tmux` captures are
  where passthrough-off garble and the conservative clamp live.
