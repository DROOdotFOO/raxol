defmodule RaxolPlaygroundWeb.LandingLive do
  @moduledoc """
  Landing page for raxol.io. Five-section narrative:
  hook (SSH + live demo) -> proof (code) -> features -> packages -> CTA.
  """

  use RaxolPlaygroundWeb, :live_view

  require Logger

  alias Raxol.Playground.Catalog
  alias RaxolPlaygroundWeb.Playground.{DemoLifecycle, Helpers}

  import RaxolPlaygroundWeb.PlaygroundComponents

  @demo_name "Button"

  @raxol_version (case :application.get_key(:raxol, :vsn) do
                    {:ok, vsn} ->
                      vsn |> to_string() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

                    _ ->
                      "2.4"
                  end)

  @counter_code_html String.trim_leading(~S"""
                     <span style="color:#ffcd9c">defmodule</span> <span style="color:#58a1c6">Counter</span> <span style="color:#ffcd9c">do</span>
                       <span style="color:#ffcd9c">use</span> <span style="color:#58a1c6">Raxol.Core.Runtime.Application</span>

                       <span style="color:#a89a80">@impl true</span>
                       <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">init</span>(<span style="color:#e8e4dc">_ctx</span>), <span style="color:#e58476">do:</span> <span style="color:#e8e4dc">%{</span><span style="color:#e58476">count:</span> <span style="color:#e8e4dc">0}</span>

                       <span style="color:#a89a80">@impl true</span>
                       <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">update</span>(<span style="color:#e58476">:increment</span>, <span style="color:#e8e4dc">model</span>), <span style="color:#e58476">do:</span> <span style="color:#e8e4dc">{%{model |</span> <span style="color:#e58476">count:</span> <span style="color:#e8e4dc">model.count + 1}, []}</span>
                       <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">update</span>(<span style="color:#e58476">:decrement</span>, <span style="color:#e8e4dc">model</span>), <span style="color:#e58476">do:</span> <span style="color:#e8e4dc">{%{model |</span> <span style="color:#e58476">count:</span> <span style="color:#e8e4dc">model.count - 1}, []}</span>
                       <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">update</span>(<span style="color:#e8e4dc">_</span>, <span style="color:#e8e4dc">model</span>), <span style="color:#e58476">do:</span> <span style="color:#e8e4dc">{model, []}</span>

                       <span style="color:#a89a80">@impl true</span>
                       <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">view</span>(<span style="color:#e8e4dc">model</span>) <span style="color:#ffcd9c">do</span>
                         <span style="color:#58a1c6">column</span> <span style="color:#e58476">style:</span> <span style="color:#e8e4dc">%{</span><span style="color:#e58476">padding:</span> <span style="color:#e8e4dc">1,</span> <span style="color:#e58476">gap:</span> <span style="color:#e8e4dc">1}</span> <span style="color:#ffcd9c">do</span>
                           <span style="color:#e8e4dc">[</span>
                             <span style="color:#58a1c6">text</span>(<span style="color:#a89a80">"Count: &#35;{model.count}"</span>, <span style="color:#e58476">style:</span> <span style="color:#e8e4dc">[</span><span style="color:#e58476">:bold</span><span style="color:#e8e4dc">]</span>),
                             <span style="color:#58a1c6">row</span> <span style="color:#e58476">style:</span> <span style="color:#e8e4dc">%{</span><span style="color:#e58476">gap:</span> <span style="color:#e8e4dc">1}</span> <span style="color:#ffcd9c">do</span>
                               <span style="color:#e8e4dc">[</span><span style="color:#58a1c6">button</span>(<span style="color:#a89a80">"+"</span>, <span style="color:#e58476">on_click:</span> <span style="color:#e58476">:increment</span>), <span style="color:#58a1c6">button</span>(<span style="color:#a89a80">"-"</span>, <span style="color:#e58476">on_click:</span> <span style="color:#e58476">:decrement</span>)<span style="color:#e8e4dc">]</span>
                             <span style="color:#ffcd9c">end</span>
                           <span style="color:#e8e4dc">]</span>
                         <span style="color:#ffcd9c">end</span>
                       <span style="color:#ffcd9c">end</span>
                     <span style="color:#ffcd9c">end</span>
                     """)

  @agent_code_html String.trim_leading(~S"""
                   <span style="color:#ffcd9c">defmodule</span> <span style="color:#58a1c6">Researcher</span> <span style="color:#ffcd9c">do</span>
                     <span style="color:#ffcd9c">use</span> <span style="color:#58a1c6">Raxol.Agent</span>

                     <span style="color:#a89a80">@impl true</span>
                     <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">init</span>(<span style="color:#e8e4dc">_ctx</span>), <span style="color:#e58476">do:</span> <span style="color:#e8e4dc">%{</span><span style="color:#e58476">notes:</span> <span style="color:#e8e4dc">[]}</span>

                     <span style="color:#a89a80">@impl true</span>
                     <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">update</span>(<span style="color:#e8e4dc">{</span><span style="color:#e58476">:agent_message</span><span style="color:#e8e4dc">, _from, query}, model</span>) <span style="color:#ffcd9c">do</span>
                       <span style="color:#e8e4dc">{model, [{</span><span style="color:#e58476">:async</span><span style="color:#e8e4dc">, &amp;llm(query, &amp;1)}]}</span>
                     <span style="color:#ffcd9c">end</span>

                     <span style="color:#ffcd9c">def</span> <span style="color:#58a1c6">update</span>(<span style="color:#e8e4dc">{</span><span style="color:#e58476">:llm_chunk</span><span style="color:#e8e4dc">, text}, model</span>), <span style="color:#e58476">do:</span>
                       <span style="color:#e8e4dc">{%{model |</span> <span style="color:#e58476">notes:</span> <span style="color:#e8e4dc">[text | model.notes]}, []}</span>
                   <span style="color:#ffcd9c">end</span>
                   """)

  @impl true
  def mount(_params, _session, socket) do
    demo_component = Catalog.get_component(@demo_name)

    socket =
      socket
      |> assign(
        page_title: "Raxol",
        counter_code: @counter_code_html,
        agent_code: @agent_code_html,
        raxol_version: @raxol_version,
        mobile_menu_open: false,
        terminal_html: false,
        lifecycle_pid: nil,
        topic: nil,
        demo_error: nil,
        demo_timer: nil,
        demo_component: demo_component
      )
      |> then(fn s ->
        if demo_component do
          DemoLifecycle.start_demo(s, demo_component,
            timeout_ms: :timer.minutes(5),
            topic_prefix: "landing"
          )
        else
          s
        end
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_mobile_menu", _params, socket) do
    {:noreply, assign(socket, :mobile_menu_open, !socket.assigns.mobile_menu_open)}
  end

  @impl true
  def handle_info({:render_update, html}, socket) do
    {:noreply,
     socket
     |> assign(:terminal_html, true)
     |> push_event("terminal_html", %{html: html})}
  end

  def handle_info({:render_update, html, _animation_css}, socket) do
    {:noreply,
     socket
     |> assign(:terminal_html, true)
     |> push_event("terminal_html", %{html: html})}
  end

  def handle_info(:demo_timeout, socket) do
    socket = DemoLifecycle.stop_demo(socket)
    demo_component = socket.assigns.demo_component

    socket =
      socket
      |> assign(terminal_html: false, demo_error: nil)
      |> then(fn s ->
        if demo_component do
          DemoLifecycle.start_demo(s, demo_component,
            timeout_ms: :timer.minutes(5),
            topic_prefix: "landing"
          )
        else
          s
        end
      end)

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

  # ===========================================================================
  # Render -- 5 sections: hook, code, features, packages, CTA
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="atmosphere" aria-hidden="true">
      <div class="pearl-bg"></div>
      <div class="dark-overlay"></div>
      <div class="orb orb-1"></div>
      <div class="orb orb-2"></div>
      <div class="orb orb-3"></div>
    </div>

    <div class="relative min-h-screen" style="z-index: 2;">
      <.nav_bar mobile_menu_open={@mobile_menu_open} />
      <main>
        <.hero_section raxol_version={@raxol_version} terminal_html={@terminal_html} />
        <hr class="section-divider" aria-hidden="true" />
        <.code_example_section counter_code={@counter_code} />
        <hr class="section-divider" aria-hidden="true" />
        <.surfaces_deep_dive />
        <hr class="section-divider" aria-hidden="true" />
        <.ssh_deep_dive />
        <hr class="section-divider" aria-hidden="true" />
        <.agent_deep_dive agent_code={@agent_code} />
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

  # ===========================================================================
  # Navigation
  # ===========================================================================

  attr(:mobile_menu_open, :boolean, required: true)

  defp nav_bar(assigns) do
    ~H"""
    <nav class="sticky top-0 z-50 surface-bar" aria-label="Main navigation">
      <div class="max-w-5xl mx-auto px-6 py-3 flex items-center justify-between">
        <a href="/" class="font-mono text-lg font-bold text-axol-coral" style="letter-spacing: 0.05em;">
          raxol
        </a>
        <div class="hidden md:flex items-center gap-6 text-sm font-mono" style="letter-spacing: 0.05em;">
          <a href="/playground" class="nav-link">Playground</a>
          <a href="/gallery" class="nav-link">Gallery</a>
          <a href="https://hexdocs.pm/raxol" class="nav-link">Docs</a>
          <a href="/skill.md" class="nav-link">Skill</a>
          <a href="https://github.com/DROOdotFOO/raxol" class="nav-link">GitHub</a>
        </div>
        <button phx-click="toggle_mobile_menu" class="md:hidden p-1 text-pearl-50" aria-label="Toggle menu">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
            <%= if @mobile_menu_open do %>
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            <% else %>
              <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            <% end %>
          </svg>
        </button>
      </div>
      <%= if @mobile_menu_open do %>
        <div class="md:hidden px-6 py-4 flex flex-col gap-4 text-sm font-mono border-t border-subtle text-pearl-50">
          <a href="/playground">Playground</a>
          <a href="/gallery">Gallery</a>
          <a href="https://hexdocs.pm/raxol">Docs</a>
          <a href="/skill.md">Skill</a>
          <a href="https://github.com/DROOdotFOO/raxol">GitHub</a>
        </div>
      <% end %>
    </nav>
    """
  end

  # ===========================================================================
  # 1. Hook: SSH + live demo + CTAs
  # ===========================================================================

  attr(:raxol_version, :string, required: true)
  attr(:terminal_html, :boolean, required: true)

  defp hero_section(assigns) do
    ~H"""
    <section class="landing-section px-6 pt-28 pb-20 md:pt-36 md:pb-24 max-w-4xl mx-auto text-center" aria-labelledby="hero-title">
      <h1 id="hero-title" class="font-mono font-bold tracking-tight text-axol-coral mb-6" style="font-size: clamp(3.5rem, 2.5rem + 5vw, 7rem); line-height: 1;">
        raxol
      </h1>

      <p class="font-mono tracking-normal text-pearl-80 mb-4" style="font-size: clamp(1.05rem, 0.95rem + 0.5vw, 1.35rem); line-height: 1.4;">
        One app. Terminal, browser, SSH, or agent.
      </p>

      <p class="body-text-dim mb-10 max-w-2xl mx-auto">
        Write a TEA module in Elixir. It renders everywhere -- crash isolation,
        hot reload, AI agents, and distributed swarm from OTP.
      </p>

      <%!-- Live terminal embed (HTML injected by RaxolTerminal hook) --%>
      <%= if @terminal_html do %>
        <div class="terminal-chrome mb-10 mx-auto text-left" style="max-width: 42rem;">
          <div class="terminal-chrome-bar">
            <div class="terminal-chrome-dot terminal-chrome-dot--red" aria-hidden="true"></div>
            <div class="terminal-chrome-dot terminal-chrome-dot--yellow" aria-hidden="true"></div>
            <div class="terminal-chrome-dot terminal-chrome-dot--green" aria-hidden="true"></div>
            <span class="terminal-chrome-title">raxol</span>
          </div>
          <div
            id="landing-terminal"
            phx-hook="RaxolTerminal"
            class="raxol-terminal p-4"
            style="background: #241b2f;"
            data-theme="synthwave84"
            data-no-scroll="true"
            tabindex="-1"
            role="img"
            aria-label="Raxol demo"
          ></div>
        </div>
      <% end %>

      <div class="mb-10">
        <div class="ssh-hero" id="ssh-copy" phx-hook="CopyToClipboard" data-copy={Helpers.ssh_command()}>
          <span class="prompt">$ </span><%= Helpers.ssh_command() %><span class="cursor-blink text-axol-coral">_</span>
        </div>
        <p class="label-text mt-3">Zero install. Click to copy.</p>
      </div>

      <div class="flex items-center justify-center gap-4 flex-wrap">
        <a href="/playground" class="btn-primary">Open Playground</a>
        <a href="/skill.md" class="btn-sky">Agent Skill</a>
        <a href="https://github.com/DROOdotFOO/raxol" class="btn-secondary">GitHub</a>
      </div>

      <div class="mt-10 mb-12">
        <code class="font-mono detail-text text-pearl-40 bg-inset border border-subtle" style="padding: 0.5rem 1rem; border-radius: 4px;"><%= raw("{:raxol, \"~> #{@raxol_version}\"}") %></code>
      </div>

      <div class="stat-grid max-w-2xl mx-auto" role="list" aria-label="Project stats">
        <div class="stat-cell" role="listitem">
          <span class="stat-value">4</span>
          <span class="stat-label">surfaces</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value">14</span>
          <span class="stat-label">packages</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value">0</span>
          <span class="stat-label">install</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value">OTP</span>
          <span class="stat-label">native</span>
        </div>
      </div>
    </section>
    """
  end

  # ===========================================================================
  # 2. Proof: code example
  # ===========================================================================

  attr(:counter_code, :string, required: true)

  defp code_example_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-20 max-w-4xl mx-auto" aria-labelledby="code-title">
      <h2 id="code-title" class="heading-2xl mb-3">Hello World</h2>
      <p class="body-text mb-8">
        Every Raxol app follows The Elm Architecture:
        <span class="text-axol-coral">init</span>,
        <span class="text-axol-coral">update</span>,
        <span class="text-axol-coral">view</span>.
      </p>

      <div class="terminal-chrome mb-8">
        <div class="terminal-chrome-bar">
          <div class="terminal-chrome-dot terminal-chrome-dot--red"></div>
          <div class="terminal-chrome-dot terminal-chrome-dot--yellow"></div>
          <div class="terminal-chrome-dot terminal-chrome-dot--green"></div>
          <span class="terminal-chrome-title">counter.exs</span>
        </div>
        <div class="terminal-chrome-body">
          <pre style="overflow-x: auto; font-size: 0.85rem; line-height: 1.7;"><code><%= Phoenix.HTML.raw(@counter_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim">
        That counter works in a terminal, Phoenix LiveView, and over SSH. One codebase.
      </p>
    </section>
    """
  end

  # ===========================================================================
  # 3a. Deep dive 01: Surfaces
  # ===========================================================================

  defp surfaces_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-24 max-w-5xl mx-auto" aria-labelledby="surfaces-title">
      <div class="mb-10">
        <span class="section-numeral" aria-hidden="true">01</span>
        <span class="section-eyebrow">Surfaces</span>
        <h2 id="surfaces-title" class="heading-2xl mb-3">One module, four surfaces.</h2>
        <p class="body-text max-w-2xl">
          Write the TEA module once. Render to the terminal, embed in
          Phoenix LiveView, serve over SSH, expose to AI agents over MCP.
          Same model. Same view. Same updates.
        </p>
      </div>

      <div class="surface-grid">
        <div class="surface-chip">
          <span class="surface-chip__name">Terminal</span>
          <span class="surface-chip__cmd">termbox2 NIF</span>
        </div>
        <div class="surface-chip">
          <span class="surface-chip__name">Browser</span>
          <span class="surface-chip__cmd">Phoenix LiveView</span>
        </div>
        <div class="surface-chip">
          <span class="surface-chip__name">SSH</span>
          <span class="surface-chip__cmd">Erlang :ssh daemon</span>
        </div>
        <div class="surface-chip">
          <span class="surface-chip__name">MCP</span>
          <span class="surface-chip__cmd">JSON-RPC over stdio</span>
        </div>
      </div>
    </section>
    """
  end

  # ===========================================================================
  # 3b. Deep dive 02: SSH zero-install
  # ===========================================================================

  defp ssh_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-24 max-w-5xl mx-auto" aria-labelledby="ssh-deep-title">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-12 items-center">
        <div>
          <span class="section-numeral" aria-hidden="true">02</span>
          <span class="section-eyebrow">Zero install</span>
          <h2 id="ssh-deep-title" class="heading-2xl mb-3">Try it without installing anything.</h2>
          <p class="body-text mb-6">
            Every Raxol app is one SSH connection away. Each session is a
            supervised BEAM process -- crash-isolated, hot-reloadable, observable.
          </p>
          <ul class="detail-text space-y-2" style="line-height: 1.7;">
            <li>-- Auto-generated host keys, no setup</li>
            <li>-- Supervised channel per connection</li>
            <li>-- Survives client disconnects</li>
            <li>-- One line to enable in your app</li>
          </ul>
        </div>
        <div class="text-center">
          <div class="ssh-hero" id="ssh-copy-deep" phx-hook="CopyToClipboard" data-copy={Helpers.ssh_command()}>
            <span class="prompt">$ </span><%= Helpers.ssh_command() %><span class="cursor-blink text-axol-coral">_</span>
          </div>
          <p class="label-text mt-3">Click to copy</p>
        </div>
      </div>
    </section>
    """
  end

  # ===========================================================================
  # 3c. Deep dive 03: Agent runtime
  # ===========================================================================

  attr(:agent_code, :string, required: true)

  defp agent_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-24 max-w-4xl mx-auto" aria-labelledby="agent-deep-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">03</span>
        <span class="section-eyebrow">Agent runtime</span>
        <h2 id="agent-deep-title" class="heading-2xl mb-3">Agents are TEA apps.</h2>
        <p class="body-text max-w-2xl">
          Same <span class="text-axol-coral">init</span> /
          <span class="text-axol-coral">update</span> /
          <span class="text-axol-coral">view</span> shape as a UI. The view is
          optional -- headless agents skip rendering. Supervision, messaging,
          hot reload, and swarm discovery come free from OTP.
        </p>
      </div>

      <div class="terminal-chrome mb-6">
        <div class="terminal-chrome-bar">
          <div class="terminal-chrome-dot terminal-chrome-dot--red"></div>
          <div class="terminal-chrome-dot terminal-chrome-dot--yellow"></div>
          <div class="terminal-chrome-dot terminal-chrome-dot--green"></div>
          <span class="terminal-chrome-title">researcher.exs</span>
        </div>
        <div class="terminal-chrome-body">
          <pre style="overflow-x: auto; font-size: 0.85rem; line-height: 1.7;"><code><%= Phoenix.HTML.raw(@agent_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim">
        Streaming LLM output via <code class="text-axol-coral">:async</code> commands.
        Inter-agent messages routed through a unique <code class="text-axol-coral">Registry</code>.
        Bring your own key for Anthropic, OpenAI, Ollama, Lumo, or Kimi -- or run mock.
      </p>
    </section>
    """
  end

  # ===========================================================================
  # 4. Features grid (numbered)
  # ===========================================================================

  defp features_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-24 max-w-5xl mx-auto" aria-labelledby="features-title">
      <span class="section-eyebrow">More capabilities</span>
      <h2 id="features-title" class="heading-2xl mb-10">What OTP gives you.</h2>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.feature_card index="01" title="Crash Isolation" description="Components crash and restart independently. Your UI keeps running." />
        <.feature_card index="02" title="Hot Code Reload" description="Change view/1, save. The running app updates without restart." />
        <.feature_card index="03" title="MCP Tools" description="Widgets auto-derive MCP tools. Agents interact with real UI programmatically." />
        <.feature_card index="04" title="Time-Travel Debug" description="Snapshot every update/2 cycle. Step back, forward, jump, restore." />
        <.feature_card index="05" title="Distributed Swarm" description="CRDTs, elections, discovery via gossip, DNS, or Tailscale." />
        <.feature_card index="06" title="Agent Payments" description="x402 micropayments, Xochi cross-chain, stealth addresses. Autonomous commerce." />
        <.feature_card index="07" title="Adaptive UI" description="Behavior tracking, layout recommendations, feedback loop. Self-evolving interfaces." />
        <.feature_card index="08" title="Session Replay" description="Asciinema v2 recording. Replay any session, scrub the timeline, ship as evidence." />
      </div>
    </section>
    """
  end

  attr(:index, :string, required: true)
  attr(:title, :string, required: true)
  attr(:description, :string, required: true)

  defp feature_card(assigns) do
    ~H"""
    <div class="panel panel--glow feature-card p-6">
      <span class="feature-card__index"><%= @index %></span>
      <h3 class="name-coral mb-2"><%= @title %></h3>
      <p class="detail-text" style="line-height: 1.7;"><%= @description %></p>
    </div>
    """
  end

  # ===========================================================================
  # 4. Packages
  # ===========================================================================

  defp packages_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-20 max-w-5xl mx-auto" aria-labelledby="packages-title">
      <h2 id="packages-title" class="heading-2xl mb-3">Pick what you need</h2>
      <p class="body-text mb-10">Full framework or just the parts that matter.</p>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <.package_card id="raxol" name="raxol" dep={~s({:raxol, "~> 2.4"})} description="Full framework: TEA runtime, rendering, widgets, effects" accent={true} />
        <.package_card id="agent" name="raxol_agent" dep={~s({:raxol_agent, "~> 2.4"})} description="AI agents, teams, strategies, LLM streaming" />
        <.package_card id="mcp" name="raxol_mcp" dep={~s({:raxol_mcp, "~> 2.4"})} description="MCP server, tool derivation from widgets" />
        <.package_card id="payments" name="raxol_payments" dep={~s({:raxol_payments, "~> 0.1"})} description="x402, MPP, Xochi cross-chain, spending controls" />
        <.package_card id="liveview" name="raxol_liveview" dep={~s({:raxol_liveview, "~> 2.4"})} description="Render TEA apps in Phoenix LiveView" />
        <.package_card id="sensor" name="raxol_sensor" dep={~s({:raxol_sensor, "~> 2.4"})} description="Sensor fusion. Zero dependencies." />
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:name, :string, required: true)
  attr(:dep, :string, required: true)
  attr(:description, :string, required: true)
  attr(:accent, :boolean, default: false)

  defp package_card(assigns) do
    ~H"""
    <div class="panel panel--glow p-5 relative">
      <h3 class={"name-sky-sm mb-1 #{if @accent, do: "text-axol-coral", else: "text-sky"}"}>
        <%= @name %>
      </h3>
      <code class="caption-text"><%= @dep %></code>
      <p class="detail-text mt-2"><%= @description %></p>
      <button
        id={"pkg-copy-#{@id}"}
        phx-hook="CopyToClipboard"
        data-copy={@dep}
        class="pkg-copy-btn"
        aria-label={"Copy #{@name} dependency"}
      >copy</button>
    </div>
    """
  end

  # ===========================================================================
  # 5a. FAQ
  # ===========================================================================

  @faqs [
    %{
      q: "What is Raxol?",
      a:
        "An OTP-native runtime for building TUIs, AI agents, and live web apps from one Elixir module. The same init/update/view shape renders to a terminal, Phoenix LiveView, SSH, and MCP."
    },
    %{
      q: "Do I need Elixir?",
      a:
        "Yes -- Raxol is an Elixir framework distributed via Hex. If you want to drive a Raxol app from another stack, you can talk to it over MCP (JSON-RPC)."
    },
    %{
      q: "Where do AI agents run?",
      a:
        "In your BEAM, supervised. Same app, same node. Bring your own API key (Anthropic, OpenAI, Ollama, Lumo, Kimi) or run mock for development. The framework streams tokens and routes inter-agent messages over a Registry."
    },
    %{
      q: "Can I drop Raxol into an existing Phoenix app?",
      a:
        "Yes. Add :raxol_liveview, mount your TEA module via TEALive or TerminalComponent. The terminal renders as an HTML <pre> diffed by LiveView."
    },
    %{
      q: "Is this production-ready?",
      a:
        "raxol, raxol_core, raxol_terminal, raxol_agent, raxol_mcp, raxol_liveview, raxol_plugin, raxol_speech, raxol_telegram, raxol_watch, and raxol_sensor are at v2.4 on Hex. raxol_payments is at 0.1. raxol_acp and raxol_symphony are pre-alpha. raxol.io itself runs on Fly."
    },
    %{
      q: "What does the SSH demo give me?",
      a:
        "ssh -p 2222 playground@raxol.io drops you into the same widget catalog you can run locally with `mix raxol.playground`. Each connection is a supervised channel with its own crash boundary."
    }
  ]

  defp faq_section(assigns) do
    assigns = assign(assigns, :faqs, @faqs)

    ~H"""
    <section class="landing-section px-6 py-24 max-w-3xl mx-auto" aria-labelledby="faq-title">
      <span class="section-eyebrow">FAQ</span>
      <h2 id="faq-title" class="heading-2xl mb-10">Questions, answered.</h2>
      <div class="faq-list">
        <%= for {%{q: q, a: a}, i} <- Enum.with_index(@faqs) do %>
          <details class="faq-item" id={"faq-#{i}"}>
            <summary><%= q %></summary>
            <div class="faq-item__body"><%= a %></div>
          </details>
        <% end %>
      </div>
    </section>
    """
  end

  # ===========================================================================
  # 6. CTA
  # ===========================================================================

  defp try_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-20 max-w-4xl mx-auto" aria-labelledby="try-title">
      <h2 id="try-title" class="heading-2xl mb-10">Try it</h2>

      <div class="space-y-3 mb-10">
        <.copyable_command id="copy-ssh" command={Helpers.ssh_command()} comment="zero install" color="#ffcd9c" />
        <.copyable_command id="copy-playground" command="mix raxol.playground" comment="interactive demos" color="#58a1c6" />
        <.copyable_command id="copy-demo" command="mix run examples/demo.exs" comment="BEAM dashboard" color="#58a1c6" />
      </div>

      <div class="flex gap-4 flex-wrap">
        <a href="/playground" class="btn-primary">Open Playground</a>
        <a href="/gallery" class="btn-secondary">Browse Gallery</a>
      </div>
    </section>
    """
  end

  # ===========================================================================
  # Footer
  # ===========================================================================

  defp footer_section(assigns) do
    ~H"""
    <footer class="landing-section px-6 py-16 border-t border-subtle">
      <div class="max-w-4xl mx-auto">
        <div class="flex flex-wrap gap-6 font-mono mb-10" style="font-size: clamp(0.7rem, 0.65rem + 0.25vw, 0.75rem); letter-spacing: 0.05em;">
          <a href="https://github.com/DROOdotFOO/raxol" class="footer-link">GitHub</a>
          <a href="https://hex.pm/packages/raxol" class="footer-link">Hex.pm</a>
          <a href="https://hexdocs.pm/raxol" class="footer-link">Docs</a>
          <a href="/playground" class="footer-link">Playground</a>
          <a href="/skill.md" class="footer-link">Skill</a>
        </div>

        <div class="flex items-center justify-between font-mono caption-text" style="letter-spacing: 0.05em;">
          <span>Elixir on OTP</span>
          <span>Made by <a href="https://axol.io" class="axol-link">axol.io</a></span>
        </div>
      </div>
    </footer>
    """
  end
end
