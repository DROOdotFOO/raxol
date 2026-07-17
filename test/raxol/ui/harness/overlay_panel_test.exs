defmodule Raxol.UI.Harness.OverlayPanelTest do
  @moduledoc """
  Red-first acceptance tests for `Raxol.UI.Harness.OverlayPanel`, the
  read-only content-panel sibling of `Raxol.UI.Harness.OverlayPicker`.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.Harness.OverlayPanel

  defp key_norm(
         key,
         mods \\ %{ctrl: false, alt: false, shift: false, meta: false}
       ) do
    %{
      kind: :key,
      char: nil,
      key: key,
      text: nil,
      mods: mods,
      state: nil,
      raw: nil
    }
  end

  defp char_norm(char) do
    %{
      kind: :char,
      char: char,
      key: nil,
      text: nil,
      mods: %{ctrl: false, alt: false, shift: false, meta: false},
      state: nil,
      raw: nil
    }
  end

  defp paste_norm(text) do
    %{
      kind: :paste,
      char: nil,
      key: nil,
      text: text,
      mods: %{ctrl: false, alt: false, shift: false, meta: false},
      state: nil,
      raw: nil
    }
  end

  describe "new/1" do
    test "derives a default title from :kind" do
      assert OverlayPanel.new(kind: :worktracks).title == "Worktracks"
      assert OverlayPanel.new(kind: :memory).title == "Memory"
      assert OverlayPanel.new(kind: :plan).title == "Plan"
    end

    test "defaults max_visible to default_max_visible/0" do
      t = OverlayPanel.new(kind: :memory)
      assert t.max_visible == OverlayPanel.default_max_visible()
    end

    test "requires :kind" do
      assert_raise KeyError, fn -> OverlayPanel.new([]) end
    end
  end

  describe "default_max_visible/0" do
    test "returns 8" do
      assert OverlayPanel.default_max_visible() == 8
    end
  end

  describe "height/1 -- fixed, never tracks content" do
    test "is 1 + max_visible regardless of line count" do
      t = OverlayPanel.new(kind: :memory, max_visible: 5)
      assert OverlayPanel.height(t) == 6

      t2 = OverlayPanel.put_lines(t, Enum.map(1..100, &"line #{&1}"))
      assert OverlayPanel.height(t2) == 6
    end
  end

  describe "render/1 -- exact row count" do
    test "empty content still yields height(t) leaves" do
      t = OverlayPanel.new(kind: :memory, max_visible: 4)
      %{type: :column, children: children} = OverlayPanel.render(t)
      assert length(children) == OverlayPanel.height(t)
      assert Enum.all?(children, &(&1.type == :text))
    end

    test "short content pads the remainder" do
      t =
        OverlayPanel.new(kind: :memory, max_visible: 8, lines: ["a", "b", "c"])

      %{children: children} = OverlayPanel.render(t)
      assert length(children) == 9
      [title_row | content_rows] = children
      assert title_row.style == %{bold: true}

      assert Enum.map(content_rows, & &1.content) == [
               "a",
               "b",
               "c",
               "",
               "",
               "",
               "",
               ""
             ]
    end

    test "overflowing content is sliced to max_visible rows" do
      lines = Enum.map(1..20, &"line #{&1}")
      t = OverlayPanel.new(kind: :memory, max_visible: 5, lines: lines)
      %{children: children} = OverlayPanel.render(t)
      assert length(children) == 6
      [_title | content_rows] = children

      assert Enum.map(content_rows, & &1.content) == [
               "line 1",
               "line 2",
               "line 3",
               "line 4",
               "line 5"
             ]
    end
  end

  describe "range indicator" do
    test "plain title when content fits" do
      t = OverlayPanel.new(kind: :memory, max_visible: 8, lines: ["a", "b"])
      %{children: [title_row | _]} = OverlayPanel.render(t)
      assert title_row.content == "Memory"
    end

    test "shows a range indicator only when content overflows" do
      lines = Enum.map(1..20, &"line #{&1}")
      t = OverlayPanel.new(kind: :memory, max_visible: 5, lines: lines)
      %{children: [title_row | _]} = OverlayPanel.render(t)
      assert title_row.content == "Memory (1-5/20)"

      {:continue, scrolled} = OverlayPanel.handle_key(t, key_norm(:down))
      %{children: [title_row2 | _]} = OverlayPanel.render(scrolled)
      assert title_row2.content == "Memory (2-6/20)"
    end
  end

  describe "scrolling" do
    test "up/down clamp at both ends" do
      lines = Enum.map(1..20, &"line #{&1}")
      t = OverlayPanel.new(kind: :memory, max_visible: 5, lines: lines)

      {:continue, still_top} = OverlayPanel.handle_key(t, key_norm(:up))
      assert still_top.offset == 0

      bottom =
        Enum.reduce(1..50, t, fn _, acc ->
          {:continue, next} = OverlayPanel.handle_key(acc, key_norm(:down))
          next
        end)

      assert bottom.offset == 15

      {:continue, still_bottom} =
        OverlayPanel.handle_key(bottom, key_norm(:down))

      assert still_bottom.offset == 15
    end

    test "page_up/page_down scroll by max_visible" do
      lines = Enum.map(1..20, &"line #{&1}")
      t = OverlayPanel.new(kind: :memory, max_visible: 5, lines: lines)

      {:continue, paged} = OverlayPanel.handle_key(t, key_norm(:page_down))
      assert paged.offset == 5

      {:continue, back} = OverlayPanel.handle_key(paged, key_norm(:page_up))
      assert back.offset == 0
    end

    test "put_lines clamps a stale offset" do
      lines = Enum.map(1..20, &"line #{&1}")
      t = OverlayPanel.new(kind: :memory, max_visible: 5, lines: lines)
      scrolled = %{t | offset: 15}

      shrunk = OverlayPanel.put_lines(scrolled, ["only", "two"])
      assert shrunk.offset == 0
    end
  end

  describe "read-only: everything but up/down/page/escape is inert" do
    test "printable char is a no-op" do
      t = OverlayPanel.new(kind: :memory, lines: ["a"])
      assert OverlayPanel.handle_key(t, char_norm("x")) == {:continue, t}
    end

    test "enter is a no-op" do
      t = OverlayPanel.new(kind: :memory, lines: ["a"])
      assert OverlayPanel.handle_key(t, key_norm(:enter)) == {:continue, t}
    end

    test "paste is a no-op" do
      t = OverlayPanel.new(kind: :memory, lines: ["a"])

      assert OverlayPanel.handle_key(t, paste_norm("pasted text")) ==
               {:continue, t}
    end

    test "never returns {:picked, _}" do
      t = OverlayPanel.new(kind: :memory, lines: ["a", "b"])

      results =
        [
          key_norm(:up),
          key_norm(:down),
          key_norm(:page_up),
          key_norm(:page_down),
          key_norm(:enter),
          key_norm(:backspace),
          char_norm("z"),
          paste_norm("x")
        ]
        |> Enum.map(&OverlayPanel.handle_key(t, &1))

      refute Enum.any?(results, &match?({:picked, _}, &1))
    end
  end

  describe "escape" do
    test "dismisses the panel" do
      t = OverlayPanel.new(kind: :memory, lines: ["a"])
      assert OverlayPanel.handle_key(t, key_norm(:escape)) == :dismissed
    end
  end
end
