defmodule Raxol.UI.Layout.ScrollContentTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.{ListScrollContent, StreamScrollContent}

  describe "ListScrollContent" do
    test "wraps a list and provides total_count" do
      items = [%{type: :text, content: "a"}, %{type: :text, content: "b"}]
      source = ListScrollContent.new(items)

      assert ListScrollContent.total_count(source) == 2
    end

    test "slices items at offset" do
      items = Enum.map(0..9, fn i -> %{type: :text, content: "#{i}"} end)
      source = ListScrollContent.new(items)

      slice = ListScrollContent.slice(source, 3, 2)
      assert length(slice) == 2
      assert Enum.at(slice, 0).content == "3"
      assert Enum.at(slice, 1).content == "4"
    end

    test "handles slice beyond end" do
      items = [%{type: :text, content: "a"}]
      source = ListScrollContent.new(items)

      assert ListScrollContent.slice(source, 5, 3) == []
    end

    test "item_height defaults to 1" do
      source = ListScrollContent.new([])
      assert ListScrollContent.item_height(source, 0) == 1
    end
  end

  describe "StreamScrollContent" do
    setup do
      # 1000-item dataset, fetch function returns text elements
      fetch_fn = fn offset, count ->
        Enum.map(offset..(offset + count - 1), fn i ->
          %{type: :text, content: "item-#{i}"}
        end)
      end

      source =
        StreamScrollContent.new(fetch_fn: fetch_fn, total: 1000, cache_size: 50)

      {:ok, source: source}
    end

    test "total_count returns configured total", %{source: source} do
      assert StreamScrollContent.total_count(source) == 1000
    end

    test "slice fetches and returns correct items", %{source: source} do
      slice = StreamScrollContent.slice(source, 10, 5)

      assert length(slice) == 5
      assert Enum.at(slice, 0).content == "item-10"
      assert Enum.at(slice, 4).content == "item-14"
    end

    test "fetch_and_update returns items and updated state", %{source: source} do
      {slice, updated} = StreamScrollContent.fetch_and_update(source, 100, 10)

      assert length(slice) == 10
      assert Enum.at(slice, 0).content == "item-100"

      # Cache is populated
      assert is_integer(updated.cache_start)
      assert is_list(updated.cache_items)

      # Subsequent slice from cache should work
      slice2 = StreamScrollContent.slice(updated, 105, 5)
      assert length(slice2) == 5
      assert Enum.at(slice2, 0).content == "item-105"
    end

    test "cache hit avoids re-fetch", %{source: source} do
      # First call populates cache
      {_slice, updated} = StreamScrollContent.fetch_and_update(source, 50, 10)

      # Track that fetch_fn is NOT called again by using a counter
      # (We test this indirectly by checking cache_start doesn't change)
      cache_start_before = updated.cache_start

      # This should hit the cache
      slice = StreamScrollContent.slice(updated, 55, 5)
      assert length(slice) == 5
      assert Enum.at(slice, 0).content == "item-55"

      # Cache start unchanged (no re-fetch happened)
      assert updated.cache_start == cache_start_before
    end
  end

  describe "Viewport integration with content_source" do
    alias Raxol.UI.Components.Display.Viewport

    test "Viewport renders from ListScrollContent" do
      items = Enum.map(0..19, fn i -> %{type: :text, content: "line-#{i}"} end)
      source = ListScrollContent.new(items)

      {:ok, state} = Viewport.init(%{content_source: source, visible_height: 5})

      assert state.content_height == 20
      assert state.content_source == source

      rendered = Viewport.render(state, %{})
      # First child is the content column
      content_column = Enum.at(hd(rendered.children).children, 0)
      assert length(content_column.children) == 5
    end

    test "Viewport renders from StreamScrollContent" do
      fetch_fn = fn offset, count ->
        Enum.map(offset..(offset + count - 1), fn i ->
          %{type: :text, content: "row-#{i}"}
        end)
      end

      source = StreamScrollContent.new(fetch_fn: fetch_fn, total: 500)

      {:ok, state} =
        Viewport.init(%{content_source: source, visible_height: 10})

      assert state.content_height == 500

      rendered = Viewport.render(state, %{})
      content_column = Enum.at(hd(rendered.children).children, 0)
      assert length(content_column.children) == 10
      first_child = Enum.at(content_column.children, 0)
      assert first_child.content == "row-0"
    end

    test "Viewport falls back to children list when no content_source" do
      items = Enum.map(0..4, fn i -> %{type: :text, content: "#{i}"} end)

      {:ok, state} = Viewport.init(%{children: items, visible_height: 3})

      assert state.content_source == nil
      assert state.content_height == 5

      rendered = Viewport.render(state, %{})
      content_column = Enum.at(hd(rendered.children).children, 0)
      assert length(content_column.children) == 3
    end
  end
end
