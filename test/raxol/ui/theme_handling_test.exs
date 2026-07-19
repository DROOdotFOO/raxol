defmodule Raxol.UI.ThemeHandlingTest do
  use ExUnit.Case
  alias Raxol.Test.RendererTestHelper, as: Helper
  alias Raxol.UI.Renderer
  alias Raxol.UI.Theming.Theme
  alias Raxol.UI.ColorResolver
  alias Raxol.UI.Harness.Prominence

  setup do
    # Ensure UserPreferences is started for tests
    case Raxol.Core.UserPreferences.start_link(test_mode?: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Initialize theme system
    Theme.init()

    :ok
  end

  test "handles missing themes" do
    element = Helper.create_test_box(0, 0, 5, 5, %{theme: "nonexistent"})
    cells = Renderer.render_to_cells(element)

    # Debug: print what cells were rendered
    IO.puts("DEBUG: Element: #{inspect(element)}")
    IO.puts("DEBUG: Cells rendered: #{length(cells)}")
    IO.puts("DEBUG: First few cells: #{inspect(Enum.take(cells, 5))}")

    # Should use default theme. Attr-less text over an unpainted bg is nil,
    # not :white (region-prominence-propagation.md §3.1/§9 Phase 3, case a)
    # -- the terminal's own default fg shows through.
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil)
  end

  test "handles missing theme colors" do
    theme = Helper.create_test_theme("test", "Test Theme", "Test theme", %{})
    element = Helper.create_test_box(0, 0, 5, 5, %{theme: theme})
    cells = Renderer.render_to_cells(element)

    # Should use default colors. Attr-less, no bg painted: fg stays nil
    # (region-prominence-propagation.md §9 Phase 3, case a).
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil)
  end

  test "handles style overrides" do
    theme =
      Helper.create_test_theme("test", "Test Theme", "Test theme", %{
        foreground: :red,
        background: :blue
      })

    element =
      Helper.create_test_box(0, 0, 5, 5, %{
        theme: theme,
        style: %{foreground: :green, background: :yellow}
      })

    cells = Renderer.render_to_cells(element)

    # Style should override theme
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, :green, :yellow)
  end

  test "handles border style overrides" do
    theme =
      Helper.create_test_theme("test", "Test Theme", "Test theme", %{
        border_style: %{type: :double}
      })

    # border must be explicit (renderer default :none)
    element =
      Helper.create_test_box(0, 0, 5, 5, %{
        theme: theme,
        border: :single,
        border_style: %{type: :single}
      })

    cells = Renderer.render_to_cells(element)

    # Border style should be overridden. Attr-less: no bg painted here, so
    # fg stays nil, not a theme-fed default (region-prominence-propagation.md
    # §9 Phase 3, case a).
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil, [:single])
  end

  test "handles default border styles" do
    # border must be explicit (renderer default :none); this test covers
    # the theme's default border STYLING, not border presence.
    element = Helper.create_test_box(0, 0, 5, 5, %{border: :single})
    cells = Renderer.render_to_cells(element)

    # Should use default border style. Attr-less, no bg painted: fg is nil,
    # not the theme's global foreground (region-prominence-propagation.md
    # §9 Phase 3, case a) -- the theme-global-foreground catch-all this test
    # used to exercise is exactly the forcing-chain link Phase 3 dismantles.
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil, [:single])
  end

  test "handles no borders" do
    element = Helper.create_test_box(0, 0, 5, 5, %{border: false})
    cells = Renderer.render_to_cells(element)

    # Should not have border style. Attr-less, no bg painted: fg is nil
    # (region-prominence-propagation.md §9 Phase 3, case a).
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil, [])
  end

  test "handles theme inheritance" do
    parent_theme =
      Helper.create_test_theme("parent", "Parent Theme", "Parent theme", %{
        foreground: :red,
        background: :blue
      })

    child_theme =
      Helper.create_test_theme("child", "Child Theme", "Child theme", %{
        foreground: :green
      })

    element =
      Helper.create_test_box(0, 0, 5, 5, %{
        theme: child_theme,
        parent_theme: parent_theme
      })

    cells = Renderer.render_to_cells(element)

    # No style override on the element itself, and no bg painted anywhere
    # in the chain -- attr-less fg stays nil (region-prominence-propagation.md
    # §9 Phase 3, case a). Theme.colors.foreground is no longer force-fed to
    # plain elements; only an explicit style/variant reference gets a theme
    # color (see "handles theme variants" below, and "theme inheritance"
    # further down for the merge-semantics-only coverage of this fixture's
    # actual claim: parent/child color inheritance on the Theme struct
    # itself, independent of rendering).
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, nil, nil)
  end

  test "handles theme variants" do
    theme =
      Helper.create_test_theme("test", "Test Theme", "Test theme", %{
        variants: %{
          "error" => %{foreground: :red},
          "success" => %{foreground: :green}
        }
      })

    element =
      Helper.create_test_box(0, 0, 5, 5, %{
        theme: theme,
        variant: "error"
      })

    cells = Renderer.render_to_cells(element)

    # Should use error variant
    cell = Helper.get_cell_at(cells, 0, 0)
    Helper.assert_cell_style(cell, :red, nil)
  end

  test "theme initialization" do
    theme =
      Helper.create_test_theme(
        "test",
        %{
          primary: "#FF0000",
          secondary: "#00FF00"
        },
        %{
          button: %{background: "#000000"}
        },
        %{
          default: %{family: "monospace"}
        }
      )

    assert theme.name == "test"
    assert theme.colors.primary == "#FF0000"
    assert theme.styles.button.background == "#000000"
    assert theme.fonts.default.family == "monospace"
  end

  test "theme merging" do
    base_theme =
      Helper.create_test_theme(
        "test",
        %{
          primary: "#FF0000",
          secondary: "#00FF00"
        },
        %{
          button: %{background: "#000000"}
        },
        %{
          default: %{family: "monospace"}
        }
      )

    override_theme =
      Helper.create_test_theme(
        "test",
        %{
          primary: "#0000FF"
        },
        %{
          button: %{text: "#FFFFFF"}
        },
        %{
          default: %{size: 14}
        }
      )

    merged = Theme.merge(base_theme, override_theme)

    assert merged.colors.primary == "#0000FF"
    assert merged.colors.secondary == "#00FF00"
    assert merged.styles.button.background == "#000000"
    assert merged.styles.button.text == "#FFFFFF"
    assert merged.fonts.default.family == "monospace"
    assert merged.fonts.default.size == 14
  end

  test "theme inheritance" do
    parent_theme =
      Helper.create_test_theme(
        "parent",
        %{
          primary: "#FF0000",
          secondary: "#00FF00"
        },
        %{
          button: %{background: "#000000"}
        },
        %{
          default: %{family: "monospace"}
        }
      )

    child_theme =
      Helper.create_test_theme(
        "child",
        %{
          primary: "#0000FF"
        },
        %{
          button: %{text: "#FFFFFF"}
        },
        %{
          default: %{size: 14}
        }
      )

    inherited = Theme.inherit(parent_theme, child_theme)

    assert inherited.colors.primary == "#0000FF"
    assert inherited.colors.secondary == "#00FF00"
    assert inherited.styles.button.background == "#000000"
    assert inherited.styles.button.text == "#FFFFFF"
    assert inherited.fonts.default.family == "monospace"
    assert inherited.fonts.default.size == 14
  end

  test ~c"theme access" do
    theme =
      Helper.create_test_theme(
        "test",
        %{
          primary: "#FF0000",
          secondary: "#00FF00"
        },
        %{
          button: %{background: "#000000"}
        },
        %{
          default: %{family: "monospace"}
        }
      )

    assert Theme.get(theme, [:colors, :primary]) == "#FF0000"
    assert Theme.get(theme, [:styles, :button, :background]) == "#000000"
    assert Theme.get(theme, [:fonts, :default, :family]) == "monospace"
  end

  describe "RP-P-06 -- attr-less default (region-prominence-propagation.md §9 Phase 3)" do
    # The two grounds the doc's own falsifier names: near-black (a typical
    # dark terminal) and near-white (a typical light terminal). Chosen wide
    # apart on purpose -- this is exactly the F1 axis (`05-salience.md`)
    # a hardcoded-ground bug would fail on one side of.
    @grounds [0.2, 0.92]

    test "unpainted bg: attr-less fg is nil end-to-end, at both grounds, with no ground ever cached" do
      element = Helper.create_test_text(0, 0, "hi")

      for ground <- @grounds do
        cells =
          element
          |> Renderer.render_to_cells_unresolved(nil)
          |> ColorResolver.resolve_cells(ground: ground)

        cell = Helper.get_cell_at(cells, 0, 0)
        Helper.assert_cell_style(cell, nil, nil)
      end

      # "with no ground ever cached": the ordinary entry point
      # (`Renderer.render_to_cells/1`) lets `ColorResolver` fall back to
      # `SalienceTheme.detect_ground/0` instead of an explicit value --
      # case (a) must not depend on any ground ever having been
      # detected/cached; it never even LOOKS at ground, since a `nil` fg
      # short-circuits before any ground read (`ColorResolver.resolve_fg/5`'s
      # first clause).
      cells = Renderer.render_to_cells(element)
      cell = Helper.get_cell_at(cells, 0, 0)
      Helper.assert_cell_style(cell, nil, nil)
    end

    test "painted bg: attr-less fg resolves via the baseline-tier ColorIntent, meeting the AA :text floor against the LOCAL bg" do
      painted_bg = "#3355AA"

      panel =
        Helper.create_test_panel(
          0,
          0,
          10,
          3,
          [Helper.create_test_text(1, 1, "hi")],
          %{style: %{background: painted_bg}}
        )

      for ground <- @grounds do
        cells =
          panel
          |> Renderer.render_to_cells_unresolved(nil)
          |> ColorResolver.resolve_cells(ground: ground)

        cell = Helper.get_cell_at(cells, 1, 1)
        assert cell != nil
        {_x, _y, _char, fg, bg, _attrs} = cell

        # bg cascaded from the panel down to the text cell
        # (StyleProcessor's `@inheritable_properties`) -- this IS the
        # element-painted-bg case (a: unpainted stays nil; b: painted gets
        # the intent), driven purely by style-flatten-time cascading, no
        # `color_resolver.ex` grid change needed.
        assert bg == painted_bg

        assert is_binary(fg) and String.starts_with?(fg, "#"),
               "expected a resolved hex fg (baseline intent solved against " <>
                 "the LOCAL bg), got #{inspect(fg)} at ground #{ground}"

        assert Prominence.wcag_ratio(fg, bg) >= 4.5,
               "attr-less text over a painted bg must meet the AA :text " <>
                 "floor (4.5) against its LOCAL bg, got " <>
                 "#{Prominence.wcag_ratio(fg, bg)} at ground #{ground}"
      end
    end
  end
end
