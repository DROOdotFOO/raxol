defmodule Raxol.Animation.FrameworkTest do
  # Disable async because we are manipulating GenServers
  use ExUnit.Case, async: false

  require Logger

  alias Raxol.Animation.Framework
  alias Raxol.Core.Accessibility, as: Accessibility
  alias Raxol.Core.Runtime.ProcessStore
  alias Raxol.Core.UserPreferences
  import Raxol.AccessibilityTestHelpers

  Logger.debug("Starting FrameworkTest module")

  # Helper to wait for animation completion
  defp wait_for_animation_completion(element_id, animation_name, timeout \\ 500) do
    assert_receive {:animation_completed, ^element_id, ^animation_name}, timeout
  end

  # Helper to wait for animation start
  defp wait_for_animation_start(element_id, animation_name, timeout \\ 500) do
    assert_receive {:animation_started, ^element_id, ^animation_name}, timeout
  end

  # Helper to flush the mailbox
  # defp flush_mailbox do
  #   receive do
  #     _ -> flush_mailbox()
  #   after
  #     0 -> :ok
  #   end
  # end

  # Start UserPreferences for these tests
  setup do
    Logger.debug("Starting setup block")

    # Start EventManager for event-based tests
    case Raxol.Core.Events.EventManager.start_link(
           name: Raxol.Core.Events.EventManager
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Logger.debug("EventManager started successfully")

    # Reset or stop default AccessibilityServer to avoid stale state from prior tests
    case Process.whereis(Raxol.Core.Accessibility.AccessibilityServer) do
      nil -> :ok
      pid ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
    end

    local_user_prefs_name = __MODULE__.UserPreferences
    user_prefs_opts = [name: local_user_prefs_name, test_mode?: true]

    Logger.debug(
      "Starting UserPreferences with opts: #{inspect(user_prefs_opts)}"
    )

    {:ok, user_prefs_pid} = start_supervised({UserPreferences, user_prefs_opts})
    Logger.debug("UserPreferences started successfully")

    # Start AccessibilityServer for the test with unique name to avoid conflicts
    accessibility_server_name = :"accessibility_server_#{System.unique_integer([:positive])}"
    {:ok, _accessibility_pid} = Raxol.Core.Accessibility.AccessibilityServer.start_link(
      name: accessibility_server_name
    )
    Logger.debug("AccessibilityServer started successfully")

    Framework.init(%{}, local_user_prefs_name)
    Logger.debug("Framework initialized")

    # Reset relevant prefs before each test
    UserPreferences.set(
      "accessibility.reduced_motion",
      false,
      local_user_prefs_name
    )

    UserPreferences.set(
      "accessibility.screen_reader",
      true,
      local_user_prefs_name
    )

    UserPreferences.set(
      "accessibility.silence_announcements",
      false,
      local_user_prefs_name
    )

    # Wait for preferences to be applied
    assert_receive {:preferences_applied, ^local_user_prefs_name}, 500
    Logger.debug("Preferences applied successfully")

    on_exit(fn ->
      try do
        Framework.stop()
      catch
        :exit, _ -> :ok
      end
      Logger.debug("Framework stopped in on_exit")

      try do
        case Process.whereis(Raxol.Core.Events.EventManager) do
          nil -> :ok
          _pid -> Raxol.Core.Events.EventManager.cleanup()
        end
      catch
        :exit, _ -> :ok
      end

      Logger.debug("EventManager cleanup completed")
    end)

    {:ok, %{user_preferences_pid: user_prefs_pid, user_preferences_name: local_user_prefs_name}}
  end

  describe "Animation Framework" do
    # Note: user_preferences_pid comes from outer setup block

    test ~c"initializes with default settings", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Ensure reduced motion is set to false before testing defaults
      UserPreferences.set(
        "accessibility.reduced_motion",
        false,
        user_preferences_pid
      )

      # Reset the framework to ensure clean state
      Framework.stop()
      assert :ok == Framework.init(%{}, user_preferences_pid)

      # Verify default settings
      settings = ProcessStore.get(:animation_framework_settings, %{})
      assert settings.reduced_motion == false
      assert settings.default_duration == 300

      # Note: default_easing is not stored in settings, it's used at creation time
    end

    test ~c"creates animation with default settings" do
      animation =
        Framework.create_animation(:test_animation, %{
          type: :fade,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      assert animation.name == :test_animation
      assert is_map(animation)
      assert Map.has_key?(animation, :type)
      assert animation.type == :fade
      # Default duration
      assert animation.duration == 300
      # Default easing
      assert animation.easing == :linear
      assert animation.from == 0
      assert animation.to == 1
    end

    @tag :skip_on_ci
    test "creates animation with custom settings" do
      animation =
        Framework.create_animation(:custom_animation, %{
          type: :slide,
          duration: 500,
          easing: :ease_out_cubic,
          from: 0,
          to: 100,
          direction: :right,
          target_path: [:position]
        })

      assert animation.name == :custom_animation
      assert is_map(animation)
      assert Map.has_key?(animation, :type)
      assert animation.type == :slide
      assert animation.duration == 500
      assert animation.easing == :ease_out_cubic
      assert animation.from == 0
      assert animation.to == 100
      assert animation.direction == :right
    end

    test "starts animation for an element", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Create and start a test animation
      animation =
        Framework.create_animation(:test_animation, %{
          type: :fade,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      assert :ok ==
               Framework.start_animation(
                 animation.name,
                 "test_element",
                 %{},
                 user_preferences_pid
               )

      wait_for_animation_start("test_element", animation.name)
    end

    test "handles reduced motion preferences", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Enable reduced motion *before* creating/starting
      UserPreferences.set(
        "accessibility.reduced_motion",
        true,
        user_preferences_pid
      )

      Framework.init(%{reduced_motion: true}, user_preferences_pid)

      # Create initial state
      initial_state = %{
        elements: %{
          "test_element" => %{
            # Initial value
            opacity: 0
          }
        }
      }

      # Create a test animation
      animation =
        Framework.create_animation(:test_animation, %{
          type: :fade,
          # Original duration doesn't matter now
          duration: 300,
          # Matches initial state
          from: 0,
          # Final value
          to: 1,
          target_path: [:opacity]
        })

      # Start the animation
      :ok =
        Framework.start_animation(
          animation.name,
          "test_element",
          %{},
          user_preferences_pid
        )

      wait_for_animation_start("test_element", animation.name)

      # Apply animation immediately
      updated_state =
        Framework.apply_animations_to_state(initial_state, user_preferences_pid)

      # Verify the final state was applied immediately due to reduced motion
      assert get_in(updated_state, [:elements, "test_element", :opacity]) == 1
    end

    @tag :event_manager
    @tag :skip_on_ci
    test "event manager is working", %{
      user_preferences_pid: _user_preferences_pid
    } do
      # Test that EventManager is working by dispatching an event
      # and checking if the accessibility spy handler receives it

      # Create an ETS table for cross-process announcement storage
      :ets.new(:accessibility_test_announcements, [:set, :public, :named_table])
      :ets.insert(:accessibility_test_announcements, {:announcements, []})

      Raxol.Core.Events.Manager.register_handler(
        :screen_reader_announcement,
        Raxol.AccessibilityTestHelpers,
        :handle_announcement_spy
      )

      # Dispatch an accessibility event
      Raxol.Core.Events.Manager.dispatch(
        {:screen_reader_announcement, "test message"}
      )

      # Give the handler time to process
      Process.sleep(10)

      # Check if the spy handler received it (from ETS table)
      announcements =
        case :ets.lookup(:accessibility_test_announcements, :announcements) do
          [{:announcements, msgs}] -> msgs
          [] -> []
        end

      assert "test message" in announcements

      # Clean up
      Raxol.Core.Events.Manager.unregister_handler(
        :screen_reader_announcement,
        Raxol.AccessibilityTestHelpers,
        :handle_announcement_spy
      )

      :ets.delete(:accessibility_test_announcements)
    end

    test "accessibility system is working", %{
      user_preferences_pid: user_preferences_pid
    } do
      with_screen_reader_spy(user_preferences_pid, fn ->
        # Debug: Check if accessibility is enabled
        enabled = Accessibility.enabled?(user_preferences_pid)
        Logger.debug("Accessibility enabled: #{enabled}")

        # Debug: Check screen reader setting
        screen_reader =
          UserPreferences.get(
            "accessibility.screen_reader",
            user_preferences_pid
          )

        Logger.debug("Screen reader enabled: #{screen_reader}")

        # Debug: Check silence announcements setting
        silence =
          UserPreferences.get(
            "accessibility.silence_announcements",
            user_preferences_pid
          )

        Logger.debug("Silence announcements: #{silence}")

        # Try to make a direct announcement
        Accessibility.announce("Test announcement", [], user_preferences_pid)

        # Debug: Check what announcements were made
        announcements = ProcessStore.get(:accessibility_test_announcements, [])
        Logger.debug("Current announcements: #{inspect(announcements)}")

        # Verify announcement was made
        assert_announced("Test announcement")
      end)
    end

    test "announces animations to screen readers when configured", %{
      user_preferences_pid: user_preferences_pid
    } do
      with_screen_reader_spy(user_preferences_pid, fn ->
        # Debug: Check if accessibility is enabled
        enabled = Accessibility.enabled?(user_preferences_pid)
        Logger.debug("Accessibility enabled: #{enabled}")

        # Debug: Check screen reader setting
        screen_reader =
          UserPreferences.get(
            "accessibility.screen_reader",
            user_preferences_pid
          )

        Logger.debug("Screen reader enabled: #{screen_reader}")

        # Debug: Check silence announcements setting
        silence =
          UserPreferences.get(
            "accessibility.silence_announcements",
            user_preferences_pid
          )

        Logger.debug("Silence announcements: #{silence}")

        # Create an animation with screen reader announcement
        animation =
          Framework.create_animation(:test_animation, %{
            type: :fade,
            from: 0,
            to: 1,
            announce_to_screen_reader: true,
            description: "Test animation",
            target_path: [:opacity]
          })

        # Start the animation
        :ok =
          Framework.start_animation(
            animation.name,
            "test_element",
            %{},
            user_preferences_pid
          )

        wait_for_animation_start("test_element", animation.name)

        # Debug: Check what announcements were made
        announcements = ProcessStore.get(:accessibility_test_announcements, [])
        Logger.debug("Current announcements: #{inspect(announcements)}")

        # Verify announcement was made using the spy helper
        assert_announced("Test animation started")
      end)
    end

    test "applies animation values to state", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Create initial state
      initial_state = %{
        elements: %{
          "test_element" => %{
            opacity: 0
          }
        }
      }

      # Create and start a fade animation with zero duration for instant result
      animation =
        Framework.create_animation(:fade_in, %{
          type: :fade,
          # Set duration to 0
          duration: 0,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      :ok =
        Framework.start_animation(
          animation.name,
          "test_element",
          %{},
          user_preferences_pid
        )

      wait_for_animation_start("test_element", animation.name)

      # Apply animation to state
      updated_state =
        Framework.apply_animations_to_state(initial_state, user_preferences_pid)

      # Verify state was updated
      assert get_in(updated_state, [:elements, "test_element", :opacity]) == 1
    end

    test "handles multiple animations on same element", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Create initial state
      initial_state = %{
        elements: %{
          "test_element" => %{
            opacity: 0,
            position: 0
          }
        }
      }

      # Create and start multiple animations with zero duration
      fade_animation =
        Framework.create_animation(:fade_in, %{
          type: :fade,
          # Set duration to 0
          duration: 0,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      slide_animation =
        Framework.create_animation(:slide_in, %{
          type: :slide,
          # Set duration to 0
          duration: 0,
          from: 0,
          to: 100,
          target_path: [:position]
        })

      :ok =
        Framework.start_animation(
          fade_animation.name,
          "test_element",
          %{},
          user_preferences_pid
        )

      :ok =
        Framework.start_animation(
          slide_animation.name,
          "test_element",
          %{},
          user_preferences_pid
        )

      wait_for_animation_start("test_element", fade_animation.name)
      wait_for_animation_start("test_element", slide_animation.name)

      # Apply animations to state
      updated_state =
        Framework.apply_animations_to_state(initial_state, user_preferences_pid)

      # Verify both animations were applied
      assert get_in(updated_state, [:elements, "test_element", :opacity]) == 1

      assert get_in(updated_state, [:elements, "test_element", :position]) ==
               100
    end

    test "meets performance requirements", %{
      user_preferences_pid: user_preferences_pid
    } do
      # Create a test animation
      animation =
        Framework.create_animation(:perf_test, %{
          type: :fade,
          duration: 100,
          from: 0,
          to: 1,
          target_path: [:opacity]
        })

      # Measure animation performance
      start_time = System.monotonic_time(:millisecond)

      :ok =
        Framework.start_animation(
          animation.name,
          "test_element",
          %{},
          user_preferences_pid
        )

      wait_for_animation_start("test_element", animation.name)

      # Apply animations to trigger completion logic
      Framework.apply_animations_to_state(%{}, user_preferences_pid)

      # Wait a bit for the animation to complete
      Process.sleep(150)

      # Apply again to ensure completion is processed
      Framework.apply_animations_to_state(%{}, user_preferences_pid)

      wait_for_animation_completion("test_element", animation.name)

      end_time = System.monotonic_time(:millisecond)

      duration = end_time - start_time

      # Verify performance requirements (should complete within reasonable time)
      # Allow 500ms for CI variability (test has 150ms sleep + 100ms animation = 250ms minimum)
      assert duration < 500, "Animation completion time too high: #{duration}ms"
    end
  end
end
