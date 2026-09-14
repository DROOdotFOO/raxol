defmodule Raxol.Terminal.Commands.CSIHandler.ModeProcessorTest do
  @moduledoc """
  ModeProcessor is the live `CSI h` / `CSI l` path: `CSIHandler` dispatches
  both final bytes here, and `ModeTypes` is the only table a mode number is
  resolved against. A number absent from the registry, a registered mode
  without a handler, or a parameter that is not a well-formed integer is
  silently dropped; the rest of the sequence still applies.

  The mouse assertions exist because SGR mouse encoding (`CSI ? 1006 h`) was
  once implemented below the live dispatch but never reached. Reporting modes
  and encoding modes are independent: the driver enables press/release
  reporting with 1000 and extended coordinate encoding with 1006.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Commands.CSIHandler.ModeProcessor
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Modes.Types.ModeTypes
  alias Raxol.Terminal.ScreenBuffer

  defp set_private(emulator, code) do
    ModeProcessor.handle_h_or_l(emulator, [code], "?", ?h)
  end

  defp reset_private(emulator, code) do
    ModeProcessor.handle_h_or_l(emulator, [code], "?", ?l)
  end

  defp feed(emulator, input) do
    {emulator, _} = Emulator.process_input(emulator, input)
    emulator
  end

  defp row0(emulator) do
    emulator.main_screen_buffer
    |> ScreenBuffer.get_line(0)
    |> Enum.map_join(& &1.char)
    |> String.trim_trailing()
  end

  describe "mouse reporting modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "CSI ? 1006 h enables SGR mouse encoding", %{emulator: emulator} do
      assert emulator.mode_manager.mouse_encoding == :x10

      result = set_private(emulator, 1006)

      assert result.mode_manager.mouse_encoding == :sgr
      assert result.mode_manager.mouse_report_mode == :none
    end

    test "CSI ? 1006 l disables only SGR encoding", %{emulator: emulator} do
      enabled =
        emulator
        |> set_private(1000)
        |> set_private(1006)

      reset = reset_private(enabled, 1006)

      assert reset.mode_manager.mouse_encoding == :x10
      assert reset.mode_manager.mouse_report_mode == :x10
    end

    test "CSI ? 1000 h enables X10 mouse reporting", %{emulator: emulator} do
      assert set_private(emulator, 1000).mode_manager.mouse_report_mode ==
               :x10
    end

    test "CSI ? 1002 h enables cell-motion mouse reporting", %{
      emulator: emulator
    } do
      assert set_private(emulator, 1002).mode_manager.mouse_report_mode ==
               :cell_motion
    end

    test "the driver's own mouse handshake keeps reporting and encoding", %{
      emulator: emulator
    } do
      result =
        emulator
        |> set_private(1000)
        |> set_private(1006)

      assert result.mode_manager.mouse_report_mode == :x10
      assert result.mode_manager.mouse_encoding == :sgr
    end
  end

  describe "DEC private modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "?7 sets and resets auto wrap (DECAWM)", %{emulator: emulator} do
      assert set_private(emulator, 7).mode_manager.auto_wrap == true

      on = put_in(emulator.mode_manager.auto_wrap, true)
      assert reset_private(on, 7).mode_manager.auto_wrap == false
    end

    test "?25 sets and resets cursor visibility (DECTCEM)", %{
      emulator: emulator
    } do
      assert set_private(emulator, 25).mode_manager.cursor_visible == true

      on = put_in(emulator.mode_manager.cursor_visible, true)
      assert reset_private(on, 25).mode_manager.cursor_visible == false
    end

    test "?6 sets and resets origin mode (DECOM)", %{emulator: emulator} do
      assert set_private(emulator, 6).mode_manager.origin_mode == true

      on = put_in(emulator.mode_manager.origin_mode, true)
      assert reset_private(on, 6).mode_manager.origin_mode == false
    end

    test "?5 sets and resets reverse screen (DECSCNM)", %{emulator: emulator} do
      assert set_private(emulator, 5).mode_manager.screen_mode_reverse == true

      on = put_in(emulator.mode_manager.screen_mode_reverse, true)
      assert reset_private(on, 5).mode_manager.screen_mode_reverse == false
    end

    test "?2004 sets and resets bracketed paste", %{emulator: emulator} do
      assert set_private(emulator, 2004).mode_manager.bracketed_paste_mode ==
               true

      on = put_in(emulator.mode_manager.bracketed_paste_mode, true)

      assert reset_private(on, 2004).mode_manager.bracketed_paste_mode ==
               false
    end

    test "?3 switches column width and resizes the buffer (DECCOLM)", %{
      emulator: emulator
    } do
      wide = set_private(emulator, 3)
      assert wide.mode_manager.column_width_mode == :wide
      assert ScreenBuffer.get_width(wide.main_screen_buffer) == 132

      narrow = reset_private(wide, 3)
      assert narrow.mode_manager.column_width_mode == :normal
      assert ScreenBuffer.get_width(narrow.main_screen_buffer) == 80
    end

    test "several private modes in one sequence all apply", %{
      emulator: emulator
    } do
      set = ModeProcessor.handle_h_or_l(emulator, [7, 25], "?", ?h)
      assert set.mode_manager.auto_wrap == true
      assert set.mode_manager.cursor_visible == true

      reset = ModeProcessor.handle_h_or_l(set, [7, 25], "?", ?l)
      assert reset.mode_manager.auto_wrap == false
      assert reset.mode_manager.cursor_visible == false
    end
  end

  describe "standard modes" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "4 sets and resets insert mode (IRM)", %{emulator: emulator} do
      set = ModeProcessor.handle_h_or_l(emulator, [4], "", ?h)
      assert set.mode_manager.insert_mode == true

      reset = ModeProcessor.handle_h_or_l(set, [4], "", ?l)
      assert reset.mode_manager.insert_mode == false
    end

    test "20 sets and resets line feed mode (LNM)", %{emulator: emulator} do
      set = ModeProcessor.handle_h_or_l(emulator, [20], "", ?h)
      assert set.mode_manager.line_feed_mode == true

      reset = ModeProcessor.handle_h_or_l(set, [20], "", ?l)
      assert reset.mode_manager.line_feed_mode == false
    end
  end

  describe "unknown and empty parameters" do
    setup do
      %{emulator: Emulator.new(80, 24)}
    end

    test "an unmodelled private mode is ignored rather than crashing", %{
      emulator: emulator
    } do
      # 1005 (UTF-8 mouse) has no ModeTypes entry and no handler. It must be
      # a no-op, not a crash.
      assert set_private(emulator, 1005).mode_manager.mouse_report_mode ==
               :none
    end

    test "a registered mode with no handler is dropped the same way", %{
      emulator: emulator
    } do
      # ?12 resolves to :att_blink, which no handler implements.
      assert set_private(emulator, 12) == emulator
      assert reset_private(emulator, 12) == emulator
    end

    test "empty parameter list is a no-op", %{emulator: emulator} do
      assert ModeProcessor.handle_h_or_l(emulator, [], "?", ?h).mode_manager ==
               emulator.mode_manager

      assert ModeProcessor.handle_h_or_l(emulator, [], "", ?l).mode_manager ==
               emulator.mode_manager
    end

    test "an unknown standard mode is a no-op", %{emulator: emulator} do
      assert ModeProcessor.handle_h_or_l(emulator, [999], "", ?h).mode_manager ==
               emulator.mode_manager
    end

    test "non-integer parameters are skipped, not raised on", %{
      emulator: emulator
    } do
      # nil is what the parser yields for an empty slot, a nested list for a
      # colon subparameter group, and a string may arrive from older callers.
      assert ModeProcessor.handle_h_or_l(emulator, [nil], "?", ?h) == emulator

      assert ModeProcessor.handle_h_or_l(emulator, [[4, 3]], "?", ?h) ==
               emulator

      assert ModeProcessor.handle_h_or_l(emulator, ["x"], "?", ?h) == emulator
      assert ModeProcessor.handle_h_or_l(emulator, ["7x"], "?", ?h) == emulator

      assert ModeProcessor.handle_h_or_l(emulator, ["7"], "?", ?h).mode_manager.auto_wrap ==
               true
    end
  end

  describe "through the parser" do
    setup do
      {emulator, _} = Emulator.process_input(Emulator.new(80, 24), "hello")
      %{emulator: emulator}
    end

    test "a malformed parameter is dropped and the rest still applies", %{
      emulator: emulator
    } do
      # `?1;` parses to [1, nil]: ?1 applies, the empty slot is ignored.
      partial = feed(emulator, "\e[?1;h")
      assert partial.mode_manager.cursor_keys_mode == :application
      assert row0(partial) == "hello"

      # `?4:3` parses to [[4, 3]]: nothing to apply.
      subparam = feed(emulator, "\e[?4:3h")
      assert subparam.mode_manager == emulator.mode_manager
      assert subparam.cursor.position == emulator.cursor.position
      assert row0(subparam) == "hello"
    end

    test "CSI 132 h, CSI 80 h and CSI ? 80 h are not column-width modes", %{
      emulator: emulator
    } do
      # Only DECCOLM (CSI ? 3) switches column width. DEC-private 80 is DECSDM
      # in xterm and standard 80/132 do not exist; all three once replaced the
      # screen buffers with empty ones.
      for input <- ["\e[132h", "\e[80h", "\e[?80h"] do
        out = feed(emulator, input)
        assert row0(out) == "hello", inspect(input)
        assert out.width == 80, inspect(input)

        assert ScreenBuffer.get_width(out.main_screen_buffer) == 80,
               inspect(input)

        assert out.mode_manager.column_width_mode == :normal, inspect(input)
      end
    end

    test "CSI ? 3 h is DECCOLM: 132 columns, emulator width included", %{
      emulator: emulator
    } do
      wide = feed(emulator, "\e[?3h")
      assert wide.width == 132
      assert ScreenBuffer.get_width(wide.main_screen_buffer) == 132
      assert wide.mode_manager.column_width_mode == :wide

      narrow = feed(wide, "\e[?3l")
      assert narrow.width == 80
      assert ScreenBuffer.get_width(narrow.main_screen_buffer) == 80
      assert narrow.mode_manager.column_width_mode == :normal
    end

    test "CSI ? 1049 h saves the cursor as DECSC, so CSI u restores it", %{
      emulator: emulator
    } do
      # xterm: 1049 = save cursor as DECSC, switch to alt screen, clear it.
      assert feed(emulator, "\e[5;10H\e[?1049h\e[1;1H\e[u").cursor.position ==
               {4, 9}
    end

    test "CSI ? 1049 l restores the cursor as DECRC", %{emulator: emulator} do
      back = feed(emulator, "\e[5;10H\e[?1049h\e[1;1H\e[?1049l")
      assert back.cursor.position == {4, 9}
      assert back.active_buffer_type == :main
    end

    # `restore_cursor_only/1` hands `apply_restored_data/3` the `nil` that
    # `restore_state([])` returns. That is survivable for exactly one reason:
    # the `:cursor` clause's `is_map(restored_state.cursor)` is a GUARD, so the
    # BadMapError on `nil.cursor` fails the clause instead of the call. The
    # same call with an unguarded field in the list (`:scroll_region`,
    # `:cursor_style`) does raise, so this pins the no-op end to end rather
    # than trusting the field list to stay as it is.
    test "CSI ? 1048 l on an empty state stack is a no-op, not a crash", %{
      emulator: emulator
    } do
      out = feed(emulator, "\e[5;10H\e[?1048l")

      assert out.state_stack == []
      assert out.cursor.position == {4, 9}
      assert out.mode_manager == emulator.mode_manager
      assert row0(out) == "hello"
    end

    test "CSI ? 1048 h then l restores the saved cursor", %{emulator: emulator} do
      out = feed(emulator, "\e[5;10H\e[?1048h\e[1;1H\e[?1048l")

      assert out.cursor.position == {4, 9}
      assert out.state_stack == []
    end
  end

  describe "property: CSI h/l never raises" do
    # Seeded `:rand` instead of StreamData (not a raxol_terminal dependency;
    # see test/property/). The corpus is therefore FIXED: same 300 x 12 cases
    # on every run, which is what makes a reported failure replayable, and
    # also means no new shape is ever discovered after the first green run.
    # It is a regression lock, not a fuzzer.
    @runs 300
    @calls_per_run 12

    # Derived from the registry, never hand-copied: a hard-coded list is the
    # same drift this PR's registry-coverage test exists to prevent, one file
    # over -- a newly registered mode would silently never be fuzzed.
    @registered_codes ModeTypes.get_all_modes()
                      |> Map.values()
                      |> Enum.map(& &1.code)
                      |> Enum.uniq()
                      |> Enum.sort()

    # Numbers a real terminal sends, plus the shapes CommandsParser can yield
    # for malformed input and the shapes an older caller might pass.
    @malformed_binaries [
      "",
      "7x",
      "x",
      " 7",
      "7 ",
      "-",
      "+1",
      "0x1F",
      "1.5",
      "1e3"
    ]
    @unicode_binaries ["é", "٣", "７", "\u0000", "\e[?1h", "ﬁ"]
    @non_numbers [nil, [], [nil], [[4, 3]], {4, 3}, :atom, 1.5, %{}, true]

    defp seed(i), do: :rand.seed(:exsss, {1012, 3, i})

    defp gen_param(depth) do
      case :rand.uniform(7) do
        1 -> gen_integer()
        2 -> Enum.random(@registered_codes)
        3 -> Integer.to_string(Enum.random(@registered_codes))
        4 -> Enum.random(@malformed_binaries)
        5 -> Enum.random(@unicode_binaries)
        6 -> Enum.random(@non_numbers)
        7 -> gen_nested(depth)
      end
    end

    defp gen_integer,
      do:
        Enum.random([
          0,
          -:rand.uniform(5000),
          :rand.uniform(3000),
          :rand.uniform(10 ** 12)
        ])

    defp gen_nested(depth) when depth >= 2, do: Enum.random(@non_numbers)

    defp gen_nested(depth),
      do: for(_ <- 1..:rand.uniform(3), do: gen_param(depth + 1))

    # `0..rand(6)` never yields fewer than two elements, so the empty list and
    # the single-parameter list -- `\e[?1h`, the commonest CSI h/l a real
    # terminal sends -- were the two shapes this never fuzzed.
    defp gen_params, do: for(_ <- 1..:rand.uniform(7)//1, do: gen_param(0)) |> drop_sometimes()

    defp drop_sometimes(params) do
      case :rand.uniform(8) do
        1 -> []
        2 -> Enum.take(params, 1)
        _ -> params
      end
    end

    test "random parameter shapes through both tables, set and reset, always return an emulator" do
      for i <- 1..@runs do
        seed(i)

        Enum.reduce(1..@calls_per_run, Emulator.new(80, 24), fn call, emulator ->
          assert_totality(
            emulator,
            gen_params(),
            Enum.random(["?", ""]),
            Enum.random([?h, ?l]),
            "iteration #{i} call #{call}"
          )
        end)
      end
    end

    # Totality is the weaker half. The generator deliberately feeds `" 7"`,
    # `"0x1F"`, `"1049 "` and friends, and the POINT of those is that they
    # are dropped: a regression that made parsing lenient (`Integer.parse/1`
    # in place of the strict check) would let `" 3"` trigger DECCOLM's
    # 80<->132 buffer reallocation, or `"1049 "` switch to the alternate
    # screen, and every "an emulator came back" assertion would still pass.
    # So a call whose parameters contain no well-formed registered code must
    # leave the emulator's mode state, geometry and buffers alone.
    test "parameters that are not well-formed registered codes have no effect" do
      for i <- 1..@runs do
        seed(i)

        Enum.each(1..@calls_per_run, fn call ->
          params = Enum.reject(gen_params(), &well_formed_code?/1)
          intermediates = Enum.random(["?", ""])
          final_byte = Enum.random([?h, ?l])
          emulator = Emulator.new(80, 24)

          result =
            ModeProcessor.handle_h_or_l(emulator, params, intermediates, final_byte)

          where = "iteration #{i} call #{call}"

          assert result.mode_manager == emulator.mode_manager,
                 "#{describe(where, params, intermediates, final_byte)} changed mode state"

          assert result.width == emulator.width,
                 "#{describe(where, params, intermediates, final_byte)} resized the emulator"

          assert result.active_buffer_type == emulator.active_buffer_type,
                 "#{describe(where, params, intermediates, final_byte)} switched buffers"

          assert result.state_stack == emulator.state_stack,
                 "#{describe(where, params, intermediates, final_byte)} touched the state stack"
        end)
      end
    end

    # A parameter reaches `ModeManager` only as an exact decimal integer in
    # the table for its intermediates. Mirrors `ModeProcessor.mode_code/1`
    # deliberately rather than calling it: a lenient rewrite of that function
    # is the regression this test exists to catch, so sharing it would make
    # the test agree with the bug.
    defp well_formed_code?(param) when is_integer(param),
      do: registered?(param)

    defp well_formed_code?(param) when is_binary(param) do
      case Integer.parse(param) do
        {code, ""} -> registered?(code)
        _ -> false
      end
    end

    defp well_formed_code?(_param), do: false

    defp registered?(code),
      do: ModeTypes.lookup_private(code) != nil or ModeTypes.lookup_standard(code) != nil

    # An %Emulator{} back, whatever went in. Anything else -- a raise or some
    # other term -- fails with the shape that caused it, so a case replays.
    defp assert_totality(emulator, params, intermediates, final_byte, where) do
      result =
        ModeProcessor.handle_h_or_l(emulator, params, intermediates, final_byte)

      assert match?(%Emulator{}, result),
             "#{describe(where, params, intermediates, final_byte)} returned " <>
               inspect(result, limit: 5)

      result
    rescue
      e in ExUnit.AssertionError ->
        reraise e, __STACKTRACE__

      e ->
        flunk(
          "#{describe(where, params, intermediates, final_byte)} raised " <>
            Exception.format(:error, e, __STACKTRACE__)
        )
    catch
      # A `throw` or an `exit` from a handler escaped with no iteration, no
      # parameter list and no sequence shape, so the failure could not be
      # replayed -- the one thing the report promises.
      kind, reason ->
        flunk(
          "#{describe(where, params, intermediates, final_byte)} threw " <>
            Exception.format(kind, reason, __STACKTRACE__)
        )
    end

    # Arguments, not body-bound variables: those are what a `rescue` clause
    # can still see.
    defp describe(where, params, intermediates, final_byte),
      do: "#{where}: #{inspect(params)} #{inspect(intermediates)} #{<<final_byte>>}"
  end
end
