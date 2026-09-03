defmodule RaxolPlaygroundWeb.LandingComponents do
  @moduledoc """
  Sections of the raxol.io landing page, extracted from LandingLive so that
  the LiveView is just lifecycle (mount, handle_event, handle_info, render
  orchestration) and the markup lives here.

  The code samples are owned by this module: it stores them as `~S\"""...\"""`
  literals, runs them through Makeup at compile time, and exposes the
  highlighted HTML through Components that don't take any attributes. Callers
  don't need to know the sources exist.

  Components that take attributes (nav_bar, screen_hero) receive only
  LiveView-driven state (mobile_menu_open, raxol_version, terminal_html).
  """
  use Phoenix.Component

  alias Raxol.UI.Components.Harness.AxolFace
  alias RaxolPlayground.BrandMarks
  alias RaxolPlayground.NetworkMarks
  alias RaxolPlayground.Capabilities
  alias RaxolPlayground.RecordedFrames
  import Phoenix.HTML, only: [raw: 1]

  import RaxolPlaygroundWeb.PlaygroundComponents,
    only: [copyable_command: 1, terminal_chrome: 1]

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
    alias Raxol.UI.Components.Harness.AxolFace

    @ramp ["·", ":", "-", "=", "+", "*", "#", "%"]
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
      do: String.at(AxolFace.glyph(:thinking, div(t, 6)), x - 32)

    defp cell(_t, x, y) when abs(y - 6) <= 1 and x in 29..38, do: " "

    defp cell(t, x, y) do
      n = rem(abs((x + div(t, 2)) * @a + (y - div(t, 3)) * @b), 9973)
      v = n / 9973 * min(1.0, abs(x - 34) / 34 + abs(y - 6) / 6)
      if v < 0.2, do: " ", else: Enum.at(@ramp, trunc(v * 7))
    end
  end
  """

  # The coding agent, as the harness's own components render it: the rows are
  # `ToolCallBlock`, the module `mix raxol.code` draws a tool call with, rather
  # than a picture of one -- so the glyph, the spinner and the layout are the
  # product's. What is authored is the turn (which tools, in what state), the
  # way `pulse` authors a wave.
  #
  # The job line above the turn is the other half of the story raxol_earn
  # tells: agents do not only spend, they sell services on the Virtuals Agent
  # Commerce Protocol and get paid for them, and the harness is how the work
  # a job was funded for actually gets done. It stays authored text rather
  # than a call into `Raxol.Earn`, because the web app does not depend on
  # raxol_earn and `RaxolEarn.Application` self-starts outside `:test` -- a
  # dependency edge added for one line of a hero pane would start a seller
  # supervision tree in the deployed site.
  #
  # The turn finishes rather than sitting on `edit` forever with only the
  # spinner moving, which read as a hang once `settle` beside it started
  # completing. `@ladder` is the dwell per frame, uneven so `edit` holds long
  # enough to read. The statuses come from the tick, so `@calls` carries name
  # and args only and `st/2` decides done, running or pending -- that, and the
  # shorter alias, is what fits: the pane clips at thirty lines and sixty-seven
  # columns.
  #
  # The job is a paid coding job, not `usdc_transfer`. A pane that announced a
  # transfer offering and then edited `router.ex` described no one's work: the
  # harness earns by doing the thing it is good at, so the job is a bugfix at a
  # price, and the calls are that bugfix.
  @harness_source ~S"""
  defmodule Harness do
    use Raxol.Core.Runtime.Application
    alias Raxol.UI.Components.Harness.ToolCallBlock, as: T
    @calls [
      {"read", "spend_gate.ex"},
      {"edit", "spend_gate.ex:42"},
      {"shell", "mix test"}
    ]
    @ladder [0, 0, 1, 1, 1, 1, 1, 2, 2, 3]
    def init(_), do: %{t: 0}
    def update(:tick, m), do: {%{m | t: m.t + 1}, []}
    def update(_, m), do: {m, []}
    def subscribe(_), do: [subscribe_interval(200, :tick)]
    def view(m) do
      at = Enum.at(@ladder, rem(m.t, length(@ladder)))
      column style: %{gap: 1} do
        [
          text("virtuals acp  bugfix  40.00 USDC", fg: :cyan),
          column(do: Enum.with_index(@calls, &call(&1, &2, at, m.t)))
        ]
      end
    end
    defp call({n, a}, i, x, t) do
      {:ok, s} = T.init(name: n, args: a, status: st(i, x), frame: t)
      T.render(s, %{})
    end
    defp st(i, x) when i < x, do: :done
    defp st(i, i), do: :running
    defp st(_, _), do: :pending
  end
  """

  # Payments as an operator receipt, not a toy progress list. The Arc corridor
  # is testnet-only until Xochi publishes it in capabilities, so this pane names
  # the funded-run shape and the Blockscout chains without inventing tx hashes.
  @settle_source ~S"""
  defmodule Settle do
    use Raxol.Core.Runtime.Application
    @route "USDC 1.10  Base Sepolia 84532 -> Arc Testnet 5042002"
    @steps [
      {"spend gate", "before signature"},
      {"intent", "EIP-712 quote signed"},
      {"execution", "submitted to solver"},
      {"source tx", "base-sepolia.blockscout.com/tx"},
      {"dest tx", "testnet.arcscan.app/tx"}
    ]
    def init(_), do: %{t: 0}
    def update(:tick, m), do: {%{m | t: m.t + 1}, []}
    def subscribe(_), do: [subscribe_interval(200, :tick)]
    def view(m) do
      at = rem(m.t, length(@steps))
      head = [
        text("XOCHI RECEIPT", style: [:bold]),
        text(@route, fg: :magenta)
      ]
      column(do: head ++ Enum.with_index(@steps, &step(&1, &2, at)))
    end
    defp step({k, v}, i, at) do
      mark = if(i == at, do: ">", else: " ")
      key = String.pad_trailing(k, 10)
      text("#{mark} [OK] #{key} #{v}", fg: :cyan)
    end
  end
  """

  # Lines and columns come from the SOURCE, not the highlighted HTML: Makeup
  # wraps every line in markup, so counting there measures the highlighter. The
  # pane sizes its type from both, so the module fits whole on either axis
  # rather than running off the right edge behind a hidden scrollbar.
  #
  # The module name is read out of the source for the same reason. The browser
  # pane heads its embedded page with it, and a name typed a second time here
  # would be free to stop matching the `defmodule` line the pane beside it
  # shows.
  #
  # The blurb is the other half of the h1's bargain. The headline names four
  # things and the rotation runs one program per thing, but a reader landing on
  # `settle.ex` cannot be expected to infer which noun it is answering, so each
  # example says so in the title bar.
  @hero_examples (for {name, file, blurb, source} <- [
                        {"settle", "settle.ex", "gate, EIP-712, solver, explorers",
                         @settle_source},
                        {"pulse", "pulse.exs", "one module, four surfaces", @pulse_source},
                        {"halo", "halo.exs", "the mark, as a program", @halo_source},
                        {"harness", "harness.ex",
                         "a Virtuals ACP job, worked by the coding agent", @harness_source}
                      ] do
                    [_, module] = Regex.run(~r/defmodule (\w+)/, source)

                    lines = source |> String.trim() |> String.split("\n")

                    {name, file, module, blurb, Makeup.highlight_inner_html(source),
                     %{
                       lines: length(lines),
                       cols: lines |> Enum.map(&String.length/1) |> Enum.max()
                     }}
                  end)

  @agent_code Makeup.highlight_inner_html(@agent_source)

  # Named once: the footer reaches for it as a mark, as a link to the package
  # directory behind the count beside it, and it used to be a nav entry too.
  @repo_url "https://github.com/DROOdotFOO/raxol"

  @install_command "curl -fsSL https://raxol.io/install | bash"

  # The hero halo's face cycles the coding agent's REAL status glyphs:
  # AxolFace.glyph/3 is the single source of truth every surface renders,
  # and exporting its frames here keeps the page and the product in
  # agreement. Four wrapped frames per state (cycles are 4/3/2/1 long, and
  # the TUI wraps the same way).
  @halo_faces Jason.encode!(
                for state <- [:idle, :thinking, :working, :done] do
                  %{
                    state: state,
                    frames: for(f <- 0..3, do: AxolFace.glyph(state, f))
                  }
                end
              )

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
      </nav>
    </header>
    """
  end

  attr(:example, :string, required: true)

  def screen_hero(assigns) do
    assigns =
      assign(assigns, halo_faces: @halo_faces, install_command: @install_command)

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
        <%!-- Names the concrete projection set without making the h1 carry a
             comma train. The receipt demo below is payments; this line keeps
             the first read on the core surface claim. --%>
        <h1 class="screen-title">
          One Elixir module.
          <span class="screen-title__claim text-axol-coral">
            Every surface, one runtime.
          </span>
        </h1>

        <p class="screen-sub">
          Runtime, agent harness, and payment rails run on OTP. Render to terminal,
          LiveView, SSH, MCP, Telegram, Watch, and Speech.
        </p>



        <div class="screen-install">
          <.copyable_command id="screen-install-cmd" command={@install_command} tone={:coral} />
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

    # Labelled "agent commerce" rather than by its protocol's name, which is
    # also ACP: the group beside it is Agent CLIENT Protocol editors and this
    # one is the Agent COMMERCE Protocol, so putting the abbreviation on both
    # would have the row name two unrelated things with one word. Hardcoded
    # rather than derived because raxol_earn is not a dependency of the web
    # app and `RaxolEarn.Application` self-starts outside `:test`.
    #
    # "Virtuals Protocol" in full, never "Virtuals" or "$VIRTUAL": their
    # editorial guide names the short forms specifically, and a partner's own
    # style guide is the one place to take the long name over the short one.
    commerce = [%{name: "Virtuals Protocol", label: "Virtuals Protocol"}]

    # The chains sit here rather than in the hero. They were a logo strip
    # inside it, between the sub-line and the install command, which is the
    # one place a logo wall does not belong: it pushes the command down and
    # dresses the claim in other people's marks. This row is what the page
    # already has for naming what raxol connects to.
    networks =
      Enum.map(NetworkMarks.all(), fn mark ->
        %{name: mark.name, label: mark.name, chain: mark}
      end)

    [
      {"models", Capabilities.connectable_providers()},
      {"acp editors", editors},
      {"agent commerce", commerce},
      {"networks", networks}
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
              class={[
                "integrations-item",
                (entry.mark || entry[:chain]) && "integrations-item--marked"
              ]}
            >
              <svg
                :if={entry.mark}
                class="integrations-mark"
                viewBox="0 0 24 24"
                aria-hidden="true"
                focusable="false"
              >
                <path
                  d={entry.mark}
                  fill="currentColor"
                  fill-rule={BrandMarks.fill_rule(entry.name)}
                />
              </svg>
              <%!-- Chains keep their own fills where every other mark in this
                   row is currentColor. Not a preference: four of the seven
                   knock a white shape out of a coloured field, so one colour
                   collapses figure into ground and Base becomes a plain disc
                   with Optimism's "OP" gone. Held back on opacity instead, so
                   they sit at the row's weight without being redrawn. --%>
              <svg
                :if={entry[:chain]}
                class="integrations-mark integrations-mark--chain"
                viewBox={entry.chain.view_box}
                aria-hidden="true"
                focusable="false"
              >
                {raw(entry.chain.body)}
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
    assigns = assign(assigns, :repo_url, @repo_url)

    ~H"""
    <footer class="screen-footer" role="contentinfo">
      <div class="screen-bar">
        <span class="screen-meta">
          <a href="https://hex.pm/packages/raxol" class="subtle-link">Hex</a>
          <a href="/token" class="subtle-link">$RAXOL</a>
          <.github_mark />
        </span>
      </div>
    </footer>
    """
  end

  @doc """
  The repository, as its mark rather than as a word.

  It used to sit in the header, where it competed with the two links a
  first-time reader actually needs. Down here it is one glyph beside the other
  places the code lives, which is the company it belongs in. The accessible
  name carries the word the mark replaces.
  """
  def github_mark(assigns) do
    assigns =
      assigns
      |> assign(:mark, BrandMarks.site_path("GitHub"))
      |> assign(:repo_url, @repo_url)

    ~H"""
    <a href={@repo_url} class="site-mark" aria-label="raxol on GitHub">
      <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
        <path d={@mark} fill="currentColor" />
      </svg>
    </a>
    """
  end

  # One list for both site headers: run it, or read the API. Product pages live
  # in the hero/demo path and in the docs, not as a second table of contents.
  @nav_links [
    {"/gallery", "Components"},
    {"https://hexdocs.pm/raxol", "Docs"}
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
  # 1. Hero demo: one module, four surfaces
  #
  # The four panes are four encodings of ONE render, all projected from the
  # same `Raxol.Headless` session, the way `Raxol.Harness.Surface.Parity`
  # projects a fixture onto cells, LiveView DOM, SSH ANSI and MCP JSON. Every
  # picture and every listing comes from a committed artifact (see
  # `RaxolPlayground.SurfaceSource`); what a pane puts AROUND one is chrome, in
  # the same sense the `$ mix run` line and the window dots above it are. The
  # browser pane's URL bar and page furniture are that chrome, and the frame
  # inside them is the recording.
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
        blurb: example_blurb(assigns.example),
        frames: RecordedFrames.hero_frames(assigns.example),
        frame_grid: RecordedFrames.hero_frame_grid(assigns.example),
        frame_ms: RecordedFrames.hero_frame_interval(assigns.example),
        next: next_example(assigns.example),
        module: example_module(assigns.example),
        ssh_frames: RecordedFrames.hero_ssh_frames(assigns.example),
        out_mcp: RecordedFrames.hero_surface(assigns.example, :mcp),
        ssh_grid: RecordedFrames.hero_ssh_grid(assigns.example),
        mcp_lines: RecordedFrames.hero_surface_lines(assigns.example, :mcp)
      )

    ~H"""
    <%!-- The id carries the example so switching remounts the hook: the frame
         player caches its frame nodes, and patching them underneath it would
         leave it stepping elements that no longer exist. --%>
    <div
      id={"hero-demo-#{@example}"}
      phx-hook="HeroDemo"
      class="hero-demo mx-auto text-left"
      data-frame-ms={@frame_ms}
    >
      <%!-- The player's controls live in the title bar, where a window's
           controls belong and where nothing can clip them. They used to sit in
           a footer below the panes: the demo box is height-capped, so on any
           viewport too short for the one-screen layout the panes overflowed it
           and `overflow: hidden` swallowed the footer whole -- the pause button
           and the example switcher were unreachable, and scrolling did not help
           because they were clipped in place rather than below the fold. --%>
      <%!-- No window dots. `terminal_chrome/1` in PlaygroundComponents already
           made this call for the rest of the site -- its docstring says it
           drops the fake mac-style red/yellow/green dots for a shell prompt
           that earns its place -- and this bar had put them back. The frames
           below are real recorded output; three grey discs above them are the
           one thing here pretending to be a window. --%>
      <div class="hero-demo-bar">
        <span class="hd-prompt" aria-hidden="true">$</span>
        <%!-- Two spans, because they answer different questions and only one
             of them changes: which program this is (static, and the thing a
             reader loses track of while clicking through surfaces) and which
             surface it is rendering to (rewritten by the tab). --%>
        <%!-- The blurb is its own span so a narrow bar can drop it whole. As
             one string it ellipsed at ~12 characters, spending a row of the
             bar to render "one ..." -- the filename is the part that has to
             survive, and .hd-title already drops itself on the same grounds. --%>
        <%!-- The filename is the link to the file. The pane tells you to
             `mix run pulse.exs`; this is where pulse.exs comes from, and
             hanging it on the name costs the bar no width. `download` because
             the click's job is to put that file on disk, not to open a page
             of source; the arrow says so at rest, where an underline only
             appears on hover. A line of its own below the demo would say it
             better, but the one-screen budget has no row to give and this
             box's overflow clips anything appended to it. --%>
        <span class="hd-name"><a
            href={"/examples/#{@title}"}
            class="hd-file"
            download={@title}
            title={"Download #{@title}, then: mix run #{@title}"}
          >{@title} <span aria-hidden="true">&darr;</span></a><span class="hd-blurb"> &middot; {@blurb}</span></span>
        <span class="hd-title" data-role="title">rendering to the terminal</span>

        <%!-- Ruled off from the captions beside them. The bar reads left to
             right as one run of small mono text, so the two things that are
             actually clickable were indistinguishable from the sentence that
             ends just before them. The transport is a glyph now (`||` and the
             pipe, which the mono stack always has, where a media glyph would
             be a font gamble) and the switcher wears a border, so the bar has
             one label, one icon and one button rather than four phrases. --%>
        <div class="hd-controls">
          <button
            type="button"
            data-role="player-pause"
            class="hd-control hd-control--icon"
            aria-label="Pause the demo"
            title="Pause the demo"
          >||</button>
          <button
            type="button"
            phx-click="next_example"
            class="hd-control hd-control--next"
            aria-label={"Next example: #{example_title(@next)}"}
          >
            Next: {example_title(@next)} <span aria-hidden="true">&rarr;</span>
          </button>
        </div>
      </div>

      <%!-- A real tablist, not four buttons wearing the role. Each tab names
           the panel it controls and only the selected one is in the tab order,
           which is what makes the arrow keys the hook binds the way you move
           between them: the pattern promises a reader that Tab leaves the group
           and the arrows walk it, and half of it announces a selection with
           nothing to step into. The ids carry the example name because the
           whole demo remounts when the example switches, and two mounts sharing
           an id would cross-wire the aria-controls. --%>
      <div class="hero-tabs" role="tablist" aria-label="Render surface">
        <button
          :for={tab <- surface_tabs()}
          type="button"
          class="hero-tab"
          role="tab"
          id={tab_id(@example, tab.i)}
          aria-controls={panel_id(@example, tab.i)}
          aria-selected={to_string(tab.i == 0)}
          tabindex={if tab.i == 0, do: "0", else: "-1"}
          data-i={tab.i}
          data-title={tab.title}
          data-label={tab.label}
        >{tab.name}</button>
      </div>

      <div class="hero-panes">
        <div class="hero-pane">
          <%!-- The examples differ in length, and the pane is a fixed slice
               of one screen, so the type size follows the line count rather
               than being tuned per example. --%>
          <pre class="hero-code" style={"--hero-lines: #{@source_grid.lines}; --hero-cols: #{@source_grid.cols}"}><code class="syntax-elixir">{raw(@source)}</code></pre>
        </div>

        <div class="hero-pane">
          <%!-- `tabindex=0` on each panel is what gives the keyboard somewhere
               to land after the arrows pick a tab. The frames inside are
               aria-hidden decoration, so without it the group would be a
               control whose entire effect is invisible to the reader working
               it; the accessible name comes off the tab that owns the panel. --%>
          <div
            class="hero-out"
            data-surface="0"
            role="tabpanel"
            tabindex="0"
            id={panel_id(@example, 0)}
            aria-labelledby={tab_id(@example, 0)}
          >
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix run {@title}</span></pre>
            <%!-- Recorded frames: real Headless output of the module beside
                 them, committed under priv/hero_frames/<example>/. Frame one
                 ships visible in the dead render; the hook steps the rest. --%>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
              <div :for={{frame, i} <- Enum.with_index(@frames)} class="hero-frame" data-frame={i} hidden={i != 0}>{raw(frame)}</div>
            </div>
          </div>

          <%!-- The browser pane shows the app sitting in a page, because that
               is what the surface is. It used to print `TerminalBridge`'s
               markup as text -- fifteen lines of escaped spans over braille --
               and markup shown as text says the library formats strings. What
               `raxol_liveview` actually hands you is a component: the frame
               below is the same recording the terminal pane steps, in a page
               that has a URL and a heading around it. --%>
          <div
            class="hero-out"
            data-surface="1"
            role="tabpanel"
            tabindex="0"
            id={panel_id(@example, 1)}
            aria-labelledby={tab_id(@example, 1)}
            hidden
          >
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix phx.server</span></pre>

            <div class="hero-browser">
              <%!-- The URL is the whole point of this bar: it says this frame
                   is being served rather than printed. The disc
                   beside it was not a favicon and not a status light, so it
                   said nothing and only made the row look like a screenshot of
                   a browser instead of a page with an address. --%>
              <div class="hero-browser__bar" aria-hidden="true">
                <span class="hero-browser__url">localhost:4000/{@example}</span>
              </div>

              <div class="hero-browser__page">
                <p class="hero-browser__heading">{@module}</p>
                <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
                  <div :for={{frame, i} <- Enum.with_index(@frames)} class="hero-frame" data-frame={i} hidden={i != 0}>{raw(frame)}</div>
                </div>
              </div>
            </div>
          </div>

          <%!-- SSH is the one non-terminal surface that delivers a picture
               rather than a description of one, so it is painted rather than
               listed: same frame, same colours, same two-axis fit as the
               terminal pane, reached over a channel instead of a local tty.
               That IS the claim the tab makes. --%>
          <div
            class="hero-out"
            data-surface="2"
            role="tabpanel"
            tabindex="0"
            id={panel_id(@example, 2)}
            aria-labelledby={tab_id(@example, 2)}
            hidden
          >
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ ssh demo@localhost -p 2222</span></pre>
            <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@ssh_grid.rows}; --frame-cols: #{@ssh_grid.cols}"}>
              <div :for={{frame, i} <- Enum.with_index(@ssh_frames)} class="hero-frame" data-frame={i} hidden={i != 0}>
                <pre class="hero-ansi">{raw(frame)}</pre>
              </div>
            </div>
          </div>

          <%!-- The one pane that is listed rather than painted, because what
               an agent reads is a structure and not a picture: the head of a
               committed artifact, clamped with a marker naming what was cut. --%>
          <div
            class="hero-out"
            data-surface="3"
            role="tabpanel"
            tabindex="0"
            id={panel_id(@example, 3)}
            aria-labelledby={tab_id(@example, 3)}
            hidden
          >
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix mcp.server</span></pre>
            <pre class="hero-pre hero-src" style={"--src-lines: #{@mcp_lines}"}>{raw(@out_mcp)}</pre>
          </div>
        </div>
      </div>

    </div>
    """
  end

  # The four render surfaces, in tab order. One list rather than four literal
  # buttons: the ids the tabs and the panels agree on are derived from `i`, and
  # a hand-written pair is free to drift apart, which is how `aria-controls`
  # pointed at nothing in the first place.
  #
  # `title` rewrites the caption in the demo's title bar; `label` is the
  # surface's longer description.
  @surface_tabs [
    %{
      i: 0,
      name: "Terminal",
      title: "rendering to the terminal",
      label: "Rendered to the terminal"
    },
    %{
      i: 1,
      name: "Browser",
      title: "rendering to Phoenix LiveView",
      label: "Embedded in a page"
    },
    %{
      i: 2,
      name: "SSH",
      title: "served over SSH",
      label: "The same frame, painted down a channel"
    },
    %{
      i: 3,
      name: "Agent / MCP",
      title: "exposed as MCP tools",
      label: "The tree an agent reads"
    }
  ]

  @doc "The hero's render surfaces, in tab order."
  @spec surface_tabs() :: [map()]
  def surface_tabs, do: @surface_tabs

  # Scoped to the example because the whole demo remounts when the example
  # switches; two mounts sharing an id would cross-wire tab and panel.
  defp tab_id(example, i), do: "hero-tab-#{example}-#{i}"
  defp panel_id(example, i), do: "hero-panel-#{example}-#{i}"

  @doc """
  One hero example as a file that actually runs.

  The pane heads itself `$ mix run pulse.exs` and shows the program running,
  but what it lists is a bare `defmodule`: `mix run` defines it and exits
  without drawing anything. A reader who copied what was on screen got silence,
  which made the command line above it the one claim in this hero that was not
  true.

  The two lines that fix it are not in the listing. The pane is already
  type-starved -- the one-screen layout fits a 30-line module at about 9px, and
  three more lines take it to the 8px floor -- so the boot is served with the
  file instead of spent on the reader's ability to read the program.

  It is GENERATED from the module the source declares, so the line that starts
  the app cannot come to name a different module than the one above it.
  `Raxol.run/2` is not a shorter spelling: it delegates to `start_link/2` and
  returns immediately, whatever its docs say.
  """
  @spec example_script(String.t()) :: {:ok, String.t()} | :error
  def example_script(name) do
    Enum.find_value(@hero_examples, :error, fn {n, _t, module, _b, _c, _g} ->
      n == name and
        {:ok,
         """
         #{example_source(name)}
         Raxol.start_link(#{module})
         Process.sleep(:infinity)
         """}
    end)
  end

  @doc "The raw (unhighlighted) source of one example."
  @spec example_source(String.t()) :: String.t()
  def example_source("pulse"), do: @pulse_source
  def example_source("halo"), do: @halo_source
  def example_source("harness"), do: @harness_source
  def example_source("settle"), do: @settle_source

  @doc "Hero examples in switch order."
  def hero_example_names, do: Enum.map(@hero_examples, &elem(&1, 0))

  defp example_title(name) do
    Enum.find_value(@hero_examples, name, fn {n, t, _m, _b, _c, _l} ->
      n == name && t
    end)
  end

  @doc "The module an example defines, as its own source spells it."
  def example_module(name) do
    Enum.find_value(@hero_examples, name, fn {n, _t, m, _b, _c, _l} ->
      n == name && m
    end)
  end

  @doc "What one example demonstrates, for the title bar beside its filename."
  def example_blurb(name) do
    Enum.find_value(@hero_examples, "", fn {n, _t, _m, b, _c, _l} ->
      n == name && b
    end)
  end

  @doc "Line and column counts of one example's source, as the pane sizes from."
  def example_grid(name) do
    Enum.find_value(@hero_examples, %{lines: 1, cols: 1}, fn {n, _t, _m, _b, _c, grid} ->
      n == name && grid
    end)
  end

  defp example_code(name) do
    Enum.find_value(@hero_examples, "", fn {n, _t, _m, _b, c, _l} ->
      n == name && c
    end)
  end

  defp next_example(name) do
    names = hero_example_names()
    idx = Enum.find_index(names, &(&1 == name)) || 0
    Enum.at(names, rem(idx + 1, length(names)))
  end

  # ---------------------------------------------------------------------------
  # 2a. Deep dive 01: Surfaces
  # ---------------------------------------------------------------------------

  def surfaces_deep_dive(assigns) do
    # The four-encodings grid below reuses the landing hero's committed
    # recording of pulse: same artifacts, same pane idioms, so this page
    # cannot drift from what the hero plays and nothing here is authored.
    assigns =
      assign(assigns,
        frame: List.first(RecordedFrames.hero_frames("pulse")),
        frame_grid: RecordedFrames.hero_frame_grid("pulse"),
        ssh_frame: List.first(RecordedFrames.hero_ssh_frames("pulse")),
        ssh_grid: RecordedFrames.hero_ssh_grid("pulse"),
        mcp: RecordedFrames.hero_surface("pulse", :mcp),
        mcp_lines: RecordedFrames.hero_surface_lines("pulse", :mcp)
      )

    ~H"""
    <section class="landing-section py-10 md:py-16 measure" aria-labelledby="surfaces-title">
      <div class="mb-6">
        <h1 id="surfaces-title" class="heading-2xl mb-3">Seven projections of one app model.</h1>
        <p class="body-text max-w-2xl">
          Terminal cells, LiveView DOM, SSH ANSI, MCP JSON, Telegram, Watch, Speech.
        </p>
      </div>

      <div class="surface-buckets surface-buckets--compact">
        <div class="surface-bucket">
          <h2 class="surface-bucket__label">Terminal</h2>
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
          <h2 class="surface-bucket__label">Browser</h2>
          <div class="surface-bucket__chips">
            <div class="surface-chip">
              <span class="surface-chip__name">Browser</span>
              <span class="surface-chip__cmd">Phoenix LiveView</span>
            </div>
          </div>
        </div>

        <div class="surface-bucket">
          <h2 class="surface-bucket__label">Agent surfaces</h2>
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

      <%!-- The landing hero plays these four as tabs; here they sit side by
           side, which is the part a tabbed player cannot show: all four at
           once, from one recording. Every pane is the committed artifact the
           landing's tests hold the hero to -- nothing on this page is
           authored output. --%>
      <div class="surface-snapshots">
        <p class="body-text-dim max-w-2xl mb-4">
          <code class="text-axol-coral">pulse.exs</code> rendered four ways:
          terminal cells, LiveView DOM, SSH ANSI, MCP JSON.
        </p>

        <div class="surface-snapshot-grid">
          <div class="terminal-chrome">
            <.terminal_chrome title="terminal" />
            <div class="terminal-chrome-body">
              <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix run pulse.exs</span></pre>
              <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
                <div class="hero-frame"><%= raw(@frame) %></div>
              </div>
            </div>
          </div>

          <div class="terminal-chrome">
            <.terminal_chrome title="browser" />
            <div class="terminal-chrome-body">
              <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix phx.server</span></pre>
              <div class="hero-browser">
                <div class="hero-browser__bar" aria-hidden="true">
                  <span class="hero-browser__url">localhost:4000/pulse</span>
                </div>
                <div class="hero-browser__page">
                  <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
                    <div class="hero-frame"><%= raw(@frame) %></div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="terminal-chrome">
            <.terminal_chrome title="ssh" />
            <div class="terminal-chrome-body">
              <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ ssh demo@localhost -p 2222</span></pre>
              <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" style={"--frame-rows: #{@ssh_grid.rows}; --frame-cols: #{@ssh_grid.cols}"}>
                <div class="hero-frame">
                  <pre class="hero-ansi"><%= raw(@ssh_frame) %></pre>
                </div>
              </div>
            </div>
          </div>

          <div class="terminal-chrome">
            <.terminal_chrome title="agent / mcp" />
            <div class="terminal-chrome-body">
              <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix mcp.server</span></pre>
              <pre class="hero-pre hero-src" style={"--src-lines: #{@mcp_lines}"}><%= raw(@mcp) %></pre>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 2b. Deep dive 02: SSH zero-install
  # ---------------------------------------------------------------------------

  def ssh_deep_dive(assigns) do
    ~H"""
    <%!-- One column. It was a two-column grid whose right half held a single
         button, vertically centred against nothing, and the button went to the
         browser playground: a section that spends four bullets selling the SSH
         surface and then hands the reader a browser link argues against itself.
         The button also had the offline notice underneath it as a subtitle, set
         in the smallest uppercase type on the page, which is where a page puts
         something it hopes will not be read.

         What the section is actually offering is a command, so it offers the
         command. The hosted endpoint being down does not make the claim untrue
         and is not a reason to send the reader somewhere else -- it is a fact
         about this deployment, so it is stated as one, in body text. --%>
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="ssh-deep-title">
      <div class="max-w-[65ch]">
        <h1 id="ssh-deep-title" class="heading-2xl mb-3">SSH is a surface.</h1>
        <p class="body-text mb-6">
          The same app runs behind an Erlang <code class="text-axol-coral">:ssh</code>
          daemon. Each channel is a supervised BEAM process.
        </p>

        <div class="mb-6">
          <.copyable_command
            id="copy-ssh-serve"
            command="mix raxol.playground --ssh"
            comment="port 2222"
            tone={:coral}
          />
        </div>

        <ul class="detail-text space-y-2 leading-relaxed list-disc list-inside mb-6">
          <li>Host keys generated on first boot</li>
          <li>Channel process per connection</li>
          <li>Disconnects tear down session state</li>
          <li>Enable with <code class="text-axol-coral">Raxol.SSH.Server</code></li>
        </ul>

        <p class="body-text-dim">
          Hosted SSH is offline while the host is rebuilt. Run
          <code class="text-axol-coral">mix raxol.playground --ssh</code>
          locally.
        </p>

        <%!-- The posture facts below are `Raxol.SSH.Server`'s documented
             boot contract, not aspirations: each one is a refusal or a log
             line the module ships with. --%>
        <h2 class="heading-xl mt-14 mb-3">Safe by default</h2>
        <p class="body-text mb-4">
          Anonymous access binds loopback by default. Public serving needs
          separate acknowledgement.
        </p>
        <ul class="detail-text space-y-2 leading-relaxed list-disc list-inside mb-6">
          <li>
            Anonymous access binds loopback; serving it publicly takes a
            second, separate acknowledgement
          </li>
          <li>
            Boot refuses to start until all four resource caps are written
            down: max connections, per-IP, idle timeout, session duration
          </li>
          <li>A group- or world-readable host key is refused, not warned about</li>
          <li>
            One posture line per boot, one accept/close line per connection:
            peer, user, duration, outcome
          </li>
        </ul>

        <h2 class="heading-xl mt-14 mb-3">Multi-tenant, keys in a directory</h2>
        <p class="body-text mb-4">
          A tenant is a directory:
          <code class="text-axol-coral">&lt;dir&gt;/&lt;user&gt;/ssh/authorized_keys</code>
          for access, <code class="text-axol-coral">work/</code> for files,
          ledger for spend. The authenticated username picks that directory.
        </p>
        <div class="mb-6">
          <.copyable_command
            id="copy-ssh-tenants"
            command="raxol code --ssh --ssh-tenants ./tenants"
            comment="port 2223"
            tone={:sky}
          />
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 2c. Deep dive 03: Agent runtime
  # ---------------------------------------------------------------------------

  def agent_deep_dive(assigns) do
    assigns = assign(assigns, :agent_code, @agent_code)

    ~H"""
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="agent-deep-title">
      <div class="mb-8">
        <h1 id="agent-deep-title" class="heading-2xl mb-3">Agents are supervised processes.</h1>
        <p class="body-text max-w-2xl">
          <span class="text-axol-coral">init</span> /
          <span class="text-axol-coral">update</span> /
          <span class="text-axol-coral">view</span> is the contract. Headless
          agents return no view. OTP supplies supervision, messaging, hot reload,
          swarm discovery.
        </p>
      </div>

      <div class="terminal-chrome mb-6 ch-snap">
        <.terminal_chrome title="researcher.exs" />
        <div class="terminal-chrome-body">
          <pre class="code-block"><code class="syntax-elixir"><%= Phoenix.HTML.raw(@agent_code) %></code></pre>
        </div>
      </div>

      <p class="body-text-dim max-w-2xl">
        Stream LLM output with <code class="text-axol-coral">:async</code>.
        Route peer messages through <code class="text-axol-coral">Registry</code>.
        Bring a provider key.
      </p>

      <div class="max-w-2xl">
        <h2 class="heading-xl mt-14 mb-3">Teams are supervisors</h2>
        <p class="body-text mb-4">
          <code class="text-axol-coral">Raxol.Agent.Team</code> is an OTP
          supervisor. A crashed worker restarts by BEAM rules. Peers send
          <code class="text-axol-coral">:send_agent</code>; receivers get
          <code class="text-axol-coral"><%= "{:agent_message, from, payload}" %></code>
          in <code class="text-axol-coral">update/2</code>.
        </p>

        <h2 class="heading-xl mt-14 mb-3">On a schedule</h2>
        <p class="body-text mb-4">
          Schedules accept delay, interval, cron, or ISO time. Jobs persist,
          replay on boot, fire history-free agents, and deliver to chat or
          callback. The <code class="text-axol-coral">cronjob</code> tool
          creates, lists, pauses, resumes, runs, and removes; fires never block
          the scheduler.
        </p>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 2d. Deep dive 04: Coding agent + ACP
  # ---------------------------------------------------------------------------

  def coding_agent_deep_dive(assigns) do
    ~H"""
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="coding-agent-title">
      <div class="mb-8">
        <h1 id="coding-agent-title" class="heading-2xl mb-3">raxol code is an ACP server.</h1>
        <p class="body-text max-w-2xl">
          TUI, headless mode, MCP, and ACP editor sessions share one journal.
          <a href="https://agentclientprotocol.com" class="text-sky">agentclientprotocol.com</a>
          lists raxol code.
        </p>
      </div>

      <div class="space-y-3 mb-6 ch-snap">
        <.copyable_command id="copy-agent-code" command="mix raxol.code" comment="interactive coding-agent TUI" tone={:coral} />
        <.copyable_command id="copy-agent-acp" command="raxol acp" comment="serve ACP editors" tone={:sky} />
        <.copyable_command id="copy-agent-p" command={~S(raxol -p "fix the failing test")} comment="headless, JSON events on stderr" tone={:sky} />
        <.copyable_command id="copy-agent-mcp" command="mix mcp.server" comment="expose the UI itself as agent tools" tone={:sky} />
      </div>

      <p class="body-text-dim max-w-2xl">
        The MCP schema is derived from the widget tree; no second tool
        manifest.
      </p>

      <div class="max-w-2xl">
        <h2 class="heading-xl mt-14 mb-3">Every session is a journal</h2>
        <p class="body-text mb-4">
          Each session is a disk journal. Resume with
          <code class="text-axol-coral">--continue</code>, list with
          <code class="text-axol-coral">--sessions</code>, replay with
          <code class="text-axol-coral">--replay ID</code>, rewind with
          <code class="text-axol-coral">/rewind</code>. ACP reconnects by
          session id because the id is the directory.
        </p>

        <h2 class="heading-xl mt-14 mb-3">Metered spend</h2>
        <p class="body-text mb-4">
          Every LLM call is priced into a ledger. Exhausted budgets halt the
          turn. Unknown model price fails closed once a ledger is wired. Share
          links are expiring, signed, read-only tokens scoped to session and
          tenant.
        </p>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # 2e. Deep dive 05: Agent payments (privacy ladder + solver reach matrix)
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
  @chain_notes %{
    4663 => "Permit2 pull",
    5_042_002 => "testnet",
    728_126_428 => "relay rail"
  }

  # Static rows for rails that must stay visible when the solver endpoint is
  # down or has not published the chain yet. Live rows win; these only fill gaps.
  @authored_reach_rows [
    %{
      chain_name: "Arc (testnet)",
      chain_id: 5_042_002,
      vm: "EVM",
      tokens: ["USDC"],
      note: "testnet"
    },
    %{
      chain_name: "Tron",
      chain_id: 728_126_428,
      vm: "TVM",
      tokens: ["USDC", "USDT"],
      note: "relay rail"
    }
  ]

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
                      %{name: "raxol_payments", version: v} ->
                        String.replace(v, "~> ", "")

                      _ ->
                        nil
                    end)

  attr(:matrix, :map, required: true)

  def payments_deep_dive(assigns) do
    # Fees come from `Raxol.Payments.FeeSchedule`, the local mirror of the
    # external fee policy the SDK checks itself against.
    # It used to come from `PrivacyTier`, which prices
    # a different (retired) model: it put a table on this page that no tier has
    # ever charged, including a `0 bps -- no fee` row that the never-discounted
    # solver floor makes impossible.
    assigns =
      assign(assigns,
        tiers: Raxol.Payments.FeeSchedule.all(),
        tier_proofs: @tier_proofs,
        solver_floor: Raxol.Payments.FeeSchedule.solver_base_bps(),
        payments_version: @payments_version,
        rows: reach_rows(assigns.matrix),
        routes: routes(),
        payment_actions: payment_actions(),
        action_groups: action_groups(),
        show_future_svm: not Enum.any?(assigns.matrix.chains, &(&1.vm_type == :svm)),
        live?: assigns.matrix.source == :live
      )

    ~H"""
    <section class="landing-section payments-deep py-14 md:py-24 measure" aria-labelledby="payments-title">
      <div class="mb-8">
        <h1 id="payments-title" class="heading-2xl mb-3">
          Agents that pay invoices.
        </h1>
        <p class="body-text max-w-2xl">
          Agents can pay HTTP 402 invoices under ledger-enforced spend gates.
          Raxol chooses the rail, signs the intent, and records the receipt.
        </p>
        <p class="caption-text mt-3">
          Payments package: <%= @payments_version %>; core: 2.6.
          Stablecoin fees run 10-22 bps by trust tier; volatile assets run 22-40 bps.
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

      <p class="body-text-dim max-w-2xl mb-10">
        Fees have three layers: solver spread, venue cut, raxol routing cut.
        Tiers discount the last two; solver spread is never discounted
        (<%= @solver_floor.stable %> bps stable,
        <%= @solver_floor.volatile %> bps volatile), so there is no zero-fee
        tier. ACP jobs skip routing cut; it is already budgeted.
      </p>

      <h2 class="name-coral mb-2">Public, stealth, or shielded</h2>
      <p class="body-text-dim max-w-2xl mb-10">
        ZK attestations prove trust tier without exposing the score.
      </p>

      <h2 class="name-coral mb-2">xochi.fi reach</h2>
      <p class="body-text-dim max-w-2xl mb-4">
        Five-minute cache; cached registry on fetch failure.
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
                <span class="tok tok--soon">absent</span>
                appears when the capabilities API returns an SVM chain
              </span>
            </div>
          </div>
        </div>
        <div class="reach-foot">
          settles public, <span class="set-stealth">stealth</span>, or
          <span class="set-shielded">shielded</span> per payment
        </div>
      </div>

      <h2 class="name-coral mt-12 mb-2">xochi.fi routing</h2>
      <p class="body-text-dim max-w-2xl mb-4">
        <code>Raxol.Payments.Router.select/1</code> picks x402, private
        settlement, or relay.
      </p>

      <div class="ladder ladder--pair mb-4" role="table" aria-label="Protocol routing">
        <div class="rung rung--head" role="row">
          <span role="columnheader">Request</span>
          <span role="columnheader">Rail</span>
        </div>
        <div :for={row <- @routes} class="rung" role="row">
          <span class="rung__note" role="cell"><%= row.label %></span>
          <span class="rung__tier" role="cell"><%= row.protocol %></span>
        </div>
      </div>

      <p class="body-text-dim max-w-2xl mb-10">
        Tron forces relay, which is public-only; stealth-to-Tron fails at the
        Action.
      </p>

      <h2 class="name-coral mb-2">
        <%= length(@payment_actions) %> Actions
      </h2>

      <%!-- Two clusters rather than thirteen hairline rows with the same word
           repeated down a column. The split is the `sensitive` flag itself, so
           the distinction the section exists to draw is the structure instead
           of a value a reader has to scan for, and the four that move money
           are read at a glance rather than counted. --%>
      <div :for={{label, actions} <- @action_groups} class="action-group">
        <h3 class="action-group__label"><%= label %></h3>
        <ul class="action-group__list">
          <li :for={action <- actions} class="action-group__item">
            <%= action.name %>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  # Both tables are derived at render rather than typed. The rails come from
  # the router itself, so a page cannot advertise a route the product would not
  # pick; the Actions come from `__action_meta__/0` on every module the
  # raxol_payments application ships, so one added to the package appears here
  # without this file being touched, and its `sensitive` flag is the same one
  # the tool-call gate reads.
  @routes [
    {"same-chain API call", [cross_chain: false]},
    {"cross-chain transfer", [cross_chain: true]},
    {"privacy: stealth", [privacy: :stealth]},
    {"privacy: shielded", [privacy: :shielded]},
    {"leg into Tron", [from_chain_id: 8453, to_chain_id: 728_126_428]},
    {"stealth, bound for Tron", [privacy: :stealth, to_chain_id: 728_126_428]}
  ]

  @doc false
  @spec routes() :: [map()]
  def routes do
    Enum.map(@routes, fn {label, opts} ->
      %{label: label, protocol: Raxol.Payments.Router.select(opts)}
    end)
  end

  @doc false
  @spec action_groups() :: [{String.t(), [map()]}]
  def action_groups do
    {gated, reads} = Enum.split_with(payment_actions(), & &1.sensitive)

    [{"moves funds", gated}, {"read only", reads}]
    |> Enum.reject(fn {_label, actions} -> actions == [] end)
  end

  @doc false
  @spec payment_actions() :: [map()]
  def payment_actions do
    {:ok, modules} = :application.get_key(:raxol_payments, :modules)

    modules
    |> Enum.filter(fn m ->
      Code.ensure_loaded?(m) and function_exported?(m, :__action_meta__, 0)
    end)
    |> Enum.map(& &1.__action_meta__())
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The project token, on its own page.

  It used to be the tail of the payments deep dive, which put it under a
  heading about settlement and invited exactly the reading the copy then had to
  deny: the corridors quote, route and settle in stablecoins, and this is not
  one of them. A token and a payment rail are different subjects, and the page
  said so more convincingly once they stopped sharing a page.
  """
  def token_deep_dive(assigns) do
    assigns = assign(assigns, token: @token, token_pair_url: @token_pair_url)

    ~H"""
    <section class="landing-section py-10 md:py-16 measure" aria-labelledby="token-title">
      <div class="mb-6">
        <h1 id="token-title" class="heading-2xl mb-3">${@token.symbol}</h1>
      </div>

      <p class="body-text-dim max-w-2xl mb-4">
        ${@token.symbol} is the project token, not the payment rail. Agents pay
        invoices in stablecoins; payment corridors quote, route, and settle in
        those assets.
      </p>

      <div class="reach reach--compact">
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

      <div class="max-w-2xl">
        <h2 class="heading-xl mt-10 mb-3">Boundary</h2>
        <div class="reach-toks mb-4">
          <span class="tok">not settlement</span>
          <span class="tok">not package access</span>
          <span class="tok">not fee switch</span>
          <span class="tok">not oracle</span>
        </div>
        <p class="body-text-dim">
          Payment rails live on
          <a href="/payments" class="link-subtle">/payments</a>.
        </p>
      </div>
    </section>
    """
  end

  defp reach_rows(%{chains: chains, tokens: tokens}) do
    chains
    |> Enum.map(&matrix_row(&1, tokens))
    |> Enum.concat(@authored_reach_rows)
    |> Enum.reduce(%{}, fn row, acc ->
      Map.update(acc, row.chain_id, row, fn existing ->
        %{existing | tokens: merge_tokens(existing.tokens, row.tokens)}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.chain_id)
  end

  defp matrix_row(chain, tokens) do
    symbols =
      tokens
      |> Enum.filter(&Map.has_key?(&1.addresses, chain.chain_id))
      |> Enum.map(& &1.symbol)
      |> Enum.uniq()
      |> sort_tokens()

    %{
      chain_name: display_chain_name(chain.chain_id, chain.chain_name),
      chain_id: chain.chain_id,
      vm: chain.vm_type |> Atom.to_string() |> String.upcase(),
      tokens: symbols,
      note: @chain_notes[chain.chain_id]
    }
  end

  defp display_chain_name(5_042_002, _name), do: "Arc (testnet)"
  defp display_chain_name(_chain_id, name), do: name

  defp merge_tokens(left, right) do
    (left ++ right)
    |> Enum.uniq()
    |> sort_tokens()
  end

  defp sort_tokens(tokens),
    do: Enum.sort_by(tokens, &{Map.get(@token_order, &1, 99), &1})

  # The top tier is open-ended, so it reads as a threshold rather than a band.
  defp score_band(%{min_score: min, max_score: nil}), do: "#{min} and above"
  defp score_band(%{min_score: min, max_score: max}), do: "#{min}-#{max}"

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
      <div class="measure flex items-center justify-end gap-4 font-mono caption-text tracking-wide">
        <span>Made by <a href="https://axol.io" class="axol-link">axol.io</a></span>
        <.github_mark />
      </div>
    </footer>
    """
  end
end
