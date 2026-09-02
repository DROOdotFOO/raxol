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
    {:noreply,
     refilter(
       assign(socket, :active_category, String.to_existing_atom(category))
     )}
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
    {:noreply,
     refilter(
       assign(socket, :complexity_filter, String.to_existing_atom(level))
     )}
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

    <main id="main-content" tabindex="-1" class="relative min-h-[100dvh] z-10">
      <%!-- One line, like every other bar on the site. It used to stack a
           display-size h1 over a subtitle and let the toolbar wrap under both,
           which measured 107px against the landing's 58 -- over the 80px a
           desktop bar gets, and visible as the brand mark jumping two rows when
           a reader crossed from `/`.

           The title is "Components", which is what the navigation calls this
           page. It read "Raxol Component Gallery" while the link that reaches
           it said "Components", so the label a reader clicked and the heading
           they landed on were different words for the same place. --%>
      <header class="surface-bar">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-3">
          <div class="flex items-center justify-between flex-wrap gap-4">
            <div class="flex items-baseline gap-2 font-mono">
              <a href="/" class="brand-link">raxol</a>
              <span class="text-pearl-60" aria-hidden="true">/</span>
              <h1 class="heading-xl">Components</h1>
              <span class="detail-text"><%= @total_count %></span>
            </div>

            <%!-- Wraps, and the search field shrinks with it. Fixed at
                 `w-48` the group measured 406px inside a 390px phone and
                 pushed the page sideways. --%>
            <div class="flex flex-wrap items-center justify-end gap-3 min-w-0">
              <a href="/playground" class="nav-link">Playground</a>

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
                  class="w-40 sm:w-48 md:w-64 min-w-0 font-mono px-4 py-2 rounded input-dark"
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
    assigns =
      assign(assigns, :preview, RecordedFrames.preview(assigns.component.name))

    ~H"""
    <div class="panel panel--glow transition-all duration-200 overflow-hidden flex flex-col">
      <%!-- Real rendered frames of the demo (committed under
           priv/demo_previews/), not a screenshot or a GIF. An animated
           demo's card plays its recording back at the demo's own tick via
           the CardLoop hook; a static demo is one frame and no hook. The
           link is a pointer shortcut duplicating "try live" below, so it
           stays out of the tab order and the accessibility tree. --%>
      <a
        :if={@preview}
        id={"preview-#{RecordedFrames.slug(@component.name)}"}
        href={"/demos/#{@component.name}"}
        class="gallery-preview bg-synthwave-bg"
        data-theme="synthwave84"
        aria-hidden="true"
        tabindex="-1"
        phx-hook={if length(@preview.frames) > 1, do: "CardLoop"}
        data-frame-ms={@preview.interval_ms}
      ><%= if length(@preview.frames) > 1 do %><span
          :for={{frame, i} <- Enum.with_index(@preview.frames)}
          class="block"
          data-frame={i}
          hidden={i != 0}
        ><%= raw(frame) %></span><% else %><%= raw(hd(@preview.frames)) %><% end %></a>
      <div class="p-3 flex flex-col flex-1">
        <div class="flex items-baseline justify-between gap-2 mb-1">
          <h2 class="font-mono font-semibold name-sky text-sm truncate"><%= @component.name %></h2>
          <span class="gallery-badge"><%= Helpers.complexity_label(@component.complexity) %></span>
        </div>
        <%!-- What the snippet demonstrates, where the card name is
             plain-language rather than a module. Derived from the snippet
             (Catalog's :shows), and absent when it would only repeat the
             name, so ten cards answer "which module is this?" and the
             other thirty-one stay quiet. --%>
        <p :if={@component.shows} class="font-mono label-text mb-1"><%= @component.shows %></p>
        <p class="font-mono detail-text gallery-desc mb-2"><%= @component.description %></p>
        <%!-- Tags and links on separate rows. They shared one line, with the
             tags clipped by `overflow-hidden` to whatever the links left over
             -- which was fine only while the tags were 8.8px. Above the
             legibility floor they no longer fit, and cards rendered "PROGRES"
             and "SELEC" cut mid-word butted against "TRY LIVE".

             Trimming to two tags did not fix it either: a dozen cards still
             clipped at desktop, because "visualization" and "keyboard" are
             just wide words. Wrapping is the answer that holds for any tag
             set, at the cost of about 18px per card. --%>
        <div class="mt-auto">
          <div class="flex flex-wrap gap-1 mb-2">
            <%= for tag <- Enum.take(@component.tags, 3) do %>
              <span class="category-tag category-tag--sm"><%= tag %></span>
            <% end %>
          </div>
          <div class="flex gap-2.5 justify-end">
            <%!-- One link. "try live" and "code" were two labels for the same
                 destination, and splitting them implied a choice that should
                 not exist: seeing a component run and being able to lift its
                 code are both what the page is for, so it shows both and this
                 says so once. --%>
            <a href={"/demos/#{@component.name}"} class="gallery-link">open &rarr;</a>
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
            <h2 class="font-mono font-semibold name-sky"><%= @component.name %></h2>
            <.complexity_badge level={@component.complexity} />
          </div>
          <p :if={@component.shows} class="font-mono label-text mb-2"><%= @component.shows %></p>
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
