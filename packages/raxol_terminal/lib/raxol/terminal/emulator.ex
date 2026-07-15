defmodule Raxol.Terminal.Emulator do
  @moduledoc """
  Enterprise-grade terminal emulator with VT100/ANSI support and high-performance parsing.

  Provides full terminal emulation with true color, mouse tracking, alternate screen,
  and modern features. Uses modular architecture with separate coordinators for
  buffer, mode, input, and output operations.

  ## Usage

      # Create standard emulator
      emulator = Raxol.Terminal.Emulator.new(80, 24)

      # Process input with colors
      {emulator, output} = Raxol.Terminal.Emulator.process_input(
        emulator,
        "\\e[1;31mRed Bold\\e[0m Normal text"
      )

  ## Performance Modes

  * `new/2` - Full features (2.8MB, ~95ms startup)
  * `new_lite/3` - Most features (1.2MB, ~30ms startup)
  * `new_minimal/2` - Basic only (8.8KB, <10ms startup)
  """

  alias Raxol.Terminal.Emulator.BufferOperations
  alias Raxol.Terminal.Emulator.Coordinator
  alias Raxol.Terminal.Emulator.CursorOps
  alias Raxol.Terminal.Emulator.Factory
  alias Raxol.Terminal.Emulator.InputProcessing
  alias Raxol.Terminal.Emulator.ModeOperations

  @compile {:no_warn_undefined,
            [
              Raxol.Terminal.Emulator.BufferOperations,
              Raxol.Terminal.Emulator.CursorOps,
              Raxol.Terminal.Emulator.Factory,
              Raxol.Terminal.Emulator.InputProcessing
            ]}

  @behaviour Raxol.Terminal.EmulatorBehaviour

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  # Terminal emulator state requires many fields (modes, buffers, managers, cursor, etc.)
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct state: nil,
            event: nil,
            buffer: nil,
            config: nil,
            command: nil,
            cursor: nil,
            window_manager: nil,
            mode_manager: nil,
            active_buffer_type: :main,
            cursor_handled_by_autowrap: false,
            main_screen_buffer: nil,
            active: nil,
            alternate: nil,
            charset_state: %{
              g0: :us_ascii,
              g1: :us_ascii,
              g2: :us_ascii,
              g3: :us_ascii,
              gl: :g0,
              gr: :g0,
              single_shift: nil,
              active: :us_ascii
            },
            width: @default_width,
            height: @default_height,
            window_state: %{
              iconified: false,
              maximized: false,
              position: {0, 0},
              size: {@default_width, @default_height},
              size_pixels: {@default_width * 8, @default_height * 16},
              stacking_order: :normal,
              previous_size: {@default_width, @default_height},
              saved_size: {@default_width, @default_height},
              icon_name: ""
            },
            state_stack: [],
            parser_state: %Raxol.Terminal.Parser.ParserState{state: :ground},
            command_history: [],
            max_command_history: 100,
            history_buffer: nil,
            scrollback_buffer: [],
            output_buffer: [],
            current_command_buffer: "",
            screen_buffer_manager: nil,
            output_manager: nil,
            cursor_manager: nil,
            scrollback_manager: nil,
            selection_manager: nil,
            mode_manager_pid: nil,
            style_manager: nil,
            damage_tracker: nil,
            mode_state: %{},
            style: nil,
            cursor_style: :block,
            bracketed_paste_active: false,
            bracketed_paste_buffer: "",
            saved_cursor: nil,
            scroll_region: {0, @default_height - 1},
            scrollback_limit: @default_scrollback,
            memory_limit: 10_000_000,
            session_id: "",
            client_options: %{},
            window_title: nil,
            last_col_exceeded: false,
            icon_name: nil,
            tab_stops: [],
            color_palette: %{},
            last_key_event: nil,
            current_hyperlink: nil,
            notification: nil,
            progress: nil,
            pointer_shape: nil,
            active_buffer: nil,
            alternate_screen_buffer: nil,
            sixel_state: nil,
            cursor_blink_rate: 500,
            device_status_reported: false,
            cursor_position_reported: false,
            notification_manager: nil,
            clipboard_manager: nil,
            hyperlink_manager: nil,
            font_manager: nil,
            color_manager: nil,
            capabilities_manager: nil,
            device_status_manager: nil,
            graphics_manager: nil,
            input_manager: nil,
            metrics_manager: nil,
            mouse_manager: nil,
            plugin_manager: nil,
            registry: nil,
            renderer: nil,
            scroll_manager: nil,
            session_manager: nil,
            state_manager: nil,
            supervisor: nil,
            sync_manager: nil,
            tab_manager: nil,
            terminal_state_manager: nil,
            theme_manager: nil,
            validation_service: nil,
            window_registry: nil

  @type t :: %__MODULE__{
          state: any(),
          event: any(),
          buffer: any(),
          config: any(),
          command: any(),
          cursor: any(),
          window_manager: any(),
          mode_manager: any(),
          active_buffer_type: atom(),
          main_screen_buffer: any(),
          active: any(),
          alternate: any(),
          charset_state: map(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          window_state: map(),
          state_stack: list(),
          parser_state: any(),
          command_history: list(),
          max_command_history: non_neg_integer(),
          scrollback_buffer: list(),
          output_buffer: list(),
          current_command_buffer: String.t(),
          screen_buffer_manager: any(),
          output_manager: any(),
          cursor_manager: any(),
          scrollback_manager: any(),
          selection_manager: any(),
          mode_manager_pid: any(),
          style_manager: any(),
          damage_tracker: any(),
          mode_state: map(),
          style: any(),
          cursor_style: atom(),
          bracketed_paste_active: boolean(),
          bracketed_paste_buffer: String.t(),
          saved_cursor: any(),
          scroll_region: tuple(),
          scrollback_limit: non_neg_integer(),
          memory_limit: non_neg_integer(),
          session_id: String.t(),
          client_options: map(),
          window_title: String.t() | nil,
          last_col_exceeded: boolean(),
          icon_name: String.t() | nil,
          tab_stops: list(),
          color_palette: map(),
          last_key_event: any(),
          current_hyperlink: any(),
          notification: String.t() | nil,
          progress:
            %{
              state: :remove | :set | :error | :indeterminate | :warning,
              value: 0..100
            }
            | nil,
          pointer_shape: String.t() | nil,
          active_buffer: any(),
          alternate_screen_buffer: any(),
          sixel_state: any(),
          cursor_blink_rate: non_neg_integer(),
          device_status_reported: boolean(),
          cursor_position_reported: boolean(),
          notification_manager: any(),
          clipboard_manager: any(),
          hyperlink_manager: any(),
          font_manager: any(),
          color_manager: any(),
          capabilities_manager: any(),
          device_status_manager: any(),
          graphics_manager: any(),
          input_manager: any(),
          metrics_manager: any(),
          mouse_manager: any(),
          plugin_manager: any(),
          registry: any(),
          renderer: any(),
          scroll_manager: any(),
          session_manager: any(),
          state_manager: any(),
          supervisor: any(),
          sync_manager: any(),
          tab_manager: any(),
          terminal_state_manager: any(),
          theme_manager: any(),
          validation_service: any(),
          window_registry: any()
        }

  # Cursor operations - delegated to CursorOps
  @doc "Gets the current cursor position as {x, y}."
  @impl Raxol.Terminal.EmulatorBehaviour
  defdelegate get_cursor_position(emulator), to: CursorOps

  @doc "Sets the cursor position to the specified coordinates."
  defdelegate set_cursor_position(emulator, x, y), to: CursorOps

  @doc "Gets the current cursor style (:block, :line, :underscore)."
  defdelegate get_cursor_style(emulator), to: CursorOps

  @doc "Sets the cursor style to :block, :line, or :underscore."
  defdelegate set_cursor_style(emulator, style), to: CursorOps

  @doc "Returns true if the cursor is visible."
  defdelegate cursor_visible?(emulator), to: CursorOps

  @doc "Gets cursor visibility state."
  @impl Raxol.Terminal.EmulatorBehaviour
  defdelegate get_cursor_visible(emulator), to: CursorOps

  @doc "Gets cursor position as a structured object."
  defdelegate get_cursor_position_struct(emulator), to: CursorOps

  @doc "Gets cursor visibility from mode manager."
  defdelegate get_mode_manager_cursor_visible(emulator), to: CursorOps

  @doc "Sets cursor visibility."
  defdelegate set_cursor_visibility(emulator, visible), to: CursorOps

  @doc "Returns true if the cursor is blinking."
  defdelegate cursor_blinking?(emulator), to: CursorOps

  @doc "Sets cursor blinking state."
  defdelegate set_cursor_blink(emulator, blinking), to: CursorOps

  @doc "Returns cursor blinking state."
  defdelegate blinking?(emulator), to: CursorOps

  @doc "Returns cursor visibility state."
  defdelegate visible?(emulator), to: CursorOps

  # Erase operations - delegated to Operations.ScreenOperations
  @doc "Clears the entire screen."
  defdelegate clear_screen(emulator),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Clears the specified line."
  defdelegate clear_line(emulator, line),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases display content based on mode (0=to end, 1=from start, 2=entire)."
  defdelegate erase_display(emulator, mode),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases content within the display."
  defdelegate erase_in_display(emulator, mode),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases line content based on mode."
  defdelegate erase_line(emulator, mode),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases content within the current line."
  defdelegate erase_in_line(emulator, mode),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases from cursor position to end of screen."
  defdelegate erase_from_cursor_to_end(emulator),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases from start of screen to cursor position."
  defdelegate erase_from_start_to_cursor(emulator),
    to: Raxol.Terminal.Operations.ScreenOperations

  @doc "Erases the specified number of characters."
  defdelegate erase_chars(emulator, count),
    to: Raxol.Terminal.Operations.ScreenOperations

  # Text operations - delegated to Operations.TextOperations
  @doc "Inserts a character at the cursor position."
  defdelegate insert_char(emulator, char),
    to: Raxol.Terminal.Operations.TextOperations

  @doc "Inserts the specified number of blank characters."
  defdelegate insert_chars(emulator, count),
    to: Raxol.Terminal.Operations.TextOperations

  @doc "Deletes the character at the cursor position."
  defdelegate delete_char(emulator),
    to: Raxol.Terminal.Operations.TextOperations

  @doc "Deletes the specified number of characters."
  defdelegate delete_chars(emulator, count),
    to: Raxol.Terminal.Operations.TextOperations

  @doc "Writes text to the terminal at the cursor position."
  defdelegate write_text(emulator, text),
    to: Raxol.Terminal.Operations.TextOperations

  # Selection operations
  @doc "Starts text selection at the specified coordinates."
  defdelegate start_selection(emulator, x, y),
    to: Raxol.Terminal.Operations.SelectionOperations

  @doc "Updates the selection endpoint to the specified coordinates."
  defdelegate update_selection(emulator, x, y),
    to: Raxol.Terminal.Operations.SelectionOperations

  @doc "Ends the current text selection."
  defdelegate end_selection(emulator),
    to: Raxol.Terminal.Operations.SelectionOperations

  @doc "Clears the current text selection."
  defdelegate clear_selection(emulator),
    to: Raxol.Terminal.Operations.SelectionOperations

  @doc "Gets the currently selected text."
  defdelegate get_selection(emulator),
    to: Raxol.Terminal.Operations.SelectionOperations

  @doc "Returns true if text is currently selected."
  defdelegate has_selection?(emulator),
    to: Raxol.Terminal.Operations.SelectionOperations

  # Scroll operations
  @doc "Scrolls the display up by the specified number of lines."
  defdelegate scroll_up(emulator, lines),
    to: Raxol.Terminal.Operations.ScrollOperations

  @doc "Scrolls the display down by the specified number of lines."
  defdelegate scroll_down(emulator, lines),
    to: Raxol.Terminal.Operations.ScrollOperations

  # State operations
  @doc "Saves the current terminal state."
  defdelegate save_state(emulator),
    to: Raxol.Terminal.Operations.StateOperations

  @doc "Restores the previously saved terminal state."
  defdelegate restore_state(emulator),
    to: Raxol.Terminal.Operations.StateOperations

  # Buffer operations - delegated to BufferOperations
  @doc "Switches to the alternate screen buffer."
  defdelegate switch_to_alternate_screen(emulator), to: BufferOperations

  @doc "Switches to the normal screen buffer."
  defdelegate switch_to_normal_screen(emulator), to: BufferOperations

  @doc "Clears the scrollback buffer."
  defdelegate clear_scrollback(emulator), to: BufferOperations

  @doc "Updates the active buffer with new content."
  @impl Raxol.Terminal.EmulatorBehaviour
  defdelegate update_active_buffer(emulator, buffer), to: BufferOperations

  @doc "Writes data to the output buffer."
  defdelegate write_to_output(emulator, data), to: BufferOperations

  # Dimension operations
  @doc "Gets the terminal width in columns."
  defdelegate get_width(emulator),
    to: Raxol.Terminal.Emulator.Dimensions

  @doc "Gets the terminal height in rows."
  defdelegate get_height(emulator),
    to: Raxol.Terminal.Emulator.Dimensions

  @doc "Gets the current scroll region as {top, bottom}."
  defdelegate get_scroll_region(emulator),
    to: Raxol.Terminal.Emulator.Dimensions

  # Process management
  @doc """
  Starts a linked terminal emulator process.
  """
  def start_link(opts \\ []) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    name = Keyword.get(opts, :name)
    initial_state = new(width, height, opts)

    if Code.ensure_loaded?(__MODULE__.Server) do
      GenServer.start_link(
        __MODULE__.Server,
        {initial_state, opts},
        if(name, do: [name: name], else: [])
      )
    else
      {:ok, spawn(fn -> :ok end)}
    end
  end

  # Constructor functions
  @impl Raxol.Terminal.EmulatorBehaviour
  def new do
    new(@default_width, @default_height, [])
  end

  @impl Raxol.Terminal.EmulatorBehaviour
  def new(width, height) do
    new(width, height, [])
  end

  @impl Raxol.Terminal.EmulatorBehaviour
  def new(width, height, opts) do
    if Keyword.get(opts, :use_genservers, false) do
      Factory.create_full(width, height, opts)
    else
      Factory.create_basic(width, height, opts)
    end
  end

  @impl Raxol.Terminal.EmulatorBehaviour
  def new(width, height, session_id, client_options) do
    opts = [session_id: session_id, client_options: client_options]
    {:ok, new(width, height, opts)}
  end

  @deprecated "Use new/3 with use_genservers: false option instead"
  def new_lite(width \\ @default_width, height \\ @default_height, opts \\ []) do
    new(width, height, Keyword.put(opts, :use_genservers, false))
  end

  @deprecated "Use new/3 with enable_history: false, alternate_buffer: false options instead"
  def new_minimal(width \\ @default_width, height \\ @default_height) do
    new(width, height,
      enable_history: false,
      alternate_buffer: false,
      use_genservers: false
    )
  end

  # Reset and resize
  @doc "Resets the terminal emulator to its initial state."
  def reset(emulator), do: Coordinator.reset(emulator)

  @doc "Resizes the terminal to the specified dimensions."
  @impl Raxol.Terminal.EmulatorBehaviour
  def resize(emulator, new_width, new_height) do
    Coordinator.resize(emulator, new_width, new_height)
  end

  # Complex coordination operations
  @doc "Moves the cursor to the specified position."
  def move_cursor(emulator, x, y), do: Coordinator.move_cursor(emulator, x, y)

  @doc "Clears the screen and moves cursor to home position."
  def clear_screen_and_home(emulator),
    do: Coordinator.clear_screen_and_home(emulator)

  @doc "Validates terminal dimensions."
  def validate_dimensions(width, height),
    do: Coordinator.validate_dimensions(width, height)

  # Mode update functions
  @doc "Updates insert mode state."
  def update_insert_mode(emulator, enabled) do
    mode_state = Map.put(emulator.mode_state, :insert_mode, enabled)
    {:ok, %{emulator | mode_state: mode_state}}
  end

  @doc "Updates auto wrap mode state."
  def update_auto_wrap_mode(emulator, enabled) do
    mode_state = Map.put(emulator.mode_state, :auto_wrap, enabled)
    {:ok, %{emulator | mode_state: mode_state}}
  end

  # Screen buffer accessor
  @doc "Gets the active screen buffer."
  @impl Raxol.Terminal.EmulatorBehaviour
  def get_screen_buffer(emulator),
    do: BufferOperations.get_screen_buffer(emulator)

  @doc "Sets terminal dimensions after validation."
  def set_dimensions(emulator, width, height) do
    case Coordinator.validate_dimensions(width, height) do
      {:ok, _} -> {:ok, %{emulator | width: width, height: height}}
      error -> error
    end
  end

  # Legacy compatibility functions
  @doc "Gets output buffer (legacy compatibility)."
  def get_output_buffer(_emulator), do: {:ok, []}

  @doc "Applies color changes (legacy compatibility)."
  def apply_color_changes(emulator), do: {:ok, emulator}

  @doc "Updates blink state (legacy compatibility)."
  def update_blink_state(emulator), do: {:ok, emulator}

  @doc "Processes input and returns updated emulator with output."
  @impl Raxol.Terminal.EmulatorBehaviour
  defdelegate process_input(emulator, input), to: InputProcessing

  # Additional functions needed by various modules
  @doc "Gets the scrollback buffer contents."
  def get_scrollback(emulator), do: emulator.scrollback_buffer || []

  @doc """
  Performs automatic scrolling if needed.

  Fires when the cursor row has moved past the bottom of the screen (the
  deferred-autowrap and pending-wrap paths move the cursor unclamped);
  scrolls the effective scroll region by the overflow amount via
  `Raxol.Terminal.Commands.Screen.scroll_up/2` -- which feeds evicted rows
  into `emulator.scrollback_buffer` per the TE eviction rules -- and clamps
  the cursor back onto the last row. The in-bounds LF-at-bottom-margin
  scroll is handled by `Raxol.Terminal.ControlCodes.handle_lf/1` directly
  and never reaches here (a clamped cursor is indistinguishable from one
  legitimately sitting on the last row).
  """
  def maybe_scroll(emulator) do
    height =
      case get_screen_buffer(emulator) do
        %{height: h} -> h
        _ -> nil
      end

    {row, col} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    case is_integer(row) and is_integer(height) and row >= height do
      true ->
        scrolled =
          Raxol.Terminal.Commands.Screen.scroll_up(emulator, row - height + 1)

        clamped_cursor =
          Raxol.Terminal.Cursor.Manager.move_to(
            scrolled.cursor,
            height - 1,
            col
          )

        %{scrolled | cursor: clamped_cursor}

      false ->
        emulator
    end
  end

  @doc "Sets a terminal mode."
  def set_mode(emulator, mode), do: ModeOperations.set_mode(emulator, mode)

  @doc "Resets a terminal mode."
  def reset_mode(emulator, mode), do: ModeOperations.reset_mode(emulator, mode)

  @doc "Sets a terminal attribute."
  def set_attribute(emulator, _attr, _value), do: emulator

  @doc "Gets the mode manager."
  def get_mode_manager(emulator), do: emulator.mode_manager

  @doc "Gets the configuration structure."
  def get_config_struct(emulator),
    do: Raxol.Terminal.Emulator.Helpers.get_config_struct(emulator)

  @doc "Moves cursor to specified position."
  def move_cursor_to(emulator, x, y), do: move_cursor(emulator, x, y)

  @doc "Moves cursor to specified position with options."
  def move_cursor_to(emulator, x, y, _opts), do: move_cursor(emulator, x, y)

  @doc "Moves cursor up (stub implementation)."
  def move_cursor_up(emulator, _count), do: emulator

  @doc "Moves cursor down (stub implementation)."
  def move_cursor_down(emulator, _count), do: emulator

  @doc "Moves cursor forward (stub implementation)."
  def move_cursor_forward(emulator, _count), do: emulator

  @doc "Moves cursor back (stub implementation)."
  def move_cursor_back(emulator, _count), do: emulator

  @doc "Handles ESC = sequence (DECKPAM - Enable application keypad mode)."
  defdelegate handle_esc_equals(emulator), to: InputProcessing

  @doc "Handles ESC > sequence (DECKPNM - Disable application keypad mode)."
  defdelegate handle_esc_greater(emulator), to: InputProcessing

  @doc "Gets output from the emulator."
  @spec get_output(t()) :: String.t()
  def get_output(_emulator), do: ""

  @doc "Renders the emulator screen."
  @spec render_screen(t()) :: String.t()
  def render_screen(emulator), do: get_output(emulator)

  @doc "Cleans up emulator resources."
  @spec cleanup(t()) :: :ok
  def cleanup(_emulator), do: :ok
end
