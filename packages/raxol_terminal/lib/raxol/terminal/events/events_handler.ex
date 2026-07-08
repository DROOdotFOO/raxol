defmodule Raxol.Terminal.Events.Handler do
  @moduledoc """
  Handles terminal events and dispatches them to appropriate handlers.
  """

  alias Raxol.Terminal.ANSI.Window.Manipulation, as: WindowManipulation

  @doc """
  Handles window-related events.
  """
  def handle_window_event(emulator_state, event) do
    case event do
      {:resize, w, h} ->
        handle_resize(emulator_state, w, h)

      {:title, title} ->
        handle_title_change(emulator_state, title)

      {:icon_name, name} ->
        handle_icon_name_change(emulator_state, name)

      _ ->
        {:error, "Unknown window event: #{inspect(event)}"}
    end
  end

  @doc """
  Handles mode change events.
  """
  def handle_mode_event(emulator_state, event) do
    case event do
      {:change, new_mode} ->
        handle_mode_change(emulator_state, new_mode)

      _ ->
        {:error, "Unknown mode event: #{inspect(event)}"}
    end
  end

  @doc """
  Handles mouse events.
  """
  def handle_mouse_event(emulator_state, event) do
    case event do
      {:click, button, x, y} ->
        handle_mouse_click(emulator_state, button, x, y)

      {:drag, button, x, y} ->
        handle_mouse_drag(emulator_state, button, x, y)

      {:release, button, x, y} ->
        handle_mouse_release(emulator_state, button, x, y)

      _ ->
        {:error, "Unknown mouse event: #{inspect(event)}"}
    end
  end

  @doc """
  Handles keyboard events.
  """
  def handle_keyboard_event(emulator_state, event) do
    case event do
      {:press, key} ->
        handle_key_press(emulator_state, key)

      {:release, key} ->
        handle_key_release(emulator_state, key)

      _ ->
        {:error, "Unknown keyboard event: #{inspect(event)}"}
    end
  end

  @doc """
  Handles focus events.
  """
  def handle_focus_event(emulator_state, event) do
    case event do
      {:gain} ->
        handle_focus_gain(emulator_state)

      {:loss} ->
        handle_focus_loss(emulator_state)

      _ ->
        {:error, "Unknown focus event: #{inspect(event)}"}
    end
  end

  @doc """
  Generic event handler that dispatches to appropriate handlers.
  """
  def handle_event(emulator_state, event) do
    case event do
      {:window, window_event} ->
        handle_window_event(emulator_state, window_event)

      {:mode, mode_event} ->
        handle_mode_event(emulator_state, mode_event)

      {:mouse, mouse_event} ->
        handle_mouse_event(emulator_state, mouse_event)

      {:keyboard, keyboard_event} ->
        handle_keyboard_event(emulator_state, keyboard_event)

      {:focus, focus_event} ->
        handle_focus_event(emulator_state, focus_event)

      _ ->
        {:error, "Unknown event type: #{inspect(event)}"}
    end
  end

  # Private helper functions

  defp handle_resize(emulator_state, w, h) do
    # Update terminal dimensions
    updated_state = %{emulator_state | width: w, height: h}

    # Clear screen and reset cursor position
    commands = [
      WindowManipulation.clear_screen(),
      WindowManipulation.move_cursor(1, 1)
    ]

    {:ok, updated_state, commands}
  end

  defp handle_title_change(emulator_state, title) do
    # Update window title
    updated_state = %{emulator_state | title: title}

    # Send title change command
    commands = [WindowManipulation.set_title(title)]

    {:ok, updated_state, commands}
  end

  defp handle_icon_name_change(emulator_state, name) do
    # Update icon name
    updated_state = %{emulator_state | icon_name: name}

    # Send icon name change command
    commands = [WindowManipulation.set_icon_name(name)]

    {:ok, updated_state, commands}
  end

  defp handle_mode_change(emulator_state, new_mode) do
    # Update terminal mode
    updated_state = %{emulator_state | mode: new_mode}

    # Send mode change command
    commands = [WindowManipulation.set_mode(new_mode)]

    {:ok, updated_state, commands}
  end

  defp handle_mouse_click(emulator_state, button, x, y) do
    # Handle mouse click
    commands = [WindowManipulation.mouse_click(button, x, y)]

    {:ok, emulator_state, commands}
  end

  defp handle_mouse_drag(emulator_state, button, x, y) do
    # Handle mouse drag
    commands = [WindowManipulation.mouse_drag(button, x, y)]

    {:ok, emulator_state, commands}
  end

  defp handle_mouse_release(emulator_state, button, x, y) do
    # Handle mouse release
    commands = [WindowManipulation.mouse_release(button, x, y)]

    {:ok, emulator_state, commands}
  end

  defp handle_key_press(emulator_state, key) do
    # Handle key press
    commands = [WindowManipulation.key_press(key)]

    {:ok, emulator_state, commands}
  end

  defp handle_key_release(emulator_state, key) do
    # Handle key release
    commands = [WindowManipulation.key_release(key)]

    {:ok, emulator_state, commands}
  end

  defp handle_focus_gain(emulator_state) do
    # Handle focus gain
    commands = [WindowManipulation.focus_gain()]

    {:ok, emulator_state, commands}
  end

  defp handle_focus_loss(emulator_state) do
    # Handle focus loss
    commands = [WindowManipulation.focus_loss()]

    {:ok, emulator_state, commands}
  end

  # === Additional Event Handlers ===

  @doc """
  Handles selection events.
  """
  @spec handle_selection_event(any(), any()) ::
          {:ok, any()} | {:error, String.t()}
  def handle_selection_event(emulator_state, event) do
    case event do
      %{start_pos: start_pos, end_pos: end_pos, text: text} ->
        # Update selection in the emulator state
        updated_state =
          update_selection_in_state(emulator_state, start_pos, end_pos, text)

        {:ok, updated_state}

      _ ->
        {:error, "Invalid selection event: #{inspect(event)}"}
    end
  end

  defp update_selection_in_state(emulator_state, start_pos, end_pos, _text) do
    # Update the screen buffer with the new selection
    updated_buffer =
      Raxol.Terminal.Buffer.Selection.start(
        emulator_state.screen_buffer,
        elem(start_pos, 0),
        elem(start_pos, 1)
      )

    updated_buffer =
      Raxol.Terminal.Buffer.Selection.update(
        updated_buffer,
        elem(end_pos, 0),
        elem(end_pos, 1)
      )

    %{emulator_state | screen_buffer: updated_buffer}
  end

  @doc """
  Handles scroll events.
  """
  @spec handle_scroll_event(any(), any()) :: {:ok, any()} | {:error, String.t()}
  def handle_scroll_event(emulator_state, event) do
    case event do
      %{direction: direction, delta: delta, position: position} ->
        # Update scroll position in the emulator state
        updated_state =
          update_scroll_in_state(emulator_state, direction, delta, position)

        {:ok, updated_state}

      _ ->
        {:error, "Invalid scroll event: #{inspect(event)}"}
    end
  end

  defp update_scroll_in_state(emulator_state, direction, delta, _position) do
    # Apply scroll operation based on direction and delta
    case direction do
      :vertical ->
        case delta > 0 do
          true ->
            # Scroll down
            Raxol.Terminal.Commands.Screen.scroll_down(emulator_state, delta)

          false ->
            # Scroll up
            Raxol.Terminal.Commands.Screen.scroll_up(emulator_state, abs(delta))
        end

      :horizontal ->
        # Horizontal scrolling not yet implemented, return unchanged state
        emulator_state

      _ ->
        emulator_state
    end
  end

  @doc """
  Handles paste events.
  """
  @spec handle_paste_event(any(), any()) :: {:ok, any()} | {:error, String.t()}
  def handle_paste_event(emulator_state, event) do
    case event do
      %{text: text} ->
        # Update the screen buffer with the pasted text
        updated_buffer =
          Raxol.Terminal.Buffer.Paste.paste(emulator_state.screen_buffer, text)

        {:ok, %{emulator_state | screen_buffer: updated_buffer}}

      _ ->
        {:error, "Invalid paste event: #{inspect(event)}"}
    end
  end

  @doc """
  Handles cursor events.
  """
  @spec handle_cursor_event(any(), any()) :: {:ok, any()} | {:error, String.t()}
  def handle_cursor_event(emulator_state, event) do
    case event do
      %{visible: visible, style: style, blink: blink, position: position} ->
        # Update cursor properties in the emulator state
        updated_state =
          update_cursor_in_state(
            emulator_state,
            visible,
            style,
            blink,
            position
          )

        {:ok, updated_state}

      _ ->
        {:error, "Invalid cursor event: #{inspect(event)}"}
    end
  end

  defp update_cursor_in_state(emulator_state, visible, style, blink, position) do
    cursor = emulator_state.cursor
    cursor = Raxol.Terminal.Cursor.Manager.set_visibility(cursor, visible)
    cursor = Raxol.Terminal.Cursor.Manager.set_style(cursor, style)
    cursor = Raxol.Terminal.Cursor.Manager.set_blink(cursor, blink)
    cursor = Raxol.Terminal.Cursor.Manager.set_position(cursor, position)

    %{emulator_state | cursor: cursor}
  end

  @doc """
  Handles clipboard events.
  """
  @spec handle_clipboard_event(any(), any()) ::
          {:ok, any()} | {:error, String.t()}
  def handle_clipboard_event(emulator_state, event) do
    case event do
      %{op: op, content: content} ->
        # Handle clipboard operations (copy, cut, etc.)
        updated_state = handle_clipboard_operation(emulator_state, op, content)
        {:ok, updated_state}

      _ ->
        {:error, "Invalid clipboard event: #{inspect(event)}"}
    end
  end

  defp handle_clipboard_operation(emulator_state, :copy, _content) do
    # Copy selected text to clipboard (implementation depends on system clipboard)
    emulator_state
  end

  defp handle_clipboard_operation(emulator_state, :cut, _content) do
    # Cut selected text to clipboard and remove from buffer
    emulator_state
  end

  defp handle_clipboard_operation(emulator_state, _op, _content) do
    # Unknown operation, return unchanged state
    emulator_state
  end
end
