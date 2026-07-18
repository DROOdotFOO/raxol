defmodule Raxol.Terminal.Emulator.Struct do
  @moduledoc """
  Provides terminal emulator structure and related functionality.
  """

  alias Raxol.Terminal.ScreenBuffer

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  # Helper functions for cursor operations with pattern matching
  defp call_cursor_operation(cursor, operation) when is_pid(cursor) do
    GenServer.call(cursor, operation)
    cursor
  end

  defp call_cursor_operation(cursor, {:move_to, col, row, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_to(cursor, row, col, width, height)
  end

  defp call_cursor_operation(cursor, {:move_up, lines, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_up(cursor, lines, width, height)
  end

  defp call_cursor_operation(cursor, {:move_down, lines, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_down(cursor, lines, width, height)
  end

  defp call_cursor_operation(cursor, {:move_right, cols, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_right(cursor, cols, width, height)
  end

  defp call_cursor_operation(cursor, {:move_left, cols, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_left(cursor, cols, width, height)
  end

  defp call_cursor_operation(cursor, :move_to_line_start) when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_to_line_start(cursor)
  end

  defp call_cursor_operation(cursor, {:move_to_column, column, width, height})
       when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.move_to_column(cursor, column, width, height)
  end

  # Subset of Emulator fields for serialization/construction -- mirrors parent struct
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :active_buffer,
    :active_buffer_type,
    :alternate_screen_buffer,
    :buffer,
    :charset_state,
    :client_options,
    :color_palette,
    :command,
    :command_history,
    :config,
    :current_command_buffer,
    :current_hyperlink_url,
    :cursor,
    :cursor_manager,
    :cursor_style,
    :event,
    :height,
    :icon_name,
    :last_col_exceeded,
    :last_key_event,
    :main_screen_buffer,
    :max_command_history,
    :memory_limit,
    :mode_manager,
    :output_buffer,
    :parser_state,
    :plugin_manager,
    :saved_cursor,
    :scroll_region,
    :scrollback_buffer,
    :scrollback_limit,
    :session_id,
    :state,
    :state_stack,
    :style,
    :tab_stops,
    :width,
    :window_manager,
    :window_title,
    :current_hyperlink
  ]

  @type t :: %__MODULE__{
          active_buffer_type: :main | :alternate,
          active_buffer: ScreenBuffer.t(),
          scrollback_buffer: [ScreenBuffer.t()],
          cursor_manager: term(),
          mode_manager: term(),
          command_history: [String.t()],
          current_command_buffer: String.t(),
          style: map(),
          color_palette: map(),
          tab_stops: [integer()],
          cursor: %{
            position: {integer(), integer()},
            style: atom(),
            visible: boolean(),
            blink_state: boolean()
          },
          cursor_style: atom(),
          saved_cursor:
            %{
              position: {integer(), integer()},
              style: atom(),
              visible: boolean(),
              blink_state: boolean()
            }
            | nil,
          charset_state: %{
            g0: atom(),
            g1: atom(),
            g2: atom(),
            g3: atom(),
            gl: atom(),
            gr: atom(),
            single_shift: atom() | nil
          },
          width: non_neg_integer(),
          height: non_neg_integer(),
          main_screen_buffer: ScreenBuffer.t(),
          alternate_screen_buffer: ScreenBuffer.t(),
          scrollback_limit: non_neg_integer(),
          memory_limit: non_neg_integer(),
          max_command_history: non_neg_integer(),
          plugin_manager: term(),
          session_id: String.t(),
          client_options: map(),
          state: atom(),
          window_manager: term(),
          command: term(),
          config: term(),
          buffer: term(),
          event: term(),
          window_title: String.t() | nil,
          state_stack: list(),
          last_col_exceeded: boolean(),
          icon_name: String.t() | nil,
          current_hyperlink_url: String.t() | nil,
          scroll_region: {non_neg_integer(), non_neg_integer()} | nil,
          last_key_event: term(),
          output_buffer: String.t(),
          parser_state: term()
        }

  @doc """
  Creates a new terminal emulator with the given options.
  """
  @spec new(non_neg_integer(), non_neg_integer(), keyword()) :: map()
  def new(width, height, opts \\ []) do
    active_buffer = ScreenBuffer.new(width, height)
    scrollback_buffer = []

    initialize_emulator(
      active_buffer,
      scrollback_buffer,
      Keyword.put(opts, :width, width)
    )
  end

  @doc """
  Gets the active buffer from the emulator.
  """
  @spec get_screen_buffer(t()) :: ScreenBuffer.t()
  def get_screen_buffer(emulator) do
    case emulator.active_buffer_type do
      :main -> emulator.main_screen_buffer
      :alternate -> emulator.alternate_screen_buffer
      _ -> emulator.main_screen_buffer
    end
  end

  @doc """
  Checks if scrolling is needed and performs it if necessary.
  """
  @spec maybe_scroll(t()) :: t()
  def maybe_scroll(emulator) do
    case needs_scroll?(emulator) do
      true -> perform_scroll(emulator)
      false -> emulator
    end
  end

  @doc """
  Gets the cursor position from the emulator.
  """
  @spec get_cursor_position(t()) :: {non_neg_integer(), non_neg_integer()}
  def get_cursor_position(emulator) do
    {emulator.cursor.row, emulator.cursor.col}
  end

  @doc """
  Processes input for the emulator.
  """
  @spec process_input(t(), String.t()) :: {t(), String.t()}
  def process_input(emulator, input) do
    # For now, just return the emulator unchanged and the input as output
    # This is a placeholder implementation
    {emulator, input}
  end

  @doc """
  Sets a terminal mode.
  """
  @spec set_mode(t(), atom()) :: t()
  def set_mode(emulator, mode) do
    case mode do
      :show_cursor ->
        %{emulator | cursor: %{emulator.cursor | visible: true}}

      :insert_mode ->
        %{emulator | state: :insert}

      :irm ->
        %{emulator | state: :insert}

      _ ->
        # For other modes, just return the emulator unchanged
        emulator
    end
  end

  @doc """
  Resets a terminal mode.
  """
  @spec reset_mode(t(), atom()) :: t()
  def reset_mode(emulator, mode) do
    case mode do
      :show_cursor ->
        %{emulator | cursor: %{emulator.cursor | visible: false}}

      :insert_mode ->
        %{emulator | state: :normal}

      :irm ->
        %{emulator | state: :normal}

      _ ->
        # For other modes, just return the emulator unchanged
        emulator
    end
  end

  @doc """
  Sets the character set for the emulator.
  """
  @spec set_charset(t(), atom()) :: {:ok, t()} | {:error, atom(), t()}
  def set_charset(emulator, _charset) do
    # For now, just return success
    # This is a placeholder implementation
    {:ok, emulator}
  end

  @doc """
  Updates the active buffer in the emulator.
  """
  @spec update_active_buffer(t(), map()) :: t()
  def update_active_buffer(emulator, new_buffer) do
    case emulator.active_buffer_type do
      :main ->
        %{emulator | main_screen_buffer: new_buffer}

      :alternate ->
        %{emulator | alternate_screen_buffer: new_buffer}

      _ ->
        %{emulator | main_screen_buffer: new_buffer}
    end
  end

  @doc """
  Moves the cursor to the specified position.
  """
  @spec move_cursor(t(), integer(), integer()) :: t()
  def move_cursor(emulator, row, col) do
    row = clamp_to_bounds(row, emulator.height)
    col = clamp_to_bounds(col, emulator.width)

    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_to, col, row, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor up by the specified number of lines.
  """
  @spec move_cursor_up(t(), integer(), integer(), integer()) :: t()
  def move_cursor_up(emulator, lines, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_up, lines, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor down by the specified number of lines.
  """
  @spec move_cursor_down(t(), integer(), integer(), integer()) :: t()
  def move_cursor_down(emulator, lines, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_down, lines, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor right by the specified number of columns.
  """
  @spec move_cursor_right(t(), integer(), integer(), integer()) :: t()
  def move_cursor_right(emulator, cols, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_right, cols, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor left by the specified number of columns.
  """
  @spec move_cursor_left(t(), integer(), integer(), integer()) :: t()
  def move_cursor_left(emulator, cols, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_left, cols, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor to the start of the current line.
  """
  @spec move_cursor_to_line_start(t()) :: t()
  def move_cursor_to_line_start(emulator) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        :move_to_line_start
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor to the specified column.
  """
  @spec move_cursor_to_column(t(), integer(), integer(), integer()) :: t()
  def move_cursor_to_column(emulator, column, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_to_column, column, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  @doc """
  Moves the cursor to the specified position.
  """
  @spec move_cursor_to(t(), {integer(), integer()}, integer(), integer()) :: t()
  def move_cursor_to(emulator, {row, col}, _width, _height) do
    moved_cursor =
      call_cursor_operation(
        emulator.cursor,
        {:move_to, col, row, emulator.width, emulator.height}
      )

    %{emulator | cursor: moved_cursor}
  end

  # Private helper functions

  defp needs_scroll?(emulator) do
    emulator.cursor.position |> elem(1) >= emulator.height
  end

  defp perform_scroll(emulator) do
    # Implementation
    emulator
  end

  defp default_opts(opts) do
    %{
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      scrollback_limit: Keyword.get(opts, :scrollback_limit, @default_scrollback),
      memory_limit: Keyword.get(opts, :memory_limit, 100_000),
      max_command_history: Keyword.get(opts, :max_command_history, 100),
      plugin_manager: Keyword.get(opts, :plugin_manager),
      session_id: Keyword.get(opts, :session_id, UUID.uuid4()),
      client_options: Keyword.get(opts, :client_options, %{}),
      state: Keyword.get(opts, :state, :normal),
      window_manager: Keyword.get(opts, :window_manager)
    }
  end

  defp initialize_emulator(active_buffer, scrollback_buffer, opts) do
    defaults = default_opts(opts)

    %__MODULE__{
      active_buffer: active_buffer,
      active_buffer_type: :main,
      scrollback_buffer: scrollback_buffer,
      cursor_manager: Keyword.get(opts, :cursor_manager),
      mode_manager: Keyword.get(opts, :mode_manager),
      command_history: [],
      current_command_buffer: "",
      style: %{},
      color_palette: %{},
      tab_stops: [],
      cursor: Raxol.Terminal.Cursor.Manager.new(),
      cursor_style: :block,
      saved_cursor: nil,
      charset_state: %{
        g0: :us_ascii,
        g1: :us_ascii,
        g2: :us_ascii,
        g3: :us_ascii,
        gl: :g0,
        gr: :g1,
        single_shift: nil
      },
      width: defaults.width,
      height: defaults.height,
      main_screen_buffer: active_buffer,
      alternate_screen_buffer: ScreenBuffer.new(defaults.width, defaults.height),
      scrollback_limit: defaults.scrollback_limit,
      memory_limit: defaults.memory_limit,
      max_command_history: defaults.max_command_history,
      plugin_manager: defaults.plugin_manager,
      session_id: defaults.session_id,
      client_options: defaults.client_options,
      state: defaults.state,
      window_manager: defaults.window_manager,
      command: nil,
      config: nil,
      buffer: nil,
      event: Raxol.Terminal.Event.Handler.new(),
      output_buffer: "",
      parser_state: %{state: :ground}
    }
  end
end
