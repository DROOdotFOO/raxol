defmodule Raxol.UI.CellDim do
  @moduledoc """
  Cell-level color dimming for content sitting behind an active modal
  dialog.

  Every element type eventually becomes `{x, y, char, fg, bg, attrs}`
  cells before paint (`Raxol.UI.Renderer`), so dimming is implemented once
  here at that choke point instead of duplicating a "dim" branch in every
  `render_visible_element/3` clause.

  Dimming is theme-aware, Helmholtz-Kohlrausch-compensated contrast
  compression toward the detected terminal ground, built on
  `Raxol.UI.Theming.Salience`: a color's *apparent* lightness (not its
  naive RGB channel values) is pulled toward the ground's apparent
  lightness. Naive `rgb * factor` scaling darkens everything uniformly,
  which makes chromatic colors (blues especially, per the H-K effect)
  read darker than gray at the same nominal scale on dark grounds, and
  does nothing to wash colors out on light grounds -- direction has to be
  hand-branched per theme. Interpolating in apparent-lightness space
  toward ground makes the direction fall out automatically: dark ground
  pulls dimmed content darker, light ground pulls it lighter (washed
  toward white), from the same formula.

  `nil` fg/bg (terminal default -- the element never painted a color)
  always stays `nil`; only colors an element actually painted get pulled
  toward the ground.
  """

  alias Raxol.UI.Theming.Colors, as: ThemeColors
  alias Raxol.UI.Theming.Salience

  # Cross-package: raxol_terminal is a compile-time dep of the main app,
  # but mirrors `Raxol.UI.Theming.SalienceTheme`'s guard pattern for the
  # same optional-detection callsite.
  @compile {:no_warn_undefined, Raxol.Terminal.Driver.BackgroundQuery}

  # Fraction of the ground-apparent-lightness *contrast* a dimmed color
  # retains (both in apparent lightness and chroma) -- 0.45 keeps the hue
  # legible while reading clearly muted.
  @contrast_keep 0.45

  # ANSI-16 atom -> code, matching `Raxol.Core.Renderer.Color`'s private
  # `@ansi_16_map` ordering. Only routes to `ThemeColors.ansi_to_rgb/1`'s
  # canonical xterm RGB table below -- no hex values invented here.
  @ansi_16_codes %{
    black: 0,
    red: 1,
    green: 2,
    yellow: 3,
    blue: 4,
    magenta: 5,
    cyan: 6,
    white: 7,
    bright_black: 8,
    bright_red: 9,
    bright_green: 10,
    bright_yellow: 11,
    bright_blue: 12,
    bright_magenta: 13,
    bright_cyan: 14,
    bright_white: 15
  }

  # Unknown atom colors (`:default`, theme-custom names not in the
  # ANSI-16 set): resolved to mid-gray before dimming rather than passed
  # through unchanged, so the modal-dimming contrast cue still reads
  # consistently for them instead of silently not dimming at all: a
  # mid-gray has zero chroma, so it dims predictably toward ground on
  # both light and dark themes without guessing at a hue that isn't
  # there.
  @unknown_atom_rgb {128, 128, 128}

  @doc "Dims every cell's fg/bg in a list toward the detected terminal ground."
  @spec dim_cells([tuple()]) :: [tuple()]
  def dim_cells(cells) do
    ground_al = ground_apparent_lightness()

    cache =
      cells
      |> Enum.flat_map(fn {_x, _y, _char, fg, bg, _attrs} -> [fg, bg] end)
      |> Enum.uniq()
      |> Map.new(&{&1, dim_color(&1, ground_al)})

    Enum.map(cells, fn {x, y, char, fg, bg, attrs} ->
      {x, y, char, Map.fetch!(cache, fg), Map.fetch!(cache, bg), attrs}
    end)
  end

  @doc "Dims a single `{x, y, char, fg, bg, attrs}` cell's fg/bg."
  @spec dim_cell(tuple()) :: tuple()
  def dim_cell({x, y, char, fg, bg, attrs}) do
    ground_al = ground_apparent_lightness()
    {x, y, char, dim_color(fg, ground_al), dim_color(bg, ground_al), attrs}
  end

  @doc """
  Dims a single color value against the detected (or reference-fallback)
  terminal ground. See `dim_color/2` for per-type behavior.
  """
  @spec dim_color(any()) :: any()
  def dim_color(color), do: dim_color(color, ground_apparent_lightness())

  @doc """
  Dims a single color value against an explicit ground apparent lightness
  (as returned by `ground_apparent_lightness/0`).

  * `nil` (unpainted cell) always stays `nil`.
  * ANSI-16 atoms resolve to their canonical RGB first (unknown atoms,
    including `:default` and theme-custom names, resolve to mid-gray).
  * `{r, g, b}` tuples and `"#rrggbb"` hex strings dim via OKLCH.
  * Integers (256-color palette indices) pass through unchanged -- there
    is no general reverse mapping from an index to a hue without
    inventing one.
  """
  @spec dim_color(any(), float()) :: any()
  def dim_color(nil, _ground_al), do: nil

  def dim_color({r, g, b}, ground_al)
      when is_integer(r) and is_integer(g) and is_integer(b) do
    dim_rgb(r, g, b, ground_al)
  end

  def dim_color(color, ground_al) when is_atom(color) do
    {r, g, b} = atom_to_rgb(color)
    dim_rgb(r, g, b, ground_al)
  end

  def dim_color("#" <> _ = hex, ground_al) do
    {l, c, h} = Salience.hex_to_oklch(hex)
    {new_l, new_c, new_h} = dim_oklch(l, c, h, ground_al)
    Salience.oklch_to_hex(new_l, new_c, new_h)
  end

  def dim_color(other, _ground_al), do: other

  @doc """
  Apparent lightness of the current ground: the OSC 11-detected terminal
  background when available, else `Raxol.UI.Theming.Salience`'s reference
  ground.
  """
  @spec ground_apparent_lightness() :: float()
  def ground_apparent_lightness do
    case detected_ground_oklch() do
      {:ok, {l, c, h}} ->
        Salience.apparent_lightness(l, c, h)

      :error ->
        Salience.apparent_lightness(Salience.reference_ground(), 0.0, 0.0)
    end
  end

  defp detected_ground_oklch do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Driver.BackgroundQuery),
         true <-
           function_exported?(
             Raxol.Terminal.Driver.BackgroundQuery,
             :detected_background,
             0
           ),
         {:ok, {r, g, b}} <-
           Raxol.Terminal.Driver.BackgroundQuery.detected_background() do
      {:ok, Salience.rgb_to_oklch(r / 255, g / 255, b / 255)}
    else
      _ -> :error
    end
  end

  defp atom_to_rgb(color) do
    case Map.fetch(@ansi_16_codes, color) do
      {:ok, code} -> ThemeColors.ansi_to_rgb(code)
      :error -> @unknown_atom_rgb
    end
  end

  defp dim_rgb(r, g, b, ground_al) do
    {l, c, h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
    {new_l, new_c, new_h} = dim_oklch(l, c, h, ground_al)
    Salience.oklch_to_rgb(new_l, new_c, new_h)
  end

  # Pull (l, c, h)'s apparent lightness toward `ground_al`, keeping
  # `@contrast_keep` of the original contrast, and desaturate by the same
  # factor so hue identity survives while reading muted. Solve back to a
  # nominal `l` that lands on the new apparent lightness.
  defp dim_oklch(l, c, h, ground_al) do
    apparent_l = Salience.apparent_lightness(l, c, h)
    new_apparent_l = ground_al + (apparent_l - ground_al) * @contrast_keep
    new_c = c * @contrast_keep
    new_l = Salience.solve_lightness(new_apparent_l, new_c, h)
    {new_l, new_c, h}
  end
end
