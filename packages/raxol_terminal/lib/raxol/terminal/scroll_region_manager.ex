defmodule Raxol.Terminal.ScrollRegionManager do
  @moduledoc """
  DECSTBM scroll-region lifecycle for the inline-hybrid render substrate
  (unit T2a, `docs/proposals/in-flight/harness-ui-roadmap.md`; suite design
  in `harness-ui-testing/02-renderer.md` §0 + §3 INV-5).

  Orientation is LOCKED (T0's verdict, restated in `02-renderer.md` §0 so
  T2a does not re-derive it): the scroll region is the TOP `1..(H-N)` rows
  -- history, scrolling, feeds native scrollback on real terminals -- and
  the footer is the `N` rows below it, `(H-N+1)..H`, OUTSIDE the region and
  pinned (T2c's buffer-diff viewport). `N` (`footer_rows`) is caller-chosen
  and held constant across resize; only `H` (`rows`) varies.

  ## What this module owns

    * Emitting `CSI 1;(H-N) r` once at `start/3` and again, exactly once,
      on every `resize/3` -- never more, never a full-screen clear (`\\e[2J`/
      `\\e[3J` are forbidden on the inline path per N06: real-hardware
      measurement showed `\\e[2J` wipes native scrollback on wezterm/kitty,
      so a resize that cleared the screen to redraw the region would nuke
      already-sealed history. `resize/3` therefore only ever writes the one
      DECSTBM sequence, nothing else).
    * Recomputing the history/footer split on resize, keeping `footer_rows`
      constant.
    * Exposing the split as plain row ranges (`history_range/1`,
      `footer_range/1`) for T2b (append path) and T2c (footer viewport) to
      build on.

  ## What this module deliberately does NOT own

  **Teardown.** T2d's `Raxol.Terminal.InlineDriver.Sequences.teardown_bytes/1`
  already emits `CSI r` (full-screen release) unconditionally, as step 2 of
  its canonical order, on every exit path it can reach (clean stop, trapped
  crash) and is already idempotent (`InlineDriver.emit_teardown/2` guards on
  `torn_down?`). Before this module existed, that `CSI r` was a no-op reset
  of the terminal's already-default (unset) region. After this module sets a
  REAL region via `start/3`, the exact same, unmodified `CSI r` now
  meaningfully releases it -- the two units compose by construction, with
  no new code needed on either side and no risk of a double release. This
  module therefore has no `teardown/1` / `release/1` function of its own:
  adding one would either duplicate T2d's release byte-for-byte (redundant,
  and a foot-gun if the two ever drift) or require this module to own an
  output device across the whole driver lifetime, which is T2d's job, not
  T2a's. `kill -9` is consequently the same **documented residual** T2d
  already names: no process is left alive to run either module's teardown;
  the honest mitigations are the same (a kernel tty reset, or the
  documented `printf '\\e[r'` recovery one-liner) and are not re-litigated
  here (see `harness-ui-testing/03-lifecycle.md` §0 risk 4).

  ## Package boundary note (why this module hand-rolls its own bytes)

  `Raxol.UI.Rendering.PaintAuthority.Dialect.region_set/2` (main `raxol`,
  `lib/raxol/ui/rendering/paint_authority.ex`) is the shared DECSTBM byte
  builder T2b/T2c's PaintAuthority implementations and the TB byte-capture
  oracle (`Raxol.Harness.Test.SealOracle`) are built against. This module
  lives in the `raxol_terminal` package, which -- per the repo's dependency
  graph (main `raxol` depends on `raxol_terminal`, never the reverse) --
  cannot import anything under main `raxol`'s `lib/raxol/ui/`. So
  `region_set_bytes/2` below reproduces `Dialect.region_set/2`'s exact wire
  format (`CSI top;bottom r`) locally rather than aliasing it. The two are
  byte-identical by construction (and pinned by a test asserting exactly
  that), so the TB oracle (`SealOracle.scroll_region/1`,
  `SealOracle.region_sets/1`) parses this module's output the same way it
  parses a `PaintAuthority` implementation's -- the oracle works off raw
  bytes and vocabulary, not module identity.

  ## The (B)-upgrade seam (thin; does not implement (B))

  Per the D-PA RULING (roadmap §0): ship (A) seal-time-only as the default,
  with (B) soft-owned-history as a **runtime-detected, per-terminal,
  additive** upgrade -- RB's real-hardware C-4 probe found iTerm2
  genuinely reflows sealed history on resize, so a future unit (T2b or a
  capability-gated follow-on) may re-emit a bounded tail of recently-sealed
  blocks on a reflow-capable terminal. This module does not probe
  capabilities and does not re-emit any content -- that decision and its
  bytes belong entirely to T2b. What it DOES expose is the one fact that
  decision needs from the region-geometry side: `geometry_changed?/2`, a
  pure comparison of two states' `region_top`, so a future caller can tell
  "this resize actually moved the history/footer split" apart from a
  width-only resize that left `region_top` untouched (in which case there
  is nothing for policy (B) to reflow in the first place, independent of
  whatever the capability probe says). Nothing here upgrades to (B); this
  is the seam, not the upgrade.
  """

  @enforce_keys [:device, :rows, :footer_rows, :region_top]
  defstruct [:device, :rows, :footer_rows, :region_top]

  @type t :: %__MODULE__{
          device: IO.device(),
          rows: pos_integer(),
          footer_rows: non_neg_integer(),
          region_top: pos_integer()
        }

  # ---------------------------------------------------------------------
  # Pure geometry (no device, no I/O) -- reused by both start/3 and
  # resize/2, and directly testable with zero process/device setup.
  # ---------------------------------------------------------------------

  @doc """
  The history region's row COUNT (`H - N`), clamped to at least 1: a
  terminal shorter than the footer still gets a 1-row history region
  rather than a zero/negative DECSTBM range (which xterm and friends treat
  inconsistently -- clamping here means this module never emits one).
  """
  @spec region_top(pos_integer(), non_neg_integer()) :: pos_integer()
  def region_top(rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    max(rows - footer_rows, 1)
  end

  @doc """
  The DECSTBM byte sequence for a given `rows`/`footer_rows` split: `CSI
  1;(H-N) r`, 1-based inclusive, byte-identical to
  `Raxol.UI.Rendering.PaintAuthority.Dialect.region_set(1, region_top(rows,
  footer_rows))` (see the package-boundary note in the moduledoc for why
  this is a local copy rather than an alias).
  """
  @spec region_set_bytes(pos_integer(), non_neg_integer()) :: binary()
  def region_set_bytes(rows, footer_rows) do
    "\e[1;#{region_top(rows, footer_rows)}r"
  end

  @doc """
  History region row range, 1-based inclusive, TOP-anchored: `1..(H-N)`.
  `region_top/2`'s clamp guarantees `top >= 1`, so this is never empty.
  """
  @spec history_range(t()) :: Range.t()
  def history_range(%__MODULE__{region_top: top}), do: 1..top//1

  @doc """
  Footer row range, 1-based inclusive, OUTSIDE the scrolling region and
  below it: `(H-N+1)..H`. Explicit `//1` step (never the bare `first..last`
  form): on a degenerate terminal where `rows <= footer_rows`,
  `region_top/2`'s clamp gives history its minimum 1 row first, which can
  leave NO rows for the requested footer at all (`top >= rows`) -- without
  the explicit step, `first..last` silently REVERSES into a descending
  range when `last < first` (Elixir's legacy two-arg `Range` behavior),
  which would make this range compare as non-empty and, worse, overlap
  `history_range/1` at row 1. With the explicit step this is correctly
  empty instead.
  """
  @spec footer_range(t()) :: Range.t()
  def footer_range(%__MODULE__{rows: rows, region_top: top}),
    do: (top + 1)..rows//1

  @doc "Current history-region row count (`H - N`) -- the footer boundary."
  @spec region_top(t()) :: pos_integer()
  def region_top(%__MODULE__{region_top: top}), do: top

  @doc "The `footer_rows` (`N`) this manager was started/resized with. Constant across resize."
  @spec footer_rows(t()) :: non_neg_integer()
  def footer_rows(%__MODULE__{footer_rows: n}), do: n

  @doc "Current total row count (`H`)."
  @spec rows(t()) :: pos_integer()
  def rows(%__MODULE__{rows: rows}), do: rows

  @doc """
  True if the two states' history/footer split point differs -- i.e. the
  resize between them actually changed geometry, not just width. See the
  moduledoc's "(B)-upgrade seam" section: this is the thin fact a future
  reflow-re-emit decision (owned elsewhere) would consult.
  """
  @spec geometry_changed?(t(), t()) :: boolean()
  def geometry_changed?(%__MODULE__{region_top: a}, %__MODULE__{region_top: b}),
    do: a != b

  # ---------------------------------------------------------------------
  # The I/O seam -- device is a parameter (mirrors T2d's InlineDriver: a
  # StringIO/collector device makes this Tier A -- byte-capture, no pty, no
  # termbox -- per harness-ui-testing/03-lifecycle.md §1.1's hard ask).
  # ---------------------------------------------------------------------

  @doc """
  Sets the history/footer split for a freshly-started inline session:
  computes `region_top = rows - footer_rows` (clamped, see `region_top/2`)
  and writes the DECSTBM region-set bytes to `device` exactly once. Returns
  the new manager state.

  Composes with T2d (see moduledoc): no teardown call is needed from this
  module. `InlineDriver`'s existing, unmodified `emit_teardown/2` releases
  whatever region this call set.
  """
  @spec start(IO.device(), pos_integer(), non_neg_integer()) :: t()
  def start(device, rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    top = region_top(rows, footer_rows)
    IO.write(device, region_set_bytes(rows, footer_rows))

    %__MODULE__{
      device: device,
      rows: rows,
      footer_rows: footer_rows,
      region_top: top
    }
  end

  @doc """
  Recomputes the region for a new row count, holding `footer_rows`
  constant, and re-emits the DECSTBM region-set bytes to the state's device
  EXACTLY ONCE (`CSI 1;(H'-N) r`) -- the single write this function makes.
  Never emits `\\e[2J`/`\\e[3J` or any other byte (INV-3 / N06: a
  full-screen clear on resize would wipe already-sealed native scrollback
  on wezterm/kitty). The footer's CONTENT is not this module's concern
  (T2c owns repainting it); only the row-range split is recomputed here.
  """
  @spec resize(t(), pos_integer()) :: t()
  def resize(
        %__MODULE__{device: device, footer_rows: footer_rows} = state,
        new_rows
      )
      when is_integer(new_rows) and new_rows > 0 do
    top = region_top(new_rows, footer_rows)
    IO.write(device, region_set_bytes(new_rows, footer_rows))
    %{state | rows: new_rows, region_top: top}
  end
end
