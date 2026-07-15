t0_root = Path.expand("../../scripts/harness/t0", __DIR__)
Code.require_file("ringb/boot.ex", t0_root)
T0.RingB.Boot.require_all!(t0_root)

defmodule Raxol.Harness.RingBGhosttyTest do
  @moduledoc """
  Unit RB, Ghostty -- a documented skip, not a driver bug. Confirmed live
  via `sdef` that this Ghostty build's AppleScript dictionary has no
  `get text`/`contents`/`history` command (it DOES have `new window`,
  `input text`, `send key` -- driving it is possible, capturing it is
  not) and the `ghostty` CLI has no `cli get-text` equivalent. This test
  pins that every capability-returning callback is `{:error,
  :unsupported}` and that the runner records it as a screenshot residual
  rather than silently omitting or guessing at a verdict.
  """

  use ExUnit.Case, async: true

  alias T0.RingB.Drivers.Ghostty

  @moduletag :ring_b
  @moduletag :macos_gui
  @moduletag :unix_only

  test "every capture/interaction primitive is unsupported (documented, not a driver bug)" do
    assert Ghostty.spawn_session([]) == {:error, :unsupported}
    assert Ghostty.run_command(:na, "echo hi") == {:error, :unsupported}
    assert Ghostty.mark_cursor(:na, "#") == {:error, :unsupported}
    assert Ghostty.get_scrollback(:na) == {:error, :unsupported}
    assert Ghostty.get_visible(:na) == {:error, :unsupported}
    assert Ghostty.get_cursor(:na) == {:error, :unsupported}
    assert Ghostty.resize(:na, 80, 24) == {:error, :unsupported}
    assert Ghostty.close(:na) == :ok
    refute Ghostty.still_open?(:na)
  end

  test "capture_method reports human_eye (Ring C, screenshot residual)" do
    assert Ghostty.capture_method() == "human_eye"
  end
end
