defmodule RaxolPlaygroundWeb.LandingLive do
  @moduledoc """
  Landing page for raxol.io: one screen, no scrolling.

  The hero plays recorded frames of a real `Raxol.Headless` session and lets
  the visitor switch between examples. There is no live session here any more.
  A "take over live" button used to start a supervised demo in this page's
  BEAM, which cost a `DemoLifecycle`, a timeout timer, keydown and click
  forwarding, crash handling and a reduced-motion pause path -- and what the
  visitor got for it was a second demo running. The recorded frames make the
  same point at none of that cost.

  The deep dives this page used to stack live at `RaxolPlaygroundWeb.TopicLive`;
  the demos live at `/gallery`.
  """

  use RaxolPlaygroundWeb, :live_view

  # The PAYMENTS solver's capability matrix -- deliberately aliased apart
  # from RaxolPlayground.Capabilities (raxol.io's own agent surface, served
  # at this app's /api/capabilities). Two different endpoints, same name.
  alias Raxol.Payments.Xochi.Capabilities, as: XochiCapabilities

  import RaxolPlaygroundWeb.LandingComponents
  import RaxolPlaygroundWeb.PlaygroundComponents, only: [atmosphere: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Raxol",
       mobile_menu_open: false,
       example: List.first(hero_example_names()),
       # ETS-cached with a 300s TTL; nil config (dev/test, or prod without
       # XOCHI_CAPABILITIES_BASE_URL) skips the network entirely and serves
       # the static fallback, which renders as a "cached" badge.
       xochi_matrix:
         XochiCapabilities.get(Application.get_env(:raxol_playground, :xochi_capabilities))
     )}
  end

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, update(socket, :mobile_menu_open, &(!&1))}
  end

  def handle_event("next_example", _params, socket) do
    names = hero_example_names()
    idx = Enum.find_index(names, &(&1 == socket.assigns.example)) || 0
    {:noreply, assign(socket, :example, Enum.at(names, rem(idx + 1, length(names))))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.atmosphere />

    <%!-- One screen, deliberately. The page used to stack eleven sections
         that restated the README; the detail now lives on its own pages
         (TopicLive) and in the gallery, and this is a claim, a way to run
         it, and the thing running. --%>
    <div class="screen">
      <.screen_header mobile_menu_open={@mobile_menu_open} />

      <main id="main-content" tabindex="-1" class="screen-main">
        <.screen_hero example={@example} />
        <.screen_integrations />
      </main>

      <.screen_footer />
    </div>
    """
  end
end
