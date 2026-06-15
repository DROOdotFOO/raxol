# Event Handling
#
# Demonstrates handling keyboard events, button clicks, and text input.
#
# What you'll learn:
#   - Event struct shapes: named char, special key, modifier
#   - Pattern matching order: specific clauses before catch-all
#   - `is_binary(ch)` guard separates printable chars from special keys
#   - Button on_click atoms vs keyboard Event structs in the same update/2
#
# Usage:
#   mix run examples/scripts/event_handling.exs
#
# Controls:
#   Any key  = display in "Last Key" box
#   q        = quit
#   Ctrl+C   = quit
#   (or click the +/- buttons)

defmodule EventHandlingExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{count: 0, text_value: "", last_key: "none"}
  end

  @impl true
  def update(message, model) do
    case message do
      # Atoms from button on_click (no Event struct wrapper)
      :increment ->
        {%{model | count: model.count + 1}, []}

      :decrement ->
        {%{model | count: model.count - 1}, []}

      # Named character: data.key is :char and data.char is a binary string
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      # Modifier key: ctrl: true appears in the data map
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # Any printable character: `is_binary(ch)` guard ensures ch is text,
      # not an atom like :enter or :esc. Order matters -- this must come
      # after the specific "q" and "c" matches above.
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when is_binary(ch) ->
        {%{model | last_key: ch}, []}

      # Special keys: :enter, :esc, :tab, :up, :down, :backspace, etc.
      # data.key is an atom, not :char
      %Raxol.Core.Events.Event{type: :key, data: %{key: key}} ->
        {%{model | last_key: inspect(key)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Event Handling Demo", style: [:bold]),
        box title: "Counter", style: %{border: :single, padding: 1} do
          column style: %{gap: 1} do
            [
              text("Count: #{model.count}"),
              row style: %{gap: 1} do
                [
                  button("Increment (+)", on_click: :increment),
                  button("Decrement (-)", on_click: :decrement)
                ]
              end
            ]
          end
        end,
        box title: "Last Key Pressed", style: %{border: :single, padding: 1} do
          text("Key: #{model.last_key}")
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

Raxol.Core.Runtime.Log.info("EventHandlingExample: Starting...")
{:ok, pid} = Raxol.start_link(EventHandlingExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
