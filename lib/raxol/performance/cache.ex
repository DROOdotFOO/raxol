defmodule Raxol.Performance.Cache do
  @moduledoc """
  Cache behavior and utilities for Raxol performance optimization.

  This module defines the standard cache interface and provides utilities
  for cache key generation and invalidation patterns.

  ## Caching Strategies

  Raxol uses several caching strategies depending on the use case:

  ### ETS Cache (ETSCacheManager)

  For runtime caching with LRU eviction. Best for:
  - Layout calculations
  - Style resolutions
  - Buffer regions
  - Cell creation

  ### Module Attribute Cache

  Compile-time caching using module attributes. Best for:
  - Static ANSI sequences
  - Predefined color maps
  - Constants

  ### Delegated Cache

  Using `cache: true` options on existing modules. Best for:
  - Theme resolution
  - Component styles

  ## Cache Keys

  Cache keys should be deterministic and based on the input parameters.
  Use `compute_hash/1` for complex structures.

  ## Example Usage

      # Using ETSCacheManager directly
      alias Raxol.Performance.ETSCacheManager

      case ETSCacheManager.get_layout(tree_hash, constraints) do
        {:ok, result} -> result
        :miss ->
          result = compute_expensive_layout(tree, constraints)
          ETSCacheManager.cache_layout(tree_hash, constraints, result)
          result
      end

      # Using the cache pattern helpers
      alias Raxol.Performance.Cache

      Cache.with_cache(
        :layout,
        {tree_hash, constraints},
        fn -> compute_expensive_layout(tree, constraints) end
      )

  """

  alias Raxol.Performance.ETSCacheManager

  @type cache_name ::
          :csi_parser | :cell | :style | :buffer | :layout | :font_metrics
  @type cache_key :: term()
  @type cache_result :: {:ok, term()} | :miss

  @doc """
  Wraps a computation with caching.

  If the value exists in cache, returns it. Otherwise, computes the value,
  caches it, and returns it.

  ## Options

    * `:ttl` - Time to live in milliseconds (not implemented, for future use)

  ## Examples

      Cache.with_cache(:layout, {tree, constraints}, fn ->
        expensive_layout_computation(tree, constraints)
      end)

  """
  @spec with_cache(cache_name(), cache_key(), (-> term()), keyword()) :: term()
  def with_cache(cache_name, key, compute_fn, _opts \\ []) do
    case get(cache_name, key) do
      {:ok, value} ->
        value

      :miss ->
        value = compute_fn.()
        put(cache_name, key, value)
        value
    end
  end

  @doc """
  Gets a value from the specified cache.
  """
  @spec get(cache_name(), cache_key()) :: cache_result()
  def get(:csi_parser, key), do: ETSCacheManager.get_csi(key)

  def get(:cell, {char, style_hash}),
    do: ETSCacheManager.get_cell(char, style_hash)

  def get(:style, {theme_id, component_type, attrs_hash}) do
    ETSCacheManager.get_style(theme_id, component_type, attrs_hash)
  end

  def get(:buffer, {buffer_id, x, y, width, height}) do
    ETSCacheManager.get_buffer_region(buffer_id, x, y, width, height)
  end

  def get(:layout, {tree_hash, constraints}) do
    ETSCacheManager.get_layout(tree_hash, constraints)
  end

  def get(:font_metrics, key), do: ETSCacheManager.get_font_metrics(key)

  @doc """
  Puts a value into the specified cache.
  """
  @spec put(cache_name(), cache_key(), term()) :: term()
  def put(:csi_parser, key, value), do: ETSCacheManager.cache_csi(key, value)

  def put(:cell, {char, style_hash}, value),
    do: ETSCacheManager.cache_cell(char, style_hash, value)

  def put(:style, {theme_id, component_type, attrs_hash}, value) do
    ETSCacheManager.cache_style(theme_id, component_type, attrs_hash, value)
  end

  def put(:buffer, {buffer_id, x, y, width, height}, value) do
    ETSCacheManager.cache_buffer_region(buffer_id, x, y, width, height, value)
  end

  def put(:layout, {tree_hash, constraints}, value) do
    ETSCacheManager.cache_layout(tree_hash, constraints, value)
  end

  def put(:font_metrics, key, value),
    do: ETSCacheManager.cache_font_metrics(key, value)

  @doc """
  Clears the specified cache. A name outside `t:cache_name/0` returns
  `{:error, :unknown_cache}`.
  """
  @spec clear(atom()) :: :ok | {:error, :unknown_cache}
  def clear(cache_name) do
    ETSCacheManager.clear_cache(cache_name)
  end

  @doc """
  Clears all caches.
  """
  @spec clear_all() :: :ok
  def clear_all do
    ETSCacheManager.clear_all()
  end

  @doc """
  Gets statistics for all caches.
  """
  @spec stats() :: map()
  def stats do
    ETSCacheManager.stats()
  end

  @doc """
  Computes a deterministic hash for a complex structure.

  Use this for generating cache keys from complex data structures.
  """
  @spec compute_hash(term()) :: non_neg_integer()
  def compute_hash(term) do
    :erlang.phash2(term, 1_000_000_000)
  end

  @doc """
  Computes a hash suitable for use as a cache key, including structure type.

  Returns `{type, hash}` tuple for more specific cache key matching.
  """
  @spec compute_typed_hash(atom(), term()) :: {atom(), non_neg_integer()}
  def compute_typed_hash(type, term) do
    {type, compute_hash(term)}
  end
end
