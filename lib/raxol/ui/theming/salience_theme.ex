defmodule Raxol.UI.Theming.SalienceTheme do
  @moduledoc """
  Builds a `Raxol.UI.Theming.Theme` from salience-tier seeds solved against
  the terminal's actual background.

  Colors are expressed as `(hue, chroma, tier)` seeds — hue carries identity,
  tier carries importance — and `Raxol.UI.Theming.Salience` solves the
  lightness of every color so each tier reads perceptually level on the
  detected ground. Works on dark and light terminals from one seed table.

  Ground detection uses the driver's OSC 11 background query
  (`Raxol.Terminal.Driver.BackgroundQuery`) when a reply arrived, falling
  back to the reference near-black ground otherwise. Apps that want to react
  to late detection can rebuild on the `:terminal_background` event.
  """

  alias Raxol.UI.Theming.Salience
  alias Raxol.UI.Theming.Theme

  @compile {:no_warn_undefined, Raxol.Terminal.Driver.BackgroundQuery}

  @fallback_ground 0.2

  # Semantic seed table. Hues follow the compensated-Darcula family:
  # orange 57 (warning), yellow 77 (emphasis), green 134 (success),
  # blue 242 (accent), neutral-blue 250 (text), red 25 (error).
  @seeds [
    %{name: :foreground, h: 250, c: 0.022, tier: :baseline},
    %{name: :accent, h: 242, c: 0.074, tier: :differentiate},
    %{name: :error, h: 25, c: 0.16, tier: :alarm},
    %{name: :warning, h: 57, c: 0.13, tier: :differentiate},
    %{name: :success, h: 134, c: 0.075, tier: :differentiate},
    %{name: :emphasis, h: 77, c: 0.125, tier: :anchor},
    %{name: :muted, h: 250, c: 0.0, tier: :recede},
    %{name: :border, h: 250, c: 0.0, tier: :recede}
  ]

  @doc "The default semantic seed table."
  @spec seeds() :: [map()]
  def seeds, do: @seeds

  @doc """
  Detected ground lightness: OKLCH `L` of the OSC 11-reported terminal
  background, or `#{@fallback_ground}` when detection is unavailable.
  """
  @spec detect_ground() :: float()
  def detect_ground do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Driver.BackgroundQuery),
         {:ok, {r, g, b}} <-
           Raxol.Terminal.Driver.BackgroundQuery.detected_background() do
      {l, _c, _h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
      l
    else
      _ -> @fallback_ground
    end
  end

  @doc """
  Builds a Theme with every color solved against the ground.

  ## Options

    * `:ground` - ground lightness override (default: `detect_ground/0`)
    * `:seeds` - seed table override (default: `seeds/0`)
    * `:id` / `:name` - theme identity (default `:salience`)
  """
  @spec build(keyword()) :: Theme.t()
  def build(opts \\ []) do
    ground = Keyword.get_lazy(opts, :ground, &detect_ground/0)
    seeds = Keyword.get(opts, :seeds, @seeds)
    palette = Salience.solve_palette(seeds, ground: ground)

    background = Salience.oklch_to_hex(ground, 0.0, 0.0)

    Theme.new(%{
      id: Keyword.get(opts, :id, :salience),
      name: Keyword.get(opts, :name, "salience"),
      colors: %{
        background: background,
        foreground: palette.foreground,
        accent: palette.accent,
        error: palette.error,
        warning: palette.warning,
        success: palette.success,
        emphasis: palette.emphasis,
        muted: palette.muted
      },
      component_styles: %{
        text_input: %{
          background: background,
          foreground: palette.foreground,
          border: palette.border,
          focus: palette.accent
        },
        button: %{
          background: palette.accent,
          foreground: background,
          hover: palette.emphasis,
          active: palette.accent
        },
        checkbox: %{
          background: background,
          foreground: palette.foreground,
          border: palette.border,
          checked: palette.accent
        },
        table: %{
          border: :single,
          header_foreground: palette.emphasis,
          row_foreground: palette.foreground,
          selected_row_foreground: palette.accent
        },
        focus: %{border: :single, border_fg: palette.accent},
        disabled: %{fg: palette.muted}
      }
    })
  end
end
