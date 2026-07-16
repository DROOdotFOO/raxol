defmodule Raxol.Terminal.ScrollRegionManagerTest do
  @moduledoc """
  `Raxol.Terminal.ScrollRegionManager` -- pure geometry + byte tests: no
  process beyond the struct itself, no pty, no termbox. Composition with the
  inline driver's teardown, the byte-capture oracle, and the `:pty`
  real-signal facts live in `test/harness/t2a_scroll_region_test.exs` (root
  project, where the oracle + `Raxol.Test.PtyHarness` are reachable).

  `async: true`: this module keeps no global/process state (`device` is a
  plain parameter, the output-device seam).
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.ScrollRegionManager, as: SRM

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  describe "history_bottom/2 -- pure geometry" do
    test "H - N for the ordinary case" do
      assert SRM.history_bottom(30, 3) == 27
    end

    test "clamps to 1 when footer_rows >= rows (degenerate terminal)" do
      assert SRM.history_bottom(5, 5) == 1
      assert SRM.history_bottom(5, 10) == 1
    end

    test "footer_rows: 0 -- history region is the whole screen" do
      assert SRM.history_bottom(24, 0) == 24
    end
  end

  describe "region_set_bytes/2" do
    test "CSI 1;(H-N) r, 1-based" do
      assert SRM.region_set_bytes(30, 3) == "\e[1;27r"
    end

    test "matches Raxol.UI.Rendering.PaintAuthority.Dialect.region_set/2's format exactly" do
      # Pinned literally (not by aliasing -- raxol_terminal must not depend
      # on main raxol's lib/raxol/ui/, see the moduledoc's package-boundary
      # note) so a future drift in either byte builder is caught here.
      # Only valid for NON-degenerate splits: Dialect.region_set/2 has no
      # concept of the degenerate-terminal policy below, so the two
      # diverge by design once `degenerate?/2` is true (see the
      # "degenerate case" test group).
      assert SRM.region_set_bytes(80, 5) == "\e[1;75r"
      assert SRM.region_set_bytes(24, 1) == "\e[1;23r"
    end
  end

  describe "degenerate?/2 -- pure geometry" do
    test "false for an ordinary split (history_bottom >= 2)" do
      refute SRM.degenerate?(30, 3)
      refute SRM.degenerate?(24, 1)
      # The exact boundary: history_bottom == 2 is the smallest VALID region
      # (top=1, bottom=2, top < bottom holds).
      refute SRM.degenerate?(5, 3)
    end

    test "true when history_bottom would be < 2 (a top == bottom DECSTBM the terminal would ignore)" do
      assert SRM.degenerate?(2, 2)
      assert SRM.degenerate?(3, 2)
      assert SRM.degenerate?(5, 4)
      assert SRM.degenerate?(1, 0)
    end
  end

  describe "region_set_bytes/2 -- degenerate case (tiny terminals)" do
    # Each of these has history_bottom(rows, footer_rows) < 2 -- a terminal too
    # short for its footer plus a 1-row history minimum. The historical bug
    # (see the false-confidence-flip test below) emitted a lying
    # `CSI 1;1 r` here; a real terminal ignores a `top == bottom` DECSTBM
    # outright, silently leaving whatever region was previously active
    # untouched while the caller believed the footer was pinned.
    for {rows, footer_rows} <- [{2, 2}, {3, 2}, {5, 4}, {1, 0}] do
      test "rows=#{rows} footer_rows=#{footer_rows}: emits the full-screen release, not a lying 1;1r" do
        rows = unquote(rows)
        footer_rows = unquote(footer_rows)

        assert SRM.degenerate?(rows, footer_rows)
        assert SRM.region_set_bytes(rows, footer_rows) == "\e[r"
        refute SRM.region_set_bytes(rows, footer_rows) == "\e[1;1r"
      end
    end
  end

  describe "start/3 -- orientation FAIL-FIRST ANCHOR" do
    test "history region is the TOP rows, footer is the BOTTOM rows OUTSIDE it" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 30, 3)

      # Orientation guard: region = TOP rows (history, scrolling), footer =
      # BOTTOM rows outside it. Swapping `history_bottom/2`'s formula to
      # `footer_rows` instead of `rows - footer_rows` would flip these two
      # assertions, so this pins the correct orientation against that error.
      assert SRM.history_range(state) == 1..27
      assert SRM.footer_range(state) == 28..30

      # History (top) must never overlap footer (bottom).
      history = MapSet.new(SRM.history_range(state))
      footer = MapSet.new(SRM.footer_range(state))
      assert MapSet.disjoint?(history, footer)

      # Footer is strictly the tail: every footer row > every history row.
      assert Enum.max(SRM.history_range(state)) <
               Enum.min(SRM.footer_range(state))

      # Together they cover the whole screen with no gap.
      assert Enum.min(SRM.history_range(state)) == 1
      assert Enum.max(SRM.footer_range(state)) == 30

      assert contents(sio) == "\e[1;27r"
    end

    test "emits the DECSTBM region-set bytes exactly once" do
      {:ok, sio} = StringIO.open("")
      _state = SRM.start(sio, 24, 1)

      assert contents(sio) == "\e[1;23r"
    end

    test "accessors reflect the started geometry" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 40, 4)

      assert SRM.rows(state) == 40
      assert SRM.footer_rows(state) == 4
      assert SRM.history_bottom(state) == 36
      refute SRM.degenerate?(state)
    end
  end

  describe "start/3 -- degenerate case (tiny terminals)" do
    for {rows, footer_rows} <- [{2, 2}, {3, 2}, {5, 4}, {1, 0}] do
      test "rows=#{rows} footer_rows=#{footer_rows}: degenerate? is true, bytes are the full-screen release" do
        rows = unquote(rows)
        footer_rows = unquote(footer_rows)

        {:ok, sio} = StringIO.open("")
        state = SRM.start(sio, rows, footer_rows)

        assert SRM.degenerate?(state)
        assert contents(sio) == "\e[r"
        # history_bottom/1 still returns a sane (>= 1) row for append-path
        # math even though the pin itself is not active.
        assert SRM.history_bottom(state) >= 1
      end
    end
  end

  describe "resize/2" do
    test "recomputes history_bottom keeping footer_rows constant" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      assert SRM.history_bottom(state) == 22

      state = SRM.resize(state, 40)
      assert SRM.footer_rows(state) == 2
      assert SRM.history_bottom(state) == 38
      assert SRM.rows(state) == 40
    end

    test "re-emits DECSTBM exactly once per resize, appended after the start bytes" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      _state = SRM.resize(state, 40)

      assert contents(sio) == "\e[1;22r" <> "\e[1;38r"
    end

    test "never writes a full-screen clear on resize" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 80, 5)
      _state = SRM.resize(state, 24)

      refute contents(sio) =~ "\e[2J"
      refute contents(sio) =~ "\e[3J"
      refute contents(sio) =~ "\e[H\e[2J"
    end

    test "shrinking below footer_rows clamps history_bottom to 1, never 0 or negative -- and never lies with a 1;1r DECSTBM" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 3)
      state = SRM.resize(state, 2)

      assert SRM.history_bottom(state) == 1

      # This is the FLIPPED false-confidence assertion: the old test here
      # asserted `contents(sio) =~ "\e[1;1r"` as SUCCESS. That was a false
      # positive -- a real terminal (xterm/wezterm/kitty) IGNORES a
      # `top == bottom` DECSTBM outright, so a `1;1r` byte on the wire
      # would silently fail to pin anything while the caller believed it
      # had. `resize/2` now emits the honest full-screen release instead,
      # and the manager records `degenerate?: true` so callers can detect
      # the condition (see the moduledoc's "Degenerate terminals" section).
      refute contents(sio) =~ "\e[1;1r"
      assert SRM.degenerate?(state)
      assert contents(sio) == "\e[1;21r" <> "\e[r"
    end

    test "geometry-gated emission: a width-only resize (rows unchanged) writes ZERO bytes" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      before_bytes = contents(sio)

      after_state = SRM.resize(state, 24)

      refute SRM.geometry_changed?(state, after_state)
      # No second DECSTBM, no bytes at all: DECSTBM homes the cursor as a
      # side effect, so re-emitting an unchanged region on a width-only
      # resize would move the cursor for zero geometric benefit.
      assert contents(sio) == before_bytes
    end

    test "geometry-gated emission: a height-changing resize still emits exactly once" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      after_state = SRM.resize(state, 40)

      assert SRM.geometry_changed?(state, after_state)
      assert contents(sio) == "\e[1;22r" <> "\e[1;38r"
    end

    test "resizing INTO a degenerate split releases the previously-active real region" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 3)
      refute SRM.degenerate?(state)

      state = SRM.resize(state, 4)

      assert SRM.degenerate?(state)
      assert contents(sio) == "\e[1;21r" <> "\e[r"
    end

    test "resizing OUT of a degenerate split emits a real DECSTBM" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 4, 3)
      assert SRM.degenerate?(state)
      assert contents(sio) == "\e[r"

      state = SRM.resize(state, 24)

      refute SRM.degenerate?(state)
      assert contents(sio) == "\e[r" <> "\e[1;21r"
    end

    test "footer stays outside the region across a whole resize sequence" do
      {:ok, sio} = StringIO.open("")

      final =
        Enum.reduce([24, 80, 30, 6, 120], SRM.start(sio, 24, 3), fn rows,
                                                                    state ->
          state =
            if SRM.rows(state) == rows, do: state, else: SRM.resize(state, rows)

          history = MapSet.new(SRM.history_range(state))
          footer = MapSet.new(SRM.footer_range(state))
          assert MapSet.disjoint?(history, footer)
          state
        end)

      assert SRM.footer_rows(final) == 3
    end
  end

  describe "geometry_changed?/2 -- the (B)-upgrade seam" do
    test "false when history_bottom is unchanged (e.g. a width-only resize)" do
      {:ok, sio} = StringIO.open("")
      before_state = SRM.start(sio, 24, 3)
      after_state = %{before_state | rows: 24}

      refute SRM.geometry_changed?(before_state, after_state)
    end

    test "true when a resize actually moves the history/footer split" do
      {:ok, sio} = StringIO.open("")
      before_state = SRM.start(sio, 24, 3)
      after_state = SRM.resize(before_state, 40)

      assert SRM.geometry_changed?(before_state, after_state)
    end
  end

  describe "interleaved resizes never let the footer bleed into the region (example-based)" do
    # The full StreamData property (`raxol_terminal` has no stream_data test
    # dep; the property lives in test/harness/t2a_scroll_region_test.exs at
    # the root project, alongside the byte-capture oracle) is mirrored here as a fixed
    # table of resize sequences so the package's own test suite still pins
    # the invariant without a new dependency.
    for {footer_rows, initial_rows, resizes} <- [
          {3, 24, [80, 30, 6, 120, 1, 300]},
          {0, 10, [1, 50]},
          {10, 5, [5, 40, 3]},
          {1, 200, [2, 2, 2, 300, 1]}
        ] do
      test "footer_rows=#{footer_rows} initial=#{initial_rows} resizes=#{inspect(resizes)}" do
        footer_rows = unquote(footer_rows)
        initial_rows = unquote(initial_rows)
        resizes = unquote(resizes)

        {:ok, sio} = StringIO.open("")
        state = SRM.start(sio, initial_rows, footer_rows)
        assert_region_invariant(state)

        final =
          Enum.reduce(resizes, state, fn rows, acc ->
            acc = SRM.resize(acc, rows)
            assert_region_invariant(acc)
            acc
          end)

        # footer_rows is an invariant of the manager, never mutated by resize.
        assert SRM.footer_rows(final) == footer_rows
      end
    end

    defp assert_region_invariant(state) do
      history = MapSet.new(SRM.history_range(state))
      footer = MapSet.new(SRM.footer_range(state))

      assert MapSet.disjoint?(history, footer)
      assert Enum.min(SRM.history_range(state)) == 1
      assert Enum.max(SRM.history_range(state)) <= SRM.rows(state)

      # On a degenerate terminal (rows <= footer_rows), history_bottom/2's
      # clamp gives history its minimum 1 row first, which can leave NO
      # rows for the footer at all -- an empty footer_range is then the
      # CORRECT outcome (not a violation): there is nowhere left to put it.
      unless Enum.empty?(footer) do
        assert Enum.max(footer) == SRM.rows(state)
        assert Enum.max(SRM.history_range(state)) < Enum.min(footer)
      end
    end
  end
end
