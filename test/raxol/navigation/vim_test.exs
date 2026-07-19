defmodule Raxol.Navigation.VimTest do
  use ExUnit.Case, async: true
  alias Raxol.Core.Buffer
  alias Raxol.Navigation.Vim

  setup do
    buffer = Buffer.create_blank_buffer(80, 24)
    buffer = Buffer.write_at(buffer, 0, 0, "Hello World")
    buffer = Buffer.write_at(buffer, 0, 1, "Line two")
    buffer = Buffer.write_at(buffer, 0, 2, "Third line here")

    vim = Vim.new(buffer)
    {:ok, vim: vim, buffer: buffer}
  end

  describe "new/2" do
    test "creates vim state with default config", %{buffer: buffer} do
      vim = Vim.new(buffer)

      assert vim.buffer == buffer
      assert vim.cursor == {0, 0}
      assert vim.mode == :normal
      assert vim.config.wrap_horizontal == true
      assert vim.config.wrap_vertical == false
    end

    test "accepts custom config", %{buffer: buffer} do
      config = %{wrap_horizontal: false, word_separators: " ."}
      vim = Vim.new(buffer, config)

      assert vim.config.wrap_horizontal == false
      assert vim.config.word_separators == " ."
    end
  end

  describe "basic movement" do
    test "h moves left", %{vim: vim} do
      vim = %{vim | cursor: {5, 0}}
      {:ok, vim} = Vim.handle_key("h", vim)
      assert vim.cursor == {4, 0}
    end

    test "h at column 0 does not move", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("h", vim)
      assert vim.cursor == {0, 0}
    end

    test "j moves down", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("j", vim)
      assert vim.cursor == {0, 1}
    end

    test "j at bottom does not move", %{buffer: buffer} do
      vim = Vim.new(buffer)
      vim = %{vim | cursor: {0, 23}}
      {:ok, vim} = Vim.handle_key("j", vim)
      assert vim.cursor == {0, 23}
    end

    test "k moves up", %{vim: vim} do
      vim = %{vim | cursor: {0, 5}}
      {:ok, vim} = Vim.handle_key("k", vim)
      assert vim.cursor == {0, 4}
    end

    test "k at top does not move", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("k", vim)
      assert vim.cursor == {0, 0}
    end

    test "l moves right", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("l", vim)
      assert vim.cursor == {1, 0}
    end

    test "l at right edge does not move", %{buffer: buffer} do
      config = %{wrap_horizontal: false}
      vim = Vim.new(buffer, config)
      vim = %{vim | cursor: {79, 0}}
      {:ok, vim} = Vim.handle_key("l", vim)
      assert vim.cursor == {79, 0}
    end
  end

  describe "jump commands" do
    test "gg goes to top", %{vim: vim} do
      vim = %{vim | cursor: {10, 10}}
      {:ok, vim} = Vim.handle_key("gg", vim)
      assert vim.cursor == {0, 0}
    end

    test "G goes to bottom", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("G", vim)
      assert vim.cursor == {0, 23}
    end

    test "0 goes to line start", %{vim: vim} do
      vim = %{vim | cursor: {10, 5}}
      {:ok, vim} = Vim.handle_key("0", vim)
      assert vim.cursor == {0, 5}
    end

    test "$ goes to line end", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("$", vim)
      {x, y} = vim.cursor
      assert y == 0
      assert x >= 10  # "Hello World" length
    end
  end

  describe "word movement" do
    test "w moves to next word", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("w", vim)
      {x, _y} = vim.cursor
      assert x > 0  # Moved from start
    end

    test "b moves to previous word", %{vim: vim} do
      vim = %{vim | cursor: {6, 0}}  # In "World"
      {:ok, vim} = Vim.handle_key("b", vim)
      assert vim.cursor == {0, 0}  # Back to "Hello"
    end

    test "e moves to end of word", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("e", vim)
      {x, y} = vim.cursor
      assert y == 0
      assert x > 0
    end

    test "w at end of line moves to next line", %{buffer: buffer} do
      vim = Vim.new(buffer)
      vim = %{vim | cursor: {10, 0}}
      {:ok, vim} = Vim.handle_key("w", vim)
      # Should wrap to next line
      {_x, y} = vim.cursor
      assert y == 1
    end
  end

  describe "search mode" do
    test "/ enters search mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("/", vim)
      assert vim.mode == :search
      assert vim.search_direction == :forward
    end

    test "? enters backward search", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("?", vim)
      assert vim.mode == :search
      assert vim.search_direction == :backward
    end

    test "Escape exits search mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("/", vim)
      {:ok, vim} = Vim.handle_key("Escape", vim)
      assert vim.mode == :normal
    end

    test "search and navigate matches", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("/", vim)
      {:ok, vim} = Vim.handle_key("l", vim)
      {:ok, vim} = Vim.handle_key("i", vim)
      {:ok, vim} = Vim.handle_key("n", vim)
      {:ok, vim} = Vim.handle_key("e", vim)
      {:ok, vim} = Vim.handle_key("Enter", vim)

      assert vim.mode == :normal
      assert is_list(vim.search_matches)
    end

    test "n navigates to next match when matches exist", %{vim: vim} do
      vim = %{vim |
        search_pattern: "line",
        search_matches: [{0, 1}, {6, 2}],
        search_index: 0
      }

      {:ok, vim} = Vim.handle_key("n", vim)
      assert vim.search_index == 1
    end

    test "N navigates to previous match", %{vim: vim} do
      vim = %{vim |
        search_pattern: "line",
        search_matches: [{0, 1}, {6, 2}],
        search_index: 1
      }

      {:ok, vim} = Vim.handle_key("N", vim)
      assert vim.search_index == 0
    end
  end

  describe "visual mode" do
    test "v enters visual mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("v", vim)
      assert vim.mode == :visual
      assert vim.visual_start == {0, 0}
    end

    test "movement in visual mode preserves mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("v", vim)
      {:ok, vim} = Vim.handle_key("l", vim)
      {:ok, vim} = Vim.handle_key("l", vim)

      assert vim.mode == :visual
      assert vim.cursor == {2, 0}
    end

    test "get_selection returns range in visual mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("v", vim)
      {:ok, vim} = Vim.handle_key("l", vim)
      {:ok, vim} = Vim.handle_key("l", vim)

      {{x1, y1}, {x2, y2}} = Vim.get_selection(vim)
      assert y1 == 0 and y2 == 0
      assert x1 == 0 and x2 == 2
    end

    test "get_selection returns nil in normal mode", %{vim: vim} do
      assert Vim.get_selection(vim) == nil
    end

    test "Escape exits visual mode", %{vim: vim} do
      {:ok, vim} = Vim.handle_key("v", vim)
      {:ok, vim} = Vim.handle_key("Escape", vim)

      assert vim.mode == :normal
      assert vim.visual_start == nil
    end
  end

  describe "horizontal wrapping" do
    test "l wraps to next line when enabled", %{buffer: buffer} do
      config = %{wrap_horizontal: true}
      vim = Vim.new(buffer, config)
      vim = %{vim | cursor: {79, 0}}

      {:ok, vim} = Vim.handle_key("l", vim)
      assert vim.cursor == {0, 1}
    end

    test "l does not wrap when disabled", %{buffer: buffer} do
      config = %{wrap_horizontal: false}
      vim = Vim.new(buffer, config)
      vim = %{vim | cursor: {79, 0}}

      {:ok, vim} = Vim.handle_key("l", vim)
      assert vim.cursor == {79, 0}
    end

    test "h wraps to previous line when enabled", %{buffer: buffer} do
      config = %{wrap_horizontal: true}
      vim = Vim.new(buffer, config)
      vim = %{vim | cursor: {0, 5}}

      {:ok, vim} = Vim.handle_key("h", vim)
      assert vim.cursor == {79, 4}
    end
  end

  describe "unknown keys" do
    test "returns unchanged state for unknown keys", %{vim: vim} do
      {:ok, new_vim} = Vim.handle_key("x", vim)
      assert new_vim == vim
    end
  end
  # `find_in_line/2` gets BYTE offsets from `Regex.scan(return: :index)`
  # but `search_matches` holds `{x, y}` cursor positions into
  # `Core.Buffer`, which stores one cell per GRAPHEME.
  describe "search positions with multi-byte text" do
    defp search_for(vim, pattern) do
      {:ok, vim} = Vim.handle_key("/", vim)

      vim =
        pattern
        |> String.graphemes()
        |> Enum.reduce(vim, fn key, acc ->
          {:ok, acc} = Vim.handle_key(key, acc)
          acc
        end)

      {:ok, vim} = Vim.handle_key("Enter", vim)
      vim
    end

    test "a multi-byte character before the match does not shift x" do
      buffer = Buffer.create_blank_buffer(80, 2)
      buffer = Buffer.write_at(buffer, 0, 0, "a — target")
      vim = Vim.new(buffer)

      vim = search_for(vim, "target")

      # "a — " is 4 cells but 6 bytes.
      assert {4, 0} in vim.search_matches
    end

    test "CJK before the match does not shift x" do
      buffer = Buffer.create_blank_buffer(80, 2)
      buffer = Buffer.write_at(buffer, 0, 0, "日本語 hit")
      vim = Vim.new(buffer)

      vim = search_for(vim, "hit")

      # 3 ideographs are 3 cells but 9 bytes.
      assert {4, 0} in vim.search_matches
    end
  end
end
