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

  # Payments, with nothing authored but the corridor and the amount. Every rate
  # is `FeeSchedule.all/0` -- the schedule pinned to the solver's own published
  # one -- and the networks are the chains USDC is actually deployed on, read
  # off `Assets.evm_tokens/0`. That sourcing is the point rather than a detail:
  # this page rendered a hand-written fee table until 2026-08-30, and the
  # numbers in it were ones no tier ever charged.
  @settle_source ~S"""
  defmodule Settle do
    use Raxol.Core.Runtime.Application
    alias Raxol.Payments.{Assets, Router}
    @route Router.select(cross_chain: true)
    @tokens Assets.evm_tokens() |> Map.keys() |> Enum.sort()
    @stables Enum.reject(@tokens, &(&1 == "WETH"))
    @steps [
      {"quote", "Base -> Arbitrum One"},
      {"sign", "EIP-712 intent"},
      {"settle", "0x7f3a9c.. stealth"}
    ]
    def init(_), do: %{t: 0}
    def update(:tick, m), do: {%{m | t: m.t + 1}, []}
    def update(_, m), do: {m, []}
    def subscribe(_), do: [subscribe_interval(200, :tick)]
    def view(m) do
      at = rem(m.t, length(@steps) + 1)
      column style: %{gap: 1} do
        [
          text("USDC 25.00  via #{@route}", style: [:bold]),
          column(do: Enum.with_index(@steps, &step(&1, &2, at))),
          text("stables  " <> Enum.join(@stables, "  "))
        ]
      end
    end

    defp step({n, note}, i, at) when i < at,
      do: text("ok  #{String.pad_trailing(n, 8)}#{note}", fg: :cyan)
    defp step({n, _note}, _i, _at), do: text("    #{n}")
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
                        {"pulse", "pulse.ex", "one module, four surfaces",
                         @pulse_source},
                        {"halo", "halo.ex", "the mark, as a program",
                         @halo_source},
                        {"harness", "harness.ex",
                         "a Virtuals ACP job, worked by the coding agent",
                         @harness_source},
                        {"settle", "settle.ex",
                         "a cross-chain transfer, through Xochi",
                         @settle_source}
                      ] do
                    lines = source |> String.trim() |> String.split("\n")

                    [_, module] = Regex.run(~r/defmodule (\w+)/, source)

                    {name, file, module, blurb,
                     Makeup.highlight_inner_html(source),
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
        <a :for={{path, label} <- topic_links()} href={path} class="nav-link">{label}</a>
      </nav>
    </header>
    """
  end

  attr(:example, :string, required: true)

  def screen_hero(assigns) do
    assigns =
      assign(assigns,
        halo_faces: @halo_faces,
        network_marks: NetworkMarks.all(),
        install_command: @install_command
      )

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

        <%!-- Each noun in the h1 is a tab away in the demo below, and this
             line says which is which: "harness" means nothing to a reader who
             has not met `raxol code`. The chains and the assets used to be
             spelled out here and are not any more -- the reach table on
             /payments carries them, derived from the solver, and naming a
             subset in the hero dates the sentence every time one is added. --%>
        <p class="screen-sub">
          Each is its own Hex package: the TEA runtime, the AI agent, the
          <span class="text-axol-coral">raxol code</span> coding harness, and
          cross-chain settlement. The demo below runs them.
        </p>

        <%!-- The chains, as marks rather than as a sentence. This is the row
             the sub-line used to spell out; a logo does not date the way a
             list of five names did, and it survives a corridor being added
             without anyone rewriting a paragraph. Six EVM chains carry a
             token in the asset registry and Tron is reached over the relay
             rail, which is the seventh. --%>
        <ul class="screen-networks" aria-label="Networks raxol settles on">
          <li :for={mark <- @network_marks} class="screen-networks__item">
            <svg
              class="screen-networks__mark"
              viewBox={mark.view_box}
              role="img"
              aria-label={mark.name}
            >
              <title>{mark.name}</title>
              {Phoenix.HTML.raw(mark.body)}
            </svg>
          </li>
        </ul>

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
    assigns = assign(assigns, :repo_url, @repo_url)

    ~H"""
    <footer class="screen-footer" role="contentinfo">
      <div class="screen-bar">
        <nav class="screen-topics" aria-label="Deep dives">
          <a :for={{path, label} <- topic_links()} href={path} class="topic-link">{label}</a>
        </nav>

        <%!-- The package count was the one claim in this line a reader could
             not check. It is the number the capability endpoints serve, and
             the directory it counts is public, so it links there. --%>
        <span class="screen-meta">
          v{Capabilities.version_minor()} &middot;
          <a href={@repo_url <> "/tree/master/packages"} class="subtle-link">
            {Capabilities.repo_package_count()} packages
          </a>
          &middot; <a href="https://hex.pm/packages/raxol" class="subtle-link">Hex</a> &middot;
          <a href="/skill.md" class="subtle-link">Skill</a>
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

  # The deep-dive pages, in one place so the header and footer cannot list
  # different ones. `TopicLive` owns the paths; this only borrows them.
  defp topic_links, do: RaxolPlaygroundWeb.TopicLive.links()

  # One list for both site headers. The landing carried four links and the
  # topic pages six, so the navigation changed shape when a reader crossed
  # between them and neither list knew the other existed.
  # Two, because two is what the site actually has to offer a first-time
  # reader: somewhere to watch it run, and somewhere to read the API.
  #
  # It carried six. Playground, Gallery and Demos were three labels for one
  # job, and no visitor could tell them apart from the words -- Demos was a
  # strictly smaller copy of Gallery over the same catalog, and is gone;
  # Playground is one link inside Components, where someone who wants the
  # fuller tool is already standing. Skill and GitHub are reference material
  # for a reader who has already decided, so they moved to the footer, GitHub
  # as its mark. Nothing here was padded back to a round number: a third item
  # added to reach one would be the same defect in a smaller font.
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
      <div class="hero-demo-bar">
        <span class="hd-dot"></span><span class="hd-dot"></span><span class="hd-dot"></span>
        <%!-- Two spans, because they answer different questions and only one
             of them changes: which program this is (static, and the thing a
             reader loses track of while clicking through surfaces) and which
             surface it is rendering to (rewritten by the tab). --%>
        <span class="hd-name"><b>{@title}</b> &middot; {@blurb}</span>
        <span class="hd-title" data-role="title">rendering to the terminal</span>

        <div class="hd-controls">
          <button type="button" data-role="player-pause" class="hd-control">pause</button>
          <button type="button" phx-click="next_example" class="hd-control hd-control--next">
            {example_title(@next)} &rarr;
          </button>
        </div>
      </div>

      <div class="hero-tabs" role="tablist" aria-label="Render surface">
        <button type="button" class="hero-tab" role="tab" aria-selected="true" data-i="0" data-title="rendering to the terminal" data-label="Rendered to the terminal">Terminal</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="1" data-title="rendering to Phoenix LiveView" data-label="Embedded in a page">Browser</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="2" data-title="served over SSH" data-label="The same frame, painted down a channel">SSH</button>
        <button type="button" class="hero-tab" role="tab" aria-selected="false" data-i="3" data-title="exposed as MCP tools" data-label="The tree an agent reads">Agent / MCP</button>
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

          <%!-- The browser pane shows the app sitting in a page, because that
               is what the surface is. It used to print `TerminalBridge`'s
               markup as text -- fifteen lines of escaped spans over braille --
               and markup shown as text says the library formats strings. What
               `raxol_liveview` actually hands you is a component: the frame
               below is the same recording the terminal pane steps, in a page
               that has a URL and a heading around it. --%>
          <div class="hero-out" data-surface="1" hidden>
            <pre class="hero-pre hero-cmd" aria-hidden="true"><span class="hc">$ mix phx.server</span></pre>

            <div class="hero-browser">
              <div class="hero-browser__bar" aria-hidden="true">
                <span class="hero-browser__dot"></span>
                <span class="hero-browser__url">localhost:4000/{@example}</span>
              </div>

              <div class="hero-browser__page">
                <p class="hero-browser__heading">{@module}</p>
                <div class="hero-frames raxol-terminal bg-synthwave-bg" data-theme="synthwave84" aria-hidden="true" style={"--frame-rows: #{@frame_grid.rows}; --frame-cols: #{@frame_grid.cols}"}>
                  <div :for={{frame, i} <- Enum.with_index(@frames)} class="hero-frame" data-frame={i} hidden={i != 0}>{raw(frame)}</div>
                </div>
                <p class="hero-browser__caption">
                  One TerminalComponent on an ordinary page. Keydown goes back
                  through InputAdapter into update/2.
                </p>
              </div>
            </div>
          </div>

          <%!-- SSH is the one non-terminal surface that delivers a picture
               rather than a description of one, so it is painted rather than
               listed: same frame, same colours, same two-axis fit as the
               terminal pane, reached over a channel instead of a local tty.
               That IS the claim the tab makes. --%>
          <div class="hero-out" data-surface="2" hidden>
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
    Enum.find_value(@hero_examples, %{lines: 1, cols: 1}, fn {n, _t, _m, _b, _c,
                                                              grid} ->
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
  # 2b. Deep dive 02: SSH zero-install
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
  # 2c. Deep dive 03: Agent runtime
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
  # 2d. Deep dive 04: Coding agent + ACP
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
                      %{name: "raxol_payments", version: v} ->
                        String.replace(v, "~> ", "")

                      _ ->
                        nil
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
        rows: reach_rows(assigns.matrix),
        show_future_svm:
          not Enum.any?(assigns.matrix.chains, &(&1.vm_type == :svm)),
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

    </section>
    """
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
    <section class="landing-section py-14 md:py-24 measure" aria-labelledby="token-title">
      <div class="mb-8">
        <span class="section-numeral" aria-hidden="true">06</span>
        <span class="section-eyebrow">Token</span>
        <h1 id="token-title" class="heading-2xl mb-3">${@token.symbol}</h1>
      </div>

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
