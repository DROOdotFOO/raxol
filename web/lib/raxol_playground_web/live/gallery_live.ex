defmodule RaxolPlaygroundWeb.GalleryLive do
  @moduledoc """
  Component gallery backed by the shared Raxol.Playground.Catalog.
  Displays all widgets with filtering by category and complexity.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Playground.Catalog
  alias RaxolPlayground.RecordedFrames
  alias RaxolPlaygroundWeb.Playground.Helpers

  import Phoenix.HTML, only: [raw: 1]
  import RaxolPlaygroundWeb.PlaygroundComponents

  @impl true
  def mount(_params, _session, socket) do
    components = Catalog.list_components()

    socket =
      socket
      |> assign(:page_title, "Gallery")
      |> assign(:components, components)
      |> assign(:total_count, length(components))
      |> assign(:categories, Catalog.list_categories())
      |> assign(:active_category, nil)
      |> assign(:search_query, "")
      |> assign(:view_mode, "grid")
      |> assign(:complexity_filter, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter_category", %{"category" => "all"}, socket) do
    {:noreply, refilter(assign(socket, :active_category, nil))}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, refilter(assign(socket, :active_category, String.to_existing_atom(category)))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, refilter(assign(socket, :search_query, query))}
  end

  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("filter_complexity", %{"level" => "all"}, socket) do
    {:noreply, refilter(assign(socket, :complexity_filter, nil))}
  end

  def handle_event("filter_complexity", %{"level" => level}, socket) do
    {:noreply, refilter(assign(socket, :complexity_filter, String.to_existing_atom(level)))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  defp refilter(socket) do
    a = socket.assigns
    search = if a.search_query == "", do: nil, else: a.search_query

    components =
      Catalog.filter(
        category: a.active_category,
        complexity: a.complexity_filter,
        search: search
      )

    assign(socket, :components, components)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.atmosphere />

    <main id="main-content" tabindex="-1" class="relative min-h-screen z-10">
      <%!-- Header --%>
      <header class="surface-bar">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div class="flex items-center justify-between flex-wrap gap-4">
            <div>
              <h1 class="font-mono font-bold tracking-wide heading-xl">
                <a href="/" class="brand-link">Raxol</a> Component Gallery
              </h1>
              <p class="font-mono mt-1 detail-text">
                <%= @total_count %> interactive terminal UI components --
                <a href="/playground" class="text-sky">open playground</a>
              </p>
            </div>

            <div class="flex items-center gap-3">
              <div class="view-toggle">
                <button
                  phx-click="toggle_view"
                  phx-value-mode="grid"
                  class={["view-toggle-btn", @view_mode == "grid" && "view-toggle-btn--active"]}
                >
                  Grid
                </button>
                <button
                  phx-click="toggle_view"
                  phx-value-mode="list"
                  class={["view-toggle-btn", @view_mode == "list" && "view-toggle-btn--active"]}
                >
                  List
                </button>
              </div>

              <form phx-change="search" id="gallery-search">
                <input
                  type="text"
                  name="query"
                  placeholder="Search components..."
                  value={@search_query}
                  phx-debounce="300"
                  aria-label="Search components"
                  class="w-48 md:w-64 font-mono px-4 py-2 rounded input-dark"
                />
              </form>
            </div>
          </div>
        </div>
      </header>

      <%!-- Filters --%>
      <div class="surface-bar-subtle">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-3">
          <div class="flex items-center gap-6 flex-wrap">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-mono label-text-dim">Category:</span>
              <div class="flex flex-wrap gap-1.5">
                <button
                  phx-click="filter_category"
                  phx-value-category="all"
                  class={["category-tag cursor-pointer transition-colors", @active_category == nil && "toggle-btn--active"]}
                >
                  All
                </button>
                <%= for cat <- @categories do %>
                  <button
                    phx-click="filter_category"
                    phx-value-category={cat}
                    class={["category-tag cursor-pointer transition-colors", @active_category == cat && "toggle-btn--active"]}
                  >
                    <%= Helpers.category_label(cat) %>
                  </button>
                <% end %>
              </div>
            </div>

            <form phx-change="filter_complexity" id="complexity-filter">
              <div class="flex items-center gap-2">
                <span class="font-mono label-text-dim">Complexity:</span>
                <select
                  name="level"
                  class="font-mono px-3 py-1 rounded input-dark"
                >
                  <option value="all" selected={@complexity_filter == nil}>All Levels</option>
                  <option value="basic" selected={@complexity_filter == :basic}>Basic</option>
                  <option value="intermediate" selected={@complexity_filter == :intermediate}>Intermediate</option>
                  <option value="advanced" selected={@complexity_filter == :advanced}>Advanced</option>
                </select>
              </div>
            </form>
          </div>
        </div>
      </div>

      <%!-- SSH Callout --%>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 pt-6">
        <.ssh_callout variant={:banner} />
      </div>

      <%!-- Component Grid/List --%>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <%= if @view_mode == "grid" do %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
            <%= for comp <- @components do %>
              <.component_card component={comp} />
            <% end %>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for comp <- @components do %>
              <.component_list_item component={comp} />
            <% end %>
          </div>
        <% end %>

        <%= if @components == [] do %>
          <div class="text-center py-12 font-mono text-pearl-60">
            No components match your filters.
          </div>
        <% end %>
      </div>
    </main>
    """
  end

  defp component_card(assigns) do
    assigns = assign(assigns, :preview, RecordedFrames.preview(assigns.component.name))

    ~H"""
    <div class="panel panel--glow transition-all duration-200 overflow-hidden flex flex-col">
      <%!-- A real rendered frame of the demo (committed under
           priv/demo_previews/), not a screenshot or a GIF. The link is a
           pointer shortcut duplicating "try live" below, so it stays out
           of the tab order and the accessibility tree. --%>
      <a
        :if={@preview}
        href={"/demos/#{@component.name}"}
        class="gallery-preview bg-synthwave-bg"
        data-theme="synthwave84"
        aria-hidden="true"
        tabindex="-1"
      ><%= raw(@preview) %></a>
      <div class="p-3 flex flex-col flex-1">
        <div class="flex items-baseline justify-between gap-2 mb-1">
          <h3 class="font-mono font-semibold name-sky text-sm truncate"><%= @component.name %></h3>
          <span class="gallery-badge"><%= Helpers.complexity_label(@component.complexity) %></span>
        </div>
        <p class="font-mono detail-text gallery-desc mb-2"><%= @component.description %></p>
        <div class="flex items-center justify-between gap-2 mt-auto">
          <div class="flex gap-1 overflow-hidden">
            <%= for tag <- Enum.take(@component.tags, 3) do %>
              <span class="category-tag category-tag--sm"><%= tag %></span>
            <% end %>
          </div>
          <div class="flex gap-2.5 shrink-0">
            <a href={"/demos/#{@component.name}"} class="gallery-link">try live</a>
            <a href={"/playground?component=#{@component.name}&code=1"} class="gallery-link gallery-link--dim">code</a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp component_list_item(assigns) do
    ~H"""
    <div class="panel panel--glow p-5 transition-all duration-200">
      <div class="flex items-start gap-6">
        <div class="flex-1 min-w-0">
          <div class="flex items-start justify-between mb-2">
            <h3 class="font-mono font-semibold name-sky"><%= @component.name %></h3>
            <.complexity_badge level={@component.complexity} />
          </div>
          <p class="font-mono mb-3 detail-text"><%= @component.description %></p>
          <div class="flex items-center gap-4 font-mono mb-3 label-text">
            <span><%= Helpers.category_label(@component.category) %></span>
          </div>
          <div class="flex flex-wrap gap-1 mb-4">
            <%= for tag <- @component.tags do %>
              <span class="category-tag category-tag--sm"><%= tag %></span>
            <% end %>
          </div>
          <div class="flex gap-3">
            <a href={"/demos/#{@component.name}"} class="btn-sky btn-compact">
              Try Live
            </a>
            <a href={"/playground?component=#{@component.name}&code=1"} class="btn-secondary btn-compact">
              View Code
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
