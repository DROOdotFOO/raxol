defmodule Raxol.Core.UXRefinementTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Mox

  alias Raxol.Core.UXRefinement, as: UXR
  alias Raxol.Core.UXRefinement.UxServer, as: Server

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    # Set up default mocks - use stub_with for global access
    stub(Raxol.Mocks.AccessibilityMock, :enable, fn _opts, _prefs -> :ok end)
    stub(Raxol.Mocks.AccessibilityMock, :disable, fn _prefs -> :ok end)
    stub(Raxol.Mocks.AccessibilityMock, :register_element_metadata, fn _id, _metadata -> :ok end)
    stub(Raxol.Mocks.FocusManagerMock, :register_focus_change_handler, fn _handler -> :ok end)
    stub(Raxol.Mocks.FocusManagerMock, :unregister_focus_change_handler, fn _handler -> :ok end)

    # Ensure server is stopped before each test
    case Process.whereis(Server) do
      nil -> :ok
      pid ->
        GenServer.stop(pid)
        # Wait for process to fully terminate
        Process.sleep(10)
    end

    # Ensure EventManager is stopped and started fresh
    Raxol.Core.Events.EventManager.cleanup()
    {:ok, _em_pid} = Raxol.Core.Events.EventManager.start_link(name: Raxol.Core.Events.EventManager)

    # Start fresh server for each test
    {:ok, pid} = Server.start_link(name: Server)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      Raxol.Core.Events.EventManager.cleanup()
    end)

    {:ok, server: pid}
  end

  describe "init/0" do
    test "initializes the UX refinement system" do
      assert :ok = UXR.init()
    end
  end

  describe "feature management" do
    test "enables and checks features" do
      assert :ok = UXR.init()

      # Initially no features enabled
      refute UXR.feature_enabled?(:hints)
      refute UXR.feature_enabled?(:focus_management)

      # Enable hints feature
      assert :ok = UXR.enable_feature(:hints)
      assert UXR.feature_enabled?(:hints)

      # Enable focus management
      assert :ok = UXR.enable_feature(:focus_management)
      assert UXR.feature_enabled?(:focus_management)
    end

    test "disables features" do
      assert :ok = UXR.init()
      assert :ok = UXR.enable_feature(:hints)
      assert UXR.feature_enabled?(:hints)

      assert :ok = UXR.disable_feature(:hints)
      refute UXR.feature_enabled?(:hints)
    end

    test "handles unknown features" do
      assert :ok = UXR.init()
      assert {:error, "Unknown feature: unknown_feature"} =
        UXR.enable_feature(:unknown_feature)
    end

    test "prevents disabling events when dependencies exist" do
      assert :ok = UXR.init()
      assert :ok = UXR.enable_feature(:accessibility)
      assert :ok = UXR.enable_feature(:events)

      assert {:error, _} = UXR.disable_feature(:events)
    end
  end

  describe "hint management" do
    setup do
      UXR.init()
      UXR.enable_feature(:hints)
      :ok
    end

    test "registers and retrieves simple hints" do
      assert :ok = UXR.register_hint("button1", "Click me")
      assert "Click me" = UXR.get_hint("button1")
    end

    test "registers and retrieves component hints with levels" do
      hint_info = %{
        basic: "Search for content",
        detailed: "Use keywords to search",
        examples: "Try 'settings' or 'help'",
        shortcuts: [{"Enter", "Execute search"}]
      }

      assert :ok = UXR.register_component_hint("search", hint_info)

      assert "Search for content" = UXR.get_component_hint("search", :basic)
      assert "Use keywords to search" = UXR.get_component_hint("search", :detailed)
      assert "Try 'settings' or 'help'" = UXR.get_component_hint("search", :examples)
      assert [{"Enter", "Execute search"}] = UXR.get_component_shortcuts("search")
    end

    test "returns nil for non-existent hints" do
      assert nil == UXR.get_hint("nonexistent")
    end

    test "falls back to basic hint when level not available" do
      UXR.register_component_hint("button", %{basic: "Click"})
      assert "Click" = UXR.get_component_hint("button", :detailed)
    end
  end

  describe "accessibility metadata" do
    setup do
      UXR.init()
      UXR.enable_feature(:accessibility)
      :ok
    end

    test "registers and retrieves accessibility metadata" do
      metadata = %{label: "Search Button", role: "button", description: "Opens search"}

      assert :ok = UXR.register_accessibility_metadata("search_btn", metadata)

      retrieved = UXR.get_accessibility_metadata("search_btn")
      assert retrieved[:label] == "Search Button"
      assert retrieved[:role] == "button"
    end

    test "returns nil when accessibility not enabled" do
      UXR.disable_feature(:accessibility)
      assert nil == UXR.get_accessibility_metadata("any_component")
    end
  end

  describe "state isolation" do
    test "maintains independent state per server instance" do
      # Start a second server without a name
      {:ok, server2} = GenServer.start_link(Server, :ok, [])

      # Initialize both
      assert :ok = UXR.init()
      assert :ok = Server.init_system(server2)

      # Enable feature on default server
      assert :ok = UXR.enable_feature(:hints)
      assert UXR.feature_enabled?(:hints)

      # Check that server2 doesn't have the feature
      refute Server.feature_enabled?(server2, :hints)

      # Enable on server2 with proper user_prefs
      user_prefs = %{}
      assert :ok = Server.enable_feature(server2, :hints, [], user_prefs)
      assert Server.feature_enabled?(server2, :hints)

      # Clean up
      GenServer.stop(server2)
    end
  end

  describe "concurrent operations" do
    test "handles concurrent hint registration" do
      UXR.init()
      UXR.enable_feature(:hints)

      # Spawn multiple processes to register hints
      tasks = for i <- 1..100 do
        Task.async(fn ->
          UXR.register_hint("component_#{i}", "Hint #{i}")
        end)
      end

      # Wait for all to complete
      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify all hints were registered
      for i <- 1..100 do
        assert "Hint #{i}" == UXR.get_hint("component_#{i}")
      end
    end

    test "handles concurrent feature toggling" do
      UXR.init()

      # Spawn processes to toggle features - each with a unique feature
      tasks = for _i <- 1..50 do
        Task.async(fn ->
          # Use :hints for all, but check the operations work
          :ok = UXR.enable_feature(:hints)
          enabled = UXR.feature_enabled?(:hints)

          # Only try to verify our own operations, not the final state
          # since other tasks may have changed it
          {enabled, :ok}
        end)
      end

      results = Task.await_many(tasks)
      assert Enum.all?(results, fn {enabled, :ok} ->
        # Just verify that enable worked (feature was enabled at some point)
        enabled == true
      end)
    end
  end
end
