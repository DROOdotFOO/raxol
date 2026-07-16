defmodule Raxol.UI.Rendering.PaintAuthority.InlineAuthority do
  @moduledoc """
  The real (production) `PaintAuthority` implementation: the printed-
  history append path.

  This is the module that fills in what `IOAuthority` deliberately leaves
  as a stub — it composes:

    * **`Raxol.Terminal.ScrollRegionManager`** for the DECSTBM
      region/footer split (`history_bottom/1`, `resize/2` re-set the region
      exactly once, never a full clear).
    * **The inline driver's device seam** — the output sink is a parameter
      (`IO.device()`), the same `:device` the scroll-region manager and
      `InlineDriver` already thread through, so a `StringIO` pid (or
      `ExUnit.CaptureIO`) captures bytes with no pty in tests and
      `:stdio` writes for real in production.
    * **The shared `Dialect` wire vocabulary** (`cursor_save/0`,
      `cursor_restore/0`) the byte-capture oracle
      (`Raxol.Harness.Test.SealOracle`) already parses.

  ## Seal-once, by construction: fill down, then scroll

  A fresh history region is empty capacity, not yet "full" — real
  terminal output naturally advances line by line from wherever the
  cursor last was, only falling back to scroll-at-the-boundary once the
  bottom row is reached. This module models that explicitly with a
  `next_row` cursor tracked in its own state: `append_sealed/2` positions
  at `min(next_row, history_bottom)` (the next unfilled history row, clamped
  to the region's bottom once full), writes, and advances `next_row` by
  the number of lines written (also clamped). Once `next_row` reaches
  `history_bottom`, every subsequent append targets that same bottom row and
  relies on the terminal's own index-at-region-boundary semantics to
  scroll — the row is never re-addressed with different content, only
  ever pushed one row closer to eviction into scrollback.

  This isn't a style choice: it is what makes the seal-once invariant
  (`Raxol.Harness.Test.SealOracle.immutable_prefix?/2`, `history/3`'s
  emit-derived high-water accounting) actually hold. An implementation
  that always targets the bottom row from the first append onward front-
  loads the combined `scrollback ++ on-screen` history with content-free
  filler rows ahead of any real content, which defeats the high-water
  prefix check silently; fill-down-then-scroll avoids this, and it is
  load-bearing, not a style preference.

  The test in `test/property/renderer_adversarial_property_test.exs`
  ("repainting an already-sealed row...") is a separate thing: an ORACLE-
  VALIDITY guard that hand-injects a known-bad stream (a row-1 repaint —
  a different, also-invalid violation class) to prove `SealOracle`
  catches a real immutable-prefix violation instead of rubber-stamping
  every input. It does not reproduce, and was never meant to reproduce,
  the filler bug described above. There is no code path in this module
  that CUPs to any row other than `min(next_row, history_bottom)`.

  ## The cursor-ownership protocol

  One owner module, both paths go through it. This module's
  `with_cursor/3` is that owner — the SOLE place a save/restore
  bracket is opened. `append_sealed/2` itself never saves or restores; it
  only positions+writes. The full protocol (save -> position -> emit ->
  restore) is `seal/2`, the composition of the two:

      seal(t, iodata) == with_cursor(t, :history, fn s -> append_sealed(s, iodata) end)

  Callers (the append path's own driver, and the footer viewport's own
  positioning) should go through `with_cursor/3` for anything that moves
  the cursor, so saves and restores from the two emit vocabularies never
  interleave (a save inside another save's bracket silently clobbers the
  single hardware DECSC register — see `SealOracle.save_restore_balance/1`
  and its `_max_depth` field).

  ## `\\e[2J` is never emitted

  Neither this module nor `Raxol.Terminal.ScrollRegionManager` (which owns
  the DECSTBM re-set on `resize/3`) ever writes `\\e[2J`/`\\e[3J`:
  real-hardware measurement showed a full-screen clear wipes native
  scrollback on wezterm/kitty, which would destroy history that, once
  sealed, exists only as terminal-owned pixels this process can no
  longer reconstruct.

  ## Resize scope: ships seal-time-only, wires the reflow-aware detection seam

  This module ships **seal-time-only**: `resize/3` NEVER re-emits
  previously-sealed content — the only byte it writes on resize is
  `ScrollRegionManager`'s single DECSTBM re-set (content already on-screen
  is left exactly as it is; a shrinking region merely clamps where
  FUTURE appends resume, per `next_row`'s resize clamp below).
  `reflow_capable?/1` is the **reflow-aware detection SEAM**: a pure
  predicate over a terminal identity, reporting whether the
  terminal-matrix probe measured THIS terminal to reflow sealed
  scrollback cleanly on resize (today: iTerm2 only — wezterm/kitty were
  measured NOT to; ghostty is unmeasurable and conservatively `false`).
  `resize/3` consults it (alongside `ScrollRegionManager.geometry_changed?/2`'s
  thin "did the split point actually move" fact) purely to emit a
  `:telemetry` event when both hold — **no bytes are re-emitted**. A
  FUTURE unit reads that telemetry (or calls `reflow_capable?/1` directly)
  to gate bounded soft-owned-history re-emission. Wiring the hook here,
  without acting on it, is the whole point: reflow-aware re-emission is a
  runtime-detected additive upgrade, deferred for a future unit to
  implement. Contract-only-grows: this module never has to be rewritten
  to add reflow-aware re-emission later, only extended.

  ## The pinned footer viewport (buffer-diff, footer-scoped)

  The `repaint_footer/2`/`keyframe_footer/2` `@impl` callbacks were
  deliberate placeholders: minimal pass-through stubs that satisfy the
  behaviour without any real positioning/diff logic. This module fills
  that in with a buffer-diff pipeline scoped to the footer rows only —
  every emitted CUP stays inside footer rows:

    * `footer_diff/2` — pure function, no I/O: given the last-painted
      footer content and the next footer content (both one binary per
      footer row, top-to-bottom, already padded/truncated to the same
      row count), returns only the `{row_index, line}` pairs that
      actually changed. This is the "minimal repaint bytes" half of the
      pipeline, kept separate from the emit half so it is unit-testable
      with zero device/cursor setup.
    * `repaint/2` — the diff-driven entry point for normal per-frame
      footer updates: pads/truncates the caller's next footer lines to
      the CURRENT footer row count (`ScrollRegionManager.footer_range/1`
      via `footer_row_count/1`), diffs against `footer_lines` (the
      struct field this module now tracks), and emits ONLY the changed
      rows — each one `CUP` (to `region_top(t) + 1 + row_index`, always
      inside the footer range) then `\\e[K` (clear that row, never
      `\\e[2J`/`\\e[3J`) then the new content — inside a single
      `with_cursor/3` bracket (`:footer` region) so a footer repaint
      never corrupts the history path's saved cursor. A no-op diff
      (nothing changed) emits zero bytes.
    * `keyframe/2` — the FULL footer repaint: every footer row cleared
      and rewritten regardless of what changed, still per-row `\\e[K`
      (never a full-screen clear). This is the Ctrl-L recovery entry
      point. Composition note: `resize/3` (below) re-derives the
      DECSTBM split but deliberately does NOT call this automatically —
      see `resize/3`'s doc for why (an existing regression test on the
      append path pins resize to emit only the DECSTBM re-set). Callers
      that also need the footer re-rendered at the new geometry compose
      explicitly:
      `authority |> InlineAuthority.resize(w, h) |> InlineAuthority.keyframe(current_lines)`.
      Both calls already guarantee no `\\e[2J`/`\\e[3J` and no history
      addressing, so the composition inherits both properties for free.

  Every row either function addresses is computed from
  `region_top(t) + 1 .. rows(region)` (the scroll-region manager's
  `footer_range/1`) — never a hand-maintained constant — so a footer
  paint can never drift into the scrolling history region even under
  resize.

  ## Caller contract: footer line width (NOT enforced here)

  `repaint/2` and `keyframe/2` pad/truncate the LIST of footer lines to the
  current footer row COUNT (`footer_row_count/1`) — but neither function
  measures or truncates an individual LINE's display width. A line wider
  than the terminal's column count wraps onto the following row (a real
  terminal's own line-wrap behavior), which breaks footer confinement: the
  wrapped tail lands on whatever row follows, which may be the next footer
  row (silently overwriting content that only `repaint/2` is assumed to
  address) or, on the LAST footer row, past the bottom of the screen
  entirely. This module does not defend against that — it is the caller's
  responsibility to display-width-truncate every line to the authority's
  `width` (the same value passed to `new/5`) BEFORE calling
  `repaint/2`/`keyframe/2`. Use `Raxol.UI.TextMeasure` for that
  measurement — never `String.length/1`, which undercounts double-width
  (CJK) characters and would let a line that measures "short" by codepoint
  count still overflow the column budget.

  ## Degenerate geometry: `degenerate?/1`

  A terminal too short for its requested footer (`rows - footer_rows < 2`,
  the scroll-region manager's `ScrollRegionManager.degenerate?/1`) cannot
  have its footer actually pinned via DECSTBM — see that module's
  moduledoc for why. This module surfaces that fact via `degenerate?/1`
  (a thin delegation, no behavior change) so callers can detect the
  condition and adapt — e.g. falling back to redrawing the footer every
  frame — instead of silently trusting a pin that a real terminal
  ignored. `repaint/2` and `keyframe/2` still function on a degenerate
  geometry (never crash): they simply operate over whatever footer
  capacity `footer_range/1` actually reports for that geometry, which may
  be smaller than `footer_rows` requested, or empty.

  ## Footer `ContentGuard`, and the `needs_keyframe` latch

  Two properties enforced here:

    * **Footer content is not trusted either.** The history append path
      does not write agent/LLM-originated iodata verbatim
      (`ContentGuard.sanitize_line/1`); the footer path carries the SAME
      kind of content (live-tail/agent text) through the SAME risk (a
      footer line smuggling `\\e[3;1H`/`\\e[2J`/etc. would execute
      against the footer confinement invariant exactly like an
      unguarded history append would against the seal-once invariant).
      `repaint/2` and `keyframe/2` both run every caller-supplied line
      through `ContentGuard.sanitize_line/1` at entry — BEFORE padding or
      diffing — so `footer_diff/2` and `footer_lines` only ever see
      already-neutralized content. `footer_lines` itself is therefore an
      invariant: once sanitized in, never re-sanitized out, so `footer_diff/2`
      comparing old (already-sanitized) against new (freshly-sanitized) is
      always an apples-to-apples comparison.
    * **A stale post-resize repaint could leave ghost content.**
      `resize/3` clamps `next_row` but, by design (see above), never
      repaints the footer — a geometry-changing resize can relocate the
      footer's on-screen rows to different absolute row numbers while their
      CONTENT (and thus `footer_diff/2`'s logical, index-based comparison)
      is unchanged. A subsequent `repaint/2` call with unchanged lines then
      computes a no-op diff and writes NOTHING, leaving those rows showing
      whatever was on screen at that position before the resize (leftover
      history text, or a stale row `repaint/2` previously left blank via
      `\\e[K` at the OLD position). The `needs_keyframe` flag closes this:
      a resize that changes EITHER axis — vertical geometry (`history_bottom`)
      OR width — sets it (a pure state change — the pinned regression test
      asserting resize's ONLY new bytes are `ScrollRegionManager`'s single
      DECSTBM re-set is untouched, since setting a struct field emits no bytes,
      and a width-only resize re-emits no region bytes at all). Width matters
      here even though the region doesn't move: a reflow-capable terminal
      rewraps sealed history on a width change, and a width-shrink can wrap an
      untruncated footer line past the pin, so the footer needs a clean
      re-render at the new width. The NEXT `repaint/2` call checks the flag
      FIRST and, if set, self-promotes to a full `keyframe/2` (which clears the
      flag) instead of running its normal diff — so the first repaint after any
      geometry OR width change always fully re-renders the footer at its current
      position and width, regardless of whether the logical content changed.

  ## Growing/shrinking the footer (overlay hosting)

  `set_footer_rows/2` is the seam a footer-hosted overlay
  (`Raxol.UI.Harness.OverlayPicker`, assembled via
  `Raxol.Harness.Surface.open_overlay/3`) uses to claim (or give back)
  rows from the footer viewport WITHOUT a real terminal resize --
  `rows`/`width` are unchanged, only the DECSTBM split point moves, via
  `ScrollRegionManager.set_footer_rows/2` (the `resize/2` counterpart
  that holds `rows` constant and varies `footer_rows` instead).

  A temporary overlay must never unpin the live footer: a target that
  would make `ScrollRegionManager.degenerate?/2` true (history could not
  keep its 2-row minimum) is refused outright, `{:error, :degenerate}`,
  zero bytes -- the caller keeps whatever footer it already had.

  **Growing** the footer (claiming rows FROM history) must not silently
  paint over content that already occupies those rows. Whatever currently
  fills the reclaimed range is scrolled up first, via plain `"\n"` bytes
  written at the OLD bottom row while the OLD (still wider) DECSTBM region
  is still active: each `\n` landing on that row is the same
  index-at-region-boundary behavior `append_sealed/2` already relies on --
  the region scrolls, the row evicted off the top lands in the terminal's
  own native scrollback, and nothing is ever re-painted. Only after that
  scroll does the DECSTBM split actually move
  (`ScrollRegionManager.set_footer_rows/2`) and `needs_keyframe: true` gets
  set -- the SAME latch `resize/3` uses, so the next `repaint/2` call
  self-promotes to a full `keyframe/2` and redraws the (now smaller)
  footer cleanly at its new position.

  **Shrinking** the footer (giving rows BACK to history) is the reverse
  concern: the rows being vacated are still footer-owned (about to become
  history) and may hold stale overlay pixels from the frame before
  dismissal -- history appends resume ABOVE them, so nothing else will
  ever clear them on its own. Each vacated row is explicitly cleared
  (`CUP` + `\e[K`, never `\e[2J`) BEFORE the DECSTBM split moves back,
  then the same `needs_keyframe` latch is set so the footer's remaining
  content is fully re-rendered at its new (smaller) position.

  Neither direction ever emits `\e[2J`/`\e[3J`.

  ## Synchronized output (DEC private mode 2026)

  `with_sync/3` is the DEC 2026 synchronized-update bracket
  (`CSI ? 2026 h` ... `CSI ? 2026 l`): a Surface frame that seals one or
  more blocks wraps the seal writes and the trailing footer repaint in
  this bracket so a multi-block seal presents to the terminal atomically
  (no partial-frame flicker between the sealed history and the repainted
  footer). It is gated on this authority's `sync_output?` field (measured
  once, at `new/5`, from the capability record) -- capability-unknown
  means don't emit, never a guess. See `with_sync/3`'s own doc for the
  balanced-bracket and failed-open-degrades guarantees.
  """

  @behaviour Raxol.UI.Rendering.PaintAuthority

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.ScrollRegionManager
  alias Raxol.UI.Rendering.PaintAuthority.ContentGuard
  alias Raxol.UI.Rendering.PaintAuthority.Dialect

  @enforce_keys [:region, :width, :reflow_capable?, :next_row]
  defstruct [
    :region,
    :width,
    :reflow_capable?,
    :next_row,
    in_cursor_bracket: false,
    footer_lines: [],
    needs_keyframe: false,
    sync_output?: false
  ]

  @type t :: %__MODULE__{
          region: ScrollRegionManager.t(),
          width: pos_integer(),
          reflow_capable?: boolean(),
          next_row: pos_integer(),
          in_cursor_bracket: boolean(),
          footer_lines: [binary()],
          needs_keyframe: boolean(),
          sync_output?: boolean()
        }

  @doc """
  Builds a new authority: sets the DECSTBM region via
  `ScrollRegionManager.start/3` (one write, `CSI 1;(H-N) r`), records
  whether this session's terminal is on the reflow-aware detection
  allowlist, and starts the fill-down cursor (`next_row`) at the
  region's first row.

  ## Options

    * `:capabilities` — a `%Raxol.Terminal.Capabilities{}` (or `nil`) used
      by `reflow_capable?/1`. Defaults to the cached session record
      (`Raxol.Terminal.Capabilities.cached/0`) if present, else `nil`.
      Tests should pass this explicitly rather than relying on the
      process-global `:persistent_term` cache.
  """
  @spec new(
          IO.device(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          t()
  def new(device, width, rows, footer_rows, opts \\ [])
      when is_integer(width) and width > 0 do
    caps =
      case Keyword.fetch(opts, :capabilities) do
        {:ok, caps} -> caps
        :error -> cached_caps()
      end

    %__MODULE__{
      region: ScrollRegionManager.start(device, rows, footer_rows),
      width: width,
      reflow_capable?: reflow_capable?(caps),
      next_row: 1,
      sync_output?: match?(%{sync_output: true}, caps)
    }
  end

  defp cached_caps do
    case Capabilities.cached() do
      {:ok, caps} -> caps
      :error -> nil
    end
  end

  @doc """
  The reflow-aware detection SEAM (thin — does not implement
  reflow-aware re-emission itself, see moduledoc). `true` only for
  terminal identities the terminal-matrix probe confirmed reflow sealed
  history cleanly on resize (iTerm2 reflows sealed history cleanly on
  resize; it was the only terminal resize-testable on real hardware).
  Every other identity — including `nil`/unmeasured (ghostty), and the
  two terminals measured NOT to reflow (wezterm, kitty) — is
  conservatively `false`. Support defaults to seal-time-only and only
  turns on where reflow-aware behavior is earned: "earned" means
  measured on real hardware, never assumed from a `$TERM_PROGRAM` guess.
  """
  @spec reflow_capable?(Capabilities.t() | nil) :: boolean()
  def reflow_capable?(%Capabilities{identity: {"iTerm2", _version}}), do: true
  def reflow_capable?(_caps), do: false

  @doc """
  The full cursor-ownership protocol for one sealed append: save the
  cursor, position into the history region (via `append_sealed/2`), emit
  `iodata`, restore. This is the entry point the append path's caller
  (and later units building on this substrate) should use —
  `append_sealed/2` alone
  only positions+emits; `seal/2` is what makes that a single, save/
  restore-bracketed operation.

  `iodata` MUST be a whole number of `\\r\\n`-terminated lines (mirrors
  `Raxol.Harness.Test.SealOracle.assert_seal_newline_terminated/1`'s
  discipline) — a dangling partial line would leave the emulator's
  reported column mid-row, and would under-count `next_row`'s advance
  against what the terminal actually did. This is now an ENFORCED
  precondition, not just prose: `seal/2` raises `ArgumentError` when
  `iodata` does not end in `\\r\\n`.

  ## Content is not trusted (`ContentGuard`)

  `iodata` is agent/LLM-originated content, not renderer-generated
  bytes — it can carry ANYTHING a language model chooses to emit,
  including control sequences that would otherwise defeat every
  invariant this module exists to hold from the INSIDE (a `\\e[2J`
  wipes native scrollback same as if this module had written it
  itself; a `\\e[1;1H` repaints an already-sealed row same as any other
  bug class this module's fill-down design defends against). Before
  the newline check and before `append_sealed/2` ever sees the bytes,
  `seal/2` runs `iodata` through
  `Raxol.UI.Rendering.PaintAuthority.ContentGuard.sanitize_line/1`,
  which allowlists printable text, the shared SGR vocabulary, and
  `\\t`/`\\r`/`\\n`, neutralizing everything else. See that module's
  moduledoc for the exact grammar and the "visible-honest" neutralization
  rationale.
  """
  @spec seal(t(), iodata()) :: t()
  def seal(%__MODULE__{} = t, iodata) do
    sanitized = validate_seal_iodata!(iodata)
    with_cursor(t, :history, fn inner -> append_sealed(inner, sanitized) end)
  end

  # Shared by `seal/2` and `try_seal/2`: enforce the `\r\n`-terminated
  # caller contract (raises `ArgumentError` -- a caller-contract bug, never
  # masked as a device failure) and run the content through
  # `ContentGuard.sanitize_line/1` (see the moduledoc's `ContentGuard`
  # section). This runs OUTSIDE `try_seal/2`'s rescued scope -- see that
  # function's doc for why the two error classes must stay distinct.
  defp validate_seal_iodata!(iodata) do
    binary = IO.iodata_to_binary(iodata)

    unless String.ends_with?(binary, "\r\n") do
      raise ArgumentError,
            "PaintAuthority.InlineAuthority.seal/2 requires \\r\\n-terminated " <>
              "iodata (a sealed block must be a whole number of lines); got " <>
              inspect(binary)
    end

    ContentGuard.sanitize_line(binary)
  end

  @doc """
  The write-confirming seal: validates and sanitizes `iodata` (via
  `validate_seal_iodata!/1`, the same discipline `seal/2` uses -- a
  missing `\\r\\n` terminator is a CALLER-CONTRACT bug and still raises
  `ArgumentError`, unmasked), then attempts the write and reports whether
  the device actually confirmed it.

  ## Write -> confirm -> mark

  This is the substrate half of the print-once safety property
  documented in `Raxol.Harness.SealFrontier.commit_walk/5`: a caller
  (`Raxol.Harness.Surface.seal_block/2`) marks a block committed only
  AFTER `try_seal/2` returns `{:ok, _}` -- never before. On `{:error,
  :write_failed, t}`, the ORIGINAL `t` (the one passed in, `next_row` not
  advanced) is returned, so a retry re-positions and re-writes from
  scratch rather than resuming from a cursor that may have been left
  mid-write.

  ## The two rescued error classes

  Only DEVICE failures are converted to `{:error, :write_failed, t}`:

    * `ArgumentError` -- the io server replied `{:error, reason}` to the
      underlying `:io.put_chars` request (e.g. `{:error, :enospc}`);
      `IO.write/2` surfaces this as a raised `ArgumentError`.
    * `ErlangError` -- the device process is dead (e.g. `%ErlangError{
      original: :terminated}` from a closed `StringIO`/port).

  The validation raise above happens BEFORE the rescued block even starts
  -- a missing `\\r\\n` is a bug in the calling code, not a device
  failure, and must never be silently downgraded to a retryable
  `:write_failed` (a caller retrying a permanently-malformed call would
  loop forever). Likewise, `with_cursor/3`'s own nested-bracket
  `RuntimeError` is deliberately NOT rescued here -- that too is a caller
  bug (two overlapping brackets), not something a device retry can fix.

  ## Partial-write honesty

  A retry may overwrite a partially-flushed row in place (the device may
  have accepted some bytes before failing mid-write, on some transports).
  This is safe: an unconfirmed row was never counted in `seal`'s high-
  water accounting (`next_row` is only advanced on `{:ok, _}`) nor marked
  committed by `commit_walk/5`, so a retry writing over it again produces
  the same rows the confirmed write would have -- no seal-once violation.
  """
  @spec try_seal(t(), iodata()) :: {:ok, t()} | {:error, :write_failed, t()}
  def try_seal(%__MODULE__{} = t, iodata) do
    sanitized = validate_seal_iodata!(iodata)
    confirmed_seal(t, sanitized)
  end

  defp confirmed_seal(t, sanitized) do
    {:ok,
     with_cursor(t, :history, fn inner -> append_sealed(inner, sanitized) end)}
  rescue
    _e in [ArgumentError, ErlangError] -> {:error, :write_failed, t}
  end

  @doc """
  The DEC 2026 synchronized-update bracket (see the moduledoc's
  "Synchronized output" section): wraps `fun.(acc)` in `CSI ? 2026 h`
  ... `CSI ? 2026 l` when this authority measured the capability true at
  construction (`sync_output?`), otherwise runs `fun.(acc)` unbracketed.

  ## Capability-gated, capability-unknown-means-don't-emit

  `sync_output?` is measured once, at `new/5`, from the capability
  record passed in (`nil`/unknown -> `false`). This function does not
  re-check the capability itself -- it trusts the field. A `nil`/unknown
  capability is the documented policy: never emit a presentation-only
  control sequence on a guess.

  ## Balanced by construction

  The close (`CSI ? 2026 l`) is emitted if AND ONLY IF the open
  succeeded, via the `after` block below -- even when `fun` raises or
  returns while a nested seal failed. A caller that sees the open fail
  degrades to running `fun` completely unbracketed (see below); there is
  never a dangling open with no matching close, and never a close with no
  matching open.

  ## A failed open degrades gracefully

  If the opening write itself fails (device error), `fun.(acc)` still
  runs, just without the bracket -- this is a PRESENTATION-only feature
  (it only affects how atomically the terminal shows already-correct
  bytes); it must never be allowed to take down the frame it wraps.

  ## Best-effort byte writes

  `sync_write/2` rescues the same two device-error classes as
  `try_seal/2` (`ArgumentError` from an `{:error, reason}` io-server
  reply, `ErlangError` from a dead device) and reports `:error` rather
  than raising, so a lost sync byte never crashes the frame it was only
  decorating.
  """
  @spec with_sync(t(), acc, (acc -> acc)) :: acc when acc: term()
  def with_sync(%__MODULE__{sync_output?: false}, acc, fun)
      when is_function(fun, 1),
      do: fun.(acc)

  def with_sync(%__MODULE__{region: region}, acc, fun)
      when is_function(fun, 1) do
    case sync_write(region.device, "\e[?2026h") do
      :ok ->
        try do
          fun.(acc)
        after
          sync_write(region.device, "\e[?2026l")
        end

      :error ->
        fun.(acc)
    end
  end

  defp sync_write(device, bytes) do
    IO.write(device, bytes)
    :ok
  rescue
    _e in [ArgumentError, ErlangError] -> :error
  end

  @impl true
  def append_sealed(%__MODULE__{region: region, next_row: next_row} = t, iodata) do
    bottom = ScrollRegionManager.history_bottom(region)
    device = region.device
    target_row = min(next_row, bottom)

    # One CUP to the next unfilled history row (or the bottom row, once
    # full) then the content. Every `\r\n` inside `iodata` that lands ON
    # the bottom row is an index-at-region-boundary: the DECSTBM region
    # scrolls up (oldest history row evicted toward scrollback), the
    # cursor stays on that same bottom row. No other code path in this
    # module ever addresses any other row.
    IO.write(device, Dialect.cursor_position(target_row))
    IO.write(device, iodata)

    lines_written = count_lines(iodata)
    %{t | next_row: min(target_row + lines_written, bottom)}
  end

  @impl true
  def repaint_footer(%__MODULE__{region: region} = t, iodata) do
    # Low-level @impl callback: write already-scoped footer bytes. The
    # diff logic (deciding WHICH rows and building those bytes) lives in
    # `repaint/2`, above the behaviour seam, mirroring how `seal/2` sits
    # above `append_sealed/2` on the history side.
    IO.write(region.device, iodata)
    t
  end

  @impl true
  def keyframe_footer(%__MODULE__{region: region} = t, iodata) do
    IO.write(region.device, iodata)
    t
  end

  @doc """
  Pure diff: only the `{row_index, line}` pairs that differ between
  `old_lines` and `new_lines` (both already the SAME length — pad/
  truncate before calling, see `repaint/2`). No I/O, no cursor movement.
  `row_index` is 0-based, relative to the top of the footer.

  Raises `ArgumentError` (rather than falling through to a bare
  `FunctionClauseError`) when the two lists' lengths differ, naming the fix:
  callers must pad/truncate both to the same row count first (`pad_rows/2`,
  which `repaint/2`/`keyframe/2` already do before calling this).
  """
  @spec footer_diff([binary()], [binary()]) :: [{non_neg_integer(), binary()}]
  def footer_diff(old_lines, new_lines)
      when is_list(old_lines) and is_list(new_lines) and
             length(old_lines) == length(new_lines) do
    old_lines
    |> Enum.zip(new_lines)
    |> Enum.with_index()
    |> Enum.reject(fn {{old_line, new_line}, _idx} -> old_line == new_line end)
    |> Enum.map(fn {{_old_line, new_line}, idx} -> {idx, new_line} end)
  end

  def footer_diff(old_lines, new_lines)
      when is_list(old_lines) and is_list(new_lines) do
    raise ArgumentError,
          "InlineAuthority.footer_diff/2 requires old_lines and new_lines to " <>
            "be the same length (got #{length(old_lines)} and " <>
            "#{length(new_lines)}) -- pad/truncate both to the same row " <>
            "count first (see pad_rows/2, or call repaint/2 / keyframe/2 " <>
            "directly, which already do this)"
  end

  @doc """
  The diff-driven footer repaint: sanitizes every line of `new_lines`
  through `ContentGuard.sanitize_line/1` (footer content is agent/LLM-
  originated, same as the history append path -- see the moduledoc's
  `ContentGuard` section), pads/truncates the sanitized result to the
  CURRENT footer row count, diffs against the last-painted footer
  (`footer_diff/2`), and emits only the changed rows -- each `CUP`
  (inside the footer range, never history) + `\\e[K` (per-row clear,
  never `\\e[2J`) + the new line content -- inside one `with_cursor/3`
  bracket. Zero changed rows emits zero bytes (but `footer_lines` is still
  updated to the padded/sanitized content, so a later resize that changes
  footer row count doesn't diff against a stale-length list). Updates
  `footer_lines` so the next call diffs against what was actually painted.

  Self-promotes to a full `keyframe/2` -- clearing `needs_keyframe` in the
  process -- when that flag is set (a prior geometry-changing `resize/3`):
  see the moduledoc's "`needs_keyframe` latch" section for why a diff-only
  repaint is not safe to trust immediately after a resize.
  """
  @spec repaint(t(), [binary()]) :: t()
  def repaint(%__MODULE__{needs_keyframe: true} = t, new_lines)
      when is_list(new_lines) do
    keyframe(t, new_lines)
  end

  def repaint(%__MODULE__{footer_lines: old_lines} = t, new_lines)
      when is_list(new_lines) do
    count = footer_row_count(t)
    padded_new = sanitize_and_pad(new_lines, count)
    padded_old = pad_rows(old_lines, count)

    case footer_diff(padded_old, padded_new) do
      [] -> %{t | footer_lines: padded_new}
      changes -> emit_footer_diff(t, changes, padded_new)
    end
  end

  defp emit_footer_diff(t, changes, padded_new) do
    footer_top = region_top(t) + 1

    iodata =
      Enum.map(changes, fn {idx, line} ->
        footer_row_bytes(footer_top + idx, line)
      end)

    t
    |> with_cursor(:footer, fn inner -> repaint_footer(inner, iodata) end)
    |> Map.put(:footer_lines, padded_new)
  end

  @doc """
  Footer keyframe: every footer row cleared (`\\e[K`, never a
  full-screen clear) and rewritten, regardless of what changed. The
  Ctrl-L recovery entry point, and what a caller composes after
  `resize/3` to re-derive the footer's on-screen content at the new
  geometry (see the moduledoc's "pinned footer viewport" section for why
  `resize/3` itself does not call this) -- and what `repaint/2` self-promotes to when
  `needs_keyframe` is set. Sanitizes every line of `new_lines` through
  `ContentGuard.sanitize_line/1` (same as `repaint/2`), then pads/
  truncates to the CURRENT footer row count.

  When the current footer row count is zero (degenerate geometry, see
  `degenerate?/1`), returns `t` immediately -- no `with_cursor/3` bracket
  is opened at all. Emitting an empty `\\e7`/`\\e8` save/restore pair over
  zero addressed rows would be a byte-for-byte no-op wrapped in
  ceremony; on a geometry that can't show a footer at all, emitting
  nothing is the honest behavior.
  """
  @spec keyframe(t(), [binary()]) :: t()
  def keyframe(%__MODULE__{} = t, new_lines) when is_list(new_lines) do
    count = footer_row_count(t)
    padded_new = sanitize_and_pad(new_lines, count)

    case count do
      0 -> %{t | footer_lines: padded_new, needs_keyframe: false}
      _ -> emit_footer_keyframe(t, padded_new)
    end
  end

  defp emit_footer_keyframe(t, padded_new) do
    footer_top = region_top(t) + 1

    iodata =
      padded_new
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        footer_row_bytes(footer_top + idx, line)
      end)

    t
    |> with_cursor(:footer, fn inner -> keyframe_footer(inner, iodata) end)
    |> Map.put(:footer_lines, padded_new)
    |> Map.put(:needs_keyframe, false)
  end

  # Common entry sanitization for both repaint/2 and keyframe/2: every
  # caller-supplied line is agent/LLM-originated (same trust boundary as
  # seal/2's history-side iodata -- see the moduledoc's `ContentGuard`
  # section) and must be neutralized BEFORE padding/diffing ever sees it.
  defp sanitize_and_pad(new_lines, count) do
    new_lines
    |> Enum.map(&ContentGuard.sanitize_line/1)
    |> pad_rows(count)
  end

  @doc "The current footer row count -- the size of `ScrollRegionManager.footer_range/1`, never a hand-maintained constant."
  @spec footer_row_count(t()) :: non_neg_integer()
  def footer_row_count(%__MODULE__{region: region}),
    do: Range.size(ScrollRegionManager.footer_range(region))

  defp footer_row_bytes(row, line), do: [cup(row), "\e[K", line]

  defp pad_rows(lines, count) do
    lines |> Enum.take(count) |> pad_tail(count)
  end

  defp pad_tail(lines, count) do
    case count - length(lines) do
      n when n > 0 -> lines ++ List.duplicate("", n)
      _ -> lines
    end
  end

  @impl true
  def with_cursor(%__MODULE__{in_cursor_bracket: true}, cursor_region, fun)
      when cursor_region in [:history, :footer] and is_function(fun, 1) do
    raise "PaintAuthority.InlineAuthority.with_cursor/3 called while a " <>
            "save/restore bracket is already open -- the single hardware " <>
            "DECSC register has exactly one slot, so a nested save would " <>
            "silently clobber the outer bracket's saved position before " <>
            "its own restore runs. Route the nested operation through the " <>
            "SAME bracket instead of opening a second one (see the " <>
            "moduledoc's cursor-ownership protocol section)."
  end

  def with_cursor(%__MODULE__{region: region} = t, cursor_region, fun)
      when cursor_region in [:history, :footer] and is_function(fun, 1) do
    device = region.device
    IO.write(device, Dialect.cursor_save())

    # `with_cursor/3` is the SOLE owner of the `\e7`/`\e8` save/restore
    # pair (moduledoc, "the cursor-ownership protocol"). The restore MUST
    # run even if `fun` raises, or the single hardware DECSC register is
    # left holding a save with no matching restore -- an unbalanced
    # bracket that violates the sole-owner guarantee for every caller
    # after this one. `after` runs on both normal return and unwind; the
    # exception itself is never swallowed, only the restore is guaranteed.
    #
    # `in_cursor_bracket: true` is set on the state passed INTO `fun` (not
    # on `t` itself) so a nested `with_cursor/3` call reached from inside
    # `fun` hits the guard clause above instead of opening a second
    # bracket. The flag is cleared again on the way out (whatever `fun`
    # returned) so the NEXT top-level `with_cursor/3` call on this
    # authority is not permanently locked out.
    try do
      result = fun.(%{t | in_cursor_bracket: true})
      %{result | in_cursor_bracket: false}
    after
      IO.write(device, Dialect.cursor_restore())
    end
  end

  @doc """
  Re-derives the DECSTBM history/footer split for a new geometry (via
  the scroll-region manager's `ScrollRegionManager.resize/2`, one
  `CSI 1;(H-N) r` write) and clamps the append cursor. Deliberately does
  NOT also repaint the footer's on-screen content here -- an existing
  regression test on the append path
  (`renderer_adversarial_property_test.exs`, "the ONLY new bytes after
  resize are ScrollRegionManager's single DECSTBM re-set") pins this
  callback to emit nothing else, and folding a footer keyframe in here
  would silently break that pinned byte-count. Callers that also need
  the footer redrawn at the new geometry compose explicitly:
  `authority |> resize(w, h) |> keyframe(current_footer_lines)` -- see
  the moduledoc's "pinned footer viewport" section. Neither call ever
  emits `\\e[2J`/`\\e[3J` or addresses a history row, so the composition
  inherits both properties.

  When the resize changes EITHER axis -- vertical geometry
  (`ScrollRegionManager.geometry_changed?/2`) OR width (`t.width != width`) --
  also sets `needs_keyframe: true` -- a pure state change, zero bytes -- so the
  NEXT `repaint/2` call self-promotes to a full `keyframe/2` instead of trusting
  a diff against footer content whose on-screen ROW POSITIONS moved (vertical)
  or whose width-correct truncation went stale / whose sealed history rewrapped
  (horizontal). This is independent of `reflow_capable?/1`/the telemetry hook
  below: the ghost-content risk applies to every terminal's footer, not just the
  reflow-capable subset.
  """
  @impl true
  def resize(%__MODULE__{region: region, next_row: next_row} = t, width, height) do
    old_region = region
    new_region = ScrollRegionManager.resize(region, height)

    geometry_changed? =
      ScrollRegionManager.geometry_changed?(old_region, new_region)

    # `geometry_changed?` is the REGION-re-emission gate: it watches the
    # VERTICAL axis (`history_bottom`, row-based) and is correctly blind to
    # width — a width-only resize needs no DECSTBM bytes (the append
    # path's pinned regression). But keyframe + reflow are HORIZONTAL
    # concerns: reflow-capable terminals rewrap sealed history on a WIDTH
    # change (the terminal-matrix probe measured this on 4/5 terminals —
    # kitty is the no-reflow exception), and a width-shrink can wrap an
    # untruncated footer line past the pin. So the latch and the reflow
    # seam key on the width axis too; only the region re-emission stays
    # vertical-only.
    width_changed? = t.width != width
    reflow_relevant? = geometry_changed? or width_changed?

    if reflow_relevant? and t.reflow_capable? do
      # The reflow-aware detection seam firing: this session's terminal
      # is known, from the real-hardware terminal-matrix probe, to reflow
      # sealed history cleanly on a geometry-changing resize. NOTHING is
      # re-emitted here — re-emission is a FUTURE unit's job (ship
      # seal-time-only now; reflow-aware re-emission is a runtime-detected
      # ADDITIVE upgrade). This telemetry event is the thin hook that unit
      # gates on — it carries BOTH axes so the future unit can tell a
      # rewrapping width change from a pure row change.
      :telemetry.execute(
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        %{},
        %{
          old_region_top: ScrollRegionManager.history_bottom(old_region),
          new_region_top: ScrollRegionManager.history_bottom(new_region),
          old_width: t.width,
          new_width: width
        }
      )
    end

    %{
      t
      | region: new_region,
        width: width,
        # Existing on-screen content is untouched (seal-time-only: no
        # re-emission) — only where FUTURE appends resume is clamped to
        # the (possibly smaller) new bottom row.
        next_row: min(next_row, ScrollRegionManager.history_bottom(new_region)),
        needs_keyframe: t.needs_keyframe or reflow_relevant?
    }
  end

  @doc """
  Grows or shrinks the footer viewport by `new_footer_rows` rows, WITHOUT
  a real terminal resize (`rows`/`width` unchanged) -- see the
  moduledoc's "Growing/shrinking the footer" section for the full
  rationale. This is the seam `Raxol.Harness.Surface.open_overlay/3` and
  `close_overlay/1` use to host `Raxol.UI.Harness.OverlayPicker`.

  Returns `{:error, :degenerate}` (zero bytes) when the target
  `new_footer_rows` would leave history unable to keep its 2-row minimum
  (`ScrollRegionManager.degenerate?/2`) -- a temporary overlay must never
  unpin the live footer. Returns `{:ok, t}` unchanged (zero bytes) when
  `new_footer_rows` equals the current footer row count.

  Otherwise grows (claims rows from history, scrolling any occupied
  claimed rows up into native scrollback first -- never painting over
  them) or shrinks (clears the vacated rows while they are still
  footer-owned, then re-pins) and sets `needs_keyframe: true` either way,
  so the next `repaint/2` self-promotes to a full `keyframe/2` at the new
  split.
  """
  @spec set_footer_rows(t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :degenerate}
  def set_footer_rows(%__MODULE__{region: region} = t, new_footer_rows)
      when is_integer(new_footer_rows) and new_footer_rows >= 0 do
    rows = ScrollRegionManager.rows(region)
    old_footer_rows = ScrollRegionManager.footer_rows(region)

    cond do
      new_footer_rows == old_footer_rows ->
        {:ok, t}

      ScrollRegionManager.degenerate?(rows, new_footer_rows) ->
        {:error, :degenerate}

      true ->
        old_bottom = ScrollRegionManager.history_bottom(region)
        new_bottom = ScrollRegionManager.history_bottom(rows, new_footer_rows)

        updated =
          if new_bottom < old_bottom do
            grow_footer(t, old_bottom, new_bottom, new_footer_rows)
          else
            shrink_footer(t, old_bottom, new_bottom, new_footer_rows)
          end

        {:ok, updated}
    end
  end

  # Claims `old_bottom - new_bottom` rows from history for the footer.
  # Whatever currently occupies the reclaimed range (rows
  # `new_bottom+1..old_bottom`) is scrolled up first (never painted over)
  # -- see moduledoc, "Growing/shrinking the footer".
  defp grow_footer(
         %__MODULE__{next_row: next_row} = t,
         old_bottom,
         new_bottom,
         new_footer_rows
       ) do
    k = grow_reclaim_count(next_row, old_bottom, new_bottom)
    t = if k > 0, do: scroll_history_up(t, old_bottom, k), else: t
    next_row_after_scroll = if k > 0, do: max(next_row - k, 1), else: next_row
    new_region = ScrollRegionManager.set_footer_rows(t.region, new_footer_rows)

    %{
      t
      | region: new_region,
        next_row: min(next_row_after_scroll, new_bottom),
        needs_keyframe: true
    }
  end

  # `append_sealed/2` maintains one loop invariant unconditionally: rows
  # `1..(next_row - 1)` hold real content, and row `next_row` itself is
  # ALWAYS blank -- either genuinely never written yet, or (once `next_row`
  # reaches the bottom margin) freshly re-blanked by the terminal's own
  # index-at-region-boundary scroll that every `\r\n`-terminated seal ends
  # with. Reclaiming down to `new_bottom` must reproduce that SAME
  # invariant for the shrunk region: after evicting the oldest `k` rows,
  # row `new_bottom` must land inside the blank tail, i.e.
  # `new_bottom >= (next_row - 1 - k) + 1`, i.e. `k >= next_row - new_bottom`.
  # `max(next_row - new_bottom, 0)` is exactly that minimal `k` -- and it
  # subsumes the old "steady state" special case (`next_row == old_bottom`)
  # for free, since `next_row` never exceeds `old_bottom` to begin with.
  # A smaller `k` (the previous `max(next_row - 1 - new_bottom, 0)` formula
  # used for the non-steady-state branch) under-scrolls by exactly one row
  # whenever real content reaches all the way to the new boundary: row
  # `new_bottom` ends up holding genuine content instead of the blank the
  # rest of this module assumes, and the very next `seal/2` silently
  # overwrites it instead of scrolling -- pinned by the "grow over a
  # PARTIALLY-filled history" regression in overlay_picker_surface_test.exs.
  defp grow_reclaim_count(next_row, _old_bottom, new_bottom) do
    max(next_row - new_bottom, 0)
  end

  # Scrolls `k` rows out of the OLD (still wider) DECSTBM region by
  # writing plain `"\n"` bytes at its bottom row -- each one an
  # index-at-region-boundary, evicting the top row into native
  # scrollback, never repainting anything. Written directly (not through
  # `append_sealed/2`): this is geometry housekeeping, not a sealed
  # content append, and carries no `next_row` bookkeeping of its own.
  defp scroll_history_up(t, old_bottom, k) do
    with_cursor(t, :history, fn inner ->
      device = inner.region.device
      IO.write(device, Dialect.cursor_position(old_bottom))
      IO.write(device, String.duplicate("\n", k))
      inner
    end)
  end

  # Gives `new_bottom - old_bottom` rows back to history. The vacated
  # range (rows `old_bottom+1..new_bottom`) is still footer-owned until
  # the split actually moves, so each row is explicitly cleared here --
  # history appends resume above them and would otherwise never touch
  # them again, leaving stale overlay pixels forever.
  defp shrink_footer(
         %__MODULE__{next_row: next_row} = t,
         old_bottom,
         new_bottom,
         new_footer_rows
       ) do
    t = clear_vacated_rows(t, old_bottom, new_bottom)
    new_region = ScrollRegionManager.set_footer_rows(t.region, new_footer_rows)
    %{t | region: new_region, next_row: next_row, needs_keyframe: true}
  end

  defp clear_vacated_rows(t, old_bottom, new_bottom) do
    with_cursor(t, :footer, fn inner ->
      device = inner.region.device

      Enum.each((old_bottom + 1)..new_bottom//1, fn row ->
        IO.write(device, Dialect.cursor_position(row))
        IO.write(device, "\e[K")
      end)

      inner
    end)
  end

  @doc """
  Re-asserts the DECSTBM history/footer split UNCONDITIONALLY (via
  `ScrollRegionManager.reassert/1`, one `CSI 1;(H-N) r` write regardless
  of whether geometry changed) and latches `needs_keyframe: true` -- the
  resume entry point after an external process owned the terminal (an
  `$EDITOR` session that released the region via the canonical suspend
  bytes).

  ## Why `resize/3` alone cannot do this

  `resize/3`'s region re-emission is geometry-gated (see
  `ScrollRegionManager.resize/2`'s "Geometry-gated resize emission"):
  when the terminal was NOT resized while suspended, `history_bottom` is
  unchanged and resize writes ZERO region bytes -- silently leaving the
  region released even though this struct still believes the footer is
  pinned. The documented resume composition is therefore

      authority |> resize(new_w, new_h) |> reassert()

  -- `resize/3` handles a mid-suspend geometry change (and may emit its
  own region bytes for it; the duplicate emit from `reassert/1` in that
  case is harmless -- identical, idempotent bytes), `reassert/1`
  guarantees the pin for the unchanged case.

  ## Why the latch instead of an explicit keyframe

  The editor repainted arbitrary screen content while it owned the tty,
  so the last-painted `footer_lines` no longer describe what is
  on-screen -- a logical diff against them would be a lie. Setting
  `needs_keyframe` (a pure state change, zero bytes) makes the NEXT
  `repaint/2` self-promote to a full `keyframe/2` (the existing
  post-resize ghost-content mechanism, see the moduledoc), so the first
  ordinary footer paint after resume fully re-renders every footer row
  with no new paint code and no second keyframe call site.

  Never emits `\\e[2J`/`\\e[3J`; never addresses a history row. Sealed
  history above the footer survives the whole suspend/resume bracket
  untouched by construction.
  """
  @spec reassert(t()) :: t()
  def reassert(%__MODULE__{region: region} = t) do
    %{t | region: ScrollRegionManager.reassert(region), needs_keyframe: true}
  end

  @impl true
  def region_top(%__MODULE__{region: region}),
    do: ScrollRegionManager.history_bottom(region)

  @doc """
  True when this authority's current geometry cannot form a valid DECSTBM
  region — i.e. the footer is NOT actually pinned right now (see the
  moduledoc's "Degenerate geometry" section). A thin delegation to
  `ScrollRegionManager.degenerate?/1`; no behavior change of its own.
  Callers that need to know whether the pin is real should check this
  rather than assuming `new/5`/`resize/3` always succeeded.
  """
  @spec degenerate?(t()) :: boolean()
  def degenerate?(%__MODULE__{region: region}),
    do: ScrollRegionManager.degenerate?(region)

  defp cup(row), do: "\e[#{row};1H"

  defp count_lines(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> :binary.matches("\n")
    |> length()
  end
end
