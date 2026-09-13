defmodule Raxol.Terminal.ModeManager do
  @moduledoc """
  Manages terminal modes (DEC Private Modes, Standard Modes) and their effects.

  This module centralizes the state and logic for various terminal modes,
  handling both simple flag toggles and modes with side effects on the
  emulator state (like screen buffer switching or resizing).
  """
  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.ModeManager.SavedState

  alias Raxol.Terminal.Modes.Handlers.{
    DECPrivateHandler,
    StandardHandler
  }

  alias Raxol.Terminal.Modes.Types.ModeTypes

  @type mode :: atom()

  defstruct cursor_visible: true,
            auto_wrap: true,
            origin_mode: false,
            insert_mode: false,
            line_feed_mode: false,
            column_width_mode: :normal,
            cursor_keys_mode: :normal,
            screen_mode_reverse: false,
            auto_repeat_mode: true,
            interlacing_mode: false,
            alternate_buffer_active: false,
            mouse_report_mode: :none,
            mouse_encoding: :x10,
            focus_events_enabled: false,
            alt_screen_mode: nil,
            bracketed_paste_mode: false,
            active_buffer_type: :main

  @type t :: %__MODULE__{}

  # --- Mode Lookup ---

  @doc """
  Looks up a DEC private mode code and returns the corresponding mode atom.
  """
  def lookup_private(code) when is_integer(code) do
    case ModeTypes.lookup_private(code) do
      nil -> nil
      mode_def -> mode_def.name
    end
  end

  @doc """
  Looks up a standard mode code and returns the corresponding mode atom.
  """
  def lookup_standard(code) when is_integer(code) do
    case ModeTypes.lookup_standard(code) do
      nil -> nil
      mode_def -> mode_def.name
    end
  end

  # --- Mode Setting/Resetting ---

  @doc """
  Sets one or more modes. Dispatches to specific handlers.
  Returns potentially updated Emulator state if side effects occurred.
  """
  def set_mode(emulator, modes, category \\ nil) when is_list(modes) do
    Log.debug(
      "ModeManager.set_mode/2 called with modes=#{inspect(modes)}, category=#{inspect(category)}"
    )

    Log.debug(
      "ModeManager.set_mode/2: initial emulator mode_manager=#{inspect(emulator.mode_manager)}"
    )

    result =
      Enum.reduce_while(modes, {:ok, emulator}, fn mode, {:ok, emu} ->
        case do_set_mode(mode, emu, category) do
          {:ok, new_emu} ->
            Log.debug(
              "ModeManager.set_mode/2: mode #{inspect(mode)} set successfully, new_emu.mode_manager=#{inspect(new_emu.mode_manager)}"
            )

            {:cont, {:ok, new_emu}}

          {:error, reason} ->
            Log.debug(
              "ModeManager.set_mode/2: mode #{inspect(mode)} failed with reason=#{inspect(reason)}"
            )

            {:halt, {:error, reason}}
        end
      end)

    Log.debug("ModeManager.set_mode/2: final result=#{inspect(result)}")
    result
  end

  @doc """
  Sets a mode with a value and options.
  """
  def set_mode(emulator, mode_name, _value, options) do
    category = Keyword.get(options, :category, nil)

    case do_set_mode(mode_name, emulator, category) do
      {:ok, new_emu} -> {:ok, new_emu}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resets one or more modes. Dispatches to specific handlers.
  Returns potentially updated Emulator state if side effects occurred.
  """
  def reset_mode(emulator, modes, category \\ nil) when is_list(modes) do
    Enum.reduce_while(modes, {:ok, emulator}, fn mode, {:ok, emu} ->
      case do_reset_mode(mode, emu, category) do
        {:ok, new_emu} -> {:cont, {:ok, new_emu}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def mode_enabled?(state, mode) do
    mode_mapping = %{
      irm: state.insert_mode,
      lnm: state.line_feed_mode,
      decom: state.origin_mode,
      decawm: state.auto_wrap,
      dectcem: state.cursor_visible,
      decscnm: state.screen_mode_reverse,
      decarm: state.auto_repeat_mode,
      decinlm: state.interlacing_mode,
      bracketed_paste: state.bracketed_paste_mode,
      decckm: state.cursor_keys_mode == :application,
      deccolm_132: state.column_width_mode == :wide,
      deccolm_80: state.column_width_mode == :normal,
      dec_alt_screen: state.alternate_buffer_active,
      dec_alt_screen_save: state.alternate_buffer_active,
      alt_screen_buffer: state.alternate_buffer_active,
      focus_events: state.focus_events_enabled,
      mouse_report_x10: state.mouse_report_mode == :x10,
      mouse_report_cell_motion: state.mouse_report_mode == :cell_motion,
      mouse_encoding_sgr: state.mouse_encoding == :sgr
    }

    Map.get(mode_mapping, mode, false)
  end

  @doc """
  Saves the current terminal state.
  """
  def save_state(emulator) do
    SavedState.save_state(emulator)
  end

  @doc """
  Restores the previously saved terminal state.
  """
  def restore_state(emulator) do
    SavedState.restore_state(emulator)
  end

  # --- Private Set/Reset Helpers ---

  defp do_set_mode(mode_name, emulator, category) do
    with {:ok, mode_def} <- find_mode_definition(mode_name, category) do
      apply_mode_effects(mode_def, emulator, true)
    end
  end

  defp do_reset_mode(mode_name, emulator, category) do
    with {:ok, mode_def} <- find_mode_definition(mode_name, category) do
      apply_mode_effects(mode_def, emulator, false)
    end
  end

  defp find_mode_definition(mode_name, category) do
    Log.debug(
      "ModeManager.find_mode_definition/2 called with mode_name=#{inspect(mode_name)}, category=#{inspect(category)}"
    )

    search_category = if category == nil, do: :standard, else: category

    case find_mode_in_category(mode_name, search_category) do
      {:ok, mode_def} ->
        {:ok, mode_def}

      {:error, :invalid_mode} ->
        find_mode_in_fallback_categories(mode_name, search_category)
    end
  end

  defp find_mode_in_category(mode_name, category) do
    case ModeTypes.get_all_modes()
         |> Map.values()
         |> Enum.find(fn mode_def ->
           mode_def.name == mode_name and mode_def.category == category
         end) do
      nil -> {:error, :invalid_mode}
      mode_def -> {:ok, mode_def}
    end
  end

  defp find_mode_in_fallback_categories(mode_name, :standard) do
    find_mode_in_categories(mode_name, [:dec_private, :screen_buffer, :mouse])
  end

  defp find_mode_in_fallback_categories(mode_name, :dec_private) do
    find_mode_in_categories(mode_name, [:screen_buffer, :mouse])
  end

  defp find_mode_in_fallback_categories(mode_name, :mouse) do
    find_mode_in_categories(mode_name, [:dec_private, :screen_buffer])
  end

  defp find_mode_in_fallback_categories(_mode_name, _category) do
    {:error, :invalid_mode}
  end

  defp find_mode_in_categories(mode_name, categories) do
    case ModeTypes.get_all_modes()
         |> Map.values()
         |> Enum.find(fn mode_def ->
           mode_def.name == mode_name and mode_def.category in categories
         end) do
      nil -> {:error, :invalid_mode}
      mode_def -> {:ok, mode_def}
    end
  end

  defp apply_mode_effects(mode_def, emulator, value) do
    Log.debug(
      "ModeManager.apply_mode_effects called with mode_def=#{inspect(mode_def)}, value=#{inspect(value)}"
    )

    case mode_def.category do
      :dec_private ->
        Log.debug("ModeManager.apply_mode_effects: routing to DECPrivateHandler")

        DECPrivateHandler.handle_mode_change(mode_def.name, value, emulator)

      :screen_buffer ->
        Log.debug("ModeManager.apply_mode_effects: routing to DECPrivateHandler (screen_buffer)")

        DECPrivateHandler.handle_mode_change(mode_def.name, value, emulator)

      :mouse ->
        Log.debug("ModeManager.apply_mode_effects: routing to DECPrivateHandler (mouse)")

        DECPrivateHandler.handle_mode_change(mode_def.name, value, emulator)

      :standard ->
        Log.debug("ModeManager.apply_mode_effects: routing to StandardHandler")

        StandardHandler.handle_mode_change(mode_def.name, value, emulator)

      _ ->
        Log.debug(
          "ModeManager.apply_mode_effects: unknown category #{inspect(mode_def.category)}"
        )

        {:ok, emulator}
    end
  end

  @doc """
  Creates a new mode manager with default values.
  """
  def new do
    %__MODULE__{}
  end

  @doc """
  Sets a mode with a value and private flag.
  """
  def set_mode_with_private(emulator, mode, value, private) do
    case private do
      true -> set_private_mode(emulator, mode, value)
      false -> set_standard_mode(emulator, mode, value)
    end
  end

  @doc """
  Sets a private mode with a value.
  """
  def set_private_mode(emulator, mode, value) do
    case DECPrivateHandler.handle_mode(emulator, mode, value) do
      {:ok, new_emu} -> {:ok, new_emu}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets a standard mode with a value.
  """
  def set_standard_mode(emulator, mode, value) do
    case StandardHandler.handle_mode(emulator, mode, value) do
      {:ok, new_emu} -> {:ok, new_emu}
      {:error, reason} -> {:error, reason}
    end
  end

  # Mode update functions for emulator delegation
  @doc """
  Updates the insert mode.
  """
  def update_insert_mode(emulator, value) do
    case set_mode_with_private(emulator, :irm, value, false) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the line feed mode.
  """
  def update_line_feed_mode(emulator, value) do
    case set_mode_with_private(emulator, :lnm, value, false) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the origin mode.
  """
  def update_origin_mode(emulator, value) do
    case set_mode_with_private(emulator, :decom, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the auto wrap mode.
  """
  def update_auto_wrap_mode(emulator, value) do
    case set_mode_with_private(emulator, :decawm, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the cursor visible mode.
  """
  def update_cursor_visible(emulator, value) do
    case set_mode_with_private(emulator, :dectcem, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the screen mode reverse.
  """
  def update_screen_mode_reverse(emulator, value) do
    case set_mode_with_private(emulator, :decscnm, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the auto repeat mode.
  """
  def update_auto_repeat_mode(emulator, value) do
    case set_mode_with_private(emulator, :decarm, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the interlacing mode.
  """
  def update_interlacing_mode(emulator, value) do
    case set_mode_with_private(emulator, :decinlm, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the bracketed paste mode.
  """
  def update_bracketed_paste_mode(emulator, value) do
    case set_mode_with_private(emulator, :bracketed_paste, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end

  @doc """
  Updates the column width 132 mode.
  """
  def update_column_width_132(emulator, value) do
    case set_mode_with_private(emulator, :deccolm_132, value, true) do
      {:ok, new_emu} -> new_emu
      {:error, _} -> emulator
    end
  end
end
