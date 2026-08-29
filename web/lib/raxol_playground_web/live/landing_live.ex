defmodule RaxolPlaygroundWeb.LandingLive do
  @moduledoc """
  Landing page for raxol.io. The hero autoplays recorded frames (no server
  work, no socket traffic) until the visitor clicks "take over live", which
  starts the live BEAM dashboard demo through a TEALive bridge. Timeout
  reverts to the recorded frames rather than showing a retry button
  (different policy than the playground/demo screens).

  All section markup lives in `RaxolPlaygroundWeb.LandingComponents`.
  """

  use RaxolPlaygroundWeb, :live_view

  alias Raxol.Playground.Catalog
  alias RaxolPlaygroundWeb.Playground.DemoLifecycle

  import RaxolPlaygroundWeb.LandingComponents
  import RaxolPlaygroundWeb.PlaygroundComponents, only: [atmosphere: 1]

  @demo_name "BEAM Dashboard"

  @impl true
  def mount(_params, _session, socket) do
    demo_component = Catalog.get_component(@demo_name)

    socket =
      socket
      |> assign(
        page_title: "Raxol",
        mobile_menu_open: false,
        terminal_html: false,
        lifecycle_pid: nil,
        topic: nil,
        demo_error: nil,
        demo_timer: nil,
        demo_paused: false,
        pause_source: nil,
        demo_component: demo_component
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  # The MotionPref hook reports prefers-reduced-motion at connect and on
  # every preference change. Server-pushed frames ARE motion, so a reduce
  # preference pauses the demo (after one frame has painted, so the hero
  # shows a static frame rather than nothing). A user who pressed play or
  # pause keeps their choice; only motion-sourced pauses auto-resume.
  def handle_event("motion_pref", %{"reduce" => true}, socket) do
    if socket.assigns.demo_paused do
      {:noreply, socket}
    else
      socket = assign(socket, demo_paused: true, pause_source: :motion)
      {:noreply, maybe_pause_after_frame(socket)}
    end
  end

  def handle_event("motion_pref", %{"reduce" => false}, socket) do
    if socket.assigns.demo_paused and socket.assigns.pause_source == :motion do
      {:noreply, resume_demo(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_demo_motion", _params, socket) do
    if socket.assigns.demo_paused do
      {:noreply, resume_demo(socket)}
    else
      socket = assign(socket, demo_paused: true, pause_source: :user)
      {:noreply, maybe_pause_after_frame(socket)}
    end
  end

  # "take over live": swap the hero's recorded frames for a live demo
  # session. The demo starts here, not at mount, so a visitor who never
  # interacts costs no server work and no socket frames.
  def handle_event("take_over", _params, socket) do
    if socket.assigns[:lifecycle_pid] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(demo_paused: false, pause_source: nil)
       |> start_landing_demo()}
    end
  end

  # "back to the tour": stop the live session and return to the recorded
  # frames (the HeroDemo hook restarts the player when data-live drops).
  def handle_event("end_take_over", _params, socket) do
    {:noreply,
     socket
     |> DemoLifecycle.stop_demo()
     |> assign(terminal_html: false, demo_error: nil, demo_paused: false, pause_source: nil)}
  end

  # Forward terminal key and click events from the RaxolTerminal hook into
  # the demo, so the embedded demo is interactive (same path as DemoLive).
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

  @impl true
  def handle_info({:render_update, html}, socket),
    do: {:noreply, socket |> DemoLifecycle.render_update(html) |> maybe_pause_after_frame()}

  def handle_info({:render_update, html, _animation_css}, socket),
    do: {:noreply, socket |> DemoLifecycle.render_update(html) |> maybe_pause_after_frame()}

  # Landing's policy: a timed-out live session reverts to the recorded
  # frames (terminal_html: false re-renders the frame player, and the
  # HeroDemo hook restarts it). No retry button, no auto-restart loop.
  def handle_info(:demo_timeout, socket) do
    socket =
      socket
      |> DemoLifecycle.stop_demo()
      |> assign(terminal_html: false, demo_error: nil, demo_paused: false, pause_source: nil)

    {:noreply, socket}
  end

  # A crashed live session also reverts to the recorded frames.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns[:lifecycle_pid] do
      {:noreply,
       assign(socket,
         lifecycle_pid: nil,
         dispatcher_pid: nil,
         terminal_html: false,
         demo_error: nil,
         demo_paused: false,
         pause_source: nil
       )}
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
      <main id="main-content" tabindex="-1">
        <.hero_section terminal_html={@terminal_html} demo_paused={@demo_paused} />
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

  # Pausing stops the Lifecycle (no more server-pushed frames, no idle
  # server work) but keeps `terminal_html` true, so the hook's last
  # injected frame stays on screen as the static hero. Deferred until a
  # frame exists so a pre-first-frame pause never blanks the hero.
  defp maybe_pause_after_frame(socket) do
    if socket.assigns.demo_paused and socket.assigns[:lifecycle_pid] do
      DemoLifecycle.stop_demo(socket)
    else
      socket
    end
  end

  defp resume_demo(socket) do
    socket = assign(socket, demo_paused: false, pause_source: nil)

    if socket.assigns[:lifecycle_pid] do
      socket
    else
      start_landing_demo(socket)
    end
  end
end
