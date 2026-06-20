defmodule RaxolExamples.SimpleTerminalLive do
  @moduledoc """
  Simple terminal LiveView example.

  Shows basic terminal rendering with periodic updates.

  ## Usage

  Add to your router:

      live "/terminal", RaxolExamples.SimpleTerminalLive

  """

  use Phoenix.LiveView
  alias Raxol.Core.{Buffer, Box}
  alias Raxol.LiveView.TerminalComponent

  @impl true
  def mount(_params, _session, socket) do
    # Create initial buffer
    buffer = create_initial_buffer()

    # Schedule periodic updates
    if connected?(socket) do
      Process.send_after(self(), :tick, 1000)
    end

    {:ok,
     assign(socket,
       buffer: buffer,
       counter: 0,
       cursor_pos: {2, 10}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen bg-gray-900">
      <div class="max-w-4xl w-full p-4">
        <div class="mb-4 text-white">
          <h1 class="text-2xl font-bold">Raxol Terminal - Simple Example</h1>
          <p class="text-gray-400">A minimal Phoenix LiveView terminal component</p>
        </div>

        <.live_component
          module={TerminalComponent}
          id="simple-terminal"
          buffer={@buffer}
          theme={:nord}
          cursor_position={@cursor_pos}
          show_cursor={true}
          cursor_style={:block}
          on_keypress={fn event -> send(self(), {:keypress, event}) end}
          on_click={fn event -> send(self(), {:click, event}) end}
        />

        <div class="mt-4 text-white text-sm">
          <p>Counter: <%= @counter %></p>
          <p class="text-gray-400">
            Terminal updates automatically every second.
            Click on the terminal or press keys to interact.
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(:tick, socket) do
    # Update counter
    counter = socket.assigns.counter + 1

    # Update buffer with new counter value
    buffer = update_buffer(socket.assigns.buffer, counter)

    # Schedule next tick
    Process.send_after(self(), :tick, 1000)

    {:noreply, assign(socket, buffer: buffer, counter: counter)}
  end

  @impl true
  def handle_info({:keypress, event}, socket) do
    # Log keyboard events (for demonstration)
    require Logger
    Logger.info("Key pressed: #{inspect(event)}")

    # You could update the buffer based on key presses here
    # For now, just acknowledge the event
    {:noreply, socket}
  end

  @impl true
  def handle_info({:click, event}, socket) do
    # Log click events (for demonstration)
    require Logger
    Logger.info("Terminal clicked at: #{inspect(event)}")

    # Update cursor position to click location
    {:noreply, assign(socket, cursor_pos: {event.x, event.y})}
  end

  # Private functions

  defp create_initial_buffer do
    Buffer.create_blank_buffer(80, 24)
    |> Box.draw_box(0, 0, 80, 24, :double)
    |> Buffer.write_at(2, 1, "Raxol Terminal - Phoenix LiveView Integration", %{
      bold: true
    })
    |> Box.draw_horizontal_line(1, 2, 78, "=")
    |> Buffer.write_at(2, 4, "Welcome to Raxol v2.0!", %{fg_color: :green})
    |> Buffer.write_at(
      2,
      6,
      "This is a minimal LiveView terminal component example.",
      %{}
    )
    |> Buffer.write_at(2, 8, "Features:", %{bold: true})
    |> Buffer.write_at(4, 9, "- Pure functional buffer rendering", %{})
    |> Buffer.write_at(4, 10, "- 60fps performance (< 16ms per frame)", %{})
    |> Buffer.write_at(4, 11, "- Multiple color themes", %{})
    |> Buffer.write_at(4, 12, "- Keyboard and mouse events", %{})
    |> Buffer.write_at(4, 13, "- Zero dependencies", %{})
    |> Buffer.write_at(2, 15, "Counter: 0", %{fg_color: :cyan})
    |> Box.draw_box(2, 17, 76, 5, :single)
    |> Buffer.write_at(4, 18, "Status: Running", %{fg_color: :green})
    |> Buffer.write_at(4, 19, "Theme: Nord", %{})
    |> Buffer.write_at(4, 20, "FPS: 60", %{})
  end

  defp update_buffer(buffer, counter) do
    # Clear the counter line and update it
    buffer
    |> Box.fill_area(2, 15, 20, 1, " ", %{})
    |> Buffer.write_at(2, 15, "Counter: #{counter}", %{fg_color: :cyan})
    |> Buffer.write_at(4, 20, "FPS: 60", %{fg_color: :green})
  end
end
