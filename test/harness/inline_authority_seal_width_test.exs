defmodule Raxol.Harness.InlineAuthoritySealWidthTest do
  @moduledoc """
  Pins the seal-path width contract documented on
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority.seal/2` ("Caller
  contract: line width, NOT enforced here"): a sealed line that is NOT
  display-width-truncated to the authority's `width` wraps onto the row
  below on a REAL terminal (autowrap/DECAWM is never turned off on the
  inline path), which `count_lines/1`'s `\r\n`-count-based `next_row`
  advance cannot see. The next seal then addresses the wrapped tail
  instead of a blank row, breaking seal-once (immutable-prefix) despite
  every byte `InlineAuthority` itself wrote being exactly what its caller
  asked for.

  This is CHARACTERIZATION, not a defect in this module's own byte
  emission -- it is a red test proving the documented caller contract is
  load-bearing: violate width-truncation upstream (as this test
  deliberately does) and history silently corrupts under real terminal
  semantics, with no exception raised anywhere in this module. If a
  future change adds width-awareness to `next_row` accounting, this test
  should start passing; when that happens, update the `seal/2` doc
  section accordingly rather than deleting this test.
  """
  use ExUnit.Case, async: false

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  # Narrow on purpose -- 10 columns makes a 15-column line's autowrap
  # deterministic and easy to reason about by hand.
  @width 10
  @height 10
  @footer_rows 2
  @region_top 8

  defp new_authority(opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, @width, @height, @footer_rows, opts)}
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp on_screen_history(raw_bytes) do
    emulator = SealOracle.replay(raw_bytes, width: @width, height: @height)
    SealOracle.history(emulator, @region_top)
  end

  test "an untruncated over-width line's wrapped tail is clobbered by the next seal" do
    {device, authority} = new_authority()

    # 15 printable columns against a width-10 authority -- the exact
    # violation the `seal/2` doc section describes. `count_lines/1` sees
    # ONE `\n`; a real (autowrap-on) terminal consumes TWO physical rows.
    over_width_line = String.duplicate("x", 15) <> "\r\n"
    authority = InlineAuthority.seal(authority, over_width_line)

    history_after_first_seal = on_screen_history(raw(device))

    # Sanity check the premise: the terminal really did wrap the line, so
    # the "sealed" content spans 2 physical rows, not the 1 `next_row`
    # credited it.
    assert length(history_after_first_seal) == 2,
           "premise check failed -- the over-width line did not wrap onto " <>
             "a second physical row; adjust @width/line length"

    _authority = InlineAuthority.seal(authority, "next\r\n")

    history_final = on_screen_history(raw(device))

    assert {:violation, idx, _expected, _actual} =
             SealOracle.immutable_prefix?(
               history_after_first_seal,
               history_final
             ),
           "expected the second seal to clobber the first line's wrapped " <>
             "tail (an immutable-prefix violation); history stayed intact " <>
             "instead -- has `next_row` accounting become width-aware? If " <>
             "so, update `seal/2`'s width-contract doc section and this test."

    # The wrapped TAIL row is what diverges -- the first physical row
    # (untouched by the second seal's CUP) must stay identical.
    assert idx == 1
  end
end
