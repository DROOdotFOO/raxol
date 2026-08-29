defmodule RaxolPlaygroundWeb.LandingComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias RaxolPlaygroundWeb.LandingComponents
  alias RaxolPlaygroundWeb.PlaygroundComponents

  test "landing promotes live install and browser paths, not the suspended SSH host" do
    hero =
      render_component(&LandingComponents.hero_section/1,
        terminal_html: false,
        demo_paused: false
      )

    deep_dive = render_component(&LandingComponents.ssh_deep_dive/1, %{})
    try_section = render_component(&LandingComponents.try_section/1, %{})

    assert hero =~ "https://raxol.io/install"
    assert hero =~ "Self-contained binary"
    assert deep_dive =~ "Hosted SSH is temporarily offline"
    assert deep_dive =~ ~s(href="/playground")
    assert try_section =~ "npm i -g raxol"

    refute Enum.join([hero, deep_dive, try_section]) =~ "playground@raxol.io"
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
      render_component(&LandingComponents.hero_section/1,
        terminal_html: false,
        demo_paused: false
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

    # Ladder derives from PrivacyTier.all/0, minus the retired :open
    # rebate tier (a PFOF-shaped rebate is unlawful in the EU -- the page
    # must not advertise it even while the code still carries it).
    assert payments =~ "sovereign"
    assert payments =~ "shielded"
    assert payments =~ "no fee, full disclosure"
    refute payments =~ "-2 bps"
    refute payments =~ "rebate"
    refute payments =~ ">open<"

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
end
