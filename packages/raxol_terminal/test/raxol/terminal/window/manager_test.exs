defmodule Raxol.Terminal.Window.ManagerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.{Config, Window.Manager}

  setup do
    # Stop any existing server first to avoid conflicts
    case Process.whereis(Raxol.Terminal.Window.Manager.WindowManagerServer) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5000)
    end

    start_supervised!(
      {Raxol.Terminal.Window.Manager.WindowManagerServer,
       [name: Raxol.Terminal.Window.Manager.WindowManagerServer]}
    )

    :ok
  end

  describe "window creation" do
    test "creates a window with config" do
      config = %Config{width: 80, height: 24}
      assert {:ok, window} = Manager.create_window(config)
      assert window.width == 80
      assert window.height == 24
    end

    test "creates a window with dimensions" do
      assert {:ok, window} = Manager.create_window(100, 50)
      assert window.width == 100
      assert window.height == 50
    end
  end

  describe "window management" do
    setup do
      {:ok, window} = Manager.create_window(80, 24)
      %{window: window}
    end

    test "destroys a window", %{window: window} do
      assert :ok = Manager.destroy_window(window.id)
      assert {:error, :not_found} = Manager.get_window(window.id)
    end

    test "gets a window by ID", %{window: window} do
      assert {:ok, retrieved} = Manager.get_window(window.id)
      assert retrieved.id == window.id
    end

    test "lists all windows", %{window: window} do
      {:ok, window2} = Manager.create_window(80, 24)
      assert {:ok, windows} = Manager.list_windows()
      assert length(windows) == 2
      assert Enum.any?(windows, &(&1.id == window.id))
      assert Enum.any?(windows, &(&1.id == window2.id))
    end

    test "sets and gets active window", %{window: window} do
      assert :ok = Manager.set_active_window(window.id)
      assert {:ok, active} = Manager.get_active_window()
      assert active.id == window.id
    end
  end

  describe "window properties" do
    setup do
      {:ok, window} = Manager.create_window(80, 24)
      %{window: window}
    end

    test "debug window ID and function dispatch", %{window: window} do
      # Debug: Check what type window.id is
      IO.puts("Window ID value: #{inspect(window.id)}")
      IO.puts("Window ID is string: #{is_binary(window.id)}")
      IO.puts("Window ID is pid: #{is_pid(window.id)}")

      # Try calling the function directly to see what happens
      result = Manager.set_window_title(window.id, "New Title")
      IO.puts("Function result: #{inspect(result)}")

      # This should help us understand what's happening
      assert true
    end

    test "updates window title", %{window: window} do
      assert {:ok, updated} = Manager.set_window_title(window.id, "New Title")
      assert updated.title == "New Title"
    end

    test "updates window position", %{window: window} do
      assert {:ok, updated} = Manager.set_window_position(window.id, 100, 200)
      assert updated.position == {100, 200}
    end

    test "updates window size", %{window: window} do
      assert {:ok, updated} = Manager.set_window_size(window.id, 120, 40)
      assert updated.size == {120, 40}
    end

    test "updates window state", %{window: window} do
      assert {:ok, updated} = Manager.set_window_state(window.id, :maximized)
      assert updated.state == :maximized
    end
  end

  describe "window hierarchy" do
    setup do
      {:ok, parent} = Manager.create_window(80, 24)
      %{parent: parent}
    end

    test "creates child window", %{parent: parent} do
      config = %Config{width: 60, height: 20}
      assert {:ok, child} = Manager.create_child_window(parent.id, config)

      # Verify parent-child relationship
      assert {:ok, updated_parent} = Manager.get_window(parent.id)
      assert child.id in updated_parent.children
      assert child.parent == parent.id
    end

    test "gets child windows", %{parent: parent} do
      config = %Config{width: 60, height: 20}
      {:ok, child1} = Manager.create_child_window(parent.id, config)
      {:ok, child2} = Manager.create_child_window(parent.id, config)

      assert {:ok, children} = Manager.get_child_windows(parent.id)
      assert length(children) == 2
      assert Enum.any?(children, &(&1.id == child1.id))
      assert Enum.any?(children, &(&1.id == child2.id))
    end

    test "gets parent window", %{parent: parent} do
      config = %Config{width: 60, height: 20}
      {:ok, child} = Manager.create_child_window(parent.id, config)

      assert {:ok, retrieved_parent} = Manager.get_parent_window(child.id)
      assert retrieved_parent.id == parent.id
    end

    test "returns error for window without parent" do
      {:ok, window} = Manager.create_window(80, 24)
      assert {:error, :no_parent} = Manager.get_parent_window(window.id)
    end
  end
end
