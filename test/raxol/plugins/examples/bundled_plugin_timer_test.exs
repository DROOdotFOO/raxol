defmodule Raxol.Plugins.Examples.BundledPluginTimerTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.{
    PluginLifecycle,
    PluginRuntime,
    PluginSupervisor
  }

  alias Raxol.Plugins.Examples.{
    GitIntegrationPlugin,
    RainbowThemePlugin,
    StatusLinePlugin
  }

  test "rainbow rotation timer returns to its stable runtime" do
    start_supervised!(PluginSupervisor)
    start_supervised!(PluginLifecycle)

    config = %{
      animation_speed: 1,
      color_palette: [:red, :green],
      auto_rotate: true,
      rotation_interval: 1
    }

    assert :ok =
             PluginLifecycle.load(
               :rainbow_timer_test,
               RainbowThemePlugin,
               config
             )

    assert {:ok, _state} = PluginRuntime.invoke(:rainbow_timer_test, :on_load)

    assert_eventually(fn ->
      {:ok, state} = PluginLifecycle.get_state(:rainbow_timer_test)
      state.current_index > 0
    end)

    assert {:ok, _state} = PluginRuntime.invoke(:rainbow_timer_test, :on_unload)
    assert :ok = PluginLifecycle.unload(:rainbow_timer_test)
  end

  test "status-line update timer is handled by its manager process" do
    assert {:ok, pid} =
             StatusLinePlugin.start_link(
               update_interval: 10,
               show_time: false,
               show_mode: false,
               show_git: false,
               show_resources: false,
               theme: "default"
             )

    GenServer.cast(pid, {:set_emulator, self()})
    assert_receive {:render_status_line, _content, "bottom"}, 500
    GenServer.stop(pid)
  end

  test "git refresh interval is handled by its manager process" do
    assert {:ok, pid} =
             GitIntegrationPlugin.start_link(
               auto_refresh: true,
               refresh_interval: 1_000
             )

    assert :ok = :sys.statistics(pid, true)

    assert_eventually(
      fn ->
        {:ok, statistics} = :sys.statistics(pid, :get)
        Keyword.fetch!(statistics, :messages_in) > 0
      end,
      400
    )

    GenServer.stop(pid)
  end

  defp assert_eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk("expected timer message to be handled")

      true ->
        receive do
        after
          5 -> assert_eventually(check, attempts - 1)
        end
    end
  end
end
