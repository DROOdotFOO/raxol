defmodule Raxol.Harness.Surface.GoldenDiffTest do
  @moduledoc """
  Unit tests for `Raxol.Harness.Surface.GoldenDiff.compare/2` -- the pure
  diff formatter the byte-golden snapshot tests
  (`test/harness/golden_snapshot_test.exs`) use to report a mismatch
  without ever dumping a raw 40KB binary into a test failure message.

  Written RED-FIRST, before `Raxol.Harness.Surface.GoldenDiff` exists
  (see the surrounding proposal's red-first discipline for this file):
  every test here fails with `UndefinedFunctionError` /
  `Raxol.Harness.Surface.GoldenDiff.compare/2 is undefined` on a first
  run, by design.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface.GoldenDiff

  describe "compare/2" do
    test "equal binaries return :ok" do
      assert GoldenDiff.compare("identical bytes", "identical bytes") == :ok
    end

    test "byte-for-byte equal binaries built differently still return :ok" do
      a = <<1, 2, 3>> <> <<4, 5, 6>>
      b = <<1, 2, 3, 4, 5, 6>>
      assert GoldenDiff.compare(a, b) == :ok
    end

    test "divergence mid-binary reports the correct offset and both escaped context windows" do
      prefix = String.duplicate("x", 20)
      expected = prefix <> "\e[2J" <> "AAAA" <> String.duplicate("y", 20)
      actual = prefix <> "\e[2J" <> "BBBB" <> String.duplicate("y", 20)

      # the two binaries first differ where "AAAA"/"BBBB" begin, right
      # after the shared prefix + ESC sequence.
      expected_offset = byte_size(prefix) + byte_size("\e[2J")

      assert {:diverged, offset, report} = GoldenDiff.compare(expected, actual)
      assert offset == expected_offset

      assert report =~ "#{offset}"
      # both sides' context windows are present, escaped (never a raw
      # ESC byte dumped into the report -- inspect/1 renders it as \e).
      assert report =~ "expected"
      assert report =~ "actual"
      assert report =~ "\\e"
      assert report =~ "AAAA"
      assert report =~ "BBBB"
    end

    test "proper prefix -- actual shorter than expected -- offset is the shorter length" do
      expected = "hello world, this is the full expected content"
      actual = "hello world, this is the "

      assert {:diverged, offset, report} = GoldenDiff.compare(expected, actual)
      assert offset == byte_size(actual)
      assert report =~ "#{byte_size(expected)}"
      assert report =~ "#{byte_size(actual)}"
    end

    test "proper prefix -- actual longer than expected -- offset is the shorter length" do
      expected = "short"
      actual = "short and then some more trailing content"

      assert {:diverged, offset, report} = GoldenDiff.compare(expected, actual)
      assert offset == byte_size(expected)
      assert report =~ "#{byte_size(expected)}"
      assert report =~ "#{byte_size(actual)}"
    end

    test "report stays bounded even for multi-KB binaries diverging near the start" do
      expected = "A" <> String.duplicate("z", 5000)
      actual = "B" <> String.duplicate("z", 5000)

      assert {:diverged, offset, report} = GoldenDiff.compare(expected, actual)
      assert offset == 0
      assert byte_size(report) < 1024
    end

    test "report stays bounded even for multi-KB binaries diverging near the end" do
      shared = String.duplicate("z", 5000)
      expected = shared <> "Atail"
      actual = shared <> "Btail"

      assert {:diverged, offset, report} = GoldenDiff.compare(expected, actual)
      assert offset == byte_size(shared)
      assert byte_size(report) < 1024
    end
  end
end
