defmodule Raxol.Core.ColorSystemTest do
  # The color system server is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Core.Accessibility.PreferenceManager
  alias Raxol.Core.ColorSystem
  alias Raxol.Style.Colors.System.ColorSystemServer

  # A server left running by an earlier test would hide a missing start.
  setup do
    if pid = Process.whereis(ColorSystemServer), do: GenServer.stop(pid)
    :ok
  end

  describe "server naming" do
    test "the theme API starts and reaches the server on first use" do
      assert :ok = ColorSystem.init(:default)
      assert ColorSystemServer.get_current_theme_name() == :default
      assert {:ok, _theme} = ColorSystem.get_current_theme()

      GenServer.stop(ColorSystemServer)
    end

    test "a high contrast preference change reaches the running server" do
      start_supervised!(ColorSystemServer)
      refute ColorSystemServer.get_high_contrast()

      PreferenceManager.maybe_notify_color_system(:high_contrast, true)

      assert ColorSystemServer.get_high_contrast()
    end
  end
end
