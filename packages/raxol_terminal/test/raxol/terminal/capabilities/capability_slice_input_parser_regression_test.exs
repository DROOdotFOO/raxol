defmodule Raxol.Terminal.Capabilities.CapabilitySliceInputParserRegressionTest do
  @moduledoc """
  CAP-N-11: reply bytes must never surface as key events. This locks the
  `InputParser` consume-unmapped path (the #443 hardening) that the
  capability probe's leak-free residual relies on: even if a reply
  reaches the key parser, it is consumed whole, silently.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.InputParser

  test "a DECRQM reply parses to ZERO events" do
    assert InputParser.parse("\e[?2026;1$y") == []
  end

  test "every DECRQM value shape parses to zero events" do
    for value <- 0..4 do
      assert InputParser.parse("\e[?2026;#{value}$y") == []
    end
  end

  test "DA replies parse to zero events" do
    assert InputParser.parse("\e[?62;4c") == []
    assert InputParser.parse("\e[?1;2c") == []
    assert InputParser.parse("\e[>1;10;0c") == []
  end

  test "a cursor position report parses to zero events" do
    assert InputParser.parse("\e[12;40R") == []
  end

  test "echoed probe queries parse to zero events" do
    # the scanner leaks these as well-formed non-reply CSI (CAP-N-07);
    # the key parser must swallow them silently
    assert InputParser.parse("\e[>0q") == []
    assert InputParser.parse("\e[c") == []
    assert InputParser.parse("\e[?2026$p") == []
  end

  test "keystrokes around a reply survive; the reply does not" do
    events = InputParser.parse("l\e[?2026;1$ys\r")

    assert [
             %{type: :key, data: %{key: :char, char: "l"}},
             %{type: :key, data: %{key: :char, char: "s"}},
             %{type: :key, data: %{key: :enter}}
           ] = events
  end
end
