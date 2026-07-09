defmodule Raxol.Plugins.ClipboardPlugin do
  @moduledoc """
  Plugin for clipboard operations in Raxol.
  """

  @behaviour Raxol.Plugins.Plugin

  # Alias the new consolidated module
  alias Raxol.System.Clipboard

  @type t :: %__MODULE__{
          # Standard Plugin fields
          name: String.t(),
          version: String.t(),
          description: String.t(),
          enabled: boolean(),
          config: map(),
          dependencies: list(map()),
          api_version: String.t(),
          # Clipboard-specific state
          selection_active: boolean(),
          # {x, y}
          selection_start: {integer(), integer()} | nil,
          # {x, y}
          selection_end: {integer(), integer()} | nil,
          last_cells_at_selection: map() | nil
        }

  defstruct [
    # Standard fields
    name: "clipboard",
    version: "0.1.0",
    description: "Handles clipboard copy and paste.",
    enabled: true,
    config: %{},
    dependencies: [],
    api_version: "1.0.1",
    # Clipboard-specific state
    selection_active: false,
    selection_start: nil,
    selection_end: nil,
    last_cells_at_selection: nil
  ]

  @impl Raxol.Plugins.Plugin
  def init(config \\ %{}) do
    # Initialize the plugin struct, merging provided config
    plugin_state = struct(__MODULE__, config)
    {:ok, plugin_state}
  end

  @impl Raxol.Plugins.Plugin
  def handle_input(
        %__MODULE__{} = state,
        %{type: :key, modifiers: mods, key: ?c} = _event
      ) do
    handle_copy_key(state, mods)
  end

  def handle_input(
        %__MODULE__{} = state,
        %{type: :key, modifiers: mods, key: ?v} = _event
      ) do
    handle_paste_key(state, mods)
  end

  # Catch-all for other map events or non-map events
  def handle_input(state, _event), do: {:ok, state}

  defp yank_selection(%__MODULE__{} = state) do
    case get_selected_text(state) do
      {:ok, text} ->
        # Call the new consolidated module
        case Clipboard.copy(text) do
          :ok ->
            Raxol.Core.Runtime.Log.debug(
              "[Clipboard] Yanked selection to clipboard: #{text}"
            )

          {:error, :command_not_found} ->
            Raxol.Core.Runtime.Log.error(
              "[Clipboard] Failed to yank selection: clipboard command not found"
            )

          {:error, {_cmd, output}} ->
            Raxol.Core.Runtime.Log.error(
              "[Clipboard] Failed to yank selection: #{output}"
            )
        end

        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  defp get_selected_text(%__MODULE__{
         selection_start: start_pos,
         selection_end: end_pos,
         last_cells_at_selection: cells
       }) do
    process_valid_selection(
      valid_selection?(start_pos, end_pos, cells),
      start_pos,
      end_pos,
      cells
    )
  end

  defp valid_selection?(start_pos, end_pos, cells) do
    is_tuple(start_pos) and tuple_size(start_pos) == 2 and
      is_tuple(end_pos) and tuple_size(end_pos) == 2 and
      is_map(cells)
  end

  defp get_selection_bounds({sx, sy}, {ex, ey}) do
    {min(sx, ex), max(sx, ex), min(sy, ey), max(sy, ey)}
  end

  defp build_selected_text(cells, min_x, max_x, min_y, max_y) do
    for y <- min_y..max_y do
      process_line(cells, y, min_x, max_x)
    end
    |> Enum.join("\n")
  end

  defp process_line(cells, y, min_x, max_x) do
    for x <- min_x..max_x do
      process_cell(Map.get(cells, {x, y}))
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp process_cell(%{char: char}) when is_integer(char), do: <<char::utf8>>
  defp process_cell(_), do: nil

  defp clear_selection(state) do
    %{state | selection_active: false, selection_start: nil, selection_end: nil}
  end

  # Reads content from the system clipboard using the consolidated module.
  defp get_clipboard_content do
    # Delegate directly to the new module
    Clipboard.paste()
  end

  @impl Raxol.Plugins.Plugin
  def get_dependencies, do: []

  @impl Raxol.Plugins.Plugin
  def get_api_version, do: "1.0.1"

  @doc """
  Returns the API version for compatibility checking.
  """
  def api_version do
    "1.0.0"
  end

  defp handle_copy_key(state, mods) do
    handle_ctrl_modifier(state, :ctrl in mods, :copy)
  end

  defp handle_paste_key(state, mods) do
    handle_ctrl_modifier(state, :ctrl in mods, :paste)
  end

  defp handle_ctrl_modifier(state, false, _action) do
    {:ok, state}
  end

  defp handle_ctrl_modifier(state, true, :copy) do
    Raxol.Core.Runtime.Log.debug("[Clipboard] Ctrl+C detected.")
    # Check for finalized selection and stored cells
    handle_copy_selection(state, has_complete_selection?(state))
  end

  defp handle_ctrl_modifier(state, true, :paste) do
    Raxol.Core.Runtime.Log.debug("[Clipboard] Ctrl+V detected.")

    case get_clipboard_content() do
      {:ok, content} when content != "" ->
        Raxol.Core.Runtime.Log.debug("[Clipboard] Pasting content: #{content}")
        # Return command for Runtime to handle
        {:ok, state, {:command, {:paste, content}}}

      {:ok, ""} ->
        Raxol.Core.Runtime.Log.debug(
          "[Clipboard] Clipboard is empty, nothing to paste."
        )

        {:ok, state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[Clipboard] Failed to get clipboard content: #{inspect(reason)}"
        )

        {:ok, state}
    end
  end

  defp has_complete_selection?(state) do
    is_tuple(state.selection_start) and is_tuple(state.selection_end) and
      is_map(state.last_cells_at_selection)
  end

  defp handle_copy_selection(state, true) do
    Raxol.Core.Runtime.Log.debug("[Clipboard] Triggering yank_selection.")
    result = yank_selection(state)
    new_state = clear_selection(state)
    # Store the yank result for debugging if needed
    new_state = Map.put(new_state, :last_yank_result, result)
    {:ok, new_state}
  end

  defp handle_copy_selection(state, false) do
    Raxol.Core.Runtime.Log.debug(
      "[Clipboard] No complete selection available for copy."
    )

    {:ok, state}
  end

  defp process_valid_selection(true, start_pos, end_pos, cells) do
    {min_x, max_x, min_y, max_y} = get_selection_bounds(start_pos, end_pos)
    {:ok, build_selected_text(cells, min_x, max_x, min_y, max_y)}
  end

  defp process_valid_selection(false, _start_pos, _end_pos, _cells) do
    {:error, :no_selection}
  end
end
