defmodule Raxol.UI.Components.Input.TextFieldTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Input.TextField

  defp create_state(props) do
    {:ok, state} = TextField.init(props)
    state = Map.put_new(state, :style, %{})
    Map.put_new(state, :type, :text_field)
  end

  defp default_context, do: %{}

  describe "theming, style, and lifecycle" do
    test "applies style and theme props to text field" do
      theme_map = %{
        text_field: %{
          border: "2px solid #00ff00",
          color: "#123456",
          layout: %{}
        }
      }

      style_prop = %{border_radius: "8px", color: "#654321"}

      state =
        create_state(%{value: "Styled", theme: theme_map, style: style_prop})

      rendered_element = TextField.render(state, %{theme: theme_map})

      assert %{type: :view, style: actual_merged_style} = rendered_element

      # Prop style assertions
      assert actual_merged_style.color == "#654321"
      assert actual_merged_style.border_radius == "8px"

      # Check for theme's border. Given the warning "Theme missing component style for :text_field",
      # we expect this to be nil for now. Once the theme application is fixed in the component,
      # this assertion should be updated to check for the actual themed border.
      assert Map.get(actual_merged_style, :border) == "2px solid #00ff00"
    end

    test "mount/1 and unmount/1 return state unchanged" do
      state = create_state(%{value: "foo"})
      assert TextField.mount(state) == {state, []}
      assert TextField.unmount(state) == state
    end
  end

  describe "render/2" do
    test "renders value and placeholder" do
      state = create_state(%{value: "Hello"})

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [text_elem] = rendered.children
      assert text_elem.type == :text
      assert String.trim(text_elem.content) == "Hello"

      state2 = create_state(%{value: "", placeholder: "Type here"})

      rendered2 =
        TextField.render(state2, %{theme: %{text_field: %{layout: %{}}}})

      [text_elem2] = rendered2.children
      assert text_elem2.type == :text
      assert String.trim(text_elem2.content) == "Type here"
      assert text_elem2.style[:color] == "#888"
      assert :italic in (text_elem2.style[:text_decoration] || [])
    end

    test "renders masked value if secret is true" do
      state = create_state(%{value: "secret", secret: true})

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [text_elem] = rendered.children
      assert text_elem.type == :text
      assert String.trim(text_elem.content) == String.duplicate("•", 6)
    end

    test "placeholder is not shown when field is focused" do
      state =
        create_state(%{
          value: "",
          placeholder: "Type here",
          focused: true,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      # When focused with empty value, should render focused children (with cursor),
      # not the placeholder text
      children = rendered.children
      assert length(children) == 3
    end

    test "renders cursor element when focused with text" do
      state =
        create_state(%{
          value: "Hello",
          focused: true,
          cursor_pos: 2,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [left, cursor, right] = rendered.children
      assert left.content == "He"
      assert cursor.content == "|"
      assert right.content == "llo"
    end

    test "secret mode renders masked value with cursor when focused" do
      state =
        create_state(%{
          value: "pass",
          secret: true,
          focused: true,
          cursor_pos: 2,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [left, cursor, right] = rendered.children
      assert left.content == "••"
      assert cursor.content == "|"
      assert right.content == "••"
    end
  end

  describe "handle_event/3 - character input" do
    test "inserts a single character at cursor position" do
      state = create_state(%{value: "hllo", cursor_pos: 1})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, "e", []}, state, default_context())

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 2
    end

    test "inserts character at the beginning of text" do
      state = create_state(%{value: "ello", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, "h", []}, state, default_context())

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 1
    end

    test "inserts character at the end of text" do
      state = create_state(%{value: "hell", cursor_pos: 4})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, "o", []}, state, default_context())

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 5
    end

    test "inserts into empty text" do
      state = create_state(%{value: "", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, "a", []}, state, default_context())

      assert new_state.value == "a"
      assert new_state.cursor_pos == 1
    end

    test "inserts multi-character string" do
      state = create_state(%{value: "hd", cursor_pos: 1})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, "ello worl", []},
          state,
          default_context()
        )

      assert new_state.value == "hello world"
      assert new_state.cursor_pos == 10
    end
  end

  describe "handle_event/3 - backspace" do
    test "deletes character before cursor" do
      state = create_state(%{value: "hello", cursor_pos: 3})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert new_state.value == "helo"
      assert new_state.cursor_pos == 2
    end

    test "backspace at position 0 does nothing" do
      state = create_state(%{value: "hello", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 0
    end

    test "backspace at end removes last character" do
      state = create_state(%{value: "hello", cursor_pos: 5})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert new_state.value == "hell"
      assert new_state.cursor_pos == 4
    end

    test "backspace on single character yields empty string" do
      state = create_state(%{value: "x", cursor_pos: 1})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert new_state.value == ""
      assert new_state.cursor_pos == 0
    end
  end

  describe "handle_event/3 - delete" do
    test "deletes character at cursor position" do
      state = create_state(%{value: "hello", cursor_pos: 1})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :delete, []},
          state,
          default_context()
        )

      assert new_state.value == "hllo"
      assert new_state.cursor_pos == 1
    end

    test "delete at end of text does nothing" do
      state = create_state(%{value: "hello", cursor_pos: 5})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :delete, []},
          state,
          default_context()
        )

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 5
    end

    test "delete at beginning removes first character" do
      state = create_state(%{value: "hello", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :delete, []},
          state,
          default_context()
        )

      assert new_state.value == "ello"
      assert new_state.cursor_pos == 0
    end

    test "delete on single character yields empty string" do
      state = create_state(%{value: "x", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :delete, []},
          state,
          default_context()
        )

      assert new_state.value == ""
      assert new_state.cursor_pos == 0
    end
  end

  describe "handle_event/3 - arrow keys" do
    test "arrow_left moves cursor left by one" do
      state = create_state(%{value: "hello", cursor_pos: 3})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :arrow_left, []},
          state,
          default_context()
        )

      assert new_state.cursor_pos == 2
      assert new_state.value == "hello"
    end

    test "arrow_left at position 0 stays at 0" do
      state = create_state(%{value: "hello", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :arrow_left, []},
          state,
          default_context()
        )

      assert new_state.cursor_pos == 0
    end

    test "arrow_right moves cursor right by one" do
      state = create_state(%{value: "hello", cursor_pos: 2})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :arrow_right, []},
          state,
          default_context()
        )

      assert new_state.cursor_pos == 3
      assert new_state.value == "hello"
    end

    test "arrow_right at end of text stays at end" do
      state = create_state(%{value: "hello", cursor_pos: 5})

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :arrow_right, []},
          state,
          default_context()
        )

      assert new_state.cursor_pos == 5
    end
  end

  describe "handle_event/3 - home and end" do
    test "home moves cursor to position 0 and resets scroll" do
      state =
        create_state(%{value: "hello world", cursor_pos: 8, scroll_offset: 3})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, :home, []}, state, default_context())

      assert new_state.cursor_pos == 0
      assert new_state.scroll_offset == 0
    end

    test "end moves cursor to end of text" do
      state = create_state(%{value: "hello", cursor_pos: 0})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, :end, []}, state, default_context())

      assert new_state.cursor_pos == 5
    end
  end

  describe "handle_event/3 - disabled field" do
    test "keypress on disabled field does nothing" do
      state = create_state(%{value: "hello", disabled: true, cursor_pos: 3})

      {returned_state, commands} =
        TextField.handle_event({:keypress, "x", []}, state, default_context())

      assert returned_state.value == "hello"
      assert returned_state.cursor_pos == 3
      assert commands == []
    end

    test "backspace on disabled field does nothing" do
      state = create_state(%{value: "hello", disabled: true, cursor_pos: 3})

      {returned_state, commands} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert returned_state.value == "hello"
      assert commands == []
    end
  end

  describe "handle_event/3 - focus and blur" do
    test "focus event sets focused to true" do
      state = create_state(%{value: "hello", focused: false})

      {new_state, commands} =
        TextField.handle_event({:focus}, state, default_context())

      assert new_state.focused == true
      assert commands == []
    end

    test "blur event sets focused to false" do
      state = create_state(%{value: "hello", focused: true})

      {new_state, commands} =
        TextField.handle_event({:blur}, state, default_context())

      assert new_state.focused == false
      assert commands == []
    end
  end

  describe "handle_event/3 - mouse click" do
    test "mouse click positions cursor based on column" do
      state =
        create_state(%{value: "hello world", cursor_pos: 0, scroll_offset: 0})

      {result, commands} =
        TextField.handle_event(
          {:mouse, {:click, {0, 5}}},
          state,
          default_context()
        )

      # update/2 returns {:noreply, new_state}, so the result is that tuple
      {:noreply, new_state} = result
      assert new_state.cursor_pos == 5
      assert commands == []
    end

    test "mouse click beyond text length clamps to text length" do
      state = create_state(%{value: "hi", cursor_pos: 0, scroll_offset: 0})

      {result, _commands} =
        TextField.handle_event(
          {:mouse, {:click, {0, 10}}},
          state,
          default_context()
        )

      {:noreply, new_state} = result
      assert new_state.cursor_pos == 2
    end
  end

  describe "handle_event/3 - unknown events" do
    test "unknown event returns state unchanged with empty commands" do
      state = create_state(%{value: "hello"})

      {returned_state, commands} =
        TextField.handle_event({:unknown_event}, state, default_context())

      assert returned_state.value == "hello"
      assert commands == []
    end

    test "unknown keypress returns noreply with unchanged state" do
      state = create_state(%{value: "hello", cursor_pos: 2})

      {:noreply, new_state} =
        TextField.handle_event({:keypress, :tab, []}, state, default_context())

      assert new_state.value == "hello"
      assert new_state.cursor_pos == 2
    end
  end

  describe "update/2 - move_cursor_to" do
    test "moves cursor to specified column" do
      state =
        create_state(%{value: "hello world", cursor_pos: 0, scroll_offset: 0})

      {:noreply, new_state} = TextField.update({:move_cursor_to, {0, 5}}, state)

      assert new_state.cursor_pos == 5
    end

    test "clamps cursor to text length when column exceeds text" do
      state = create_state(%{value: "hi", cursor_pos: 0, scroll_offset: 0})

      {:noreply, new_state} =
        TextField.update({:move_cursor_to, {0, 100}}, state)

      assert new_state.cursor_pos == 2
    end

    test "accounts for scroll offset when positioning cursor" do
      state =
        create_state(%{
          value: "a very long text string",
          cursor_pos: 0,
          scroll_offset: 5
        })

      {:noreply, new_state} = TextField.update({:move_cursor_to, {0, 3}}, state)

      # col 3 + scroll_offset 5 = position 8
      assert new_state.cursor_pos == 8
    end

    test "clamps cursor to 0 when column plus offset is negative" do
      state = create_state(%{value: "hello", cursor_pos: 3, scroll_offset: 0})

      {:noreply, new_state} = TextField.update({:move_cursor_to, {0, 0}}, state)

      assert new_state.cursor_pos == 0
    end
  end

  describe "update/2 - update_props" do
    test "updates value and clamps cursor" do
      state = create_state(%{value: "hello world", cursor_pos: 10})

      new_state = TextField.update({:update_props, %{value: "hi"}}, state)

      assert new_state.value == "hi"
      assert new_state.cursor_pos == 2
    end

    test "updates width and clamps scroll_offset" do
      state =
        create_state(%{
          value: "hello",
          cursor_pos: 0,
          scroll_offset: 3,
          width: 20
        })

      new_state = TextField.update({:update_props, %{width: 10}}, state)

      assert new_state.width == 10
      # scroll_offset clamped to max(0, len("hello") - 10) = 0
      assert new_state.scroll_offset == 0
    end
  end

  describe "update/2 - unknown message" do
    test "returns noreply with unchanged state" do
      state = create_state(%{value: "hello"})

      {:noreply, returned_state} = TextField.update(:some_random_message, state)

      assert returned_state == state
    end
  end

  describe "CJK characterization (graphemes vs cells)" do
    # These tests pin current behavior for double-width characters. The
    # data model is grapheme-indexed (cursor_pos, scroll_offset) while
    # `width` is conceptually cells -- mismatched units cause clipping
    # and scroll bugs. See TODO refactor backlog and the planned
    # cell-aware redesign.

    test "inserting a CJK char advances cursor by 1 grapheme (not 2 cells)" do
      state = create_state(%{value: "", cursor_pos: 0, width: 10})

      {:noreply, s1} =
        TextField.handle_event({:keypress, "你", []}, state, default_context())

      assert s1.value == "你"
      assert s1.cursor_pos == 1
    end

    test "backspace on CJK removes one grapheme (not two bytes)" do
      state = create_state(%{value: "你好", cursor_pos: 2, width: 10})

      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert s1.value == "你"
      assert s1.cursor_pos == 1
    end

    test "arrow_left moves cursor by 1 grapheme over CJK" do
      state = create_state(%{value: "你好世界", cursor_pos: 3, width: 10})

      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, :arrow_left, []},
          state,
          default_context()
        )

      assert s1.cursor_pos == 2
      # The grapheme to the left of the new cursor is "你好"; the cell
      # span the cursor crossed is 2, but cursor_pos decremented by 1.
    end

    # BUG (cell-vs-grapheme mismatch): visible_value uses String.slice
    # with width as a grapheme count. Four CJK chars are 8 cells but
    # render as if they fit in a 5-cell window. The redesign must
    # truncate by cells, not graphemes.
    test "render with CJK overflowing width emits more cells than width allows (BUG)" do
      state =
        create_state(%{
          value: "你好世界",
          cursor_pos: 4,
          focused: true,
          width: 5,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [left, cursor, right] = rendered.children
      # Current: left contains all 4 graphemes = 8 display cells in a
      # 5-cell field. The redesign should produce a left of at most
      # ~2 graphemes (4 cells) plus the cursor.
      assert left.content == "你好世界"
      assert cursor.content == "|"
      assert right.content == ""
    end

    # BUG: cursor placement within window is computed in graphemes
    # (cursor_pos - scroll_offset). With CJK before the cursor, the
    # rendered cursor sits at the wrong cell column.
    test "render places cursor by grapheme index even for double-width left side (BUG)" do
      state =
        create_state(%{
          value: "你好ab",
          # cursor between 好 and a
          cursor_pos: 2,
          focused: true,
          width: 20,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [left, _cursor, right] = rendered.children
      # Current: left = "你好" (2 graphemes = 4 cells). Renders cursor
      # at column 2 visually because consumers measure left in graphemes.
      # Cell-aware redesign should still produce left="你好" here, but
      # consumers must know it occupies 4 columns.
      assert left.content == "你好"
      assert right.content == "ab"
    end
  end

  describe "emoji characterization (1 grapheme, 2 cells)" do
    # Single emoji and ZWJ-compound emoji are single graphemes but
    # double-width (and ZWJ sequences are many bytes). The TextField
    # currently treats them as single-cell units in scroll math.

    test "inserting an emoji advances cursor by 1 grapheme" do
      state = create_state(%{value: "", cursor_pos: 0, width: 10})

      {:noreply, s1} =
        TextField.handle_event({:keypress, "🎉", []}, state, default_context())

      assert s1.value == "🎉"
      assert s1.cursor_pos == 1
    end

    test "inserting a ZWJ compound emoji advances cursor by 1 grapheme" do
      state = create_state(%{value: "", cursor_pos: 0, width: 10})

      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, "👨‍👩‍👧", []},
          state,
          default_context()
        )

      assert s1.value == "👨‍👩‍👧"
      assert s1.cursor_pos == 1
      # The ZWJ sequence is 18 bytes / 1 grapheme / 2 cells; the
      # cursor_pos lands on the right side of the family glyph.
    end

    test "backspace deletes a whole ZWJ emoji (not part of it)" do
      zwj = "👨‍👩‍👧"

      state =
        create_state(%{value: "a" <> zwj <> "b", cursor_pos: 2, width: 10})

      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert s1.value == "ab"
      assert s1.cursor_pos == 1
    end

    # BUG: same overflow class as CJK -- visible_value is sliced by
    # grapheme count; emoji width is ignored.
    test "render with emoji overflowing width emits more cells than width allows (BUG)" do
      # 5 emojis = 10 cells, width = 6
      value = String.duplicate("🎉", 5)

      state =
        create_state(%{
          value: value,
          cursor_pos: 5,
          focused: true,
          width: 6,
          style: %{color: "#fff", background: "#000"}
        })

      rendered =
        TextField.render(state, %{theme: %{text_field: %{layout: %{}}}})

      [left, _cursor, _right] = rendered.children
      # Current: left contains all 5 emojis = 10 cells in a 6-cell field.
      assert left.content == value
    end
  end

  describe "scroll offset behavior" do
    test "typing past visible width increases scroll offset" do
      # width=5, so only 5 chars visible at a time
      state =
        create_state(%{
          value: "abcd",
          cursor_pos: 4,
          width: 5,
          scroll_offset: 0
        })

      # Type a character that puts cursor at position 5 (beyond width-1=4)
      {:noreply, s1} =
        TextField.handle_event({:keypress, "e", []}, state, default_context())

      assert s1.value == "abcde"
      assert s1.cursor_pos == 5

      # Type another character, cursor at 6, should scroll
      {:noreply, s2} =
        TextField.handle_event({:keypress, "f", []}, s1, default_context())

      assert s2.value == "abcdef"
      assert s2.cursor_pos == 6
      assert s2.scroll_offset > 0
    end

    test "arrow_left scrolls back when cursor moves before scroll window" do
      state =
        create_state(%{
          value: "abcdefghij",
          cursor_pos: 5,
          width: 5,
          scroll_offset: 5
        })

      # Move left repeatedly until cursor goes before the scroll window
      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, :arrow_left, []},
          state,
          default_context()
        )

      assert s1.cursor_pos == 4
      assert s1.scroll_offset == 4
    end

    test "home resets scroll offset to 0" do
      state =
        create_state(%{
          value: "abcdefghij",
          cursor_pos: 8,
          width: 5,
          scroll_offset: 5
        })

      {:noreply, new_state} =
        TextField.handle_event({:keypress, :home, []}, state, default_context())

      assert new_state.cursor_pos == 0
      assert new_state.scroll_offset == 0
    end

    test "end key adjusts scroll offset for long text" do
      state =
        create_state(%{
          value: "abcdefghijklmnop",
          cursor_pos: 0,
          width: 5,
          scroll_offset: 0
        })

      {:noreply, new_state} =
        TextField.handle_event({:keypress, :end, []}, state, default_context())

      assert new_state.cursor_pos == 16
      # scroll_offset should ensure cursor is visible within the 5-char window
      assert new_state.scroll_offset > 0
      assert new_state.cursor_pos <= new_state.scroll_offset + 5
    end

    test "backspace near scroll boundary adjusts scroll offset" do
      state =
        create_state(%{
          value: "abcdefghij",
          cursor_pos: 5,
          width: 5,
          scroll_offset: 5
        })

      {:noreply, new_state} =
        TextField.handle_event(
          {:keypress, :backspace, []},
          state,
          default_context()
        )

      assert new_state.value == "abcdfghij"
      assert new_state.cursor_pos == 4
      # Scroll should adjust since cursor moved before the window
      assert new_state.scroll_offset <= new_state.cursor_pos
    end

    test "delete near end of text may reduce scroll offset" do
      state =
        create_state(%{
          value: "abcdefghij",
          cursor_pos: 8,
          width: 5,
          scroll_offset: 5
        })

      {:noreply, s1} =
        TextField.handle_event(
          {:keypress, :delete, []},
          state,
          default_context()
        )

      assert s1.value == "abcdefghj"

      {:noreply, s2} =
        TextField.handle_event({:keypress, :delete, []}, s1, default_context())

      assert s2.value == "abcdefgh"
      # With 8 chars and width 5, max scroll = 3
      assert s2.scroll_offset <= max(0, String.length(s2.value) - 5)
    end
  end
end
