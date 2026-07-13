defmodule Raxol.Terminal.ANSI.StateMachineTest do
  use ExUnit.Case, async: true
  alias Raxol.Terminal.ANSI.StateMachine

  describe "new/0" do
    test ~c"creates a new parser state with default values" do
      state = StateMachine.new()
      assert state.state == :ground
      assert state.params_buffer == ""
      assert state.intermediates_buffer == ""
      assert state.payload_buffer == ""
      assert state.final_byte == nil
      assert state.designating_gset == nil
    end
  end

  describe "process/2" do
    test ~c"handles simple text" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "Hello")
      assert new_state.state == :ground
      assert length(sequences) == 5
      assert Enum.all?(sequences, &(&1.type == :text))
      assert Enum.map(sequences, & &1.text) == ["H", "e", "l", "l", "o"]
    end

    test ~c"handles CSI sequences" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e[1;2;3m")
      assert new_state.state == :ground
      assert length(sequences) == 1
      [sequence] = sequences
      assert sequence.type == :csi
      assert sequence.command == "m"
      assert sequence.params == ["1", "2", "3"]
      assert sequence.intermediate == ""
      assert sequence.final == "m"
    end

    test ~c"handles OSC sequences" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e]0;title\a")
      assert new_state.state == :ground
      assert length(sequences) == 1
      [sequence] = sequences
      assert sequence.type == :osc
      assert sequence.command == "0"
      assert sequence.params == ["title"]
      assert sequence.text == "title"
    end

    test ~c"handles character set designation" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e(0")
      assert new_state.state == :ground
      assert length(sequences) == 1
      [sequence] = sequences
      assert sequence.type == :esc
      assert sequence.command == "(0"
    end

    test ~c"handles invalid sequences" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e[invalid")
      assert new_state.state in [:ground, :ignore]
      assert Enum.empty?(sequences)
    end

    test ~c"handles CAN/SUB in CSI sequences" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e[1\x18")
      assert new_state.state == :ground
      assert Enum.empty?(sequences)
    end

    test ~c"handles OSC with ST terminator" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\e]0;title\e\\")
      assert new_state.state == :ground
      assert length(sequences) == 1
      [sequence] = sequences
      assert sequence.type == :osc
      assert sequence.command == "0"
      assert sequence.params == ["title"]
      assert sequence.text == "title"
    end

    test ~c"handles a well-formed DCS sequence without crashing or leaking text" do
      state = StateMachine.new()

      {new_state, sequences} =
        StateMachine.process(state, "\eP1;2q$q\"p\e\\")

      assert new_state.state == :ground
      assert Enum.empty?(sequences)
    end

    test ~c"handles an empty DCS sequence" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\eP\e\\")
      assert new_state.state == :ground
      assert Enum.empty?(sequences)
    end

    test ~c"handles CAN/SUB inside a DCS sequence" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\eP1;2\x18")
      assert new_state.state == :ground
      assert Enum.empty?(sequences)
    end

    test ~c"handles unparsable DCS payload without raising" do
      state = StateMachine.new()

      payload = <<0x1B, ?P, 200, 150, 90, 0xF0, 0x9F, 0x92, 0xA9, 0x1B, ?\\>>

      {new_state, sequences} = StateMachine.process(state, payload)
      assert new_state.state == :ground
      assert Enum.empty?(sequences)
    end

    test ~c"handles a DCS sequence followed by more input" do
      state = StateMachine.new()

      {new_state, sequences} =
        StateMachine.process(state, "\eP1qdata\e\\Hello")

      assert new_state.state == :ground
      assert Enum.map(sequences, & &1.type) == [:text, :text, :text, :text, :text]
      assert Enum.map(sequences, & &1.text) == ["H", "e", "l", "l", "o"]
    end

    test ~c"handles an unterminated DCS sequence without raising" do
      state = StateMachine.new()
      {new_state, sequences} = StateMachine.process(state, "\eP1;2qsome data")
      assert new_state.state in [:dcs_entry, :dcs_passthrough, :dcs_passthrough_maybe_st]
      assert Enum.empty?(sequences)
    end

    test ~c"handles multiple sequences" do
      state = StateMachine.new()

      {new_state, sequences} =
        StateMachine.process(state, "Hello\e[1mWorld\e[0m")

      assert new_state.state == :ground
      assert length(sequences) == 12

      assert Enum.map(sequences, & &1.type) == [
               :text,
               :text,
               :text,
               :text,
               :text,
               :csi,
               :text,
               :text,
               :text,
               :text,
               :text,
               :csi
             ]
    end
  end
end
