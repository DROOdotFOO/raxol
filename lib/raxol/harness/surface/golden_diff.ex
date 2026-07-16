defmodule Raxol.Harness.Surface.GoldenDiff do
  @moduledoc """
  A pure, small diff formatter for the byte-golden snapshot tests
  (`test/harness/golden_snapshot_test.exs`). Golden byte streams are
  tens of kilobytes; a raw `assert rendered == golden` on a mismatch
  would dump the whole binary into the test failure message. This module
  exists so a divergence reports exactly one thing: the first byte
  offset the two streams disagree at, plus a small, escaped context
  window around it -- never the full streams.

  Written RED-FIRST (see `test/harness/golden_diff_test.exs`, which was
  authored and run against a not-yet-existing module before this file
  was written, per this proposal's red-first discipline for pure diff
  logic).
  """

  # Bytes of context captured on EACH side of the divergence offset.
  @context_bytes 32

  @doc """
  Compares `expected` (the checked-in golden) against `actual` (a fresh
  render). Returns `:ok` on byte equality, or `{:diverged, offset,
  report}` where `offset` is the first byte index the two binaries
  disagree at (or, for a proper-prefix pair, `min(byte_size(expected),
  byte_size(actual))` -- the point where the shorter side simply ends)
  and `report` is a bounded, human-readable string.
  """
  @spec compare(binary(), binary()) ::
          :ok | {:diverged, non_neg_integer(), String.t()}
  def compare(expected, actual)
      when is_binary(expected) and is_binary(actual) do
    if expected == actual do
      :ok
    else
      offset = first_divergence(expected, actual)
      {:diverged, offset, report(expected, actual, offset)}
    end
  end

  # The first byte index at which `expected` and `actual` differ. The
  # length of the longest common prefix IS that index by definition -- and
  # for a proper-prefix pair (one binary is an exact prefix of the other)
  # it naturally bottoms out at `min(byte_size(expected),
  # byte_size(actual))`, matching the documented proper-prefix contract
  # above. One BIF call, no per-byte walk.
  defp first_divergence(expected, actual) do
    :binary.longest_common_prefix([expected, actual])
  end

  defp report(expected, actual, offset) do
    """
    golden byte mismatch at offset #{offset}
    expected: #{byte_size(expected)} bytes total
    actual:   #{byte_size(actual)} bytes total

    expected context (bytes #{window_start(expected, offset)}..#{window_stop(expected, offset)}):
    #{inspect(window(expected, offset))}

    actual context (bytes #{window_start(actual, offset)}..#{window_stop(actual, offset)}):
    #{inspect(window(actual, offset))}
    """
  end

  defp window_start(_binary, offset), do: max(offset - @context_bytes, 0)

  defp window_stop(binary, offset),
    do: min(offset + @context_bytes, byte_size(binary))

  # Up to `@context_bytes` before and after `offset`, escaped via
  # `inspect/1` (renders `\e`, `\r`, `\n`, and other non-printable bytes as
  # visible escapes) so a reviewer reading the report sees the actual
  # control sequences at play, never a raw binary dump. Bounded to
  # `2 * @context_bytes` (64) raw bytes per side, comfortably under the
  # ~200-byte-per-side ceiling this module's own moduledoc promises.
  defp window(binary, offset) do
    start = window_start(binary, offset)
    stop = window_stop(binary, offset)
    len = max(stop - start, 0)
    binary_part(binary, start, len)
  end
end
