defmodule Raxol.Terminal.EventHandler do
  @moduledoc """
  Handles various terminal events including mouse, keyboard, and focus events.
  This module is responsible for processing and responding to user interactions.
  """

  alias Raxol.Terminal.ANSI.Mouse
  alias Raxol.Terminal.Emulator

  @doc """
  Processes a mouse event.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  @spec handle_mouse_event(Emulator.t(), map()) ::
          {:ok, Emulator.t()} | {:error, String.t()}
  def handle_mouse_event(emulator, %{type: :mouse_press} = event) do
    handle_mouse_press(emulator, event.button, event.x, event.y)
  end

  def handle_mouse_event(emulator, %{type: :mouse_release} = event) do
    handle_mouse_release(emulator, event.button, event.x, event.y)
  end

  def handle_mouse_event(emulator, %{type: :mouse_move} = event) do
    handle_mouse_move(emulator, event.x, event.y)
  end

  def handle_mouse_event(_emulator, invalid_event) do
    {:error, "Invalid mouse event: #{inspect(invalid_event)}"}
  end

  @doc """
  Processes a keyboard event.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  @spec handle_keyboard_event(Emulator.t(), map()) ::
          {:ok, Emulator.t()} | {:error, String.t()}
  def handle_keyboard_event(emulator, %{type: :key_press} = event) do
    handle_key_press(emulator, event.key, event.modifiers)
  end

  def handle_keyboard_event(emulator, %{type: :key_release} = event) do
    handle_key_release(emulator, event.key, event.modifiers)
  end

  def handle_keyboard_event(_emulator, invalid_event) do
    {:error, "Invalid keyboard event: #{inspect(invalid_event)}"}
  end

  @doc """
  Processes a focus event.
  Returns {:ok, updated_emulator} or {:error, reason}.
  """
  @spec handle_focus_event(Emulator.t(), atom()) ::
          {:ok, Emulator.t()} | {:error, String.t()}
  def handle_focus_event(emulator, :focus_gain) do
    handle_focus_gain(emulator)
  end

  def handle_focus_event(emulator, :focus_loss) do
    handle_focus_loss(emulator)
  end

  def handle_focus_event(_emulator, invalid_event) do
    {:error, "Invalid focus event: #{inspect(invalid_event)}"}
  end

  # Private Functions

  defp handle_mouse_press(emulator, button, x, y) do
    # Always handle selection for left button regardless of mouse reporting mode
    emulator = handle_button_selection(emulator, button, x, y)

    case Emulator.get_mode_manager(emulator).mouse_report_mode do
      :none ->
        {:ok, emulator}

      :x10 ->
        process_mouse_button_event(emulator, :press, button, x, y)

      :cell_motion ->
        process_mouse_any_event(emulator, :press, button, x, y)

      _ ->
        {:ok, emulator}
    end
  end

  defp handle_mouse_release(emulator, button, x, y) do
    # Handle selection end for left button
    emulator = handle_button_release(emulator, button)

    case Emulator.get_mode_manager(emulator).mouse_report_mode do
      :none ->
        {:ok, emulator}

      :x10 ->
        process_mouse_button_event(emulator, :release, button, x, y)

      :cell_motion ->
        process_mouse_any_event(emulator, :release, button, x, y)

      _ ->
        {:ok, emulator}
    end
  end

  defp handle_mouse_move(emulator, x, y) do
    # Handle selection drag if active
    emulator = handle_selection_drag_if_active(emulator, x, y)

    case Emulator.get_mode_manager(emulator).mouse_report_mode do
      :none ->
        {:ok, emulator}

      :x10 ->
        # X10 mode doesn't report move events
        {:ok, emulator}

      :cell_motion ->
        process_mouse_move_event(emulator, x, y)

      _ ->
        {:ok, emulator}
    end
  end

  defp handle_key_press(emulator, key, modifiers) do
    case Emulator.get_mode_manager(emulator).keyboard_mode do
      :normal ->
        process_normal_key_press(emulator, key, modifiers)

      :application ->
        process_application_key_press(emulator, key, modifiers)
    end
  end

  defp handle_key_release(emulator, key, modifiers) do
    case Emulator.get_mode_manager(emulator).keyboard_mode do
      :normal ->
        process_normal_key_release(emulator, key, modifiers)

      :application ->
        process_application_key_release(emulator, key, modifiers)
    end
  end

  defp handle_focus_gain(emulator) do
    # Restore cursor visibility and other focus-related states
    emulator = Emulator.set_cursor_visibility(emulator, true)
    {:ok, emulator}
  end

  defp handle_focus_loss(emulator) do
    # Save cursor visibility and other focus-related states
    emulator = Emulator.set_cursor_visibility(emulator, false)
    {:ok, emulator}
  end

  # Mouse Event Processing

  defp process_mouse_button_event(emulator, type, button, x, y) do
    {term_x, term_y} = convert_to_terminal_coordinates(emulator, x, y)
    command = encode_mouse_event(emulator, type, button, term_x, term_y)

    {updated_emulator, _} = Emulator.process_input(emulator, command)
    {:ok, updated_emulator}
  end

  defp process_mouse_any_event(emulator, type, button, x, y) do
    process_mouse_button_event(emulator, type, button, x, y)
  end

  defp process_mouse_move_event(emulator, x, y) do
    {term_x, term_y} = convert_to_terminal_coordinates(emulator, x, y)
    command = encode_mouse_event(emulator, :move, :left, term_x, term_y)

    {updated_emulator, _} = Emulator.process_input(emulator, command)
    {:ok, updated_emulator}
  end

  # Keyboard Event Processing

  defp process_normal_key_press(emulator, key, modifiers) do
    command = generate_normal_key_command(key, modifiers)

    {updated_emulator, _} = Emulator.process_input(emulator, command)
    {:ok, updated_emulator}
  end

  defp process_application_key_press(emulator, key, modifiers) do
    command = generate_application_key_command(key, modifiers)

    {updated_emulator, _} = Emulator.process_input(emulator, command)
    {:ok, updated_emulator}
  end

  defp process_normal_key_release(emulator, _key, _modifiers) do
    {:ok, emulator}
  end

  defp process_application_key_release(emulator, _key, _modifiers) do
    {:ok, emulator}
  end

  # Helper Functions

  defp convert_to_terminal_coordinates(_emulator, x, y) do
    # Convert pixel coordinates to cell coordinates
    # For now, assume direct mapping - this could be enhanced based on font metrics
    {x, y}
  end

  defp encode_mouse_event(emulator, type, button, x, y) do
    encoding = Emulator.get_mode_manager(emulator).mouse_encoding
    Mouse.format_mouse_event({button, type, x, y}, encoding)
  end

  defp generate_normal_key_command(_key, _modifiers) do
    ""
  end

  # Mouse selection handling functions

  defp handle_mouse_selection_start(emulator, x, y) do
    alias Raxol.Terminal.Selection.Manager

    # Initialize selection manager if not present
    selection_manager = emulator.selection_manager || Manager.new()

    # Convert screen coordinates to terminal coordinates
    {term_x, term_y} = convert_to_terminal_coordinates(emulator, x, y)

    # Start new selection
    updated_selection_manager =
      Manager.start_selection(selection_manager, {term_x, term_y})

    %{emulator | selection_manager: updated_selection_manager}
  end

  defp handle_mouse_selection_drag(emulator, x, y) do
    alias Raxol.Terminal.Selection.Manager

    case {emulator.selection_manager,
          emulator.selection_manager && emulator.selection_manager.active} do
      {nil, _} ->
        emulator

      {_manager, false} ->
        emulator

      {manager, true} ->
        # Convert screen coordinates to terminal coordinates
        {term_x, term_y} = convert_to_terminal_coordinates(emulator, x, y)

        # Update selection end position
        updated_selection_manager =
          Manager.update_selection(manager, {term_x, term_y})

        %{emulator | selection_manager: updated_selection_manager}
    end
  end

  defp handle_mouse_selection_end(emulator) do
    # Selection remains active until explicitly cleared
    # This allows for copy operations after selection is made
    emulator
  end

  defp generate_application_key_command(_key, _modifiers) do
    ""
  end

  # Helper functions for button handling
  defp handle_button_selection(emulator, :left, x, y) do
    handle_mouse_selection_start(emulator, x, y)
  end

  defp handle_button_selection(emulator, _button, _x, _y) do
    emulator
  end

  defp handle_button_release(emulator, :left) do
    handle_mouse_selection_end(emulator)
  end

  defp handle_button_release(emulator, _button) do
    emulator
  end

  defp handle_selection_drag_if_active(emulator, x, y) do
    case {emulator.selection_manager,
          emulator.selection_manager && emulator.selection_manager.active} do
      {nil, _} -> emulator
      {_manager, false} -> emulator
      {_manager, true} -> handle_mouse_selection_drag(emulator, x, y)
    end
  end
end
