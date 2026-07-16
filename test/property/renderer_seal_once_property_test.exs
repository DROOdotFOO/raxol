defmodule Raxol.Property.RendererSealOnceTest do
  @moduledoc """
  The append path's positive suite: the printed-history append path
  properties that belong to the APPEND path specifically — the footer
  viewport's own footer-side properties (the pinned-viewport repaint
  path) are that unit's own PR, not duplicated here.

  Unlike `test/harness/tb_oracle_test.exs` (which drives the
  `CaptureAuthority` test double), these properties drive the REAL
  production implementation,
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority`, through a
  `StringIO` device — the actual bytes the append path ships, replayed
  through the same `Raxol.Harness.Test.SealOracle` oracles (a mechanical
  scanner and a VT replay oracle) the byte-capture oracle suite already
  built.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  # Small, fixed geometry reused across this suite (matches
  # `tb_oracle_test.exs`'s convention): 10 rows total, footer 2 rows,
  # region_top = 8 (history rows 1..8, footer rows 9..10).
  @width 40
  @height 10
  @footer_rows 2
  @region_top 8

  # -- harness helpers --

  defp new_authority(opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, @width, @height, @footer_rows, opts)}
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp line_gen do
    string(:alphanumeric, min_length: 1, max_length: @width - 1)
  end

  # A "block" is 1-3 lines, each `\r\n`-terminated -- the newline discipline
  # `InlineAuthority.seal/2` requires (mirrors `assert_seal_newline_terminated/1`).
  defp block_gen do
    gen all(lines <- list_of(line_gen(), min_length: 1, max_length: 3)) do
      Enum.map_join(lines, "", &(&1 <> "\r\n"))
    end
  end

  defp blocks_gen(opts) do
    list_of(block_gen(), opts)
  end

  # ---------------------------------------------------------------------
  # Keystone: immutable-prefix seal-once
  # ---------------------------------------------------------------------

  describe "keystone: immutable-prefix" do
    test "streaming 1000 sealed single-line blocks: zero rewrites at constant width" do
      {device, authority} = new_authority()

      checkpoint_ks = [1, 8, 9, 50, 137, 274, 500, 999, 1000]

      {_final_authority, snapshots} =
        Enum.reduce(1..1000, {authority, %{}}, fn n, {auth, snaps} ->
          auth = InlineAuthority.seal(auth, "block #{n}\r\n")

          snaps =
            if n in checkpoint_ks,
              do: Map.put(snaps, n, raw(device)),
              else: snaps

          {auth, snaps}
        end)

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)
      assert hw_final == 1000

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      for k <- checkpoint_ks do
        raw_k = Map.fetch!(snapshots, k)
        hw_k = SealOracle.seal_high_water(raw_k)
        assert hw_k == k

        emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)

        history_k =
          SealOracle.history(emulator_k, @region_top, high_water: hw_k)

        assert :ok == SealOracle.immutable_prefix?(history_k, history_final),
               "history diverged at checkpoint k=#{k}"
      end
    end

    property "arbitrary block streams: every prefix checkpoint's history is an immutable prefix of the final history" do
      check all(
              blocks <- blocks_gen(min_length: 1, max_length: 60),
              max_runs: 25
            ) do
        {device, authority} = new_authority()

        {_final, snapshot_by_index} =
          Enum.reduce(Enum.with_index(blocks, 1), {authority, %{}}, fn {block,
                                                                        idx},
                                                                       {auth,
                                                                        snaps} ->
            auth = InlineAuthority.seal(auth, block)
            {auth, Map.put(snaps, idx, raw(device))}
          end)

        raw_final = raw(device)
        hw_final = SealOracle.seal_high_water(raw_final)

        emulator_final =
          SealOracle.replay(raw_final, width: @width, height: @height)

        history_final =
          SealOracle.history(emulator_final, @region_top, high_water: hw_final)

        for {idx, raw_k} <- snapshot_by_index do
          hw_k = SealOracle.seal_high_water(raw_k)
          emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)

          history_k =
            SealOracle.history(emulator_k, @region_top, high_water: hw_k)

          assert :ok == SealOracle.immutable_prefix?(history_k, history_final),
                 "history diverged after seal ##{idx}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # Footer-confinement + composition with the scroll-region manager
  # ---------------------------------------------------------------------

  describe "composition with the scroll-region manager: sealed lines land in history, never footer" do
    test "every seal-path CUP addresses a history row (fill-down, then the bottom row), never a footer row" do
      {device, authority} = new_authority()

      _ =
        Enum.reduce(1..20, authority, fn n, auth ->
          InlineAuthority.seal(auth, "block #{n}\r\n")
        end)

      rows = SealOracle.cup_rows(raw(device))

      # Every row this stream ever addresses (the DECSTBM homing from
      # `new/5`'s ScrollRegionManager.start, plus every append's CUP -- to
      # the next unfilled row while filling down, then to the bottom row
      # once full) is a HISTORY row, `1..region_top`.
      assert Enum.all?(rows, &(&1 in 1..@region_top))

      # Once the region fills (after 8 single-line seals), every further
      # append targets the bottom row exactly.
      assert @region_top in rows

      # Footer rows (9, 10) never appear -- the append path never bleeds
      # into the footer viewport's territory.
      refute (@region_top + 1) in rows
      refute @height in rows
    end

    test "footer rows stay blank -- the append path never writes on-screen footer content" do
      {device, authority} = new_authority()

      _ =
        Enum.reduce(1..3, authority, fn n, auth ->
          InlineAuthority.seal(auth, "block #{n}\r\n")
        end)

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)

      footer_rows =
        emulator
        |> Emulator.get_screen_buffer()
        |> Map.get(:cells)
        |> Enum.drop(@region_top)

      assert length(footer_rows) == @height - @region_top

      assert Enum.all?(footer_rows, fn row ->
               Enum.all?(row, fn cell ->
                 Map.get(cell, :char) in [" ", nil, ""]
               end)
             end)
    end
  end

  # ---------------------------------------------------------------------
  # No full clear, ever
  # ---------------------------------------------------------------------

  describe "no \\e[2J on the append path, with or without resize" do
    property "arbitrary seal/resize interleavings never emit a full-screen clear" do
      op_gen =
        gen all(
              kind <- member_of([:seal, :resize]),
              block <- block_gen(),
              new_height <- integer(6..40)
            ) do
          case kind do
            :seal -> {:seal, block}
            :resize -> {:resize, new_height}
          end
        end

      check all(
              ops <- list_of(op_gen, min_length: 1, max_length: 40),
              max_runs: 30
            ) do
        {device, authority} = new_authority()

        Enum.reduce(ops, authority, fn
          {:seal, block}, auth ->
            InlineAuthority.seal(auth, block)

          {:resize, new_height}, auth ->
            InlineAuthority.resize(auth, @width, new_height)
        end)

        refute SealOracle.emits_full_clear?(raw(device))
      end
    end
  end

  # ---------------------------------------------------------------------
  # Cursor-ownership round-trip
  # ---------------------------------------------------------------------

  describe "cursor-ownership round-trip (interleaved seals never corrupt cursor state)" do
    property "after any number of seal/2 calls, the cursor is back at its pre-bracket position every time, and save/restore never nests" do
      check all(
              blocks <- blocks_gen(min_length: 1, max_length: 30),
              max_runs: 30
            ) do
        {device, authority} = new_authority()

        # Baseline: cursor position implied by just the initial DECSTBM
        # region-set (home, by xterm's homing-on-DECSTBM semantics).
        baseline_cursor =
          device
          |> raw()
          |> SealOracle.replay(width: @width, height: @height)
          |> Emulator.get_cursor_position()

        Enum.reduce(blocks, authority, fn block, auth ->
          auth = InlineAuthority.seal(auth, block)

          cursor_now =
            device
            |> raw()
            |> SealOracle.replay(width: @width, height: @height)
            |> Emulator.get_cursor_position()

          assert cursor_now == baseline_cursor,
                 "cursor did not return to its pre-bracket position after a seal/2 call"

          auth
        end)

        balance = SealOracle.save_restore_balance(raw(device))
        assert balance.decsc == 0
        assert balance.decsc_max_depth <= 1
      end
    end
  end

  # ---------------------------------------------------------------------
  # Resize under seal-time-only policy
  # ---------------------------------------------------------------------

  describe "resize never re-emits sealed content; DECSTBM re-set exactly once" do
    test "seal, resize, seal again: history before resize is byte-unchanged; region re-set fires exactly once per resize" do
      {device, authority} = new_authority()

      authority = InlineAuthority.seal(authority, "before resize\r\n")
      raw_before_resize = raw(device)
      hw_before = SealOracle.seal_high_water(raw_before_resize)

      emulator_before =
        SealOracle.replay(raw_before_resize, width: @width, height: @height)

      history_before =
        SealOracle.history(emulator_before, @region_top, high_water: hw_before)

      new_height = 14
      authority = InlineAuthority.resize(authority, @width, new_height)
      new_region_top = InlineAuthority.region_top(authority)
      assert new_region_top == new_height - @footer_rows

      _authority = InlineAuthority.seal(authority, "after resize\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      # Replay the FULL final stream at the terminal's ACTUAL dimensions
      # after the resize (a real resize is an out-of-band terminal
      # dimension change no ANSI byte encodes -- DECSTBM only communicates
      # the new scroll-region boundary within whatever the current screen
      # size already is). Absolute CUP addressing is always relative to
      # row 1 (the top), so the earlier, pre-resize content still lands at
      # the same physical rows regardless of which height the replay uses.
      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: new_height)

      history_final =
        SealOracle.history(emulator_final, new_region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_before, history_final)

      assert SealOracle.region_sets(raw_final) == [
               {1, @region_top},
               {1, new_region_top}
             ]

      refute SealOracle.emits_full_clear?(raw_final)
    end
  end
end
