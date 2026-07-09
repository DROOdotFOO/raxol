defmodule Raxol.Performance.ETSCacheManager do
  @moduledoc """
  High-performance ETS cache manager for Raxol hot paths.

  Provides dedicated caches for performance-critical operations:
  - ANSI parser cache
  - Cell creation cache
  - Theme/style resolution cache
  - Buffer operations cache
  - Layout calculation cache

  Uses ETS tables with optimized access patterns and LRU eviction.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Performance.ETS.{CacheHelper, TableHelper}

  @csi_parser_cache :raxol_csi_parser_cache
  @cell_cache :raxol_cell_cache
  @style_cache :raxol_style_cache
  @buffer_cache :raxol_buffer_cache
  @layout_cache :raxol_layout_cache
  @font_metrics_cache :raxol_font_metrics_cache

  @max_csi_entries 1000
  @max_cell_entries 10_000
  @max_style_entries 5000
  @max_buffer_entries 2000
  @max_layout_entries 1000
  @max_font_metrics_entries 10_000

  # Client API

  @doc "Cache a parsed CSI sequence."
  def cache_csi(sequence, result) do
    CacheHelper.put_lru(@csi_parser_cache, sequence, result, @max_csi_entries)
    result
  end

  @doc "Get a cached CSI parse result."
  def get_csi(sequence), do: CacheHelper.get_lru(@csi_parser_cache, sequence)

  @doc "Cache a cell creation."
  def cache_cell(char, style_hash, cell) do
    CacheHelper.put_lru(
      @cell_cache,
      {char, style_hash},
      cell,
      @max_cell_entries
    )

    cell
  end

  @doc "Get a cached cell."
  def get_cell(char, style_hash),
    do: CacheHelper.get_lru(@cell_cache, {char, style_hash})

  @doc "Cache a style resolution."
  def cache_style(theme_id, component_type, attrs_hash, resolved_style) do
    key = {theme_id, component_type, attrs_hash}
    CacheHelper.put_lru(@style_cache, key, resolved_style, @max_style_entries)
    resolved_style
  end

  @doc "Get a cached style resolution."
  def get_style(theme_id, component_type, attrs_hash),
    do:
      CacheHelper.get_lru(@style_cache, {theme_id, component_type, attrs_hash})

  @doc "Cache a buffer region."
  def cache_buffer_region(buffer_id, x, y, width, height, data) do
    key = {:region, buffer_id, x, y, width, height}
    CacheHelper.put_lru(@buffer_cache, key, data, @max_buffer_entries)
    data
  end

  @doc "Get a cached buffer region."
  def get_buffer_region(buffer_id, x, y, width, height),
    do:
      CacheHelper.get_lru(
        @buffer_cache,
        {:region, buffer_id, x, y, width, height}
      )

  @doc """
  Cache a layout calculation.
  Supports both full tree layouts and partial node layouts.
  """
  def cache_layout(tree_hash, constraints, result) do
    key = {tree_hash, constraints}
    CacheHelper.put_lru(@layout_cache, key, result, @max_layout_entries)
    result
  end

  @doc """
  Get a cached layout.
  Supports constraint matching for responsive layouts.
  """
  def get_layout(tree_hash, constraints) do
    key = {tree_hash, constraints}

    case CacheHelper.get_lru(@layout_cache, key) do
      {:ok, _} = hit -> hit
      :miss -> find_compatible_layout(tree_hash, constraints)
    end
  end

  @doc """
  Batch cache multiple layouts.
  Useful for pre-computing common viewport sizes.
  """
  def cache_layouts_batch(layouts) do
    _ =
      Enum.each(layouts, fn {tree_hash, constraints, result} ->
        cache_layout(tree_hash, constraints, result)
      end)
  end

  defp find_compatible_layout(tree_hash, constraints) do
    pattern = {{tree_hash, :_}, :_, :_}
    candidates = :ets.match_object(@layout_cache, pattern)

    case find_best_match(candidates, constraints) do
      {key, result, _timestamp} ->
        _ =
          :ets.update_element(@layout_cache, key, {3, System.monotonic_time()})

        {:ok, result}

      nil ->
        :miss
    end
  end

  @doc "Cache font metrics calculation."
  def cache_font_metrics(key, result) do
    CacheHelper.put_lru(
      @font_metrics_cache,
      key,
      result,
      @max_font_metrics_entries
    )

    result
  end

  @doc "Get cached font metrics."
  def get_font_metrics(key),
    do: CacheHelper.get_lru(@font_metrics_cache, key)

  defp find_best_match([], _), do: nil

  defp find_best_match(candidates, target_constraints) do
    Enum.find(candidates, fn {{_tree_hash, cached_constraints}, _result, _ts} ->
      constraints_compatible?(cached_constraints, target_constraints)
    end)
  end

  defp constraints_compatible?(cached, target)
       when is_list(cached) and is_list(target) do
    cached_map = Map.new(cached)
    target_map = Map.new(target)

    width_compatible?(cached_map[:width], target_map[:width]) and
      height_compatible?(cached_map[:height], target_map[:height])
  end

  defp constraints_compatible?(_, _), do: false

  defp width_compatible?(nil, _), do: true
  defp width_compatible?(_, nil), do: true

  defp width_compatible?(w1, w2) do
    max_val = Enum.max([w1, w2])
    abs(w1 - w2) / max_val <= 0.1
  end

  defp height_compatible?(nil, _), do: true
  defp height_compatible?(_, nil), do: true

  defp height_compatible?(h1, h2) do
    max_val = Enum.max([h1, h2])
    abs(h1 - h2) / max_val <= 0.1
  end

  @doc "Clear all caches."
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc "Clear a specific cache."
  def clear_cache(cache_name) do
    GenServer.call(__MODULE__, {:clear_cache, cache_name})
  end

  @doc "Get cache statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # BaseManager Implementation

  @impl true
  def init_manager(_opts) do
    _ =
      TableHelper.ensure_table(@csi_parser_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    _ =
      TableHelper.ensure_table(@cell_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    _ =
      TableHelper.ensure_table(@style_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    _ =
      TableHelper.ensure_table(@buffer_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    _ =
      TableHelper.ensure_table(@layout_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

    _ =
      TableHelper.ensure_table(@font_metrics_cache, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    stats = %{
      csi: %{hits: 0, misses: 0},
      cell: %{hits: 0, misses: 0},
      style: %{hits: 0, misses: 0},
      buffer: %{hits: 0, misses: 0},
      layout: %{hits: 0, misses: 0},
      font_metrics: %{hits: 0, misses: 0}
    }

    {:ok, %{stats: stats}}
  end

  @impl true
  def handle_manager_call(:clear_all, _from, state) do
    _ = :ets.delete_all_objects(@csi_parser_cache)
    _ = :ets.delete_all_objects(@cell_cache)
    _ = :ets.delete_all_objects(@style_cache)
    _ = :ets.delete_all_objects(@buffer_cache)
    _ = :ets.delete_all_objects(@layout_cache)
    _ = :ets.delete_all_objects(@font_metrics_cache)

    {:reply, :ok, state}
  end

  def handle_manager_call({:clear_cache, cache_name}, _from, state) do
    table = get_table_name(cache_name)
    _ = :ets.delete_all_objects(table)
    {:reply, :ok, state}
  end

  def handle_manager_call(:stats, _from, state) do
    stats = %{
      csi_parser: table_stats(@csi_parser_cache),
      cell: table_stats(@cell_cache),
      style: table_stats(@style_cache),
      buffer: table_stats(@buffer_cache),
      layout: table_stats(@layout_cache),
      font_metrics: table_stats(@font_metrics_cache),
      hit_rates: state.stats
    }

    {:reply, stats, state}
  end

  defp table_stats(table) do
    %{
      size: :ets.info(table, :size),
      memory_bytes: :ets.info(table, :memory) * :erlang.system_info(:wordsize),
      keypos: :ets.info(table, :keypos),
      type: :ets.info(table, :type)
    }
  end

  defp get_table_name(:csi_parser), do: @csi_parser_cache
  defp get_table_name(:cell), do: @cell_cache
  defp get_table_name(:style), do: @style_cache
  defp get_table_name(:buffer), do: @buffer_cache
  defp get_table_name(:layout), do: @layout_cache
  defp get_table_name(:font_metrics), do: @font_metrics_cache
  defp get_table_name(name), do: name
end
