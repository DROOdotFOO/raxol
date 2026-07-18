defmodule Raxol.UI.ThemeResolver do
  @moduledoc """
  Consolidated theme resolution, color processing, and theme-related utilities.

  This module provides theme resolution with optional caching for high-performance applications.

  ## Configuration

  Set the default caching strategy in application config:

      config :raxol, :theme_resolver,
        cache_enabled: true

  Or control per-call with options:

      ThemeResolver.resolve_styles(attrs, component_type, theme, cache: true)

  ## Caching (formerly Raxol.UI.ThemeResolverCached)

  The removed `Raxol.UI.ThemeResolverCached` shim mapped one-to-one onto
  cached calls here:

      Raxol.UI.ThemeResolver.resolve_styles(attrs, component_type, theme, cache: true)
      Raxol.UI.ThemeResolver.get_default_theme(cache: true)

  ## Examples

      # Non-cached (simple operations)
      theme = ThemeResolver.resolve_element_theme(element_theme, default_theme)

      # Cached (performance-critical operations)
      {fg, bg, attrs} = ThemeResolver.resolve_styles(attrs, :button, theme, cache: true)
  """

  # Caching configuration and helpers

  defp should_use_cache?(opts) do
    cache_from_opts = Keyword.get(opts, :cache)

    cache_from_config =
      Application.get_env(:raxol, :theme_resolver, [])[:cache_enabled]

    # opts override config, default to false
    enabled =
      case {cache_from_opts, cache_from_config} do
        {nil, nil} -> false
        {nil, config} -> config not in [nil, false]
        {opt, _} -> opt not in [nil, false]
      end

    enabled and cache_available?()
  end

  defp cache_available? do
    Code.ensure_loaded?(Raxol.Performance.ETSCacheManager) and
      Process.whereis(Raxol.Performance.ETSCacheManager) != nil
  end

  @doc """
  Resolves an element's theme, handling string themes and providing fallbacks.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def resolve_element_theme(element_theme, default_theme, opts \\ [])

  def resolve_element_theme(element_theme, default_theme, opts) do
    if should_use_cache?(opts) do
      resolve_element_theme_cached(element_theme, default_theme)
    else
      resolve_element_theme_direct(element_theme, default_theme)
    end
  end

  # Cached implementation
  defp resolve_element_theme_cached(element_theme, default_theme) do
    # For string themes, cache the lookup
    case element_theme do
      theme_name when is_binary(theme_name) ->
        cache_key = {:theme_lookup, theme_name}

        case get_cached_theme(cache_key) do
          {:ok, theme} ->
            theme

          :miss ->
            theme = resolve_element_theme_direct(element_theme, default_theme)
            cache_theme(cache_key, theme)
            theme
        end

      _ ->
        # For non-string themes, use direct resolver
        resolve_element_theme_direct(element_theme, default_theme)
    end
  end

  # Direct implementation (original logic)
  defp resolve_element_theme_direct(element_theme, default_theme) do
    case element_theme do
      nil ->
        default_theme

      theme when is_binary(theme) ->
        # Try to get theme by name, fallback to default
        case Raxol.UI.Theming.Theme.get(theme) do
          nil -> default_theme
          found_theme -> found_theme
        end

      theme when is_map(theme) ->
        theme

      _ ->
        default_theme
    end
  end

  @doc """
  Resolves an element's theme with inheritance support.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def resolve_element_theme_with_inheritance(element, default_theme, opts \\ [])

  def resolve_element_theme_with_inheritance(element, default_theme, opts) do
    if should_use_cache?(opts) do
      resolve_element_theme_with_inheritance_cached(element, default_theme)
    else
      resolve_element_theme_with_inheritance_direct(element, default_theme)
    end
  end

  # Cached implementation
  defp resolve_element_theme_with_inheritance_cached(element, default_theme) do
    # Create cache key based on element's theme configuration
    cache_key = build_inheritance_cache_key(element)

    case get_cached_theme(cache_key) do
      {:ok, theme} ->
        theme

      :miss ->
        theme =
          resolve_element_theme_with_inheritance_direct(element, default_theme)

        cache_theme(cache_key, theme)
        theme
    end
  end

  # Direct implementation (original logic)
  defp resolve_element_theme_with_inheritance_direct(element, default_theme) do
    # Get the main theme
    main_theme =
      resolve_element_theme_direct(Map.get(element, :theme), default_theme)

    # Check for parent theme inheritance
    parent_theme = Map.get(element, :parent_theme)

    merge_parent_theme_if_present(parent_theme, main_theme)
  end

  @doc """
  Merges themes for inheritance (parent theme as base, child theme overrides).
  """
  def merge_themes_for_inheritance(parent_theme, child_theme) do
    # Merge colors (child overrides parent)
    merged_colors =
      Map.merge(
        Map.get(parent_theme, :colors, %{}),
        Map.get(child_theme, :colors, %{})
      )

    # Merge component styles (child overrides parent)
    merged_component_styles =
      Map.merge(
        Map.get(parent_theme, :component_styles, %{}),
        Map.get(child_theme, :component_styles, %{})
      )

    # Merge variants (child overrides parent)
    merged_variants =
      Map.merge(
        Map.get(parent_theme, :variants, %{}),
        Map.get(child_theme, :variants, %{})
      )

    # Create merged theme
    Map.merge(parent_theme, %{
      colors: merged_colors,
      component_styles: merged_component_styles,
      variants: merged_variants
    })
  end

  @doc """
  Gets the default theme with fallback creation.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def get_default_theme(opts \\ [])

  def get_default_theme(opts) do
    if should_use_cache?(opts) do
      get_default_theme_cached()
    else
      get_default_theme_direct()
    end
  end

  # Cached implementation
  defp get_default_theme_cached do
    cache_key = :default_theme

    case get_cached_theme(cache_key) do
      {:ok, theme} ->
        theme

      :miss ->
        theme = get_default_theme_direct()
        cache_theme(cache_key, theme)
        theme
    end
  end

  # Direct implementation (original logic)
  defp get_default_theme_direct do
    case Raxol.UI.Theming.Theme.get(:default) do
      nil -> create_fallback_theme()
      theme -> theme
    end
  end

  @doc """
  Creates a fallback theme when no default theme is available.
  """
  def create_fallback_theme do
    %{
      colors: %{
        foreground: :white,
        background: :black
      },
      component_styles: %{},
      variants: %{}
    }
  end

  @doc """
  Resolves foreground and background colors with proper fallbacks.
  Returns {fg_color, bg_color, style_attrs}.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def resolve_styles(attrs, component_type, theme, opts \\ [])

  def resolve_styles(attrs, component_type, theme, opts) do
    if should_use_cache?(opts) do
      resolve_styles_cached(attrs, component_type, theme)
    else
      resolve_styles_direct(attrs, component_type, theme)
    end
  end

  # Cached implementation
  defp resolve_styles_cached(attrs, component_type, theme) do
    # Generate cache key
    theme_id = get_theme_id(theme)
    attrs_hash = hash_attrs(attrs)

    # Check cache first
    case get_cached_style(theme_id, component_type, attrs_hash) do
      {:ok, cached_result} ->
        cached_result

      :miss ->
        # Compute and cache the result
        result = resolve_styles_direct(attrs, component_type, theme)
        cache_style(theme_id, component_type, attrs_hash, result)
        result
    end
  end

  # Direct implementation (original logic)
  defp resolve_styles_direct(attrs, component_type, theme) do
    component_styles = get_component_styles(component_type, theme)
    fg_color = resolve_fg_color(attrs, component_styles, theme)
    bg_color = resolve_bg_color(attrs, component_styles, theme)
    style_attrs = resolve_style_attrs(attrs, component_styles)

    {fg_color, bg_color, style_attrs}
  end

  @doc """
  Resolves foreground color with proper fallbacks.
  """
  def resolve_fg_color(attrs, _component_styles, theme) do
    attrs
    |> get_explicit_color([:fg, :foreground])
    |> fallback_to_variant_color(attrs, theme, :foreground)
    |> fallback_to_theme_color(theme, :foreground, :white)
    |> convert_color_to_atom()
  end

  @doc """
  Resolves background color with proper fallbacks.
  """
  # Deliberately no fallback to the theme's global background, unlike the
  # foreground: text needs a colour, but a background does not. An element that
  # asks for no background gets none, and the cell keeps the terminal's own --
  # which is what leaves it transparent on a terminal with transparency on.
  # Falling back to the theme's `background` painted every element with the
  # terminal's own colour: invisible on an opaque terminal, an opaque rectangle
  # on a transparent one.
  def resolve_bg_color(attrs, _component_styles, theme) do
    attrs
    |> get_explicit_color([:bg, :background])
    |> fallback_to_variant_color(attrs, theme, :background)
    |> convert_color_to_atom()
  end

  @doc """
  Resolves style attributes from explicit attrs and component styles.
  """
  def resolve_style_attrs(attrs, component_styles) do
    explicit_attrs = Map.get(attrs, :style, []) |> ensure_list()
    component_attrs = Map.get(component_styles, :style, []) |> ensure_list()
    (explicit_attrs ++ component_attrs) |> Enum.uniq()
  end

  @doc """
  Resolves color from theme variant.
  """
  def resolve_variant_color(attrs, theme, color_type) do
    variant_name = Map.get(attrs, :variant)

    get_variant_color_if_valid(variant_name, theme, color_type)
  end

  @doc """
  Gets component styles from theme.
  """
  def get_component_styles(component_type, theme) do
    get_component_styles_if_valid(component_type, theme)
  end

  defp get_component_styles_from_map(component_styles, component_type)
       when is_map(component_styles) do
    Map.get(component_styles, component_type, %{})
  end

  defp get_component_styles_from_map(_, _), do: %{}

  # Convert color values to atoms for test compatibility
  defp convert_color_to_atom(color) when is_atom(color), do: color

  defp convert_color_to_atom(color) when is_binary(color) do
    hex_to_color_atom(String.downcase(color))
  end

  defp convert_color_to_atom(%{r: r, g: g, b: b}) do
    # Convert RGB color struct to hex and then to atom
    hex =
      "##{Integer.to_string(r, 16) |> String.pad_leading(2, "0")}#{Integer.to_string(g, 16) |> String.pad_leading(2, "0")}#{Integer.to_string(b, 16) |> String.pad_leading(2, "0")}"

    convert_color_to_atom(hex)
  end

  # Default fallback
  defp convert_color_to_atom(_), do: :white

  defp hex_to_color_atom("#ffffff"), do: :white
  defp hex_to_color_atom("#000000"), do: :black
  defp hex_to_color_atom("#ff0000"), do: :red
  defp hex_to_color_atom("#00ff00"), do: :green
  defp hex_to_color_atom("#0000ff"), do: :blue
  defp hex_to_color_atom("#ffff00"), do: :yellow
  defp hex_to_color_atom("#ff00ff"), do: :magenta
  defp hex_to_color_atom("#00ffff"), do: :cyan
  # Default fallback
  defp hex_to_color_atom(_), do: :white

  defp ensure_list(value), do: Raxol.Core.Utils.List.ensure_list(value)

  # Helper functions to reduce complexity
  defp get_explicit_color(attrs, color_keys) do
    Enum.find_value(color_keys, fn key ->
      get_attr_value_if_present(attrs, key)
    end)
  end

  defp fallback_to_variant_color(nil, attrs, theme, color_type) do
    resolve_variant_color(attrs, theme, color_type)
  end

  defp fallback_to_variant_color(color, _attrs, _theme, _color_type), do: color

  defp fallback_to_theme_color(nil, theme, color_type, default) do
    get_theme_color(theme, color_type, default)
  end

  defp fallback_to_theme_color(color, _theme, _color_type, _default), do: color

  defp get_theme_color(nil, _color_type, default), do: default

  defp get_theme_color(theme, _color_type, default) when not is_map(theme),
    do: default

  defp get_theme_color(theme, color_type, default) do
    case Map.get(theme, :colors) do
      nil -> default
      colors when is_map(colors) -> Map.get(colors, color_type, default)
      _ -> default
    end
  end

  ## Pattern matching helper functions for if statement elimination

  defp merge_parent_theme_if_present(parent_theme, main_theme)
       when is_map(parent_theme) do
    # Merge parent theme with main theme (main theme overrides parent)
    merge_themes_for_inheritance(parent_theme, main_theme)
  end

  defp merge_parent_theme_if_present(_parent_theme, main_theme), do: main_theme

  defp get_variant_color_if_valid(nil, _theme, _color_type), do: nil
  defp get_variant_color_if_valid(_variant_name, nil, _color_type), do: nil

  defp get_variant_color_if_valid(_variant_name, theme, _color_type)
       when not is_map(theme),
       do: nil

  defp get_variant_color_if_valid(variant_name, theme, color_type) do
    variants = Map.get(theme, :variants, %{})
    variant = Map.get(variants, variant_name)
    get_color_from_variant(variant, color_type)
  end

  defp get_color_from_variant(variant, color_type) when is_map(variant) do
    Map.get(variant, color_type)
  end

  defp get_color_from_variant(_variant, _color_type), do: nil

  defp get_component_styles_if_valid(nil, _theme), do: %{}

  defp get_component_styles_if_valid(_component_type, theme)
       when not is_map(theme),
       do: %{}

  defp get_component_styles_if_valid(component_type, theme) do
    theme
    |> Map.get(:component_styles, %{})
    |> get_component_styles_from_map(component_type)
  end

  defp get_attr_value_if_present(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> value
    end
  end

  # Cache Management Functions

  @doc """
  Clear all theme/style caches.
  """
  def clear_cache do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.clear_cache(:style)
    end
  end

  @doc """
  Invalidate cache entries for a specific theme.
  """
  def invalidate_theme(_theme_id) do
    # This would require more sophisticated cache management
    # For now, clear all style cache when a theme changes
    clear_cache()
  end

  # Private cache operation helpers

  defp get_cached_style(theme_id, component_type, attrs_hash) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.get_style(
        theme_id,
        component_type,
        attrs_hash
      )
    else
      :miss
    end
  end

  defp cache_style(theme_id, component_type, attrs_hash, result) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.cache_style(
        theme_id,
        component_type,
        attrs_hash,
        result
      )
    end
  end

  defp get_cached_theme(key) do
    if cache_available?() do
      # Use the style cache table for theme data
      Raxol.Performance.ETSCacheManager.get_style(
        :theme_cache,
        nil,
        :erlang.phash2(key)
      )
    else
      :miss
    end
  end

  defp cache_theme(key, theme) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.cache_style(
        :theme_cache,
        nil,
        :erlang.phash2(key),
        theme
      )
    end
  end

  # Cache key generation helpers

  defp get_theme_id(nil), do: :no_theme
  defp get_theme_id(theme) when is_atom(theme), do: theme
  defp get_theme_id(theme) when is_binary(theme), do: theme

  defp get_theme_id(theme) when is_map(theme) do
    # Use theme name if available, otherwise hash the theme
    Map.get(theme, :name, :erlang.phash2(theme))
  end

  defp get_theme_id(_), do: :unknown_theme

  defp hash_attrs(nil), do: 0

  defp hash_attrs(attrs) when is_map(attrs) do
    # Create a stable hash of relevant style attributes
    relevant_keys = [
      :fg,
      :foreground,
      :bg,
      :background,
      :variant,
      :style,
      :bold,
      :italic,
      :underline,
      :blink,
      :reverse
    ]

    attrs
    |> Map.take(relevant_keys)
    |> :erlang.phash2()
  end

  defp hash_attrs(_), do: 0

  defp hash_theme(nil), do: 0

  defp hash_theme(theme) when is_map(theme) do
    # Hash only the parts of theme that affect style resolution
    %{
      colors: Map.get(theme, :colors, %{}),
      component_styles: Map.get(theme, :component_styles, %{}),
      variants: Map.get(theme, :variants, %{})
    }
    |> :erlang.phash2()
  end

  defp hash_theme(_), do: 0

  defp build_inheritance_cache_key(element) do
    element_theme = Map.get(element, :theme)
    parent_theme = Map.get(element, :parent_theme)

    {:inheritance, get_theme_id(element_theme), hash_theme(parent_theme)}
  end
end
