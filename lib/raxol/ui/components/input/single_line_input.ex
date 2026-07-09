defmodule Raxol.UI.Components.Input.SingleLineInput do
  @moduledoc """
  A simple single-line text input component.
  """

  @typedoc """
  State for the SingleLineInput component.

  - :id - unique identifier
  - :value - current text value
  - :placeholder - placeholder text
  - :style - style map
  - :focused - whether the field is focused
  - :cursor_pos - cursor position
  - :on_change - callback for value change
  - :on_submit - callback for submit action
  """
  @type t :: %__MODULE__{
          id: any(),
          value: String.t(),
          placeholder: String.t(),
          style: map(),
          focused: boolean(),
          cursor_pos: non_neg_integer(),
          on_change: (String.t() -> any()) | nil,
          on_submit: (-> any()) | nil
        }

  # Use standard component behaviour
  use Raxol.UI.Components.Base.Component

  require Raxol.View.Elements
  require Raxol.Core.Renderer.View

  # Define state struct
  defstruct id: nil,
            value: "",
            placeholder: "",
            style: %{},
            focused: false,
            cursor_pos: 0,
            on_change: nil,
            on_submit: nil

  # --- Component Behaviour Callbacks ---

  @doc """
  Initializes the SingleLineInput component state from the given props.
  """
  @spec init(map()) :: {:ok, __MODULE__.t()}
  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    # Initialize state from props
    {:ok,
     %__MODULE__{
       id: props[:id],
       value: props[:initial_value] || "",
       placeholder: props[:placeholder] || "",
       style: props[:style] || %{},
       on_change: props[:on_change],
       on_submit: props[:on_submit],
       cursor_pos: String.length(props[:initial_value] || "")
     }}
  end

  @doc """
  Updates the SingleLineInput component state in response to messages or prop changes.
  """
  @spec update(term(), __MODULE__.t()) :: {__MODULE__.t(), list()}
  @impl Raxol.UI.Components.Base.Component
  def update(msg, state) do
    Raxol.Core.Runtime.Log.debug(
      "SingleLineInput #{state.id} received message: #{inspect(msg)}"
    )

    dispatch_message(msg, state)
  end

  defp dispatch_message({:insert_char, char}, state),
    do: insert_char(char, state)

  defp dispatch_message(:move_cursor_left, state), do: move_cursor(-1, state)
  defp dispatch_message(:move_cursor_right, state), do: move_cursor(1, state)
  defp dispatch_message(:backspace, state), do: backspace(state)
  defp dispatch_message(:delete, state), do: delete(state)
  defp dispatch_message(:move_cursor_start, state), do: move_cursor_to(0, state)

  defp dispatch_message(:move_cursor_end, state),
    do: move_cursor_to(String.length(state.value), state)

  defp dispatch_message(:submit, state), do: submit(state)
  defp dispatch_message(:focus, state), do: {%{state | focused: true}, []}
  defp dispatch_message(:blur, state), do: {%{state | focused: false}, []}
  defp dispatch_message(_msg, state), do: {state, []}

  @doc """
  Handles events for the SingleLineInput component, such as keypresses and mouse clicks.
  """
  @spec handle_event(term(), __MODULE__.t(), map()) :: {__MODULE__.t(), list()}
  @impl Raxol.UI.Components.Base.Component
  def handle_event(event, state, %{} = _context) do
    # Handle keyboard events, mouse clicks (focus), etc.
    Raxol.Core.Runtime.Log.debug(
      "SingleLineInput #{state.id} received event: #{inspect(event)}"
    )

    case event do
      %{type: :key, data: key_data} ->
        handle_key_event(key_data, state)

      # Focus on click
      %{type: :mouse, data: %{button: :left, action: :press}} ->
        {state, [{:focus, state.id}]}

      _ ->
        {state, []}
    end
  end

  # --- Render Logic ---

  @doc """
  Renders the SingleLineInput component using the current state and props.
  """
  @spec render(__MODULE__.t(), map()) :: any()
  @impl Raxol.UI.Components.Base.Component
  def render(%{value: "", focused: false} = state, %{} = _props) do
    Raxol.View.Elements.box id: state.id,
                            style: Map.put(state.style, :color, :gray) do
      Raxol.View.Elements.label(content: state.placeholder)
    end
  end

  def render(%{focused: true} = state, %{} = _props) do
    before = String.slice(state.value, 0, state.cursor_pos)
    after_cursor = String.slice(state.value, state.cursor_pos..-1//1)

    Raxol.View.Elements.box id: state.id,
                            style: Map.put(state.style, :color, :white) do
      [
        Raxol.View.Elements.label(content: before),
        Raxol.View.Elements.label(content: "|"),
        Raxol.View.Elements.label(content: after_cursor)
      ]
    end
  end

  def render(state, %{} = _props) do
    Raxol.View.Elements.box id: state.id,
                            style: Map.put(state.style, :color, :white) do
      Raxol.View.Elements.label(content: state.value)
    end
  end

  # --- Internal Helpers ---

  defp handle_key_event(key_data, state) do
    msg = map_key_to_message(key_data)

    case msg do
      nil -> {state, []}
      message -> update(message, state)
    end
  end

  defp map_key_to_message(%{key: k, modifiers: []})
       when is_binary(k) and byte_size(k) == 1 do
    {:insert_char, k}
  end

  defp map_key_to_message(%{key: "Enter", modifiers: []}), do: :submit
  defp map_key_to_message(%{key: "Backspace", modifiers: []}), do: :backspace
  defp map_key_to_message(%{key: "Delete", modifiers: []}), do: :delete
  defp map_key_to_message(%{key: "Left", modifiers: []}), do: :move_cursor_left

  defp map_key_to_message(%{key: "Right", modifiers: []}),
    do: :move_cursor_right

  defp map_key_to_message(%{key: "Home", modifiers: []}), do: :move_cursor_start
  defp map_key_to_message(%{key: "End", modifiers: []}), do: :move_cursor_end
  defp map_key_to_message(_), do: nil

  alias Raxol.UI.Components.Input.TextEditing

  defp insert_char(char, state) do
    {new_value, new_cursor_pos} =
      TextEditing.insert_at(state.value, state.cursor_pos, char)

    new_state = %{state | value: new_value, cursor_pos: new_cursor_pos}
    {new_state, on_change_commands(state.on_change, new_value)}
  end

  defp move_cursor(offset, state) do
    new_cursor_pos =
      TextEditing.move_cursor(state.value, state.cursor_pos, offset)

    {%{state | cursor_pos: new_cursor_pos}, []}
  end

  defp move_cursor_to(pos, state) do
    new_cursor_pos = TextEditing.move_cursor_to(state.value, pos)
    {%{state | cursor_pos: new_cursor_pos}, []}
  end

  defp backspace(state) do
    case TextEditing.backspace(state.value, state.cursor_pos) do
      {:noop, _} ->
        {state, []}

      {new_value, new_cursor_pos} ->
        new_state = %{state | value: new_value, cursor_pos: new_cursor_pos}
        {new_state, on_change_commands(state.on_change, new_value)}
    end
  end

  defp delete(state) do
    case TextEditing.delete(state.value, state.cursor_pos) do
      {:noop, _} ->
        {state, []}

      {new_value, cursor_pos} ->
        new_state = %{state | value: new_value, cursor_pos: cursor_pos}
        {new_state, on_change_commands(state.on_change, new_value)}
    end
  end

  defp submit(state) do
    commands =
      case state.on_submit do
        nil -> []
        callback -> [{callback, state.value}]
      end

    {state, commands}
  end

  defp on_change_commands(nil, _value), do: []
  defp on_change_commands(callback, value), do: [{callback, value}]
end
