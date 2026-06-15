# Clock
#
# A real-time clock demonstrating time-based subscriptions.
#
# What you'll learn:
#   - subscribe/1 returns subscriptions that the runtime manages for you
#   - subscribe_interval(ms, atom) sends that atom to update/2 every ms
#   - No manual Process.send_after needed -- the runtime handles timers
#
# Usage:
#   mix run examples/scripts/clock.exs
#
# Controls:
#   q       = quit
#   Ctrl+C  = quit

defmodule ClockExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{time: DateTime.utc_now()}
  end

  @impl true
  def update(message, model) do
    case message do
      # :tick arrives every 1000ms from subscribe/1. Timer messages
      # are just atoms -- they go through update/2 like keyboard events.
      :tick ->
        {%{model | time: DateTime.utc_now()}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

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
    time_str = Calendar.strftime(model.time, "%H:%M:%S")
    date_str = Calendar.strftime(model.time, "%Y-%m-%d")

    column style: %{padding: 2, gap: 1, align_items: :center} do
      [
        box title: "Clock",
            style: %{
              border: :single,
              padding: 1,
              width: 30,
              justify_content: :center
            } do
          column style: %{gap: 1, align_items: :center} do
            [
              text(time_str, style: [:bold]),
              text(date_str)
            ]
          end
        end,
        text("Press 'q' to quit.")
      ]
    end
  end

  # subscribe_interval(1000, :tick) tells the runtime to send the atom
  # :tick to update/2 every 1000ms. The timer is managed by the runtime --
  # it starts automatically and stops when the app exits.
  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end
end

Raxol.Core.Runtime.Log.info("ClockExample: Starting...")
{:ok, pid} = Raxol.start_link(ClockExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
