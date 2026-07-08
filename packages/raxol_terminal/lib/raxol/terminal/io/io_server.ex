defmodule Raxol.Terminal.IO.IOServer do
  @moduledoc """
  Unified input/output system for the terminal emulator.

  This module provides a consolidated interface for handling all terminal I/O operations,
  including:
  - Input event processing (keyboard, mouse, special keys)
  - Output buffering and processing
  - Command history management
  - Input mode management
  - Event propagation control
  - Performance optimizations
  """

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Terminal.{
    Commands.History,
    Rendering.RenderServer,
    ScreenBuffer.Manager
  }

  # Types
  @type mouse_button :: 0 | 1 | 2 | 3 | 4
  @type mouse_event_type :: :press | :release | :move | :scroll
  @type mouse_event ::
          {mouse_event_type(), mouse_button(), non_neg_integer(), non_neg_integer()}
  @type special_key ::
          :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :page_up
          | :page_down
          | :insert
          | :delete
          | :escape
          | :tab
          | :enter
          | :backspace
          | :f1
          | :f2
          | :f3
          | :f4
          | :f5
          | :f6
          | :f7
          | :f8
          | :f9
          | :f10
          | :f11
          | :f12
  @type input_mode :: :normal | :insert | :replace | :command
  @type completion_callback :: (String.t() -> list(String.t()))

  @type t :: %__MODULE__{
          # Input state
          mode: input_mode(),
          history_index: integer() | nil,
          input_history: [String.t()],
          buffer: String.t(),
          prompt: String.t() | nil,
          completion_context: map() | nil,
          last_event_time: integer() | nil,
          last_input: String.t() | nil,
          clipboard_content: String.t() | nil,
          clipboard_history: [String.t()],
          mouse_enabled: boolean(),
          mouse_buttons: MapSet.t(mouse_button()),
          mouse_position: {non_neg_integer(), non_neg_integer()},
          modifier_state: map(),
          input_queue: list(String.t()),
          processing_escape: boolean(),
          completion_callback: completion_callback() | nil,
          completion_options: list(String.t()),
          completion_index: non_neg_integer(),

          # Output state
          output_buffer: String.t(),
          output_queue: list(String.t()),
          output_processing: boolean(),

          # Component references
          buffer_manager: pid() | nil,
          scroll_buffer: Raxol.Terminal.Buffer.Scroll.t(),
          renderer: pid() | nil,
          command_history: term(),

          # Configuration
          config: map()
        }

  defstruct [
    # Input state
    :mode,
    :history_index,
    :input_history,
    :buffer,
    :prompt,
    :completion_context,
    :last_event_time,
    :last_input,
    :clipboard_content,
    :clipboard_history,
    :mouse_enabled,
    :mouse_buttons,
    :mouse_position,
    :modifier_state,
    :input_queue,
    :processing_escape,
    :completion_callback,
    :completion_options,
    :completion_index,

    # Output state
    :output_buffer,
    :output_queue,
    :output_processing,

    # Component references
    :buffer_manager,
    :scroll_buffer,
    :renderer,
    :command_history,

    # Configuration
    :config
  ]

  # Client API

  # Helper function to get the process name
  defp process_name(pid) when is_pid(pid), do: pid
  defp process_name(name) when is_atom(name), do: name
  defp process_name(_), do: __MODULE__

  @doc """
  Initializes the terminal IO system.
  """
  def init_terminal(width, height, config, process \\ __MODULE__) do
    GenServer.call(
      process_name(process),
      {:init_terminal, width, height, config}
    )
  end

  @doc """
  Processes an input event.
  """
  def process_input(event, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:process_input, event})
  end

  @doc """
  Processes output data.
  """
  def process_output(data, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:process_output, data})
  end

  @doc """
  Updates the IO configuration.
  """
  def update_config(config, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:update_config, config})
  end

  @doc """
  Sets a specific configuration value.
  """
  def set_config_value(path, value, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:set_config_value, path, value})
  end

  @doc """
  Resets the configuration to defaults.
  """
  def reset_config(process \\ __MODULE__) do
    GenServer.call(process_name(process), :reset_config)
  end

  @doc """
  Resizes the terminal.
  """
  def resize(width, height, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:resize, width, height})
  end

  @doc """
  Sets cursor visibility.
  """
  def set_cursor_visibility(visible, process \\ __MODULE__) do
    GenServer.call(process_name(process), {:set_cursor_visibility, visible})
  end

  @doc """
  Cleans up the I/O manager.
  """
  def cleanup(_io, process \\ __MODULE__) do
    # Stop the renderer
    RenderServer.shutdown_terminal()

    # Reset the state
    GenServer.call(process_name(process), :cleanup)
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    # Convert keyword list to map for config
    config = convert_keyword_to_map(opts)

    state = %__MODULE__{
      # Input state
      mode: :normal,
      history_index: nil,
      input_history: [],
      buffer: "",
      prompt: nil,
      completion_context: nil,
      last_event_time: nil,
      last_input: nil,
      clipboard_content: nil,
      clipboard_history: [],
      mouse_enabled: false,
      mouse_buttons: MapSet.new(),
      mouse_position: {0, 0},
      modifier_state: %{},
      input_queue: [],
      processing_escape: false,
      completion_callback: nil,
      completion_options: [],
      completion_index: 0,

      # Output state
      output_buffer: "",
      output_queue: [],
      output_processing: false,

      # Configuration
      config: config
    }

    {:ok, state}
  end

  defp convert_keyword_to_map(opts) when is_list(opts) do
    case Keyword.keyword?(opts) do
      true -> Map.new(opts)
      false -> opts
    end
  end

  defp convert_keyword_to_map(opts), do: opts

  @impl true
  def handle_manager_call({:init_terminal, width, height, config}, _from, state) do
    # Initialize components
    buffer_manager =
      Manager.new(
        width,
        height,
        scrollback_limit: config.scrollback_limit,
        memory_limit: config.memory_limit
      )

    scroll_buffer = Raxol.Terminal.Buffer.Scroll.new(config.scrollback_limit)
    {:ok, renderer} = RenderServer.start_link(config.rendering)
    Process.unlink(renderer)
    command_history = History.new(config.command_history_limit)

    new_state = %{
      state
      | buffer_manager: buffer_manager,
        scroll_buffer: scroll_buffer,
        renderer: renderer,
        command_history: command_history,
        config: config
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:process_input, event}, _from, state) do
    case process_input_event(state, event) do
      {:ok, new_state, commands} ->
        {:reply, {:ok, commands}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call({:process_output, data}, _from, state) do
    {:ok, new_state, commands} = process_output_data(state, data)
    {:reply, {:ok, commands}, new_state}
  end

  @impl true
  def handle_manager_call({:update_config, config}, _from, state) do
    # Merge with defaults to ensure all required keys are present
    merged_config = Map.merge(get_default_config(), config)
    new_state = update_io_config(state, merged_config)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:set_config_value, path, value}, _from, state) do
    # Ensure we have a config to work with
    config = state.config || get_default_config()

    # Ensure the path structure exists before using put_in
    config = ensure_config_path(config, path)

    new_config = put_in(config, path, value)
    # Deep merge with defaults to ensure all required keys are present
    merged_config = deep_merge(get_default_config(), new_config)
    new_state = update_io_config(state, merged_config)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call(:reset_config, _from, state) do
    new_config = get_default_config()
    new_state = update_io_config(state, new_config)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:resize, width, height}, _from, state) do
    new_state = handle_resize(state, width, height)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_manager_call({:set_cursor_visibility, visible}, _from, state) do
    # Only call RenderServer if it's available
    set_cursor_visibility_if_available(visible)
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_call(:get_title, _from, state) do
    {:reply, {:ok, ""}, state}
  end

  @impl true
  def handle_manager_call({:set_title, _title}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_manager_call(:cleanup, _from, state) do
    # Reset all state to initial values
    new_state = %__MODULE__{
      # Input state
      mode: :normal,
      history_index: nil,
      input_history: [],
      buffer: "",
      prompt: nil,
      completion_context: nil,
      last_event_time: nil,
      last_input: nil,
      clipboard_content: nil,
      clipboard_history: [],
      mouse_enabled: false,
      mouse_buttons: MapSet.new(),
      mouse_position: {0, 0},
      modifier_state: %{},
      input_queue: [],
      processing_escape: false,
      completion_callback: nil,
      completion_options: [],
      completion_index: 0,

      # Output state
      output_buffer: "",
      output_queue: [],
      output_processing: false,

      # Configuration
      config: state.config
    }

    {:reply, :ok, new_state}
  end

  # Helper functions
  defp set_cursor_visibility_if_available(visible) do
    case Process.whereis(Raxol.Terminal.Rendering.RenderServer) do
      nil -> :ok
      _pid -> RenderServer.set_cursor_visibility(visible)
    end
  end

  defp update_render_server_config_if_available(rendering_config) do
    case Process.whereis(Raxol.Terminal.Rendering.RenderServer) do
      nil -> :ok
      _pid -> RenderServer.update_config(rendering_config)
    end
  end

  # Private Functions

  defp process_input_event(state, event) do
    case event do
      # Keyboard events
      %{type: :key, key: key} ->
        process_keyboard_input(state, key)

      # Mouse events
      %{type: :mouse} = mouse_event ->
        process_mouse_input(state, mouse_event)

      # Special key events
      %{type: :special_key, key: key} ->
        process_special_key(state, key)

      # Invalid events - handle gracefully
      %{type: :invalid} ->
        {:ok, state, []}

      # Unknown events - handle gracefully
      %{type: :unknown} ->
        {:ok, state, []}

      # Invalid event
      _ ->
        {:error, "Invalid event type: #{inspect(event.type)}"}
    end
  end

  defp process_keyboard_input(state, key) do
    handle_keyboard_input(state.processing_escape, state, key)
  end

  defp handle_keyboard_input(true, state, key) do
    handle_escape_sequence(state, key)
  end

  defp handle_keyboard_input(false, state, key) do
    case key do
      "\e" -> {:ok, %{state | processing_escape: true}, []}
      _ -> process_normal_input(state, key)
    end
  end

  defp process_mouse_input(state, event) do
    handle_mouse_input(state.mouse_enabled, state, event)
  end

  defp handle_mouse_input(true, state, event) do
    mouse_sequence = encode_mouse_event(event)

    new_state = %{
      state
      | buffer: state.buffer <> mouse_sequence,
        mouse_buttons: update_mouse_buttons(state.mouse_buttons, event),
        mouse_position: {event.x, event.y}
    }

    {:ok, new_state, []}
  end

  defp handle_mouse_input(false, state, _event) do
    {:ok, state, []}
  end

  defp process_special_key(state, key) do
    special_key_sequence = get_special_key_sequence(key)
    process_keyboard_input(state, special_key_sequence)
  end

  defp process_output_data(state, data) when is_nil(data) do
    # Handle nil data gracefully
    {:ok, state, []}
  end

  defp process_output_data(state, data) do
    # Add data to output buffer
    new_state = %{state | output_buffer: state.output_buffer <> data}

    # Process the output buffer
    {:ok, final_state, commands} = process_output_buffer(new_state)
    {:ok, final_state, commands}
  end

  defp process_output_buffer(state) do
    case state.output_buffer do
      "" -> {:ok, state, []}
      _ -> {:ok, %{state | output_buffer: ""}, []}
    end
  end

  defp update_io_config(state, config) when is_map(config) do
    # Initialize or update components
    {buffer_manager, scroll_buffer, renderer, command_history} =
      initialize_or_update_components(state, config)

    %{
      state
      | buffer_manager: buffer_manager,
        scroll_buffer: scroll_buffer,
        renderer: renderer,
        command_history: command_history,
        config: config
    }
  end

  defp initialize_or_update_components(state, config) do
    handle_component_initialization(state.buffer_manager, state, config)
  end

  defp handle_component_initialization(nil, _state, config) do
    initialize_new_components(config)
  end

  defp handle_component_initialization(_buffer_manager, state, config) do
    update_existing_components(state, config)
  end

  defp update_existing_components(state, config) do
    # ScreenBuffer.Manager doesn't need config updates - just use existing manager
    new_buffer_manager = state.buffer_manager

    new_scroll_buffer =
      Raxol.Terminal.Buffer.Scroll.set_max_height(
        state.scroll_buffer,
        config.scrollback_limit
      )

    update_render_server_config_if_available(config.rendering)
    new_command_history = History.update_config(state.command_history, config)

    {new_buffer_manager, new_scroll_buffer, state.renderer, new_command_history}
  end

  defp initialize_new_components(config) do
    new_buffer_manager =
      Manager.new(
        config.width || @default_width,
        config.height || @default_height,
        scrollback_limit: config.scrollback_limit || @default_scrollback,
        memory_limit: config.memory_limit || 50 * 1024 * 1024
      )

    new_scroll_buffer =
      Raxol.Terminal.Buffer.Scroll.new(config.scrollback_limit || @default_scrollback)

    {:ok, new_renderer} = RenderServer.start_link(config.rendering || %{})
    Process.unlink(new_renderer)
    new_command_history = History.new(config.command_history_limit || @default_scrollback)

    {new_buffer_manager, new_scroll_buffer, new_renderer, new_command_history}
  end

  defp handle_resize(state, width, height) do
    # Ensure buffer manager exists
    buffer_manager =
      state.buffer_manager ||
        Manager.new(
          width,
          height,
          scrollback_limit: state.config[:scrollback_limit] || @default_scrollback,
          memory_limit: state.config[:memory_limit] || 50 * 1024 * 1024
        )

    handle_buffer_manager_resize(buffer_manager, state, width, height)
  end


  defp handle_buffer_manager_resize(buffer_manager, state, width, height) do
    # Update buffer manager
    new_buffer_manager = Manager.resize(buffer_manager, width, height)

    # Update renderer if it exists
    update_renderer_if_exists(state.renderer, width, height)

    %{state | buffer_manager: new_buffer_manager}
  end

  defp update_renderer_if_exists(nil, _width, _height), do: :ok

  defp update_renderer_if_exists(_renderer, width, height) do
    RenderServer.resize(width, height)
  end

  defp get_default_config do
    %{
      width: @default_width,
      height: @default_height,
      scrollback_limit: @default_scrollback,
      # 50 MB
      memory_limit: 50 * 1024 * 1024,
      command_history_limit: @default_scrollback,
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
  end

  defp encode_mouse_event(event) do
    # Encode mouse event as escape sequence
    "\e[M#{event.button + 32}#{event.x + 33}#{event.y + 33}"
  end

  defp update_mouse_buttons(buttons, event) do
    case event.event_type || event.type do
      :press -> MapSet.put(buttons, event.button)
      :release -> MapSet.delete(buttons, event.button)
      _ -> buttons
    end
  end

  defp get_special_key_sequence(:up), do: "\e[A"
  defp get_special_key_sequence(:down), do: "\e[B"
  defp get_special_key_sequence(:right), do: "\e[C"
  defp get_special_key_sequence(:left), do: "\e[D"
  defp get_special_key_sequence(:home), do: "\e[H"
  defp get_special_key_sequence(:end), do: "\e[F"
  defp get_special_key_sequence(:page_up), do: "\e[5~"
  defp get_special_key_sequence(:page_down), do: "\e[6~"
  defp get_special_key_sequence(:insert), do: "\e[2~"
  defp get_special_key_sequence(:delete), do: "\e[3~"
  defp get_special_key_sequence(:f1), do: "\eOP"
  defp get_special_key_sequence(:f2), do: "\eOQ"
  defp get_special_key_sequence(:f3), do: "\eOR"
  defp get_special_key_sequence(:f4), do: "\eOS"
  defp get_special_key_sequence(:f5), do: "\e[15~"
  defp get_special_key_sequence(:f6), do: "\e[17~"
  defp get_special_key_sequence(:f7), do: "\e[18~"
  defp get_special_key_sequence(:f8), do: "\e[19~"
  defp get_special_key_sequence(:f9), do: "\e[20~"
  defp get_special_key_sequence(:f10), do: "\e[21~"
  defp get_special_key_sequence(:f11), do: "\e[23~"
  defp get_special_key_sequence(:f12), do: "\e[24~"
  defp get_special_key_sequence(_), do: ""

  defp handle_escape_sequence(state, key) do
    sequence = state.escape_buffer <> key

    case sequence do
      "\e[" <> rest -> handle_csi_sequence(state, rest)
      "\eO" <> rest -> handle_ss3_sequence(state, rest)
      _ -> handle_incomplete_sequence(state, key, sequence)
    end
  end

  defp handle_csi_sequence(state, rest) do
    case parse_csi_sequence(rest) do
      {:ok, command} ->
        {:ok, %{state | processing_escape: false, escape_buffer: ""}, [command]}

      :invalid ->
        {:ok, %{state | processing_escape: false, escape_buffer: ""}, []}
    end
  end

  defp handle_ss3_sequence(state, rest) do
    case parse_ss3_sequence(rest) do
      {:ok, command} ->
        {:ok, %{state | processing_escape: false, escape_buffer: ""}, [command]}

      :invalid ->
        {:ok, %{state | processing_escape: false, escape_buffer: ""}, []}
    end
  end

  defp handle_incomplete_sequence(state, key, sequence) do
    handle_sequence_length(String.length(sequence) > 10, state, key)
  end

  defp handle_sequence_length(true, state, _key) do
    {:ok, %{state | processing_escape: false, escape_buffer: ""}, []}
  end

  defp handle_sequence_length(false, state, key) do
    {:ok, %{state | escape_buffer: state.escape_buffer <> key}, []}
  end

  defp process_normal_input(state, key) do
    # Process normal keyboard input
    new_state = %{state | buffer: state.buffer <> key, last_input: key}
    {:ok, new_state, []}
  end

  defp parse_csi_sequence(sequence) do
    # Parse CSI (Control Sequence Introducer) sequences
    case sequence do
      <<n::binary-size(1), "A">> ->
        {:ok, {:cursor_up, String.to_integer(n)}}

      <<n::binary-size(1), "B">> ->
        {:ok, {:cursor_down, String.to_integer(n)}}

      <<n::binary-size(1), "C">> ->
        {:ok, {:cursor_forward, String.to_integer(n)}}

      <<n::binary-size(1), "D">> ->
        {:ok, {:cursor_backward, String.to_integer(n)}}

      <<n::binary-size(1), "H">> ->
        {:ok, {:cursor_position, String.to_integer(n), 1}}

      <<n::binary-size(1), "F">> ->
        {:ok, {:cursor_position, String.to_integer(n), :end}}

      <<n::binary-size(1), "~">> ->
        {:ok, {:special_key, String.to_integer(n)}}

      _ ->
        :invalid
    end
  end

  defp parse_ss3_sequence(sequence) do
    # Parse SS3 (Single Shift Select of G3 Character Set) sequences
    case sequence do
      "P" -> {:ok, :f1}
      "Q" -> {:ok, :f2}
      "R" -> {:ok, :f3}
      "S" -> {:ok, :f4}
      _ -> :invalid
    end
  end

  # Private helper to ensure config path exists
  defp ensure_config_path(config, path) do
    update_in(config, Enum.map(path, &Access.key(&1, %{})), fn
      nil -> %{}
      val -> val
    end)
  end

  # Deep merge two maps, recursively merging nested maps
  defp deep_merge(map1, map2) do
    Map.merge(map1, map2, fn _key, val1, val2 ->
      merge_nested_values(val1, val2)
    end)
  end

  defp merge_nested_values(val1, val2) when is_map(val1) and is_map(val2) do
    deep_merge(val1, val2)
  end

  defp merge_nested_values(_val1, val2), do: val2
end
