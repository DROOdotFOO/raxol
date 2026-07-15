defmodule Raxol.Terminal.CapabilitySliceParserPropertyTest do
  @moduledoc """
  InputParser fuzz over reply shapes: CAP-F-05 (a DECRQM/CPR/DA reply
  never yields a key/char event -- locks the `input_parser.ex`
  consume-unmapped path) and CAP-F-06 (totality with a reply prefix).

  CPR is generated with row >= 2: `CSI 1 ; <n> R` is byte-identical to
  xterm's modified-F3 key encoding, so the key parser *cannot*
  distinguish them -- which is why the ReplyScanner consumes CPR before
  the key parser during probe windows (see the scanner suite).
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Test.CapabilitySliceGen, as: Gen

  @runs 500

  test "CAP-F-05: DECRQM/CPR/DA replies never become key events" do
    for i <- 1..@runs do
      Gen.seed(i)

      {reply, kind} =
        case :rand.uniform(3) do
          1 -> Gen.decrqm()
          2 -> Gen.da1()
          3 -> Gen.cpr()
        end

      events = InputParser.parse(reply)

      key_events = Enum.filter(events, &(&1.type == :key))

      assert key_events == [],
             "iteration #{i} (#{kind}): #{inspect(reply)} leaked " <>
               "#{inspect(key_events)}"
    end
  end

  test "CAP-F-06: parse(reply <> noise) never raises" do
    for i <- 1..@runs do
      Gen.seed(i)
      {reply, _kind} = Gen.reply()
      noise = Gen.noise(64)

      events = InputParser.parse(reply <> noise)
      assert is_list(events), "iteration #{i}"
    end
  end
end
