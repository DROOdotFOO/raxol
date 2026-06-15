# Counter Example
#
# A counter with two input sources: keyboard keys and button clicks.
#
# What you'll learn:
#   - Two kinds of messages: atoms from button on_click vs Event structs
#     from keyboard
#   - Layout macros: column (vertical), row (horizontal), box (bordered)
#   - Style maps (%{padding: 1}) vs style lists ([:bold])
#   - How buttons wire to update/2 via on_click atoms
#
# Usage:
#   mix run examples/getting_started/counter.exs
#
# Controls:
#   =       = increment
#   -       = decrement
#   q       = quit
#   Ctrl+C  = quit
#   (or click the buttons)

defmodule CounterExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{count: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      # Atoms arrive from button on_click handlers (see view/1 below).
      # The button widget sends the atom directly to update/2 -- no
      # Event struct wrapping, just the raw atom.
      :increment ->
        {%{model | count: model.count + 1}, []}

      :decrement ->
        {%{model | count: model.count - 1}, []}

      :reset ->
        {%{model | count: 0}, []}

      # Keyboard events arrive as Event structs (different from atoms).
      # Both sources feed into the same update/2 -- TEA unifies all input.
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
        {%{model | count: model.count + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} ->
        {%{model | count: model.count - 1}, []}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # column = vertical layout. style is a map with CSS-like properties.
    column style: %{padding: 1, gap: 1, align_items: :center} do
      [
        # style: [:bold] is a list of text attributes (bold, dim, underline)
        text("Counter Example", style: [:bold]),
        # box wraps content in a border. style is a map for layout properties.
        box style: %{
              padding: 1,
              border: :single,
              width: 20,
              justify_content: :center
            } do
          text("Count: #{model.count}", style: [:bold])
        end,
        # row = horizontal layout. on_click: :increment sends that atom
        # directly to update/2 when clicked.
        row style: %{gap: 1} do
          [
            button("Increment (=)", on_click: :increment),
            button("Reset", on_click: :reset),
            button("Decrement (-)", on_click: :decrement)
          ]
        end,
        text("Press '=' or '-' keys, or click buttons."),
        text("Press 'q' or Ctrl+C to quit")
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    []
  end
end

{:ok, pid} = Raxol.start_link(CounterExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
