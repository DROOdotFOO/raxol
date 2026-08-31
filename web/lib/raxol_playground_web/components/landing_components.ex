defmodule RaxolPlaygroundWeb.LandingComponents do
  @moduledoc """
  Sections of the raxol.io landing page, extracted from LandingLive so that
  the LiveView is just lifecycle (mount, handle_event, handle_info, render
  orchestration) and the markup lives here.

  The counter and agent code samples are owned by this module: it stores
  them as `~S\"""...\"""` literals, runs them through Makeup at compile time,
  and exposes the highlighted HTML through Components that don't take any
  attributes. Callers don't need to know either source exists.

  Components that take attributes (nav_bar, screen_hero) receive only
  LiveView-driven state (mobile_menu_open, raxol_version, terminal_html).
  """
  use Phoenix.Component

  alias Raxol.UI.Components.Harness.AxolFace
  alias RaxolPlayground.BrandMarks
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

  # The hero examples, kept short so the whole program fits one screen. Each is
  # byte-identical to the module `scripts/gen_landing_frames.exs` records into
  # priv/hero_frames/<name>/; edit one, rerun the script, or the pane and the
  # frames stop being the same program.
  @pulse_source ~S"""
  defmodule Pulse do
    use Raxol.Core.Runtime.Application

    def init(_), do: %{t: 0}
    def update(:tick, m), do: {%{m | t: m.t + 1}, []}
    def update(_, m), do: {m, []}
    def subscribe(_), do: [subscribe_interval(90, :tick)]

    def view(m) do
      line_chart(series: series(m.t), width: 60, height: 12)
    end

    defp series(t) do
      [
        %{name: "sine", data: wave(t, &:math.sin/1), color: :cyan},
        %{name: "cos", data: wave(t, &:math.cos/1), color: :magenta}
      ]
    end

    defp wave(t, f),
      do: for(i <- 0..29, do: round(50 + 35 * f.((t + i) * 0.2)))
  end
  """

  # The page's own mark, as a program. The canvas version rasterizes the face
  # glyph and dithers around it; a terminal needs no rasterizer, because the
  # face IS characters there -- so the program is the drift field and a hole
  # for the face to sit in.
  @halo_source ~S"""
  defmodule Halo do
    use Raxol.Core.Runtime.Application

    @ramp ["·", ":", "-", "=", "+", "*", "#", "%"]
    @faces ["≡··≡", "≡''≡", "≡oo≡", "≡^^≡"]
    @a 374_761_393
    @b 668_265_263

    def init(_), do: %{t: 0}
    def update(:tick, m), do: {%{m | t: m.t + 1}, []}
    def update(_, m), do: {m, []}
    def subscribe(_), do: [subscribe_interval(110, :tick)]

    def view(m) do
      column(do: for(y <- 0..12, do: text(scan(m.t, y), fg: :cyan)))
    end

    defp scan(t, y), do: for(x <- 0..67, into: "", do: cell(t, x, y))

    defp cell(t, x, 6) when x in 32..35,
      do: String.at(Enum.at(@faces, rem(div(t, 6), 4)), x - 32)

    defp cell(_t, x, y) when abs(y - 6) <= 1 and x in 29..38, do: " "

    defp cell(t, x, y) do
      n = rem(abs((x + div(t, 2)) * @a + (y - div(t, 3)) * @b), 9973)
      v = n / 9973 * min(1.0, abs(x - 34) / 34 + abs(y - 6) / 6)
      if v < 0.2, do: " ", else: Enum.at(@ramp, trunc(v * 7))
    end
  end
  """

  # Lines and columns come from the SOURCE, not the highlighted HTML: Makeup
  # wraps every line in markup, so counting there measures the highlighter. The
  # pane sizes its type from both, so the module fits whole on either axis
  # rather than running off the right edge behind a hidden scrollbar.
  @hero_examples (for {name, file, source} <- [
                        {"pulse", "pulse.ex", @pulse_source},
                        {"halo", "halo.ex", @halo_source}
                      ] do
                    lines = source |> String.trim() |> String.split("\n")

                    {name, file, Makeup.highlight_inner_html(source),
                     %{
                       lines: length(lines),
                       cols: lines |> Enum.map(&String.length/1) |> Enum.max()
                     }}
                  end)

  @counter_code Makeup.highlight_inner_html(@counter_source)
  @agent_code Makeup.highlight_inner_html(@agent_source)
  # Counted from the registry `Xochi.Capabilities.fallback/0` derives from, so
  # the headline cannot claim a corridor the solver does not have. Tron is
  # reached over the relay rail rather than this table and is not counted.
  @network_count length(Raxol.Payments.Assets.supported_chain_ids())

  @install_command "curl -fsSL https://raxol.io/install | bash"
  @brew_command "brew install droodotfoo/tap/raxol"
  @npm_command "npm i -g raxol"

  # The hero halo's face cycles the coding agent's REAL status glyphs:
  # AxolFace.glyph/3 is the single source of truth every surface renders,
  # and exporting its frames here keeps the page and the product in
  # agreement. Four wrapped frames per state (cycles are 4/3/2/1 long, and
  # the TUI wraps the same way).
  @halo_faces Jason.encode!(
                for state <- [:idle, :thinking, :working, :done] do
                  %{state: state, frames: for(f <- 0..3, do: AxolFace.glyph(state, f))}
                end
              )

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
  # The one-screen landing: header / hero / footer, sized to the viewport.
  #
  # The rule these three obey is that nothing here scrolls. Anything that
  # wants more room than a screen belongs on a page of its own -- the deep
  # dives moved to `TopicLive`, the demos to /gallery -- and this page links
  # to them rather than restating them.
  # ---------------------------------------------------------------------------

  attr(:mobile_menu_open, :boolean, required: true)

  def screen_header(assigns) do
    ~H"""
    <header class="screen-header" role="banner">
      <%!-- The bar spans the viewport so its rule does; the row inside it is
           held to the same measure as the hero, so the mark starts on the
           h1's column instead of out in the gutter. --%>
      <div class="screen-bar">
        <a href="/" class="screen-mark">raxol</a>

        <nav class="screen-nav" aria-label="Main navigation">
          <a :for={{href, label} <- nav_links()} href={href} class="nav-link">{label}</a>
        </nav>

        <button
          type="button"
          phx-click="toggle_mobile_menu"
          class="screen-menu-btn"
          aria-label={if @mobile_menu_open, do: "Close menu", else: "Open menu"}
          aria-expanded={to_string(@mobile_menu_open)}
          aria-controls="screen-mobile-nav"
        >
          <span aria-hidden="true">{if @mobile_menu_open, do: "close", else: "menu"}</span>
        </button>
      </div>

      <%!-- Outside the measured row: the overlay spans the header's full width
           and anchors to it, so it drops directly under the button. --%>
      <nav
        :if={@mobile_menu_open}
        id="screen-mobile-nav"
        class="screen-nav-mobile"
        aria-label="Main navigation"
      >
        <a :for={{href, label} <- nav_links()} href={href} class="nav-link">{label}</a>
        <a :for={{path, label} <- topic_links()} href={path} class="nav-link">{label}</a>
      </nav>
    </header>
    """
  end

  attr(:example, :string, required: true)

  def screen_hero(assigns) do
    assigns = assign(assigns, halo_faces: @halo_faces, network_count: @network_count)

    ~H"""
    <%!-- The brand mark beside the claim rather than above it: an upright box
         of dithered character cells, which reads as a column of the same
         monospace grid the demo below is made of. Decoration -- aria-hidden,
         reduced-motion aware client-side -- and the h1 carries the meaning. --%>
    <div class="screen-intro">
      <div
        id="hero-halo"
        phx-hook="HaloField"
        phx-update="ignore"
        class="hero-halo screen-halo"
        aria-hidden="true"
        data-faces={@halo_faces}
      >
        <canvas></canvas>
      </div>

      <div class="screen-intro__text">
        <h1 class="screen-title">
          One module, every surface.
          <span class="text-axol-coral">Agent, harness, and payments included.</span>
        </h1>

        <p class="screen-sub">
          Each ships as its own Hex package: take the runtime, the AI agent, the
          coding harness, or private settlement across <%= @network_count %> networks.
        </p>

        <div class="screen-install">
          <.copyable_command
            id="screen-install-cmd"
            command="curl -fsSL https://raxol.io/install | bash"
            tone={:coral}
          />
        </div>
      </div>
    </div>

    <.hero_demo example={@example} />
    """
  end

  @doc """
  The integrations row, grouped, with empty groups dropped.

  Every entry derives from `Capabilities`: models from the agent's own provider
  registry, editors from the ACP client list gated on raxol's own ACP surface
  being compiled in. Nothing here is written down twice, so a new backend
  reaches the landing page without an edit. Public so a test can hold the
  rendered row against its source.

  Only things with a vendor behind them. The surfaces belong to raxol rather
  than to anyone it integrates with, and half of them (terminal, ssh, watch,
  speech) are concepts with no mark to show, so they are the h1's business and
  not this row's.
  """
  @spec integration_groups() :: [{String.t(), [map()]}]
  def integration_groups do
    editors = Enum.map(Capabilities.acp_editors(), &%{name: &1, label: &1})

    [
      {"models", Capabilities.connectable_providers()},
      {"acp editors", editors}
    ]
    |> Enum.reject(fn {_label, entries} -> entries == [] end)
    |> Enum.map(fn {group, entries} ->
      {group, Enum.map(entries, &Map.put(&1, :mark, BrandMarks.path(&1.name)))}
    end)
  end

  @doc """
  Reinforcement under the argument, in the band the capped demo frees.

  A sibling of the hero rather than part of it: the hero must not say "ACP"
  (it claims four surfaces and an ACP tab is not one of them) and this row
  names ACP editors, so a test holds them apart.

  Each entry shows its mark and reveals its name on hover. The name is always
  in the markup, never swapped in by script: it is what a screen reader reads,
  what an entry with no mark shows outright, and what sets the item's width, so
  the cross-fade cannot reflow a moving row.
  """
  def screen_integrations(assigns) do
    assigns = assign(assigns, groups: integration_groups())

    ~H"""
    <%!-- Two identical runs, so translating the track by half its width loops
         seamlessly. The copy is aria-hidden -- it exists for the animation,
         and a screen reader reading the list twice would be a defect. --%>
    <div class="screen-integrations">
      <div class="integrations-track">
        <div
          :for={dup? <- [false, true]}
          class={["integrations-run", dup? && "integrations-run--dup"]}
          aria-hidden={dup? && "true"}
        >
          <span :for={{label, entries} <- @groups} class="integrations-group">
            <span class="integrations-label">{label}</span>
            <span
              :for={entry <- entries}
              class={["integrations-item", entry.mark && "integrations-item--marked"]}
            >
              <svg
                :if={entry.mark}
                class="integrations-mark"
                viewBox="0 0 24 24"
                aria-hidden="true"
                focusable="false"
              >
                <path d={entry.mark} fill="currentColor" />
              </svg>
              <%!-- The reveal has room the row does not, so it shows the
                   registry's own label. The short head is what fits in the
                   flow, but it is also the part that cannot tell "Claude
                   (subscription, via CLI)" from "Anthropic (Claude)". --%>
              <span class="integrations-name">{if entry.mark, do: entry.label, else: entry.name}</span>
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  def screen_footer(assigns) do
    ~H"""
    <footer class="screen-footer" role="contentinfo">
      <div class="screen-bar">
        <nav class="screen-topics" aria-label="Deep dives">
          <a :for={{path, label} <- topic_links()} href={path} class="topic-link">{label}</a>
        </nav>

        <span class="screen-meta">
          v{Capabilities.version_minor()} &middot; {Capabilities.package_count()} packages &middot;
          <a href="https://hex.pm/packages/raxol" class="subtle-link">Hex</a>
        </span>
      </div>
    </footer>
    """
  end

  # The deep-dive pages, in one place so the header and footer cannot list
  # different ones. `TopicLive` owns the paths; this only borrows them.
  defp topic_links, do: RaxolPlaygroundWeb.TopicLive.links()

  # One list for both site headers. The landing carried four links and the
  # topic pages six, so the navigation changed shape when a reader crossed
  # between them and neither list knew the other existed.
  @nav_links [
    {"/playground", "Playground"},
    {"/gallery", "Gallery"},
    {"/demos", "Demos"},
    {"https://hexdocs.pm/raxol", "Docs"},
    {"/skill.md", "Skill"},
    {"https://github.com/DROOdotFOO/raxol", "GitHub"}
  ]

  @doc "Site navigation as `{href, label}`. Both headers render exactly this."
  @spec nav_links() :: [{String.t(), String.t()}]
  def nav_links, do: @nav_links

  # ---------------------------------------------------------------------------
  # Navigation
  # ---------------------------------------------------------------------------

  attr(:mobile_menu_open, :boolean, required: true)

  def nav_bar(assigns) do
    ~H"""
    <%!-- A banner landmark around the navigation, not a bare nav. The topic
         pages had no `header` at all, so the one region a screen reader jumps
         to first did not exist on five of them, and the brand link sat outside
         any landmark. Matches `screen_header` on the landing. --%>
    <header class="sticky top-0 z-50 surface-bar" role="banner">
      <div class="measure py-3 flex items-center justify-between">
        <a href="/" class="font-mono text-lg font-bold text-axol-coral tracking-wide">
          raxol
        </a>
        <nav
          class="hidden md:flex items-center gap-6 text-sm font-mono tracking-wide"
          aria-label="Main navigation"
        >
          <a :for={{href, label} <- nav_links()} href={href} class="nav-link">{label}</a>
        </nav>
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
        <nav
          id="mobile-navigation"
          class="md:hidden px-6 py-4 flex flex-col gap-4 text-sm font-mono border-t border-subtle text-pearl-60"
          aria-label="Main navigation"
        >
          <a :for={{href, label} <- nav_links()} href={href}>{label}</a>
        </nav>
      <% end %>
    </header>
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

      <%!-- Only channels that exist get a link: the script this site
           serves, and the published Hex package. brew/npm links land
           when the tap repo and npm package publish. --%>
      <div class="install-pane" data-m="curl">
        <.ssh_copy_block id="install-copy-curl" cmd={@curl_cmd} />
        <p class="label-text mt-3">
          Self-contained binary. macOS and Linux. Click to copy.
          <a href="/install" class="install-link">read the script</a>
        </p>
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
        <p class="label-text mt-3">
          Add to mix.exs in an existing Elixir app.
          <a href="https://hex.pm/packages/raxol" class="install-link">view on Hex</a>
        </p>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # 1b. Hero demo: one module, four surfaces
  #
  # The four panes are four encodings of ONE render, all projected from the
  # frame-zero buffer of the same `Raxol.Headless` session, the way
  # `Raxol.Harness.Surface.Parity` projects a fixture onto cells, LiveView
  # DOM, SSH ANSI and MCP JSON. None is authored: the browser pane is the
  # source of the markup the terminal pane renders, and the other two come
  # from committed artifacts (see `RaxolPlayground.SurfaceSource`).
  #
  # No ACP tab. ACP is the coding agent's editor protocol, not a surface a
  # TEA module renders to, so a pane captioned "pulse, driven over ACP" would
  # describe a program that does not exist. It has its own page.
  #
  # All four panes are server-rendered; the HeroDemo hook only toggles
  # `hidden`/aria-selected, auto-advancing tabs and stepping the recorded
  # frames on a fixed-timestep rAF accumulator. Clicking a tab stops the
  # auto-advance. Switching examples re-mounts the hook (the element id
  # carries the example name).
  # ---------------------------------------------------------------------------

  attr(:example, :string, required: true)

  def hero_demo(assigns) do
    assigns =
      assign(assigns,
        source: example_code(assigns.example),
        source_grid: example_grid(assigns.example),
        title: example_title(assigns.example),
        frames: RecordedFrames.hero_frames(assigns.example),
        frame_grid: RecordedFrames.hero_frame_grid(assigns.example),
        next: next_example(assigns.example),
        out_browser: RecordedFrames.hero_surface(assigns.example, :browser),
        out_ssh: RecordedFrames.hero_surface(assigns.example, :ssh),
        out_mcp: RecordedFrames.hero_surface(assigns.example, :mcp),
        browser_lines: RecordedFrames.hero_surface_lines(assigns.example, :browser),
        ssh_grid: RecordedFrames.hero_ssh_grid(assigns.example),
        mcp_lines: RecordedFrames.hero_surface_lines(assigns.example, :mcp)
      )

    ~H"""
    <%!-- The id carries the example so switching remounts the hook: the frame
         player caches its frame nodes, and patching them underneath it would
         leave it stepping elements that no longer exist. --%>
    <div id={"hero-demo-#{@example}"} phx-hook="HeroDemo" class="hero-demo mx-auto text-left">
      <%!-- The player's controls live in the title bar, where a window's
           controls belong and where nothing can clip them. They used to sit in
           a footer below the panes: the demo box is height-capped, so on any
           viewport too short for the one-screen layout the panes overflowed it
           and `overflow: hidden` swallowed the footer whole -- the pause button
           and the example switcher were unreachable, and scrolling did not help
           because they were clipped in place rather than below the fold. --%>
      <div class="hero-demo-bar">
        <span class="hd-dot"></span><span class="hd-dot"></span><span class="hd-dot"></span>
        <span class="hd-title" data-role="title">{@title} -- rendering to the terminal</span>

        <div class="hd-controls">
          <button type="button" data-role="player-pause" class="hd-control">pause</button>
          <button type="button" phx-click="next_example" class="hd-control hd-control--next">
            {example_title(@next)} &rarr;
          </button>
        </div>
      </div>

      <div class="hero-tabs" role="tablist" aria-label="Render surface">
        <button type="button" class="hero-tab" role="tab" aria-selected="true" data-i="0" data-title={"#{@title} -- rendering to the terminal"} data-label="Rendered to the terminal">Terminal</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="1" data-title={"#{@title} -- rendering to Phoenix LiveView"} data-label="The DOM LiveView patches">Browser</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="2" data-title={"#{@title} -- served over SSH"} data-label="The same frame, painted down a channel">SSH</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="3" data-title={"#{@title} -- exposed as MCP tools"} data-label="The tree an agent reads">Agent / MCP</button>
      </div>

      <div class="hero-panes">
        <div class="hero-pane">
          <%!-- The examples differ in length, and the pane is a fixed slice
               of one screen, so the type size follows the line count rather
               than being tuned per example. --%>
          <pre class="hero-code" style={"--hero-lines: #{@source_grid.lines}; --hero-cols: #{@source_grid.cols}"}><code class="syntax-elixir">{raw(@source)}</code></pre>
        </div>

        <div class="hero-pane">
          <div class="hero-out" data-surface="0">
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix run {@example}.exs</span></pre>
            <%!-- Recorded frames: real Headless output of the module beside
                 them, committed under priv/hero_frames/<example>/. Frame one
                 ships visible in the dead render; the hook steps the rest. --%>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
              <div :for={{frame, i} <- Enum.with_index(@frames)} class="hero-frame" data-frame={i} hidden={i != 0}>{raw(frame)}</div>
            </div>
          </div>

          <%!-- The same frame, re-encoded three ways: the head of a committed
               artifact, clamped with a marker naming what was cut. --%>
          <div class="hero-out" data-surface="1" hidden>
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix phx.server</span></pre>
            <pre class="hero-pre hero-src" style={"--src-lines: #{@browser_lines}"}>{raw(@out_browser)}</pre>
          </div>

          <%!-- SSH is the one non-terminal surface that delivers a picture
               rather than a description of one, so it is painted rather than
               listed: same frame, same colours, same two-axis fit as the
               terminal pane, reached over a channel instead of a local tty.
               That IS the claim the tab makes. --%>
          <div class="hero-out" data-surface="2" hidden>
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ ssh demo@localhost -p 2222</span></pre>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@ssh_grid.rows}; --frame-cols: #{@ssh_grid.cols}"}>
              <pre class="hero-ansi">{raw(@out_ssh)}</pre>
            </div>
          </div>

          <div class="hero-out" data-surface="3" hidden>
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix mcp.server</span></pre>
            <pre class="hero-pre hero-src" style={"--src-lines: #{@mcp_lines}"}>{raw(@out_mcp)}</pre>
          </div>
        </div>
      </div>

    </div>
    """
  end

  @doc "Hero examples in switch order."
  def hero_example_names, do: Enum.map(@hero_examples, &elem(&1, 0))

  defp example_title(name) do
    Enum.find_value(@hero_examples, name, fn {n, t, _c, _l} -> n == name && t end)
  end

  @doc "Line and column counts of one example's source, as the pane sizes from."
  def example_grid(name) do
    Enum.find_value(@hero_examples, %{lines: 1, cols: 1}, fn {n, _t, _c, grid} ->
      n == name && grid
    end)
  end

  defp example_code(name) do
    Enum.find_value(@hero_examples, "", fn {n, _t, c, _l} -> n == name && c end)
  end

  defp next_example(name) do
    names = hero_example_names()
    idx = Enum.find_index(names, &(&1 == name)) || 0
    Enum.at(names, rem(idx + 1, length(names)))
  end

  # ---------------------------------------------------------------------------
  # 2. Proof: counter example
  # ---------------------------------------------------------------------------

  def code_example_section(assigns) do
    assigns = assign(assigns, :counter_code, @counter_code)

    ~H"""
    <section class="landing-section py-12 md:py-20 measure" aria-labelledby="code-title">
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="surfaces-title">
      <div class="mb-10">
        <span class="section-numeral" aria-hidden="true">01</span>
        <span class="section-eyebrow">Surfaces</span>
        <h1 id="surfaces-title" class="heading-2xl mb-3">One module, <%= Capabilities.surface_count() %> surfaces.</h1>
        <p class="body-text max-w-2xl">
          Write the TEA module once. It meets you in three places you already
          are: your terminal, your browser, and wherever your agents work.
          Same model. Same view.
        </p>
      </div>

      <div class="surface-buckets">
        <div class="surface-bucket">
          <h2 class="surface-bucket__label">In your terminal</h2>
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
          <h2 class="surface-bucket__label">In your browser</h2>
          <div class="surface-bucket__chips">
            <div class="surface-chip">
              <span class="surface-chip__name">Browser</span>
              <span class="surface-chip__cmd">Phoenix LiveView</span>
            </div>
          </div>
        </div>

        <div class="surface-bucket">
          <h2 class="surface-bucket__label">Where your agents are</h2>
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="ssh-deep-title">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-8 md:gap-12 items-center">
        <div>
          <span class="section-numeral" aria-hidden="true">02</span>
          <span class="section-eyebrow">SSH surface</span>
          <h1 id="ssh-deep-title" class="heading-2xl mb-3">Serve the same app over SSH.</h1>
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="agent-deep-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">03</span>
        <span class="section-eyebrow">Agent runtime</span>
        <h1 id="agent-deep-title" class="heading-2xl mb-3">Agents are TEA apps.</h1>
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="coding-agent-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">04</span>
        <span class="section-eyebrow">Coding agent</span>
        <h1 id="coding-agent-title" class="heading-2xl mb-3">raxol speaks ACP.</h1>
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

  # What each tier must PROVE, beyond reaching the score. The proofs are
  # `Raxol.Payments.FeeSchedule.tier_attestation_requirements/0`; this is the
  # prose for them.
  @tier_proofs %{
    standard: "no proof required",
    trusted: "no proof required",
    verified: "compliance proof",
    premium: "compliance + non-membership",
    institutional: "compliance + non-membership"
  }

  # Authored commentary on solver rails the matrix data does not carry.
  @chain_notes %{4663 => "Permit2 pull", 728_126_428 => "relay rail"}

  # Checked against Robinhood Chain's RPC, not an aggregator: eth_chainId
  # 0x1237 (4663), symbol() "RAXOL", decimals() 18, and the pool's
  # token0/token1 are VIRTUAL and this token. Re-verify before editing.
  #
  # Durable facts only. A market number would be stale by the next request.
  @token %{
    symbol: "RAXOL",
    address: "0xf44702b17d9abD53815F703e772F35E9c71A53af",
    chain_name: "Robinhood Chain",
    chain_id: 4663,
    quote: "VIRTUAL",
    venue: "Uniswap",
    pool: "0xa20b68e2e1de71f1426b546ed5514bf253215a48"
  }

  @token_pair_url "https://dexscreener.com/robinhood/#{@token.pool}"

  # Stables lead, WETH trails; unknown symbols land after, alphabetically.
  @token_order %{"USDC" => 0, "USDT" => 1, "USDG" => 2, "WETH" => 3}

  @payments_version Enum.find_value(Capabilities.packages(), fn
                      %{name: "raxol_payments", version: v} -> String.replace(v, "~> ", "")
                      _ -> nil
                    end)

  attr(:matrix, :map, required: true)

  def payments_deep_dive(assigns) do
    # Fees come from `Raxol.Payments.FeeSchedule`, the mirror of Riddler's
    # FeePolicy that is pinned to the same generated schedule the Riddler SDK
    # checks itself against. They used to come from `PrivacyTier`, which prices
    # a different (retired) model: it put a table on this page that no tier has
    # ever charged, including a `0 bps -- no fee` row that the never-discounted
    # solver floor makes impossible.
    assigns =
      assign(assigns,
        tiers: Raxol.Payments.FeeSchedule.all(),
        tier_proofs: @tier_proofs,
        solver_floor: Raxol.Payments.FeeSchedule.solver_base_bps(),
        payments_version: @payments_version,
        token: @token,
        token_pair_url: @token_pair_url,
        rows: reach_rows(assigns.matrix),
        show_future_svm: not Enum.any?(assigns.matrix.chains, &(&1.vm_type == :svm)),
        live?: assigns.matrix.source == :live
      )

    ~H"""
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="payments-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">05</span>
        <span class="section-eyebrow">Agent payments</span>
        <h1 id="payments-title" class="heading-2xl mb-3">Agents that settle, privately.</h1>
        <p class="body-text max-w-2xl">
          First funded cross-chain settlement on 2026-06-28; the USDC transfer
          offering has been live on Base since 2026-07-20. What a transfer costs
          is set by the agent's trust score and by what it is moving -- the rates
          below are the solver's own published schedule, mirrored in
          <code>Raxol.Payments.FeeSchedule</code> and pinned to it in CI.
        </p>
        <p class="caption-text mt-3">
          Early, and labeled: the payments packages are at <%= @payments_version %> beside a 2.6
          core. Dated on-chain events over claims.
        </p>
      </div>

      <div class="ladder mb-4" role="table" aria-label="Fee tiers">
        <div class="rung rung--head" role="row">
          <span role="columnheader">Tier</span>
          <span role="columnheader">Trust score</span>
          <span role="columnheader">Stable</span>
          <span role="columnheader">Volatile</span>
          <span role="columnheader">Proof</span>
        </div>
        <div :for={tier <- @tiers} class="rung" role="row">
          <span class="rung__tier" role="cell"><%= tier.tier %></span>
          <span class="rung__note" role="cell"><%= score_band(tier) %></span>
          <span class="rung__fee" role="cell"><%= tier.stable_bps %> bps</span>
          <span class="rung__fee" role="cell"><%= tier.volatile_bps %> bps</span>
          <span class="rung__note" role="cell"><%= @tier_proofs[tier.tier] %></span>
        </div>
      </div>

      <p class="caption-text max-w-2xl mb-10">
        Three additive layers: the solver spread, the Xochi venue cut, and the
        raxol routing cut. A tier discounts the venue and routing layers only --
        the solver spread (<%= @solver_floor.stable %> bps stable,
        <%= @solver_floor.volatile %> bps volatile) is never discounted, because
        it is the floor that keeps a fill cash-positive. There is no zero-fee
        tier. An intent that originates from an ACP job pays no routing layer:
        that cut is already in the job budget.
      </p>

      <h2 class="name-coral mb-2">Privacy is a settlement mode, not a price</h2>
      <p class="body-text-dim max-w-2xl mb-10">
        Every corridor settles one of three ways, and the choice is independent
        of the fee tier: <strong>public</strong> on the destination chain,
        <strong>stealth</strong> to a one-time address derived per payment
        (ERC-5564), or <strong>shielded</strong> as a note posted into an Aztec
        execution environment. Trust is proven with zero-knowledge attestations
        rather than disclosed, so reaching a lower-fee tier reveals less about
        the agent, not more.
      </p>

      <h2 class="name-coral mb-2">Reach, from the solver's own matrix</h2>
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
            <%!-- The badge, not the dimming, is what says this corridor is not
                 live. Greying alone said it in colour only, at a contrast a
                 reader could not clear, so the one row that needed reading
                 most was the hardest to read. --%>
            <div :if={@show_future_svm} class="reach-row reach-row--future">
              <span class="reach-row__name">Solana</span>
              <span class="reach-row__id">--</span>
              <span class="reach-row__vm">SVM</span>
              <span class="reach-row__note">
                <span class="tok tok--soon">not yet</span>
                lights up when the solver ships it, zero redeploy
              </span>
            </div>
          </div>
        </div>
        <div class="reach-foot">
          every corridor settles public,
          <span class="set-stealth">stealth</span> (ERC-5564 one-time address), or
          <span class="set-shielded">shielded</span> (Aztec) -- chosen per payment
        </div>
      </div>

      <h2 class="name-coral mb-2 mt-12">${@token.symbol}</h2>
      <p class="body-text-dim max-w-2xl mb-4">
        The project token, on <%= @token.chain_name %>. It is not a settlement
        asset -- the corridors quote, route and settle in stablecoins.
      </p>

      <div class="reach">
        <div class="reach-bar">
          <span><span class="reach-verb">ERC-20</span> <%= @token.chain_name %> (<%= @token.chain_id %>)</span>
          <a href={@token_pair_url} rel="noopener" class="src-badge">live pair &rarr;</a>
        </div>
        <div class="token-facts">
          <div class="token-fact">
            <span class="token-fact__key">token</span>
            <code class="token-fact__val"><%= @token.address %></code>
          </div>
          <div class="token-fact">
            <span class="token-fact__key">pool</span>
            <code class="token-fact__val"><%= @token.pool %></code>
          </div>
          <div class="token-fact">
            <span class="token-fact__key">pair</span>
            <span class="token-fact__val">
              <%= @token.symbol %> / <%= @token.quote %> on <%= @token.venue %>
            </span>
          </div>
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

  # The top tier is open-ended, so it reads as a threshold rather than a band.
  defp score_band(%{min_score: min, max_score: nil}), do: "#{min} and above"
  defp score_band(%{min_score: min, max_score: max}), do: "#{min}-#{max}"

  # ---------------------------------------------------------------------------
  # 4. Features grid (numbered)
  # ---------------------------------------------------------------------------

  def features_section(assigns) do
    ~H"""
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="features-title">
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
      <h2 class="name-coral mb-2"><%= @title %></h2>
      <p class="detail-text leading-relaxed"><%= @description %></p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # 5. Packages
  # ---------------------------------------------------------------------------

  def packages_section(assigns) do
    ~H"""
    <section class="landing-section py-12 md:py-20 measure" aria-labelledby="packages-title">
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="faq-title">
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
    <section class="landing-section py-12 md:py-20 measure" aria-labelledby="try-title">
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

  @doc """
  The topic pages' footer: a signature, not a second navigation.

  It used to carry GitHub, Hex.pm, Docs, Playground and Skill. Four of those
  five are in `nav_links/0`, three inches above on the same page, so the row
  restated the header rather than adding to it -- a third of the page's links
  pointing where the header already pointed. Hex.pm was the one destination it
  owned, and the landing footer's meta line already carries it.
  """
  def footer_section(assigns) do
    ~H"""
    <footer class="landing-section py-16 border-t border-subtle" role="contentinfo">
      <div class="measure flex items-center justify-end font-mono caption-text tracking-wide">
        <span>Made by <a href="https://axol.io" class="axol-link">axol.io</a></span>
      </div>
    </footer>
    """
  end
end
