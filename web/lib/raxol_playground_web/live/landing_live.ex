defmodule RaxolPlaygroundWeb.LandingLive do
  @moduledoc """
  Landing page for raxol.io. Mounts a single demo (Button) into a TEALive
  bridge and orchestrates the section layout. Auto-restarts the demo on
  timeout instead of showing a retry button (different policy than the
  playground/demo screens).

  All section markup lives in `RaxolPlaygroundWeb.LandingComponents`.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Playground.Catalog
  alias RaxolPlaygroundWeb.Playground.DemoLifecycle

  import RaxolPlaygroundWeb.LandingComponents
  import RaxolPlaygroundWeb.PlaygroundComponents, only: [atmosphere: 1]

  @demo_name "Button"

  @raxol_version (case :application.get_key(:raxol, :vsn) do
                    {:ok, vsn} ->
                      vsn |> to_string() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

                    _ ->
                      "2.4"
                  end)

  @impl true
  def mount(_params, _session, socket) do
    demo_component = Catalog.get_component(@demo_name)

    socket =
      socket
      |> assign(
        page_title: "Raxol",
        raxol_version: @raxol_version,
        mobile_menu_open: false,
        terminal_html: false,
        lifecycle_pid: nil,
        topic: nil,
        demo_error: nil,
        demo_timer: nil,
        demo_component: demo_component
      )
      |> start_landing_demo()

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  @impl true
  def handle_info({:render_update, html}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  def handle_info({:render_update, html, _animation_css}, socket),
    do: {:noreply, DemoLifecycle.render_update(socket, html)}

  # Landing's policy: auto-restart on timeout instead of show-retry.
  def handle_info(:demo_timeout, socket) do
    socket =
      socket
      |> DemoLifecycle.stop_demo()
      |> assign(terminal_html: false, demo_error: nil)
      |> start_landing_demo()

    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:lifecycle_pid] do
      {:noreply, assign(socket, lifecycle_pid: nil, demo_error: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    _ = DemoLifecycle.stop_demo(socket)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.atmosphere orbs={true} />

    <div class="relative min-h-screen z-10">
      <.nav_bar mobile_menu_open={@mobile_menu_open} />
      <main>
        <.hero_section raxol_version={@raxol_version} terminal_html={@terminal_html} />
        <hr class="section-divider" aria-hidden="true" />
        <.code_example_section />
        <hr class="section-divider" aria-hidden="true" />
        <.surfaces_deep_dive />
        <hr class="section-divider" aria-hidden="true" />
        <.ssh_deep_dive />
        <hr class="section-divider" aria-hidden="true" />
        <.agent_deep_dive />
        <hr class="section-divider" aria-hidden="true" />
        <.features_section />
        <hr class="section-divider" aria-hidden="true" />
        <.packages_section />
        <hr class="section-divider" aria-hidden="true" />
        <.faq_section />
        <hr class="section-divider" aria-hidden="true" />
        <.try_section />
      </main>
      <.footer_section />
    </div>
    """
  end

  defp start_landing_demo(socket) do
    case socket.assigns.demo_component do
      nil ->
        socket

      component ->
        DemoLifecycle.start_demo(socket, component,
          timeout_ms: :timer.minutes(5),
          topic_prefix: "landing"
        )
    end
  end
end
