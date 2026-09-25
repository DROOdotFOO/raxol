defmodule Raxol.Core.AccessibilityTestHelper do
  @moduledoc """
  Helper module for accessibility tests providing common test utilities and fixtures.
  """

  alias Raxol.Core.UserPreferences
  import ExUnit.Assertions
  import ExUnit.Callbacks

  def wait_for_state(condition, timeout \\ 100) do
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + timeout

    wait_for_condition(condition, end_time)
  end

  defp wait_for_condition(condition, end_time) do
    check_timeout(System.monotonic_time(:millisecond), end_time)
    check_condition_status(condition.(), condition, end_time)
  end

  defp check_timeout(current_time, end_time) when current_time > end_time do
    flunk("Condition not met within timeout")
  end

  defp check_timeout(_current_time, _end_time), do: :ok

  defp check_condition_status(true, _condition, _end_time), do: :ok

  defp check_condition_status(false, condition, end_time) do
    Process.sleep(10)
    wait_for_condition(condition, end_time)
  end

  def pref_key(key), do: [:accessibility, key]

  def setup_test_preferences(prefs_name) do
    # Ensure EventManager is started
    Raxol.Core.Events.EventManager.init()

    pid =
      start_supervised!({UserPreferences, [test_mode?: true, name: prefs_name]})

    Raxol.Core.UserPreferences.set(pref_key(:enabled), true, pid)
    Raxol.Core.UserPreferences.set(pref_key(:screen_reader), true, pid)
    Raxol.Core.UserPreferences.set(pref_key(:high_contrast), false, pid)
    Raxol.Core.UserPreferences.set(pref_key(:reduced_motion), false, pid)
    Raxol.Core.UserPreferences.set(pref_key(:keyboard_focus), true, pid)
    Raxol.Core.UserPreferences.set(pref_key(:large_text), false, pid)

    Raxol.Core.UserPreferences.set(
      pref_key(:silence_announcements),
      false,
      pid
    )

    # Note: No on_exit cleanup needed here because:
    # 1. UserPreferences is started via start_supervised! so ExUnit handles cleanup
    # 2. EventManager is started by the application's :test supervision tree
    #    and should not be stopped by individual tests (doing so causes flaky
    #    test failures)

    {:ok, prefs_name: prefs_name, pref_pid: pid}
  end

  def setup_test_preferences_with_events(prefs_name) do
    # Reset global state for test isolation
    Raxol.Test.IsolationHelper.reset_global_state()

    # Ensure EventManager is started and supervised (if not already running)
    # Must use name: option so Process.whereis can find it
    case Process.whereis(Raxol.Core.Events.EventManager) do
      nil ->
        start_supervised!(
          {Raxol.Core.Events.EventManager,
           [name: Raxol.Core.Events.EventManager]}
        )

        Process.sleep(10)

      _pid ->
        # Already running
        :ok
    end

    # Check if UserPreferences is already running
    pid_of_prefs = get_or_start_preferences()

    # Ensure AccessibilityServer is started and supervised with unique name
    accessibility_server_name =
      :"accessibility_server_helper_#{System.unique_integer([:positive])}"

    accessibility_pid =
      start_supervised!(
        {Raxol.Core.Accessibility.AccessibilityServer,
         [name: accessibility_server_name]}
      )

    # Wait a bit to ensure servers are ready
    Process.sleep(10)

    # Set up preferences
    Raxol.Core.UserPreferences.set(pref_key(:screen_reader), true, pid_of_prefs)
    Raxol.Core.Accessibility.enable([], pid_of_prefs)
    Raxol.Core.Accessibility.clear_announcements()

    # Ensure process is alive before returning
    ensure_process_alive(pid_of_prefs)

    on_exit(fn ->
      # Clean up accessibility and stop the process if alive
      cleanup_process_if_alive(pid_of_prefs)
      # EventManager is now supervised and will be cleaned up automatically
    end)

    {:ok,
     prefs_name: prefs_name,
     pref_pid: pid_of_prefs,
     accessibility_pid: accessibility_pid}
  end

  def register_test_elements do
    # Register test elements
    Raxol.Core.Accessibility.register_element_metadata("search_button", %{
      label: "Search"
    })

    Raxol.Core.Accessibility.register_element_metadata("text_input", %{
      label: "Username"
    })

    Raxol.Core.Accessibility.register_element_metadata("submit_button", %{
      label: "Submit Form"
    })

    # Return a cleanup function
    fn ->
      Raxol.Core.Accessibility.unregister_element_metadata("search_button")
      Raxol.Core.Accessibility.unregister_element_metadata("text_input")
      Raxol.Core.Accessibility.unregister_element_metadata("submit_button")
    end
  end

  def clear_test_state(prefs_name) do
    Raxol.Core.Accessibility.clear_announcements()
    Raxol.Core.Accessibility.disable(prefs_name)

    # Use clear_handlers() instead of cleanup() to avoid stopping the global EventManager
    Raxol.Core.Events.EventManager.clear_handlers()
  end

  defp get_or_start_preferences do
    case Process.whereis(Raxol.Core.UserPreferences) do
      nil ->
        # Start UserPreferences with the global name for tests that need it
        start_supervised!(
          {UserPreferences,
           [test_mode?: true, name: Raxol.Core.UserPreferences]}
        )

      existing_pid ->
        # If already running, use the existing process
        existing_pid
    end
  end

  defp ensure_process_alive(pid) do
    check_process_alive(Process.alive?(pid))
  end

  defp check_process_alive(true), do: :ok

  defp check_process_alive(false),
    do: flunk("UserPreferences process not alive after setup")

  defp cleanup_process_if_alive(pid) do
    cleanup_based_on_alive_status(Process.alive?(pid), pid)
  end

  defp cleanup_based_on_alive_status(true, pid) do
    Raxol.Core.Accessibility.disable(pid)
    Process.exit(pid, :normal)
  end

  defp cleanup_based_on_alive_status(false, _pid), do: :ok
end
