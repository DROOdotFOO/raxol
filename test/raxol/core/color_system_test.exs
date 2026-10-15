defmodule Raxol.Core.ColorSystemTest do
  # The color system server is a singleton registered under a global name.
  use ExUnit.Case, async: false
  @moduletag :capture_log

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
  end
end
