defmodule Raxol.Core.UXRefinement.UxServerTest do
  @moduledoc """
  Tests for UxServer GenServer directly, using uniquely named instances
  to avoid singleton conflicts.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.UXRefinement.UxServer

  defp start_server(_context) do
    name = :"test_ux_#{System.unique_integer([:positive])}"
    {:ok, pid} = UxServer.start_link(name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, %{server: name, pid: pid}}
  end

  describe "start_link and init" do
    setup :start_server

    test "starts with empty state", %{server: server} do
      refute UxServer.feature_enabled?(server, :hints)
      refute UxServer.feature_enabled?(server, :events)
      refute UxServer.feature_enabled?(server, :focus_management)
    end

    test "init_system resets state to clean baseline", %{server: server} do
      # Enable a feature first
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert UxServer.feature_enabled?(server, :hints)

      # init_system resets features
      assert :ok = UxServer.init_system(server)
      refute UxServer.feature_enabled?(server, :hints)
    end

    test "init_system clears hints and metadata", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert :ok = UxServer.register_hint(server, "btn", "Click me")
      assert "Click me" = UxServer.get_hint(server, "btn")

      assert :ok = UxServer.init_system(server)

      # Re-enable hints to query (hints map was cleared by init_system)
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert nil == UxServer.get_hint(server, "btn")
    end
  end

  describe "enable_feature/4" do
    setup :start_server

    test "enables :events feature", %{server: server} do
      refute UxServer.feature_enabled?(server, :events)
      assert :ok = UxServer.enable_feature(server, :events, [], nil)
      assert UxServer.feature_enabled?(server, :events)
    end

    test "enables :hints feature", %{server: server} do
      refute UxServer.feature_enabled?(server, :hints)
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert UxServer.feature_enabled?(server, :hints)
    end

    test "enables :focus_management feature", %{server: server} do
      refute UxServer.feature_enabled?(server, :focus_management)

      assert :ok = UxServer.enable_feature(server, :focus_management, [], nil)
      assert UxServer.feature_enabled?(server, :focus_management)
    end

    test "returns error for unknown feature", %{server: server} do
      assert {:error, "Unknown feature: bogus"} =
               UxServer.enable_feature(server, :bogus, [], nil)

      refute UxServer.feature_enabled?(server, :bogus)
    end

    test "enabling an already-enabled feature is idempotent", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert UxServer.feature_enabled?(server, :hints)
    end
  end

  describe "disable_feature/2" do
    setup :start_server

    test "disables :hints and clears hint state", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert :ok = UxServer.register_hint(server, "c1", "Help text")
      assert UxServer.feature_enabled?(server, :hints)

      assert :ok = UxServer.disable_feature(server, :hints)
      refute UxServer.feature_enabled?(server, :hints)

      # Re-enable to verify hints were cleared
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert nil == UxServer.get_hint(server, "c1")
    end

    test "disables :events when no dependents exist", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :events, [], nil)
      assert UxServer.feature_enabled?(server, :events)

      assert :ok = UxServer.disable_feature(server, :events)
      refute UxServer.feature_enabled?(server, :events)
    end

    test "disabling a feature that was never enabled is a no-op", %{server: server} do
      refute UxServer.feature_enabled?(server, :hints)
      assert :ok = UxServer.disable_feature(server, :hints)
      refute UxServer.feature_enabled?(server, :hints)
    end

    test "disables :focus_management independently of :events", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :events, [], nil)
      assert :ok = UxServer.enable_feature(server, :focus_management, [], nil)
      assert UxServer.feature_enabled?(server, :focus_management)
      assert UxServer.feature_enabled?(server, :events)

      assert :ok = UxServer.disable_feature(server, :focus_management)
      refute UxServer.feature_enabled?(server, :focus_management)
      # Events remain enabled (no automatic cascade)
      assert UxServer.feature_enabled?(server, :events)
    end
  end

  describe "feature_enabled?/2" do
    setup :start_server

    test "returns false for features never enabled", %{server: server} do
      refute UxServer.feature_enabled?(server, :hints)
      refute UxServer.feature_enabled?(server, :events)
      refute UxServer.feature_enabled?(server, :focus_management)
      refute UxServer.feature_enabled?(server, :accessibility)
      refute UxServer.feature_enabled?(server, :keyboard_shortcuts)
    end

    test "returns true after enabling, false after disabling", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :events, [], nil)
      assert UxServer.feature_enabled?(server, :events)

      assert :ok = UxServer.disable_feature(server, :events)
      refute UxServer.feature_enabled?(server, :events)
    end
  end

  describe "register_hint/3 and get_hint/2" do
    setup context do
      {:ok, ctx} = start_server(context)
      UxServer.enable_feature(ctx.server, :hints, [], nil)
      {:ok, ctx}
    end

    test "registers and retrieves a simple string hint", %{server: server} do
      assert :ok = UxServer.register_hint(server, "button1", "Click to submit")
      assert "Click to submit" = UxServer.get_hint(server, "button1")
    end

    test "returns nil for a non-existent component", %{server: server} do
      assert nil == UxServer.get_hint(server, "nonexistent")
    end

    test "overwrites an existing hint", %{server: server} do
      assert :ok = UxServer.register_hint(server, "btn", "Old hint")
      assert "Old hint" = UxServer.get_hint(server, "btn")

      assert :ok = UxServer.register_hint(server, "btn", "New hint")
      assert "New hint" = UxServer.get_hint(server, "btn")
    end

    test "multiple components maintain separate hints", %{server: server} do
      assert :ok = UxServer.register_hint(server, "a", "Hint A")
      assert :ok = UxServer.register_hint(server, "b", "Hint B")
      assert :ok = UxServer.register_hint(server, "c", "Hint C")

      assert "Hint A" = UxServer.get_hint(server, "a")
      assert "Hint B" = UxServer.get_hint(server, "b")
      assert "Hint C" = UxServer.get_hint(server, "c")
    end

    test "get_hint returns the :basic level from a simple hint", %{server: server} do
      # register_hint stores as %{basic: hint}, so get_hint (which reads :basic) works
      assert :ok = UxServer.register_hint(server, "x", "Basic text")
      assert "Basic text" = UxServer.get_hint(server, "x")
    end
  end

  describe "register_component_hint/3 and get_component_hint/3" do
    setup context do
      {:ok, ctx} = start_server(context)
      UxServer.enable_feature(ctx.server, :hints, [], nil)
      {:ok, ctx}
    end

    test "registers and retrieves hints at all levels", %{server: server} do
      hint_info = %{
        basic: "Search for items",
        detailed: "Type keywords and press Enter to search",
        examples: "Try 'settings' or 'preferences'"
      }

      assert :ok = UxServer.register_component_hint(server, "search", hint_info)

      assert "Search for items" =
               UxServer.get_component_hint(server, "search", :basic)

      assert "Type keywords and press Enter to search" =
               UxServer.get_component_hint(server, "search", :detailed)

      assert "Try 'settings' or 'preferences'" =
               UxServer.get_component_hint(server, "search", :examples)
    end

    test "falls back to :basic when requested level is nil", %{server: server} do
      hint_info = %{basic: "Fallback hint"}
      assert :ok = UxServer.register_component_hint(server, "widget", hint_info)

      # :detailed and :examples are nil, so it falls back to :basic
      assert "Fallback hint" =
               UxServer.get_component_hint(server, "widget", :detailed)

      assert "Fallback hint" =
               UxServer.get_component_hint(server, "widget", :examples)
    end

    test "returns nil for a non-existent component", %{server: server} do
      assert nil == UxServer.get_component_hint(server, "missing", :basic)
    end

    test "accepts a string hint_info and normalizes it", %{server: server} do
      assert :ok = UxServer.register_component_hint(server, "btn", "Simple text")
      assert "Simple text" = UxServer.get_component_hint(server, "btn", :basic)
    end

    test "registers hints with shortcuts included", %{server: server} do
      hint_info = %{
        basic: "Open file dialog",
        shortcuts: [{"Ctrl+O", "Open file"}]
      }

      assert :ok = UxServer.register_component_hint(server, "open_btn", hint_info)

      assert "Open file dialog" =
               UxServer.get_component_hint(server, "open_btn", :basic)
    end
  end

  describe "get_component_shortcuts/2" do
    setup context do
      {:ok, ctx} = start_server(context)
      UxServer.enable_feature(ctx.server, :hints, [], nil)
      {:ok, ctx}
    end

    test "returns shortcuts from component hint", %{server: server} do
      hint_info = %{
        basic: "Execute action",
        shortcuts: [{"Enter", "Submit"}, {"Escape", "Cancel"}]
      }

      assert :ok = UxServer.register_component_hint(server, "form", hint_info)
      shortcuts = UxServer.get_component_shortcuts(server, "form")
      assert [{"Enter", "Submit"}, {"Escape", "Cancel"}] = shortcuts
    end

    test "returns empty list when no shortcuts registered", %{server: server} do
      hint_info = %{basic: "No shortcuts here"}
      assert :ok = UxServer.register_component_hint(server, "plain", hint_info)
      assert [] = UxServer.get_component_shortcuts(server, "plain")
    end

    test "returns empty list for non-existent component", %{server: server} do
      assert [] = UxServer.get_component_shortcuts(server, "nonexistent")
    end
  end

  describe "register_accessibility_metadata/3 and get_accessibility_metadata/2" do
    setup :start_server

    test "get returns nil when :accessibility feature is not enabled", %{server: server} do
      metadata = %{label: "Save", role: "button"}
      # Register stores nothing when accessibility is disabled
      assert :ok = UxServer.register_accessibility_metadata(server, "save_btn", metadata)
      assert nil == UxServer.get_accessibility_metadata(server, "save_btn")
    end

    test "get returns nil for non-existent component regardless of feature state", %{server: server} do
      assert nil == UxServer.get_accessibility_metadata(server, "nonexistent")
    end
  end

  describe "state isolation between server instances" do
    test "two servers maintain independent feature sets" do
      name1 = :"test_ux_iso_#{System.unique_integer([:positive])}"
      name2 = :"test_ux_iso_#{System.unique_integer([:positive])}"
      {:ok, pid1} = UxServer.start_link(name: name1)
      {:ok, pid2} = UxServer.start_link(name: name2)

      on_exit(fn ->
        for pid <- [pid1, pid2] do
          try do
            if Process.alive?(pid), do: GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Enable hints on server1 only
      assert :ok = UxServer.enable_feature(name1, :hints, [], nil)
      assert UxServer.feature_enabled?(name1, :hints)
      refute UxServer.feature_enabled?(name2, :hints)

      # Enable events on server2 only
      assert :ok = UxServer.enable_feature(name2, :events, [], nil)
      refute UxServer.feature_enabled?(name1, :events)
      assert UxServer.feature_enabled?(name2, :events)
    end

    test "two servers maintain independent hint stores" do
      name1 = :"test_ux_hints_#{System.unique_integer([:positive])}"
      name2 = :"test_ux_hints_#{System.unique_integer([:positive])}"
      {:ok, pid1} = UxServer.start_link(name: name1)
      {:ok, pid2} = UxServer.start_link(name: name2)

      on_exit(fn ->
        for pid <- [pid1, pid2] do
          try do
            if Process.alive?(pid), do: GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      UxServer.enable_feature(name1, :hints, [], nil)
      UxServer.enable_feature(name2, :hints, [], nil)

      assert :ok = UxServer.register_hint(name1, "btn", "Hint from server 1")
      assert :ok = UxServer.register_hint(name2, "btn", "Hint from server 2")

      assert "Hint from server 1" = UxServer.get_hint(name1, "btn")
      assert "Hint from server 2" = UxServer.get_hint(name2, "btn")
    end
  end

  describe "concurrent operations on a single server" do
    setup :start_server

    test "concurrent hint registrations all succeed", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            UxServer.register_hint(server, "comp_#{i}", "Hint #{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      for i <- 1..50 do
        assert UxServer.get_hint(server, "comp_#{i}") == "Hint #{i}"
      end
    end

    test "concurrent reads return consistent data", %{server: server} do
      assert :ok = UxServer.enable_feature(server, :hints, [], nil)
      assert :ok = UxServer.register_hint(server, "stable", "Consistent value")

      tasks =
        for _i <- 1..50 do
          Task.async(fn ->
            UxServer.get_hint(server, "stable")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == "Consistent value"))
    end
  end
end
