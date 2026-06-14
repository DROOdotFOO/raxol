defmodule Raxol.Core.Events.Event do
  @moduledoc """
  Defines the structure for events in the Raxol system, providing a standardized format
  for key presses, mouse actions, and other UI events that components need to process.

  Events are structs with a :type and :data field, where :type indicates the event category
  (e.g., :key, :mouse, :resize) and :data contains the event-specific details.
  """

  @type event_type :: atom()
  @type event_data :: any()

  @type t :: %__MODULE__{
          type: event_type(),
          data: event_data(),
          timestamp: DateTime.t()
        }

  defstruct [:type, :data, :timestamp, mounted: false, render_count: 0]

  @doc """
  Creates a new event with the given type and data. Optionally accepts a timestamp (defaults to now).
  """
  def new(type, data, timestamp \\ DateTime.utc_now()) do
    %__MODULE__{
      type: type,
      data: data,
      timestamp: timestamp
    }
  end

  @type key :: atom() | String.t()
  @type key_state :: :pressed | :released | :repeat
  @type modifiers :: [atom()]

  @type key_event :: %{
          key: key(),
          state: key_state(),
          modifiers: modifiers()
        }

  @doc """
  Creates a keyboard event.

  ## Parameters
    * `key` - The key that was pressed/released (e.g. :enter, :backspace, "a")
    * `state` - The state of the key (:pressed, :released, :repeat)
    * `modifiers` - List of active modifiers (e.g. [:shift, :ctrl])
  """
  def key_event(key, state, modifiers \\ [])

  def key_event(key, state, modifiers)
      when state in [:pressed, :released, :repeat] and is_list(modifiers) do
    new(:key, %{
      key: key,
      state: state,
      modifiers: modifiers
    })
  end

  def key_event(_key, _state, _modifiers) do
    {:error, :invalid_key_event}
  end

  @doc """
  Creates a simple key event with pressed state and no modifiers.
  """
  def key(key) do
    key_event(key, :pressed, [])
  end

  @type mouse_button :: :left | :right | :middle
  @type mouse_state :: :pressed | :released | :double_click
  @type mouse_position :: {non_neg_integer(), non_neg_integer()}

  @type mouse_event :: %{
          button: mouse_button() | nil,
          state: mouse_state() | nil,
          position: mouse_position(),
          modifiers: modifiers()
        }

  @doc """
  Creates a mouse event.

  ## Parameters
    * `button` - The mouse button (:left, :right, :middle)
    * `position` - The mouse position as {x, y}
    * `state` - The button state (:pressed, :released, :double_click)
    * `modifiers` - List of active modifiers (e.g. [:shift, :ctrl])
  """
  def mouse_event(button, position, state \\ :pressed, modifiers \\ [])

  def mouse_event(button, position, state, modifiers)
      when button in [:left, :right, :middle] and
             state in [:pressed, :released, :double_click] and
             is_tuple(position) and
             is_list(modifiers) do
    new(:mouse, %{
      button: button,
      position: position,
      state: state,
      modifiers: modifiers
    })
  end

  def mouse_event(_button, _position, _state, _modifiers) do
    {:error, :invalid_mouse_event}
  end

  @doc """
  Creates a simple mouse event with pressed state and no modifiers.
  """
  def mouse(button, position) when button in [:left, :right, :middle] do
    mouse_event(button, position)
  end

  @doc """
  Creates a mouse event with drag state.
  """
  def mouse(button, position, drag: true)
      when button in [:left, :right, :middle] do
    new(:mouse, %{
      button: button,
      position: position,
      state: :pressed,
      drag: true,
      modifiers: []
    })
  end

  @type window_event :: %{
          width: non_neg_integer(),
          height: non_neg_integer(),
          action: :resize | :focus | :blur
        }

  @doc """
  Creates a window event.

  ## Parameters
    * `width` - The window width
    * `height` - The window height
    * `action` - The window action (:resize, :focus, :blur)
  """
  def window_event(width, height, action)
      when is_integer(width) and is_integer(height) and
             action in [:resize, :focus, :blur] do
    new(:window, %{
      width: width,
      height: height,
      action: action
    })
  end

  def window_event(_width, _height, _action) do
    {:error, :invalid_window_event}
  end

  @doc """
  Creates a simple window event.
  """
  def window(width, height, action) when action in [:resize, :focus, :blur] do
    window_event(width, height, action)
  end

  @doc """
  Creates a timer event.

  ## Parameters
    * `data` - Timer-specific data
  """
  def timer_event(data) do
    new(:timer, data)
  end

  @doc """
  Creates a simple timer event.
  """
  def timer(data) do
    timer_event(data)
  end

  @doc """
  Creates a custom event.

  ## Parameters
    * `data` - Custom event data
  """
  def custom_event(data) do
    new(:custom, data)
  end

  @doc """
  Creates a simple custom event.
  """
  def custom(data) do
    custom_event(data)
  end

  @type focus_target :: :component | :window | :application
  @type focus_event :: %{
          target: focus_target(),
          focused: boolean()
        }

  @doc """
  Creates a focus event.

  ## Parameters
    * `target` - What received/lost focus
    * `focused` - Whether focus was gained (true) or lost (false)
  """
  def focus_event(target, focused)
      when target in [:component, :window, :application] do
    new(:focus, %{
      target: target,
      focused: focused
    })
  end

  @type scroll_direction :: :vertical | :horizontal
  @type scroll_event :: %{
          direction: scroll_direction(),
          delta: integer(),
          position: {non_neg_integer(), non_neg_integer()}
        }

  @doc """
  Creates a scroll event.

  ## Parameters
    * `direction` - Scroll direction
    * `delta` - Amount scrolled (positive or negative)
    * `position` - Current scroll position
  """
  def scroll_event(direction, delta, position)
      when direction in [:vertical, :horizontal] and is_integer(delta) do
    new(:scroll, %{
      direction: direction,
      delta: delta,
      position: position
    })
  end

  @type cursor_event :: %{
          visible: boolean(),
          style: :block | :line | :underscore,
          blink: boolean(),
          position: {non_neg_integer(), non_neg_integer()}
        }

  @doc """
  Creates a cursor event.

  ## Parameters
    * `visible` - Whether cursor is visible
    * `style` - Cursor style
    * `blink` - Whether cursor should blink
    * `position` - Cursor position
  """
  def cursor_event(visible, style, blink, position)
      when is_boolean(visible) and style in [:block, :line, :underscore] and
             is_boolean(blink) and is_tuple(position) do
    new(:cursor, %{
      visible: visible,
      style: style,
      blink: blink,
      position: position
    })
  end

  @type selection_event :: %{
          start_pos: {non_neg_integer(), non_neg_integer()},
          end_pos: {non_neg_integer(), non_neg_integer()},
          text: String.t()
        }

  @doc """
  Creates a selection event.

  ## Parameters
    * `start_pos` - Selection start position
    * `end_pos` - Selection end position
    * `text` - Selected text
  """
  def selection_event(start_pos, end_pos, text)
      when is_tuple(start_pos) and is_tuple(end_pos) and is_binary(text) do
    new(:selection, %{
      start_pos: start_pos,
      end_pos: end_pos,
      text: text
    })
  end

  @type paste_event :: %{
          text: String.t(),
          position: {non_neg_integer(), non_neg_integer()}
        }

  @doc """
  Creates a paste event.

  ## Parameters
    * `text` - Pasted text
    * `position` - Paste position
  """
  def paste_event(text, position) when is_binary(text) and is_tuple(position) do
    new(:paste, %{
      text: text,
      position: position
    })
  end

  # -- Pattern-matching macros for concise event matching in update/2 --

  @doc """
  Match macro for key events. Works in pattern match positions (case/function heads).

  ## Examples

      # Match a character key:
      key_match("q") -> ...

      # Match a special key:
      key_match(:tab) -> ...

      # Match with extra data fields:
      key_match(:tab, shift: true) -> ...
  """
  defmacro key_match(char_or_key) do
    case char_or_key do
      {val, _, _} when is_atom(val) ->
        # Variable or atom literal -- treat as special key
        quote do
          %Raxol.Core.Events.Event{
            type: :key,
            data: %{key: unquote(char_or_key)}
          }
        end

      val when is_atom(val) ->
        # Literal atom like :tab, :up, :down
        quote do
          %Raxol.Core.Events.Event{
            type: :key,
            data: %{key: unquote(val)}
          }
        end

      val when is_binary(val) ->
        # String literal like "q", "1"
        quote do
          %Raxol.Core.Events.Event{
            type: :key,
            data: %{key: :char, char: unquote(val)}
          }
        end

      _ ->
        quote do
          %Raxol.Core.Events.Event{
            type: :key,
            data: %{key: unquote(char_or_key)}
          }
        end
    end
  end

  @doc """
  Match macro for key events with additional data fields.

  ## Examples

      key_match(:tab, shift: true) -> ...
  """
  defmacro key_match(key, extra) do
    extra_pairs =
      case extra do
        pairs when is_list(pairs) ->
          Enum.map(pairs, fn {k, v} -> {k, v} end)

        _ ->
          []
      end

    base_pairs =
      if is_binary(key) do
        [{:key, :char}, {:char, key} | extra_pairs]
      else
        [{:key, key} | extra_pairs]
      end

    data_pattern = {:%{}, [], base_pairs}

    quote do
      %Raxol.Core.Events.Event{type: :key, data: unquote(data_pattern)}
    end
  end

  # -- CloudEvents v1.0 interop --

  @type_prefix "raxol."

  @doc """
  Convert an Event to a `Raxol.Core.Events.CloudEvent`.

  The CloudEvents `type` is `"raxol.<atom>"`. The `source` defaults to
  the `:event_source` application env (or `"raxol://localhost"`).

  ## Options

    * `:source` - override the source URI for this conversion
  """
  @spec to_cloud_event(t(), keyword()) :: Raxol.Core.Events.CloudEvent.t()
  def to_cloud_event(%__MODULE__{} = event, opts \\ []) do
    source =
      Keyword.get(opts, :source) ||
        Application.get_env(:raxol_core, :event_source, "raxol://localhost")

    Raxol.Core.Events.CloudEvent.new(
      @type_prefix <> Atom.to_string(event.type),
      source,
      data: event.data,
      time: event.timestamp
    )
  end

  @doc """
  Build an Event from a `Raxol.Core.Events.CloudEvent`.

  Returns `{:error, :unknown_event_type}` if the CloudEvents `type` does
  not strip to a known atom in the current VM (existing-atoms only, to
  avoid memory-leak risk on external input).
  """
  @spec from_cloud_event(Raxol.Core.Events.CloudEvent.t()) ::
          {:ok, t()} | {:error, :unknown_event_type}
  def from_cloud_event(%Raxol.Core.Events.CloudEvent{} = ce) do
    raw =
      case ce.type do
        @type_prefix <> rest -> rest
        other -> other
      end

    try do
      atom = String.to_existing_atom(raw)
      timestamp = ce.time || DateTime.utc_now()
      {:ok, new(atom, ce.data, timestamp)}
    rescue
      ArgumentError -> {:error, :unknown_event_type}
    end
  end
end
