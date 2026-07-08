defmodule Raxol.UI.StyleProcessor do
  @moduledoc """
  Handles style processing, merging, inheritance, and flattening.

  Supports optional caching for performance-critical applications.

  ## Configuration

  Set caching mode in application config:

      config :raxol, :style_processor,
        cache_enabled: true

  Or control per-call with options:

      StyleProcessor.flatten_merged_style(parent, child, theme, cache: true)

  ## Migration from StyleProcessorCached

  Replace:
      Raxol.UI.StyleProcessorCached.flatten_merged_style(parent, child, theme)

  With:
      Raxol.UI.StyleProcessor.flatten_merged_style(parent, child, theme, cache: true)
  """

  @doc """
  Flattens and merges styles from parent style and child element with proper theme resolution.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def flatten_merged_style(parent_style, child_element, theme, opts \\ []) do
    if should_use_cache?(opts) do
      flatten_merged_style_cached(parent_style, child_element, theme)
    else
      flatten_merged_style_direct(parent_style, child_element, theme)
    end
  end

  # Cached implementation
  defp flatten_merged_style_cached(parent_style, child_element, theme) do
    cache_key = build_flatten_cache_key(parent_style, child_element, theme)

    case get_cached_flattened_style(cache_key) do
      {:ok, cached_style} ->
        cached_style

      :miss ->
        flattened =
          flatten_merged_style_direct(parent_style, child_element, theme)

        cache_flattened_style(cache_key, flattened)
        flattened
    end
  end

  # Properties that cascade from parent to child (text styling).
  # Layout properties (padding, border, width, height, margin) do NOT inherit.
  @inheritable_properties [
    :fg,
    :bg,
    :foreground,
    :background,
    :fg_color,
    :bg_color,
    :bold,
    :italic,
    :underline,
    :strikethrough,
    :reverse,
    :dim
  ]

  # Direct implementation with cascading inheritance.
  # Priority (highest wins): child top-level attrs > child :style map > parent inherited
  defp flatten_merged_style_direct(parent_style, child_element, theme) do
    parent_style_map = extract_parent_style(parent_style)
    child_style_map = Map.get(child_element, :style, %{})

    inherited = Map.take(parent_style_map, @inheritable_properties)
    merged_style_map = Map.merge(inherited, child_style_map)

    child_top_level =
      child_element
      |> Map.drop([:style])
      |> Map.filter(fn {_k, v} -> v != nil end)

    all_attrs = Map.merge(merged_style_map, child_top_level)

    promote_colors(all_attrs, theme)
  end

  defp extract_parent_style(%{style: style_map} = parent)
       when is_map(style_map) do
    Map.merge(style_map, Map.take(parent, [:foreground, :background, :fg, :bg]))
  end

  defp extract_parent_style(style_map) when is_map(style_map), do: style_map
  defp extract_parent_style(_), do: %{}

  defp promote_colors(all_attrs, theme) do
    component_styles = Raxol.UI.ThemeResolver.get_component_styles(nil, theme)

    resolved_fg =
      Raxol.UI.ThemeResolver.resolve_fg_color(
        all_attrs,
        component_styles,
        theme
      )

    resolved_bg =
      Raxol.UI.ThemeResolver.resolve_bg_color(
        all_attrs,
        component_styles,
        theme
      )

    final_fg =
      Map.get(all_attrs, :foreground) || Map.get(all_attrs, :fg) || resolved_fg

    final_bg =
      Map.get(all_attrs, :background) || Map.get(all_attrs, :bg) || resolved_bg

    all_attrs
    |> Map.put(:foreground, final_fg)
    |> Map.put(:background, final_bg)
    |> Map.put(:fg, final_fg)
    |> Map.put(:bg, final_bg)
  end

  @doc """
  Merges parent and child styles for inheritance.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def merge_styles_for_inheritance(parent_style, child_style, opts \\ []) do
    if should_use_cache?(opts) do
      merge_styles_for_inheritance_cached(parent_style, child_style)
    else
      merge_styles_for_inheritance_direct(parent_style, child_style)
    end
  end

  # Cached implementation
  defp merge_styles_for_inheritance_cached(parent_style, child_style) do
    cache_key =
      {:style_merge, hash_style(parent_style), hash_style(child_style)}

    case get_cached_merged_style(cache_key) do
      {:ok, merged} ->
        merged

      :miss ->
        merged = merge_styles_for_inheritance_direct(parent_style, child_style)
        cache_merged_style(cache_key, merged)
        merged
    end
  end

  # Direct implementation (original logic)
  defp merge_styles_for_inheritance_direct(parent_style, child_style) do
    # Extract style maps from both parent and child
    parent_style_map = Map.get(parent_style, :style, %{})
    child_style_map = Map.get(child_style, :style, %{})

    # Merge the style maps (child overrides parent)
    merged_style_map = Map.merge(parent_style_map, child_style_map)

    # Create a complete inherited style that includes both the merged style map
    # and the promoted keys for proper inheritance
    %{}
    |> Map.put(:style, merged_style_map)
    |> maybe_put_if_not_nil(
      :foreground,
      Map.get(merged_style_map, :foreground)
    )
    |> maybe_put_if_not_nil(
      :background,
      Map.get(merged_style_map, :background)
    )
    |> maybe_put_if_not_nil(:fg, Map.get(merged_style_map, :fg))
    |> maybe_put_if_not_nil(:bg, Map.get(merged_style_map, :bg))
  end

  @doc """
  Inherits colors from parent to child style.

  ## Options
  - `cache: boolean()` - Enable caching for this operation (default: false)
  """
  def inherit_colors(
        child_style_map,
        parent_element,
        parent_style_map,
        opts \\ []
      ) do
    if should_use_cache?(opts) do
      inherit_colors_cached(child_style_map, parent_element, parent_style_map)
    else
      inherit_colors_direct(child_style_map, parent_element, parent_style_map)
    end
  end

  # Cached implementation
  defp inherit_colors_cached(child_style_map, parent_element, parent_style_map) do
    cache_key =
      {:color_inherit, hash_style(child_style_map), hash_style(parent_element),
       hash_style(parent_style_map)}

    case get_cached_colors(cache_key) do
      {:ok, colors} ->
        colors

      :miss ->
        colors =
          inherit_colors_direct(
            child_style_map,
            parent_element,
            parent_style_map
          )

        cache_colors(cache_key, colors)
        colors
    end
  end

  # Direct implementation (original logic)
  defp inherit_colors_direct(child_style_map, parent_element, parent_style_map) do
    %{
      fg:
        Map.get(child_style_map, :foreground) ||
          Map.get(parent_element, :foreground) ||
          Map.get(parent_style_map, :foreground),
      bg:
        Map.get(child_style_map, :background) ||
          Map.get(parent_element, :background) ||
          Map.get(parent_style_map, :background),
      fg_short:
        Map.get(child_style_map, :fg) || Map.get(parent_element, :fg) ||
          Map.get(parent_style_map, :fg),
      bg_short:
        Map.get(child_style_map, :bg) || Map.get(parent_element, :bg) ||
          Map.get(parent_style_map, :bg)
    }
  end

  defdelegate ensure_list(value), to: Raxol.Core.Utils.List

  @doc """
  Clear all style processing caches.
  """
  def clear_cache do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.clear_cache(:style)
    end
  end

  # Caching configuration and helpers

  defp should_use_cache?(opts) do
    cache_from_opts = Keyword.get(opts, :cache)

    cache_from_config =
      Application.get_env(:raxol, :style_processor, [])[:cache_enabled]

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

  # Cache operations (require ETSCacheManager to be available)

  defp get_cached_flattened_style(key) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.get_style(
        :flatten_cache,
        nil,
        :erlang.phash2(key)
      )
    else
      :miss
    end
  end

  defp cache_flattened_style(key, style) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.cache_style(
        :flatten_cache,
        nil,
        :erlang.phash2(key),
        style
      )
    end
  end

  defp get_cached_merged_style(key) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.get_style(
        :merge_cache,
        nil,
        :erlang.phash2(key)
      )
    else
      :miss
    end
  end

  defp cache_merged_style(key, style) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.cache_style(
        :merge_cache,
        nil,
        :erlang.phash2(key),
        style
      )
    end
  end

  defp get_cached_colors(key) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.get_style(
        :colors_cache,
        nil,
        :erlang.phash2(key)
      )
    else
      :miss
    end
  end

  defp cache_colors(key, colors) do
    if cache_available?() do
      Raxol.Performance.ETSCacheManager.cache_style(
        :colors_cache,
        nil,
        :erlang.phash2(key),
        colors
      )
    end
  end

  # Cache key builders

  defp build_flatten_cache_key(parent_style, child_element, theme) do
    {:flatten, hash_style(parent_style), hash_element(child_element),
     get_theme_id(theme)}
  end

  defp hash_style(nil), do: 0

  defp hash_style(style) when is_map(style) do
    relevant_keys = [
      :style,
      :foreground,
      :background,
      :fg,
      :bg,
      :bold,
      :italic,
      :underline,
      :variant
    ]

    style
    |> Map.take(relevant_keys)
    |> :erlang.phash2()
  end

  defp hash_style(_), do: 0

  defp hash_element(nil), do: 0

  defp hash_element(element) when is_map(element) do
    %{
      style: Map.get(element, :style, %{}),
      theme: Map.get(element, :theme),
      variant: Map.get(element, :variant),
      foreground: Map.get(element, :foreground),
      background: Map.get(element, :background),
      fg: Map.get(element, :fg),
      bg: Map.get(element, :bg)
    }
    |> :erlang.phash2()
  end

  defp hash_element(_), do: 0

  defp get_theme_id(nil), do: :no_theme
  defp get_theme_id(theme) when is_atom(theme), do: theme
  defp get_theme_id(theme) when is_binary(theme), do: theme

  defp get_theme_id(theme) when is_map(theme) do
    Map.get(theme, :name, :erlang.phash2(theme))
  end

  defp get_theme_id(_), do: :unknown_theme

  # Helper function to put a key-value pair only if the value is not nil
  defp maybe_put_if_not_nil(map, _key, nil), do: map
  defp maybe_put_if_not_nil(map, key, value), do: Map.put(map, key, value)
end
