defmodule RaxolPlaygroundWeb.PlaygroundLive do
  @moduledoc """
  Main playground LiveView. Sidebar with Catalog components, TEALive-hosted
  demo rendering, code snippets, theme selector, and multi-user presence.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Playground.Catalog
  alias RaxolPlaygroundWeb.Playground.{DemoLifecycle, Helpers}
  alias RaxolPlaygroundWeb.Presence, as: PlaygroundPresence

  import RaxolPlaygroundWeb.PlaygroundComponents

  @themes Helpers.themes()
  @demo_timeout_ms :timer.minutes(30)

  # =========================================================================
  # Mount
  # =========================================================================

  @impl true
  def mount(params, _session, socket) do
    components = Catalog.list_components()

    initial_name = params["component"]

    selected =
      (initial_name && Catalog.get_component(initial_name)) ||
        List.first(components)

    {socket, _user_id} = init_presence(socket, selected)

    socket =
      socket
      |> assign(:components, components)
      |> assign(:selected, selected)
      |> assign(:search_query, "")
      |> assign(:terminal_html, false)
      |> assign(:lifecycle_pid, nil)
      |> assign(:topic, nil)
      |> assign(:show_code, false)
      |> assign(:show_shortcuts, false)
      |> assign(:show_users_panel, false)
      |> assign(:sync_enabled, false)
      |> assign(:sidebar_collapsed, false)
      |> assign(:terminal_theme, :synthwave84)
      |> assign(:themes, @themes)
      |> assign(:demo_error, nil)
      |> assign(:demo_timer, nil)
      |> assign(:auto_focus, true)
      |> DemoLifecycle.start_demo(selected,
        timeout_ms: @demo_timeout_ms,
        topic_prefix: "playground"
      )

    {:ok, socket}
  end

  # =========================================================================
  # Event Handlers
  # =========================================================================

  @impl true
  def handle_event("select_component", %{"component" => name}, socket) do
    component = Catalog.get_component(name)

    if component do
      if socket.assigns.user_id do
        PlaygroundPresence.update_component(socket.assigns.user_id, name)
      end

      if socket.assigns.sync_enabled do
        PlaygroundPresence.broadcast_event_from(self(), :component_selected, %{
          component: name,
          user_id: socket.assigns.user_id
        })
      end

      {:noreply, switch_demo(socket, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("search_components", %{"query" => query}, socket) do
    search = if query == "", do: nil, else: query
    components = Catalog.filter(search: search)

    {:noreply, socket |> assign(:search_query, query) |> assign(:components, components)}
  end

  def handle_event("toggle_code", _params, socket) do
    {:noreply, assign(socket, :show_code, !socket.assigns.show_code)}
  end

  def handle_event("toggle_shortcuts", _params, socket) do
    {:noreply, assign(socket, :show_shortcuts, !socket.assigns.show_shortcuts)}
  end

  def handle_event("toggle_users_panel", _params, socket) do
    {:noreply, assign(socket, :show_users_panel, !socket.assigns.show_users_panel)}
  end

  def handle_event("toggle_sync", _params, socket) do
    {:noreply, assign(socket, :sync_enabled, !socket.assigns.sync_enabled)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("select_theme", %{"theme" => theme}, socket) do
    atom = String.to_existing_atom(theme)
    {:noreply, assign(socket, :terminal_theme, atom)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("retry_demo", _params, socket) do
    comp = socket.assigns.selected

    socket =
      socket
      |> DemoLifecycle.stop_demo()
      |> assign(:demo_error, nil)
      |> DemoLifecycle.maybe_push_reset()
      |> DemoLifecycle.start_demo(comp,
        timeout_ms: @demo_timeout_ms,
        topic_prefix: "playground"
      )

    {:noreply, DemoLifecycle.maybe_push_error(socket)}
  end

  def handle_event("keydown", params, socket) do
    if socket.assigns[:lifecycle_pid] do
      event = Raxol.LiveView.InputAdapter.translate_key_event(params)
      {:noreply, DemoLifecycle.dispatch_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("terminal_click", params, socket) do
    event = Raxol.LiveView.InputAdapter.translate_click_event(params)

    if event && socket.assigns[:lifecycle_pid] do
      {:noreply, DemoLifecycle.dispatch_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # =========================================================================
  # Handle Info
  # =========================================================================

  @impl true
  def handle_info({:render_update, html}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  def handle_info({:render_update, html, _animation_css}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, :online_users, PlaygroundPresence.list_users())}

  def handle_info(
        {:playground_event, :component_selected, %{component: name, user_id: from}},
        socket
      ) do
    if socket.assigns.sync_enabled and from != socket.assigns.user_id do
      case Catalog.get_component(name) do
        nil -> {:noreply, socket}
        comp -> {:noreply, switch_demo(socket, comp)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(:demo_timeout, socket),
    do: {:noreply, DemoLifecycle.demo_timeout(socket)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket),
    do: {:noreply, DemoLifecycle.lifecycle_down(socket, pid, reason)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    DemoLifecycle.stop_demo(socket)
    :ok
  end

  # =========================================================================
  # Render
  # =========================================================================

  @impl true
  def render(assigns) do
    theme_bg = Helpers.theme_bg(assigns.terminal_theme)
    assigns = assign(assigns, :theme_bg, theme_bg)

    ~H"""
    <div class="playground-container h-screen flex flex-col bg-obsidian">
      <%!-- Header --%>
      <div class="px-6 py-3 surface-bar">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <h1 class="name-coral">
              Raxol Playground
            </h1>
            <span class="hidden sm:flex items-center gap-2 font-mono text-pearl-35 tracking-wide" style="font-size: 0.65rem;">
              <a href="/" class="subtle-link">Home</a>
              <span>|</span>
              <a href="/gallery" class="subtle-link">Gallery</a>
              <span>|</span>
              <a href="/demos" class="subtle-link">Demos</a>
            </span>
          </div>

          <div class="flex items-center gap-3">
            <span class="hidden lg:block font-mono caption-text">
              <%= Helpers.ssh_command() %>
            </span>

            <button
              phx-click="toggle_users_panel"
              class={["flex items-center gap-2 toggle-btn", @show_users_panel && "toggle-btn--active"]}
            >
              <span><%= length(@online_users) %> online</span>
              <%= if length(@online_users) > 1 do %>
                <span class="w-2 h-2 rounded-full animate-pulse bg-sky"></span>
              <% end %>
            </button>

            <button
              phx-click="toggle_shortcuts"
              class="font-mono px-3 py-1.5 rounded border border-subtle text-pearl-40 transition-colors"
              style="font-size: 0.7rem;"
              aria-label="Keyboard shortcuts"
            >
              ?
            </button>
          </div>
        </div>
      </div>

      <%!-- Main Area --%>
      <div class="flex-1 flex overflow-hidden">
        <%!-- Sidebar --%>
        <div class="hidden md:block">
          <.sidebar {assigns} />
        </div>

        <%!-- Content --%>
        <div class="flex-1 flex flex-col min-w-0">
          <.toolbar {assigns} />

          <%!-- Demo + Code --%>
          <div class="flex-1 flex flex-col lg:flex-row overflow-hidden">
            <div class="flex-1 flex flex-col">
              <.terminal_chrome title={if @selected, do: @selected.name <> " Demo", else: "Terminal"} />
              <%!-- Outer themeable shell: morphdom owns its attributes so theme
                   changes can re-paint the background. Inner element is the
                   hook-controlled terminal whose innerHTML we mark as ignored
                   so demo frames survive across re-renders. --%>
              <div
                class="flex-1 overflow-auto"
                style={"background: #{@theme_bg};"}
                data-theme={@terminal_theme}
              >
                <%= if @demo_error do %>
                  <div class="p-4 py-8 text-center font-mono">
                    <p class="mb-4 text-coral-red"><%= @demo_error %></p>
                    <button phx-click="retry_demo" class="btn-primary">Retry</button>
                  </div>
                <% else %>
                  <div
                    id="playground-terminal"
                    phx-hook="RaxolTerminal"
                    phx-keydown="keydown"
                    phx-update="ignore"
                    class="h-full p-4 font-mono text-sm"
                    tabindex="0"
                    role="application"
                    aria-roledescription="Interactive terminal"
                    aria-label="Component demo"
                    aria-keyshortcuts="ArrowUp ArrowDown ArrowLeft ArrowRight Enter Space Tab"
                  >
                    <%!-- Initial state; hook overwrites on first terminal_html event.
                         Press '/' anywhere to refocus this terminal. --%>
                    <%= if @lifecycle_pid do %>
                      <div class="py-8 text-center font-mono text-pearl-40" role="status">
                        <div class="loading-spinner mb-3 mx-auto"></div>
                        <p>Starting demo... <span class="text-pearl-25">(press / to focus)</span></p>
                      </div>
                    <% else %>
                      <.terminal_fallback description={if @selected, do: @selected.description} />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <%= if @selected do %>
              <.code_panel show={@show_code} code={@selected.code_snippet} />
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Shortcuts Overlay --%>
      <%= if @show_shortcuts do %>
        <div phx-window-keydown="toggle_shortcuts" phx-key="Escape">
          <.shortcuts_overlay />
        </div>
      <% end %>

      <%!-- Users Panel --%>
      <%= if @show_users_panel do %>
        <div phx-window-keydown="toggle_users_panel" phx-key="Escape">
          <.users_panel online_users={@online_users} user_id={@user_id} sync_enabled={@sync_enabled} />
        </div>
      <% end %>
    </div>
    """
  end

  # =========================================================================
  # Render Components
  # =========================================================================

  defp sidebar(assigns) do
    ~H"""
    <aside class={[
      "overflow-y-auto transition-all duration-200 bg-panel-subtle border-r border-subtle-faint",
      @sidebar_collapsed && "w-28",
      not @sidebar_collapsed && "w-72"
    ]}>
      <div class="p-3">
        <div class="flex items-center justify-between mb-3">
          <%= if not @sidebar_collapsed do %>
            <h2 class="font-mono font-semibold text-pearl tracking-wide" style="font-size: 0.8rem;">Components</h2>
          <% end %>
          <button
            phx-click="toggle_sidebar"
            class="font-mono p-2 rounded transition-colors text-pearl-40"
            style="font-size: 0.75rem;"
            title={if @sidebar_collapsed, do: "Expand sidebar", else: "Collapse sidebar"}
            aria-label={if @sidebar_collapsed, do: "Expand sidebar", else: "Collapse sidebar"}
            aria-expanded={not @sidebar_collapsed}
          >
            <%= if @sidebar_collapsed, do: ">", else: "<" %>
          </button>
        </div>

        <%= if not @sidebar_collapsed do %>
          <form phx-change="search_components" id="sidebar-search" class="mb-3">
            <input
              type="text"
              name="query"
              placeholder="Search..."
              value={@search_query}
              phx-debounce="300"
              aria-label="Search components"
              class="w-full input-dark"
            />
          </form>

          <div class="space-y-0.5" role="listbox" aria-label="Components">
            <%= for comp <- @components do %>
              <button
                type="button"
                class={[
                  "w-full text-left p-2 rounded transition-colors font-mono border",
                  selected?(@selected, comp) && "sidebar-row--active",
                  not selected?(@selected, comp) && "border-transparent"
                ]}
                phx-click="select_component"
                phx-value-component={comp.name}
                role="option"
                aria-selected={selected?(@selected, comp)}
              >
                <div class={["font-medium", if(selected?(@selected, comp), do: "text-sky", else: "text-pearl")]} style="font-size: 0.8rem;"><%= comp.name %></div>
                <div class="text-pearl-35" style="font-size: 0.65rem; line-height: 1.4;"><%= comp.description %></div>
              </button>
            <% end %>
          </div>
        <% else %>
          <div class="space-y-0.5" role="listbox" aria-label="Components">
            <%= for comp <- @components do %>
              <button
                type="button"
                class={[
                  "w-full text-left px-2 py-1.5 rounded transition-colors font-mono border",
                  selected?(@selected, comp) && "sidebar-row--active",
                  not selected?(@selected, comp) && "border-transparent"
                ]}
                phx-click="select_component"
                phx-value-component={comp.name}
                title={"#{comp.name}: #{comp.description}"}
                role="option"
                aria-selected={selected?(@selected, comp)}
              >
                <div class="truncate text-pearl-60" style="font-size: 0.7rem;"><%= comp.name %></div>
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    </aside>
    """
  end

  defp selected?(nil, _comp), do: false
  defp selected?(selected, comp), do: selected.name == comp.name

  defp toolbar(assigns) do
    ~H"""
    <div class="px-4 py-2 surface-toolbar">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <%= if @selected do %>
            <span class="font-mono font-semibold text-pearl" style="font-size: 0.8rem;"><%= @selected.name %></span>
            <.complexity_badge level={@selected.complexity} />
            <span class="font-mono label-text-dim"><%= Helpers.category_label(@selected.category) %></span>
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <.theme_selector
            theme={@terminal_theme}
            themes={@themes}
            form_id="theme-selector"
          />

          <button
            phx-click="toggle_code"
            class={["toggle-btn", @show_code && "toggle-btn--active"]}
          >
            Code
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp shortcuts_overlay(assigns) do
    ~H"""
    <div
      class="fixed inset-0 flex items-center justify-center z-50 bg-obsidian-80 backdrop-blur-sm"
      phx-click="toggle_shortcuts"
    >
      <div class="panel panel--elevated p-6 w-full max-w-md">
        <h3 class="font-mono font-semibold mb-4 text-pearl tracking-wide" style="font-size: 0.9rem;">Keyboard Shortcuts</h3>
        <div class="space-y-2 font-mono" style="font-size: 0.75rem;">
          <div class="flex justify-between gap-8">
            <span class="text-pearl-60">Navigate components</span>
            <span class="text-gold">j / k</span>
          </div>
          <div class="flex justify-between gap-8">
            <span class="text-pearl-60">Select component</span>
            <span class="text-gold">Enter</span>
          </div>
          <div class="flex justify-between gap-8">
            <span class="text-pearl-60">Toggle code panel</span>
            <span class="text-gold">c</span>
          </div>
          <div class="flex justify-between gap-8">
            <span class="text-pearl-60">Search</span>
            <span class="text-gold">/</span>
          </div>
          <div class="flex justify-between gap-8">
            <span class="text-pearl-60">Toggle shortcuts</span>
            <span class="text-gold">?</span>
          </div>
        </div>
        <div class="mt-4 pt-4 font-mono border-t border-subtle caption-text">
          Click anywhere to close
        </div>
      </div>
    </div>
    """
  end

  attr(:online_users, :list, required: true)
  attr(:user_id, :any, required: true)
  attr(:sync_enabled, :boolean, required: true)

  defp users_panel(assigns) do
    ~H"""
    <div class="fixed right-4 top-16 w-72 panel panel--elevated z-50">
      <div class="p-4 flex justify-between items-center border-b border-subtle">
        <h3 class="font-mono font-semibold text-pearl" style="font-size: 0.8rem;">Online (<%= length(@online_users) %>)</h3>
        <button phx-click="toggle_users_panel" class="font-mono text-pearl-40 text-base">
          &times;
        </button>
      </div>

      <div class="p-3 border-b border-subtle-faint">
        <label class="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={@sync_enabled}
            phx-click="toggle_sync"
            class="rounded accent-sky"
          />
          <span class="font-mono text-pearl-60" style="font-size: 0.75rem;">Sync with others</span>
        </label>
        <p class="font-mono mt-1 caption-text">
          Selections sync across sessions when enabled
        </p>
      </div>

      <div class="max-h-64 overflow-y-auto">
        <%= if @online_users == [] do %>
          <div class="p-4 text-center font-mono text-pearl-35" style="font-size: 0.75rem;">No other users online</div>
        <% else %>
          <ul>
            <%= for user <- @online_users do %>
              <li class="p-3 flex items-center gap-3 user-row">
                <div
                  class="w-7 h-7 rounded-full flex items-center justify-center text-white font-mono font-semibold user-avatar"
                  style={"--user-color: #{user.color};"}
                >
                  <%= String.first(user.name) %>
                </div>
                <div class="flex-1 min-w-0">
                  <span class={["font-mono font-medium", if(user.user_id == @user_id, do: "text-sky", else: "text-pearl")]} style="font-size: 0.75rem;">
                    <%= user.name %>
                    <%= if user.user_id == @user_id, do: "(you)" %>
                  </span>
                  <%= if user.current_component do %>
                    <div class="font-mono truncate text-pearl-35" style="font-size: 0.6rem;">
                      Viewing: <%= user.current_component %>
                    </div>
                  <% end %>
                </div>
                <div class="w-2 h-2 rounded-full bg-sky"></div>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # =========================================================================
  # Private Helpers
  # =========================================================================

  defp init_presence(socket, selected) do
    if connected?(socket) do
      PlaygroundPresence.subscribe()
      track_and_assign(socket, selected)
    else
      {assign(socket, user_id: nil, online_users: []), nil}
    end
  end

  defp track_and_assign(socket, selected) do
    case PlaygroundPresence.track_user(socket) do
      {:ok, user_id, _user_meta} ->
        if selected,
          do: PlaygroundPresence.update_component(user_id, selected.name)

        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:online_users, PlaygroundPresence.list_users())

        {socket, user_id}

      {:error, _reason} ->
        {assign(socket, user_id: nil, online_users: []), nil}
    end
  end

  defp switch_demo(socket, comp) do
    socket
    |> DemoLifecycle.stop_demo()
    |> assign(:selected, comp)
    |> assign(:demo_error, nil)
    |> DemoLifecycle.maybe_push_reset()
    |> DemoLifecycle.start_demo(comp,
      timeout_ms: @demo_timeout_ms,
      topic_prefix: "playground"
    )
    |> DemoLifecycle.maybe_push_error()
  end
end
