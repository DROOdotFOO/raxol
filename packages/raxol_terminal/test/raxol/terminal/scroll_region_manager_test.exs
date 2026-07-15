defmodule Raxol.Terminal.ScrollRegionManagerTest do
  @moduledoc """
  Unit T2a (`Raxol.Terminal.ScrollRegionManager`) -- pure geometry + byte
  tests, Tier A of `harness-ui-testing/02-renderer.md` /
  `harness-ui-testing/03-lifecycle.md`: no process beyond the struct
  itself, no pty, no termbox. Harness-level composition with T2d's
  teardown, the TB byte-capture oracle, and the `:pty` real-signal facts
  live in `test/harness/t2a_scroll_region_test.exs` (root project, where
  the TB oracle + `Raxol.Test.PtyHarness` are reachable).

  `async: true`: this module keeps no global/process state (`device` is a
  plain parameter, per the suite design's output-device seam requirement).
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.ScrollRegionManager, as: SRM

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  describe "region_top/2 -- pure geometry" do
    test "H - N for the ordinary case" do
      assert SRM.region_top(30, 3) == 27
    end

    test "clamps to 1 when footer_rows >= rows (degenerate terminal)" do
      assert SRM.region_top(5, 5) == 1
      assert SRM.region_top(5, 10) == 1
    end

    test "footer_rows: 0 -- history region is the whole screen" do
      assert SRM.region_top(24, 0) == 24
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
      assert SRM.region_set_bytes(80, 5) == "\e[1;75r"
      assert SRM.region_set_bytes(24, 1) == "\e[1;23r"
    end
  end

  describe "start/3 -- orientation FAIL-FIRST ANCHOR" do
    test "history region is the TOP rows, footer is the BOTTOM rows OUTSIDE it" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 30, 3)

      # This is the exact orientation v1 of the roadmap had backwards
      # (roadmap: "region = rows 1..H-N (history, scrolling); footer
      # outside — v1 had the orientation backwards"). Swapping
      # `region_top/2`'s formula to `footer_rows` instead of
      # `rows - footer_rows` (the historical bug) flips these two
      # assertions to fail -- demonstrated red during development by
      # temporarily inverting the implementation and confirming both
      # ranges below come out swapped.
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
      assert SRM.region_top(state) == 36
    end
  end

  describe "resize/2" do
    test "recomputes region_top keeping footer_rows constant" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      assert SRM.region_top(state) == 22

      state = SRM.resize(state, 40)
      assert SRM.footer_rows(state) == 2
      assert SRM.region_top(state) == 38
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

    test "shrinking below footer_rows clamps region_top to 1, never 0 or negative" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 3)
      state = SRM.resize(state, 2)

      assert SRM.region_top(state) == 1
      assert contents(sio) =~ "\e[1;1r"
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
    test "false when region_top is unchanged (e.g. a width-only resize)" do
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
    # the root project, alongside the TB oracle) is mirrored here as a fixed
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

      # On a degenerate terminal (rows <= footer_rows), region_top/2's
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
