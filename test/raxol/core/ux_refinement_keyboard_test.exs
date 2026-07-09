defmodule Raxol.Core.UXRefinementKeyboardTest do
  use ExUnit.Case, async: false
  import Mox

  # Aliases for mocks will be used directly, e.g., Raxol.Mocks.AccessibilityMock
  # alias Raxol.Core.Accessibility, as: Accessibility # Removed
  # alias Raxol.Core.Accessibility, as: Accessibility.Mock
  alias Raxol.Core.Events.Event
  alias Raxol.Core.Events.EventManager, as: EventManager
  # alias Raxol.Core.FocusManager, as: FocusManager # Removed
  # alias Raxol.Core.KeyboardShortcuts, as: KeyboardShortcuts # Removed
  alias Raxol.Core.UXRefinement, as: UXRefinement, as: UXRefinement

  # alias Raxol.Core.UserPreferences # Not directly used in :meck refactor, keep if other tests need

  # Define the mock for KeyboardShortcutsBehaviour (already present)
  # Mox.defmock(Raxol.Mocks.KeyboardShortcutsMock,
  #   for: Raxol.Core.KeyboardShortcutsRefactoredBehaviour)
  # Mocks for Accessibility and FocusManager are defined in test/support/mocks.ex

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    # Start EventManager first
    case EventManager.start_link(name: EventManager) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Initialize event manager for tests
    EventManager.init()

    # Start UX refinement server for tests
    case Raxol.Core.UXRefinement.UxServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      # Clean up any enabled features - check if process is alive first
      if Process.whereis(Raxol.Core.UXRefinement.UxServer) do
        [
          :keyboard_shortcuts,
          :events,
          :focus_management,
          :accessibility,
          :hints
        ]
        |> Enum.each(fn feature ->
          try do
            if UXRefinement.feature_enabled?(feature) do
              UXRefinement.disable_feature(feature)
            end
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end
        end)
      end

      # Clean up EventManager
      case Process.whereis(EventManager) do
        nil -> :ok
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              EventManager.cleanup()
            rescue
              _ -> :ok
            catch
              :exit, _ -> :ok
            end
          end
      end

      # Stop UX refinement server
      case Process.whereis(Raxol.Core.UXRefinement.UxServer) do
        nil -> :ok
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(Raxol.Core.UXRefinement.UxServer, :normal)
            rescue
              _ -> :ok
            catch
              :exit, {:noproc, _} -> :ok
              :exit, {:normal, _} -> :ok
              :exit, _ -> :ok
            end
          end
      end
    end)

    :ok
  end

  describe "keyboard shortcuts integration" do
    test "enable_feature/1 initializes keyboard shortcuts" do
      expect(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)

      assert :ok = UXRefinement.enable_feature(:keyboard_shortcuts)

      assert UXRefinement.feature_enabled?(:keyboard_shortcuts)
      assert UXRefinement.feature_enabled?(:events)
    end

    test "disable_feature/1 cleans up keyboard shortcuts" do
      stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)
      UXRefinement.enable_feature(:keyboard_shortcuts)

      expect(Raxol.Mocks.KeyboardShortcutsMock, :cleanup, fn -> :ok end)
      assert :ok = UXRefinement.disable_feature(:keyboard_shortcuts)
      refute UXRefinement.feature_enabled?(:keyboard_shortcuts)
    end

    test "UXRefinement.set_shortcuts_context/1 delegates to KeyboardShortcutsMock" do
      stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)
      UXRefinement.enable_feature(:keyboard_shortcuts)

      test_context = :editor

      expect(Raxol.Mocks.KeyboardShortcutsMock, :set_context, fn context ->
        assert context == test_context
        :ok
      end)

      assert UXRefinement.set_shortcuts_context(test_context) == :ok
    end

    test "UXRefinement.get_available_shortcuts/1 delegates to KeyboardShortcutsMock" do
      stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)
      UXRefinement.enable_feature(:keyboard_shortcuts)

      expected_shortcuts_data = %{some: :shortcuts}

      # Test with explicit context
      expect(
        Raxol.Mocks.KeyboardShortcutsMock,
        :get_shortcuts_for_context,
        fn context ->
          assert context == :editor
          expected_shortcuts_data
        end
      )

      assert UXRefinement.get_available_shortcuts(:editor) ==
               expected_shortcuts_data

      # Test with nil context (default argument)
      expect(
        Raxol.Mocks.KeyboardShortcutsMock,
        :get_shortcuts_for_context,
        fn context ->
          assert context == nil
          expected_shortcuts_data
        end
      )

      assert UXRefinement.get_available_shortcuts() == expected_shortcuts_data
    end

    test "UXRefinement.show_shortcuts_help/0 delegates to KeyboardShortcutsMock" do
      stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)
      UXRefinement.enable_feature(:keyboard_shortcuts, [], nil)

      expect(
        Raxol.Mocks.KeyboardShortcutsMock,
        :show_shortcuts_help,
        fn _user_prefs_pid_or_name ->
          :ok
        end
      )

      assert UXRefinement.show_shortcuts_help(nil) == :ok
    end
  end

  describe "component shortcuts integration" do
    test "UXRefinement.register_accessibility_metadata/2 calls Accessibility.register_element_metadata" do
      expect(Raxol.Mocks.AccessibilityMock, :enable, fn _, _ -> :ok end)

      stub(Raxol.Mocks.FocusManagerMock, :register_focus_change_handler, fn _ ->
        :ok
      end)

      UXRefinement.enable_feature(:accessibility)

      metadata = %{label: "Search", hint: "Press Enter to search"}
      component_id = "search_button"

      expect(
        Raxol.Mocks.AccessibilityMock,
        :register_element_metadata,
        fn id, meta ->
          assert id == component_id
          assert meta == metadata
          :ok
        end
      )

      assert UXRefinement.register_accessibility_metadata(
               component_id,
               metadata
             ) == :ok
    end

    test "register_component_hint/2 registers shortcuts via KeyboardShortcuts" do
      stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)
      UXRefinement.enable_feature(:keyboard_shortcuts)
      UXRefinement.enable_feature(:hints)
      UXRefinement.enable_feature(:focus_management)

      hint_info = %{
        basic: "Search for content",
        detailed: "Search for content in the application",
        shortcuts: [
          {"Enter", "Execute search"},
          {"Alt+S", "Focus search"}
        ]
      }

      expect(
        Raxol.Mocks.KeyboardShortcutsMock,
        :register_shortcut,
        2,
        fn shortcut_key, name, _callback, opts ->
          case shortcut_key do
            "Enter" ->
              assert name == "search_button_shortcut_Enter"
              assert Keyword.get(opts, :description) == "Execute search"
              assert Keyword.get(opts, :context) == "search_button"

            "Alt+S" ->
              assert name == "search_button_shortcut_Alt+S"
              assert Keyword.get(opts, :description) == "Focus search"
              assert Keyword.get(opts, :context) == "search_button"

            _ ->
              flunk("Unexpected shortcut_key: #{inspect(shortcut_key)}")
          end

          :ok
        end
      )

      UXRefinement.register_component_hint("search_button", hint_info)
    end
  end

  describe "shortcut handling specific to UXRefinement callbacks" do
    test "shortcut callback from register_component_hint triggers FocusManager.set_focus" do
      # Override config to use real implementations for this test
      original_ks_config = Application.get_env(:raxol, :keyboard_shortcuts_module)
      original_fm_config = Application.get_env(:raxol, :focus_manager_module)

      Application.put_env(:raxol, :keyboard_shortcuts_module, Raxol.Core.KeyboardShortcuts)
      Application.put_env(:raxol, :keyboard_shortcuts_impl, Raxol.Core.KeyboardShortcuts)
      Application.put_env(:raxol, :focus_manager_module, Raxol.Core.FocusManager)
      Application.put_env(:raxol, :focus_manager_impl, Raxol.Core.FocusManager)

      on_exit(fn ->
        if original_ks_config do
          Application.put_env(:raxol, :keyboard_shortcuts_module, original_ks_config)
          Application.put_env(:raxol, :keyboard_shortcuts_impl, original_ks_config)
        else
          Application.delete_env(:raxol, :keyboard_shortcuts_module)
          Application.delete_env(:raxol, :keyboard_shortcuts_impl)
        end

        if original_fm_config do
          Application.put_env(:raxol, :focus_manager_module, original_fm_config)
          Application.put_env(:raxol, :focus_manager_impl, original_fm_config)
        else
          Application.delete_env(:raxol, :focus_manager_module)
          Application.delete_env(:raxol, :focus_manager_impl)
        end
      end)

      # Use real implementations
      alias Raxol.Core.FocusManager
      alias Raxol.Core.KeyboardShortcuts

      # Start FocusManager server if not already started
      case GenServer.whereis(Raxol.Core.FocusManager.FocusServer) do
        nil ->
          {:ok, _pid} =
            Raxol.Core.FocusManager.FocusServer.start_link(
              name: Raxol.Core.FocusManager.FocusServer
            )
        _pid ->
          :ok
      end

      # Clean up on exit
      on_exit(fn ->
        case GenServer.whereis(Raxol.Core.FocusManager.FocusServer) do
          nil ->
            :ok

          pid when is_pid(pid) ->
            try do
              GenServer.stop(pid, :normal, 1000)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      # Enable features which will start the real servers
      UXRefinement.enable_feature(:keyboard_shortcuts)
      UXRefinement.enable_feature(:focus_management)
      UXRefinement.enable_feature(:hints)

      component_id = "search_button_focus"

      # Register the component as focusable first - use string ID as FocusManager expects
      FocusManager.register_focusable(component_id, 1)

      # Get initial focus state
      initial_focus = FocusManager.get_current_focus()

      # Register component hint which should create the shortcut
      UXRefinement.register_component_hint(component_id, %{
        shortcuts: [{"Alt+F", "Focus This Component"}]
      })

      # Get component-specific shortcuts (shortcuts are registered in the component's context)
      component_shortcuts = KeyboardShortcuts.get_shortcuts_for_context(component_id)

      # Find the shortcut we registered (should be in component-specific shortcuts as "alt_f")
      our_shortcut = Map.get(component_shortcuts, "alt_f")

      assert our_shortcut != nil, "Shortcut alt_f should have been registered in component context"

      callback = our_shortcut.callback

      # Execute the shortcut callback
      callback.()

      # Verify that focus was set to our component
      current_focus = FocusManager.get_current_focus()
      assert current_focus == component_id, "Focus should have been set to #{component_id}, but was #{inspect(current_focus)}"
      assert current_focus != initial_focus, "Focus should have changed"
    end
  end

  describe "events integration" do
    test "keyboard events are handled via KeyboardShortcuts and EventManager" do
      # Stub KeyboardShortcutsMock.init BEFORE enabling features
      Mox.stub(Raxol.Mocks.KeyboardShortcutsMock, :init, fn -> :ok end)

      # Enable events first to initialize EventManager
      UXRefinement.enable_feature(:events)

      # Enable keyboard shortcuts which should register the handler
      UXRefinement.enable_feature(:keyboard_shortcuts)

      # Manually register the mock handler for keyboard events
      EventManager.register_handler(
        :keyboard_event,
        Raxol.Mocks.KeyboardShortcutsMock,
        :handle_keyboard_event
      )

      context_pid = self()

      event_handled_callback = fn ->
        send(context_pid, :handled_shortcut_event)
      end

      Mox.expect(
        Raxol.Mocks.KeyboardShortcutsMock,
        :handle_keyboard_event,
        fn event_name, dispatched_payload ->
          assert event_name == :keyboard_event
          assert dispatched_payload.type == :key
          assert dispatched_payload.data == %{key: "t", modifiers: [:ctrl]}
          event_handled_callback.()
          :ok
        end
      )

      event_to_dispatch = %Event{
        type: :key,
        data: %{key: "t", modifiers: [:ctrl]}
      }

      EventManager.dispatch({:keyboard_event, event_to_dispatch})

      # Wait for event to be handled with a timeout
      assert_receive :handled_shortcut_event, 100
      Mox.verify!(Raxol.Mocks.KeyboardShortcutsMock)
    end
  end
end
