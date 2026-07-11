if Code.ensure_loaded?(Phoenix.LiveComponent) do
  defmodule Raxol.LiveView.TerminalComponent do
    @moduledoc """
    Phoenix LiveComponent for embedding a Raxol terminal in a LiveView page.

    Renders a terminal buffer as styled HTML using `TerminalBridge`, with
    keyboard event capture and theming support.

    ## Usage in a LiveView template

        <.live_component
          module={Raxol.LiveView.TerminalComponent}
          id="my-terminal"
          buffer={@buffer}
          theme={:synthwave84}
        />

    ## Assigns

    - `:buffer` (required) -- terminal buffer (map or `Raxol.Core.Buffer.t()`)
    - `:theme` -- theme atom (default: `:default`)
    - `:width` -- columns (default: 80)
    - `:height` -- rows (default: 24)
    - `:show_cursor` -- display cursor (default: true)
    - `:cursor_x` -- cursor column (default: 0)
    - `:cursor_y` -- cursor row (default: 0)
    """

    use Phoenix.LiveComponent

    alias Raxol.LiveView.{TerminalBridge, Themes}

    @impl true
    def mount(socket) do
      {:ok,
       assign(socket,
         theme: :default,
         width: 80,
         height: 24,
         show_cursor: true,
         cursor_x: 0,
         cursor_y: 0
       )}
    end

    @impl true
    def update(assigns, socket) do
      {:ok, assign(socket, assigns)}
    end

    @impl true
    def render(assigns) do
      html = render_buffer(assigns)
      css_vars = Themes.to_css_vars(assigns.theme)

      assigns =
        assigns
        |> Map.put(:inner_html, html)
        |> Map.put(:css_vars, css_vars)

      ~H"""
      <div
        id={@id}
        class="raxol-terminal-wrapper"
        style={@css_vars}
        tabindex="0"
        role="log"
        aria-live="polite"
        aria-label={"Terminal " <> to_string(@id)}
        phx-target={@myself}
        phx-window-keydown="keydown"
      >
        <%= Phoenix.HTML.raw(@inner_html) %>
      </div>
      """
    end

    @impl true
    def handle_event("keydown", params, socket) do
      send(self(), {:terminal_keydown, socket.assigns.id, params})
      {:noreply, socket}
    end

    defp render_buffer(assigns) do
      # The wrapper <div> below is the single coarse live region (role="log",
      # aria-live). Render the inner buffer in :application mode so its <pre>
      # is not a second, nested log region announcing the same content.
      TerminalBridge.buffer_to_html(
        assigns.buffer,
        theme: assigns.theme,
        show_cursor: assigns.show_cursor,
        cursor_position: {assigns.cursor_x, assigns.cursor_y},
        aria_mode: :application
      )
    end
  end
end
