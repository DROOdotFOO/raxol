defmodule Raxol.Terminal.ANSI.TerminalStateTest do
  use ExUnit.Case
  # remove charactersets terminal ansi
  alias Raxol.Terminal.ANSI.TerminalState
  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ModeManager

  defp create_test_emulator(
         {x, y},
         style,
         scroll_region \\ nil,
         cursor_style \\ :blinking_block
       ) do
    emulator = Emulator.new(80, 24)
    cursor = Raxol.Terminal.Cursor.Manager.new(%{row: y, col: x})

    %Emulator{
      emulator
      | cursor: cursor,
        style: style,
        charset_state: Raxol.Terminal.ANSI.CharacterSets.new(),
        mode_manager: ModeManager.new(),
        scroll_region: scroll_region,
        cursor_style: cursor_style
    }
  end

  describe "get_state_stack/1" do
    test ~c"returns the current terminal state stack" do
      state = TerminalState.new()

      initial_style =
        TextFormatting.new() |> TextFormatting.set_foreground(:red)

      emulator_state = create_test_emulator({10, 5}, initial_style, {5, 15})

      state = TerminalState.update_state_stack(state, [emulator_state])
      retrieved_stack = TerminalState.get_state_stack(state)

      assert retrieved_stack == [emulator_state]
      assert length(retrieved_stack) == 1
    end
  end
end
