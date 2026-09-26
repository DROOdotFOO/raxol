defmodule Raxol.Terminal.Integration.Renderer do
  @moduledoc """
  Handles terminal output rendering and display management using Termbox2.
  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.Integration.State
  alias Raxol.Terminal.ScreenBuffer.Manager

  @doc """
  Initializes the underlying terminal system.
  Must be called before other rendering functions.
  Returns :ok or {:error, reason}.
  """
  def init_terminal do
    init_terminal_by_mode(Application.get_env(:raxol, :terminal_test_mode, false))
  end

  @doc """
  Shuts down the underlying terminal system.
  Must be called to restore terminal state.
  Returns :ok or {:error, reason}.
  """
  def shutdown_terminal do
    shutdown_terminal_by_mode(Application.get_env(:raxol, :terminal_test_mode, false))
  end

  @doc """
  Renders the current terminal state to the screen.
  Returns :ok or {:error, reason}.
  """
  def render(%State{} = state) do
    active_buffer = Manager.get_active_buffer(state.buffer_manager)

    render_buffer_if_present(active_buffer, state)
  end

  defp handle_cursor_and_present(state) do
    handle_cursor_by_mode(
      state,
      Application.get_env(:raxol, :terminal_test_mode, false)
    )
  end

  defp present_buffer do
    present_buffer_by_mode(Application.get_env(:raxol, :terminal_test_mode, false))
  end

  @doc """
  Gets the current terminal dimensions.
  Returns {:ok, {width, height}} or {:error, :dimensions_unavailable}.
  Note: termbox2 width/height C functions return int, not status codes.
  A negative value might indicate an error (e.g., not initialized).
  """
  def get_dimensions do
    get_dimensions_by_mode(Application.get_env(:raxol, :terminal_test_mode, false))
  end

  @doc """
  Clears the terminal screen (specifically, the back buffer).
  Call present/0 afterwards to make it visible.
  Returns :ok or {:error, reason}.
  """
  def clear_screen(%State{} = _state) do
    clear_screen_by_mode(Application.get_env(:raxol, :terminal_test_mode, false))
  end

  defp clear_and_present do
    case :termbox2_nif.tb_clear() do
      :ok -> present_buffer()
      clear_error_code -> {:error, {:clear_failed, clear_error_code}}
    end
  end

  @doc """
  Moves the hardware cursor to a specific position on the screen.
  Call present/0 afterwards if you want to ensure it's shown with other changes.
  The cursor position is typically updated with present/0.
  Returns :ok or {:error, reason}.
  """
  def move_cursor(%State{} = _state, x, y) do
    move_cursor_by_mode(
      x,
      y,
      Application.get_env(:raxol, :terminal_test_mode, false)
    )
  end

  defp set_cursor_and_present(x, y) do
    case :termbox2_nif.tb_set_cursor(x, y) do
      :ok ->
        present_buffer()

      set_cursor_error_code ->
        {:error, {:set_cursor_failed, set_cursor_error_code}}
    end
  end

  @doc """
  Creates a new renderer with the given options.
  """
  def new(opts \\ []) do
    # Initialize terminal if not in test mode
    case init_terminal() do
      :ok ->
        # Create initial state with configuration
        config = build_initial_config(opts)

        state = %State{
          width: Map.get(config, :width, 80),
          height: Map.get(config, :height, 24),
          config: config
        }

        {:ok, state}

      error ->
        error
    end
  end

  @doc """
  Updates the renderer configuration.
  """
  def update_config(%State{} = state, config) do
    # Merge new config with existing config
    updated_config = Map.merge(state.config || %{}, config)

    # Apply configuration changes
    case apply_config_changes(updated_config) do
      :ok ->
        %{state | config: updated_config}

      {:error, reason} ->
        Log.error("Failed to apply renderer configuration: #{inspect(reason)}")

        state
    end
  end

  @doc """
  Sets a specific configuration value.
  """
  def set_config_value(%State{} = state, key, value) do
    # Update the specific key in the config
    updated_config = Map.put(state.config || %{}, key, value)

    # Apply the configuration change
    case apply_config_value(key, value) do
      :ok ->
        %{state | config: updated_config}

      {:error, reason} ->
        Log.error("Failed to set config value #{key}: #{inspect(reason)}")

        state
    end
  end

  @doc """
  Resets the renderer configuration to defaults.
  """
  def reset_config(%State{} = state) do
    # Get default configuration
    default_config = build_initial_config([])

    # Apply default configuration
    case apply_config_changes(default_config) do
      :ok ->
        %{state | config: default_config}

      {:error, reason} ->
        Log.error("Failed to reset renderer configuration: #{inspect(reason)}")

        state
    end
  end

  @doc """
  Resizes the renderer to the given dimensions.
  """
  def resize(%State{} = state, width, height)
      when is_integer(width) and is_integer(height) do
    resize_by_mode(
      state,
      width,
      height,
      Application.get_env(:raxol, :terminal_test_mode, false)
    )
  end

  @doc """
  Sets the cursor visibility.
  """
  def set_cursor_visibility(%State{} = state, visible)
      when is_boolean(visible) do
    set_cursor_visibility_by_mode(
      state,
      visible,
      Application.get_env(:raxol, :terminal_test_mode, false)
    )
  end

  @doc """
  Sets the terminal title.
  """
  def set_title(%State{} = state, title) when is_binary(title) do
    set_title_by_mode(
      state,
      title,
      Application.get_env(:raxol, :terminal_test_mode, false)
    )
  end

  @doc """
  Gets the terminal title.
  """
  def get_title(%State{} = state) do
    # Return the title from our state
    Map.get(state.config || %{}, :title, "")
  end

  # Private helper functions

  defp build_initial_config(opts) when is_list(opts) do
    %{
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      cursor_visible: Keyword.get(opts, :cursor_visible, true),
      title: Keyword.get(opts, :title, "Raxol Terminal"),
      theme: Keyword.get(opts, :theme, %{foreground: :white, background: :black}),
      fps: Keyword.get(opts, :fps, 60),
      font_settings: Keyword.get(opts, :font_settings, %{size: 12})
    }
  end

  defp build_initial_config(opts) when is_map(opts) do
    %{
      width: Map.get(opts, :width, 80),
      height: Map.get(opts, :height, 24),
      cursor_visible: Map.get(opts, :cursor_visible, true),
      title: Map.get(opts, :title, "Raxol Terminal"),
      theme: Map.get(opts, :theme, %{foreground: :white, background: :black}),
      fps: Map.get(opts, :fps, 60),
      font_settings: Map.get(opts, :font_settings, %{size: 12})
    }
  end

  defp build_initial_config(_) do
    %{
      width: 80,
      height: 24,
      cursor_visible: true,
      title: "Raxol Terminal",
      theme: %{foreground: :white, background: :black},
      fps: 60,
      font_settings: %{size: 12}
    }
  end

  defp apply_config_changes(config) do
    apply_theme_if_present(config)
  end

  defp apply_config_value(:cursor_visible, visible) do
    set_terminal_cursor_visibility(visible)
  end

  defp apply_config_value(:title, title) do
    case :termbox2_nif.tb_set_title(title) do
      {:ok, ~c"set"} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp apply_config_value(:theme, theme) do
    apply_theme_config(theme)
  end

  defp apply_config_value(_key, _value) do
    # For other config values, just return success
    :ok
  end

  defp apply_theme_config(theme) do
    # Apply theme colors to terminal
    # Note: Termbox2 doesn't have a direct theme setting function,
    # so we just validate the theme structure
    case validate_theme(theme) do
      :ok -> :ok
      error -> error
    end
  end

  defp set_terminal_cursor_visibility(visible) do
    set_cursor_visibility_state(visible)
  end

  defp validate_dimensions(width, _height) when width <= 0 do
    {:error, {:invalid_width, width}}
  end

  defp validate_dimensions(_width, height) when height <= 0 do
    {:error, {:invalid_height, height}}
  end

  defp validate_dimensions(width, _height) when width > 1000 do
    {:error, {:width_too_large, width}}
  end

  defp validate_dimensions(_width, height) when height > 1000 do
    {:error, {:height_too_large, height}}
  end

  defp validate_dimensions(_width, _height) do
    :ok
  end

  defp validate_theme(theme) when is_map(theme) do
    # Basic theme validation
    required_keys = [:foreground, :background]

    case Enum.find(required_keys, fn key -> !Map.has_key?(theme, key) end) do
      nil -> :ok
      missing_key -> {:error, {:missing_theme_key, missing_key}}
    end
  end

  defp validate_theme(_theme) do
    {:error, :invalid_theme_format}
  end

  ## Helper functions for refactored if statements

  defp init_terminal_by_mode(true) do
    Log.info("[Renderer] Test mode detected, skipping actual terminal initialization")

    :ok
  end

  defp init_terminal_by_mode(false) do
    Log.info("[Renderer] Attempting to call :termbox2_nif.tb_init()")

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           raw_init_result = :termbox2_nif.tb_init()

           case raw_init_result do
             0 ->
               Log.info("[Renderer] :termbox2_nif.tb_init() returned 0 (success)")

               :ok

             int_val when is_integer(int_val) ->
               Log.warning(
                 "Terminal integration renderer failed to initialize: #{inspect(int_val)}",
                 %{error: int_val}
               )

               {:error, {:init_failed_with_code, int_val}}

             other ->
               Log.error(
                 "[Renderer] Termbox2 NIF tb_init() returned unexpected value: #{inspect(other)}"
               )

               {:error, {:init_failed_unexpected_return, other}}
           end
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Log.error("""
        [Renderer] Caught exception/exit during :termbox2_nif.tb_init() call.
        Reason: #{inspect(reason)}
        """)

        {:error, {:init_failed_exception, reason}}
    end
  end

  defp shutdown_terminal_by_mode(true) do
    Log.info("[Renderer] Test mode detected, skipping actual terminal shutdown")
    :ok
  end

  defp shutdown_terminal_by_mode(false) do
    Log.info("[Renderer] Attempting to call :termbox2_nif.tb_shutdown()")

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           :termbox2_nif.tb_shutdown()
           Log.info("[Renderer] :termbox2_nif.tb_shutdown() called.")
           :ok
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Log.error("""
        [Renderer] Caught exception/exit during :termbox2_nif.tb_shutdown() call.
        Reason: #{inspect(reason)}
        """)

        {:error, {:shutdown_failed_exception, reason}}
    end
  end

  defp render_buffer_if_present(%{cells: cells}, state)
       when not is_nil(cells) do
    case Raxol.Terminal.Integration.CellRenderer.render(cells) do
      :ok -> handle_cursor_and_present(state)
      error -> error
    end
  end

  defp render_buffer_if_present(_active_buffer, _state) do
    :ok
  end

  defp handle_cursor_by_mode(_state, true) do
    # In test mode, just return success
    :ok
  end

  defp handle_cursor_by_mode(state, false) do
    {cursor_x, cursor_y} = CursorManager.get_position(state.cursor_manager)

    case :termbox2_nif.tb_set_cursor(cursor_x, cursor_y) do
      :ok -> present_buffer()
      error_code -> {:error, {:set_cursor_failed, error_code}}
    end
  end

  defp present_buffer_by_mode(true) do
    # In test mode, just return success
    :ok
  end

  defp present_buffer_by_mode(false) do
    case :termbox2_nif.tb_present() do
      :ok -> :ok
      error_code -> {:error, {:present_failed, error_code}}
    end
  end

  defp get_dimensions_by_mode(true) do
    # Return mock dimensions for tests
    {:ok, {80, 24}}
  end

  defp get_dimensions_by_mode(false) do
    width = :termbox2_nif.tb_width()
    height = :termbox2_nif.tb_height()

    validate_terminal_dimensions(width, height)
  end

  defp validate_terminal_dimensions(width, height)
       when width >= 0 and height >= 0 do
    {:ok, {width, height}}
  end

  defp validate_terminal_dimensions(width, height) do
    # Assuming negative values mean error/not initialized
    {:error, {:dimensions_unavailable, width: width, height: height}}
  end

  defp clear_screen_by_mode(true) do
    # In test mode, just return success
    :ok
  end

  defp clear_screen_by_mode(false) do
    clear_and_present()
  end

  defp move_cursor_by_mode(_x, _y, true) do
    # In test mode, just return success
    :ok
  end

  defp move_cursor_by_mode(x, y, false) do
    set_cursor_and_present(x, y)
  end

  defp resize_by_mode(state, width, height, true) do
    # In test mode, just update the state
    %{state | width: width, height: height}
  end

  defp resize_by_mode(state, width, height, false) do
    # In real mode, we need to handle terminal resize
    # Note: Termbox2 doesn't have a direct resize function, so we update our state
    # and let the next render cycle handle the new dimensions
    case validate_dimensions(width, height) do
      :ok ->
        %{state | width: width, height: height}

      {:error, reason} ->
        Log.error("Invalid resize dimensions: #{inspect(reason)}")
        state
    end
  end

  defp set_cursor_visibility_by_mode(state, visible, true) do
    # In test mode, just update the state
    %{state | config: Map.put(state.config || %{}, :cursor_visible, visible)}
  end

  defp set_cursor_visibility_by_mode(state, visible, false) do
    # In real mode, use termbox2 to hide/show cursor
    case set_terminal_cursor_visibility(visible) do
      :ok ->
        %{
          state
          | config: Map.put(state.config || %{}, :cursor_visible, visible)
        }

      {:error, reason} ->
        Log.error("Failed to set cursor visibility: #{inspect(reason)}")
        state
    end
  end

  defp set_title_by_mode(state, title, true) do
    # In test mode, just update the state
    %{state | config: Map.put(state.config || %{}, :title, title)}
  end

  defp set_title_by_mode(state, title, false) do
    # In real mode, use termbox2 to set the title
    case :termbox2_nif.tb_set_title(title) do
      {:ok, ~c"set"} ->
        %{state | config: Map.put(state.config || %{}, :title, title)}

      {:error, reason} ->
        Log.error("Failed to set terminal title: #{inspect(reason)}")
        state

      other ->
        Log.error("Unexpected response from tb_set_title: #{inspect(other)}")

        state
    end
  end

  defp apply_theme_if_present(%{theme: theme}) do
    case apply_theme_config(theme) do
      :ok -> :ok
      error -> error
    end
  end

  defp apply_theme_if_present(_config) do
    :ok
  end

  defp set_cursor_visibility_state(true) do
    # Show cursor by setting it to a valid position (will be updated during render)
    :ok
  end

  defp set_cursor_visibility_state(false) do
    # Hide cursor by setting it to -1, -1
    case :termbox2_nif.tb_set_cursor(-1, -1) do
      :ok -> :ok
      error_code -> {:error, {:hide_cursor_failed, error_code}}
    end
  end
end
