defmodule Raxol.Terminal.EmulatorAdversarialPropertyTest do
  @moduledoc """
  The emulator's output byte stream is untrusted, so no byte string may make
  `Emulator.process_input/2` raise (a crash drops the pilot's session) or
  leave the screen buffer at another size or shape. Random bytes rarely form
  a complete escape sequence, so the generator also assembles CSI, DCS and
  OSC sequences from introducers, numbers and payloads real programs send.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.Emulator

  @width 20
  @height 6

  defp csi_fragment do
    gen all(
          intro <-
            member_of(["\e[", "\e[?", "\e[>", "\e[=", "\eP", "\eP$", "\eP+"]),
          params <-
            list_of(one_of([integer(0..9), integer(0..99_999)]), max_length: 5),
          separator <- member_of([";", ":"]),
          final <- integer(0x40..0x7E)
        ) do
      intro <>
        Enum.map_join(params, separator, &Integer.to_string/1) <> <<final>>
    end
  end

  defp osc_fragment do
    gen all(
          ps <-
            member_of(
              ~w(0 1 2 4 7 8 9 10 11 12 17 19 22 50 51 52 104 112 777 1337)
            ),
          payload <-
            member_of([
              "?",
              "c;?",
              "s;?",
              "c;aGVsbG8=",
              "1;?",
              "1;rgb:ff/00/00",
              "1;",
              "rgb:12/34/56",
              "#abc",
              "file://host/tmp",
              ";http://example.com",
              "CurrentDir=/tmp",
              "RemoteHost=host",
              "4;1;50",
              "title",
              ""
            ]),
          terminator <- member_of(["\a", "\e\\", ""])
        ) do
      "\e]" <> ps <> ";" <> payload <> terminator
    end
  end

  # Whole sequences real programs send (ncurses, tmux, vim, shells), so the
  # interactions between them get exercised, not only malformed input.
  defp vocabulary do
    member_of([
      "\e[?1049h",
      "\e[?1049l",
      "\e[?1047h",
      "\e[?1047l",
      "\e[?1048h",
      "\e[?1048l",
      "\e[?47h",
      "\e[?47l",
      "\e7",
      "\e8",
      "\e[s",
      "\e[u",
      "\e(0",
      "\e(B",
      "\e)0",
      "\e[5 q",
      "\e[0 q",
      "\e[2;5r",
      "\e[1;99r",
      "\e[r",
      "\e[10;1H",
      "\e[99;99H",
      "\e[1;31;42m",
      "\e[38;5;196;48;2;1;2;3m",
      "\e[4:3m",
      "\e[0m",
      "\e[!p",
      "\e[?25l",
      "\e[?25h",
      "\e[?7l",
      "\e[?6h",
      "\e[2J",
      "\e[3J",
      "\e[K",
      "\e[3L",
      "\e[2M",
      "\e[4@",
      "\e[2P",
      "\e[3X",
      "\e[H",
      "\e[6;15H",
      "\e[6n",
      "\e[c",
      "\e]0;title\a",
      "\e]7;file://host/tmp\e\\",
      "\e]11;?\a",
      "\e]52;c;?\a",
      "\eP$qm\e\\",
      "\eP+q544e\e\\",
      "\eM",
      "\eD",
      "\eE",
      "\eH",
      "\ec"
    ])
  end

  defp fragment do
    one_of([
      vocabulary(),
      vocabulary(),
      binary(max_length: 12),
      # Invalid UTF-8 after a pictograph, which OTP's grapheme breaking raises on.
      constant(<<0xC2, 0xAE, 0x9B, 0x9A>>),
      csi_fragment(),
      osc_fragment(),
      member_of([
        "\eH",
        "\e#8",
        "\ec",
        "\e7",
        "\e8",
        "\eM",
        "\eD",
        "\eE",
        "\n",
        "\r",
        "\t",
        "\b"
      ]),
      member_of(["\ePq#1;2;100;0;0#1!30~-~\e\\", "\ePq\"1;1;9;9#300~\e\\"])
    ])
  end

  defp chunks do
    list_of(map(list_of(fragment(), max_length: 12), &IO.iodata_to_binary/1),
      min_length: 1,
      max_length: 4
    )
  end

  # A step is either output or a resize, so the parser and the line
  # operations also run against sizes that changed under them.
  defp step do
    frequency([
      {4, map(chunks(), &{:output, IO.iodata_to_binary(&1)})},
      {1, tuple({constant(:resize), integer(4..40), integer(2..12)})}
    ])
  end

  defp run_step({:output, chunk}, emulator) do
    {emulator, _output} = Emulator.process_input(emulator, chunk)
    emulator
  end

  defp run_step({:resize, width, height}, emulator),
    do: Emulator.resize(emulator, width, height)

  defp assert_consistent_shape(emulator) do
    buffer = Emulator.get_screen_buffer(emulator)
    assert length(buffer.cells) == buffer.height
    assert Enum.all?(buffer.cells, &(length(&1) == buffer.width))
  end

  property "process_input never raises and keeps the screen's shape" do
    check all(chunks <- chunks(), max_runs: 300) do
      emulator =
        Enum.reduce(
          chunks,
          Emulator.new(@width, @height),
          &run_step({:output, &1}, &2)
        )

      buffer = Emulator.get_screen_buffer(emulator)

      # DECCOLM (CSI ? 3 h / l) legitimately switches to 132 or 80 columns.
      assert buffer.width in [@width, 80, 132]
      assert buffer.height == @height
      assert_consistent_shape(emulator)
    end
  end

  property "the screen's rows stay consistent across resizes" do
    check all(
            steps <- list_of(step(), min_length: 1, max_length: 6),
            max_runs: 200
          ) do
      emulator = Enum.reduce(steps, Emulator.new(@width, @height), &run_step/2)
      assert_consistent_shape(emulator)
    end
  end

  # Past the cell ceiling the buffer is clamped but the emulator's height is
  # not, so a scroll region can run past the buffer's last row.
  property "a size past the cell ceiling keeps the buffer's shape" do
    emulator = Emulator.new(4096, 300)

    check all(
            chunks <- chunks(),
            region <- member_of(["\e[1;300r", "\e[100;290r", "\e[r"]),
            row <- integer(1..300),
            max_runs: 25
          ) do
      emulator =
        run_step(
          {:output, region <> "\e[#{row};1H" <> Enum.join(chunks)},
          emulator
        )

      assert_consistent_shape(emulator)
    end
  end
end
