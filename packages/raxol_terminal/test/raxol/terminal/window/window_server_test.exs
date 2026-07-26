defmodule Raxol.Terminal.Window.WindowServerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Window.Manager
  alias Raxol.Terminal.Window.Manager.WindowManagerServer, as: Server

  setup do
    # Stop any existing WindowManagerServer
    case Process.whereis(Server) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Start fresh WindowManagerServer
    {:ok, pid} = Server.start_link(name: Server)

    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{pid: pid}
  end

  describe "window creation" do
    test "creates a window with default options", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert window.title == ""
      assert window.size == {80, 24}
      assert window.position == {0, 0}
      # Window state is tracked separately by WindowManagerServer
      assert window.state in [:active, :inactive]
    end

    test "creates a window with custom options", %{pid: _pid} do
      {:ok, window} = Manager.create_window(100, 30)
      assert window.size == {100, 30}
    end
  end

  describe "window splitting" do
    test "splits window horizontally", %{pid: _pid} do
      {:ok, parent} = Manager.create_window(80, 24)
      {:ok, child_id} = Manager.split_window(parent.id, :horizontal)

      assert {:ok, parent} = Manager.get_window(parent.id)
      assert {:ok, child} = Manager.get_window(child_id)

      assert parent.children == [child_id]
      assert child.parent == parent.id
    end

    test "splits window vertically", %{pid: _pid} do
      {:ok, parent} = Manager.create_window(80, 24)
      {:ok, child_id} = Manager.split_window(parent.id, :vertical)

      assert {:ok, parent} = Manager.get_window(parent.id)
      assert {:ok, child} = Manager.get_window(child_id)

      assert parent.children == [child_id]
      assert child.parent == parent.id
    end

    test "fails to split non-existent window", %{pid: _pid} do
      assert {:error, :window_not_found} =
               Manager.split_window("nonexistent", :horizontal)
    end
  end

  describe "window operations" do
    test "sets window title", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert {:ok, updated_window} = Manager.set_title(window.id, "New Title")
      assert updated_window.title == "New Title"
    end

    test "sets window icon name", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      # set_icon_name returns window_id for compatibility
      assert window.id == Manager.set_icon_name(window.id, "New Icon")
    end

    test "resizes window", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert {:ok, updated_window} = Manager.resize(window.id, 100, 30)
      assert updated_window.size == {100, 30}
    end

    test "moves window", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert {:ok, updated_window} = Manager.move(window.id, 10, 20)
      assert updated_window.position == {10, 20}
    end

    test "sets window stacking order", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert :ok = Manager.set_stacking_order(window.id, :front)
    end
  end

  describe "window focus" do
    test "sets active window", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert :ok = Manager.set_active_window(window.id)
      assert {:ok, active_window} = Manager.get_active_window()
      assert active_window.id == window.id
    end

    test "fails to set active window for non-existent window", %{pid: _pid} do
      assert {:error, :not_found} =
               Manager.set_active_window("nonexistent")
    end
  end

  describe "window cleanup" do
    test "destroys a window", %{pid: _pid} do
      {:ok, window} = Manager.create_window(80, 24)
      assert :ok = Manager.destroy_window(window.id)
      assert {:error, :not_found} = Manager.get_window(window.id)
    end

    test "fails to destroy non-existent window", %{pid: _pid} do
      assert {:error, :not_found} = Manager.destroy_window("nonexistent")
    end
  end

  describe "configuration" do
    test "updates window manager configuration", %{pid: _pid} do
      new_config = %{
        window_size: {100, 30}
      }

      assert :ok = Manager.update_config(new_config)
    end
  end
end
