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
  end

  describe "property: CSI h/l never raises" do
    # Seeded :rand instead of StreamData (not a raxol_terminal dependency;
    # see test/property/). Every failure names the iteration to replay.
    @runs 300
    @calls_per_run 12

    @registered_codes [
      1,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      12,
      20,
      25,
      47,
      1000,
      1002,
      1004,
      1006,
      1047,
      1048,
      1049,
      2004
    ]

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

    defp gen_params, do: for(_ <- 0..:rand.uniform(6), do: gen_param(0))

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
    end

    # Arguments, not body-bound variables: those are what a `rescue` clause
    # can still see.
    defp describe(where, params, intermediates, final_byte),
      do: "#{where}: #{inspect(params)} #{inspect(intermediates)} #{<<final_byte>>}"
  end
end
