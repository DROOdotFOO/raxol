# Hello World
#
# The simplest Raxol application: display a message and quit on 'q'.
#
# What you'll learn:
#   - The four TEA callbacks (init, update, view, subscribe)
#   - How `use Raxol.Core.Runtime.Application` wires everything up
#   - Event struct shape for keyboard input
#   - Commands as data (returning side effects from update/2)
#   - View DSL macros for layout (column, box, text)
#
# Usage:
#   mix run examples/getting_started/hello_world.exs
#
# Controls:
#   q       = quit
#   Ctrl+C  = quit

defmodule HelloWorld do
  # This single `use` imports the View DSL macros (column, box, text, etc.),
  # the key_match macro for keyboard shortcuts, the command() helper for
  # side effects, and sets up the TEA behaviour callbacks.
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  # -- TEA callback 1/4: init/1 --
  # Called once at startup. Returns the initial model (app state).
  # The model is a plain map -- no structs, no special types.
  @impl true
  def init(_context) do
    %{message: "Hello, World!"}
  end

  # -- TEA callback 2/4: update/2 --
  # Called whenever a message arrives (keyboard event, button click, timer).
  # Must return {updated_model, list_of_commands}.
  # An empty command list [] means "no side effects."
  @impl true
  def update(message, model) do
    case message do
      # Keyboard events arrive as Event structs. The shape:
      #   %Event{type: :key, data: %{key: :char, char: "q"}}
      # :char means a printable character; special keys use atoms like :enter, :esc
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        # command(:quit) is a built-in command that tells the runtime to
        # shut down gracefully. Commands are data returned from update/2,
        # not imperative calls -- this is how TEA isolates side effects.
        {model, [Directive.stop()]}

      # Modifier keys appear in the data map: ctrl, alt, shift
      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # Catch-all: ignore any message we don't handle.
      # Always return {model, []} to keep the loop running.
      _ ->
        {model, []}
    end
  end

  # -- TEA callback 3/4: view/1 --
  # Pure function: takes the model, returns a UI element tree.
  # Called after every update/2. Never do side effects here.
  @impl true
  def view(model) do
    # View DSL macros build a declarative element tree:
    #   column  = vertical stack (like CSS flex-direction: column)
    #   box     = bordered container with optional title
    #   text    = text display; style: [:bold] for text attributes
    column style: %{padding: 2, gap: 1, align_items: :center} do
      [
        box style: %{
              border: :single,
              padding: 1,
              width: 30,
              justify_content: :center
            } do
          text(model.message, style: [:bold])
        end,
        text("Press 'q' to quit.")
      ]
    end
  end

  # -- TEA callback 4/4: subscribe/1 --
  # Returns a list of subscriptions (timers, external data feeds).
  # Empty list means this app only reacts to user input.
  @impl true
  def subscribe(_model), do: []
end

# -- Boot sequence --
# Raxol.start_link/2 starts a supervised process running the TEA loop.
# It initializes the terminal, calls init/1, renders the first view/1,
# then waits for events to feed into update/2.
Raxol.Core.Runtime.Log.info("HelloWorld: Starting...")
{:ok, pid} = Raxol.start_link(HelloWorld, [])

# Monitor the process so the script exits when the app quits.
# Without this, `mix run` would exit immediately.
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
