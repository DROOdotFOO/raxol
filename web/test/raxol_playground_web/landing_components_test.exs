defmodule RaxolPlaygroundWeb.LandingComponentsTest do
  # Not async: the SSH-availability tests flip RAXOL_SSH_PLAYGROUND, which is
  # VM-global. Four component renders are cheap; a racy env read is not.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Raxol.Agent.Backend.Resolver
  alias RaxolPlayground.BrandMarks
  alias RaxolPlayground.Capabilities
  alias RaxolPlayground.RecordedFrames
  alias RaxolPlayground.SurfaceSource
  alias RaxolPlaygroundWeb.LandingComponents
  alias RaxolPlaygroundWeb.PlaygroundComponents

  test "landing promotes live install and browser paths, not the suspended SSH host" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    deep_dive = render_component(&LandingComponents.ssh_deep_dive/1, %{})
    try_section = render_component(&LandingComponents.try_section/1, %{})

    # The one-screen hero carries ONE install path -- the curl script this
    # site serves. The four-method tabs live in `install_tabs`, tested below.
    assert hero =~ "curl -fsSL https://raxol.io/install | bash"
    assert deep_dive =~ "Hosted SSH is temporarily offline"
    assert deep_dive =~ ~s(href="/playground")
    assert try_section =~ "npm i -g raxol"

    refute Enum.join([hero, deep_dive, try_section]) =~ "playground@raxol.io"
  end

  # The landing is one screen. These are the two properties that keeps: it
  # carries no deep-dive section (those are their own pages now), and the hero
  # plays recorded frames rather than starting a live session.
  test "the landing screen carries no deep dive and no live session" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    refute hero =~ "take over live"
    refute hero =~ "run it live"
    refute hero =~ ~s(phx-click="take_over")
    refute hero =~ "RaxolTerminal"

    # Recorded frames, and more than one, or the hero is a still image.
    assert hero =~ ~s(class="hero-frame")
    assert length(String.split(hero, ~s(class="hero-frame"))) - 1 > 1
  end

  test "every hero example has recorded frames and a readable module" do
    for name <- LandingComponents.hero_example_names() do
      frames = RaxolPlayground.RecordedFrames.hero_frames(name)

      assert length(frames) > 1, "#{name} has #{length(frames)} recorded frame(s)"
      assert Enum.uniq(frames) == frames, "#{name} recorded identical frames"

      hero = render_component(&LandingComponents.screen_hero/1, example: name)
      assert hero =~ "#{name}.ex"
    end
  end

  # The hero claims one module reaches four surfaces, each pane an encoding of
  # one recorded render. These two tests stop a pane reverting to authored text.
  test "every non-terminal hero pane is a recorded artifact, line for line" do
    for name <- LandingComponents.hero_example_names(),
        surface <- [:browser, :ssh, :mcp] do
      artifact = RecordedFrames.hero_artifact(name, surface)
      pane = RecordedFrames.hero_surface(name, surface)

      assert artifact != "", "#{name}/#{surface} has no recorded artifact"
      assert pane != "", "#{name}/#{surface} renders no pane"

      lines = pane_lines(pane)
      marker? = List.last(lines) =~ ~r/^\.\.\. \d+ more lines, \d+ bytes total$/
      body = if marker?, do: Enum.drop(lines, -1), else: lines

      for line <- body do
        assert String.contains?(artifact, unspell(line, surface)),
               "#{name}/#{surface} shows a line that is not in the artifact:\n#{inspect(line)}"
      end

      # A pane either says what it cut, or it cut nothing.
      full = artifact |> break_lines(surface) |> SurfaceSource.wrap()

      if marker? do
        assert length(lines) == SurfaceSource.budget()
        assert length(full) > SurfaceSource.budget()
      else
        assert body == full,
               "#{name}/#{surface} shows #{length(body)} of #{length(full)} lines and says nothing"
      end
    end
  end

  # The pane's claim is that you can read the whole program, and the pane is a
  # fixed slice of one screen. A longer example does not scroll, it clips --
  # which is how halo grew to 35 lines and started cutting off mid-function
  # without anything failing. The budget is what the pane holds at its type
  # floor on the shortest viewport the page still calls one screen.
  @max_example_lines 30

  test "every hero example fits the pane it is displayed in" do
    for name <- LandingComponents.hero_example_names() do
      %{lines: lines} = LandingComponents.example_grid(name)

      assert lines <= @max_example_lines,
             "#{name}.ex is #{lines} lines; the pane holds #{@max_example_lines}"
    end
  end

  test "the hero renders four surfaces and claims no ACP one" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    for label <- ["Terminal", "Browser", "SSH", "Agent / MCP"] do
      assert hero =~ ">#{label}</button>"
    end

    assert length(String.split(hero, ~s(class="hero-tab"))) - 1 == 4
    assert hero =~ ~s(data-surface="3")
    refute hero =~ ~s(data-surface="4")

    # ACP is the coding agent's editor protocol, not a surface a TEA chart
    # renders to, so the hero may not caption an example module with it.
    refute hero =~ "ACP"
    refute hero =~ "session/prompt"
    refute hero =~ "agent_message_chunk"
  end

  # The row reinforces the claim with things that are true, so its entries have
  # to come from the tables the rest of the site serves rather than from a list
  # someone typed. A hand-kept copy is what put "Groq" on /api/capabilities and
  # left four real providers off it. This fails rather than drifting.
  test "the integrations row's models are the agent's own provider registry" do
    expected =
      Resolver.providers()
      |> Enum.reject(&(&1.harness == :mock))
      |> Enum.map(&(&1.label |> String.split(" (") |> hd()))

    assert Capabilities.connectable_backends() == expected

    # Mock answers canned text offline. It belongs in the manifest an agent
    # reads, and not in a list of providers a reader could connect to.
    assert "Mock" in Capabilities.backends()
    refute "Mock" in expected

    row = render_component(&LandingComponents.screen_integrations/1, %{})

    for name <- expected do
      assert row =~ name,
             "the integrations row omits #{name}, which the provider registry lists"
    end
  end

  # npm and the Homebrew tap are built but unpublished and human-gated. The row
  # names channels that exist today. `install_tabs` still advertises both and
  # is rendered by nothing; that wart must not spread to a live component.
  test "the integrations row names no unpublished install channel" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    refute row =~ "npm"
    refute row =~ "brew"
    refute row =~ "Homebrew"
  end

  # Editors are third-party ACP clients, so the honest gate is our own ACP
  # surface: a build without it (a Hex install of raxol_agent compiles no
  # StdioAgent) names no editor rather than five that cannot reach it. Asserted
  # as a relationship, since a compile gate cannot be flipped from a test the
  # way RAXOL_SSH_PLAYGROUND can.
  test "editors appear only while raxol's own ACP surface is compiled in" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})
    labels = Enum.map(LandingComponents.integration_groups(), &elem(&1, 0))

    editors_named? = "acp editors" in labels

    assert Capabilities.acp_available?() == (Capabilities.acp_editors() != [])
    assert editors_named? == Capabilities.acp_available?()

    for editor <- Capabilities.acp_editors() do
      assert row =~ editor, "the integrations row omits #{editor}"
    end
  end

  # The hero may not say "ACP" (above), and this row names ACP editors. Keeping
  # the row a sibling of the hero rather than part of it is what keeps both
  # true, so the separation is asserted instead of left to convention.
  test "the integrations row is a sibling of the hero, not part of it" do
    for name <- LandingComponents.hero_example_names() do
      hero = render_component(&LandingComponents.screen_hero/1, example: name)

      refute hero =~ "integrations-track",
             "#{name}'s hero carries the integrations row, which must stay a sibling"
    end
  end

  # A mark decorates a derived entry, it never replaces one. The row still
  # lists what the registry lists, and an entry whose brand has no mark shows
  # its name. Both directions are held: a mark left behind for something no
  # longer offered would otherwise rot in the directory unnoticed.
  test "marks decorate the derived entries without narrowing them" do
    entries = Enum.flat_map(LandingComponents.integration_groups(), &elem(&1, 1))
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    for entry <- entries do
      assert row =~ ">#{entry}</span>", "the row drops #{entry}, which is derived"
    end

    for name <- BrandMarks.known() do
      assert name in entries, "#{name} has a mark but is no longer an entry"
    end

    # Two runs are rendered: the visible one and the aria-hidden copy the loop
    # needs, so every marked entry appears twice.
    marked = Enum.filter(entries, &BrandMarks.path/1)
    assert length(String.split(row, "integrations-item--marked")) - 1 == length(marked) * 2

    # The no-mark path has to be live, not theoretical. Were every entry to
    # gain a mark this test would still pass while the fallback rotted, so the
    # fallback is asserted to be exercised by something.
    assert Enum.any?(entries, &is_nil(BrandMarks.path(&1))),
           "no entry exercises the no-mark fallback"
  end

  # The marks are inlined, not fetched: a logo row that reaches out over the
  # network is a row that renders differently on a bad connection than in a
  # test, and it leaks who reads the page to whoever hosts the icons.
  test "every mark is a single inlined path, never a request" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    assert row =~ ~s(viewBox="0 0 24 24")
    refute row =~ "<img"
    refute row =~ "http"

    for name <- BrandMarks.known() do
      d = BrandMarks.path(name)
      assert is_binary(d) and d != "", "#{name} has an empty mark"
      assert String.starts_with?(d, ["M", "m"]), "#{name}'s mark is not path data"
    end
  end

  # The name is markup, not something script swaps in on hover: it is what a
  # screen reader reads, what an unmarked entry shows outright, and what sets
  # the item's width so a cross-fade cannot reflow a moving row.
  test "the name is always in the markup, hover only reveals it" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    assert row =~ ~s(class="integrations-name")
    refute row =~ "phx-hook"
    refute row =~ "onmouseover"
    refute row =~ ~s(title=")
  end

  defp break_lines(artifact, :browser), do: SurfaceSource.dom_lines(artifact)
  defp break_lines(artifact, :ssh), do: SurfaceSource.ansi_lines(artifact)
  defp break_lines(artifact, :mcp), do: SurfaceSource.json_lines(artifact)

  # Undoes SurfaceSource's colour spans and escaping, leaving the lines as its
  # line-breaking produced them.
  defp pane_lines(pane) do
    pane
    |> String.replace(~r{</?span[^>]*>}, "")
    |> unescape()
    |> String.split("\n")
  end

  # ANSI lines carry ESC spelled out; put the byte back before checking.
  defp unspell(line, :ssh), do: String.replace(line, "ESC", "\e")
  defp unspell(line, _surface), do: line

  defp unescape(text) do
    # &amp; last, or an escaped &amp;lt; would come back as a literal <.
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  test "install tabs carry all four methods with curl visible by default" do
    tabs = render_component(&LandingComponents.install_tabs/1, %{})

    assert tabs =~ ~s(aria-label="Install method")
    assert tabs =~ "curl -fsSL https://raxol.io/install | bash"
    assert tabs =~ "brew install droodotfoo/tap/raxol"
    assert tabs =~ "npm i -g raxol"
    assert tabs =~ "{:raxol,"

    # The curl pane is the one visible before JS runs (dead render).
    assert tabs =~ ~s(aria-selected="true" data-m="curl")
    refute tabs =~ ~s(<div class="install-pane" data-m="curl" hidden>)
    assert tabs =~ ~s(<div class="install-pane" data-m="brew" hidden>)

    # Only channels that exist are linked: the script this site serves and
    # the published Hex package. brew/npm stay unlinked until they publish.
    assert tabs =~ ~s(href="/install")
    assert tabs =~ ~s(href="https://hex.pm/packages/raxol")
    refute tabs =~ "npmjs.com"
    refute tabs =~ "homebrew-tap"
  end

  test "the hero halo exports the coding agent's real face frames" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    assert hero =~ ~s(phx-hook="HaloField")
    assert hero =~ ~s(aria-hidden="true")
    # data-faces carries AxolFace.glyph/3 output: the branded gills and the
    # canonical state cycle, so the page and the TUI render the same face.
    assert hero =~ "≡··≡"
    assert hero =~ "idle"
    assert hero =~ "thinking"
    assert hero =~ "working"
    assert hero =~ "done"
  end

  test "surface chips group into the three places you already are" do
    surfaces = render_component(&LandingComponents.surfaces_deep_dive/1, %{})

    assert surfaces =~ "In your terminal"
    assert surfaces =~ "In your browser"
    assert surfaces =~ "Where your agents are"
    assert surfaces =~ "termbox2 NIF"
    assert surfaces =~ "Phoenix LiveView"
    assert surfaces =~ "JSON-RPC over stdio"
  end

  test "the closing section leads with a claim, proven by the commands beneath" do
    try_section = render_component(&LandingComponents.try_section/1, %{})

    assert try_section =~ "One module away from every surface."
    assert try_section =~ "four commands"
    assert try_section =~ "curl -fsSL https://raxol.io/install | bash"
  end

  test "nav links the demo index on desktop and mobile" do
    closed = render_component(&LandingComponents.nav_bar/1, mobile_menu_open: false)
    open = render_component(&LandingComponents.nav_bar/1, mobile_menu_open: true)

    assert closed =~ ~s(href="/demos")
    assert open =~ ~s(href="/demos")
  end

  @live_matrix %{
    source: :live,
    chains: [
      %{chain_id: 8453, chain_name: "Base", vm_type: :evm},
      %{chain_id: 728_126_428, chain_name: "Tron", vm_type: :tvm}
    ],
    tokens: [
      %{symbol: "WETH", roles: [:origin, :destination], addresses: %{8453 => "0xweth"}},
      %{symbol: "USDC", roles: [:origin, :destination], addresses: %{8453 => "0xabc"}},
      %{
        symbol: "USDT",
        roles: [:origin, :destination],
        addresses: %{8453 => "0xdef", 728_126_428 => "Txyz"}
      }
    ],
    deposit_attestation_signer: nil
  }

  test "payments section renders the ladder, dated proof, and a live matrix honestly" do
    payments = render_component(&LandingComponents.payments_deep_dive/1, matrix: @live_matrix)

    # Dated proof leads; maturity is labeled.
    assert payments =~ "2026-06-28"
    assert payments =~ "2026-07-20"
    assert payments =~ "0.2"

    # Fees come from FeeSchedule, the pinned mirror of the solver's published
    # schedule -- every tier, both asset classes, at the rates it actually
    # charges.
    for {tier, band, stable, volatile} <- [
          {"standard", "0-24", "22 bps", "40 bps"},
          {"trusted", "25-49", "19 bps", "35 bps"},
          {"verified", "50-74", "15 bps", "29 bps"},
          {"premium", "75-99", "12 bps", "25 bps"},
          {"institutional", "100 and above", "10 bps", "22 bps"}
        ] do
      assert payments =~ tier
      assert payments =~ band
      assert payments =~ stable
      assert payments =~ volatile
    end

    # The never-discounted floor is stated, because it is what makes a
    # zero-fee tier impossible.
    assert payments =~ "8 bps stable"
    assert payments =~ "never discounted"
    # Whitespace-tolerant: HEEx wraps prose across lines.
    assert payments =~ ~r/no zero-fee\s+tier/

    # The retired privacy-priced model must not come back: it named tiers no
    # solver has, and advertised a free one.
    refute payments =~ "sovereign"
    refute payments =~ "no fee, full disclosure"
    refute payments =~ "-2 bps"
    refute payments =~ "rebate"
    refute payments =~ ">open<"
    refute payments =~ "30 bps"

    # Privacy is still described, as the settlement mode it is.
    assert payments =~ "shielded"
    assert payments =~ "Privacy is a settlement mode"

    # Matrix rows from the data, stables before WETH, authored rail notes.
    assert payments =~ "source: live"
    assert payments =~ "Base"
    assert payments =~ "8453"
    assert payments =~ "TVM"
    assert payments =~ "relay rail"
    assert payments =~ ~r/USDC.*USDT.*WETH/s

    # No SVM chain in the data -> the greyed future row appears.
    assert payments =~ "Solana"
    assert payments =~ "lights up when the solver ships it"
  end

  test "an unreachable solver renders the cached badge, never fake liveness" do
    fallback = Raxol.Payments.Xochi.Capabilities.fallback()
    payments = render_component(&LandingComponents.payments_deep_dive/1, matrix: fallback)

    assert payments =~ "source: cached"
    refute payments =~ "source: live"
    assert payments =~ "Robinhood Chain"
    assert payments =~ "Permit2 pull"
  end

  # Pinned: these are the only strings on the site meant to be pasted into a
  # chain explorer, and a wrong character looks identical to a right one.
  test "the token block prints the verified contract and no market numbers" do
    payments = render_component(&LandingComponents.payments_deep_dive/1, matrix: @live_matrix)

    assert payments =~ "$RAXOL"
    assert payments =~ "0xf44702b17d9abD53815F703e772F35E9c71A53af"
    assert payments =~ "0xa20b68e2e1de71f1426b546ed5514bf253215a48"
    assert payments =~ "Robinhood Chain"
    assert payments =~ "4663"
    assert payments =~ "VIRTUAL"
    assert payments =~ "Uniswap"

    assert payments =~
             "https://dexscreener.com/robinhood/0xa20b68e2e1de71f1426b546ed5514bf253215a48"

    # A token beside a fee schedule invites the reading that it is what the
    # corridors move. Whitespace-tolerant: HEEx wraps prose across lines.
    assert payments =~ ~r/not a settlement\s+asset/

    # A market number would be stale by the next request.
    refute payments =~ ~r/\$\d/
    refute payments =~ ~r/\bFDV\b/i
    refute payments =~ ~r/market cap/i
  end

  test "coding agent section claims ACP membership and prints the four surfaces" do
    coding = render_component(&LandingComponents.coding_agent_deep_dive/1, %{})

    assert coding =~ "agentclientprotocol.com"
    assert coding =~ "Zed"
    assert coding =~ "mix raxol.code"
    assert coding =~ "raxol acp"
    assert coding =~ "raxol -p"
    assert coding =~ "mix mcp.server"
  end

  test "copy control and mobile menu use native accessible controls" do
    copy =
      render_component(&PlaygroundComponents.ssh_copy_block/1,
        id: "copy-install",
        cmd: "raxol doctor"
      )

    nav =
      render_component(&LandingComponents.nav_bar/1, mobile_menu_open: false)

    assert copy =~ "<button"
    assert copy =~ ~s(aria-label="Copy command: raxol doctor")
    assert copy =~ ~s(aria-live="polite")
    assert nav =~ ~s(aria-expanded="false")
    assert nav =~ ~s(aria-controls="mobile-navigation")
    assert nav =~ ~s(aria-label="Open menu")
  end

  describe "hosted SSH availability" do
    # The landing page has never advertised the suspended host (the test above
    # holds that line). These are the playground-side surfaces, which did: the
    # gallery/demo banner, the demo footer, and the no-terminal fallback. With
    # RAXOL_SSH_PLAYGROUND unset -- which is how it ships in fly.toml since the
    # 2026-08-26 suspension -- nothing may name a port that is not listening.
    test "callout and fallback offer only the local command while SSH is suspended" do
      refute Capabilities.ssh_available?()
      assert Capabilities.ssh_command() == nil

      banner = render_component(&PlaygroundComponents.ssh_callout/1, variant: :banner)
      footer = render_component(&PlaygroundComponents.ssh_callout/1, variant: :footer)
      fallback = render_component(&PlaygroundComponents.terminal_fallback/1, %{})

      rendered = Enum.join([banner, footer, fallback])

      refute rendered =~ "playground@raxol.io"
      refute rendered =~ "ssh -p"

      # The surface still has to be useful, not just silent.
      assert banner =~ "mix raxol.playground"
      assert footer =~ "mix raxol.playground"
      assert fallback =~ "mix raxol.playground"
    end

    test "the agent manifest omits the ssh link rather than publishing a dead one" do
      refute Map.has_key?(Capabilities.links(), :ssh)

      # The rest of the manifest is unaffected.
      assert Capabilities.links().playground == "https://raxol.io/playground"
    end

    test "re-enabling the env var restores every mention with no code change" do
      System.put_env("RAXOL_SSH_PLAYGROUND", "true")

      try do
        assert Capabilities.ssh_available?()
        assert Capabilities.ssh_command() == "ssh -p 2222 playground@raxol.io"
        assert Capabilities.links().ssh == "ssh -p 2222 playground@raxol.io"

        banner = render_component(&PlaygroundComponents.ssh_callout/1, variant: :banner)
        assert banner =~ "playground@raxol.io"
      after
        System.delete_env("RAXOL_SSH_PLAYGROUND")
      end
    end
  end
end
