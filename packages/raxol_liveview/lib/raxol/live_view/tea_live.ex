if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Raxol.LiveView.TEALive do
    @moduledoc """
    A Phoenix LiveView that hosts a TEA (The Elm Architecture) application.

    This allows any Raxol TEA app to run in a browser with the same `init/1`,
    `update/2`, and `view/1` callbacks that work in the terminal.

    ## Usage

    In your Phoenix router:

        live "/counter", Raxol.LiveView.TEALive,
          session: %{"app_module" => "Elixir.CounterExample"}

    Or create a dedicated LiveView:

        defmodule MyAppWeb.CounterLive do
          use Phoenix.LiveView

          def mount(params, session, socket) do
            Raxol.LiveView.TEALive.mount(params, session, socket,
              app_module: CounterExample
            )
          end

          # Delegate remaining callbacks...
        end
    """

    use Phoenix.LiveView

    @compile {:no_warn_undefined,
              [
                Raxol.Core.Runtime.Lifecycle,
                Raxol.Core.Accessibility,
                Phoenix.PubSub
              ]}

    require Logger

    alias Raxol.Core.Runtime.Lifecycle
    alias Raxol.LiveView.InputAdapter
    alias Raxol.LiveView.TerminalBridge

    @impl true
    def mount(params, session, socket) do
      mount(params, session, socket, [])
    end

    def mount(_params, session, socket, opts) do
      app_module =
        Keyword.get(opts, :app_module) ||
          session
          |> Map.get("app_module", "")
          |> String.to_existing_atom()

      topic = "tea_live:#{inspect(self())}"

      if connected?(socket) do
        _ = Phoenix.PubSub.subscribe(Raxol.PubSub, topic)

        announce_ref = subscribe_announcements()

        {:ok, lifecycle_pid} =
          Lifecycle.start_link(app_module,
            environment: :liveview,
            liveview_topic: topic,
            width: 80,
            height: 24,
            name: :"tea_live_lifecycle_#{inspect(self())}"
          )

        socket =
          socket
          |> assign(:lifecycle_pid, lifecycle_pid)
          |> assign(:topic, topic)
          |> assign(:app_module, app_module)
          |> assign(:rows, [])
          |> assign(:container_attrs, TerminalBridge.container_attrs(:log))
          |> assign(:announce_ref, announce_ref)
          |> assign(:announcement, nil)

        {:ok, socket}
      else
        socket =
          socket
          |> assign(:lifecycle_pid, nil)
          |> assign(:topic, topic)
          |> assign(:app_module, app_module)
          |> assign(:rows, [])
          |> assign(:container_attrs, TerminalBridge.container_attrs(:log))
          |> assign(:announce_ref, nil)
          |> assign(:announcement, nil)

        {:ok, socket}
      end
    end

    @impl true
    def handle_event("keydown", params, socket) do
      event = InputAdapter.translate_key_event(params)
      dispatch_to_app(socket.assigns.lifecycle_pid, event)
      {:noreply, socket}
    end

    @impl true
    def handle_event(_event, _params, socket), do: {:noreply, socket}

    @impl true
    def handle_info({:render_update, html, animation_css}, socket) do
      socket =
        socket
        |> put_screen(html)
        |> assign(:animation_css, animation_css)

      {:noreply, socket}
    end

    @impl true
    def handle_info({:render_update, html}, socket) do
      {:noreply, put_screen(socket, html)}
    end

    @impl true
    def handle_info({:announcement_added, _ref, announcement}, socket) do
      {:noreply, assign(socket, :announcement, normalize_announcement(announcement))}
    end

    @impl true
    def handle_info(_msg, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <%= if assigns[:animation_css] && assigns[:animation_css] != "" do %>
        <%= Phoenix.HTML.raw(assigns[:animation_css]) %>
      <% end %>
      <div
        class="raxol-sr-only"
        role="status"
        aria-live={announcement_live(assigns[:announcement])}
        aria-atomic="true"
      ><%= announcement_text(assigns[:announcement]) %></div>
      <div
        id="raxol-terminal"
        phx-hook="RaxolTerminal"
        phx-window-keydown="keydown"
        class="raxol-terminal-container"
        style="font-family: monospace; background: #1a1a2e; color: #e0e0e0; padding: 1rem;"
        tabindex="0"
      ><pre id="raxol-terminal-screen" class="raxol-terminal raxol-terminal-rows" {@container_attrs}><div :for={row <- @rows} id={row.id} class="raxol-row"><%= Phoenix.HTML.raw(row.html) %></div></pre></div>
      """
    end

    # Each row is its own dynamic in the comprehension above, so LiveView's
    # keyed-comprehension diff puts only the rows whose markup differs from the
    # previous frame on the wire. Assigning the screen as one string instead
    # made every frame resend the whole screen: measured 2.8 KB per frame at
    # 62x13 and 7.0 KB at 60x34, against 0.3 KB for a one-row change either way.
    #
    # The <pre> lives here rather than inside the assigned markup because the
    # rows have to be its direct children. Its container semantics come from
    # TerminalBridge so they cannot drift from the ones buffer_to_html/2 emits
    # for the same :aria_mode -- a second nested live region re-reads the whole
    # screen on every change.
    defp put_screen(socket, html) do
      assign(socket, :rows, TerminalBridge.html_to_rows(html))
    end

    # The screen-reader announcement region is always present so assistive
    # technology tracks changes to it. It reflects accessibility announcements
    # delivered via Raxol.Core.Accessibility.subscribe_to_announcements/1:
    # polite by default, assertive for :high-priority announcements.
    defp announcement_live(%{priority: :high}), do: "assertive"
    defp announcement_live(_announcement), do: "polite"

    defp announcement_text(%{message: message}) when is_binary(message),
      do: message

    defp announcement_text(_announcement), do: ""

    defp normalize_announcement(announcement) when is_map(announcement) do
      %{
        message: to_string(Map.get(announcement, :message, "")),
        priority: Map.get(announcement, :priority, :normal)
      }
    end

    defp normalize_announcement(_announcement), do: nil

    defp subscribe_announcements do
      ref = make_ref()
      Raxol.Core.Accessibility.subscribe_to_announcements(ref)
      ref
    rescue
      error ->
        Logger.debug("TEALive announcement subscription failed: #{Exception.message(error)}")

        nil
    end

    @impl true
    def terminate(_reason, socket) do
      if ref = socket.assigns[:announce_ref] do
        _ = unsubscribe_announcements(ref)
      end

      if socket.assigns[:lifecycle_pid] do
        Lifecycle.stop(socket.assigns.lifecycle_pid)
      end

      :ok
    end

    defp unsubscribe_announcements(ref) do
      Raxol.Core.Accessibility.unsubscribe_from_announcements(ref)
    rescue
      _error -> :ok
    end

    defp dispatch_to_app(nil, _event), do: :ok

    defp dispatch_to_app(lifecycle_pid, event) do
      case GenServer.call(lifecycle_pid, :get_full_state) do
        %{dispatcher_pid: pid} when is_pid(pid) ->
          GenServer.cast(pid, {:dispatch, event})

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.debug("TEALive dispatch failed: #{Exception.message(e)}")
        :ok
    end
  end
end
