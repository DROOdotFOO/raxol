defmodule Raxol.UI.ComponentTest do
  @moduledoc deprecated: "Scheduled for removal in Raxol 3.0; no replacement planned."
  @moduledoc """
  Test utilities for Raxol UI components.

  > #### Deprecated {: .warning}
  >
  > This module has no callers and is scheduled for removal in Raxol 3.0.

  Provides helpers for rendering components in isolation, simulating events,
  and asserting on component output.

  ## Usage

      defmodule MyComponentTest do
        use ExUnit.Case
        import Raxol.UI.ComponentTest

        test "renders button with label" do
          result = render_component(MyButton, label: "Click me")
          assert_text(result, "Click me")
        end

        test "handles click event" do
          {result, events} = render_with_events(MyButton, label: "Click")
          result = simulate_click(result, 5, 1)
          assert_event(events, :clicked)
        end
      end
  """

  alias Raxol.Core.Buffer

  @type render_result :: %{
          buffer: term(),
          state: term(),
          component: module(),
          props: keyword(),
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @doc """
  Render a component to a buffer for testing.

  ## Options

    - `:width` - Buffer width (default: 80)
    - `:height` - Buffer height (default: 24)
    - `:props` - Component props

  ## Example

      result = render_component(MyButton, label: "Click", width: 20, height: 3)
  """
  @spec render_component(module(), keyword()) :: render_result()
  def render_component(component, opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    props = Keyword.drop(opts, [:width, :height])

    buffer = Buffer.create_blank_buffer(width, height)

    state =
      if function_exported?(component, :init, 1) do
        component.init(props)
      else
        %{}
      end

    rendered_buffer =
      if function_exported?(component, :render, 2) do
        component.render(state, buffer)
      else
        buffer
      end

    %{
      buffer: rendered_buffer,
      state: state,
      component: component,
      props: props,
      width: width,
      height: height
    }
  end

  @doc """
  Render a component and capture events.

  Returns a tuple of {render_result, event_agent} where event_agent
  can be used to check which events were emitted.

  ## Example

      {result, events} = render_with_events(MyButton, label: "Click")
  """
  @spec render_with_events(module(), keyword()) :: {render_result(), pid()}
  def render_with_events(component, opts \\ []) do
    {:ok, events} = Agent.start_link(fn -> [] end)

    render_opts =
      Keyword.put(opts, :on_event, fn event ->
        Agent.update(events, fn list -> [event | list] end)
      end)

    result = render_component(component, render_opts)
    {result, events}
  end

  @doc """
  Simulate a click event on a rendered component.

  ## Example

      result = simulate_click(result, x: 5, y: 1)
  """
  @spec simulate_click(map(), non_neg_integer(), non_neg_integer()) :: map()
  def simulate_click(result, x, y) do
    simulate_event(result, %{
      type: :mouse,
      data: %{x: x, y: y, button: :left, action: :click}
    })
  end

  @doc """
  Simulate a key press event on a rendered component.

  ## Example

      result = simulate_key(result, :enter)
      result = simulate_key(result, "a")
  """
  @spec simulate_key(render_result(), atom() | String.t()) :: render_result()
  def simulate_key(result, key) do
    key_data =
      case key do
        k when is_atom(k) ->
          %{key: k, char: nil, ctrl: false, alt: false, shift: false}

        k when is_binary(k) ->
          %{key: :char, char: k, ctrl: false, alt: false, shift: false}
      end

    simulate_event(result, %{type: :key, data: key_data})
  end

  @doc """
  Simulate any event on a rendered component.

  ## Example

      result = simulate_event(result, %{type: :focus, data: %{}})
  """
  @spec simulate_event(map(), map()) :: map()
  def simulate_event(result, event) do
    component = result.component
    state = result.state

    new_state =
      if function_exported?(component, :handle_event, 3) do
        case component.handle_event(event, state, %{}) do
          {s, _commands} when is_map(s) -> s
          {:noreply, s} -> s
          {:reply, _msg, s} -> s
          s when is_map(s) -> s
        end
      else
        state
      end

    new_buffer =
      if function_exported?(component, :render, 2) do
        component.render(
          new_state,
          Buffer.create_blank_buffer(result.width, result.height)
        )
      else
        result.buffer
      end

    %{result | state: new_state, buffer: new_buffer}
  end

  @doc """
  Assert that the rendered buffer contains specific text.

  ## Example

      assert_text(result, "Hello")
  """
  @spec assert_text(map(), String.t()) :: :ok
  def assert_text(result, expected_text) do
    buffer_text = Buffer.to_string(result.buffer)

    unless String.contains?(buffer_text, expected_text) do
      raise ExUnit.AssertionError,
        message:
          "Expected buffer to contain #{inspect(expected_text)}\nGot:\n#{buffer_text}"
    end

    :ok
  end

  @doc """
  Assert that the rendered buffer does not contain specific text.

  ## Example

      refute_text(result, "Error")
  """
  @spec refute_text(map(), String.t()) :: :ok
  def refute_text(result, unexpected_text) do
    buffer_text = Buffer.to_string(result.buffer)

    if String.contains?(buffer_text, unexpected_text) do
      raise ExUnit.AssertionError,
        message:
          "Expected buffer NOT to contain #{inspect(unexpected_text)}\nGot:\n#{buffer_text}"
    end

    :ok
  end

  @doc """
  Assert that a specific event was captured.

  ## Example

      assert_event(events, :clicked)
      assert_event(events, {:value_changed, 42})
  """
  @spec assert_event(pid(), term()) :: :ok
  def assert_event(events_agent, expected_event) do
    captured = Agent.get(events_agent, & &1)

    matching =
      Enum.any?(captured, fn event ->
        match_event?(event, expected_event)
      end)

    unless matching do
      raise ExUnit.AssertionError,
        message:
          "Expected event #{inspect(expected_event)} to be captured\nCaptured events: #{inspect(captured)}"
    end

    :ok
  end

  @doc """
  Get all captured events.

  ## Example

      events = get_events(events_agent)
  """
  @spec get_events(pid()) :: list()
  def get_events(events_agent) do
    Agent.get(events_agent, & &1)
  end

  @doc """
  Clear all captured events.

  ## Example

      clear_events(events_agent)
  """
  @spec clear_events(pid()) :: :ok
  def clear_events(events_agent) do
    Agent.update(events_agent, fn _ -> [] end)
    :ok
  end

  @doc """
  Get the text content of a specific line from the buffer.

  ## Example

      line = get_line(result, 0)
  """
  @spec get_line(map(), non_neg_integer()) :: String.t()
  def get_line(result, line_number) do
    result.buffer
    |> Buffer.to_string()
    |> String.split("\n")
    |> Enum.at(line_number, "")
  end

  @doc """
  Get the character at a specific position in the buffer.

  ## Example

      char = get_char_at(result, 5, 2)
  """
  @spec get_char_at(map(), non_neg_integer(), non_neg_integer()) ::
          String.t() | nil
  def get_char_at(result, x, y) do
    line = get_line(result, y)

    if x < String.length(line) do
      String.at(line, x)
    else
      nil
    end
  end

  # Private helpers

  defp match_event?(event, expected) when is_atom(expected) do
    case event do
      ^expected -> true
      {^expected, _} -> true
      %{type: ^expected} -> true
      _ -> false
    end
  end

  defp match_event?(event, expected) do
    event == expected
  end
end
