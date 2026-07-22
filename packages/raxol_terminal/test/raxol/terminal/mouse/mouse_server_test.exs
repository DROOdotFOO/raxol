defmodule Raxol.Terminal.Mouse.MouseServerTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Mouse.MouseServer

  setup do
    # Stop any existing MouseServer
    case Process.whereis(MouseServer) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, pid} = MouseServer.start_link(name: MouseServer)

    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "mouse creation" do
    test ~c"creates mouse context with default configuration" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()
      assert {:ok, mouse_state} = MouseServer.get_mouse_state(mouse_id)
      assert mouse_state.config.tracking == :all
      assert mouse_state.config.sgr_mode == true
      assert mouse_state.config.urxvt_mode == false
      assert mouse_state.config.pixel_mode == false
    end

    test ~c"creates mouse context with custom configuration" do
      config = %{
        tracking: :button,
        sgr_mode: false,
        urxvt_mode: true,
        pixel_mode: true
      }

      assert {:ok, mouse_id} = MouseServer.create_mouse(config)
      assert {:ok, mouse_state} = MouseServer.get_mouse_state(mouse_id)
      assert mouse_state.config.tracking == :button
      assert mouse_state.config.sgr_mode == false
      assert mouse_state.config.urxvt_mode == true
      assert mouse_state.config.pixel_mode == true
    end

    test ~c"first mouse context becomes active" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()
      assert {:ok, active_id} = MouseServer.get_active_mouse()
      assert mouse_id == active_id
    end
  end

  describe "mouse management" do
    test ~c"gets list of all mouse contexts" do
      assert {:ok, mouse1} = MouseServer.create_mouse()
      assert {:ok, mouse2} = MouseServer.create_mouse()
      assert {:ok, mouse3} = MouseServer.create_mouse()

      mice = MouseServer.get_mice()
      assert length(mice) == 3
      assert mouse1 in mice
      assert mouse2 in mice
      assert mouse3 in mice
    end

    test ~c"sets active mouse context" do
      assert {:ok, mouse1} = MouseServer.create_mouse()
      assert {:ok, mouse2} = MouseServer.create_mouse()

      assert :ok = MouseServer.set_active_mouse(mouse2)
      assert {:ok, active_id} = MouseServer.get_active_mouse()
      assert active_id == mouse2
    end

    test ~c"handles non-existent mouse context" do
      assert {:error, :mouse_not_found} = MouseServer.set_active_mouse(999)
      assert {:error, :mouse_not_found} = MouseServer.get_mouse_state(999)
    end
  end

  describe "mouse operations" do
    test ~c"processes mouse event" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()

      event = %{
        button: :left,
        action: :press,
        modifiers: [:shift],
        x: 100,
        y: 200
      }

      assert :ok = MouseServer.process_mouse_event(mouse_id, event)
      assert {:ok, mouse_state} = MouseServer.get_mouse_state(mouse_id)
      assert mouse_state.position == {100, 200}
      assert mouse_state.button_state == %{left: :pressed}
      assert mouse_state.modifiers == [:shift]
    end

    test ~c"gets mouse position" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()

      event = %{
        button: :left,
        action: :press,
        modifiers: [],
        x: 150,
        y: 250
      }

      assert :ok = MouseServer.process_mouse_event(mouse_id, event)
      assert {:ok, {150, 250}} = MouseServer.get_mouse_position(mouse_id)
    end

    test ~c"gets mouse button state" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()

      event = %{
        button: :right,
        action: :press,
        modifiers: [],
        x: 100,
        y: 200
      }

      assert :ok = MouseServer.process_mouse_event(mouse_id, event)
      assert {:ok, button_state} = MouseServer.get_mouse_button_state(mouse_id)
      assert button_state == %{right: :pressed}
    end

    test ~c"closes mouse context" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()
      assert :ok = MouseServer.close_mouse(mouse_id)
      assert {:error, :mouse_not_found} = MouseServer.get_mouse_state(mouse_id)
    end

    test ~c"closing active mouse updates active mouse" do
      assert {:ok, mouse1} = MouseServer.create_mouse()
      assert {:ok, mouse2} = MouseServer.create_mouse()

      assert :ok = MouseServer.set_active_mouse(mouse1)
      assert :ok = MouseServer.close_mouse(mouse1)
      assert {:ok, active_id} = MouseServer.get_active_mouse()
      assert active_id == mouse2
    end
  end

  describe "mouse configuration" do
    test ~c"updates mouse configuration" do
      assert {:ok, mouse_id} = MouseServer.create_mouse()

      new_config = %{
        tracking: :drag,
        sgr_mode: false,
        urxvt_mode: true
      }

      assert :ok = MouseServer.update_mouse_config(mouse_id, new_config)
      assert {:ok, mouse_state} = MouseServer.get_mouse_state(mouse_id)
      assert mouse_state.config.tracking == :drag
      assert mouse_state.config.sgr_mode == false
      assert mouse_state.config.urxvt_mode == true
    end

    test ~c"updates mouse manager configuration" do
      config = %{
        max_mice: 5,
        default_tracking: :drag,
        default_sgr_mode: false,
        default_urxvt_mode: true,
        default_pixel_mode: true
      }

      assert :ok = MouseServer.update_config(config)
    end
  end

  describe "cleanup" do
    test ~c"cleans up all mouse contexts" do
      assert {:ok, _mouse1} = MouseServer.create_mouse()
      assert {:ok, _mouse2} = MouseServer.create_mouse()

      assert :ok = MouseServer.cleanup()
      assert MouseServer.get_mice() == []
      assert {:error, :no_active_mouse} = MouseServer.get_active_mouse()
    end
  end

  describe "error handling" do
    test ~c"handles invalid mouse operations" do
      assert {:error, :mouse_not_found} = MouseServer.set_active_mouse(999)
      assert {:error, :mouse_not_found} = MouseServer.get_mouse_state(999)

      assert {:error, :mouse_not_found} =
               MouseServer.update_mouse_config(999, %{})

      assert {:error, :mouse_not_found} = MouseServer.close_mouse(999)

      assert {:error, :mouse_not_found} =
               MouseServer.process_mouse_event(999, %{})

      assert {:error, :mouse_not_found} = MouseServer.get_mouse_position(999)

      assert {:error, :mouse_not_found} =
               MouseServer.get_mouse_button_state(999)
    end
  end
end
