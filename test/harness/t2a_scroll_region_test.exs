defmodule Raxol.Harness.T2aScrollRegionTest do
  @moduledoc """
  Scroll-region manager (`Raxol.Terminal.ScrollRegionManager`) --
  harness-level suite. Pure package-local geometry/byte tests live in
  `packages/raxol_terminal/test/raxol/terminal/scroll_region_manager_test.exs`;
  this file covers what only the root project can: assertions against the
  byte-capture oracle (`Raxol.Harness.Test.SealOracle`,
  `Raxol.UI.Rendering.PaintAuthority.Dialect`), composition with the inline
  driver's teardown (`Raxol.Terminal.InlineDriver`), a full StreamData
  property (`raxol_terminal` carries no `stream_data` test dep), and the
  `:pty` real-signal facts (`Raxol.Test.PtyHarness`).

  Orientation: scroll region = TOP rows `1..(H-N)` (history, scrolling);
  footer = rows `(H-N+1)..H`, OUTSIDE the region, pinned. The inline
  driver's `InlineDriver.Sequences.teardown_bytes/1` already emits `CSI r`
  (bare release) unconditionally and idempotently; this module's job is only
  ever to SET a real region (`start/3`, `resize/2`) -- release composes for
  free, tested here at the byte level and, for the real-signal facts, under
  an actual pty.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.InlineDriver
  alias Raxol.Terminal.ScrollRegionManager, as: SRM
  alias Raxol.Test.PtyHarness
  alias Raxol.UI.Rendering.PaintAuthority.Dialect

  @moduletag :harness

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  describe "byte format matches the TB Dialect exactly (package-boundary pin)" do
    test "SRM.region_set_bytes/2 == Dialect.region_set(1, history_bottom), for NON-degenerate splits" do
      # {6, 10} deliberately dropped from this table: it is a degenerate
      # split (history_bottom(6, 10) == 1 < 2), and the byte-identical claim
      # here only holds for non-degenerate geometry. `Dialect.region_set/2`
      # (IOAuthority's legacy-profile byte builder, see the moduledoc's
      # "Emission ownership" section) has no concept of the
      # degenerate-terminal policy -- it always emits the literal
      # `CSI top;bottom r`, even a lying `1;1r` a real terminal would
      # ignore. SRM's `region_set_bytes/2` diverges from it there BY
      # DESIGN (see the next test).
      for {rows, footer_rows} <- [{24, 1}, {80, 5}, {30, 3}] do
        top = SRM.history_bottom(rows, footer_rows)
        refute SRM.degenerate?(rows, footer_rows)

        assert SRM.region_set_bytes(rows, footer_rows) ==
                 Dialect.region_set(1, top)
      end
    end

    test "diverges from Dialect.region_set/2 for a degenerate split -- by design" do
      # {6, 10}: history_bottom(6, 10) == 1, degenerate. Dialect.region_set/2
      # blindly emits the wire format it's told to (`CSI 1;1 r`); SRM
      # knows a real terminal ignores that and emits the honest
      # full-screen release instead. This divergence is the fix, not a
      # regression -- see the moduledoc's "Degenerate terminals" section.
      rows = 6
      footer_rows = 10
      top = SRM.history_bottom(rows, footer_rows)
      assert SRM.degenerate?(rows, footer_rows)

      assert Dialect.region_set(1, top) == "\e[1;1r"
      assert SRM.region_set_bytes(rows, footer_rows) == "\e[r"
    end
  end

  describe "start/3 -- ORIENTATION FAIL-FIRST ANCHOR, via the byte-capture oracle" do
    test "SealOracle parses the region as {1, H-N}; footer rows fall strictly outside it" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 30, 3)
      raw = contents(sio)

      # The anchor: if `history_bottom/2`'s formula were inverted
      # (footer_rows used where H-N belongs), this would parse as {1, 3}
      # instead of {1, 27} and every assertion below flips.
      assert SealOracle.scroll_region(raw) == {1, 27}
      assert SealOracle.region_sets(raw) == [{1, 27}]

      footer = SRM.footer_range(state)
      {_top, bottom} = SealOracle.scroll_region(raw)
      assert Enum.min(footer) > bottom
      assert Enum.max(footer) == 30
    end

    test "region_sets/1 sees exactly one DECSTBM set for a single start/3 call" do
      {:ok, sio} = StringIO.open("")
      _state = SRM.start(sio, 24, 2)

      assert SealOracle.region_sets(contents(sio)) == [{1, 22}]
    end

    test "never emits a full-screen clear" do
      {:ok, sio} = StringIO.open("")
      _state = SRM.start(sio, 24, 2)

      refute SealOracle.emits_full_clear?(contents(sio))
    end
  end

  describe "resize/2 -- correct bounds via the byte-capture oracle" do
    test "exactly one region re-set per resize, correct bounds, no full clear" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 2)
      _state = SRM.resize(state, 40)

      raw = contents(sio)
      assert SealOracle.region_sets(raw) == [{1, 22}, {1, 38}]
      refute SealOracle.emits_full_clear?(raw)
    end

    test "a width-only resize (rows unchanged) is geometry-gated: zero bytes, no redundant DECSTBM" do
      {:ok, sio} = StringIO.open("")
      before_state = SRM.start(sio, 24, 2)
      after_state = SRM.resize(before_state, 24)

      refute SRM.geometry_changed?(before_state, after_state)

      # FLIPPED from the old assertion `[{1, 22}, {1, 22}]`: re-emitting an
      # identical DECSTBM on a width-only resize was pure waste with a
      # real side effect -- DECSTBM homes the cursor (VT100) -- for zero
      # geometric benefit. `resize/2` now skips the write entirely when
      # `history_bottom` is unchanged, so the oracle sees only the original
      # start/3 region-set, never a second one.
      assert SealOracle.region_sets(contents(sio)) == [{1, 22}]
    end
  end

  describe "composition with the inline driver's teardown (byte-capture, StringIO, no pty)" do
    # Mirrors packages/raxol_terminal/test/raxol/terminal/inline_driver_test.exs's
    # "terminate/2 emits full teardown regardless of reason" --
    # driving InlineDriver.terminate/2 directly with a crash-shaped reason,
    # on the SAME device the region manager already wrote its region-set
    # bytes to, proves the two compose across the trapped-crash path without
    # any new wiring: the inline driver's bare `CSI r` release, unmodified,
    # meaningfully resets the REAL region the manager set.
    test "clean/trapped-crash: SET (region manager) precedes RELEASE (inline driver), no double-emission, no full clear" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 30, 2)

      driver_state = %InlineDriver.State{
        device: sio,
        rows: 30,
        stty_enabled?: false
      }

      assert :ok =
               InlineDriver.terminate(
                 %RuntimeError{message: "boom"},
                 driver_state
               )

      raw = contents(sio)

      # SET appears exactly once, from the region manager; the inline driver
      # never emits a SET, only the bare release -- so the oracle's
      # region-sets list stays a single entry even after a full teardown.
      assert SealOracle.region_sets(raw) == [{1, SRM.history_bottom(state)}]

      {set_idx, _} = :binary.match(raw, SRM.region_set_bytes(30, 2))
      {release_idx, _} = :binary.match(raw, "\e[r")
      assert set_idx < release_idx

      refute SealOracle.emits_full_clear?(raw)

      # The teardown's final absolute move (`CSI 30;1 H`) addresses the
      # real bottom row, which is INSIDE the region this module set (1..28,
      # footer rows 29-30 excluded) -- proving the release truly preceded the
      # move byte-for-byte: had the order been reversed, a real terminal would
      # clamp this move inside the still-active 1..28 region instead of
      # landing on row 30.
      {move_idx, _} = :binary.match(raw, "\e[30;1H")
      assert release_idx < move_idx
    end

    test "composing with the inline driver's idempotent emit_teardown/2 seam never double-releases" do
      {:ok, sio} = StringIO.open("")
      state = SRM.start(sio, 24, 1)

      driver_state = %InlineDriver.State{
        device: sio,
        rows: 24,
        stty_enabled?: false
      }

      driver_state = InlineDriver.emit_teardown(sio, driver_state)
      assert driver_state.torn_down? == true

      # Second call, state properly threaded (the documented contract:
      # emit_teardown/2 is idempotent when the CALLER threads torn_down?
      # back in -- see the module's own moduledoc on why raw terminate/2
      # is not re-entrant the same way).
      _driver_state = InlineDriver.emit_teardown(sio, driver_state)

      raw = contents(sio)
      # Exactly one release token, and the region manager's SET is still
      # exactly one entry -- the inline driver's idempotency guard, unmodified,
      # absorbs the second call cleanly regardless of what the manager wrote first.
      assert length(:binary.matches(raw, "\e[r")) == 1
      assert SealOracle.region_sets(raw) == [{1, SRM.history_bottom(state)}]
    end
  end

  describe "property: any resize sequence keeps the footer outside the region (StreamData)" do
    property "history/footer stay disjoint, correctly ordered, and every DECSTBM set is exact" do
      check all(
              footer_rows <- integer(0..15),
              initial_rows <- integer(1..300),
              resizes <- list_of(integer(1..300), max_length: 25),
              max_runs: 200
            ) do
        {:ok, sio} = StringIO.open("")
        state = SRM.start(sio, initial_rows, footer_rows)

        # footer_rows never changes across resize, so the expected DECSTBM
        # sequence is derived from history_bottom/2 applied to each rows value
        # in turn -- independently derived from the pure geometry
        # function, not by re-walking SRM's own stateful resize/2 (which
        # would make this property tautological). Two adjustments versus
        # the naive "one entry per call" version, mirroring resize/2's own
        # rules (both stated declaratively here from the pure primitives,
        # not by calling resize/2):
        #
        #   1. Adjacent dedup: start/3 always attempts an emit, but each
        #      resize/2 call only emits when its history_bottom DIFFERS from
        #      the PREVIOUS state's history_bottom (the geometry gate --
        #      "Geometry-gated resize emission" in the moduledoc). A
        #      resize to the same rows (or a different rows value that
        #      happens to produce the same history_bottom) contributes no
        #      entry.
        #   2. Degenerate exclusion: an emit whose TARGET geometry is
        #      degenerate writes a full-screen release, not a `{1, top}`
        #      DECSTBM -- the oracle's region_sets/1 does not parse a bare
        #      release as a region set (same as it already does for the
        #      inline driver's teardown release), so a degenerate emit contributes no
        #      entry either, even though real bytes were written.
        initial_top = SRM.history_bottom(initial_rows, footer_rows)

        {reversed_resize_entries, _final_top} =
          Enum.reduce(resizes, {[], initial_top}, fn rows, {acc, prev_top} ->
            new_top = SRM.history_bottom(rows, footer_rows)

            acc =
              cond do
                new_top == prev_top -> acc
                SRM.degenerate?(rows, footer_rows) -> acc
                true -> [{1, new_top} | acc]
              end

            {acc, new_top}
          end)

        resize_entries = Enum.reverse(reversed_resize_entries)

        expected_sets =
          if SRM.degenerate?(initial_rows, footer_rows) do
            resize_entries
          else
            [{1, initial_top} | resize_entries]
          end

        final =
          Enum.reduce(resizes, state, fn rows, acc -> SRM.resize(acc, rows) end)

        raw = contents(sio)
        refute SealOracle.emits_full_clear?(raw)
        assert SealOracle.region_sets(raw) == expected_sets

        history = MapSet.new(SRM.history_range(final))
        footer = MapSet.new(SRM.footer_range(final))
        assert MapSet.disjoint?(history, footer)
        assert SRM.footer_rows(final) == footer_rows
      end
    end
  end

  # --- Real pty, real signals (this module's own scope) ---

  @footer_rows 2
  @rows 24

  @mock_app_src """
  defmodule T2aPtyMockApp do
    use Raxol.Core.Runtime.Application
    def init(_ctx), do: %{}
    def update(_message, model), do: {model, []}
    def view(_model), do: nil
    def subscribe(_model), do: []
  end

  defmodule T2aPtySigtermHandler do
    @behaviour :gen_event
    def init(%{lifecycle: lifecycle}), do: {:ok, %{lifecycle: lifecycle}}

    def handle_event(:sigterm, %{lifecycle: lifecycle} = state) do
      case :sys.get_state(lifecycle).driver_pid do
        driver_pid when is_pid(driver_pid) -> GenServer.stop(driver_pid, :normal)
        _ -> :ok
      end

      System.stop(0)
      {:ok, state}
    end

    def handle_event(_signal, state), do: {:ok, state}
    def handle_call(_request, state), do: {:ok, :ok, state}
  end

  {:ok, pid} =
    Raxol.start_link(T2aPtyMockApp,
      environment: :inline,
      probe?: false,
      rows: #{@rows}
    )

  # This module's own contribution: set a REAL scroll region on the same tty
  # the driver just claimed, straight to :stdio -- exactly how a future
  # append-path integration would call this module, without touching
  # inline_driver.ex.
  _srm = Raxol.Terminal.ScrollRegionManager.start(:stdio, #{@rows}, #{@footer_rows})

  :ok = :os.set_signal(:sigterm, :handle)

  :ok =
    :gen_event.add_handler(
      :erl_signal_server,
      {T2aPtySigtermHandler, pid},
      %{lifecycle: pid}
    )

  IO.puts("READY")
  Process.sleep(:infinity)
  """

  setup_all do
    if PtyHarness.available?() do
      :ok
    else
      {:skip, "python3 not found on PATH"}
    end
  end

  defp start_mock_app_under_pty do
    PtyHarness.start(["mix", "run", "--no-halt", "-e", @mock_app_src],
      env: %{"MIX_ENV" => "test"}
    )
  end

  defp cleanup(session) do
    PtyHarness.stop(session)
    File.rm(session.capture_path)
  end

  describe "real pty: SIGTERM composed with a real region set" do
    @describetag :pty
    @describetag :unix_only
    @describetag :skip_on_ci

    test "a real SIGTERM: the region set precedes the inline driver's release, no full clear, region set exactly once" do
      {:ok, session} = start_mock_app_under_pty()
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 15_000)
      assert :ok = PtyHarness.signal(session, :term)
      assert {:ok, {:exit, 0}} = PtyHarness.await(session, 15_000)

      {:ok, output} = PtyHarness.read_output(session)

      expected_top = SRM.history_bottom(@rows, @footer_rows)
      assert SealOracle.region_sets(output) == [{1, expected_top}]
      refute SealOracle.emits_full_clear?(output)

      {set_idx, _} =
        :binary.match(output, SRM.region_set_bytes(@rows, @footer_rows))

      {release_idx, _} = :binary.match(output, "\e[r")
      assert set_idx < release_idx
    end
  end

  describe "real pty: kill -9 residual, scoped to the region set" do
    @describetag :pty
    @describetag :unix_only
    @describetag :skip_on_ci

    test "kill -9 leaves a REAL region set (not default) with no release -- the documented residual" do
      {:ok, session} = start_mock_app_under_pty()
      on_exit(fn -> cleanup(session) end)

      assert :ok = PtyHarness.await_capture(session, "READY", 15_000)
      assert :ok = PtyHarness.signal(session, :kill)
      assert {:ok, {:signaled, 9}} = PtyHarness.await(session, 15_000)

      {:ok, output} = PtyHarness.read_output(session)

      expected_top = SRM.history_bottom(@rows, @footer_rows)
      # The region set is a tested, real fact (not the terminal's
      # already-default state) -- the residual is that it never gets
      # released, because no process survived to run either module's
      # teardown. Scroll-region state has no kernel representation (unlike
      # raw mode's -icanon/-echo, which `stty -a` can show), so the
      # documented recovery for THIS residual is the same byte-level
      # one-liner the inline driver already proves generically
      # (`test/harness/t2d_teardown_negative_test.exs`,
      # "residual-while-hung (SIGSTOP) + the documented recovery
      # one-liner") -- not re-demonstrated here to avoid duplicating that
      # pty-heavy test for a fact that isn't region-specific.
      assert SealOracle.region_sets(output) == [{1, expected_top}]
      refute output =~ "\e[r"
    end
  end
end
