defmodule Raxol.Style.Colors.System do
  @moduledoc """
  Refactored Color System module with GenServer-based state management.

  This module provides backward compatibility while eliminating Process dictionary usage.
  All state is now managed through the Colors.System.Server GenServer.

  ## Migration Notes

  This module replaces direct Process dictionary usage with supervised GenServer state.
  The API remains the same, but the implementation is now OTP-compliant and more robust.

  ## Features Maintained

  * Theme management and switching
  * High contrast mode support
  * Automatic accessibility adjustments
  * Color caching and resolution
  * Event-driven theme changes
  """


  alias Raxol.Style.Colors.{Color, Utilities}
  alias Raxol.Style.Colors.System.ColorSystemServer, as: Server
  alias Raxol.UI.Theming.Theme

  @default_theme :default

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      Server,
      fn -> Server.start_link(name: Server) end
    )
  end

  @doc """
  Initialize the color system.

  This sets up the default themes, registers event handlers for accessibility changes,
  and establishes the default color palette.

  ## Options

  * `:theme` - The initial theme to use (default: `:default`)
  * `:high_contrast` - Whether to start in high contrast mode (default: from accessibility settings)

  ## Examples

      iex> ColorSystem.init()
      :ok

      iex> ColorSystem.init(theme: :dark)
      :ok
  """
  def init(opts \\ []) do
    ensure_server_started()

    # Don't call server during initialization to avoid deadlock
    # The server is initialized via ensure_server_started()
    # Just apply the initial theme if needed
    initial_theme_id = Keyword.get(opts, :theme, @default_theme)
    high_contrast = Keyword.get(opts, :high_contrast, false)

    # Only apply theme if it's not the default
    if initial_theme_id != @default_theme or high_contrast do
      apply_theme(initial_theme_id, high_contrast: high_contrast)
    end

    :ok
  end

  @doc """
  Get a color from the current theme.

  This function respects the current accessibility settings, automatically
  returning high-contrast alternatives when needed.

  ## Parameters

  * `color_name` - The semantic name of the color (e.g., `:primary`, `:error`)
  * `variant` - The variant of the color (e.g., `:base`, `:hover`, `:active`) (default: `:base`)

  ## Examples

      iex> ColorSystem.get_color(:primary)
      "#0077CC"

      iex> ColorSystem.get_color(:primary, :hover)
      "#0088DD"
  """
  def get_color(color_name, variant \\ :base) do
    ensure_server_started()
    Server.get_color(color_name, variant)
  end

  @doc """
  Register a custom theme.

  ## Parameters

  * `theme_attrs` - Map of theme attributes

  ## Examples

      iex> ColorSystem.register_theme(%{
      ...>   primary: "#0077CC",
      ...>   secondary: "#00AAFF",
      ...>   background: "#001133",
      ...>   foreground: "#FFFFFF",
      ...>   accent: "#FF9900"
      ...> })
      :ok
  """
  def register_theme(theme_attrs) do
    ensure_server_started()
    Server.register_theme(theme_attrs)
  end

  @doc """
  Applies a theme to the color system.

  ## Parameters

  - `theme_name` - The name of the theme to apply
  - `opts` - Additional options
    - `:high_contrast` - Whether to apply high contrast mode (default: current setting)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  def apply_theme(theme_name, opts \\ []) do
    ensure_server_started()
    Server.apply_theme(theme_name, opts)
  end

  @doc """
  Handle high contrast mode changes from the accessibility module.
  """
  def handle_high_contrast(
        event_type \\ :accessibility_high_contrast,
        event_data
      ) do
    ensure_server_started()
    Server.handle_high_contrast(event_type, event_data)
  end

  @doc """
  Get the current theme name.
  """
  def get_current_theme_name do
    ensure_server_started()
    Server.get_current_theme_name()
  end

  @doc """
  Get a UI color by role (e.g., :primary_button) from the current theme.
  Resolves the role using the theme's ui_mappings, then fetches the color.
  Returns nil if the role or color is not found.
  """
  @spec get_ui_color(atom()) :: any()
  def get_ui_color(ui_role) do
    ensure_server_started()
    Server.get_ui_color(ui_role)
  end

  @doc """
  Get all UI colors for the current theme as a map of role => color.
  """
  @spec get_all_ui_colors() :: map()
  def get_all_ui_colors do
    ensure_server_started()
    Server.get_all_ui_colors()
  end

  @doc """
  Get all UI colors for a specific theme as a map of role => color.
  """
  def get_all_ui_colors(theme) do
    ensure_server_started()

    # For a specific theme, we need to temporarily apply it or calculate manually
    (theme.ui_mappings || %{})
    |> Enum.map(fn {role, color_name} ->
      color_atom =
        case is_atom(color_name) do
          true -> color_name
          false -> String.to_atom(color_name)
        end

      {role, get_color_from_theme(theme, color_atom)}
    end)
    |> Enum.into(%{})
  end

  # Private helper for theme-specific color resolution
  defp get_color_from_theme(theme, color_name, variant \\ :base) do
    val =
      Map.get(theme.variants || %{}, {color_name, variant}) ||
        Map.get(theme.colors, color_name)

    case val do
      %Color{} = c -> c
      hex when is_binary(hex) -> Color.from_hex(hex)
      _ -> nil
    end
  end

  # --- Color manipulation functions (delegated) ---

  def lighten_color(%Color{} = color, amount) do
    Color.lighten(color, amount)
  end

  def darken_color(%Color{} = color, amount) do
    Color.darken(color, amount)
  end

  def increase_contrast(%Color{} = color) do
    Utilities.increase_contrast(color)
  end

  def adjust_for_contrast(%Color{} = color, %Color{} = background, level, size) do
    Utilities.adjust_for_contrast(color, background, level, size)
  end

  def meets_contrast_requirements?(%Color{} = fg, %Color{} = bg, level, size) do
    Utilities.meets_contrast_requirements?(fg, bg, level, size)
  end

  # --- Theme creation functions ---

  def create_dark_theme do
    %Theme{
      name: "dark",
      colors: %{
        primary: Color.from_hex("#90CAF9"),
        secondary: Color.from_hex("#B0BEC5"),
        background: Color.from_hex("#121212"),
        text: Color.from_hex("#FFFFFF")
      },
      ui_mappings: %{
        app_background: :background,
        surface_background: :background,
        primary_button: :primary,
        secondary_button: :secondary,
        text: :text
      },
      metadata: %{dark_mode: true}
    }
  end

  def create_high_contrast_theme do
    %Theme{
      name: "high_contrast",
      colors: %{
        primary: Color.from_hex("#FFFF00"),
        secondary: Color.from_hex("#000000"),
        background: Color.from_hex("#000000"),
        text: Color.from_hex("#FFFFFF")
      },
      ui_mappings: %{
        app_background: :background,
        surface_background: :background,
        primary_button: :primary,
        secondary_button: :secondary,
        text: :text
      },
      metadata: %{high_contrast: true}
    }
  end

  # Backward compatibility functions

  @doc false
  def get_current_theme do
    ensure_server_started()
    Server.get_current_theme()
  end

  @doc false
  def get_high_contrast do
    ensure_server_started()
    Server.get_high_contrast()
  end
end
