defmodule Raxol.Property.DcsParsingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.ANSI.StateMachine

  # Mirrors StateMachine.state()/0 -- kept in sync manually since the type
  # itself isn't introspectable at runtime.
  @valid_states [
    :ground,
    :escape,
    :csi_entry,
    :csi_param,
    :csi_intermediate,
    :csi_final,
    :osc_string,
    :osc_string_maybe_st,
    :dcs_entry,
    :dcs_passthrough,
    :dcs_passthrough_maybe_st,
    :designate_charset,
    :ignore
  ]

  defp assert_sane_result({new_state, sequences}) do
    assert new_state.state in @valid_states
    assert is_list(sequences)
    Enum.each(sequences, &assert(is_map(&1)))
  end

  # Regression coverage for the FunctionClauseError originally hit fuzzing
  # the state machine with random unicode inside a DCS string, e.g.
  # `"\eP��...\e\\"`.
  describe "DCS totality" do
    property "never raises on DCS strings wrapping arbitrary bytes" do
      check all(
              payload <- binary(max_length: 64),
              max_runs: 500
            ) do
        input = <<0x1B, ?P>> <> payload <> <<0x1B, ?\\>>

        StateMachine.process(StateMachine.new(), input)
        |> assert_sane_result()
      end
    end

    property "never raises on DCS strings wrapping arbitrary unicode" do
      check all(
              codepoints <-
                list_of(
                  one_of([
                    integer(0..0xD7FF),
                    integer(0xE000..0x10FFFF)
                  ]),
                  max_length: 24
                ),
              max_runs: 500
            ) do
        payload = Enum.map_join(codepoints, fn cp -> <<cp::utf8>> end)
        input = "\eP" <> payload <> "\e\\"

        StateMachine.process(StateMachine.new(), input)
        |> assert_sane_result()
      end
    end

    property "never raises on unterminated or truncated DCS strings" do
      check all(
              payload <- binary(max_length: 64),
              max_runs: 500
            ) do
        input = <<0x1B, ?P>> <> payload

        StateMachine.process(StateMachine.new(), input)
        |> assert_sane_result()
      end
    end

    property "a DCS closed with ST and no control bytes always returns to :ground" do
      check all(
              payload <- list_of(integer(0x20..0x7E), max_length: 40),
              max_runs: 500
            ) do
        payload_bin = :erlang.list_to_binary(payload)
        input = <<0x1B, ?P>> <> payload_bin <> <<0x1B, ?\\>>

        {new_state, sequences} = StateMachine.process(StateMachine.new(), input)

        assert new_state.state == :ground
        assert Enum.empty?(sequences)
      end
    end

    property "a DCS cancelled with CAN/SUB always returns to :ground" do
      check all(
              prefix <- list_of(integer(0x20..0x7E), max_length: 40),
              cancel_byte <- member_of([0x18, 0x1A]),
              max_runs: 500
            ) do
        prefix_bin = :erlang.list_to_binary(prefix)
        input = <<0x1B, ?P>> <> prefix_bin <> <<cancel_byte>>

        {new_state, sequences} = StateMachine.process(StateMachine.new(), input)

        assert new_state.state == :ground
        assert Enum.empty?(sequences)
      end
    end
  end

  describe "whole-machine totality (broad fuzz)" do
    property "never raises on arbitrary binary input" do
      check all(
              input <- binary(max_length: 128),
              max_runs: 1000
            ) do
        StateMachine.process(StateMachine.new(), input)
        |> assert_sane_result()
      end
    end
  end
end
