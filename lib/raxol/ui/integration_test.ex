defmodule Raxol.UI.IntegrationTest do
  @moduledoc deprecated:
               "Scheduled for removal in Raxol 3.0; no replacement planned."
  @moduledoc """
  Integration testing utilities for Raxol applications.

  > #### Deprecated {: .warning}
  >
  > This module has no callers and is scheduled for removal in Raxol 3.0.

  Provides helpers for testing complete application flows including
  component interactions, state management, and event handling.

  ## Usage

      defmodule MyAppIntegrationTest do
        use ExUnit.Case
        import Raxol.UI.IntegrationTest

        test "user can navigate menu and select option" do
          app = start_test_app(MyApp)

          app
          |> send_key(:down)
          |> send_key(:down)
          |> send_key(:enter)
          |> assert_screen_contains("Option 2 selected")
        end
      end
  """

  alias Raxol.Core.Buffer
  @default_timeout_ms Raxol.Core.Defaults.timeout_ms()

  @doc """
  Start an application for integration testing.

  ## Options

    - `:width` - Terminal width (default: 80)
    - `:height` - Terminal height (default: 24)
    - `:initial_state` - Override initial state

  ## Example

      app = start_test_app(MyApp, width: 120, height: 40)
  """
  @spec start_test_app(module(), keyword()) :: %{
          module: module(),
          state: map(),
          buffer: term(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          event_log: list()
        }
  def start_test_app(app_module, opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    initial_state = Keyword.get(opts, :initial_state)

    buffer = Buffer.create_blank_buffer(width, height)

    state =
      cond do
        initial_state != nil ->
          initial_state

        function_exported?(app_module, :init, 1) ->
          app_module.init(opts)

        function_exported?(app_module, :init, 0) ->
          app_module.init()

        true ->
          %{}
      end

    rendered_buffer =
      if function_exported?(app_module, :render, 2) do
        app_module.render(state, buffer)
      else
        buffer
      end

    %{
      module: app_module,
      state: state,
      buffer: rendered_buffer,
      width: width,
      height: height,
      event_log: []
    }
  end

  @doc """
  Send a key event to the application.

  ## Example

      app = send_key(app, :enter)
      app = send_key(app, "a")
      app = send_key(app, :tab, ctrl: true)
  """
  @spec send_key(
          %{
            module: module(),
            state: map(),
            buffer: term(),
            width: non_neg_integer(),
            height: non_neg_integer(),
            event_log: list()
          },
          atom() | String.t(),
          keyword()
        ) :: %{
          module: module(),
          state: map(),
          buffer: term(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          event_log: list()
        }
  def send_key(app, key, modifiers \\ []) do
    event = build_key_event(key, modifiers)
    process_event(app, event)
  end

  @doc """
  Send a mouse click event to the application.

  ## Example

      app = send_click(app, 10, 5)
      app = send_click(app, 10, 5, button: :right)
  """
  @spec send_click(map(), non_neg_integer(), non_neg_integer(), keyword()) ::
          map()
  def send_click(app, x, y, opts \\ []) do
    button = Keyword.get(opts, :button, :left)

    event = %{
      type: :mouse,
      data: %{x: x, y: y, button: button, action: :click}
    }

    process_event(app, event)
  end

  @doc """
  Send a resize event to the application.

  ## Example

      app = send_resize(app, 120, 40)
  """
  @spec send_resize(map(), pos_integer(), pos_integer()) :: map()
  def send_resize(app, width, height) do
    event = %{type: :resize, data: %{width: width, height: height}}

    app
    |> Map.put(:width, width)
    |> Map.put(:height, height)
    |> process_event(event)
  end

  @doc """
  Send a sequence of keys to the application.

  ## Example

      app = send_keys(app, [:down, :down, :enter])
      app = send_keys(app, ["h", "e", "l", "l", "o"])
  """
  @spec send_keys(map(), list()) :: map()
  def send_keys(app, keys) do
    Enum.reduce(keys, app, fn key, acc ->
      send_key(acc, key)
    end)
  end

  @doc """
  Type a string as individual key presses.

  ## Example

      app = type_text(app, "Hello, World!")
  """
  @spec type_text(map(), String.t()) :: map()
  def type_text(app, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(app, fn char, acc ->
      send_key(acc, char)
    end)
  end

  @doc """
  Assert that the screen contains specific text.

  ## Example

      app |> assert_screen_contains("Welcome")
  """
  @spec assert_screen_contains(map(), String.t()) :: map()
  def assert_screen_contains(app, expected_text) do
    screen_text = Buffer.to_string(app.buffer)

    unless String.contains?(screen_text, expected_text) do
      raise ExUnit.AssertionError,
        message:
          "Expected screen to contain #{inspect(expected_text)}\n\nScreen content:\n#{screen_text}"
    end

    app
  end

  @doc """
  Assert that the screen does not contain specific text.

  ## Example

      app |> refute_screen_contains("Error")
  """
  @spec refute_screen_contains(map(), String.t()) :: map()
  def refute_screen_contains(app, unexpected_text) do
    screen_text = Buffer.to_string(app.buffer)

    if String.contains?(screen_text, unexpected_text) do
      raise ExUnit.AssertionError,
        message:
          "Expected screen NOT to contain #{inspect(unexpected_text)}\n\nScreen content:\n#{screen_text}"
    end

    app
  end

  @doc """
  Assert that a specific line contains text.

  ## Example

      app |> assert_line(0, "Title")
  """
  @spec assert_line(map(), non_neg_integer(), String.t()) :: map()
  def assert_line(app, line_number, expected_text) do
    line = get_screen_line(app, line_number)

    unless String.contains?(line, expected_text) do
      raise ExUnit.AssertionError,
        message:
          "Expected line #{line_number} to contain #{inspect(expected_text)}\n\nLine content: #{inspect(line)}"
    end

    app
  end

  @doc """
  Assert that the application state matches a pattern.

  ## Example

      app |> assert_state(%{selected_index: 2})
  """
  @spec assert_state(map(), map() | keyword()) :: map()
  def assert_state(app, expected_state) do
    expected_map =
      case expected_state do
        m when is_map(m) -> m
        kw when is_list(kw) -> Map.new(kw)
      end

    Enum.each(expected_map, fn {key, expected_value} ->
      actual_value = Map.get(app.state, key)

      unless actual_value == expected_value do
        raise ExUnit.AssertionError,
          message:
            "Expected state.#{key} to be #{inspect(expected_value)}, got #{inspect(actual_value)}\n\nFull state: #{inspect(app.state)}"
      end
    end)

    app
  end

  @doc """
  Get the current screen content as a string.

  ## Example

      screen = get_screen(app)
  """
  @spec get_screen(map()) :: String.t()
  def get_screen(app) do
    Buffer.to_string(app.buffer)
  end

  @doc """
  Get a specific line from the screen.

  ## Example

      line = get_screen_line(app, 0)
  """
  @spec get_screen_line(map(), non_neg_integer()) :: String.t()
  def get_screen_line(app, line_number) do
    app
    |> get_screen()
    |> String.split("\n")
    |> Enum.at(line_number, "")
  end

  @doc """
  Get the event log showing all events processed.

  ## Example

      events = get_event_log(app)
  """
  @spec get_event_log(map()) :: list()
  def get_event_log(app) do
    Enum.reverse(app.event_log)
  end

  @doc """
  Clear the event log.

  ## Example

      app = clear_event_log(app)
  """
  @spec clear_event_log(%{
          module: module(),
          state: map(),
          buffer: term(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          event_log: list()
        }) :: %{
          module: module(),
          state: map(),
          buffer: term(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          event_log: list()
        }
  def clear_event_log(app) do
    %{app | event_log: []}
  end

  @doc """
  Wait for a condition to be true (useful for async operations).

  ## Example

      app = wait_for(app, fn a -> a.state.loading == false end, timeout: 1000)
  """
  @spec wait_for(map(), (map() -> boolean()), keyword()) :: map()
  def wait_for(app, condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for(app, condition_fn, deadline, interval)
  end

  # Private helpers

  defp build_key_event(key, modifiers) do
    ctrl = Keyword.get(modifiers, :ctrl, false)
    alt = Keyword.get(modifiers, :alt, false)
    shift = Keyword.get(modifiers, :shift, false)
    meta = Keyword.get(modifiers, :meta, false)

    key_data =
      case key do
        k when is_atom(k) ->
          %{key: k, char: nil, ctrl: ctrl, alt: alt, shift: shift, meta: meta}

        k when is_binary(k) ->
          %{key: :char, char: k, ctrl: ctrl, alt: alt, shift: shift, meta: meta}
      end

    %{type: :key, data: key_data}
  end

  defp process_event(app, event) do
    module = app.module
    state = app.state

    new_state =
      if function_exported?(module, :handle_event, 3) do
        case module.handle_event(event, state, %{}) do
          {s, _commands} when is_map(s) -> s
          {:noreply, s} -> s
          {:reply, _msg, s} -> s
          s when is_map(s) -> s
        end
      else
        state
      end

    new_buffer =
      if function_exported?(module, :render, 2) do
        module.render(
          new_state,
          Buffer.create_blank_buffer(app.width, app.height)
        )
      else
        app.buffer
      end

    %{
      app
      | state: new_state,
        buffer: new_buffer,
        event_log: [event | app.event_log]
    }
  end

  defp do_wait_for(app, condition_fn, deadline, interval) do
    cond do
      condition_fn.(app) ->
        app

      System.monotonic_time(:millisecond) >= deadline ->
        raise ExUnit.AssertionError,
          message:
            "Timeout waiting for condition\n\nFinal state: #{inspect(app.state)}"

      true ->
        Process.sleep(interval)
        do_wait_for(app, condition_fn, deadline, interval)
    end
  end
end
