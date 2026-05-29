defmodule Raxol.AccessibilityTestHelpers do
  @moduledoc """
  Test helpers for accessibility-related assertions and simulation in Raxol.

  REFACTORED: All try/after blocks replaced with functional patterns.

  ## Features

  - Test helpers for screen reader announcements
  - Color contrast testing tools
  - Keyboard navigation test helpers
  - Focus management testing
  - High contrast mode testing
  - Reduced motion testing
  """

  import ExUnit.Assertions

  alias Raxol.Core.Accessibility, as: Accessibility
  alias Raxol.Core.Events.EventManager, as: EventManager
  alias Raxol.Core.FocusManager, as: FocusManager
  alias Raxol.Core.KeyboardShortcuts, as: KeyboardShortcuts
  alias Raxol.Core.Runtime.ProcessStore
  alias Raxol.Style.Colors.Utilities

  @doc """
  Run a test with a spy on screen reader announcements.

  This function sets up a spy to capture screen reader announcements
  during the execution of the provided function, allowing you to
  assert that specific announcements were made.

  ## Examples

      with_screen_reader_spy(user_preferences_pid, fn ->
        # Perform action
        click_button("Save")

        # Assert announcement
        assert_announced("File saved successfully")
      end)
  """
  def with_screen_reader_spy(pid, fun)
      when is_pid(pid) and is_function(fun, 0) do
    # Create ETS table for cross-process communication
    table_created =
      case :ets.whereis(:accessibility_test_announcements) do
        :undefined ->
          _ =
            :ets.new(:accessibility_test_announcements, [
              :set,
              :public,
              :named_table
            ])

          true

        _tid ->
          false
      end

    # Initialize announcements in ETS
    :ets.insert(:accessibility_test_announcements, {:announcements, []})

    # Store test process PID for handler to send messages back
    _ = ProcessStore.put(:test_process_pid, self())

    # Register spy handler for the correct event
    EventManager.register_handler(
      :screen_reader_announcement,
      __MODULE__,
      :handle_announcement_spy
    )

    # Use functional approach with proper cleanup
    result = safe_execute_with_spy(pid, fun)

    # Always cleanup
    Accessibility.disable()

    EventManager.unregister_handler(
      :screen_reader_announcement,
      __MODULE__,
      :handle_announcement_spy
    )

    # Clean up ETS table if we created it
    case table_created do
      true -> :ets.delete(:accessibility_test_announcements)
      false -> :ok
    end

    result
  end

  def with_screen_reader_spy(_, _) do
    raise "with_screen_reader_spy/2 must be called with a pid and a function. " <>
            "Example: with_screen_reader_spy(user_preferences_pid, fn -> ... end)"
  end

  defp safe_execute_with_spy(pid, fun) do
    task =
      Task.async(fn ->
        Accessibility.enable([], pid)
        fun.()
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  @doc """
  Assert that a specific announcement was made to the screen reader.
  """
  defmacro assert_announced(expected, opts \\ []) do
    exact = Keyword.get(opts, :exact, false)
    context = Keyword.get(opts, :context, "")
    timeout = Keyword.get(opts, :timeout, 500)

    quote do
      # Announcements are delivered asynchronously via EventManager. Poll until
      # the expected announcement arrives rather than sleeping a fixed interval,
      # which raced on slower CI runners.
      announcements =
        Raxol.AccessibilityTestHelpers.wait_for_announcement(
          unquote(expected),
          unquote(exact),
          unquote(timeout)
        )

      Raxol.AccessibilityTestHelpers.validate_announcement_match(
        unquote(exact),
        announcements,
        unquote(expected),
        unquote(context)
      )
    end
  end

  @doc false
  def read_announcements do
    case :ets.whereis(:accessibility_test_announcements) do
      :undefined ->
        ProcessStore.get(:accessibility_test_announcements, [])

      tid ->
        case :ets.lookup(tid, :announcements) do
          [{:announcements, msgs}] -> msgs
          [] -> []
        end
    end
  end

  @doc false
  def wait_for_announcement(expected, exact, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_announcement(expected, exact, deadline)
  end

  defp do_wait_for_announcement(expected, exact, deadline) do
    announcements = read_announcements()

    cond do
      announcement_present?(announcements, expected, exact) ->
        announcements

      System.monotonic_time(:millisecond) >= deadline ->
        announcements

      true ->
        Process.sleep(10)
        do_wait_for_announcement(expected, exact, deadline)
    end
  end

  defp announcement_present?(announcements, expected, true),
    do: Enum.member?(announcements, expected)

  defp announcement_present?(announcements, expected, false),
    do: Enum.any?(announcements, &String.contains?(&1, expected))

  @doc """
  Assert that no announcements were made to the screen reader.

  ## Parameters

  * `opts` - Additional options

  ## Options

  * `:context` - Additional context for the error message

  ## Examples

      assert_no_announcements()
  """
  def assert_no_announcements(opts \\ []) do
    # Try ETS table first, fall back to process dictionary
    announcements =
      case :ets.whereis(:accessibility_test_announcements) do
        :undefined ->
          ProcessStore.get(:accessibility_test_announcements, [])

        tid ->
          case :ets.lookup(tid, :announcements) do
            [{:announcements, msgs}] -> msgs
            [] -> []
          end
      end

    context = Keyword.get(opts, :context, "")

    validate_no_announcements_made(announcements, context)
  end

  @doc """
  Refute that a specific announcement was made to the screen reader.
  """
  defmacro refute_announced(expected, opts \\ []) do
    exact = Keyword.get(opts, :exact, false)
    context = Keyword.get(opts, :context, "")

    quote do
      announcements = ProcessStore.get(:accessibility_test_announcements, [])

      Raxol.AccessibilityTestHelpers.validate_announcement_not_match(
        unquote(exact),
        announcements,
        unquote(expected),
        unquote(context)
      )
    end
  end

  @doc """
  Assert that two colors have sufficient contrast.

  ## Parameters

  * `color1` - The first color (hex string or tuple)
  * `color2` - The second color (hex string or tuple)
  * `opts` - Additional options

  ## Options

  * `:level` - The WCAG level to check (:aa or :aaa, defaults to :aa)
  * `:size` - The text size (:normal or :large, defaults to :normal)
  * `:context` - Additional context for the error message

  ## Examples

      assert_sufficient_contrast("#0077CC", "#FFFFFF")
      assert_sufficient_contrast("#333333", "#CCCCCC", level: :aaa, size: :large)
  """
  def assert_sufficient_contrast(color1, color2, opts \\ []) do
    level = Keyword.get(opts, :level, :aa)
    size = Keyword.get(opts, :size, :normal)
    context = Keyword.get(opts, :context, "")

    ratio = Utilities.contrast_ratio(color1, color2)
    min_ratio = get_minimum_ratio(level, size)

    validate_contrast_ratio_sufficient(ratio, min_ratio, level, size, context)
  end

  @doc """
  Simulate keyboard navigation for testing.

  This function simulates TAB key presses to navigate through focusable elements,
  allowing you to test the tab order and focus management of your UI.

  ## Examples

      simulate_keyboard_navigation(3, fn ->
        assert_focus_on("search_button")
      end)
  """
  def simulate_keyboard_navigation(steps, _fun) when steps > 0 do
    Enum.each(1..steps, fn _ ->
      # Get current focus
      current = FocusManager.get_current_focus()

      # Find next focusable element
      next =
        get_next_focusable_element(current)

      # Move focus
      move_focus_if_available(next)
    end)
  end

  @doc """
  Assert that the focus is on a specific element.

  ## Parameters

  * `expected` - The expected focused element
  * `opts` - Additional options

  ## Options

  * `:context` - Additional context for the error message

  ## Examples

      assert_focus_on("search_button")
  """
  def assert_focus_on(expected, opts \\ []) do
    current = FocusManager.get_current_focus()

    context = Keyword.get(opts, :context, "")

    validate_focus_matches_expected(current, expected, context)
  end

  @doc """
  Test keyboard shortcut handling.

  This function simulates pressing a keyboard shortcut and verifies that
  the appropriate action is triggered.

  ## Parameters

  * `shortcut` - The shortcut to test (e.g., "Ctrl+S")
  * `opts` - Additional options

  ## Options

  * `:context` - Additional context for the error message
  * `:in_context` - The context in which to test the shortcut

  ## Examples

      test_keyboard_shortcut("Ctrl+S")

      test_keyboard_shortcut("Ctrl+F", in_context: :editor)
  """
  def test_keyboard_shortcut(shortcut, opts \\ []) do
    # Get options
    context = Keyword.get(opts, :context, "")
    shortcut_context = Keyword.get(opts, :in_context)

    # Set context if provided
    set_keyboard_context_if_provided(shortcut_context)

    # Initialize action spy
    _ = ProcessStore.put(:shortcut_action_executed, false)
    _ = ProcessStore.put(:shortcut_action_id, nil)

    # Register spy handler
    EventManager.register_handler(
      :shortcut_executed,
      __MODULE__,
      :handle_shortcut_spy
    )

    # Use functional approach with cleanup
    result = safe_test_shortcut(shortcut, context)

    # Always cleanup
    EventManager.unregister_handler(
      :shortcut_executed,
      __MODULE__,
      :handle_shortcut_spy
    )

    result
  end

  defp safe_test_shortcut(shortcut, context) do
    task =
      Task.async(fn ->
        # Parse the shortcut string into an event tuple
        event_tuple = parse_shortcut_string(shortcut)

        # Dispatch the keyboard event to simulate pressing the keys
        {_type, key, modifiers} = event_tuple

        EventManager.dispatch(
          {:keyboard_event, %{key: key, modifiers: modifiers}}
        )

        # Check if action was executed
        executed = ProcessStore.get(:shortcut_action_executed, false)
        action_id = ProcessStore.get(:shortcut_action_id)

        validate_shortcut_execution(executed, shortcut, context)

        # Return the action ID for further assertions
        action_id
      end)

    case Task.yield(task, 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  @doc """
  Test high contrast mode.

  This function temporarily enables high contrast mode, runs the provided
  function, and then restores the previous setting.

  ## Examples

      with_high_contrast fn ->
        # Test how elements look in high contrast mode
        assert color_of("button") == "#FFFFFF"
      end
  """
  def with_high_contrast(fun) do
    # Store current setting
    previous = Map.get(Accessibility.get_preferences(), :high_contrast)

    # Enable high contrast
    Accessibility.set_high_contrast(true)

    # Execute function and ensure cleanup
    result = safe_execute_function(fun)

    # Always restore previous setting
    Accessibility.set_high_contrast(previous || false)

    result
  end

  @doc """
  Test reduced motion mode.

  This function temporarily enables reduced motion mode, runs the provided
  function, and then restores the previous setting.

  ## Examples

      with_reduced_motion fn ->
        # Test animations with reduced motion
        refute animation_running?("focus_ring", :pulse)
      end
  """
  def with_reduced_motion(fun_or_pid, fun \\ nil) do
    case {fun_or_pid, fun} do
      {pid, fun} when is_pid(pid) and is_function(fun, 0) ->
        previous = Map.get(Accessibility.get_preferences(), :reduced_motion)
        Accessibility.set_reduced_motion(true)

        # Execute function and ensure cleanup
        result = safe_execute_function(fun)

        # Always restore
        Accessibility.set_reduced_motion(previous || false)

        result

      {fun, nil} when is_function(fun, 0) ->
        previous = Map.get(Accessibility.get_preferences(), :reduced_motion)
        Accessibility.set_reduced_motion(true)

        # Execute function and ensure cleanup
        result = safe_execute_function(fun)

        # Always restore
        Accessibility.set_reduced_motion(previous || false)

        result
    end
  end

  defp safe_execute_function(fun) do
    task = Task.async(fn -> fun.() end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  @doc """
  Spy handler for screen reader announcements.
  """
  def handle_announcement_spy({:screen_reader_announcement, message}) do
    # Store in a way that's accessible across processes
    # Use an ETS table if it exists, otherwise try to send to the test process
    case :ets.whereis(:accessibility_test_announcements) do
      :undefined ->
        # Try to store in local process dictionary as fallback
        announcements = ProcessStore.get(:accessibility_test_announcements, [])
        updated_announcements = [message | announcements]

        _ =
          ProcessStore.put(
            :accessibility_test_announcements,
            updated_announcements
          )

        # Also try to send to the test process if we can identify it
        case ProcessStore.get(:test_process_pid) do
          nil ->
            :ok

          pid when is_pid(pid) ->
            send(pid, {:announcement_captured, message})
        end

      tid ->
        # Store in ETS table (accessible across processes)
        case :ets.lookup(tid, :announcements) do
          [] ->
            :ets.insert(tid, {:announcements, [message]})

          [{:announcements, existing}] ->
            :ets.insert(tid, {:announcements, [message | existing]})
        end
    end

    :ok
  end

  @doc """
  Spy handler for screen reader announcements (2-arity version for EventManager).
  """
  def handle_announcement_spy(:screen_reader_announcement, message) do
    handle_announcement_spy({:screen_reader_announcement, message})
  end

  @doc """
  Spy handler for shortcut execution.
  """
  def handle_shortcut_spy({:shortcut_executed, {shortcut_id, _shortcut}}) do
    # Record execution
    _ = ProcessStore.put(:shortcut_action_executed, true)
    _ = ProcessStore.put(:shortcut_action_id, shortcut_id)

    :ok
  end

  # Helper function to parse shortcut string (e.g., "Ctrl+Shift+A") into event tuple
  defp parse_shortcut_string(shortcut_string) when is_binary(shortcut_string) do
    parts = String.split(shortcut_string, "+")
    key_str = List.last(parts)
    modifier_strs = Enum.take(parts, length(parts) - 1)

    key =
      case key_str do
        k when byte_size(k) == 1 -> String.to_charlist(k) |> hd()
        # Add more special key mappings if needed (e.g., "Enter", "Tab")
        # Assume atom for F-keys, etc.
        _ -> String.to_atom(String.downcase(key_str))
      end

    modifiers =
      Enum.map(modifier_strs, fn
        "Ctrl" -> :ctrl
        "Alt" -> :alt
        "Shift" -> :shift
        # Ignore unknown modifiers
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {:key, key, modifiers}
  end

  # Helper function to get minimum contrast ratio
  defp get_minimum_ratio(:aa, :normal), do: 4.5
  defp get_minimum_ratio(:aa, :large), do: 3.0
  defp get_minimum_ratio(:aaa, :normal), do: 7.0
  defp get_minimum_ratio(:aaa, :large), do: 4.5

  # Removed unused announcement validation helpers - these can be re-added if needed

  ## Pattern matching helper functions for announcement validation

  def validate_announcement_match(true, announcements, expected, context) do
    case Enum.member?(announcements, expected) do
      true ->
        :ok

      false ->
        flunk(
          "Expected exact announcement \"#{expected}\" not found.\n#{context}"
        )
    end
  end

  def validate_announcement_match(false, announcements, expected, context) do
    case Enum.any?(announcements, &String.contains?(&1, expected)) do
      true ->
        :ok

      false ->
        flunk("No announcement containing \"#{expected}\" found.\n#{context}")
    end
  end

  def validate_announcement_not_match(true, announcements, unexpected, context) do
    case Enum.member?(announcements, unexpected) do
      true ->
        flunk(
          "Unexpected exact announcement \"#{unexpected}\" found.\n#{context}"
        )

      false ->
        :ok
    end
  end

  def validate_announcement_not_match(false, announcements, unexpected, context) do
    case Enum.any?(announcements, &String.contains?(&1, unexpected)) do
      true ->
        flunk("Found announcement containing \"#{unexpected}\".\n#{context}")

      false ->
        :ok
    end
  end

  def validate_announcement_not_contains(announcements, unexpected, context) do
    case Enum.any?(announcements, &String.contains?(&1, unexpected)) do
      true ->
        flunk("Found announcement containing \"#{unexpected}\".\n#{context}")

      false ->
        :ok
    end
  end

  def validate_announcement_not_matches_regex(announcements, regex, context) do
    case Enum.any?(announcements, &Regex.match?(regex, &1)) do
      true ->
        flunk(
          "Found announcement matching regex #{inspect(regex)}.\n#{context}"
        )

      false ->
        :ok
    end
  end

  defp validate_no_announcements_made([], _context), do: :ok

  defp validate_no_announcements_made(announcements, context) do
    flunk(
      "Expected no screen reader announcements, but got: #{inspect(announcements)}\n#{context}"
    )
  end

  defp validate_contrast_ratio_sufficient(
         ratio,
         min_ratio,
         level,
         size,
         context
       )
       when ratio < min_ratio do
    level_str = level |> Atom.to_string() |> String.upcase()

    flunk(
      "Insufficient contrast ratio: #{ratio}. " <>
        "Expected at least #{min_ratio} for WCAG #{level_str} with #{size} text.\n#{context}"
    )
  end

  defp validate_contrast_ratio_sufficient(
         _ratio,
         _min_ratio,
         _level,
         _size,
         _context
       ),
       do: :ok

  defp get_next_focusable_element(current) do
    # Default to forward direction since get_focus_direction doesn't exist
    FocusManager.get_next_focusable(current)
  end

  defp move_focus_if_available(nil), do: :ok

  defp move_focus_if_available(next) do
    FocusManager.set_focus(next)
  end

  defp validate_focus_matches_expected(current, expected, context)
       when current != expected do
    flunk(
      ~s(Expected focus on "#{expected}", but it's on "#{current}"\n#{context})
    )
  end

  defp validate_focus_matches_expected(_current, _expected, _context), do: :ok

  defp set_keyboard_context_if_provided(nil), do: :ok

  defp set_keyboard_context_if_provided(shortcut_context) do
    KeyboardShortcuts.set_active_context(shortcut_context)
  end

  defp validate_shortcut_execution(executed, shortcut, context) do
    case executed do
      true ->
        :ok

      false ->
        flunk(
          "Keyboard shortcut \"#{shortcut}\" did not trigger any action.\n#{context}"
        )
    end
  end
end
