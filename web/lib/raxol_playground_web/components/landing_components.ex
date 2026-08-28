defmodule RaxolPlaygroundWeb.LandingComponents do
  @moduledoc """
  Sections of the raxol.io landing page, extracted from LandingLive so that
  the LiveView is just lifecycle (mount, handle_event, handle_info, render
  orchestration) and the markup lives here.

  The counter and agent code samples are owned by this module: it stores
  them as `~S\"""...\"""` literals, runs them through Makeup at compile time,
  and exposes the highlighted HTML through Components that don't take any
  attributes. Callers don't need to know either source exists.

  Components that take attributes (nav_bar, hero_section) receive only
  LiveView-driven state (mobile_menu_open, raxol_version, terminal_html).
  """
  use Phoenix.Component

  alias RaxolPlayground.Capabilities
  import Phoenix.HTML, only: [raw: 1]

  import RaxolPlaygroundWeb.PlaygroundComponents,
    only: [copyable_command: 1, terminal_chrome: 1, ssh_copy_block: 1]

  @counter_source ~S"""
  defmodule Counter do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_ctx), do: %{count: 0}

    @impl true
    def update(:increment, model), do: {%{model | count: model.count + 1}, []}
    def update(:decrement, model), do: {%{model | count: model.count - 1}, []}
    def update(_, model), do: {model, []}

    @impl true
    def view(model) do
      column style: %{padding: 1, gap: 1} do
        [
          text("Count: #{model.count}", style: [:bold]),
          row style: %{gap: 1} do
            [button("+", on_click: :increment), button("-", on_click: :decrement)]
          end
        ]
      end
    end
  end
  """

  @agent_source ~S"""
  defmodule Researcher do
    use Raxol.Agent

    @impl true
    def init(_ctx), do: %{notes: []}

    @impl true
    def update({:agent_message, _from, query}, model) do
      {model, [{:async, &llm(query, &1)}]}
    end

    def update({:llm_chunk, text}, model),
      do: {%{model | notes: [text | model.notes]}, []}
  end
  """

  @counter_code Makeup.highlight_inner_html(@counter_source)
  @agent_code Makeup.highlight_inner_html(@agent_source)
  @install_command "curl -fsSL https://raxol.io/install | bash"

  @faqs [
    %{
      q: "What is Raxol?",
      a:
        "An OTP-native runtime for building TUIs, AI agents, and live web apps from one Elixir module. The same init/update/view shape renders to a terminal, Phoenix LiveView, SSH, and MCP."
    },
    %{
      q: "Do I need Elixir?",
      a:
        "Yes. Raxol is an Elixir framework distributed via Hex. If you want to drive a Raxol app from another stack, you can talk to it over MCP (JSON-RPC)."
    },
    %{
      q: "Where do AI agents run?",
      a:
        "In your BEAM, supervised. Same app, same node. Bring your own API key (Anthropic, OpenAI, OpenRouter, Ollama, Lumo, Kimi) or run mock for development. The framework streams tokens and routes inter-agent messages over a Registry."
    },
    %{
      q: "Can I drop Raxol into an existing Phoenix app?",
      a:
        "Yes. Add :raxol_liveview, mount your TEA module via TEALive or TerminalComponent. The terminal renders as an HTML <pre> diffed by LiveView."
    },
    %{
      q: "Is this production-ready?",
      a:
        "raxol, raxol_core, raxol_terminal, raxol_agent, raxol_mcp, raxol_liveview, raxol_plugin, and raxol_sensor are at v2.5 on Hex; raxol_speech, raxol_telegram, and raxol_watch at 0.2; raxol_payments at 0.1. raxol_earn and raxol_symphony are pre-alpha. raxol.io itself runs on Fly."
    },
    %{
      q: "What does the SSH demo give me?",
      a:
        "Raxol's SSH surface gives every connection a supervised channel with its own crash boundary. The hosted playground is currently browser-only; run `mix raxol.playground --ssh` to try the SSH surface locally."
    }
  ]

  # ---------------------------------------------------------------------------
  # Navigation
  # ---------------------------------------------------------------------------

  attr(:mobile_menu_open, :boolean, required: true)

  def nav_bar(assigns) do
    ~H"""
    <nav class="sticky top-0 z-50 surface-bar" aria-label="Main navigation">
      <div class="max-w-5xl mx-auto px-6 py-3 flex items-center justify-between">
        <a href="/" class="font-mono text-lg font-bold text-axol-coral tracking-wide">
          raxol
        </a>
        <div class="hidden md:flex items-center gap-6 text-sm font-mono tracking-wide">
          <a href="/playground" class="nav-link">Playground</a>
          <a href="/gallery" class="nav-link">Gallery</a>
          <a href="https://hexdocs.pm/raxol" class="nav-link">Docs</a>
          <a href="/skill.md" class="nav-link">Skill</a>
          <a href="https://github.com/DROOdotFOO/raxol" class="nav-link">GitHub</a>
        </div>
        <button
          type="button"
          phx-click="toggle_mobile_menu"
          class="md:hidden p-3 text-pearl-50"
          aria-label={if @mobile_menu_open, do: "Close menu", else: "Open menu"}
          aria-expanded={to_string(@mobile_menu_open)}
          aria-controls="mobile-navigation"
        >
          <svg xmlns="http://www.w3.org/2000/svg" class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2" aria-hidden="true">
            <%= if @mobile_menu_open do %>
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            <% else %>
              <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            <% end %>
          </svg>
        </button>
      </div>
      <%= if @mobile_menu_open do %>
        <div id="mobile-navigation" class="md:hidden px-6 py-4 flex flex-col gap-4 text-sm font-mono border-t border-subtle text-pearl-50">
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

  # ---------------------------------------------------------------------------
  # 1. Hook: SSH + live demo + CTAs
  # ---------------------------------------------------------------------------

  attr(:raxol_version, :string, required: true)
  attr(:terminal_html, :boolean, required: true)

  def hero_section(assigns) do
    assigns = assign(assigns, :install_command, @install_command)

    ~H"""
    <section class="landing-section px-6 pt-24 pb-14 md:pt-32 md:pb-24 max-w-4xl mx-auto text-center" aria-labelledby="hero-title">
      <h1 id="hero-title" class="font-mono font-bold tracking-tight text-axol-coral mb-6" style="font-size: clamp(3.5rem, 2.5rem + 5vw, 7rem); line-height: 1;">
        raxol
      </h1>

      <p class="font-mono tracking-normal text-pearl-80 mb-4" style="font-size: clamp(1.05rem, 0.95rem + 0.5vw, 1.35rem); line-height: 1.4;">
        One app. Terminal, browser, SSH, or agent.
      </p>

      <p class="body-text-dim mb-10 max-w-2xl mx-auto">
        Write a TEA module in Elixir. It renders everywhere: crash isolation,
        hot reload, AI agents, and distributed swarm from OTP.
      </p>

      <%!-- Live terminal embed (HTML injected by RaxolTerminal hook) --%>
      <%= if @terminal_html do %>
        <div class="terminal-chrome mb-10 mx-auto text-left max-w-2xl">
          <.terminal_chrome title="raxol" />
          <div
            id="landing-terminal"
            phx-hook="RaxolTerminal"
            class="raxol-terminal p-4 bg-synthwave-bg"
            data-theme="synthwave84"
            data-no-scroll="true"
            tabindex="-1"
            role="img"
            aria-label="Raxol demo"
          ></div>
        </div>
      <% end %>

      <div class="mb-10">
        <.ssh_copy_block id="install-copy" cmd={@install_command} />
        <p class="label-text mt-3">Self-contained binary. Click to copy.</p>
      </div>

      <div class="flex items-center justify-center gap-4 flex-wrap">
        <a href="/playground" class="btn-primary">Open Playground</a>
        <a href="/skill.md" class="btn-sky">Agent Skill</a>
        <a href="https://github.com/DROOdotFOO/raxol" class="btn-secondary">GitHub</a>
      </div>

      <div class="mt-10 mb-12">
        <code class="font-mono detail-text text-pearl-40 bg-inset border border-subtle px-4 py-2 rounded-sm"><%= raw("{:raxol, \"~> #{@raxol_version}\"}") %></code>
      </div>

      <div class="stat-grid max-w-2xl mx-auto" role="list" aria-label="Project stats">
        <div class="stat-cell" role="listitem">
          <span class="stat-value"><%= Capabilities.surface_count() %></span>
          <span class="stat-label">surfaces</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value"><%= Capabilities.package_count() %></span>
          <span class="stat-label">packages</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value">1</span>
          <span class="stat-label">binary</span>
        </div>
        <div class="stat-cell" role="listitem">
          <span class="stat-value">OTP</span>
          <span class="stat-label">native</span>
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 2. Proof: counter example
  # ---------------------------------------------------------------------------

  def code_example_section(assigns) do
    assigns = assign(assigns, :counter_code, @counter_code)

    ~H"""
    <section class="landing-section px-6 py-12 md:py-20 max-w-4xl mx-auto" aria-labelledby="code-title">
      <h2 id="code-title" class="heading-2xl mb-3">Hello World</h2>
      <p class="body-text mb-8">
        Every Raxol app follows The Elm Architecture:
        <span class="text-axol-coral">init</span>,
        <span class="text-axol-coral">update</span>,
        <span class="text-axol-coral">view</span>.
      </p>

      <div class="terminal-chrome mb-8">
        <.terminal_chrome title="counter.exs" />
        <div class="terminal-chrome-body">
          <pre class="code-block"><code class="syntax-elixir"><%= Phoenix.HTML.raw(@counter_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim">
        That counter works in a terminal, Phoenix LiveView, and over SSH. One codebase.
      </p>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 3a. Deep dive 01: Surfaces
  # ---------------------------------------------------------------------------

  def surfaces_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="surfaces-title">
      <div class="mb-10">
        <span class="section-numeral" aria-hidden="true">01</span>
        <span class="section-eyebrow">Surfaces</span>
        <h2 id="surfaces-title" class="heading-2xl mb-3">One module, <%= Capabilities.surface_count() %> surfaces.</h2>
        <p class="body-text max-w-2xl">
          Write the TEA module once. Render to a terminal, embed in Phoenix
          LiveView, serve over SSH, expose to agents over MCP, or reach a phone
          via Telegram, watch push, and voice. Same model. Same view.
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
        <div class="surface-chip">
          <span class="surface-chip__name">Telegram</span>
          <span class="surface-chip__cmd">Telegex HTTP</span>
        </div>
        <div class="surface-chip">
          <span class="surface-chip__name">Watch</span>
          <span class="surface-chip__cmd">APNS + FCM push</span>
        </div>
        <div class="surface-chip">
          <span class="surface-chip__name">Speech</span>
          <span class="surface-chip__cmd">TTS + STT</span>
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 3b. Deep dive 02: SSH zero-install
  # ---------------------------------------------------------------------------

  def ssh_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="ssh-deep-title">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-8 md:gap-12 items-center">
        <div>
          <span class="section-numeral" aria-hidden="true">02</span>
          <span class="section-eyebrow">SSH surface</span>
          <h2 id="ssh-deep-title" class="heading-2xl mb-3">Serve the same app over SSH.</h2>
          <p class="body-text mb-6">
            Every Raxol app is one SSH connection away. Each session is a
            supervised BEAM process: crash-isolated, hot-reloadable, observable.
          </p>
          <ul class="detail-text space-y-2 leading-relaxed list-disc list-inside">
            <li>Auto-generated host keys, no setup</li>
            <li>Supervised channel per connection</li>
            <li>Survives client disconnects</li>
            <li>One line to enable in your app</li>
          </ul>
        </div>
        <div class="text-center space-y-4">
          <a href="/playground" class="btn-primary">Open Browser Playground</a>
          <p class="label-text">Hosted SSH is temporarily offline.</p>
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 3c. Deep dive 03: Agent runtime
  # ---------------------------------------------------------------------------

  def agent_deep_dive(assigns) do
    assigns = assign(assigns, :agent_code, @agent_code)

    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-4xl mx-auto" aria-labelledby="agent-deep-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">03</span>
        <span class="section-eyebrow">Agent runtime</span>
        <h2 id="agent-deep-title" class="heading-2xl mb-3">Agents are TEA apps.</h2>
        <p class="body-text max-w-2xl">
          Same <span class="text-axol-coral">init</span> /
          <span class="text-axol-coral">update</span> /
          <span class="text-axol-coral">view</span> shape as a UI. The view is
          optional; headless agents skip rendering. Supervision, messaging,
          hot reload, and swarm discovery come free from OTP.
        </p>
      </div>

      <div class="terminal-chrome mb-6">
        <.terminal_chrome title="researcher.exs" />
        <div class="terminal-chrome-body">
          <pre class="code-block"><code class="syntax-elixir"><%= Phoenix.HTML.raw(@agent_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim">
        Streaming LLM output via <code class="text-axol-coral">:async</code> commands.
        Inter-agent messages routed through a unique <code class="text-axol-coral">Registry</code>.
        Bring your own key for Anthropic, OpenAI, OpenRouter, Ollama, Lumo, or Kimi, or run mock.
      </p>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 4. Features grid (numbered)
  # ---------------------------------------------------------------------------

  def features_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="features-title">
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
      <p class="detail-text leading-relaxed"><%= @description %></p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # 5. Packages
  # ---------------------------------------------------------------------------

  def packages_section(assigns) do
    ~H"""
    <section class="landing-section px-6 py-12 md:py-20 max-w-5xl mx-auto" aria-labelledby="packages-title">
      <h2 id="packages-title" class="heading-2xl mb-3">Pick what you need</h2>
      <p class="body-text mb-10">Full framework or just the parts that matter.</p>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <.package_card id="raxol" name="raxol" dep={Capabilities.dep("raxol")} description="Full framework: TEA runtime, rendering, widgets, effects" accent={true} />
        <.package_card id="agent" name="raxol_agent" dep={Capabilities.dep("raxol_agent")} description="AI agents, teams, strategies, LLM streaming" />
        <.package_card id="mcp" name="raxol_mcp" dep={Capabilities.dep("raxol_mcp")} description="MCP server, tool derivation from widgets" />
        <.package_card id="payments" name="raxol_payments" dep={Capabilities.dep("raxol_payments")} description="x402, MPP, Xochi cross-chain, spending controls" />
        <.package_card id="liveview" name="raxol_liveview" dep={Capabilities.dep("raxol_liveview")} description="Render TEA apps in Phoenix LiveView" />
        <.package_card id="sensor" name="raxol_sensor" dep={Capabilities.dep("raxol_sensor")} description="Sensor fusion. Zero dependencies." />
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
      <h3 class={["name-sky-sm mb-1", if(@accent, do: "text-axol-coral", else: "text-sky")]}>
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

  # ---------------------------------------------------------------------------
  # 6. FAQ
  # ---------------------------------------------------------------------------

  def faq_section(assigns) do
    assigns = assign(assigns, :faqs, @faqs)

    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-3xl mx-auto" aria-labelledby="faq-title">
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

  # ---------------------------------------------------------------------------
  # 7. CTA
  # ---------------------------------------------------------------------------

  def try_section(assigns) do
    assigns = assign(assigns, :install_command, @install_command)

    ~H"""
    <section class="landing-section px-6 py-12 md:py-20 max-w-4xl mx-auto" aria-labelledby="try-title">
      <h2 id="try-title" class="heading-2xl mb-10">Try it</h2>

      <div class="space-y-3 mb-10">
        <.copyable_command id="copy-install" command={@install_command} comment="self-contained binary" tone={:coral} />
        <.copyable_command id="copy-npm" command="npm i -g raxol" comment="Node users" tone={:sky} />
        <.copyable_command id="copy-playground" command="mix raxol.playground" comment="interactive demos" tone={:sky} />
        <.copyable_command id="copy-demo" command="mix run examples/demo.exs" comment="BEAM dashboard" tone={:sky} />
      </div>

      <div class="flex gap-4 flex-wrap">
        <a href="/playground" class="btn-primary">Open Playground</a>
        <a href="/gallery" class="btn-secondary">Browse Gallery</a>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Footer
  # ---------------------------------------------------------------------------

  def footer_section(assigns) do
    ~H"""
    <footer class="landing-section px-6 py-16 border-t border-subtle">
      <div class="max-w-4xl mx-auto">
        <div class="flex flex-wrap gap-6 font-mono mb-10 tracking-wide text-sm">
          <a href="https://github.com/DROOdotFOO/raxol" class="footer-link">GitHub</a>
          <a href="https://hex.pm/packages/raxol" class="footer-link">Hex.pm</a>
          <a href="https://hexdocs.pm/raxol" class="footer-link">Docs</a>
          <a href="/playground" class="footer-link">Playground</a>
          <a href="/skill.md" class="footer-link">Skill</a>
        </div>

        <div class="flex items-center justify-between font-mono caption-text tracking-wide">
          <span>Elixir on OTP</span>
          <span>Made by <a href="https://axol.io" class="axol-link">axol.io</a></span>
        </div>
      </div>
    </footer>
    """
  end
end
