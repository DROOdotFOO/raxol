defmodule Raxol.Terminal.CapabilitySliceScannerPropertyTest do
  @moduledoc """
  ReplyScanner fuzz: CAP-F-01 (totality), CAP-F-02 (conservation),
  CAP-F-03 (chunk-split invariance), CAP-F-08 (two-sided keystroke
  property). Deterministic seeded generators (see
  `Raxol.Test.CapabilitySliceGen` -- stream_data is not a raxol_terminal
  dependency); every failure reports the iteration to replay.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.ReplyScanner
  alias Raxol.Test.CapabilitySliceGen, as: Gen

  @runs 500

  test "CAP-F-01: totality -- scan/2 never raises on arbitrary bytes" do
    Enum.reduce(1..@runs, ReplyScanner.new(), fn i, carried_acc ->
      Gen.seed(i)
      noise = Gen.noise()

      # fresh accumulator
      {acc, leak} = ReplyScanner.scan(noise, ReplyScanner.new())
      assert %ReplyScanner{} = acc
      assert is_binary(leak)

      # and an accumulator carried across iterations (partials chain)
      {carried, leak2} = ReplyScanner.scan(noise, carried_acc)
      assert %ReplyScanner{} = carried
      assert is_binary(leak2)
      carried
    end)
  end

  test "CAP-F-02: conservation -- leak_free = input minus parsed replies" do
    for i <- 1..@runs do
      Gen.seed(i)
      {input, expected_leak} = Gen.interleave()

      {acc, leak} = ReplyScanner.scan(input, ReplyScanner.new())

      assert leak == expected_leak,
             "iteration #{i}: leak mismatch for #{inspect(input)}"

      # replies are complete in G-interleave: nothing may stay parked
      assert acc.partial == "", "iteration #{i}: unexpected partial"
    end
  end

  test "CAP-F-03: chunk-split invariance at an arbitrary index" do
    for i <- 1..@runs do
      Gen.seed(i)
      {input, _leak} = Gen.interleave()

      {acc_one, leak_one} = ReplyScanner.scan(input, ReplyScanner.new())

      split = :rand.uniform(byte_size(input) + 1) - 1
      <<part_a::binary-size(^split), part_b::binary>> = input

      {acc_a, leak_a} = ReplyScanner.scan(part_a, ReplyScanner.new())
      {acc_two, leak_b} = ReplyScanner.scan(part_b, acc_a)

      assert acc_two == acc_one,
             "iteration #{i}: acc diverged at split #{split}"

      assert leak_a <> leak_b == leak_one,
             "iteration #{i}: leak diverged at split #{split}"
    end
  end

  test "CAP-F-08: no-leak-of-replies AND no-eat-of-input" do
    for i <- 1..@runs do
      Gen.seed(i)
      keys_before = Gen.printable()
      {reply, kind} = Gen.reply()
      keys_after = Gen.printable()

      {_acc, leak} =
        ReplyScanner.scan(
          keys_before <> reply <> keys_after,
          ReplyScanner.new()
        )

      assert leak == keys_before <> keys_after,
             "iteration #{i} (#{kind}): keystrokes eaten or reply leaked"
    end
  end
end
