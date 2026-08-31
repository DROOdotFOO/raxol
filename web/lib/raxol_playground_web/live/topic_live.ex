defmodule RaxolPlaygroundWeb.TopicLive do
  @moduledoc """
  One deep-dive topic per page.

  These sections used to be stacked on the landing page, which is what made
  raxol.io a scrolling document that restated the README. The landing is now a
  single screen and links here instead, so the detail survives without being
  the first thing anyone reads.

  The section markup is unchanged and still lives in `LandingComponents`: a
  topic page is a route and a heading around the same component, not a second
  copy of the content.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Payments.Xochi.Capabilities, as: XochiCapabilities

  import RaxolPlaygroundWeb.LandingComponents
  import RaxolPlaygroundWeb.PlaygroundComponents, only: [atmosphere: 1]

  # The router names each topic as a `live_action`, so the URL and the atom
  # this module matches on are declared in one place (the router) and cannot
  # drift apart. `{path, page title, nav label}`.
  @topics %{
    surfaces: {"/surfaces", "Surfaces", "Surfaces"},
    ssh: {"/ssh", "SSH", "SSH"},
    agent: {"/agent", "Agents", "Agents"},
    coding_agent: {"/coding-agent", "Coding agent", "Coding agent"},
    payments: {"/payments", "Agent payments", "Payments"},
    token: {"/token", "$RAXOL", "$RAXOL"}
  }

  @order [:surfaces, :ssh, :agent, :coding_agent, :payments, :token]

  @doc "Every topic as `{path, label}`, in nav order."
  def links do
    Enum.map(@order, fn topic ->
      {path, _title, label} = @topics[topic]
      {path, label}
    end)
  end

  @impl true
  def mount(_params, _session, socket) do
    {_path, title, _label} = Map.fetch!(@topics, socket.assigns.live_action)

    {:ok,
     assign(socket,
       # The layout already appends " · Raxol", so naming the brand here put it
       # in the tab twice.
       page_title: title,
       title: title,
       mobile_menu_open: false,
       xochi_matrix: xochi_matrix(socket.assigns.live_action)
     )}
  end

  # Only the payments topic renders the matrix, and resolving it is a BLOCKING
  # outbound request on a cache miss. Resolving it for every topic to keep
  # mount total put four unrelated pages behind a third-party endpoint's
  # availability; the branch is cheaper than that coupling.
  defp xochi_matrix(:payments) do
    XochiCapabilities.get(
      Application.get_env(:raxol_playground, :xochi_capabilities)
    )
  end

  defp xochi_matrix(_topic), do: nil

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, update(socket, :mobile_menu_open, &(!&1))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.atmosphere />
    <div class="relative z-10">
      <.nav_bar mobile_menu_open={@mobile_menu_open} />
      <main id="main-content" tabindex="-1">
        <nav class="topic-crumb measure pt-8" aria-label="Breadcrumb">
          <a href="/" class="subtle-link">raxol</a>
          <span aria-hidden="true">/</span>
          <span aria-current="page"><%= @title %></span>
        </nav>

        <.topic_body topic={@live_action} matrix={@xochi_matrix} />

        <div class="measure pb-16">
          <a href="/" class="subtle-link">&larr; back</a>
        </div>
      </main>
      <.footer_section />
    </div>
    """
  end

  # One clause per topic rather than a dynamic component call: the mapping from
  # a URL to the function that renders it stays greppable.
  defp topic_body(%{topic: :surfaces} = assigns),
    do: ~H"<.surfaces_deep_dive />"

  defp topic_body(%{topic: :ssh} = assigns), do: ~H"<.ssh_deep_dive />"
  defp topic_body(%{topic: :agent} = assigns), do: ~H"<.agent_deep_dive />"

  defp topic_body(%{topic: :coding_agent} = assigns),
    do: ~H"<.coding_agent_deep_dive />"

  defp topic_body(%{topic: :payments} = assigns),
    do: ~H"<.payments_deep_dive matrix={@matrix} />"

  defp topic_body(%{topic: :token} = assigns), do: ~H"<.token_deep_dive />"
end
