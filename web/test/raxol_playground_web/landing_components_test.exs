defmodule RaxolPlaygroundWeb.LandingComponentsTest do
  # Not async: the SSH-availability tests flip RAXOL_SSH_PLAYGROUND, which is
  # VM-global. Four component renders are cheap; a racy env read is not.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias RaxolPlayground.Capabilities
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
