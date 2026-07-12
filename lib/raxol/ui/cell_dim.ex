defmodule Raxol.UI.CellDim do
  @moduledoc """
  Cell-level color dimming for content sitting behind an active modal
  dialog.

  Every element type eventually becomes `{x, y, char, fg, bg, attrs}`
  cells before paint (`Raxol.UI.Renderer`), so dimming is implemented once
  here at that choke point instead of duplicating a "dim" branch in every
  `render_visible_element/3` clause.

  Dimming pulls a color's H-K-compensated *apparent* lightness (via
  `Raxol.UI.Theming.Salience`), not its raw RGB channels, toward the
  detected terminal ground -- naive `rgb * factor` scaling reads
  chromatic colors (blues especially) darker than gray at the same
  nominal scale, and interpolating in apparent-lightness space makes the
  darken-on-dark-ground / wash-on-light-ground direction fall out of the
  same formula instead of being hand-branched per theme.

  `nil` fg/bg (never painted) always stays `nil`. `ElementRenderer`/
  `BorderRenderer` default every unpainted background to the atom
  `:black` (see their `resolve_bg/1`), so `:black` is the de facto
  unpainted-bg sentinel and passes through undimmed for backgrounds --
  `dim_fg/2` treats a painted `fg: :black` as a real color and dims it.
  """

  alias Raxol.UI.Theming.Colors, as: ThemeColors
  alias Raxol.UI.Theming.Salience

  # Optional cross-package dep (same pattern as SalienceTheme).
  @compile {:no_warn_undefined, Raxol.Terminal.Driver.BackgroundQuery}

  # Fraction of the ground-apparent-lightness *contrast* a dimmed color
  # retains -- 0.45 keeps the dim/non-dim distinction unambiguous without
  # crushing everything to near-ground.
  @contrast_keep 0.45

  # Keep more chroma than contrast so ANSI hues stay legible (not flat gray).
  @chroma_keep 0.65

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

  # Unknown atoms -> mid-gray so they still take the dim cue.
  @unknown_atom_rgb {128, 128, 128}

  @doc "Dims every cell's fg/bg in a list toward the detected terminal ground."
  @spec dim_cells([tuple()]) :: [tuple()]
  def dim_cells(cells) do
    ground_al = ground_apparent_lightness()

    fg_cache =
      cells
      |> Enum.map(fn {_x, _y, _char, fg, _bg, _attrs} -> fg end)
      |> Enum.uniq()
      |> Map.new(&{&1, dim_fg(&1, ground_al)})

    bg_cache =
      cells
      |> Enum.map(fn {_x, _y, _char, _fg, bg, _attrs} -> bg end)
      |> Enum.uniq()
      |> Map.new(&{&1, dim_bg(&1, ground_al)})

    Enum.map(cells, fn {x, y, char, fg, bg, attrs} ->
      {x, y, char, Map.get(fg_cache, fg), Map.get(bg_cache, bg), attrs}
    end)
  end

  @doc """
  Dims a foreground color. Same as `dim_color/2` except a painted
  `:black` is treated as a real color (dimmed), not the bg-only
  unpainted sentinel -- see moduledoc.
  """
  @spec dim_fg(any(), float()) :: any()
  def dim_fg(:black, ground_al) do
    {r, g, b} = atom_to_rgb(:black)
    dim_rgb(r, g, b, ground_al)
  end

  def dim_fg(color, ground_al), do: dim_color(color, ground_al)

  @doc "Dims a background color. Alias of `dim_color/2` (bg-oriented, `:black` sentinel)."
  @spec dim_bg(any(), float()) :: any()
  def dim_bg(color, ground_al), do: dim_color(color, ground_al)

  @doc """
  Dims a single color value against the detected (or reference-fallback)
  terminal ground. See `dim_color/2` for per-type behavior.
  """
  @spec dim_color(any()) :: any()
  def dim_color(color), do: dim_color(color, ground_apparent_lightness())

  @doc """
  Dims a single color value against an explicit ground apparent lightness
  (as returned by `ground_apparent_lightness/0`). Bg-oriented -- see
  `dim_fg/2` for foregrounds.

  * `nil` stays `nil`; `:black` stays `:black` (bg unpainted sentinel,
    see moduledoc).
  * Other ANSI-16 atoms resolve to canonical RGB first (unknown atoms,
    including `:default` and theme-custom names, resolve to mid-gray).
  * `{r, g, b}` tuples and `"#rrggbb"` hex strings dim via OKLCH.
  * Integers (256-color palette indices) pass through unchanged -- there
    is no general reverse mapping from an index to a hue without
    inventing one.
  """
  @spec dim_color(any(), float()) :: any()
  def dim_color(nil, _ground_al), do: nil
  def dim_color(:black, _ground_al), do: :black

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
  # `@contrast_keep` of the original contrast, and desaturate by the
  # (larger) `@chroma_keep` factor so hue identity survives clearly rather
  # than reading as flat gray. Solve back to a nominal `l` that lands on
  # the new apparent lightness.
  defp dim_oklch(l, c, h, ground_al) do
    apparent_l = Salience.apparent_lightness(l, c, h)
    new_apparent_l = ground_al + (apparent_l - ground_al) * @contrast_keep
    new_c = c * @chroma_keep
    new_l = Salience.solve_lightness(new_apparent_l, new_c, h)
    {new_l, new_c, h}
  end
end
