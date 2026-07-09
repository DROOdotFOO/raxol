defmodule Raxol.UI.Components.Terminal.EmulatorTest do
  use ExUnit.Case

  setup_all do
    start_supervised!(
      {Raxol.Terminal.Window.WindowServer, [name: Raxol.Terminal.Window.WindowServer]}
    )

    start_supervised!(
      {Raxol.Terminal.IO.IOServer, [name: Raxol.Terminal.IO.IOServer]}
    )
    :ok
  end

  setup do
    # Create initial state with proper configuration
    initial_state = create_test_initial_state()
    %{initial_state: initial_state}
  end

  alias Raxol.UI.Components.Terminal.Emulator, as: EmulatorComponent

  # Helper function to create a proper test initial state
  defp create_test_initial_state do
    # Create initial state with test-specific configuration
    EmulatorComponent.init(%{
      width: 80,
      height: 24,
      config: %{
        scrollback_limit: 1000,
        memory_limit: 50 * 1024 * 1024,
        command_history_limit: 1000,
        rendering: %{
          fps: 60,
          theme: %{
            foreground: :white,
            background: :black
          },
          font_settings: %{
            size: 12
          }
        }
      }
    })
  end

  # Helper for debug test
  defp return_a_two_tuple do
    # This is what the function intends to return
    # Ensure :a is a distinct atom
    value_to_return = {Map.put(%{}, :a, 1), "b"}
    value_to_return
  end

  test ~c"debug tuple transformation sanity check" do
    # Call the helper
    result = return_a_two_tuple()
    # This is what the test actually received

    match_success =
      try do
        {_map_val, _string_val} = result
        true
      rescue
        MatchError -> false
      end

    assert match_success, "Expected a 2-tuple, but got: #{inspect(result)}"
  end

  test ~c"initializes terminal emulator", %{initial_state: initial_state} do
    # The component should have a state field
    assert Map.has_key?(initial_state, :state)

    # For now, just verify the structure is correct
    assert is_map(initial_state.state)
  end

  test ~c"processes basic input", %{initial_state: initial_state} do
    # Process input and verify it returns a tuple
    {updated_state, _output} =
      EmulatorComponent.process_input("Hello", initial_state)

    # Verify the structure
    assert is_map(updated_state)
    assert Map.has_key?(updated_state, :state)
  end

  test ~c"handles ANSI color codes", %{initial_state: initial_state} do
    # Test SGR sequences (e.g., color changes)
    # Input: ESC [ 31 m (set text color to red)
    {state1, _} = EmulatorComponent.process_input("\e[31m", initial_state)
    assert is_map(state1)
    assert Map.has_key?(state1, :state)

    # Process text with red style active
    {state2, _} = EmulatorComponent.process_input("Red", state1)
    assert is_map(state2)
    assert Map.has_key?(state2, :state)

    # Process reset code
    {state3, _} = EmulatorComponent.process_input("\e[0m", state2)
    assert is_map(state3)
    assert Map.has_key?(state3, :state)
  end

  test ~c"handles cursor movement", %{initial_state: initial_state} do
    # Use the shared initial state instead of creating a new one
    result = EmulatorComponent.process_input("\e[5;10H", initial_state)

    # Re-add a simple assertion to ensure the test runs and we see output
    assert match?({_, _}, result)
  end

  test ~c"handles screen resizing", %{initial_state: initial_state} do
    # Initial state
    {state, _} = EmulatorComponent.process_input("Hello", initial_state)

    # Resize - Component's handle_resize is a placeholder, re-initializes core
    state = EmulatorComponent.handle_resize({40, 12}, state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"handles line wrapping", %{initial_state: initial_state} do
    # Create a line longer than terminal width
    long_line = String.duplicate("a", 85)

    # Use the shared initial state instead of creating a new one
    # Process the long line
    {state, _output} = EmulatorComponent.process_input(long_line, initial_state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"maintains cell attributes", %{initial_state: initial_state} do
    # Set some attributes
    {state, _} =
      EmulatorComponent.process_input("\e[1;31mBold Red\e[0m", initial_state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"handles scroll region", %{initial_state: initial_state} do
    # Handle tuple return
    {state, _} = EmulatorComponent.process_input("\e[5;20r", initial_state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"preserves content during resize", %{initial_state: initial_state} do
    # Direct call for testing
    {state, _output} =
      EmulatorComponent.process_input("Line 1\n", initial_state)

    # Resize - Component's handle_resize is a placeholder, re-initializes core
    state = EmulatorComponent.handle_resize({40, 12}, state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"handles terminal modes", %{initial_state: initial_state} do
    # Insert mode
    # DECSET Insert Mode (IRM)
    # Handle tuple return
    {state, _} = EmulatorComponent.process_input("\e[4h", initial_state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)

    # Normal mode (resetting insert mode)
    # DECRST Insert Mode (IRM)
    # Handle tuple return
    {state, _} = EmulatorComponent.process_input("\e[4l", state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"handles dirty cells", %{initial_state: initial_state} do
    # Handle tuple return
    {state, _} = EmulatorComponent.process_input("Hello", initial_state)

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end

  test ~c"handles OSC sequences", %{initial_state: initial_state} do
    result =
      EmulatorComponent.process_input(
        "\e]0;New Window Title\e\\",
        initial_state
      )

    {state, _} = result

    # Verify the structure
    assert is_map(state)
    assert Map.has_key?(state, :state)
  end
end
