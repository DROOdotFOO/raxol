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
      |> assign(:page_title, "Demo")
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
      |> assign(:demo_error, nil)
      |> assign(:demo_timer, nil)
      |> assign(:auto_focus, true)

    {:ok, socket}
  end

  # -- Handle Params (drives demo swap on initial mount AND patch navigation) --

  @impl true
  def handle_params(%{"demo" => name}, _uri, socket) do
    current = socket.assigns[:component]

    if current && current.name == name do
      {:noreply, socket}
    else
      # A name the catalog does not have is a wrong URL. Without this the nil
      # falls through to the `component: nil` render clause, which is the index
      # and reads assigns only the index mount sets -- a KeyError served as a
      # 500. Raise before `catalog_position/1`, so nothing downstream has to
      # carry a nil component.
      component =
        Catalog.get_component(name) ||
          raise RaxolPlaygroundWeb.NotFoundError,
                "no demo named #{inspect(name)}"

      pos = catalog_position(name)

      socket =
        socket
        |> DemoLifecycle.stop_demo()
        |> assign(:page_title, component.name)
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

  # j/k from the PlaygroundKeys hook: patch to the adjacent demo, same as
  # the prev/next header links. No wrap -- the ends are the ends, matching
  # the visible buttons.
  def handle_event("nav_component", %{"dir" => dir}, socket)
      when dir in ["next", "prev"] do
    target =
      case dir do
        "next" -> socket.assigns.next_component
        "prev" -> socket.assigns.prev_component
      end

    if target do
      {:noreply, push_patch(socket, to: "/demos/#{URI.encode(target)}")}
    else
      {:noreply, socket}
    end
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

  # -- Render --
  #
  # One clause. There used to be a second for `component: nil`, the index at
  # /demos: the same catalog as /gallery, rendered as cards with no preview, no
  # search and no filters, linking to exactly these pages. It was a strictly
  # smaller gallery, and a third label in the navigation for a job that already
  # had two. /gallery is the index now and /demos redirects to it.

  @impl true
  def render(assigns) do
    theme_bg = Helpers.theme_bg(assigns.terminal_theme)

    assigns = assign(assigns, :theme_bg, theme_bg)

    ~H"""
    <%!-- PlaygroundKeys: j/k patch to the adjacent demo, c toggles code,
         Esc leaves the focused terminal. data-keys omits '?' because
         this page has no shortcuts overlay. --%>
    <main
      id="main-content"
      tabindex="-1"
      phx-hook="PlaygroundKeys"
      data-terminal="demo-terminal"
      data-keys="jk"
      class="h-[100dvh] flex flex-col bg-obsidian"
    >
      <!-- Header -->
      <header class="px-8 py-5 surface-bar">
        <div class="flex items-center justify-between gap-8">
          <div class="flex items-center gap-6 min-w-0">
            <a href="/gallery" class="font-mono text-sm subtle-link whitespace-nowrap" aria-label="Back to all components">&larr; Back</a>
            <div class="min-w-0">
              <div class="flex items-baseline gap-2">
                <h1 class="font-mono font-semibold text-pearl truncate" style="font-size: clamp(1rem, 0.9rem + 0.5vw, 1.25rem);"><%= @component.name %></h1>
                <span class={["font-mono shrink-0", "pg-cx-#{@component.complexity}"]} style="font-size: 0.7rem;">[<%= @component.complexity %>]</span>
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
          </div>
        </div>
      </header>

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
                  <div class="py-8 text-center font-mono text-pearl-60" role="status">
                    <div class="loading-spinner mb-3 mx-auto"></div>
                    <p>Starting demo... <span class="text-pearl-60">(press / to focus)</span></p>
                  </div>
                <% else %>
                  <.terminal_fallback description={@component.description} />
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Always shown, below the demo. It used to be behind a toggle,
               and the gallery offered "try live" and "code" as two links into
               the same closed panel -- so neither label was true and the
               difference between them was nothing. Seeing it run and being
               able to lift the code are not two things a reader chooses
               between; they are what a component page is for. --%>
          <div class="pg-code">
            <div class="pg-code-head">
              <span>Code</span>
              <button
                id="demo-code-copy"
                phx-hook="CopyToClipboard"
                data-copy={String.trim(@component.code_snippet)}
                class="copy-chip"
                aria-label="Copy code snippet"
              >
                copy
              </button>
            </div>
            <pre class="pg-code-snippet"><%= String.trim(@component.code_snippet) %></pre>
          </div>
        </div>
      </div>

      <%!-- Status bar: same key-hint line as the playground; every key
           listed is wired. --%>
      <div class="pg-statusbar font-mono">
        <span class="pg-statusbar-chip">demo</span>
        <span class="pg-statusbar-keys">
          <span :for={{key, action} <- statusbar_keys()} class="pg-key">
            <b><%= key %></b> <%= action %>
          </span>
        </span>
        <span :if={@demo_position && @demo_total} class="pg-statusbar-count">
          <%= @demo_position %>/<%= @demo_total %> demos
        </span>
      </div>
    </main>
    """
  end

  # -- Helpers --

  # The status bar's key hints, as `{key, what it does}`. `c` is gone with the
  # panel it used to toggle: the code is always on this page now.
  defp statusbar_keys do
    [{"j/k", "prev/next"}, {"/", "focus demo"}, {"esc", "back"}]
  end

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
