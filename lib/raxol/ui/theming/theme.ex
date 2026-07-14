defmodule Raxol.UI.Theming.Theme do
  @moduledoc """
  Theme management for Raxol UI components.

  This module provides functionality for:
  - Theme definition and management
  - Color palette integration
  - Component styling
  - Theme variants and accessibility
  """

  alias Raxol.Core.ColorSystem
  alias Raxol.Style.Colors.{Color, Utilities}

  @type color_value :: Color.t() | atom() | String.t()
  @type style_map :: %{atom() => any()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          colors: map() | nil,
          component_styles: map() | nil,
          styles: map() | nil,
          variants: map() | nil,
          metadata: map() | nil,
          fonts: map() | nil,
          ui_mappings: map() | nil,
          dark_mode: boolean() | nil
        }

  # # @derive Jason.Encoder
  defstruct [
    :id,
    :name,
    :description,
    :colors,
    :component_styles,
    :styles,
    :variants,
    :metadata,
    :fonts,
    :ui_mappings,
    :dark_mode,
    :high_contrast
  ]

  @behaviour Access

  @impl true
  def fetch(%__MODULE__{} = theme, key) when is_atom(key) or is_binary(key) do
    Map.fetch(theme, key)
  end

  @impl true
  def get_and_update(%__MODULE__{} = theme, key, fun)
      when is_atom(key) or is_binary(key) do
    Map.get_and_update(theme, key, fun)
  end

  @impl true
  def pop(%__MODULE__{} = theme, key) when is_atom(key) or is_binary(key) do
    Map.pop(theme, key)
  end

  @doc """
  Creates a new theme with the given attributes.
  """
  def new, do: new(default_attrs())

  def new(attrs) when is_map(attrs) do
    attrs = process_colors(attrs)

    attrs =
      attrs
      |> Map.update(:component_styles, %{}, fn
        nil ->
          %{}

        map ->
          Map.put_new(map, :button, %{background: "#000000"})
      end)
      |> Map.update(:styles, %{}, fn
        nil ->
          %{}

        map ->
          Map.put_new(map, :button, %{background: "#000000"})
      end)

    attrs = Map.put(attrs, :styles, attrs[:component_styles])

    struct(__MODULE__, attrs)
  end

  @doc """
  Gets a color from the theme, respecting variants and accessibility settings.
  """
  def get_color(theme, color_name, arg3 \\ nil)

  def get_color(%__MODULE__{} = theme, color_name, variant) do
    ColorSystem.get_color(theme.id, color_name, variant)
  end

  def get_color(theme, color_name, default) do
    get_in(theme, [:colors, color_name]) || default
  end

  @doc """
  Gets a component style from the theme.
  """
  def get_component_style(%__MODULE__{} = theme, component_type) do
    case get_in(theme, [:component_styles, component_type]) do
      nil -> %{}
      style -> style
    end
  end

  def get_component_style(theme_map, component_type) when is_map(theme_map) do
    case get_in(theme_map, [component_type]) do
      nil -> %{}
      style -> style
    end
  end

  @doc """
  Creates a high contrast variant of the theme.
  """
  def create_high_contrast_variant(%__MODULE__{} = theme) do
    high_contrast_colors =
      Enum.map(theme.colors, fn {name, color} ->
        {name, Utilities.increase_contrast(color)}
      end)
      |> Map.new()

    %{
      theme
      | colors: high_contrast_colors,
        variants:
          Map.put(theme.variants, :high_contrast, %{
            colors: high_contrast_colors
          })
    }
  end

  @doc """
  Returns a high-contrast version of the given theme, for accessibility support.
  If the theme is already high-contrast, returns it unchanged.
  """
  def adjust_for_high_contrast(%__MODULE__{} = theme) do
    create_high_contrast_variant(theme)
  end

  @doc """
  Gets a theme by ID.
  """
  def get(theme_id) do
    case Application.get_env(:raxol, :themes) do
      nil -> default_theme()
      themes -> Map.get(themes, theme_id, default_theme())
    end
  end

  @doc """
  Gets a value from the theme using a path.
  """
  def get(%__MODULE__{} = theme, [first | rest]) do
    key = normalize_key(first)
    value = get_in(theme, [key | rest])
    process_value(value, key, rest)
  end

  @doc """
  Returns the current theme.
  """
  def current do
    Application.get_env(:raxol, :current_theme, default_theme())
  end

  @doc """
  Returns the default theme.
  """
  def default_theme do
    new(%{
      id: :default,
      name: "default",
      colors: %{
        background: "#000000",
        # A raised opaque surface -- a dialog, a panel. Distinct from
        # :background, which is only this theme's assumption about the
        # terminal's own canvas and is never painted (ADR-0029). A surface IS
        # painted, on purpose, so it needs a colour of its own.
        surface: "#1E1E1E",
        foreground: "#FFFFFF",
        accent: "#4A9CD5",
        error: "#FF5555",
        warning: "#FFB86C",
        success: "#50FA7B",
        fuschia: "#FF00FF"
      },
      component_styles: %{
        text_input: %{
          background: "#1E1E1E",
          foreground: "#FFFFFF",
          border: "#4A9CD5",
          focus: "#4A9CD5"
        },
        button: %{
          background: "#4A9CD5",
          foreground: "#FFFFFF",
          hover: "#5FB0E8",
          active: "#3A8CC5"
        },
        checkbox: %{
          background: "#1E1E1E",
          foreground: "#FFFFFF",
          border: "#4A9CD5",
          checked: "#4A9CD5"
        },
        text_field: %{
          border: :single,
          padding: {0, 1}
        },
        table: %{
          border: :single,
          header_background: Color.from_hex("#222831"),
          header_foreground: Color.from_hex("#FFFFFF"),
          row_background: Color.from_hex("#1E1E1E"),
          row_foreground: Color.from_hex("#FFFFFF"),
          selected_row_background: Color.from_hex("#4A9CD5"),
          selected_row_foreground: Color.from_hex("#FFFFFF")
        },
        focus: %{border: :single, border_fg: :cyan},
        disabled: %{fg: :gray},
        active: %{border: :double, border_fg: :white}
      }
    })
  end

  @doc """
  Returns the dark theme.
  """
  def dark_theme do
    new(%{
      id: :dark,
      name: "dark",
      colors: %{
        background: "#1E1E1E",
        foreground: "#FFFFFF",
        accent: "#4A9CD5",
        error: "#FF5555",
        warning: "#FFB86C",
        success: "#50FA7B",
        fuschia: "#FF00FF"
      },
      component_styles: %{
        text_input: %{
          background: "#2D2D2D",
          foreground: "#FFFFFF",
          border: "#4A9CD5",
          focus: "#4A9CD5"
        },
        button: %{
          background: "#4A9CD5",
          foreground: "#FFFFFF",
          hover: "#5FB0E8",
          active: "#3A8CC5"
        },
        checkbox: %{
          background: "#2D2D2D",
          foreground: "#FFFFFF",
          border: "#4A9CD5",
          checked: "#4A9CD5"
        }
      }
    })
  end

  def component_style(theme, component_type),
    do: get_component_style(theme, component_type)

  # Private helpers

  defp process_colors(attrs) do
    handle_colors(Map.has_key?(attrs, :colors), attrs)
  end

  defp handle_colors(true, attrs) do
    Map.update!(attrs, :colors, &convert_hex_colors/1)
  end

  defp handle_colors(false, attrs) do
    attrs
  end

  defp convert_hex_colors(colors) do
    Enum.into(colors, %{}, fn
      {k, v} when is_binary(v) ->
        {k, Raxol.Style.Colors.Color.from_hex(v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp default_attrs do
    %{
      id: :default,
      name: "Default Theme",
      description: "The default Raxol theme",
      colors: %{
        primary: Color.from_hex("#0077CC"),
        secondary: Color.from_hex("#666666"),
        accent: Color.from_hex("#FF9900"),
        background: Color.from_hex("#FFFFFF"),
        surface: Color.from_hex("#F5F5F5"),
        error: Color.from_hex("#CC0000"),
        success: Color.from_hex("#009900"),
        warning: Color.from_hex("#FF9900"),
        info: Color.from_hex("#0099CC"),
        text: Color.from_hex("#000000"),
        foreground: Color.from_hex("#000000")
      },
      component_styles: %{
        panel: %{
          border: :single,
          padding: 1
        },
        button: %{
          padding: {0, 1},
          text_style: [:bold]
        },
        text_field: %{
          border: :single,
          padding: {0, 1}
        }
      },
      variants: %{},
      metadata: %{
        author: "Raxol",
        version: "1.0.0"
      },
      fonts: %{
        default: %{
          family: "monospace",
          size: 12,
          weight: "normal"
        }
      },
      ui_mappings: %{
        app_background: :background,
        surface_background: :surface,
        primary_button: :primary,
        secondary_button: :secondary,
        accent_button: :accent,
        error_text: :error,
        success_text: :success,
        warning_text: :warning,
        info_text: :info,
        text: :text
      }
    }
  end

  @doc """
  Initializes the theme system and registers the default theme.
  This should be called during application startup.
  """
  def init do
    default_theme = new()
    register(default_theme)
    :ok
  end

  @doc """
  Registers a theme in the application environment.
  """
  def register(%__MODULE__{} = theme) do
    current_themes = Application.get_env(:raxol, :themes, %{})
    new_themes = Map.put(current_themes, theme.id, theme)
    Application.put_env(:raxol, :themes, new_themes)
    :ok
  end

  @doc """
  Applies a theme by name or struct.
  """
  def apply_theme(%__MODULE__{} = theme) do
    Application.put_env(:raxol, :current_theme, theme)
    :ok
  end

  def apply_theme(theme_name) when is_atom(theme_name) do
    case get(theme_name) do
      nil -> {:error, :theme_not_found}
      theme -> apply_theme(theme)
    end
  end

  @doc """
  Lists all available themes.
  """
  def list_themes do
    case Application.get_env(:raxol, :themes) do
      nil -> [default_theme()]
      themes -> Map.values(themes)
    end
  end

  def default_theme_id, do: :default

  case Code.ensure_loaded?(String.Chars) do
    true ->
      defimpl String.Chars, for: __MODULE__ do
        def to_string(theme) do
          "#<Theme id=#{inspect(theme.id)} name=#{inspect(theme.name)} colors=#{inspect(Map.keys(theme.colors))}>"
        end
      end

    false ->
      :ok
  end

  @doc """
  Merges two themes, with the second theme overriding values from the first.
  """
  def merge(%__MODULE__{} = base_theme, %__MODULE__{} = override_theme) do
    merged_colors = Map.merge(base_theme.colors, override_theme.colors)

    merged_component_styles =
      deep_merge(base_theme.component_styles, override_theme.component_styles)

    merged_fonts = deep_merge(base_theme.fonts, override_theme.fonts)
    merged_variants = deep_merge(base_theme.variants, override_theme.variants)
    merged_metadata = deep_merge(base_theme.metadata, override_theme.metadata)

    merged_ui_mappings =
      deep_merge(base_theme.ui_mappings, override_theme.ui_mappings)

    merged_styles = merged_component_styles

    %__MODULE__{
      id: override_theme.id || base_theme.id,
      name: override_theme.name || base_theme.name,
      description: override_theme.description || base_theme.description,
      colors: merged_colors,
      component_styles: merged_component_styles,
      styles: merged_styles,
      variants: merged_variants,
      metadata: merged_metadata,
      fonts: merged_fonts,
      ui_mappings: merged_ui_mappings
    }
  end

  @doc """
  Creates a child theme that inherits from a parent theme.
  """
  def inherit(%__MODULE__{} = parent_theme, %__MODULE__{} = child_theme) do
    merge(parent_theme, child_theme)
  end

  defp deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, v1, v2 ->
      case {is_map(v1), is_map(v2)} do
        {true, true} ->
          deep_merge(v1, v2)

        _ ->
          v2
      end
    end)
  end

  defp deep_merge(_map1, map2), do: map2

  defp normalize_key(:styles), do: :component_styles
  defp normalize_key(key), do: key

  defp process_value(value, _key, rest) when is_map(value),
    do: ensure_button_background(value, rest)

  defp process_value(:default, key, rest), do: handle_missing_value(key, rest)
  defp process_value(nil, key, rest), do: handle_missing_value(key, rest)
  defp process_value(value, _key, _rest), do: value

  defp ensure_button_background(value, rest) do
    case {Enum.any?(rest, &(&1 == :button)), Map.has_key?(value, :background)} do
      {true, false} ->
        Map.put(value, :background, "#000000")

      _ ->
        value
    end
  end

  defp handle_missing_value(:component_styles, [:button | _]),
    do: %{background: "#000000"}

  defp handle_missing_value(:colors, [_ | _] = rest) do
    color_key = List.last(rest)
    get_color_fallback(color_key)
  end

  defp handle_missing_value(_, _), do: nil

  defp get_color_fallback(:white), do: :white
  defp get_color_fallback(:black), do: :black
  defp get_color_fallback(:green), do: :green
  defp get_color_fallback(:red), do: :red
  defp get_color_fallback(:yellow), do: :yellow
  defp get_color_fallback(:blue), do: :blue
  defp get_color_fallback(:cyan), do: :cyan
  defp get_color_fallback(:foreground), do: :white
  defp get_color_fallback(:background), do: :black
  defp get_color_fallback(_), do: :white
end
