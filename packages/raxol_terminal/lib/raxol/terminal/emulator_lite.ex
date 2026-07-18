defmodule Raxol.Terminal.EmulatorLite do
  @moduledoc """
  Lightweight terminal emulator for performance-critical paths.

  This is a pure struct-based emulator without GenServer processes,
  designed for fast parsing and simple terminal operations.

  For full-featured terminal emulation with state management and
  concurrent operations, use Raxol.Terminal.Emulator.
  """

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cursor
  alias Raxol.Terminal.ModeManager
  alias Raxol.Terminal.ScreenBuffer

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  defstruct [
    # Core state
    :width,
    :height,
    :cursor,
    :main_screen_buffer,
    :alternate_screen_buffer,
    :active_buffer_type,

    # Parser state
    :parser_state,
    :charset_state,

    # Style and formatting
    :style,
    :saved_style,

    # Cursor state
    :saved_cursor,
    :cursor_style,
    :last_col_exceeded,

    # Scrolling
    :scroll_region,
    :scrollback_buffer,
    :scrollback_limit,

    # Mode management
    :mode_manager,
    :mode_state,

    # Command history (optional, can be nil for performance)
    :command_history,
    :current_command_buffer,
    :max_command_history,

    # Window state
    :window_title,
    :window_state,

    # Output buffer
    :output_buffer,

    # Session info
    :session_id,
    :client_options
  ]

  @type t :: %__MODULE__{
          width: non_neg_integer(),
          height: non_neg_integer(),
          cursor: Cursor.t(),
          main_screen_buffer: ScreenBuffer.t(),
          alternate_screen_buffer: ScreenBuffer.t() | nil,
          active_buffer_type: :main | :alternate,
          parser_state: any(),
          charset_state: map(),
          style: TextFormatting.t(),
          saved_style: TextFormatting.t() | nil,
          saved_cursor: Cursor.t() | nil,
          cursor_style: atom(),
          last_col_exceeded: boolean(),
          scroll_region: {non_neg_integer(), non_neg_integer()} | nil,
          scrollback_buffer: list(),
          scrollback_limit: non_neg_integer(),
          mode_manager: ModeManager.t(),
          mode_state: map(),
          command_history: list() | nil,
          current_command_buffer: String.t() | nil,
          max_command_history: non_neg_integer(),
          window_title: String.t() | nil,
          window_state: map(),
          output_buffer: String.t(),
          session_id: String.t() | nil,
          client_options: map()
        }

  @doc """
  Creates a new lightweight emulator with minimal overhead.

  Options:
    - :enable_history - Enable command history tracking (default: false)
    - :scrollback_limit - Number of scrollback lines (default: 1000)
    - :alternate_buffer - Create alternate screen buffer (default: false)
  """
  def new(width \\ @default_width, height \\ @default_height, opts \\ []) do
    enable_history = Keyword.get(opts, :enable_history, false)
    scrollback_limit = Keyword.get(opts, :scrollback_limit, @default_scrollback)
    create_alternate = Keyword.get(opts, :alternate_buffer, false)

    cursor = %Cursor{
      position: {0, 0},
      shape: :block,
      visible: true
    }

    %__MODULE__{
      width: width,
      height: height,
      cursor: cursor,
      main_screen_buffer: ScreenBuffer.new(width, height),
      alternate_screen_buffer:
        case create_alternate do
          true -> ScreenBuffer.new(width, height)
          false -> nil
        end,
      active_buffer_type: :main,
      parser_state: nil,
      charset_state: default_charset_state(),
      style: TextFormatting.new(),
      saved_style: nil,
      saved_cursor: nil,
      cursor_style: :block,
      last_col_exceeded: false,
      scroll_region: nil,
      scrollback_buffer: [],
      scrollback_limit: scrollback_limit,
      mode_manager: %ModeManager{},
      mode_state: %{},
      command_history:
        case enable_history do
          true -> []
          false -> nil
        end,
      current_command_buffer:
        case enable_history do
          true -> ""
          false -> nil
        end,
      max_command_history: 100,
      window_title: nil,
      window_state: default_window_state(width, height),
      output_buffer: "",
      session_id: Keyword.get(opts, :session_id),
      client_options: Keyword.get(opts, :client_options, %{})
    }
  end

  @doc """
  Creates a minimal emulator for fastest possible parsing.
  No history, no alternate buffer, minimal features.
  """
  def new_minimal(width \\ @default_width, height \\ @default_height) do
    new(width, height,
      enable_history: false,
      alternate_buffer: false,
      scrollback_limit: 0
    )
  end

  @doc """
  Gets the active screen buffer.
  """
  def get_active_buffer(%__MODULE__{
        active_buffer_type: :alternate,
        alternate_screen_buffer: buffer
      })
      when not is_nil(buffer),
      do: buffer

  def get_active_buffer(%__MODULE__{main_screen_buffer: buffer}), do: buffer

  @doc """
  Updates the active screen buffer.
  """
  def update_active_buffer(
        %__MODULE__{active_buffer_type: :alternate} = emulator,
        fun
      )
      when not is_nil(emulator.alternate_screen_buffer) do
    %{
      emulator
      | alternate_screen_buffer: fun.(emulator.alternate_screen_buffer)
    }
  end

  def update_active_buffer(%__MODULE__{} = emulator, fun) do
    %{emulator | main_screen_buffer: fun.(emulator.main_screen_buffer)}
  end

  @doc """
  Switches between main and alternate screen buffers.
  """
  def switch_buffer(%__MODULE__{} = emulator, :alternate) do
    # Create alternate buffer if it doesn't exist
    alternate =
      emulator.alternate_screen_buffer ||
        ScreenBuffer.new(emulator.width, emulator.height)

    %{
      emulator
      | active_buffer_type: :alternate,
        alternate_screen_buffer: alternate
    }
  end

  def switch_buffer(%__MODULE__{} = emulator, :main) do
    %{emulator | active_buffer_type: :main}
  end

  @doc """
  Resets the emulator to initial state.
  """
  def reset(%__MODULE__{width: width, height: height} = emulator) do
    %{
      emulator
      | cursor: %Cursor{position: {0, 0}, shape: :block, visible: true},
        main_screen_buffer: ScreenBuffer.new(width, height),
        alternate_screen_buffer:
          case emulator.alternate_screen_buffer do
            nil -> nil
            _ -> ScreenBuffer.new(width, height)
          end,
        active_buffer_type: :main,
        style: TextFormatting.new(),
        saved_style: nil,
        saved_cursor: nil,
        last_col_exceeded: false,
        scroll_region: nil,
        scrollback_buffer: [],
        command_history:
          case emulator.command_history do
            nil -> nil
            _ -> []
          end,
        current_command_buffer:
          case emulator.current_command_buffer do
            nil -> nil
            _ -> ""
          end,
        output_buffer: ""
    }
  end

  @doc """
  Resizes the emulator to new dimensions.
  """
  def resize(%__MODULE__{} = emulator, new_width, new_height) do
    %{
      emulator
      | width: new_width,
        height: new_height,
        main_screen_buffer:
          ScreenBuffer.resize(
            emulator.main_screen_buffer,
            new_width,
            new_height
          ),
        alternate_screen_buffer:
          case emulator.alternate_screen_buffer do
            nil ->
              nil

            buffer ->
              ScreenBuffer.resize(
                buffer,
                new_width,
                new_height
              )
          end,
        cursor: constrain_cursor(emulator.cursor, new_width, new_height)
    }
  end

  @doc """
  Moves the cursor to a specific position.
  """
  def move_cursor(%__MODULE__{} = emulator, x, y) do
    new_x = clamp_to_bounds(x, emulator.width)
    new_y = clamp_to_bounds(y, emulator.height)
    new_cursor = %{emulator.cursor | position: {new_x, new_y}}
    %{emulator | cursor: new_cursor}
  end

  @doc """
  Updates the cursor position relatively.
  """
  def move_cursor_relative(%__MODULE__{cursor: cursor} = emulator, dx, dy) do
    {x, y} = cursor.position
    move_cursor(emulator, x + dx, y + dy)
  end

  # Private functions

  defp default_charset_state do
    %{
      g0: :us_ascii,
      g1: :us_ascii,
      g2: :us_ascii,
      g3: :us_ascii,
      gl: :g0,
      gr: :g0,
      single_shift: nil
    }
  end

  defp default_window_state(width, height) do
    %{
      iconified: false,
      maximized: false,
      position: {0, 0},
      size: {width, height},
      size_pixels: {width * 8, height * 16},
      stacking_order: :normal,
      previous_size: {width, height},
      saved_size: {width, height},
      icon_name: ""
    }
  end

  defp constrain_cursor(cursor, width, height) do
    {x, y} = cursor.position
    new_x = clamp_to_bounds(x, width)
    new_y = clamp_to_bounds(y, height)
    %{cursor | position: {new_x, new_y}}
  end
end
