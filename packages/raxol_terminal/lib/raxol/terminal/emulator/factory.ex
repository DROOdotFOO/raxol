defmodule Raxol.Terminal.Emulator.Factory do
  @moduledoc """
  Emulator construction helpers: creates full (GenServer) and basic (struct-only) emulators.
  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.ScreenBufferAdapter, as: ScreenBuffer

  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  @doc """
  Creates a full-featured emulator with GenServer processes.
  Falls back to basic emulator on failure.
  """
  def create_full(width, height, opts) do
    Raxol.Terminal.Emulator.Coordinator.new(width, height, opts)
  rescue
    error ->
      Log.warning("Failed to create full emulator with GenServers: #{inspect(error)}")

      create_basic(width, height, opts)
  end

  @doc """
  Creates a basic emulator without GenServer processes (optimized for performance).
  """
  def create_basic(width, height, opts) do
    enable_history = Keyword.get(opts, :enable_history, true)
    alternate_buffer = Keyword.get(opts, :alternate_buffer, true)
    scrollback_limit = Keyword.get(opts, :scrollback_limit, @default_scrollback)

    main_buffer = ScreenBuffer.new(width, height)
    mode_manager = Raxol.Terminal.ModeManager.new()

    cursor = %CursorManager{
      row: 0,
      col: 0,
      position: {0, 0},
      visible: true,
      blinking: true,
      style: :block,
      bottom_margin: height - 1
    }

    alternate_screen_buffer =
      if alternate_buffer, do: ScreenBuffer.new(width, height), else: nil

    command_history = if enable_history, do: [], else: nil
    current_command_buffer = if enable_history, do: "", else: nil

    history_buffer =
      if enable_history, do: Raxol.Terminal.HistoryBuffer.new(), else: nil

    %Raxol.Terminal.Emulator{
      state: %{modes: %{}, attributes: %{}, state_stack: []},
      event: nil,
      buffer: nil,
      config: nil,
      command: nil,
      cursor: cursor,
      window_manager: nil,
      width: width,
      height: height,
      main_screen_buffer: main_buffer,
      alternate_screen_buffer: alternate_screen_buffer,
      active_buffer: main_buffer,
      active_buffer_type: :main,
      mode_manager: mode_manager,
      style: Raxol.Terminal.ANSI.TextFormatting.new(),
      session_id: Keyword.get(opts, :session_id, ""),
      client_options: Keyword.get(opts, :client_options, %{}),
      parser_state: %Raxol.Terminal.Parser.ParserState{state: :ground},
      charset_state: %{
        g0: :us_ascii,
        g1: :us_ascii,
        g2: :us_ascii,
        g3: :us_ascii,
        gl: :g0,
        gr: :g0,
        active: :g0,
        single_shift: nil
      },
      window_state: %{
        iconified: false,
        maximized: false,
        position: {0, 0},
        size: {width, height},
        size_pixels: {width * 8, height * 16},
        stacking_order: :normal,
        previous_size: {width, height},
        saved_size: {width, height},
        icon_name: ""
      },
      state_stack: [],
      command_history: command_history,
      max_command_history: if(enable_history, do: 100, else: 0),
      history_buffer: history_buffer,
      scrollback_buffer: [],
      scrollback_limit: scrollback_limit,
      output_buffer: "",
      current_command_buffer: current_command_buffer,
      bracketed_paste_active: false,
      bracketed_paste_buffer: "",
      scroll_region: nil,
      memory_limit: 10_000_000,
      tab_stops: [],
      color_palette: %{},
      cursor_blink_rate: 500,
      device_status_reported: false,
      cursor_position_reported: false,
      last_col_exceeded: false,
      plugin_manager: Keyword.get(opts, :plugin_manager)
    }
  end
end
