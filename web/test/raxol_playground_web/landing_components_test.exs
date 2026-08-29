defmodule RaxolPlaygroundWeb.LandingComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias RaxolPlaygroundWeb.LandingComponents
  alias RaxolPlaygroundWeb.PlaygroundComponents

  test "landing promotes live install and browser paths, not the suspended SSH host" do
    hero =
      render_component(&LandingComponents.hero_section/1,
        raxol_version: "2.5",
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
