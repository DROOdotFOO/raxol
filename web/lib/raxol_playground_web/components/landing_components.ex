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
  alias RaxolPlayground.RecordedFrames
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

  # The module the hero's surface tabs render. scripts/gen_landing_frames.exs
  # at the repo root records EXACTLY this module through Raxol.Headless into
  # priv/hero_frames/ -- keep the two sources identical and rerun the script
  # after editing, so the pane and the frames stay the same program.
  @hero_counter_source ~S"""
  defmodule Counter do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_), do: %{count: 0}

    @impl true
    def update(:inc, m),
      do: {%{m | count: m.count + 1}, []}

    def update(%{data: %{char: "+"}}, m),
      do: update(:inc, m)

    def update(_, m), do: {m, []}

    @impl true
    def view(m) do
      column style: %{padding: 1, gap: 1} do
        [
          text("Count: #{m.count}", style: [:bold]),
          button("+", on_click: :inc)
        ]
      end
    end
  end
  """

  @counter_code Makeup.highlight_inner_html(@counter_source)
  @agent_code Makeup.highlight_inner_html(@agent_source)
  @hero_counter_code Makeup.highlight_inner_html(@hero_counter_source)
  @install_command "curl -fsSL https://raxol.io/install | bash"
  @brew_command "brew install droodotfoo/tap/raxol"
  @npm_command "npm i -g raxol"

  # Authored output panes for the hero's non-terminal surfaces (the
  # terminal and SSH panes embed real recorded frames instead). Kept as
  # pre-escaped HTML strings: whitespace is significant inside <pre>, and
  # a HEEx heredoc cannot carry flush-left lines.
  @hero_out_browser ~S"""
  <span class="hc">$ mix phx.server</span>

  &lt;div <span class="hk">data-raxol-id</span>=<span class="hg">"counter"</span>&gt;
    &lt;span <span class="hk">class</span>=<span class="hg">"bold"</span>&gt;Count: 3&lt;/span&gt;
    &lt;button <span class="hk">phx-click</span>=<span class="hg">"inc"</span>&gt;+&lt;/button&gt;
  &lt;/div&gt;

  <span class="hc">TerminalBridge, cell-level patches</span>
  <span class="hc">same model, same view/1</span>
  """

  @hero_out_mcp ~S"""
  <span class="hc">$ mix mcp.server</span>

  {
    <span class="hk">"tools"</span>: [
      { <span class="hk">"name"</span>: <span class="hg">"counter_click"</span>,
        <span class="hk">"desc"</span>: <span class="hg">"Press the + button"</span> },
      { <span class="hk">"name"</span>: <span class="hg">"counter_read"</span>,
        <span class="hk">"desc"</span>: <span class="hg">"Read the count"</span> }
    ]
  }

  <span class="hc">derived from the widget tree</span>
  """

  @hero_out_acp ~S"""
  <span class="hc">$ raxol acp</span>

  <span class="hc">-&gt;</span> { <span class="hk">"method"</span>: <span class="hg">"session/prompt"</span>,
       <span class="hk">"params"</span>: { <span class="hk">"sessionId"</span>: <span class="hg">"..."</span> } }

  <span class="hc">&lt;-</span> { <span class="hk">"method"</span>: <span class="hg">"session/update"</span>,
       <span class="hk">"update"</span>: { <span class="hk">"sessionUpdate"</span>:
         <span class="hg">"agent_message_chunk"</span> } }

  <span class="hc">Zed, JetBrains, neovim, Emacs</span>
  """

  # Version claims derive from Capabilities.packages() so the FAQ can never
  # drift from the package table the capability endpoints serve.
  @faq_versions Capabilities.packages()
                |> Enum.group_by(& &1.version, & &1.name)
                |> Enum.sort_by(fn {version, _names} -> version end, :desc)
                |> Enum.map_join("; ", fn {version, names} ->
                  "#{Enum.join(names, ", ")} at #{String.replace(version, "~> ", "v")}"
                end)

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
        "On Hex: #{@faq_versions}. raxol_earn and raxol_symphony are pre-alpha. raxol.io itself runs on Fly."
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
          <a href="/demos" class="nav-link">Demos</a>
          <a href="https://hexdocs.pm/raxol" class="nav-link">Docs</a>
          <a href="/skill.md" class="nav-link">Skill</a>
          <a href="https://github.com/DROOdotFOO/raxol" class="nav-link">GitHub</a>
        </div>
        <button
          type="button"
          phx-click="toggle_mobile_menu"
          class="md:hidden p-3 text-pearl-60"
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
        <div id="mobile-navigation" class="md:hidden px-6 py-4 flex flex-col gap-4 text-sm font-mono border-t border-subtle text-pearl-60">
          <a href="/playground">Playground</a>
          <a href="/gallery">Gallery</a>
          <a href="/demos">Demos</a>
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

  attr(:terminal_html, :boolean, required: true)
  attr(:demo_paused, :boolean, required: true)

  def hero_section(assigns) do
    ~H"""
    <%!-- MotionPref reports prefers-reduced-motion to the LiveView (at
         connect and on preference change) so the server stops pushing
         live demo frames after takeover; CSS media queries cannot gate
         those. The recorded-frames player gates itself client-side. --%>
    <section id="hero" phx-hook="MotionPref" class="landing-section px-6 pt-20 pb-14 md:pt-28 md:pb-24 max-w-5xl mx-auto text-center" aria-labelledby="hero-title">
      <h1 id="hero-title" class="font-mono font-bold tracking-tight text-pearl mb-5" style="font-size: clamp(1.9rem, 1.3rem + 2.6vw, 3.4rem); line-height: 1.2;">
        One app. <span class="text-axol-coral">Terminal, browser, SSH, or agent.</span>
      </h1>

      <p class="body-text-dim mb-10 max-w-2xl mx-auto">
        Write a TEA module in Elixir. It renders everywhere: crash isolation,
        hot reload, AI agents, and distributed swarm from OTP.
      </p>

      <.hero_demo terminal_html={@terminal_html} demo_paused={@demo_paused} />

      <div class="mb-10">
        <.install_tabs />
      </div>

      <div class="flex items-center justify-center gap-4 flex-wrap mb-12">
        <a href="/playground" class="btn-primary">Open Playground</a>
        <a href="/skill.md" class="btn-sky">Agent Skill</a>
        <a href="https://github.com/DROOdotFOO/raxol" class="btn-secondary">GitHub</a>
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
  # 1a. Install tabs: four methods over one command line
  #
  # All four panes ship in the dead render; the InstallTabs hook only
  # toggles `hidden`/aria-selected, so the block works (showing curl)
  # before JS and never round-trips the server.
  # ---------------------------------------------------------------------------

  def install_tabs(assigns) do
    assigns =
      assign(assigns,
        curl_cmd: @install_command,
        brew_cmd: @brew_command,
        npm_cmd: @npm_command,
        hex_dep: Capabilities.dep("raxol")
      )

    ~H"""
    <div id="install-tabs" phx-hook="InstallTabs" class="install-tabs mx-auto">
      <div class="install-tabs__row" role="tablist" aria-label="Install method">
        <button type="button" class="install-tab" role="tab" aria-selected="true" data-m="curl">curl</button>
        <button type="button" class="install-tab" role="tab" aria-selected="false" data-m="brew">brew</button>
        <button type="button" class="install-tab" role="tab" aria-selected="false" data-m="npm">npm</button>
        <button type="button" class="install-tab" role="tab" aria-selected="false" data-m="hex">hex</button>
      </div>

      <div class="install-pane" data-m="curl">
        <.ssh_copy_block id="install-copy-curl" cmd={@curl_cmd} />
        <p class="label-text mt-3">Self-contained binary. macOS and Linux. Click to copy.</p>
      </div>
      <div class="install-pane" data-m="brew" hidden>
        <.ssh_copy_block id="install-copy-brew" cmd={@brew_cmd} />
        <p class="label-text mt-3">Homebrew tap. macOS and Linux.</p>
      </div>
      <div class="install-pane" data-m="npm" hidden>
        <.ssh_copy_block id="install-copy-npm" cmd={@npm_cmd} />
        <p class="label-text mt-3">One wrapper, one per-platform binary. Needs Node.</p>
      </div>
      <div class="install-pane" data-m="hex" hidden>
        <.ssh_copy_block id="install-copy-hex" cmd={@hex_dep} prompt={nil} />
        <p class="label-text mt-3">Add to mix.exs in an existing Elixir app.</p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # 1b. Hero demo: one module, five surfaces
  #
  # All five surface panes are server-rendered (the dead render before the
  # socket connects carries the module pane and terminal frame one); the
  # HeroDemo hook only toggles `hidden`/aria-selected, auto-advancing tabs
  # and stepping the recorded frames on a fixed-timestep rAF accumulator.
  # Clicking a tab stops the auto-advance; "take over live" swaps the
  # terminal pane's recorded frames for the live DemoLifecycle session.
  # ---------------------------------------------------------------------------

  attr(:terminal_html, :boolean, required: true)
  attr(:demo_paused, :boolean, required: true)

  def hero_demo(assigns) do
    assigns =
      assign(assigns,
        hero_code: @hero_counter_code,
        hero_frames: RecordedFrames.hero_frames(),
        ssh_frame: List.last(RecordedFrames.hero_frames()),
        out_browser: @hero_out_browser,
        out_mcp: @hero_out_mcp,
        out_acp: @hero_out_acp
      )

    ~H"""
    <div id="hero-demo" phx-hook="HeroDemo" data-live={@terminal_html && "true"} class="hero-demo mb-10 mx-auto text-left">
      <div class="hero-demo-bar">
        <span class="hd-dot"></span><span class="hd-dot"></span><span class="hd-dot"></span>
        <span :if={!@terminal_html} class="hd-title" data-role="title">counter.ex -- rendering to the terminal</span>
        <span :if={@terminal_html} class="hd-title">beam dashboard -- live from this page's VM</span>
      </div>

      <%= if @terminal_html do %>
        <%!-- Live takeover: the surface tour is replaced by a real
             supervised session streaming from this page's BEAM. --%>
        <div class="hero-live-wrap">
          <%!-- phx-update="ignore": the RaxolTerminal hook owns this
               element's content; without it any hero re-render patches
               it back to empty. --%>
          <div
            id="landing-terminal"
            phx-hook="RaxolTerminal"
            phx-update="ignore"
            class="raxol-terminal bg-synthwave-bg"
            data-theme="synthwave84"
            data-no-scroll="true"
            tabindex="-1"
            role="img"
            aria-label="Raxol live demo"
          ></div>
        </div>
      <% else %>
      <div class="hero-tabs" role="tablist" aria-label="Render surface">
        <button type="button" class="hero-tab" role="tab" aria-selected="true" data-i="0" data-title="counter.ex -- rendering to the terminal" data-label="Rendered to the terminal">Terminal</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="1" data-title="counter.ex -- rendering to Phoenix LiveView" data-label="Rendered to the browser">Browser</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="2" data-title="counter.ex -- served over SSH" data-label="Served over SSH">SSH</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="3" data-title="counter.ex -- exposed as MCP tools" data-label="Exposed to agents">Agent / MCP</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="4" data-title="counter.ex -- driven over ACP" data-label="Driven from your editor">Editor / ACP</button>
      </div>

      <div class="hero-panes">
        <div class="hero-pane">
          <div class="hero-pane-label">The module (never changes)</div>
          <pre class="hero-code"><code class="syntax-elixir"><%= raw(@hero_code) %></code></pre>
        </div>

        <div class="hero-pane">
          <div class="hero-pane-label" data-role="out-label">Rendered to the terminal</div>

          <div class="hero-out" data-surface="0">
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix run counter.exs</span></pre>
            <%!-- Recorded frames: real Headless output, committed under
                 priv/hero_frames/. Frame one ships visible in the dead
                 render; the hook steps the rest. --%>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true">
              <%= for {frame, i} <- Enum.with_index(@hero_frames) do %>
                <div class="hero-frame" data-frame={i} hidden={i != 0}><%= raw(frame) %></div>
              <% end %>
            </div>
            <pre class="hero-pre hero-note" aria-hidden="true"><span class="hc">termbox2 NIF, direct cell diff</span></pre>
          </div>

          <div class="hero-out" data-surface="1" hidden>
            <pre class="hero-pre"><%= raw(@out_browser) %></pre>
          </div>

          <div class="hero-out" data-surface="2" hidden>
            <%!-- A local example on purpose: hosted SSH is suspended, and
                 the landing must not advertise playground@raxol.io (the
                 component test enforces this). --%>
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ ssh -p 2222 demo@localhost</span></pre>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true">
              <div class="hero-frame"><%= raw(@ssh_frame) %></div>
            </div>
            <pre class="hero-pre hero-note" aria-hidden="true"><span class="hc">one supervised BEAM process per connection</span></pre>
          </div>

          <div class="hero-out" data-surface="3" hidden>
            <pre class="hero-pre"><%= raw(@out_mcp) %></pre>
          </div>

          <div class="hero-out" data-surface="4" hidden>
            <pre class="hero-pre"><%= raw(@out_acp) %></pre>
          </div>
        </div>
      </div>
      <% end %>

      <div class="hero-demo-foot">
        <%= if @terminal_html do %>
          <span class="hero-live-badge">live session</span>
          <button
            type="button"
            phx-click="toggle_demo_motion"
            class="label-text cursor-pointer hover:text-pearl-80 transition-colors"
          >
            <%= if @demo_paused, do: "play demo", else: "pause demo" %>
          </button>
          <button
            type="button"
            phx-click="end_take_over"
            class="label-text cursor-pointer hover:text-pearl-80 transition-colors"
          >
            back to the tour
          </button>
        <% else %>
          <button
            type="button"
            data-role="player-pause"
            class="label-text cursor-pointer hover:text-pearl-80 transition-colors"
          >
            pause
          </button>
          <button
            type="button"
            phx-click="take_over"
            class="label-text cursor-pointer text-axol-coral hover:text-pearl-80 transition-colors"
          >
            take over live
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # 2. Proof: counter example
  # ---------------------------------------------------------------------------

  def code_example_section(assigns) do
    assigns = assign(assigns, :counter_code, @counter_code)

    ~H"""
    <section class="landing-section px-6 py-12 md:py-20 max-w-5xl mx-auto" aria-labelledby="code-title">
      <h2 id="code-title" class="heading-2xl mb-3">Hello World</h2>
      <p class="body-text mb-8 max-w-2xl">
        Every Raxol app follows The Elm Architecture:
        <span class="text-axol-coral">init</span>,
        <span class="text-axol-coral">update</span>,
        <span class="text-axol-coral">view</span>.
      </p>

      <div class="terminal-chrome mb-8 ch-snap">
        <.terminal_chrome title="counter.exs" />
        <div class="terminal-chrome-body">
          <pre class="code-block"><code class="syntax-elixir"><%= Phoenix.HTML.raw(@counter_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim max-w-2xl">
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
          Write the TEA module once. It meets you in three places you already
          are: your terminal, your browser, and wherever your agents work.
          Same model. Same view.
        </p>
      </div>

      <div class="surface-buckets">
        <div class="surface-bucket">
          <h3 class="surface-bucket__label">In your terminal</h3>
          <div class="surface-bucket__chips">
            <div class="surface-chip">
              <span class="surface-chip__name">Terminal</span>
              <span class="surface-chip__cmd">termbox2 NIF</span>
            </div>
            <div class="surface-chip">
              <span class="surface-chip__name">SSH</span>
              <span class="surface-chip__cmd">Erlang :ssh daemon</span>
            </div>
          </div>
        </div>

        <div class="surface-bucket">
          <h3 class="surface-bucket__label">In your browser</h3>
          <div class="surface-bucket__chips">
            <div class="surface-chip">
              <span class="surface-chip__name">Browser</span>
              <span class="surface-chip__cmd">Phoenix LiveView</span>
            </div>
          </div>
        </div>

        <div class="surface-bucket">
          <h3 class="surface-bucket__label">Where your agents are</h3>
          <div class="surface-bucket__chips">
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
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="agent-deep-title">
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

      <div class="terminal-chrome mb-6 ch-snap">
        <.terminal_chrome title="researcher.exs" />
        <div class="terminal-chrome-body">
          <pre class="code-block"><code class="syntax-elixir"><%= Phoenix.HTML.raw(@agent_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim max-w-2xl">
        Streaming LLM output via <code class="text-axol-coral">:async</code> commands.
        Inter-agent messages routed through a unique <code class="text-axol-coral">Registry</code>.
        Bring your own key for Anthropic, OpenAI, OpenRouter, Ollama, Lumo, or Kimi, or run mock.
      </p>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 3d. Deep dive 04: Coding agent + ACP
  # ---------------------------------------------------------------------------

  def coding_agent_deep_dive(assigns) do
    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="coding-agent-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">04</span>
        <span class="section-eyebrow">Coding agent</span>
        <h2 id="coding-agent-title" class="heading-2xl mb-3">raxol speaks ACP.</h2>
        <p class="body-text max-w-2xl">
          Open it in Zed, JetBrains, neovim, Emacs, or VS Code: raxol is listed
          on <a href="https://agentclientprotocol.com" class="text-sky">agentclientprotocol.com</a>
          beside Claude Agent, Codex CLI, Cursor, Gemini CLI, and GitHub
          Copilot. The same agent loop serves four surfaces:
        </p>
      </div>

      <div class="space-y-3 mb-6 ch-snap">
        <.copyable_command id="copy-agent-code" command="mix raxol.code" comment="interactive coding-agent TUI" tone={:coral} />
        <.copyable_command id="copy-agent-acp" command="raxol acp" comment="serve to Zed, JetBrains, neovim" tone={:sky} />
        <.copyable_command id="copy-agent-p" command={~S(raxol -p "fix the failing test")} comment="headless, JSON events on stderr" tone={:sky} />
        <.copyable_command id="copy-agent-mcp" command="mix mcp.server" comment="expose the UI itself as agent tools" tone={:sky} />
      </div>

      <p class="body-text-dim max-w-2xl">
        The last line is one no competitor can print: deriving MCP tools from a
        widget tree requires the UI framework and the agent runtime to be the
        same system.
      </p>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 3e. Deep dive 05: Agent payments (privacy ladder + solver reach matrix)
  #
  # The reach matrix renders server-side from the PAYMENTS solver's
  # capability endpoint (Raxol.Payments.Xochi.Capabilities) -- unrelated to
  # raxol.io's own /api/capabilities (CapabilitiesController, the agent
  # surface). `source: :fallback` renders a "cached" badge; liveness is
  # never faked.
  # ---------------------------------------------------------------------------

  # Score ranges live in PrivacyTier's score_to_tier clauses (not exposed);
  # the open/public notes describe opt-down tiers with no score gate.
  @tier_notes %{
    open: "rebate for full analytics",
    public: "no fee, full disclosure",
    standard: "trust score 0-24",
    stealth: "trust score 25-49",
    private: "trust score 50-74",
    sovereign: "trust score 75 and above"
  }

  # Authored commentary on solver rails the matrix data does not carry.
  @chain_notes %{4663 => "Permit2 pull", 728_126_428 => "relay rail"}

  # Stables lead, WETH trails; unknown symbols land after, alphabetically.
  @token_order %{"USDC" => 0, "USDT" => 1, "USDG" => 2, "WETH" => 3}

  @payments_version Enum.find_value(Capabilities.packages(), fn
                      %{name: "raxol_payments", version: v} -> String.replace(v, "~> ", "")
                      _ -> nil
                    end)

  attr(:matrix, :map, required: true)

  def payments_deep_dive(assigns) do
    assigns =
      assign(assigns,
        tiers: Raxol.Payments.PrivacyTier.all(),
        tier_notes: @tier_notes,
        payments_version: @payments_version,
        rows: reach_rows(assigns.matrix),
        show_future_svm: not Enum.any?(assigns.matrix.chains, &(&1.vm_type == :svm)),
        live?: assigns.matrix.source == :live
      )

    ~H"""
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="payments-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">05</span>
        <span class="section-eyebrow">Agent payments</span>
        <h2 id="payments-title" class="heading-2xl mb-3">Agents that settle, privately.</h2>
        <p class="body-text max-w-2xl">
          First funded cross-chain settlement on 2026-06-28; the USDC transfer
          offering has been live on Base since 2026-07-20. Trust is proven with
          zero-knowledge attestations rather than disclosed, so a higher tier
          reveals less while charging less. Stealth settlement derives a
          one-time address per payment (ERC-5564); shielded settlement posts
          the note into an Aztec execution environment.
        </p>
        <p class="caption-text mt-3">
          Early, and labeled: the payments packages are at <%= @payments_version %> beside a 2.6
          core. Dated on-chain events over claims.
        </p>
      </div>

      <div class="ladder mb-10" role="table" aria-label="Privacy tiers">
        <div class="rung rung--head" role="row">
          <span role="columnheader">Tier</span>
          <span role="columnheader">Fee</span>
          <span role="columnheader">Settlement</span>
          <span role="columnheader">Trust score</span>
        </div>
        <div :for={tier <- @tiers} class="rung" role="row">
          <span class="rung__tier" role="cell"><%= tier.tier %></span>
          <span class="rung__fee" role="cell"><%= tier.fee_bps %> bps</span>
          <span class={["rung__set", settlement_class(tier.settlement)]} role="cell"><%= tier.settlement %></span>
          <span class="rung__note" role="cell"><%= @tier_notes[tier.tier] %></span>
        </div>
      </div>

      <h3 class="name-coral mb-2">Reach, from the solver's own matrix</h3>
      <p class="body-text-dim max-w-2xl mb-4">
        Rendered server-side from the Xochi solver's capability matrix
        (<code>Raxol.Payments.Xochi.Capabilities.get/1</code>, five-minute
        cache). When the endpoint is unreachable it degrades to the static
        registry and says so. New solver chains light up with zero redeploy.
      </p>

      <div class="reach">
        <div class="reach-bar">
          <span><span class="reach-verb">GET</span> api.xochi.fi/api/capabilities</span>
          <span class={["src-badge", !@live? && "src-badge--cached"]}>
            <%= if @live?, do: "source: live", else: "source: cached" %>
          </span>
        </div>
        <div class="reach-scroll">
          <div class="reach-grid">
            <div :for={row <- @rows} class="reach-row">
              <span class="reach-row__name"><%= row.chain_name %></span>
              <span class="reach-row__id"><%= row.chain_id %></span>
              <span class="reach-row__vm"><%= row.vm %></span>
              <span class="reach-toks">
                <span :for={symbol <- row.tokens} class={["tok", symbol == "WETH" && "tok--alt"]}><%= symbol %></span>
                <span :if={row.note} class="tok tok--dim"><%= row.note %></span>
              </span>
            </div>
            <div :if={@show_future_svm} class="reach-row reach-row--future">
              <span class="reach-row__name">Solana</span>
              <span class="reach-row__id">--</span>
              <span class="reach-row__vm">SVM</span>
              <span class="reach-row__note">lights up when the solver ships it, zero redeploy</span>
            </div>
          </div>
        </div>
        <div class="reach-foot">
          every corridor settles public,
          <span class="set-stealth">stealth</span> (ERC-5564 one-time address), or
          <span class="set-shielded">shielded</span> (Aztec) -- selected by trust tier
        </div>
      </div>
    </section>
    """
  end

  defp reach_rows(%{chains: chains, tokens: tokens}) do
    Enum.map(chains, fn chain ->
      symbols =
        tokens
        |> Enum.filter(&Map.has_key?(&1.addresses, chain.chain_id))
        |> Enum.map(& &1.symbol)
        |> Enum.uniq()
        |> Enum.sort_by(&{Map.get(@token_order, &1, 99), &1})

      %{
        chain_name: chain.chain_name,
        chain_id: chain.chain_id,
        vm: chain.vm_type |> Atom.to_string() |> String.upcase(),
        tokens: symbols,
        note: @chain_notes[chain.chain_id]
      }
    end)
  end

  defp settlement_class(:public), do: "set-public"
  defp settlement_class(:stealth), do: "set-stealth"
  defp settlement_class(:shielded), do: "set-shielded"

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
      <p class="body-text mb-10 max-w-2xl">Full framework or just the parts that matter.</p>

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
    <section class="landing-section px-6 py-14 md:py-24 max-w-5xl mx-auto" aria-labelledby="faq-title">
      <span class="section-eyebrow">FAQ</span>
      <h2 id="faq-title" class="heading-2xl mb-10">Questions, answered.</h2>
      <div class="faq-list max-w-3xl">
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
    <section class="landing-section px-6 py-12 md:py-20 max-w-5xl mx-auto" aria-labelledby="try-title">
      <h2 id="try-title" class="heading-2xl mb-3">One module away from every surface.</h2>
      <p class="body-text mb-10 max-w-2xl">Starting is genuinely four commands.</p>

      <div class="space-y-3 mb-10 ch-snap">
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
      <div class="max-w-5xl mx-auto">
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
