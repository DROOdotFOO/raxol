defmodule Raxol.Terminal.ScrollRegionManager do
  @moduledoc """
  DECSTBM scroll-region lifecycle for the inline-hybrid render substrate.

  **The invariant this module exists to hold**: the top rows of the
  terminal are history (native scrollback, freely scrolling) and the
  bottom `N` rows are a pinned footer that must never scroll into history.
  Everything below is either geometry math for that split, or the DECSTBM
  bytes that ask a real terminal to enforce it -- and this module never
  claims the pin succeeded when the terminal will actually ignore the
  request (see "Degenerate terminals" below).

  Orientation is fixed: the scroll region is the TOP `1..(H-N)` rows
  -- history, scrolling, feeds native scrollback on real terminals -- and
  the footer is the `N` rows below it, `(H-N+1)..H`, OUTSIDE the region and
  pinned. `N` (`footer_rows`) is caller-chosen and constant across
  `resize/2` (only `H`, `rows`, varies there); `set_footer_rows/2` is the
  one function that varies `N` instead, holding `H` constant -- the seam a
  footer-hosted overlay picker uses to grow or shrink the pinned footer
  viewport without a real terminal resize.

  ## Degenerate terminals: never emit a DECSTBM the terminal will ignore

  DECSTBM (`CSI top;bottom r`) requires `top < bottom` -- a 2-row minimum
  region. This module always requests `top = 1`, so the region is only
  valid when `bottom = history_bottom(rows, footer_rows) >= 2`. When
  `rows - footer_rows < 2` (a terminal too short for its footer plus a
  1-row history minimum), `history_bottom/2`'s clamp still returns `1` (so
  row-range math never sees a zero/negative value) -- but emitting
  `CSI 1;1 r` for that `top == bottom` request is a LIE: real terminals
  (xterm, wezterm, kitty) silently IGNORE it, leaving whatever region was
  previously active (or the full-screen default) untouched, while the
  caller believes the footer is now pinned. That silent unpin is exactly
  the bug this section exists to prevent.

  When `degenerate?(rows, footer_rows)` is true, `region_set_bytes/2`
  therefore emits the full-screen release (`CSI r`) instead of a lying
  `1;1r`: an honest un-pin rather than a pretend-pin a real terminal
  ignores. The returned struct also records `degenerate?: true` so callers
  can detect the condition and adapt -- e.g. falling back to redrawing the
  footer every frame instead of relying on the pin. The documented limit:
  **the footer cannot be pinned when `rows < footer_rows + 2`.**
  `history_bottom/2` still returns a sane (`>= 1`) row in this case, purely
  for append-path row-range math -- it does not mean the pin is active;
  callers must consult `degenerate?/1` for that.

  ## What this module owns

    * Emitting `CSI 1;(H-N) r` once at `start/3` and again, on every
      `resize/2` that actually changes the history/footer split point (see
      "Geometry-gated resize emission" below) -- never more, never a
      full-screen clear. `\\e[2J`/`\\e[3J` are forbidden on the inline path:
      measurement showed `\\e[2J` wipes native scrollback on wezterm/kitty,
      so a resize that cleared the screen to redraw the region would nuke
      already-sealed history.
    * Recomputing the history/footer split on resize, keeping `footer_rows`
      constant.
    * Exposing the split as plain row ranges (`history_range/1`,
      `footer_range/1`) for the append path and footer viewport to build on.

  ## Geometry-gated resize emission

  `resize/2` re-emits DECSTBM only when the new `history_bottom` differs from
  the current one -- the same comparison `geometry_changed?/2` exposes.
  DECSTBM has a documented VT100 side effect: it homes the cursor. A
  width-only resize (rows unchanged, so `history_bottom` is unchanged too) has
  nothing to re-pin; re-emitting the identical `CSI 1;(H-N) r` in that case
  would move the cursor as a side effect for zero geometric benefit.
  `resize/2` skips the write (zero bytes emitted) when geometry is
  unchanged, and still emits -- with the accompanying cursor-homing side
  effect -- whenever the split point actually moves.

  ## Emission ownership (avoid duplicate DECSTBM owners)

  `Raxol.UI.Rendering.PaintAuthority.Dialect.region_set/2` (main `raxol`)
  is a second, independent DECSTBM byte builder, and `IOAuthority.resize/3`
  (`lib/raxol/ui/rendering/paint_authority.ex`) calls it with a hardcoded
  1-row footer on every resize. That is a SEPARATE, legacy/basic rendering
  profile -- it is not wired at the same time as this module. In the
  inline harness profile (driven via `InlineAuthority`), THIS module
  (`Raxol.Terminal.ScrollRegionManager`) is the SOLE runtime owner of
  DECSTBM emission; `IOAuthority` must never be wired simultaneously with
  it against the same output device, or the two would race to set
  independent, inconsistent regions. This is a documentation-only
  boundary: fixing `IOAuthority`'s hardcoded footer or merging the two
  emitters is out of scope for this module.

  ## What this module deliberately does NOT own

  **Teardown.** `Raxol.Terminal.InlineDriver.Sequences.teardown_bytes/1`
  already emits `CSI r` (full-screen release) unconditionally, as step 2 of
  its canonical order, on every exit path it can reach (clean stop, trapped
  crash) and is already idempotent (`InlineDriver.emit_teardown/2` guards on
  `torn_down?`). Before this module existed, that `CSI r` was a no-op reset
  of the terminal's already-default (unset) region. After this module sets a
  REAL region via `start/3`, the exact same, unmodified `CSI r` now
  meaningfully releases it -- the two compose by construction, with no new
  code needed on either side and no risk of a double release. This module
  therefore has no `teardown/1` / `release/1` function of its own: adding
  one would either duplicate the driver's release byte-for-byte (redundant,
  and a foot-gun if the two ever drift) or require this module to own an
  output device across the whole driver lifetime, which is the driver's job,
  not this module's. `kill -9` is consequently the same **documented
  residual** the driver already names: no process is left alive to run
  either module's teardown; the honest mitigations are the same (a kernel
  tty reset, or the documented `printf '\\e[r'` recovery one-liner).

  ## Package boundary note (why this module hand-rolls its own bytes)

  `Raxol.UI.Rendering.PaintAuthority.Dialect.region_set/2` (main `raxol`,
  `lib/raxol/ui/rendering/paint_authority.ex`) is the shared DECSTBM byte
  builder the `PaintAuthority` implementations and the byte-capture oracle
  (`Raxol.Harness.Test.SealOracle`) are built against. This module lives in
  the `raxol_terminal` package, which -- per the repo's dependency graph
  (main `raxol` depends on `raxol_terminal`, never the reverse) -- cannot
  import anything under main `raxol`'s `lib/raxol/ui/`. So
  `region_set_bytes/2` below reproduces `Dialect.region_set/2`'s exact wire
  format (`CSI top;bottom r`) locally rather than aliasing it. The two are
  byte-identical by construction (and pinned by a test asserting exactly
  that), so the oracle (`SealOracle.scroll_region/1`,
  `SealOracle.region_sets/1`) parses this module's output the same way it
  parses a `PaintAuthority` implementation's -- the oracle works off raw
  bytes and vocabulary, not module identity.

  ## Reflow-aware resize: the seam this module exposes

  The default policy is seal-time-only: history bytes, once emitted, are the
  terminal's to reflow. Some terminals (e.g. iTerm2) genuinely reflow sealed
  history on resize, so a future, capability-gated upgrade may re-emit a
  bounded tail of recently-sealed blocks on a reflow-capable terminal. This
  module does not probe capabilities and does not re-emit any content -- that
  decision and its bytes belong to the append path, not here. What it DOES
  expose is the one fact that decision needs from the region-geometry side:
  `geometry_changed?/2`, a pure comparison of two states' `history_bottom`,
  so a future caller can tell "this resize actually moved the history/footer
  split" apart from a width-only resize that left `history_bottom` untouched
  (in which case there is nothing to reflow in the first place). This is the
  seam, not the upgrade.
  """

  @enforce_keys [:device, :rows, :footer_rows, :history_bottom, :degenerate?]
  defstruct [:device, :rows, :footer_rows, :history_bottom, :degenerate?]

  @type t :: %__MODULE__{
          device: IO.device(),
          rows: pos_integer(),
          footer_rows: non_neg_integer(),
          history_bottom: pos_integer(),
          degenerate?: boolean()
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
  @spec history_bottom(pos_integer(), non_neg_integer()) :: pos_integer()
  def history_bottom(rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    max(rows - footer_rows, 1)
  end

  @doc """
  True when `rows`/`footer_rows` cannot form a valid 2-row-minimum DECSTBM
  region (`history_bottom(rows, footer_rows) < 2`) -- see the moduledoc's
  "Degenerate terminals" section. In this case the footer cannot be
  pinned: `region_set_bytes/2` emits a full-screen release instead of a
  `top == bottom` request a real terminal would silently ignore.
  """
  @spec degenerate?(pos_integer(), non_neg_integer()) :: boolean()
  def degenerate?(rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    history_bottom(rows, footer_rows) < 2
  end

  @doc """
  The DECSTBM byte sequence for a given `rows`/`footer_rows` split.

  Ordinary case: `CSI 1;(H-N) r`, 1-based inclusive, byte-identical to
  `Raxol.UI.Rendering.PaintAuthority.Dialect.region_set(1, history_bottom(rows,
  footer_rows))` (see the package-boundary note in the moduledoc for why
  this is a local copy rather than an alias).

  Degenerate case (`degenerate?(rows, footer_rows)`, see the moduledoc):
  `CSI r`, the full-screen release -- NOT `CSI 1;1 r`. A real terminal
  ignores a `top == bottom` DECSTBM request outright, so emitting one here
  would silently leave whatever region was previously active untouched
  while claiming the pin succeeded. Emitting the release instead is
  honest: it un-pins (matches "no region set") rather than lying.
  """
  @spec region_set_bytes(pos_integer(), non_neg_integer()) :: binary()
  def region_set_bytes(rows, footer_rows) do
    if degenerate?(rows, footer_rows) do
      "\e[r"
    else
      "\e[1;#{history_bottom(rows, footer_rows)}r"
    end
  end

  @doc """
  History region row range, 1-based inclusive, TOP-anchored: `1..(H-N)`.
  `history_bottom/2`'s clamp guarantees `top >= 1`, so this is never empty.
  """
  @spec history_range(t()) :: Range.t()
  def history_range(%__MODULE__{history_bottom: top}), do: 1..top//1

  @doc """
  Footer row range, 1-based inclusive, OUTSIDE the scrolling region and
  below it: `(H-N+1)..H`. Explicit `//1` step (never the bare `first..last`
  form): on a degenerate terminal where `rows <= footer_rows`,
  `history_bottom/2`'s clamp gives history its minimum 1 row first, which can
  leave NO rows for the requested footer at all (`top >= rows`) -- without
  the explicit step, `first..last` silently REVERSES into a descending
  range when `last < first` (Elixir's legacy two-arg `Range` behavior),
  which would make this range compare as non-empty and, worse, overlap
  `history_range/1` at row 1. With the explicit step this is correctly
  empty instead.
  """
  @spec footer_range(t()) :: Range.t()
  def footer_range(%__MODULE__{rows: rows, history_bottom: top}),
    do: (top + 1)..rows//1

  @doc "Current history-region row count (`H - N`) -- the footer boundary."
  @spec history_bottom(t()) :: pos_integer()
  def history_bottom(%__MODULE__{history_bottom: top}), do: top

  @doc "The `footer_rows` (`N`) this manager was started/resized with. Constant across resize/2; changed only by set_footer_rows/2."
  @spec footer_rows(t()) :: non_neg_integer()
  def footer_rows(%__MODULE__{footer_rows: n}), do: n

  @doc "Current total row count (`H`)."
  @spec rows(t()) :: pos_integer()
  def rows(%__MODULE__{rows: rows}), do: rows

  @doc """
  True if this manager's current geometry cannot form a valid DECSTBM
  region (see the moduledoc's "Degenerate terminals" section) -- i.e. the
  footer is NOT actually pinned right now, regardless of what
  `history_bottom/1`/`footer_range/1` report for row-range math. Callers
  needing to know whether the pin is real (the footer-viewport callers)
  must check this rather than assuming `start/3`/`resize/2` always
  succeeded.
  """
  @spec degenerate?(t()) :: boolean()
  def degenerate?(%__MODULE__{degenerate?: d}), do: d

  @doc """
  True if the two states' history/footer split point differs -- i.e. the
  resize between them actually changed geometry, not just width. See the
  moduledoc's "Reflow-aware resize" section: this is the thin fact a future
  reflow-re-emit decision (owned elsewhere) would consult; `resize/2`
  itself also consults this comparison to skip a redundant DECSTBM
  re-emit on a width-only resize (see "Geometry-gated resize emission").

  Note: this compares `history_bottom` ONLY. It assumes both states share the
  same `footer_rows` (true for any pair of states produced by `start/3`
  followed by `resize/2` calls, since `footer_rows` is held constant across
  resize/2) -- it is not a general "these two states are otherwise identical"
  check, and is not meaningful across two managers started with different
  `footer_rows`. A second producer of a `footer_rows` difference now exists
  (`set_footer_rows/2` -- states across a `set_footer_rows/2` call
  intentionally differ in `footer_rows`, by design), but `geometry_changed?/2`
  itself is still only ever consulted by `resize/2`-path callers, so this
  assumption continues to hold for every call site.
  """
  @spec geometry_changed?(t(), t()) :: boolean()
  def geometry_changed?(%__MODULE__{history_bottom: a}, %__MODULE__{
        history_bottom: b
      }),
      do: a != b

  # ---------------------------------------------------------------------
  # The I/O seam -- device is a parameter. Passing a StringIO/collector
  # device makes emission byte-capturable in tests (no pty, no termbox).
  # ---------------------------------------------------------------------

  @doc """
  Sets the history/footer split for a freshly-started inline session:
  computes `history_bottom = rows - footer_rows` (clamped, see `history_bottom/2`)
  and writes the DECSTBM region-set bytes to `device` exactly once. Returns
  the new manager state.

  If `rows`/`footer_rows` are degenerate (see the moduledoc's "Degenerate
  terminals" section), the bytes written are the full-screen release
  (`CSI r`), not a `top == bottom` DECSTBM the terminal would ignore, and
  the returned state has `degenerate?: true` -- the footer is NOT pinned
  in this case; callers must check `degenerate?/1`.

  Composes with the inline driver (see moduledoc): no teardown call is needed
  from this module. `InlineDriver`'s existing, unmodified `emit_teardown/2` releases
  whatever region this call set (a no-op re-release in the degenerate
  case, since this call already released).
  """
  @spec start(IO.device(), pos_integer(), non_neg_integer()) :: t()
  def start(device, rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    IO.write(device, region_set_bytes(rows, footer_rows))
    plan(device, rows, footer_rows)
  end

  @doc """
  The PURE constructor: the same state `start/3` builds, with ZERO bytes
  written -- no DECSTBM is claimed. This is the geometry record for a
  caller that tracks the history/footer split WITHOUT pinning it yet
  (`Raxol.UI.Rendering.PaintAuthority.InlineAuthority`'s FLOATING state,
  the adaptive-pin model: the footer follows content until it reaches
  the pinned position). All the pure row-range math (`history_bottom/1`,
  `footer_range/1`, `degenerate?/1`, ...) works identically on a planned
  state; the one thing a planned state does NOT mean is "the terminal is
  enforcing this split." The caller pins later with `reassert/1` (the
  unconditional single-write emitter), which is exactly the float->pin
  transition's region byte.
  """
  @spec plan(IO.device(), pos_integer(), non_neg_integer()) :: t()
  def plan(device, rows, footer_rows)
      when is_integer(rows) and rows > 0 and is_integer(footer_rows) and
             footer_rows >= 0 do
    %__MODULE__{
      device: device,
      rows: rows,
      footer_rows: footer_rows,
      history_bottom: history_bottom(rows, footer_rows),
      degenerate?: degenerate?(rows, footer_rows)
    }
  end

  @doc """
  Recomputes the region for a new row count, holding `footer_rows`
  constant, and re-emits the DECSTBM region-set bytes to the state's
  device -- but ONLY when the new `history_bottom` differs from the current
  one (see the moduledoc's "Geometry-gated resize emission" section). A
  width-only resize (rows unchanged, so `history_bottom` unchanged) writes
  ZERO bytes: there is nothing to re-pin, and DECSTBM's cursor-homing side
  effect would otherwise fire for no geometric reason. When the split
  point does move, exactly one DECSTBM (or, in the degenerate case, one
  full-screen release -- see `region_set_bytes/2`) is written. Never emits
  `\\e[2J`/`\\e[3J` or any other byte (a full-screen clear on resize would
  wipe already-sealed native scrollback on wezterm/kitty).
  The footer's CONTENT is not this module's concern (the footer viewport
  owns repainting it); only the row-range split is recomputed here.

  `footer_rows` (`N`) is held constant across resize/2; changed only by
  `set_footer_rows/2`.
  """
  @spec resize(t(), pos_integer()) :: t()
  def resize(
        %__MODULE__{
          device: device,
          footer_rows: footer_rows,
          history_bottom: current_top
        } =
          state,
        new_rows
      )
      when is_integer(new_rows) and new_rows > 0 do
    new_top = history_bottom(new_rows, footer_rows)

    if new_top != current_top do
      IO.write(device, region_set_bytes(new_rows, footer_rows))
    end

    %{
      state
      | rows: new_rows,
        history_bottom: new_top,
        degenerate?: degenerate?(new_rows, footer_rows)
    }
  end

  @doc """
  Recomputes the region for a new `footer_rows`, holding `rows` (`H`)
  constant -- the counterpart to `resize/2`, which holds `footer_rows`
  constant and varies `rows`. This is the seam a footer-hosted overlay
  (`Raxol.UI.Harness.OverlayPicker`, via
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority.set_footer_rows/2`)
  uses to grow or shrink the pinned footer viewport without a real
  terminal resize.

  Re-emits the DECSTBM region-set bytes ONLY when the resulting
  `history_bottom` differs from the current one -- the same
  geometry-gated-emission discipline `resize/2` uses (see that function's
  doc and the moduledoc's "Geometry-gated resize emission" section):
  DECSTBM homes the cursor as a documented side effect, so a call whose
  `footer_rows` change happens not to move the split (e.g. `rows` is
  already degenerate on both sides) writes zero bytes rather than paying
  that side effect for no geometric benefit.

  `footer_rows`, `history_bottom`, and `degenerate?` are updated to match
  the new split; `rows` (`H`) is untouched.
  """
  @spec set_footer_rows(t(), non_neg_integer()) :: t()
  def set_footer_rows(
        %__MODULE__{
          device: device,
          rows: rows,
          history_bottom: current_top
        } = state,
        new_footer_rows
      )
      when is_integer(new_footer_rows) and new_footer_rows >= 0 do
    new_top = history_bottom(rows, new_footer_rows)

    if new_top != current_top do
      IO.write(device, region_set_bytes(rows, new_footer_rows))
    end

    %{
      state
      | footer_rows: new_footer_rows,
        history_bottom: new_top,
        degenerate?: degenerate?(rows, new_footer_rows)
    }
  end

  @doc """
  Re-emits `region_set_bytes(rows, footer_rows)` to `state`'s device
  UNCONDITIONALLY and returns `state` unchanged (same geometry, same
  device, same everything) -- the resume-after-suspend counterpart to
  `resize/2`'s geometry-gated emission.

  ## Why unconditional (contrast `resize/2`)

  `resize/2` skips the write when the new `history_bottom` matches the
  current one -- correct for an ordinary resize, where the region is
  never in question (this module keeps it pinned continuously from
  `start/3` onward, so "geometry unchanged" really does mean "nothing to
  re-pin"). But a resume after an EXTERNAL process owned the terminal
  (an `$EDITOR` session that released the region via
  `Raxol.Terminal.InlineDriver.Sequences.suspend_bytes/1`, the canonical
  suspend bytes) genuinely un-pins the region without changing geometry
  at all -- `resize/2`'s gate would (correctly, for ITS purpose) see
  identical `history_bottom` and skip the write, silently leaving the
  terminal un-pinned even though this process still believes the footer
  is pinned. `reassert/1` is the different call site that needs the
  unconditional form: always re-emit, regardless of whether geometry
  moved.

  Degenerate geometry (`degenerate?(state)`) re-emits the same
  full-screen release `region_set_bytes/2` already emits for that case --
  an honest un-pin, consistent with what `start/3`/`resize/2` would write
  at that same geometry (see the moduledoc's "Degenerate terminals"
  section).

  DECSTBM's cursor-homing side effect is acceptable here: every
  subsequent paint (`InlineAuthority.repaint/2`/`keyframe/2`) CUPs to an
  absolute row before writing anything, so a homed cursor never becomes
  visible.
  """
  @spec reassert(t()) :: t()
  def reassert(
        %__MODULE__{device: device, rows: rows, footer_rows: footer_rows} =
          state
      ) do
    IO.write(device, region_set_bytes(rows, footer_rows))
    state
  end
end
