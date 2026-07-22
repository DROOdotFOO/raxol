defmodule Raxol.UI.Components.Input.MultiLineInput.EventHandler do
  @moduledoc """
  Event handler for MultiLineInput component.
  Handles keyboard input and navigation events.

  Key events are normalized through `Raxol.UI.Harness.InputEvent` before
  dispatch. The previous head matched `data: %{key: key, modifiers:
  modifiers}` -- a shape that ONLY `Raxol.Core.Events.Event.key_event/3`
  (the test API) produces. The two real driver shapes -- the termbox
  `event_translator.ex`'s boolean `shift:`/`ctrl:`/... fields and the
  raw-ANSI `input_parser.ex`'s omitted-when-false fields -- carry no
  `:modifiers` key at all, so every real backspace/delete/arrow keypress
  fell through to the no-op default: dead editing keys on a real
  terminal, green tests on the test-API shape. `InputEvent.normalize/1`
  erases the shape difference (see that module's moduledoc -- this is
  the same class of fix its "What T11/T14 migrate to" section
  prescribes); the normalized mods map is rebuilt into the modifier-list
  vocabulary `dispatch_key/3`'s existing clauses already speak.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Harness.InputEvent

  # `InputEvent`'s press/repeat/nil-state set: an explicit `:released`
  # must not insert or re-dispatch (see that module's "Release does not
  # insert or dispatch" section).
  @live_states [nil, :pressed, :repeat]

  @doc """
  Handles events for the MultiLineInput component.
  """
  @spec handle_event(Event.t(), MultiLineInput.t()) ::
          {:update, term(), MultiLineInput.t()}
          | {:noreply, MultiLineInput.t()}
          | term()
  def handle_event(%Event{type: :key} = event, state) do
    case InputEvent.normalize(event) do
      %{kind: :char, char: char, state: key_state, mods: mods}
      when key_state in @live_states ->
        dispatch_key(char, modifier_list(mods), state)

      %{kind: :key, key: key, state: key_state, mods: mods}
      when key_state in @live_states ->
        dispatch_key(key, modifier_list(mods), state)

      _released_or_unclassifiable ->
        {:noreply, state, nil}
    end
  end

  def handle_event(
        %Event{
          type: :mouse,
          data: %{button: :left, state: :pressed, position: {x, y}}
        },
        state
      ) do
    # Handle mouse click to move cursor (coordinates are swapped: y becomes row, x becomes col)
    {:update, {:move_cursor_to, {y, x}}, state}
  end

  def handle_event(%Event{type: :mouse}, state) do
    # Handle other mouse events (drag, release, etc.)
    {:noreply, state}
  end

  def handle_event(_event, state) do
    # Default case for other event types
    {:noreply, state, nil}
  end

  # Character input. Routed through `{:clipboard_content, char}` -- the
  # same safe insertion path bracketed paste uses -- rather than
  # `{:input, char}`, whose `TextHelper.insert_char/2` expects an INTEGER
  # codepoint (`<<codepoint::utf8>>`) and raises on the binary grapheme
  # every key-event shape actually carries (the same upstream bug
  # `Raxol.UI.Components.Harness.Composer.insert_char/2` documents and
  # routes around). Also correctly inserts multi-codepoint graphemes
  # (emoji), which the previous `byte_size(char) == 1` guard dropped.
  defp dispatch_key(char, [], state) when is_binary(char),
    do: {:update, {:clipboard_content, char}, state}

  # Editing keys
  defp dispatch_key(:enter, [], state), do: {:update, {:enter}, state}
  defp dispatch_key(:backspace, [], state), do: {:update, {:backspace}, state}
  defp dispatch_key(:delete, [], state), do: {:update, {:delete}, state}
  defp dispatch_key(:tab, [], state), do: {:update, {:input, ?\t}, state}

  # Arrow keys (no modifier)
  defp dispatch_key(:up, [], state), do: {:update, {:move_cursor, :up}, state}

  defp dispatch_key(:down, [], state),
    do: {:update, {:move_cursor, :down}, state}

  defp dispatch_key(:left, [], state),
    do: {:update, {:move_cursor, :left}, state}

  defp dispatch_key(:right, [], state),
    do: {:update, {:move_cursor, :right}, state}

  # Arrow keys with shift (selection)
  defp dispatch_key(:up, [:shift], state),
    do: {:update, {:selection_move, :up}, state}

  defp dispatch_key(:down, [:shift], state),
    do: {:update, {:selection_move, :down}, state}

  defp dispatch_key(:left, [:shift], state),
    do: {:update, {:selection_move, :left}, state}

  defp dispatch_key(:right, [:shift], state),
    do: {:update, {:selection_move, :right}, state}

  # Home/End
  defp dispatch_key(:home, [], state),
    do: {:update, {:move_cursor_line_start}, state}

  defp dispatch_key(:end, [], state),
    do: {:update, {:move_cursor_line_end}, state}

  # Page up/down (both variants)
  defp dispatch_key(k, [], state) when k in [:page_up, :pageup],
    do: {:update, {:move_cursor_page, :up}, state}

  defp dispatch_key(k, [], state) when k in [:page_down, :pagedown],
    do: {:update, {:move_cursor_page, :down}, state}

  # Ctrl combinations
  defp dispatch_key("a", [:ctrl], state), do: {:update, {:select_all}, state}
  defp dispatch_key("c", [:ctrl], state), do: {:update, {:copy}, state}
  defp dispatch_key("v", [:ctrl], state), do: {:update, {:paste}, state}
  defp dispatch_key("x", [:ctrl], state), do: {:update, {:cut}, state}
  defp dispatch_key("z", [:ctrl], state), do: {:update, :undo, state}
  defp dispatch_key("y", [:ctrl], state), do: {:update, :redo, state}

  # Default case
  defp dispatch_key(_key, _modifiers, state), do: {:noreply, state, nil}

  # Rebuilds the modifier-list vocabulary `dispatch_key/3`'s clauses match
  # on ([:shift], [:ctrl], ...) from the normalized always-all-four mods
  # map. Fixed order; multi-modifier combinations produce a multi-element
  # list no clause matches, landing on the default no-op -- exactly the
  # pre-normalization behavior for those combinations.
  defp modifier_list(mods) do
    for mod <- [:ctrl, :alt, :shift, :meta], Map.get(mods, mod, false), do: mod
  end
end
