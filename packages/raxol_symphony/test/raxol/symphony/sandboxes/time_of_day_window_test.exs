defmodule Raxol.Symphony.Sandboxes.TimeOfDayWindowTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox
  alias Raxol.Symphony.Sandboxes.TimeOfDayWindow

  doctest TimeOfDayWindow

  defp authorize(sb, action \\ :turn) do
    Sandbox.authorize(sb, action, %{turn: 1, issue_id: "iss-1"}, %{})
  end

  describe "allows?/2 -- contiguous daytime window" do
    test "true inside the window" do
      sb = %TimeOfDayWindow{start_hour: 9, end_hour: 17}
      assert TimeOfDayWindow.allows?(sb, 9)
      assert TimeOfDayWindow.allows?(sb, 12)
      assert TimeOfDayWindow.allows?(sb, 16)
    end

    test "false at and after end_hour (exclusive)" do
      sb = %TimeOfDayWindow{start_hour: 9, end_hour: 17}
      refute TimeOfDayWindow.allows?(sb, 17)
      refute TimeOfDayWindow.allows?(sb, 20)
      refute TimeOfDayWindow.allows?(sb, 23)
    end

    test "false before start_hour" do
      sb = %TimeOfDayWindow{start_hour: 9, end_hour: 17}
      refute TimeOfDayWindow.allows?(sb, 0)
      refute TimeOfDayWindow.allows?(sb, 8)
    end
  end

  describe "allows?/2 -- window crossing midnight" do
    test "true after start_hour (evening half)" do
      sb = %TimeOfDayWindow{start_hour: 21, end_hour: 6}
      assert TimeOfDayWindow.allows?(sb, 21)
      assert TimeOfDayWindow.allows?(sb, 22)
      assert TimeOfDayWindow.allows?(sb, 23)
    end

    test "true before end_hour (morning half)" do
      sb = %TimeOfDayWindow{start_hour: 21, end_hour: 6}
      assert TimeOfDayWindow.allows?(sb, 0)
      assert TimeOfDayWindow.allows?(sb, 3)
      assert TimeOfDayWindow.allows?(sb, 5)
    end

    test "false during the daytime gap" do
      sb = %TimeOfDayWindow{start_hour: 21, end_hour: 6}
      refute TimeOfDayWindow.allows?(sb, 6)
      refute TimeOfDayWindow.allows?(sb, 12)
      refute TimeOfDayWindow.allows?(sb, 20)
    end
  end

  describe "Sandbox protocol -- :turn action" do
    test "allows :turn when current hour falls in the window" do
      # The Sandbox is only `allows?: true` when `start_hour < end_hour`
      # AND `hour` is in `[start, end)`, OR when the window crosses
      # midnight. To make a window that definitely contains "now"
      # without relying on test execution time, construct one that
      # spans 23 hours of midnight-crossing: start=now+23, end=now+1.
      now =
        TimeOfDayWindow.current_hour(%TimeOfDayWindow{
          start_hour: 0,
          end_hour: 23,
          timezone: "Etc/UTC"
        })

      start_h = rem(now + 23, 24)
      end_h = rem(now + 1, 24)

      sb = %TimeOfDayWindow{
        start_hour: start_h,
        end_hour: end_h,
        timezone: "Etc/UTC"
      }

      assert :ok = authorize(sb)
    end

    test "denies :turn when outside the window" do
      now = TimeOfDayWindow.current_hour(%TimeOfDayWindow{start_hour: 0, end_hour: 24, timezone: "Etc/UTC"})
      # Construct a tiny window that definitely does NOT contain `now`:
      # 2 hours far away from `now`.
      start_h = rem(now + 6, 24)
      end_h = rem(now + 8, 24)
      sb = %TimeOfDayWindow{start_hour: start_h, end_hour: end_h, timezone: "Etc/UTC"}

      assert {:deny, :outside_window} = authorize(sb)
    end

    test "abstains for non-:turn actions" do
      # Window that would deny :turn if reached.
      now = TimeOfDayWindow.current_hour(%TimeOfDayWindow{start_hour: 0, end_hour: 24, timezone: "Etc/UTC"})
      start_h = rem(now + 6, 24)
      end_h = rem(now + 8, 24)
      sb = %TimeOfDayWindow{start_hour: start_h, end_hour: end_h, timezone: "Etc/UTC"}

      # Other dimensions pass.
      assert :ok = authorize(sb, :shell)
      assert :ok = authorize(sb, :send_agent)
      assert :ok = authorize(sb, :async)
    end
  end

  describe "current_hour/1" do
    test "returns 0..23 for UTC" do
      sb = %TimeOfDayWindow{start_hour: 9, end_hour: 17, timezone: "Etc/UTC"}
      hour = TimeOfDayWindow.current_hour(sb)
      assert hour >= 0 and hour < 24
    end

    test "falls back to UTC if tz shifting fails for a bogus timezone" do
      sb = %TimeOfDayWindow{
        start_hour: 9,
        end_hour: 17,
        timezone: "Not/A_Real_Tz"
      }

      hour = TimeOfDayWindow.current_hour(sb)
      assert hour >= 0 and hour < 24
    end
  end
end
