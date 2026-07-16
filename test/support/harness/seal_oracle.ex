defmodule Raxol.Harness.Test.SealOracle do
  @moduledoc """
  The two oracles from `harness-ui-testing/02-renderer.md` §2, built
  ADDITIVELY on top of `test/support/cross_terminal/` — no VT
  re-implementation here (CLAUDE.md rule: reuse `raxol_terminal`'s parser as
  the test oracle).

    * **O1 — mechanical / positional** (`scroll_region/1`, `cup_rows/2`,
      `emits_full_clear?/1`, `save_restore_balance/1`): tokenizes via
      `Raxol.Test.CrossTerminal.SequenceScanner.scan/1` and runs a small
      stateful positional model over the token stream (absolute CUP AND
      relative movement — see `cup_rows/2`). Cheap; catches
      footer-confinement (INV-2), no-full-clear (INV-3), and
      cursor-balance/depth (INV-4) violations. It CANNOT prove a sealed
      block's *content* is unchanged — only that no addressing crosses
      into the frozen zone. That is O2's job.

    * **O2 — content-level / VT replay** (`replay/2`, `history/3`,
      `immutable_prefix?/2`): feeds bytes into the real
      `Raxol.Terminal.Emulator` via
      `Raxol.Test.CrossTerminal.AnsiReplayer` and compares actual grid/
      scrollback state. Catches the seal-once violation (INV-1) — the
      keystone assertion of the whole T2b/T2c suite.

  All wire-level row/column numbers in this module (CSI params, CUP) are
  **1-based**, matching the ANSI wire format the roadmap uses (`CSI
  1;(H-N) r`). This is independent of `Raxol.Terminal.Emulator`'s internal
  0-based `get_scroll_region/1` representation — do not conflate the two.
  """

  alias Raxol.Harness.Test.CaptureAuthority
  alias Raxol.Terminal.Emulator
  alias Raxol.Test.CrossTerminal.{AnsiReplayer, SequenceScanner}

  defmodule UnverifiableError do
    @moduledoc """
    Raised by `cup_rows/2` when the O1 row walk meets a token outside its
    modeled/ignorable whitelists. O1 is FAIL-CLOSED: a token it cannot
    model is a failed assertion, never a silent skip — escalate the stream
    to O2 or reject it.
    """
    defexception [:token]

    @impl true
    def message(%{token: token}) do
      "O1 row walk is fail-closed: unmodeled row/content-affecting token " <>
        "#{inspect(token)} — escalate to the O2 replay oracle or reject " <>
        "the stream (see SealOracle.row_walk/2 for the three-way token split)"
    end
  end

  # ---------------------------------------------------------------------
  # O1 — mechanical / positional (no emulation)
  # ---------------------------------------------------------------------

  @doc """
  The scroll region `{top, bottom}` (1-based, as transmitted) set by the
  MOST RECENT `CSI top;bottom r` (DECSTBM) in `raw`, or `nil` if none.
  """
  @spec scroll_region(binary()) :: {pos_integer(), pos_integer()} | nil
  def scroll_region(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.reduce(nil, fn
      {:csi, params, "r"}, acc -> parse_region(params) || acc
      _token, acc -> acc
    end)
  end

  defp parse_region(params) do
    with [top_s, bottom_s] <- String.split(params, ";"),
         {top, ""} <- Integer.parse(top_s),
         {bottom, ""} <- Integer.parse(bottom_s) do
      {top, bottom}
    else
      _ -> nil
    end
  end

  @doc """
  EVERY DECSTBM region set in `raw`, parsed, in emission order. The INV-5
  seam: a correct resize emits its region re-set EXACTLY ONCE with the
  right bounds, so the assertion is
  `region_sets(resize_bytes) == [{1, h - n}]` — a doubled re-set or wrong
  bounds both diverge from the single-element expected list.
  """
  @spec region_sets(binary()) :: [{pos_integer(), pos_integer()}]
  def region_sets(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.flat_map(fn
      {:csi, params, "r"} ->
        case parse_region(params) do
          nil -> []
          region -> [region]
        end

      _token ->
        []
    end)
  end

  @doc """
  FAIL-CLOSED stateful row walk: every row number (1-based) the cursor
  OCCUPIES after each movement in `raw`, in emission order — or
  `{:unverifiable, token}` the moment a token outside the whitelists
  appears. The basis for INV-2 (footer-confinement): every row a
  `:footer`/`:keyframe`-origin emit addresses must fall inside the footer
  row set, and a footer bleed via RELATIVE movement (CUP to a legal footer
  row, then CUU up into history) must be caught the same as an absolute
  one.

  ## The three-way token split

  Row-affecting vocabulary never stops growing (VPR, IL/DL, SU/SD, partial
  ED, RIS, DECALN, SCO restore, ...), so the walk does not chase tokens —
  it keeps whitelists and REJECTS everything else:

    * **Modeled** (row effect tracked): CUP `H` / HVP `f` / VPA `d`
      (absolute; missing/zero params default to 1) · CUU `A` / CUD `B` /
      CNL `E` / CPL `F` (relative) · IND `ESC D` / RI `ESC M` / NEL
      `ESC E` and `\\n` in text runs (index, with region-scroll semantics:
      at the DECSTBM boundary the REGION scrolls and the cursor row stays
      put) · DECSC/DECRC `ESC 7`/`ESC 8` (restore is movement) · DECSTBM
      `CSI t;b r` (homes the cursor to row 1, xterm semantics).

    * **Ignorable** (provably row/content-placement-safe): SGR `m` · EL
      `K`, ECH `X`, ICH `@`, DCH `P` (current-row-local; the row is
      already recorded by the movement that reached it) · CHA `G`, CUF
      `C`, CUB `D` (column-only) · DSR `n` · mode set/reset `h`/`l`
      EXCEPT alt-screen switches (`?1049`/`?47`, which relocate every row)
      · keypad `ESC =`/`ESC >` · OSC/DCS strings (titles, marks).

    * **Unverifiable → FAILURE** (everything else): VPR `e`, IL `L`, DL
      `M`, SU `S`, SD `T`, ED `J` (any params — partial 0/1 clears rows
      the walk can't see; 2/3 is also an INV-3 violation), window ops
      `t`, alt-screen `h`/`l`, RIS `ESC c`, DECALN `ESC # 8`, SCO
      save/restore `s`/`u`, unknown CSI finals, unknown ESC bytes. The
      walk halts with `{:unverifiable, token}`; INV assertions must treat
      it as a failed check (escalate to O2 or reject the stream), never a
      skip.

  The cursor starts at row 1. Rows are clamped to `>= 1` always, and to
  `opts[:height]` when given (default: unclamped below).
  """
  @spec row_walk(binary(), keyword()) ::
          {:ok, [pos_integer()]} | {:unverifiable, SequenceScanner.token()}
  def row_walk(raw, opts \\ []) when is_binary(raw) do
    height = Keyword.get(opts, :height, :infinity)

    raw
    |> SequenceScanner.scan()
    |> Enum.reduce_while({initial_walk_state(), []}, fn token, {state, rows} ->
      case classify(token) do
        :modeled -> {:cont, walk(token, state, rows, height)}
        :ignorable -> {:cont, {state, rows}}
        :unverifiable -> {:halt, {:unverifiable, token}}
      end
    end)
    |> case do
      {:unverifiable, token} -> {:unverifiable, token}
      {_state, rows} -> {:ok, Enum.reverse(rows)}
    end
  end

  @doc """
  `row_walk/2` with a list-only API for assertions: returns the row list,
  or RAISES `#{inspect(__MODULE__)}.UnverifiableError` on an unmodeled
  token — so an INV check written as `refute row in cup_rows(bytes)`
  fails closed instead of silently passing over vocabulary the walk
  doesn't model.
  """
  @spec cup_rows(binary(), keyword()) :: [pos_integer()]
  def cup_rows(raw, opts \\ []) when is_binary(raw) do
    case row_walk(raw, opts) do
      {:ok, rows} -> rows
      {:unverifiable, token} -> raise UnverifiableError, token: token
    end
  end

  @modeled_csi_finals ["H", "f", "d", "A", "B", "E", "F", "r"]
  @ignorable_csi_finals ["m", "K", "X", "@", "P", "G", "C", "D", "n"]
  @modeled_esc ["7", "8", "D", "M", "E"]
  @ignorable_esc ["=", ">"]

  defp classify({:csi, params, final}) do
    cond do
      final in @modeled_csi_finals -> :modeled
      final in ["h", "l"] -> classify_mode_switch(params)
      final in @ignorable_csi_finals -> :ignorable
      true -> :unverifiable
    end
  end

  defp classify({:esc, esc}) when esc in @modeled_esc, do: :modeled
  defp classify({:esc, esc}) when esc in @ignorable_esc, do: :ignorable
  defp classify({:esc, _esc}), do: :unverifiable
  defp classify({:osc, _body}), do: :ignorable
  defp classify({:dcs, _body}), do: :ignorable
  defp classify({:text, _text}), do: :modeled

  # Alt-screen switches relocate every row; everything else mode-shaped is
  # placement-safe.
  defp classify_mode_switch("?" <> params) do
    modes = params |> String.split(";") |> Enum.map(&String.trim/1)

    if Enum.any?(modes, &(&1 in ["1049", "47"])),
      do: :unverifiable,
      else: :ignorable
  end

  defp classify_mode_switch(_params), do: :ignorable

  defp initial_walk_state, do: %{row: 1, saved: nil, region: nil}

  defp walk({:csi, params, final}, state, rows, height)
       when final in ["H", "f", "d"] do
    row = params |> first_param(1) |> clamp(height)
    {%{state | row: row}, [row | rows]}
  end

  defp walk({:csi, params, "A"}, state, rows, height),
    do: move_relative(state, rows, -first_param(params, 1), height)

  defp walk({:csi, params, "B"}, state, rows, height),
    do: move_relative(state, rows, first_param(params, 1), height)

  defp walk({:csi, params, "E"}, state, rows, height),
    do: move_relative(state, rows, first_param(params, 1), height)

  defp walk({:csi, params, "F"}, state, rows, height),
    do: move_relative(state, rows, -first_param(params, 1), height)

  defp walk({:csi, params, "r"}, state, rows, _height) do
    # DECSTBM homes the cursor (xterm semantics).
    {%{state | region: parse_region(params), row: 1}, [1 | rows]}
  end

  defp walk({:esc, "7"}, state, rows, _height),
    do: {%{state | saved: state.row}, rows}

  defp walk({:esc, "8"}, state, rows, _height) do
    row = state.saved || state.row
    {%{state | row: row}, [row | rows]}
  end

  defp walk({:esc, esc}, state, rows, height) when esc in ["D", "E"],
    do: index_down(state, rows, height)

  defp walk({:esc, "M"}, state, rows, _height), do: index_up(state, rows)

  defp walk({:text, text}, state, rows, height) do
    newlines = text |> :binary.matches("\n") |> length()

    Enum.reduce(1..newlines//1, {state, rows}, fn _n, {s, r} ->
      index_down(s, r, height)
    end)
  end

  defp move_relative(state, rows, delta, height) do
    row = clamp(state.row + delta, height)
    {%{state | row: row}, [row | rows]}
  end

  # Region-scroll-on-newline: at the region's bottom row the REGION scrolls
  # and the cursor row is unchanged (recorded anyway — the cursor addresses
  # that row again).
  defp index_down(%{region: {_top, bottom}, row: row} = state, rows, _height)
       when row == bottom do
    {state, [row | rows]}
  end

  defp index_down(state, rows, height) do
    row = clamp(state.row + 1, height)
    {%{state | row: row}, [row | rows]}
  end

  defp index_up(%{region: {top, _bottom}, row: row} = state, rows)
       when row == top do
    {state, [row | rows]}
  end

  defp index_up(state, rows) do
    row = max(state.row - 1, 1)
    {%{state | row: row}, [row | rows]}
  end

  defp clamp(row, :infinity), do: max(row, 1)
  defp clamp(row, height), do: row |> max(1) |> min(height)

  defp first_param(params, default) do
    case params |> String.split(";") |> List.first() |> Integer.parse() do
      {n, _rest} when n > 0 -> n
      _other -> default
    end
  end

  @doc """
  True if `raw` contains a full-screen clear anywhere: `CSI 2 J`, `CSI 3 J`,
  or (as a special case of the former) the `\\e[H\\e[2J` idiom. INV-3: the
  inline path forbids this on every emit path.
  """
  @spec emits_full_clear?(binary()) :: boolean()
  def emits_full_clear?(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.any?(fn
      {:csi, params, "J"} -> params in ["2", "3"]
      _token -> false
    end)
  end

  @doc """
  Cursor save/restore balance AND running max depth for BOTH dialects —
  DECSC (`\\e7`/`\\e8`) and SCO (`\\e[s`/`\\e[u`) — since the owner dialect is
  not yet pinned (pending T2d, `harness-ui-testing/02-renderer.md` open
  question 3). Returns `%{decsc: n, sco: n, decsc_max_depth: d,
  sco_max_depth: d}`.

  INV-4 requires BOTH checks: balance `0` (every save matched by a restore)
  AND `max_depth <= 1`. A nested save (`\\e7 ... \\e7 ... \\e8 ... \\e8`) has
  net balance 0 but silently clobbers the single hardware save register —
  the max-depth field is what catches it.
  """
  @spec save_restore_balance(binary()) :: %{
          decsc: integer(),
          sco: integer(),
          decsc_max_depth: non_neg_integer(),
          sco_max_depth: non_neg_integer()
        }
  def save_restore_balance(raw) when is_binary(raw) do
    tokens = SequenceScanner.scan(raw)

    {decsc, decsc_max} = balance_walk(tokens, {:esc, "7"}, {:esc, "8"})
    {sco, sco_max} = balance_walk(tokens, {:csi, "", "s"}, {:csi, "", "u"})

    %{
      decsc: decsc,
      sco: sco,
      decsc_max_depth: decsc_max,
      sco_max_depth: sco_max
    }
  end

  defp balance_walk(tokens, save_token, restore_token) do
    Enum.reduce(tokens, {0, 0}, fn token, {depth, max_depth} ->
      cond do
        token == save_token -> {depth + 1, max(max_depth, depth + 1)}
        token == restore_token -> {depth - 1, max_depth}
        true -> {depth, max_depth}
      end
    end)
  end

  @doc "The row (1-based) implied by the LAST cursor-positioning sequence in `raw`, or `nil`."
  @spec last_cursor_row(binary()) :: pos_integer() | nil
  def last_cursor_row(raw) when is_binary(raw) do
    case cup_rows(raw) do
      [] -> nil
      rows -> List.last(rows)
    end
  end

  # ---------------------------------------------------------------------
  # O2 — content-level (VT replay)
  # ---------------------------------------------------------------------

  @doc """
  Replays `raw` into a fresh emulator — thin pass-through to
  `Raxol.Test.CrossTerminal.AnsiReplayer.replay/2` so oracle callers don't
  need a second alias.
  """
  @spec replay(binary(), keyword()) :: Emulator.t()
  def replay(raw, opts \\ []), do: AnsiReplayer.replay(raw, opts)

  @doc """
  The terminal-owned "sealed history" of a replayed emulator: rows already
  scrolled into `scrollback_buffer`, followed by the still-on-screen rows
  above the footer boundary. `region_top` is a ROW COUNT (`H - N`, matching
  `PaintAuthority.region_top/1`), not a wire-format row number.

      history(E) = Emulator.get_scrollback(E) ++ rows_above_footer(E)

  Both halves are lists of rows-of-`Cell` (the same shape
  `Emulator.get_scrollback/1` and `ScreenBuffer.cells` use), so
  `immutable_prefix?/2` compares exact cell content, not rendered text.

  ## Eviction hole — CLOSED BY TE (`02-renderer.md` open question 1)

  TB originally confirmed the emulator did NOT feed evicted scroll-region
  rows into `scrollback_buffer` (both live scroll paths blanked them),
  which cut both ways: spurious violations past region capacity AND O2
  false-passing a rewrite of any already-evicted row. TE
  (feat/harness-ui-TE, merged before TB) closes it: a TOP-ANCHORED scroll
  region (pre-scroll top == 0, including the no-region case) now feeds
  evictions into `scrollback_buffer` oldest-first via
  `Raxol.Terminal.Emulator.BufferOperations.feed_scrollback_from_region_scroll/3`
  (interior regions still discard, matching xterm; the alternate screen
  never feeds). That makes `history/3`'s `scrollback ++ on-screen` shape
  one continuous in-order record, so the seal-once immutable-prefix oracle
  is valid PAST region capacity — T2b's R-P1 1k-block stream included.
  TE's regression net lives in
  `test/harness/tb_scrollback_spike_test.exs`.

  Two residual caveats: `scrollback_limit` still bounds the comparable
  window (rows trimmed off the front of scrollback are gone — size the
  emulator's limit above the stream length in property runs), and interior
  -region evictions remain unverifiable by O2 (by design: they are not
  history).

  ## Sizing the sealed window: `:high_water` vs the blank-trim fallback

  The screen holds `region_top` rows of history CAPACITY, but only the rows
  the append cursor has actually reached are SEALED — the rest are future
  capacity that must not participate in the immutable-prefix comparison
  (else legitimately appending new content into an untouched row looks
  identical to rewriting sealed content).

    * **Preferred: `high_water:` option** — the number of sealed rows,
      derived from the EMIT stream (see `seal_high_water/1`), never from
      content. `history/3` then returns exactly the first `high_water`
      history rows.

    * **Fallback (no `high_water:` given): trailing-blank trim.** Rows at
      the tail that are entirely blank are dropped. **This fallback has a
      documented BLIND SPOT**: a deliberately sealed BLANK row (a block
      whose last line is empty) is content-indistinguishable from
      never-written capacity, gets trimmed, and a later rewrite of it
      false-passes. Pinned by the `sealed_blank_rewrite` self-test in
      `test/harness/tb_oracle_test.exs`. Callers asserting seal-once on
      streams that may seal blank lines MUST pass `high_water:`.
  """
  @spec history(Emulator.t(), pos_integer(), keyword()) :: [list()]
  def history(emulator, region_top, opts \\ []) when is_integer(region_top) do
    rows =
      Emulator.get_scrollback(emulator) ++
        rows_above_footer(emulator, region_top)

    case Keyword.get(opts, :high_water) do
      nil ->
        drop_trailing_blank_rows(rows)

      high_water when is_integer(high_water) and high_water >= 0 ->
        Enum.take(rows, high_water)
    end
  end

  @doc """
  The high-water mark of sealed rows, derived from the seal-path EMIT
  stream (never from screen content), for `history/3`'s `:high_water`.

  Two forms:

    * **`%CaptureAuthority{}` (preferred, exact):** counts sealed lines in
      the authority's own `:seal`-origin emit records — the authority KNOWS
      what it sealed; no other origin's bytes can contaminate the count.
      Pair with `assert_seal_newline_terminated/1`, which makes the
      one-line-per-`\\n` accounting an enforced invariant rather than an
      assumption.

    * **`binary()` (heuristic, for raw-bytes callers):** number of `\\n`
      bytes in the stream. Only valid when the binary is a pure seal-path
      stream whose every sealed line is newline-terminated — the caller
      owns that guarantee.

  The append path seals line-by-line, each line `\\r\\n`-terminated, so
  every `\\n` is one sealed row — including deliberately blank ones, which
  is exactly what the content-based fallback in `history/3` cannot see.
  """
  @spec seal_high_water(CaptureAuthority.t() | binary()) :: non_neg_integer()
  def seal_high_water(%CaptureAuthority{} = capture) do
    capture
    |> CaptureAuthority.log_by_origin(:seal)
    |> Enum.map_join("", & &1.bytes)
    |> seal_high_water()
  end

  def seal_high_water(bytes) when is_binary(bytes) do
    bytes |> :binary.matches("\n") |> length()
  end

  @doc """
  Enforces the seal-path emit discipline `seal_high_water/1` counts on:
  every `:seal`-origin emit must end in a newline (a sealed block is a
  whole number of lines; a dangling partial line would silently
  under-count the high-water mark). Returns `:ok` or raises
  `ExUnit.AssertionError` naming the offending emit. T2b's suite calls
  this on every run.
  """
  @spec assert_seal_newline_terminated(CaptureAuthority.t()) :: :ok
  def assert_seal_newline_terminated(%CaptureAuthority{} = capture) do
    capture
    |> CaptureAuthority.log_by_origin(:seal)
    |> Enum.find(&(not String.ends_with?(&1.bytes, "\n")))
    |> case do
      nil ->
        :ok

      emit ->
        raise ExUnit.AssertionError,
          message:
            "seal-path emit ##{emit.seq} is not newline-terminated " <>
              "(#{inspect(emit.bytes)}) — every sealed block must be a " <>
              "whole number of lines or seal_high_water/1 under-counts"
    end
  end

  @doc "The first `region_top` on-screen rows (rows-of-`Cell`), 0-indexed from the top."
  @spec rows_above_footer(Emulator.t(), pos_integer()) :: [list()]
  def rows_above_footer(emulator, region_top) when is_integer(region_top) do
    emulator
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.take(region_top)
  end

  defp drop_trailing_blank_rows(rows) do
    rows
    |> Enum.reverse()
    |> Enum.drop_while(&blank_row?/1)
    |> Enum.reverse()
  end

  defp blank_row?(row) when is_list(row), do: Enum.all?(row, &blank_cell?/1)
  defp blank_row?(_row), do: false

  defp blank_cell?(%{char: char}), do: char in [" ", nil, ""]
  defp blank_cell?(_cell), do: false

  @doc """
  INV-1 (Seal-Once / Immutable-Prefix): `history_k` must be a
  byte-identical, in-order PREFIX of `history_final`. Returns `:ok`, or a
  `{:violation, ...}` tuple identifying the first divergence — this is the
  keystone assertion that catches footer bleed, stray CUP, `\\e[2J`, and
  resize re-wrap in one property (per `02-renderer.md` §2).
  """
  @spec immutable_prefix?(list(), list()) ::
          :ok
          | {:violation, :truncated, non_neg_integer(), non_neg_integer()}
          | {:violation, non_neg_integer(), term(), term()}
  def immutable_prefix?(history_k, history_final)
      when is_list(history_k) and is_list(history_final) do
    k_length = length(history_k)
    final_length = length(history_final)

    if final_length < k_length do
      {:violation, :truncated, k_length, final_length}
    else
      history_k
      |> Enum.zip(Enum.take(history_final, k_length))
      |> Enum.with_index()
      |> first_divergence()
    end
  end

  defp first_divergence(indexed_pairs) do
    indexed_pairs
    |> Enum.find(fn {{expected, actual}, _idx} -> expected != actual end)
    |> case do
      nil -> :ok
      {{expected, actual}, idx} -> {:violation, idx, expected, actual}
    end
  end
end
