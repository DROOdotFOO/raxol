defmodule Raxol.Core.KeyboardNavigatorTest do
  use ExUnit.Case

  alias Raxol.Core.KeyboardNavigator.NavigatorServer

  setup do
    # Start a fresh navigator server for each test
    name = :"navigator_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      NavigatorServer.start_link(name: name, config: %{})

    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{server: name}
  end

  describe "configure/2" do
    test "updates navigation config", %{server: server} do
      NavigatorServer.configure(server, arrow_navigation: false, vim_keys: true)
      config = NavigatorServer.get_config(server)
      assert config.arrow_navigation == false
      assert config.vim_keys == true
    end

    test "preserves unmodified config keys", %{server: server} do
      NavigatorServer.configure(server, vim_keys: true)
      config = NavigatorServer.get_config(server)
      assert config.tab_navigation == true
      assert config.vim_keys == true
    end
  end

  describe "register_component_position/6" do
    test "stores component position in spatial map", %{server: server} do
      NavigatorServer.register_component_position(server, "btn1", 10, 20, 40, 5)
      spatial_map = NavigatorServer.get_spatial_map(server)
      assert Map.has_key?(spatial_map, "btn1")
      pos = spatial_map["btn1"]
      assert pos.x == 10
      assert pos.y == 20
      assert pos.width == 40
      assert pos.height == 5
      assert pos.center_x == 30
      assert pos.center_y == 22
    end

    test "overwrites existing position", %{server: server} do
      NavigatorServer.register_component_position(server, "btn1", 0, 0, 10, 10)

      NavigatorServer.register_component_position(
        server,
        "btn1",
        50,
        50,
        20,
        20
      )

      spatial_map = NavigatorServer.get_spatial_map(server)
      assert spatial_map["btn1"].x == 50
    end
  end

  describe "define_navigation_path/4" do
    test "stores explicit navigation path", %{server: server} do
      NavigatorServer.define_navigation_path(server, "btn1", :right, "btn2")
      paths = NavigatorServer.get_navigation_paths(server)
      assert get_in(paths, ["btn1", :right]) == "btn2"
    end

    test "multiple paths from same component", %{server: server} do
      NavigatorServer.define_navigation_path(server, "btn1", :right, "btn2")
      NavigatorServer.define_navigation_path(server, "btn1", :down, "btn3")
      paths = NavigatorServer.get_navigation_paths(server)
      assert get_in(paths, ["btn1", :right]) == "btn2"
      assert get_in(paths, ["btn1", :down]) == "btn3"
    end
  end

  describe "push_focus/2 and pop_focus/1" do
    test "push and pop maintain stack order", %{server: server} do
      NavigatorServer.push_focus(server, "modal1")
      NavigatorServer.push_focus(server, "modal2")

      state = NavigatorServer.get_state(server)
      assert state.focus_stack == ["modal2", "modal1"]
    end

    test "pop returns nil when stack is empty", %{server: server} do
      result = NavigatorServer.pop_focus(server)
      assert result == nil
    end
  end

  describe "register_to_group/3 and unregister_from_group/3" do
    test "registers component to a group", %{server: server} do
      NavigatorServer.register_to_group(server, "btn1", :toolbar)
      state = NavigatorServer.get_state(server)
      assert "btn1" in state.groups[:toolbar]
    end

    test "does not duplicate component in group", %{server: server} do
      NavigatorServer.register_to_group(server, "btn1", :toolbar)
      NavigatorServer.register_to_group(server, "btn1", :toolbar)
      state = NavigatorServer.get_state(server)
      assert length(state.groups[:toolbar]) == 1
    end

    test "unregisters component from group", %{server: server} do
      NavigatorServer.register_to_group(server, "btn1", :toolbar)
      NavigatorServer.register_to_group(server, "btn2", :toolbar)
      NavigatorServer.unregister_from_group(server, "btn1", :toolbar)
      state = NavigatorServer.get_state(server)
      refute "btn1" in state.groups[:toolbar]
      assert "btn2" in state.groups[:toolbar]
    end

    test "removes empty group", %{server: server} do
      NavigatorServer.register_to_group(server, "btn1", :toolbar)
      NavigatorServer.unregister_from_group(server, "btn1", :toolbar)
      state = NavigatorServer.get_state(server)
      refute Map.has_key?(state.groups, :toolbar)
    end
  end

  describe "reset/1" do
    test "resets all state to defaults", %{server: server} do
      NavigatorServer.configure(server, vim_keys: true)
      NavigatorServer.register_component_position(server, "btn1", 0, 0, 10, 10)
      NavigatorServer.push_focus(server, "modal1")
      NavigatorServer.register_to_group(server, "btn1", :toolbar)

      NavigatorServer.reset(server)
      state = NavigatorServer.get_state(server)

      assert state.config.vim_keys == false
      assert state.spatial_map == %{}
      assert state.focus_stack == []
      assert state.groups == %{}
      assert state.navigation_paths == %{}
    end
  end

  describe "get_state/1" do
    test "returns full state map", %{server: server} do
      state = NavigatorServer.get_state(server)
      assert is_map(state)
      assert Map.has_key?(state, :config)
      assert Map.has_key?(state, :spatial_map)
      assert Map.has_key?(state, :navigation_paths)
      assert Map.has_key?(state, :focus_stack)
      assert Map.has_key?(state, :groups)
    end
  end
end
