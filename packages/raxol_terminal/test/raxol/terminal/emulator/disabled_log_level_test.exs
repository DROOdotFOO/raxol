defmodule Raxol.Terminal.Emulator.DisabledLogLevelTest do
  # Input from a program or a remote peer must not pay for log messages
  # nobody will see. A message is built when its argument is evaluated, and
  # `Raxol.Core.Runtime.Log`'s level functions evaluate theirs before the
  # level check, so a struct dump in one of them runs at every level. The
  # emulator here carries an `InspectProbe`, which reports each time it is
  # inspected: any dump of the emulator on these paths trips it.
  #
  # async: false because the Logger level is node-wide.
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Emulator
  alias Raxol.Test.InspectProbe

  setup do
    level = Logger.level()
    Logger.configure(level: :emergency)
    on_exit(fn -> Logger.configure(level: level) end)

    %{emulator: %{Emulator.new(80, 24) | event: InspectProbe.new(:emulator)}}
  end

  test "mode sequences dump nothing while logging is disabled", %{emulator: emulator} do
    {emulator, _output} =
      Emulator.process_input(emulator, "\e[?1049h\e[?25l\e[4h\e[?1000h\e[?1006h")

    refute emulator.mode_manager.cursor_visible
    assert emulator.mode_manager.alternate_buffer_active
    assert emulator.mode_manager.insert_mode
    assert emulator.mode_manager.mouse_encoding == :sgr
    refute_received {:inspected, _}
  end

  test "an invalid UTF-8 byte dumps nothing while logging is disabled", %{emulator: emulator} do
    {_emulator, _output} = Emulator.process_input(emulator, <<0xFF, ?a>>)

    refute_received {:inspected, _}
  end
end
