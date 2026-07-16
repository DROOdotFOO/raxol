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

  ## T2c: the pinned footer viewport (buffer-diff, footer-scoped)

  T2b's `repaint_footer/2`/`keyframe_footer/2` `@impl` callbacks were
  deliberate placeholders ("mirrors `PaintAuthority.IOAuthority`'s
  minimal stub so the behaviour is satisfied without reaching into T2c's
  work"). T2c fills that in with the real buffer-diff pipeline the
  roadmap describes ("a buffer-diff pipeline scoped to the footer rows
  only... every emitted CUP scoped to footer rows"):

    * `footer_diff/2` — pure function, no I/O: given the last-painted
      footer content and the next footer content (both one binary per
      footer row, top-to-bottom, already padded/truncated to the same
      row count), returns only the `{row_index, line}` pairs that
      actually changed. This is the "minimal repaint bytes" half of the
      pipeline, kept separate from the emit half so it is unit-testable
      with zero device/cursor setup.
    * `repaint/2` — the diff-driven entry point (T2c's normal per-frame
      footer update): pads/truncates the caller's next footer lines to
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
      see `resize/3`'s doc for why (an existing T2b regression test
      pins resize to emit only the DECSTBM re-set). Callers that also
      need the footer re-rendered at the new geometry compose explicitly:
      `authority |> InlineAuthority.resize(w, h) |> InlineAuthority.keyframe(current_lines)`.
      Both calls already guarantee no `\\e[2J`/`\\e[3J` and no history
      addressing, so the composition inherits both properties for free.

  Every row either function addresses is computed from
  `region_top(t) + 1 .. rows(region)` (T2a's `footer_range/1`) — never a
  hand-maintained constant — so a footer paint can never drift into the
  scrolling history region even under resize.

  ## Caller contract: footer line width (NOT enforced here)

  `repaint/2` and `keyframe/2` pad/truncate the LIST of footer lines to the
  current footer row COUNT (`footer_row_count/1`) — but neither function
  measures or truncates an individual LINE's display width. A line wider
  than the terminal's column count wraps onto the following row (a real
  terminal's own line-wrap behavior), which breaks footer confinement: the
  wrapped tail lands on whatever row follows, which may be the next footer
  row (silently overwriting content INV-2 assumes only `repaint/2`
  addresses) or, on the LAST footer row, past the bottom of the screen
  entirely. This module does not defend against that — it is the caller's
  (T13a's assembler) responsibility to display-width-truncate every line
  to the authority's `width` (the same value passed to `new/5`) BEFORE
  calling `repaint/2`/`keyframe/2`. Use `Raxol.UI.TextMeasure` for that
  measurement — never `String.length/1`, which undercounts double-width
  (CJK) characters and would let a line that measures "short" by codepoint
  count still overflow the column budget.

  ## Degenerate geometry: `degenerate?/1`

  A terminal too short for its requested footer (`rows - footer_rows < 2`,
  T2a's `ScrollRegionManager.degenerate?/1`) cannot have its footer
  actually pinned via DECSTBM — see that module's moduledoc for why. This
  module surfaces that fact via `degenerate?/1` (a thin delegation, no
  behavior change) so callers can detect the condition and adapt — e.g.
  T13a falling back to redrawing the footer every frame — instead of
  silently trusting a pin that a real terminal ignored. `repaint/2` and
  `keyframe/2` still function on a degenerate geometry (never crash): they
  simply operate over whatever footer capacity `footer_range/1` actually
  reports for that geometry, which may be smaller than `footer_rows`
  requested, or empty.
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
    footer_lines: []
  ]

  @type t :: %__MODULE__{
          region: ScrollRegionManager.t(),
          width: pos_integer(),
          reflow_capable?: boolean(),
          next_row: pos_integer(),
          in_cursor_bracket: boolean(),
          footer_lines: [binary()]
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
      next_row: 1
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
    binary = IO.iodata_to_binary(iodata)

    unless String.ends_with?(binary, "\r\n") do
      raise ArgumentError,
            "PaintAuthority.InlineAuthority.seal/2 requires \\r\\n-terminated " <>
              "iodata (a sealed block must be a whole number of lines); got " <>
              inspect(binary)
    end

    sanitized = ContentGuard.sanitize_line(binary)

    with_cursor(t, :history, fn inner -> append_sealed(inner, sanitized) end)
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

  @doc """
  T2c's diff-driven footer repaint: pads/truncates `new_lines` to the
  CURRENT footer row count, diffs against the last-painted footer
  (`footer_diff/2`), and emits only the changed rows -- each `CUP`
  (inside the footer range, never history) + `\\e[K` (per-row clear,
  never `\\e[2J`) + the new line content -- inside one `with_cursor/3`
  bracket. Zero changed rows emits zero bytes. Updates `footer_lines` so
  the next call diffs against what was actually painted.
  """
  @spec repaint(t(), [binary()]) :: t()
  def repaint(%__MODULE__{footer_lines: old_lines} = t, new_lines)
      when is_list(new_lines) do
    count = footer_row_count(t)
    padded_new = pad_rows(new_lines, count)
    padded_old = pad_rows(old_lines, count)

    case footer_diff(padded_old, padded_new) do
      [] ->
        t

      changes ->
        footer_top = region_top(t) + 1

        iodata =
          Enum.map(changes, fn {idx, line} ->
            footer_row_bytes(footer_top + idx, line)
          end)

        t
        |> with_cursor(:footer, fn inner -> repaint_footer(inner, iodata) end)
        |> Map.put(:footer_lines, padded_new)
    end
  end

  @doc """
  Footer keyframe: every footer row cleared (`\\e[K`, never a
  full-screen clear) and rewritten, regardless of what changed. The
  Ctrl-L recovery entry point, and what a caller composes after
  `resize/3` to re-derive the footer's on-screen content at the new
  geometry (see the moduledoc's "T2c" section for why `resize/3` itself
  does not call this). Pads/truncates `new_lines` to the CURRENT footer
  row count, same as `repaint/2`.
  """
  @spec keyframe(t(), [binary()]) :: t()
  def keyframe(%__MODULE__{} = t, new_lines) when is_list(new_lines) do
    count = footer_row_count(t)
    padded_new = pad_rows(new_lines, count)
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
  T2a's `ScrollRegionManager.resize/2`, one `CSI 1;(H-N) r` write) and
  clamps the append cursor. Deliberately does NOT also repaint the
  footer's on-screen content here -- an existing T2b regression test
  (`renderer_adversarial_property_test.exs`, "the ONLY new bytes after
  resize are ScrollRegionManager's single DECSTBM re-set") pins this
  callback to emit nothing else, and folding a footer keyframe in here
  would silently break that pinned byte-count. Callers that also need
  the footer redrawn at the new geometry compose explicitly:
  `authority |> resize(w, h) |> keyframe(current_footer_lines)` -- see
  the moduledoc's "T2c" section. Neither call ever emits
  `\\e[2J`/`\\e[3J` or addresses a history row, so the composition
  inherits both properties.
  """
  @impl true
  def resize(%__MODULE__{region: region, next_row: next_row} = t, width, height) do
    old_region = region
    new_region = ScrollRegionManager.resize(region, height)

    if ScrollRegionManager.geometry_changed?(old_region, new_region) and
         t.reflow_capable? do
      # The reflow-aware detection seam firing: this session's terminal
      # is known, from the terminal-matrix probe, to reflow sealed
      # history cleanly on a geometry-changing resize. NOTHING is
      # re-emitted here — re-emission is a FUTURE unit's job (ship
      # seal-time-only now; reflow-aware re-emission is a
      # runtime-detected ADDITIVE upgrade). This telemetry event is the
      # thin hook that unit gates on.
      :telemetry.execute(
        [:raxol, :ui, :paint_authority, :reflow_capable_resize],
        %{},
        %{
          old_region_top: ScrollRegionManager.history_bottom(old_region),
          new_region_top: ScrollRegionManager.history_bottom(new_region)
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
        next_row: min(next_row, ScrollRegionManager.history_bottom(new_region))
    }
  end

  @impl true
  def region_top(%__MODULE__{region: region}),
    do: ScrollRegionManager.history_bottom(region)

  @doc """
  True when this authority's current geometry cannot form a valid DECSTBM
  region — i.e. the footer is NOT actually pinned right now (see the
  moduledoc's "Degenerate geometry" section). A thin delegation to T2a's
  `ScrollRegionManager.degenerate?/1`; no behavior change of its own.
  Callers that need to know whether the pin is real (T13a's assembler)
  should check this rather than assuming `new/5`/`resize/3` always
  succeeded.
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
