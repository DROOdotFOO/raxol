defmodule Raxol.Core.ColorSystem do
  @moduledoc """
  Core color system for Raxol.

  This module provides a unified interface for managing colors and themes
  throughout the application. It integrates with the Style.Colors modules
  to provide a consistent color experience.

  ## Features

  - Theme management with semantic color naming
  - Color format conversion and validation
  - Accessibility checks and adjustments
  """

  alias Raxol.Style.Colors.{Color, Utilities}
  alias Raxol.UI.Theming.Colors
  alias Raxol.UI.Theming.Theme

  @doc """
  Creates a new theme with the given name and colors.

  ## Examples

      iex> theme = create_theme("dark", %{
      ...>   primary: "#FF0000",
      ...>   background: "#000000",
      ...>   text: "#FFFFFF"
      ...> })
      iex> theme.name
      "dark"
  """
  def create_theme(name, colors) when is_binary(name) and is_map(colors) do
    # Convert hex colors to Color structs
    colors =
      Map.new(colors, fn {key, value} -> {key, Color.from_hex(value)} end)

    %{
      name: name,
      colors: colors,
      created_at: DateTime.utc_now()
    }
  end

  @doc """
  Gets a color from the theme by its semantic name.

  ## Examples

      iex> theme = create_theme("dark", %{primary: "#FF0000"})
      iex> get_color(theme, :primary)
      %Color{r: 255, g: 0, b: 0, hex: "#FF0000"}
  """
  def get_color(theme, name) when is_map(theme) and is_atom(name) do
    get_in(theme, [:colors, name])
  end

  @doc """
  Gets a color from the theme by its semantic name with additional context.

  ## Examples

      iex> theme = create_theme("dark", %{primary: "#FF0000"})
      iex> get_color(theme, :primary, :foreground)
      %Color{r: 255, g: 0, b: 0, hex: "#FF0000"}
  """
  def get_color(theme, name, context)
      when is_map(theme) and is_atom(name) and is_atom(context) do
    color = get_in(theme, [:colors, name])

    case context do
      :foreground -> color
      :background -> color
      :accent -> color
      _ -> color
    end
  end

  @doc """
  Checks if two colors meet WCAG contrast requirements.

  ## Examples

      iex> theme = create_theme("dark", %{
      ...>   text: "#FFFFFF",
      ...>   background: "#000000"
      ...> })
      iex> meets_contrast_requirements?(theme, :text, :background, :AA, :normal)
      true
  """
  def meets_contrast_requirements?(theme, foreground, background, level, size) do
    fg = get_color(theme, foreground)
    bg = get_color(theme, background)

    Utilities.meets_contrast_requirements?(fg, bg, level, size)
  end

  @doc """
  Converts a color to its ANSI representation.

  ## Examples

      iex> theme = create_theme("dark", %{primary: "#FF0000"})
      iex> to_ansi(theme, :primary, :foreground)
      196
  """
  def to_ansi(theme, color_name, type) do
    color = get_color(theme, color_name)
    Color.to_ansi(color, type)
  end

  @doc """
  Adjusts a color to meet contrast requirements with another color.

  ## Examples

      iex> theme = create_theme("dark", %{
      ...>   text: "#808080",
      ...>   background: "#000000"
      ...> })
      iex> adjusted = adjust_for_contrast(theme, :text, :background, :AA, :normal)
      iex> meets_contrast_requirements?(adjusted, :text, :background, :AA, :normal)
      true
  """
  def adjust_for_contrast(theme, foreground, background, level, size) do
    fg = get_color(theme, foreground)
    bg = get_color(theme, background)

    do_adjust_for_contrast(
      Utilities.meets_contrast_requirements?(fg, bg, level, size),
      theme,
      foreground,
      fg,
      bg,
      level,
      size
    )
  end

  @spec do_adjust_for_contrast(any(), any(), any(), any(), any(), any(), any()) ::
          any()
  defp do_adjust_for_contrast(true, theme, _foreground, _fg, _bg, _level, _size) do
    theme
  end

  @spec do_adjust_for_contrast(
          any(),
          any(),
          any(),
          any(),
          any(),
          any(),
          non_neg_integer()
        ) :: any()
  defp do_adjust_for_contrast(false, theme, foreground, fg, bg, level, size) do
    # Adjust the foreground color to meet contrast requirements
    adjusted_fg = adjust_color_for_contrast(fg, bg, level, size)
    put_in(theme, [:colors, foreground], adjusted_fg)
  end

  @doc """
  Gets the effective color value for a given semantic color name.

  It retrieves the color from the specified theme (by ID), automatically considering
  whether a high contrast variant is active based on accessibility settings.

  Args:
    - `theme_id`: The atom ID of the theme to use (e.g., :default, :dark).
    - `color_name`: The semantic name of the color (e.g., :primary, :background).

  Returns the color value (e.g., :red, {:rgb, r, g, b}) or nil if not found.
  """
  @spec get(atom(), atom()) :: Raxol.UI.Theming.Theme.color_value() | nil
  def get(theme_id, color_name)
      when is_atom(theme_id) and is_atom(color_name) do
    # Get the theme struct using the correct alias
    theme = Theme.get(theme_id)
    do_get_color(theme, theme_id, color_name)
  end

  @spec do_get_color(
          any(),
          String.t() | integer(),
          Raxol.Terminal.Color.TrueColor.t()
        ) :: any()
  defp do_get_color(nil, theme_id, _color_name) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "ColorSystem: Theme with ID #{theme_id} not found. Falling back.",
      %{}
    )

    nil
  end

  @spec do_get_color(
          any(),
          String.t() | integer(),
          Raxol.Terminal.Color.TrueColor.t()
        ) :: any()
  defp do_get_color(theme, _theme_id, color_name) do
    # Get the active accessibility variant (e.g., :high_contrast)
    active_variant_id =
      Raxol.Core.Accessibility.ThemeIntegration.get_active_variant()

    # Check variant palette first, then base palette
    # Get variant palette safely
    variant_definition = safe_map_get(theme.variants, active_variant_id)

    variant_palette = get_variant_palette(variant_definition)
    base_palette = theme.colors

    lookup_color_in_palettes(color_name, variant_palette, base_palette)
  end

  defp get_variant_palette(nil), do: nil

  defp get_variant_palette(variant_definition) do
    safe_map_get(variant_definition, :palette)
  end

  @doc """
  Gets a color value and ensures it's returned in a specific format (e.g., RGB tuple).
  Useful when a specific color representation is required for rendering.

  Args:
    - `theme_id`: The atom ID of the theme to use.
    - `color_name`: The semantic name of the color.
    - `format`: The desired output format (:rgb_tuple, :hex_string, :term).

  Supported formats: :rgb_tuple, :hex_string, :term
  """
  @spec get_as(atom(), atom(), atom()) :: any() | nil
  def get_as(theme_id, color_name, format \\ :term)
      when is_atom(theme_id) and is_atom(color_name) and is_atom(format) do
    # Pass theme_id to get/2
    color_value = get(theme_id, color_name)

    case color_value do
      nil ->
        nil

      _ ->
        case format do
          :rgb_tuple ->
            Colors.to_rgb(color_value)

          :hex_string ->
            Colors.to_hex(color_value)

          # Return the raw term (:red, {:rgb, ...}, etc.)
          :term ->
            color_value

          _ ->
            # Log warning about unsupported format?
            # Fallback to raw term
            color_value
        end
    end
  end

  @doc """
  Initialize the color system with the given theme.

  ## Parameters

  * `theme_id` - The theme identifier to use (default: :default)

  ## Returns

  * `:ok` - Initialization successful
  * `{:error, reason}` - Initialization failed

  ## Examples

      iex> ColorSystem.init(:dark)
      :ok

      iex> ColorSystem.init()
      :ok
  """
  def init(theme_id \\ :default) do
    Raxol.Core.Runtime.Log.debug(
      "Initializing color system with theme: #{inspect(theme_id)}"
    )

    # Get the theme
    theme = Theme.get(theme_id)
    do_init(theme, theme_id)
  end

  defp do_init(nil, theme_id) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "ColorSystem: Theme #{theme_id} not found, using default",
      %{}
    )

    Raxol.Style.Colors.System.ColorSystemServer.set_current_theme(:default)
    :ok
  end

  defp do_init(_theme, theme_id) do
    # Store current theme in process dictionary for compatibility
    Raxol.Style.Colors.System.ColorSystemServer.set_current_theme(theme_id)
    :ok
  end

  @doc """
  Get the current theme configuration.

  ## Returns

  * `{:ok, theme}` - Current theme configuration
  * `{:error, reason}` - Failed to get theme

  ## Examples

      iex> ColorSystem.get_current_theme()
      {:ok, %{name: "default", colors: %{...}}}
  """
  def get_current_theme do
    theme_id =
      Raxol.Style.Colors.System.ColorSystemServer.get_current_theme_name() ||
        :default

    theme = Theme.get(theme_id)
    format_theme_result(theme)
  end

  defp format_theme_result(nil), do: {:error, :theme_not_found}
  defp format_theme_result(theme), do: {:ok, theme}

  @doc """
  Set the current theme.

  ## Parameters

  * `theme_id` - The theme identifier to set

  ## Returns

  * `:ok` - Theme set successfully
  * `{:error, reason}` - Failed to set theme

  ## Examples

      iex> ColorSystem.set_theme(:dark)
      :ok
  """
  def set_theme(theme_id) when is_atom(theme_id) do
    Raxol.Core.Runtime.Log.debug(
      "Setting color system theme to: #{inspect(theme_id)}"
    )

    theme = Theme.get(theme_id)
    do_set_theme(theme, theme_id)
  end

  defp do_set_theme(nil, _theme_id), do: {:error, :theme_not_found}

  defp do_set_theme(_theme, theme_id) do
    Raxol.Style.Colors.System.ColorSystemServer.set_current_theme(theme_id)
    :ok
  end

  # Private functions

  @spec adjust_color_for_contrast(any(), any(), any(), non_neg_integer()) ::
          any()
  defp adjust_color_for_contrast(fg, bg, level, size) do
    # Start with the original color
    current = fg
    step = 0.1

    # Try lightening first
    lightened = Color.lighten(current, step)

    try_contrast_adjustment(
      Utilities.meets_contrast_requirements?(lightened, bg, level, size),
      lightened,
      current,
      bg,
      level,
      size,
      step
    )
  end

  @spec try_contrast_adjustment(any(), any(), any(), any(), any(), any(), any()) ::
          any()
  defp try_contrast_adjustment(
         true,
         lightened,
         _current,
         _bg,
         _level,
         _size,
         _step
       ) do
    lightened
  end

  @spec try_contrast_adjustment(
          any(),
          any(),
          any(),
          any(),
          any(),
          non_neg_integer(),
          any()
        ) :: any()
  defp try_contrast_adjustment(
         false,
         _lightened,
         current,
         bg,
         level,
         size,
         step
       ) do
    # If lightening doesn't work, try darkening
    darkened = Color.darken(current, step)

    try_darkening(
      Utilities.meets_contrast_requirements?(darkened, bg, level, size),
      darkened,
      bg
    )
  end

  defp try_darkening(true, darkened, _bg), do: darkened

  defp try_darkening(false, _darkened, bg) do
    # If neither works, try the opposite of the background
    Color.complement(bg)
  end

  defp safe_map_get(data, key, default \\ nil) do
    do_safe_map_get(is_map(data), data, key, default)
  end

  defp do_safe_map_get(true, data, key, default) do
    Map.get(data, key, default)
  end

  defp do_safe_map_get(false, _data, _key, default), do: default

  defp lookup_color_in_palettes(color_name, variant_palette, base_palette) do
    case {variant_palette && Map.has_key?(variant_palette, color_name),
          Map.has_key?(base_palette, color_name)} do
      {true, _} ->
        safe_map_get(variant_palette, color_name)

      {false, true} ->
        safe_map_get(base_palette, color_name)

      _ ->
        # Color not found in either palette
        nil
    end
  end
end
