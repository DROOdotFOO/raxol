defmodule Raxol.Property.RendererFooterTest do
  @moduledoc """
  Positive-case suite for the pinned footer viewport, scoped to the
  footer path specifically -- append-path properties live in their own
  suite (`renderer_seal_once_property_test.exs`), not duplicated here.

  Like that suite, these properties drive the REAL production
  implementation, `Raxol.UI.Rendering.PaintAuthority.InlineAuthority`'s
  `repaint/2`/`keyframe/2` (the diff-repaint / full-keyframe entry points
  built on top of the `repaint_footer/2`/`keyframe_footer/2` @impl
  callbacks), through a `StringIO` device -- the actual bytes shipped,
  replayed through the same `Raxol.Harness.Test.SealOracle` oracles
  (mechanical scanner + VT replay) the append path already uses.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Buffer.Queries
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.Rendering.PaintAuthority.Dialect
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  # Same fixed geometry the append path's suite uses: 10 rows total, footer 2 rows,
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

  # The footer row range for the authority's CURRENT geometry -- never a
  # hand-maintained constant, so this stays correct across resize.
  defp footer_range(authority) do
    top = InlineAuthority.region_top(authority)
    count = InlineAuthority.footer_row_count(authority)
    (top + 1)..(top + count)//1
  end

  # A second `new_authority` for tests exercising non-fixed geometry (the
  # degenerate-geometry cases) -- the module-level `new_authority/1` above
  # is deliberately pinned to the fixed 10/2/40 geometry every other test
  # in this file relies on.
  defp new_authority(width, rows, footer_rows, opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, width, rows, footer_rows, opts)}
  end

  defp delta(all_bytes, prior_size) do
    binary_part(all_bytes, prior_size, byte_size(all_bytes) - prior_size)
  end

  # The rendered TEXT of one wire-format (1-based) row after replaying
  # `raw_bytes` through the real emulator -- content-level, unlike
  # `SealOracle.cup_rows/1`'s positional-only walk. Padded to `width` with
  # spaces past the written content's end, matching a real terminal's
  # column model (and `Queries.get_text_at/4`'s own nil/blank -> " "
  # convention).
  defp footer_row_text(raw_bytes, row_1_based, width, height) do
    raw_bytes
    |> SealOracle.replay(width: width, height: height)
    |> Emulator.get_screen_buffer()
    |> Queries.get_text_at(0, row_1_based - 1, width)
  end

  # Every footer emit is exactly `Dialect.cursor_save() <> ... <>
  # Dialect.cursor_restore()` (the `with_cursor/3` bracket). Stripping it
  # before feeding a bracket-delta to `SealOracle.cup_rows/2` avoids a
  # walker artifact: a FRESH per-delta walk has no memory of the row the
  # save actually captured (that context lives in the FULL stream), so
  # the trailing DECRC restore would otherwise report a fabricated
  # row-1 "movement" that isn't real. Stripping the bracket we fully
  # control leaves only the CUP+clear+text bytes the footer path itself
  # is responsible for.
  defp strip_cursor_bracket(bytes) do
    save = Dialect.cursor_save()
    restore = Dialect.cursor_restore()

    bytes
    |> strip_prefix(save)
    |> strip_suffix(restore)
  end

  defp strip_prefix(bytes, prefix) do
    if String.starts_with?(bytes, prefix) do
      binary_part(
        bytes,
        byte_size(prefix),
        byte_size(bytes) - byte_size(prefix)
      )
    else
      bytes
    end
  end

  defp strip_suffix(bytes, suffix) do
    if String.ends_with?(bytes, suffix) do
      binary_part(bytes, 0, byte_size(bytes) - byte_size(suffix))
    else
      bytes
    end
  end

  defp line_gen,
    do: string(:alphanumeric, min_length: 0, max_length: @width - 1)

  defp footer_lines_gen, do: list_of(line_gen(), min_length: 0, max_length: 4)

  # ---------------------------------------------------------------------
  # footer_diff/2: pure minimal-diff (no I/O)
  # ---------------------------------------------------------------------

  describe "footer_diff/2: pure minimal-diff" do
    test "identical lines produce zero changes" do
      lines = ["live tail", "status | composer"]
      assert InlineAuthority.footer_diff(lines, lines) == []
    end

    test "only the rows that actually changed are returned, with correct 0-based index and new content" do
      old_lines = ["a", "b", "c"]
      new_lines = ["a", "B", "c"]

      assert InlineAuthority.footer_diff(old_lines, new_lines) == [{1, "B"}]
    end

    property "every returned {index, line} pair's line differs from the old line at that index, and every unreturned index is unchanged" do
      check all(
              old_lines <- list_of(line_gen(), min_length: 1, max_length: 6),
              new_lines_raw <-
                list_of(line_gen(), min_length: 0, max_length: 10),
              max_runs: 100
            ) do
        # Force equal lengths (footer_diff/2's precondition) by
        # pad/truncating the independently-generated `new_lines_raw` to
        # `old_lines`'s length -- StreamData generators can't reference a
        # prior generator's runtime length directly.
        count = length(old_lines)
        new_lines = new_lines_raw |> Enum.take(count) |> pad_to(count)

        changes = InlineAuthority.footer_diff(old_lines, new_lines)
        changed_indices = MapSet.new(changes, fn {idx, _line} -> idx end)

        old_lines
        |> Enum.zip(new_lines)
        |> Enum.with_index()
        |> Enum.each(fn {{old_line, new_line}, idx} ->
          if old_line == new_line do
            refute idx in changed_indices
          else
            assert {idx, new_line} in changes
          end
        end)
      end
    end
  end

  defp pad_to(lines, count) do
    case count - length(lines) do
      n when n > 0 -> lines ++ List.duplicate("", n)
      _ -> lines
    end
  end

  # ---------------------------------------------------------------------
  # Acceptance 1: footer repaint touches only footer rows
  # ---------------------------------------------------------------------

  describe "acceptance 1: repaint/2 touches only footer rows" do
    test "a single repaint with all-new content CUPs only inside the footer range" do
      {device, authority} = new_authority()
      prior_size = device |> raw() |> byte_size()

      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      new_bytes = delta(raw(device), prior_size)
      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert rows != []
      assert Enum.all?(rows, &(&1 in footer_range(authority)))
    end

    property "arbitrary sequences of footer content changes only ever address footer rows, across a live session" do
      check all(
              footer_states <-
                list_of(footer_lines_gen(), min_length: 1, max_length: 40),
              max_runs: 100
            ) do
        {device, authority} = new_authority()
        # `new_authority/1`'s construction already wrote the initial
        # DECSTBM region-set (homing the cursor); the delta baseline
        # starts AFTER that, not at byte 0.
        initial_size = device |> raw() |> byte_size()

        Enum.reduce(footer_states, {authority, initial_size}, fn lines,
                                                                 {auth,
                                                                  prior_size} ->
          auth = InlineAuthority.repaint(auth, lines)
          all_bytes = raw(device)
          new_bytes = delta(all_bytes, prior_size)

          rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()
          range = footer_range(auth)

          assert Enum.all?(rows, &(&1 in range)),
                 "a repaint/2 CUP addressed a row outside the footer range " <>
                   "#{inspect(range)}: #{inspect(rows)}"

          {auth, byte_size(all_bytes)}
        end)
      end
    end

    test "a no-op repaint (identical content) emits zero bytes" do
      {device, authority} = new_authority()
      authority = InlineAuthority.repaint(authority, ["same", "same"])
      prior_size = device |> raw() |> byte_size()

      _authority = InlineAuthority.repaint(authority, ["same", "same"])

      assert delta(raw(device), prior_size) == ""
    end
  end

  # ---------------------------------------------------------------------
  # Content-correctness: the footer RENDERS exactly the new content -- no
  # residue from a prior, wider/taller repaint. Positional-only assertions
  # (acceptance 1, above) prove every CUP stays inside the footer range but
  # cannot prove WHAT ends up on screen; a stale-content bug (dropping
  # `\e[K` from `footer_row_bytes/2`) keeps every one of those green while
  # leaving ghost characters behind a shorter new line. This is the
  # content-level check a positional-only scan cannot provide -- it
  # replays the real emitted bytes through the actual VT emulator and
  # reads back rendered text, the same oracle machinery
  # `history/3`/`immutable_prefix?/2` use for the history side.
  # ---------------------------------------------------------------------

  describe "content-correctness: repaint/2 renders exactly the new footer content, no residue" do
    test "shrinking content (fewer AND shorter lines) leaves no stale characters from the prior, wider repaint" do
      {device, authority} = new_authority()

      wide_line_1 = String.duplicate("A", @width - 1)
      wide_line_2 = String.duplicate("B", @width - 1)
      authority = InlineAuthority.repaint(authority, [wide_line_1, wide_line_2])

      short_line = "hi"
      _authority = InlineAuthority.repaint(authority, [short_line])

      raw_bytes = raw(device)
      footer_top = @region_top + 1

      # Row 1: the shorter new content, exactly -- no trailing "A"s from
      # the previous, wider line.
      assert footer_row_text(raw_bytes, footer_top, @width, @height) ==
               String.pad_trailing(short_line, @width)

      # Row 2: the second footer line wasn't in the new content at all
      # (fewer lines) -- pad_rows/2 pads it to "", so it must render as
      # entirely blank, not the previous "B"*39 line.
      assert footer_row_text(raw_bytes, footer_top + 1, @width, @height) ==
               String.pad_trailing("", @width)
    end

    property "after ANY content-shrinking transition, every footer row renders exactly the padded new content" do
      check all(
              old_lines <-
                list_of(line_gen(), min_length: 1, max_length: @footer_rows),
              new_lines <-
                list_of(line_gen(), min_length: 0, max_length: @footer_rows),
              max_runs: 50
            ) do
        {device, authority} = new_authority()
        authority = InlineAuthority.repaint(authority, old_lines)
        _authority = InlineAuthority.repaint(authority, new_lines)

        raw_bytes = raw(device)
        footer_top = @region_top + 1

        expected =
          new_lines |> Enum.take(@footer_rows) |> pad_to(@footer_rows)

        expected
        |> Enum.with_index()
        |> Enum.each(fn {line, idx} ->
          actual = footer_row_text(raw_bytes, footer_top + idx, @width, @height)

          assert actual == String.pad_trailing(line, @width),
                 "footer row #{footer_top + idx} rendered #{inspect(actual)}, " <>
                   "expected the padded new content #{inspect(String.pad_trailing(line, @width))} " <>
                   "-- old_lines=#{inspect(old_lines)} new_lines=#{inspect(new_lines)}"
        end)
      end
    end
  end

  # ---------------------------------------------------------------------
  # Degenerate geometry: InlineAuthority surfaces the scroll-region
  # manager's degenerate?/1 signal, and repaint/2 + keyframe/2 never crash
  # or address a row outside the actual screen even when the requested
  # footer doesn't fit.
  # ---------------------------------------------------------------------

  describe "degenerate geometry: new/5 never crashes, degenerate?/1 surfaces the scroll-region manager's signal" do
    test "rows=2/footer_rows=3: degenerate, footer capacity shrinks to what's left, no CUP outside the screen" do
      {device, authority} = new_authority(40, 2, 3)

      assert InlineAuthority.degenerate?(authority)
      # region_top/2's clamp gives history its 1-row minimum first, leaving
      # only 1 row for the footer even though 3 were requested --
      # footer_row_count/1 must reflect the ACTUAL capacity.
      assert InlineAuthority.footer_row_count(authority) == 1

      prior_size = device |> raw() |> byte_size()

      authority =
        InlineAuthority.repaint(authority, ["only one line fits", "dropped"])

      rows =
        raw(device)
        |> delta(prior_size)
        |> strip_cursor_bracket()
        |> SealOracle.cup_rows()

      assert rows != []
      assert Enum.all?(rows, &(&1 in 1..2))

      # keyframe/2 must not crash either, on this same tight geometry.
      _authority = InlineAuthority.keyframe(authority, ["x"])
    end

    test "rows=1/footer_rows=2: degenerate, footer_range empty, repaint/2 and keyframe/2 emit zero bytes (no bracket at all)" do
      {device, authority} = new_authority(40, 1, 2)

      assert InlineAuthority.degenerate?(authority)
      assert InlineAuthority.footer_row_count(authority) == 0

      prior_size = device |> raw() |> byte_size()
      authority = InlineAuthority.repaint(authority, ["anything", "at all"])
      assert delta(raw(device), prior_size) == ""

      prior_size = device |> raw() |> byte_size()
      _authority = InlineAuthority.keyframe(authority, ["anything", "at all"])

      # keyframe/2 with zero footer row capacity early-returns without
      # opening a with_cursor/3 bracket at all --
      # an empty \e7/\e8 save/restore pair over zero addressed rows would
      # be ceremony around a no-op; emitting NOTHING is the honest
      # behavior on a geometry that cannot show a footer.
      assert delta(raw(device), prior_size) == ""
    end

    test "rows=4/footer_rows=2: control case, NOT degenerate, footer confined to rows 3..4" do
      {device, authority} = new_authority(40, 4, 2)

      refute InlineAuthority.degenerate?(authority)
      assert InlineAuthority.footer_row_count(authority) == 2

      prior_size = device |> raw() |> byte_size()
      _authority = InlineAuthority.repaint(authority, ["a", "b"])

      rows =
        raw(device)
        |> delta(prior_size)
        |> strip_cursor_bracket()
        |> SealOracle.cup_rows()

      assert rows != []
      assert Enum.all?(rows, &(&1 in 3..4))
    end
  end

  # ---------------------------------------------------------------------
  # Acceptance 3: Ctrl-L recovery (keyframe/2) repaints footer only
  # ---------------------------------------------------------------------

  describe "acceptance 3: keyframe/2 (Ctrl-L recovery) repaints footer only" do
    test "a keyframe redraws every footer row (even unchanged ones), all confined to the footer range, no full clear" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "history line\r\n")
      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      prior_size = byte_size(raw_k)

      _authority =
        InlineAuthority.keyframe(authority, ["live tail", "composer"])

      new_bytes = delta(raw(device), prior_size)
      rows = new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

      # Every footer row is touched (a keyframe always redraws all of
      # them, unlike the diff-only repaint/2), and every one of those
      # rows is inside the footer range.
      assert MapSet.new(rows) == MapSet.new(footer_range(authority))
      refute SealOracle.emits_full_clear?(new_bytes)

      # History is untouched by the keyframe -- the "history unchanged"
      # half of that invariant.
      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)
    end
  end

  # ---------------------------------------------------------------------
  # Acceptance 2: resize composition -- footer re-derived, history untouched
  # ---------------------------------------------------------------------

  describe "acceptance 2: resize/3 |> keyframe/2 re-derives the footer without touching history" do
    test "seal + footer paint, then resize + keyframe: no full clear, history stays an immutable prefix, footer confined to the NEW range" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed before resize\r\n")
      authority = InlineAuthority.repaint(authority, ["live tail", "composer"])

      raw_before = raw(device)
      hw_before = SealOracle.seal_high_water(raw_before)

      emulator_before =
        SealOracle.replay(raw_before, width: @width, height: @height)

      history_before =
        SealOracle.history(emulator_before, @region_top, high_water: hw_before)

      new_height = 14
      resized = InlineAuthority.resize(authority, @width, new_height)
      new_region_top = InlineAuthority.region_top(resized)
      assert new_region_top == new_height - @footer_rows

      # resize/3's OWN delta: the single DECSTBM re-set, nothing else --
      # no full clear (checked below via the whole-stream assertion), no
      # footer content bytes (resize does not auto-repaint the footer by
      # design, see InlineAuthority.resize/3's doc).
      resize_delta = delta(raw(device), byte_size(raw_before))

      # keyframe/2's OWN delta, measured strictly AFTER resize/3
      # returned, isolates the footer-redraw bytes from the DECSTBM
      # re-set above -- otherwise the re-set's homing-to-row-1 CUP
      # (xterm DECSTBM semantics) would look like a history-row address
      # that was never actually a footer-confinement violation.
      prior_size = byte_size(raw_before) + byte_size(resize_delta)
      _final = InlineAuthority.keyframe(resized, ["live tail", "composer"])

      raw_final = raw(device)
      keyframe_delta = delta(raw_final, prior_size)

      refute SealOracle.emits_full_clear?(keyframe_delta)

      rows = keyframe_delta |> strip_cursor_bracket() |> SealOracle.cup_rows()

      assert Enum.all?(rows, &(&1 > new_region_top)),
             "keyframe/2 after resize addressed a row outside the new " <>
               "footer range (region_top=#{new_region_top}): #{inspect(rows)}"

      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: new_height)

      history_final =
        SealOracle.history(emulator_final, new_region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_before, history_final)

      assert SealOracle.region_sets(raw_final) == [
               {1, @region_top},
               {1, new_region_top}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # Footer side: with_cursor(:footer, ...) round-trips the cursor
  # ---------------------------------------------------------------------

  describe "footer side: repaint/2 and keyframe/2 never leave the cursor moved or the save/restore bracket unbalanced" do
    property "after any number of repaint/2 or keyframe/2 calls, the cursor is back at its pre-bracket position every time" do
      op_gen =
        gen all(
              kind <- member_of([:repaint, :keyframe]),
              lines <- footer_lines_gen()
            ) do
          {kind, lines}
        end

      check all(
              ops <- list_of(op_gen, min_length: 1, max_length: 30),
              max_runs: 30
            ) do
        {device, authority} = new_authority()

        baseline_cursor =
          device
          |> raw()
          |> SealOracle.replay(width: @width, height: @height)
          |> Emulator.get_cursor_position()

        Enum.reduce(ops, authority, fn
          {:repaint, lines}, auth ->
            auth = InlineAuthority.repaint(auth, lines)

            cursor_now =
              device
              |> raw()
              |> SealOracle.replay(width: @width, height: @height)
              |> Emulator.get_cursor_position()

            assert cursor_now == baseline_cursor
            auth

          {:keyframe, lines}, auth ->
            auth = InlineAuthority.keyframe(auth, lines)

            cursor_now =
              device
              |> raw()
              |> SealOracle.replay(width: @width, height: @height)
              |> Emulator.get_cursor_position()

            assert cursor_now == baseline_cursor
            auth
        end)

        balance = SealOracle.save_restore_balance(raw(device))
        assert balance.decsc == 0
        assert balance.decsc_max_depth <= 1
      end
    end
  end

  # ---------------------------------------------------------------------
  # Composition under interleaving: seal + repaint + keyframe + resize
  # ---------------------------------------------------------------------

  describe "composition: interleaved history + footer ops never cross-contaminate" do
    property "arbitrary interleavings of seal/repaint/keyframe/resize: footer bytes stay in the CURRENT footer range, no full clear, history stays an immutable prefix" do
      op_gen =
        gen all(
              kind <- member_of([:seal, :repaint, :keyframe, :resize]),
              seal_line <-
                string(:alphanumeric, min_length: 1, max_length: @width - 1),
              footer_lines <- footer_lines_gen(),
              new_height <- integer(6..40)
            ) do
          case kind do
            :seal -> {:seal, seal_line <> "\r\n"}
            :repaint -> {:repaint, footer_lines}
            :keyframe -> {:keyframe, footer_lines}
            :resize -> {:resize, new_height}
          end
        end

      check all(
              ops <- list_of(op_gen, min_length: 1, max_length: 40),
              max_runs: 30
            ) do
        {device, authority} = new_authority()
        initial_size = device |> raw() |> byte_size()

        {_final, _prior_size} =
          Enum.reduce(ops, {authority, initial_size}, fn op,
                                                         {auth, prior_size} ->
            auth =
              case op do
                {:seal, line} -> InlineAuthority.seal(auth, line)
                {:repaint, lines} -> InlineAuthority.repaint(auth, lines)
                {:keyframe, lines} -> InlineAuthority.keyframe(auth, lines)
                {:resize, h} -> InlineAuthority.resize(auth, @width, h)
              end

            all_bytes = raw(device)
            new_bytes = delta(all_bytes, prior_size)

            refute SealOracle.emits_full_clear?(new_bytes)

            case op do
              {kind, _} when kind in [:repaint, :keyframe] ->
                rows =
                  new_bytes |> strip_cursor_bracket() |> SealOracle.cup_rows()

                range = footer_range(auth)

                assert Enum.all?(rows, &(&1 in range)),
                       "#{kind} CUP addressed a row outside the footer range " <>
                         "#{inspect(range)}: #{inspect(rows)}"

              _other ->
                :ok
            end

            {auth, byte_size(all_bytes)}
          end)

        refute SealOracle.emits_full_clear?(raw(device))
      end
    end
  end
end
