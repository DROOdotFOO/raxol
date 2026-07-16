defmodule Raxol.Harness.Test.BuggyAuthority do
  @moduledoc """
  Hand-written violating byte streams for the TB oracle self-test (R-P12:
  "the oracle must flag a known-bad byte stream before any of its passes are
  trusted") and for reuse, without duplication, by T2b/T2c's negative
  property suite (`renderer_adversarial_property_test.exs`, R-N1..N7 in
  `harness-ui-testing/02-renderer.md` §5).

  Each function returns raw ANSI bytes a CORRECT `PaintAuthority`
  implementation would never emit. The paired assertion lives in
  `Raxol.Harness.Test.SealOracle` — see the moduledoc on each function below
  for which oracle/invariant catches it. The mutation-completeness table
  test in `test/harness/tb_oracle_test.exs` guarantees every invariant
  INV-1..6 has at least one kill stream here.
  """

  alias Raxol.UI.Rendering.PaintAuthority.Dialect

  @doc """
  Footer-bleed CUP (R-N2 class): a footer repaint positions the cursor ONE
  ROW into the history region (`region_top`) and writes there — the footer
  path leaking outside its confinement. Caught by INV-2
  (`SealOracle.cup_rows/1` includes `region_top`, which must never appear
  among footer-origin addresses).
  """
  @spec footer_bleed_cup(pos_integer()) :: binary()
  def footer_bleed_cup(region_top) when is_integer(region_top) do
    "\e[#{region_top};1H\e[2KLEAKED INTO HISTORY"
  end

  @doc """
  Footer-bleed via RELATIVE movement (R-N2 class, the sneaky variant): the
  footer path CUPs to its own first footer row — legal — then moves UP one
  row with CUU (`CSI 1 A`) into `region_top` (history) and writes there. An
  absolute-CUP-only scanner false-passes this stream; the stateful O1 row
  walk (`SealOracle.cup_rows/2`) catches it because relative movement also
  lands the cursor on a history row.
  """
  @spec footer_bleed_relative(pos_integer()) :: binary()
  def footer_bleed_relative(region_top) when is_integer(region_top) do
    "\e[#{region_top + 1};1H\e[1A\e[2KLEAKED VIA CUU"
  end

  @doc """
  Full-screen clear (R-N1 class): today's `build_terminal_frame/4` keyframe
  idiom, forbidden on the inline path. Caught by INV-3
  (`SealOracle.emits_full_clear?/1`).
  """
  @spec full_screen_clear() :: binary()
  def full_screen_clear do
    "\e[2J\e[1;1Hrepainted everything"
  end

  @doc """
  Unbalanced cursor save (R-N3 class): the cursor is saved (DECSC `\\e7`)
  but never restored — a single-owner leak between the two emit paths.
  Caught by INV-4 (`SealOracle.save_restore_balance/1` returns a nonzero
  `:decsc` count).
  """
  @spec unbalanced_cursor_save() :: binary()
  def unbalanced_cursor_save do
    "\e7\e[1;1HAppended without restoring the cursor"
  end

  @doc """
  Sealed-row rewrite (the Ink-style failure INV-1 exists to reject): a block
  is sealed at row 1, then — LATER, after other content has been sealed —
  the SAME row is CUP-addressed again and overwritten.

  Returns `{sealed_at_k, final}`: replay `sealed_at_k` alone to compute
  `history_k`, then replay `final` (which extends `sealed_at_k`) to compute
  `history_final`. Caught by INV-1
  (`SealOracle.immutable_prefix?/2` returns a `{:violation, ...}` tuple
  instead of `:ok` — `history_k` is no longer a prefix of `history_final`).
  """
  @spec sealed_row_rewrite() :: {binary(), binary()}
  def sealed_row_rewrite do
    sealed_at_k = "\e[1;1H\e[2Koriginal sealed content\r\n"
    rewrite = "\e[1;1H\e[2Krewritten! (violates seal-once)\r\n"
    {sealed_at_k, sealed_at_k <> rewrite}
  end

  @doc """
  Sealed-BLANK-row rewrite (the trailing-blank-trim blind spot): a block is
  sealed whose LAST line is intentionally blank (row 2 written as an empty
  line), then later that blank row is overwritten. Content-wise a
  written-blank row is indistinguishable from never-written capacity, so a
  content-based trailing-blank trim on `history/2` false-passes this stream;
  only the emit-derived high-water mark (`SealOracle.seal_high_water/1` +
  `history/3` with `:high_water`) catches it.

  Returns `{sealed_at_k, final}`, same protocol as `sealed_row_rewrite/0`.
  """
  @spec sealed_blank_rewrite() :: {binary(), binary()}
  def sealed_blank_rewrite do
    sealed_at_k = "\e[1;1H\e[2Kfirst sealed line\r\n\e[2;1H\e[2K\r\n"
    rewrite = "\e[2;1H\e[2Ksmuggled into the sealed blank\r\n"
    {sealed_at_k, sealed_at_k <> rewrite}
  end

  @doc """
  Nested cursor save (R-N3 class, the balance-blind variant): two DECSC
  saves before any restore. Net save/restore balance is ZERO — a
  net-balance-only check false-passes it — but the single hardware DECSC
  register means the inner save silently destroyed the outer saved
  position. Caught by the running max-depth check
  (`SealOracle.save_restore_balance/1` `:decsc_max_depth` > 1).
  """
  @spec nested_cursor_save() :: binary()
  def nested_cursor_save do
    "\e7\e[1;1Houter\e7\e[2;1Hinner\e8\e8"
  end

  @doc """
  Footer-bleed via VPA (R-N2 class, absolute-but-not-CUP): CUP to a legal
  footer row, then VPA (`CSI Pn d`) directly to `region_top` (history) and
  write. Caught by the modeled `d` clause in the O1 row walk.
  """
  @spec footer_bleed_vpa(pos_integer()) :: binary()
  def footer_bleed_vpa(region_top) when is_integer(region_top) do
    "\e[#{region_top + 1};1H\e[#{region_top}d\e[2KLEAKED VIA VPA"
  end

  @doc """
  Keyframe/Ctrl-L touching a history row (INV-6 kill): a footer keyframe
  redraw burst that CUP-addresses `region_top` (the last history row) and
  repaints it. Caught by INV-2/INV-6 — the keyframe-origin row set must be
  confined to footer rows.
  """
  @spec keyframe_history_touch(pos_integer()) :: binary()
  def keyframe_history_touch(region_top) when is_integer(region_top) do
    "\e[#{region_top};1H\e[2Kkeyframe repainted a sealed history row"
  end

  @doc """
  Doubled DECSTBM on resize (INV-5 kill): the region re-set emitted twice
  in one resize. Caught by `SealOracle.region_sets/1` diverging from the
  exactly-once expected list.
  """
  @spec double_region_set(pos_integer()) :: binary()
  def double_region_set(region_top) when is_integer(region_top) do
    Dialect.region_set(1, region_top) <> Dialect.region_set(1, region_top)
  end

  @doc """
  Wrong DECSTBM bounds on resize (INV-5 kill): the region re-set names a
  bottom row one past the correct `h - N` boundary (the footer's first row
  would scroll with history). Caught by `SealOracle.region_sets/1` bounds
  comparison.
  """
  @spec wrong_region_bounds(pos_integer()) :: binary()
  def wrong_region_bounds(region_top) when is_integer(region_top) do
    Dialect.region_set(1, region_top + 1)
  end

  @doc """
  IL row shift (fail-closed kill): `CSI 2 L` inserts lines at the cursor,
  shifting every row below it — movement the O1 row walk does not model.
  The point of this stream is proving the walk REJECTS what it cannot
  verify: `row_walk/2` returns `{:unverifiable, token}` instead of
  false-passing.
  """
  @spec il_shift() :: binary()
  def il_shift do
    "\e[5;1H\e[2Lshifted sealed rows down"
  end

  @doc """
  Partial ED (fail-closed kill): `CSI J` (ED 0) clears from the cursor to
  end of screen — content destruction across rows the O1 row walk cannot
  attribute. Like `il_shift/0`, must die via the fail-closed path
  (`{:unverifiable, token}`), never pass silently.
  """
  @spec ed_partial() :: binary()
  def ed_partial do
    "\e[5;1H\e[Jcleared from cursor to end of screen"
  end

  @doc """
  A known-good stream for the same shape as `sealed_row_rewrite/0`: a block
  sealed once, never revisited, followed by a SECOND, different block
  sealed below it (advancing the cursor down instead of rewriting). Used as
  the "does the oracle also pass a good stream" half of the self-test.
  """
  @spec sealed_stream_ok() :: {binary(), binary()}
  def sealed_stream_ok do
    sealed_at_k = "\e[1;1H\e[2Kfirst sealed block\r\n"
    appended = "\e[2;1H\e[2Ksecond sealed block\r\n"
    {sealed_at_k, sealed_at_k <> appended}
  end
end
