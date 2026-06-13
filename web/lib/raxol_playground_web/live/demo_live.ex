defmodule RaxolPlaygroundWeb.DemoLive do
  @moduledoc """
  Individual component demo page with TEALive-hosted rendering.
  Each demo runs the real Catalog demo app through the Lifecycle bridge.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Playground.Catalog
  alias RaxolPlaygroundWeb.Playground.{DemoLifecycle, Helpers}

  import RaxolPlaygroundWeb.PlaygroundComponents

  @demo_timeout_ms :timer.minutes(30)

  # -- Mount --
  #
  # mount sets up state that survives across patch navigation between demos
  # (theme, code-panel visibility, presence). The actual demo lifecycle is
  # started in handle_params/3 so that prev/next via `<.link patch=...>`
  # swap demos in-place without remounting (and without reconnecting the
  # LiveSocket).

  @impl true
  def mount(%{"demo" => _name}, _session, socket) do
    socket =
      socket
      |> assign(:component, nil)
      |> assign(:prev_component, nil)
      |> assign(:next_component, nil)
      |> assign(:demo_position, nil)
      |> assign(:demo_total, nil)
      |> assign(:terminal_html, false)
      |> assign(:lifecycle_pid, nil)
      |> assign(:topic, nil)
      |> assign(:terminal_theme, :synthwave84)
      |> assign(:themes, Helpers.themes())
      |> assign(:show_code, false)
      |> assign(:demo_error, nil)
      |> assign(:demo_timer, nil)
      |> assign(:auto_focus, true)

    {:ok, socket}
  end

  def mount(_params, _session, socket) do
    components = Catalog.list_components()

    socket =
      socket
      |> assign(:component, nil)
      |> assign(:components, components)
      |> assign(:total_count, length(components))

    {:ok, socket}
  end

  # -- Handle Params (drives demo swap on initial mount AND patch navigation) --

  @impl true
  def handle_params(%{"demo" => name}, _uri, socket) do
    current = socket.assigns[:component]

    if current && current.name == name do
      {:noreply, socket}
    else
      component = Catalog.get_component(name)
      pos = catalog_position(name)

      socket =
        socket
        |> DemoLifecycle.stop_demo()
        |> assign(:component, component)
        |> assign(:prev_component, pos.prev)
        |> assign(:next_component, pos.next)
        |> assign(:demo_position, pos.position)
        |> assign(:demo_total, pos.total)
        |> assign(:demo_error, nil)
        |> DemoLifecycle.maybe_push_reset()
        |> DemoLifecycle.start_demo(component, timeout_ms: @demo_timeout_ms)

      {:noreply, DemoLifecycle.maybe_push_error(socket)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # -- Events --

  @impl true
  def handle_event("select_theme", %{"theme" => theme}, socket) do
    {:noreply, assign(socket, :terminal_theme, String.to_existing_atom(theme))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("toggle_code", _params, socket) do
    {:noreply, assign(socket, :show_code, !socket.assigns.show_code)}
  end

  def handle_event("keydown", params, socket) do
    if socket.assigns[:lifecycle_pid] do
      event = Raxol.LiveView.InputAdapter.translate_key_event(params)
      {:noreply, DemoLifecycle.dispatch_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("retry_demo", _params, socket) do
    comp = socket.assigns.component

    socket =
      socket
      |> DemoLifecycle.stop_demo()
      |> assign(:demo_error, nil)
      |> DemoLifecycle.maybe_push_reset()
      |> DemoLifecycle.start_demo(comp, timeout_ms: @demo_timeout_ms)

    {:noreply, DemoLifecycle.maybe_push_error(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # -- Info --

  @impl true
  def handle_info({:render_update, html}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  def handle_info({:render_update, html, _animation_css}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  def handle_info(:demo_timeout, socket),
    do: {:noreply, DemoLifecycle.demo_timeout(socket)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket),
    do: {:noreply, DemoLifecycle.lifecycle_down(socket, pid, reason)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _ = DemoLifecycle.stop_demo(socket)
    :ok
  end

  # -- Render: Index --

  @impl true
  def render(%{component: nil} = assigns) do
    ~H"""
    <.atmosphere />

    <div class="relative min-h-screen z-10">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="text-center mb-8">
          <h1 class="font-mono font-bold tracking-wide mb-4 text-pearl" style="font-size: clamp(1.5rem, 1.25rem + 1vw, 2.5rem);">
            <a href="/" class="brand-link">Raxol</a> Interactive Demos
          </h1>
          <p class="font-mono body-text">
            <%= @total_count %> widget demos. Click to try.
          </p>
        </div>

        <.ssh_callout variant={:banner} class="mb-8" />

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
          <%= for comp <- @components do %>
            <a href={"/demos/#{comp.name}"} class="panel panel--glow block p-4 transition-all duration-200">
              <div class="flex items-start justify-between mb-2">
                <h3 class="font-mono font-semibold name-sky"><%= comp.name %></h3>
                <.complexity_badge level={comp.complexity} />
              </div>
              <p class="font-mono mb-2 detail-text"><%= comp.description %></p>
              <span class="font-mono label-text"><%= Helpers.category_label(comp.category) %></span>
            </a>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # -- Render: Show --

  def render(assigns) do
    theme_bg = Helpers.theme_bg(assigns.terminal_theme)

    assigns = assign(assigns, :theme_bg, theme_bg)

    ~H"""
    <div class="h-screen flex flex-col bg-obsidian">
      <!-- Header -->
      <div class="px-8 py-5 surface-bar">
        <div class="flex items-center justify-between gap-8">
          <div class="flex items-center gap-6 min-w-0">
            <a href="/demos" class="font-mono text-sm subtle-link whitespace-nowrap" aria-label="Back to all demos">&larr; Back</a>
            <div class="min-w-0">
              <div class="flex items-center gap-3">
                <h1 class="font-mono font-semibold text-pearl truncate" style="font-size: clamp(1rem, 0.9rem + 0.5vw, 1.25rem);"><%= @component.name %></h1>
                <.complexity_badge level={@component.complexity} />
                <span :if={@demo_position && @demo_total} class="font-mono text-pearl-40 text-sm whitespace-nowrap" aria-label={"Demo #{@demo_position} of #{@demo_total}"}>
                  <%= @demo_position %> / <%= @demo_total %>
                </span>
              </div>
              <p class="font-mono detail-text truncate"><%= @component.description %></p>
            </div>
          </div>

          <div class="flex items-center gap-4 flex-wrap">
            <%!-- Prev/Next navigation. Patch-based so the LiveView stays
                 mounted and only the demo lifecycle swaps. --%>
            <nav class="flex items-center gap-2 font-mono text-sm" aria-label="Demo navigation">
              <.link
                :if={@prev_component}
                patch={"/demos/#{@prev_component}"}
                class="btn-secondary toggle-btn-sm"
                aria-label={"Previous demo: #{@prev_component}"}
              >
                &larr; <%= @prev_component %>
              </.link>
              <.link
                :if={@next_component}
                patch={"/demos/#{@next_component}"}
                class="btn-secondary toggle-btn-sm"
                aria-label={"Next demo: #{@next_component}"}
              >
                <%= @next_component %> &rarr;
              </.link>
            </nav>

            <.theme_selector
              theme={@terminal_theme}
              themes={@themes}
              form_id="theme-select"
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

      <!-- Terminal + Code -->
      <div class="flex-1 flex overflow-hidden">
        <div class="flex-1 flex flex-col">
          <.terminal_chrome title={"#{@component.name} Demo"} />
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
                <button phx-click="retry_demo" class="btn-primary">
                  Retry
                </button>
              </div>
            <% else %>
              <div
                id="demo-terminal"
                phx-hook="RaxolTerminal"
                phx-keydown="keydown"
                phx-update="ignore"
                class="h-full p-4 font-mono text-sm"
                tabindex="0"
                role="application"
                aria-roledescription="Interactive terminal"
                aria-label={"#{@component.name} demo"}
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
                  <.terminal_fallback description={@component.description} />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <.code_panel show={@show_code} code={@component.code_snippet} />
      </div>

      <.ssh_callout variant={:footer} />
    </div>
    """
  end

  # -- Helpers --

  defp catalog_position(name) do
    all = Catalog.list_components()
    names = Enum.map(all, & &1.name)
    idx = Enum.find_index(names, &(&1 == name))
    total = length(names)

    prev_name = if idx && idx > 0, do: Enum.at(names, idx - 1)
    next_name = if idx && idx < total - 1, do: Enum.at(names, idx + 1)
    position = if idx, do: idx + 1

    %{prev: prev_name, next: next_name, position: position, total: total}
  end
end
