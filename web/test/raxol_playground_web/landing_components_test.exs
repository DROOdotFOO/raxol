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
