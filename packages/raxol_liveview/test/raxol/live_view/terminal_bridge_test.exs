defmodule Raxol.LiveView.TerminalBridgeTest do
  use ExUnit.Case, async: true

  alias Raxol.LiveView.TerminalBridge
  alias Raxol.LiveView.Test.BufferHelper, as: Buffer

  describe "buffer_to_html/2" do
    test "converts empty buffer to HTML" do
      buffer = Buffer.create_blank_buffer(10, 3)
      html = TerminalBridge.buffer_to_html(buffer)

      assert html =~ ~s(<pre class="raxol-terminal")
      assert html =~ ~s(role="log")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(</pre>)
    end

    test "converts buffer with text to HTML" do
      buffer = Buffer.create_blank_buffer(20, 5)
      buffer = Buffer.write_string(buffer, 0, 0, "Hello")

      html = TerminalBridge.buffer_to_html(buffer)

      assert html =~ "Hello"
      assert html =~ ~s(<pre class="raxol-terminal")
    end

    test "applies theme class" do
      buffer = Buffer.create_blank_buffer(10, 3)

      html = TerminalBridge.buffer_to_html(buffer, theme: :nord)
      assert html =~ "raxol-theme-nord"

      html = TerminalBridge.buffer_to_html(buffer, theme: :dracula)
      assert html =~ "raxol-theme-dracula"
    end

    test "uses custom CSS prefix" do
      buffer = Buffer.create_blank_buffer(10, 3)
      html = TerminalBridge.buffer_to_html(buffer, css_prefix: "custom")

      assert html =~ ~s(class="custom-terminal")
    end

    test "cursor options are accepted" do
      buffer = Buffer.create_blank_buffer(10, 3)

      html =
        TerminalBridge.buffer_to_html(buffer,
          show_cursor: true,
          cursor_position: {5, 2},
          cursor_style: :block
        )

      assert html =~ ~s(<pre class="raxol-terminal")
    end
  end

  describe "buffer_diff_to_html/3" do
    test "highlights changed cells" do
      old_buffer = Buffer.create_blank_buffer(20, 5)
      new_buffer = Buffer.write_string(old_buffer, 0, 0, "Changed")

      html = TerminalBridge.buffer_diff_to_html(old_buffer, new_buffer)

      assert html =~ "raxol-diff"
      assert html =~ "raxol-diff-changed"
    end

    test "does not highlight unchanged cells" do
      buffer = Buffer.create_blank_buffer(20, 5)
      buffer = Buffer.write_string(buffer, 0, 0, "Same")

      html = TerminalBridge.buffer_diff_to_html(buffer, buffer)

      assert html =~ "raxol-diff"
      refute html =~ "raxol-diff-changed"
    end
  end

  describe "style_to_classes/2" do
    test "converts bold to CSS class" do
      assert TerminalBridge.style_to_classes(%{bold: true}) =~ "raxol-bold"
    end

    test "converts italic to CSS class" do
      assert TerminalBridge.style_to_classes(%{italic: true}) =~ "raxol-italic"
    end

    test "converts underline to CSS class" do
      assert TerminalBridge.style_to_classes(%{underline: true}) =~ "raxol-underline"
    end

    test "converts named foreground color to CSS class" do
      assert TerminalBridge.style_to_classes(%{fg_color: :blue}) =~ "raxol-fg-blue"
    end

    test "converts named background color to CSS class" do
      assert TerminalBridge.style_to_classes(%{bg_color: :red}) =~ "raxol-bg-red"
    end

    test "combines multiple style attributes" do
      classes =
        TerminalBridge.style_to_classes(%{
          bold: true,
          italic: true,
          fg_color: :green,
          bg_color: :black
        })

      assert classes =~ "raxol-bold"
      assert classes =~ "raxol-italic"
      assert classes =~ "raxol-fg-green"
      assert classes =~ "raxol-bg-black"
    end

    test "uses custom CSS prefix" do
      classes = TerminalBridge.style_to_classes(%{bold: true, fg_color: :blue}, "custom")
      assert classes =~ "custom-bold"
      assert classes =~ "custom-fg-blue"
    end

    test "returns empty string for empty style" do
      assert TerminalBridge.style_to_classes(%{}) == ""
    end
  end

  describe "style_to_inline/1" do
    test "converts bold to inline style" do
      assert TerminalBridge.style_to_inline(%{bold: true}) =~ "font-weight: bold"
    end

    test "converts italic to inline style" do
      assert TerminalBridge.style_to_inline(%{italic: true}) =~ "font-style: italic"
    end

    test "converts underline to inline style" do
      assert TerminalBridge.style_to_inline(%{underline: true}) =~ "text-decoration: underline"
    end

    test "converts RGB foreground color to inline style" do
      assert TerminalBridge.style_to_inline(%{fg_color: {255, 128, 64}}) =~
               "color: rgb(255, 128, 64)"
    end

    test "converts RGB background color to inline style" do
      assert TerminalBridge.style_to_inline(%{bg_color: {64, 128, 255}}) =~
               "background-color: rgb(64, 128, 255)"
    end

    test "converts named foreground color to hex" do
      assert TerminalBridge.style_to_inline(%{fg_color: :red}) =~ "color: #ff0000"
    end

    test "converts named background color to hex" do
      assert TerminalBridge.style_to_inline(%{bg_color: :blue}) =~ "background-color: #0000ff"
    end

    test "converts 256-color index to RGB" do
      assert TerminalBridge.style_to_inline(%{fg_color: 196}) =~ "color: rgb("
    end

    test "combines multiple inline styles" do
      inline =
        TerminalBridge.style_to_inline(%{
          bold: true,
          italic: true,
          fg_color: {255, 0, 0},
          bg_color: {0, 0, 255}
        })

      assert inline =~ "font-weight: bold"
      assert inline =~ "font-style: italic"
      assert inline =~ "color: rgb(255, 0, 0)"
      assert inline =~ "background-color: rgb(0, 0, 255)"
    end

    test "returns empty string for empty style" do
      assert TerminalBridge.style_to_inline(%{}) == ""
    end
  end

  describe "HTML safety" do
    test "escapes HTML special characters" do
      buffer =
        Buffer.create_blank_buffer(20, 3)
        |> Buffer.write_string(0, 0, "<script>")

      html = TerminalBridge.buffer_to_html(buffer)

      assert html =~ "&lt;"
      assert html =~ "&gt;"
      refute html =~ "<script>"
    end

    test "escapes ampersands" do
      buffer =
        Buffer.create_blank_buffer(20, 3)
        |> Buffer.write_string(0, 0, "A & B")

      html = TerminalBridge.buffer_to_html(buffer)
      assert html =~ "&amp;"
    end

    test "preserves spaces in pre block" do
      buffer = Buffer.create_blank_buffer(20, 3)
      html = TerminalBridge.buffer_to_html(buffer)
      assert html =~ ~s(<pre class="raxol-terminal")
    end
  end

  describe "full-buffer rendering" do
    test "renders an 80x24 buffer to well-formed HTML" do
      buffer =
        Enum.reduce(0..23, Buffer.create_blank_buffer(80, 24), fn y, acc ->
          Buffer.write_string(acc, 0, y, "Line #{y}")
        end)

      html = TerminalBridge.buffer_to_html(buffer)

      assert html =~ ~s(<pre class="raxol-terminal")
      assert html =~ "Line 0"
      assert html =~ "Line 23"
    end

    test "diff rendering emits diff-marked HTML for cells that changed" do
      old_buffer = Buffer.create_blank_buffer(80, 24)

      new_buffer =
        Enum.reduce(0..23, old_buffer, fn y, acc ->
          Buffer.write_string(acc, 0, y, "Line #{y}")
        end)

      html = TerminalBridge.buffer_diff_to_html(old_buffer, new_buffer)

      assert is_binary(html)
      assert html =~ "raxol-diff"
      # Diff splits each rendered character into its own span; verify the
      # first line of changed cells is present in cell form.
      assert html =~ ">L</span>"
      assert html =~ ">i</span>"
      assert html =~ ">n</span>"
      assert html =~ ">e</span>"
    end
  end

  describe "per-element ARIA (a11y_map)" do
    # Map a run of cells to an element id, then supply an accessibility node for
    # that id. The span carrying data-raxol-id="<id>" should gain ARIA read
    # straight from the node (the bridge never recomputes roles).
    defp with_mapped_text(text, id, node) do
      buffer = Buffer.write_string(Buffer.create_blank_buffer(40, 3), 0, 0, text)

      id_map =
        for x <- 0..(String.length(text) - 1), into: %{}, do: {{x, 0}, id}

      a11y_map = if node, do: %{id => node}, else: %{}

      TerminalBridge.buffer_to_html(buffer,
        element_id_map: id_map,
        a11y_map: a11y_map
      )
    end

    test "emits role and aria-label from the node" do
      node = %{
        role: :button,
        label: "Save",
        state: %{},
        value: nil,
        children: [],
        live?: false,
        id: "save"
      }

      html = with_mapped_text("Save", "save", node)

      assert html =~ ~s(data-raxol-id="save")
      assert html =~ ~s(role="button")
      assert html =~ ~s(aria-label="Save")
    end

    test "emits aria-disabled and aria-required from present flags" do
      node = %{
        role: :textbox,
        label: "Name",
        state: %{disabled?: true, required?: true},
        value: nil,
        children: [],
        live?: false,
        id: "name"
      }

      html = with_mapped_text("Name", "name", node)

      assert html =~ ~s(aria-disabled="true")
      assert html =~ ~s(aria-required="true")
    end

    test "emits tri-state aria-checked=false when the flag is present and false" do
      node = %{
        role: :checkbox,
        label: "Agree",
        state: %{checked?: false},
        value: nil,
        children: [],
        live?: false,
        id: "agree"
      }

      html = with_mapped_text("[ ] Agree", "agree", node)

      assert html =~ ~s(aria-checked="false")
    end

    test "emits aria-selected and aria-expanded from the node state" do
      node = %{
        role: :option,
        label: "Item",
        state: %{selected?: true, expanded?: false},
        value: nil,
        children: [],
        live?: false,
        id: "opt"
      }

      html = with_mapped_text("Item", "opt", node)

      assert html =~ ~s(aria-selected="true")
      assert html =~ ~s(aria-expanded="false")
    end

    test "escapes the aria-label value" do
      node = %{
        role: :button,
        label: ~s(A"<b>&),
        state: %{},
        value: nil,
        children: [],
        live?: false,
        id: "b"
      }

      html = with_mapped_text("Btn", "b", node)

      assert html =~ ~s(aria-label="A&quot;&lt;b&gt;&amp;")
      refute html =~ ~s(aria-label="A"<b>&")
    end

    test "id with no a11y_map entry gets data-raxol-id but no ARIA" do
      html = with_mapped_text("Plain", "plain", nil)

      # The span closes immediately after data-raxol-id: no ARIA injected.
      assert html =~ ~s(<span data-raxol-id="plain">Plain</span>)
      refute html =~ "aria-label"
    end
  end

  describe "aria_mode container semantics" do
    test "defaults to :log (whole-screen live region)" do
      buffer = Buffer.create_blank_buffer(10, 2)
      html = TerminalBridge.buffer_to_html(buffer)

      assert html =~ ~s(role="log")
      assert html =~ ~s(aria-live="polite")
    end

    test ":application drops the live region" do
      buffer = Buffer.create_blank_buffer(10, 2)
      html = TerminalBridge.buffer_to_html(buffer, aria_mode: :application)

      assert html =~ ~s(role="application")
      refute html =~ ~s(role="log")
      refute html =~ "aria-live"
    end
  end

  describe "buffer_to_rows/2" do
    test "a one-cell edit changes exactly one row" do
      before = styled_screen()
      after_edit = Buffer.set_cell(before, 3, 5, "X", style: %{fg_color: :red})

      rows_before = TerminalBridge.buffer_to_rows(before)
      rows_after = TerminalBridge.buffer_to_rows(after_edit)

      changed =
        Enum.zip(rows_before, rows_after)
        |> Enum.reject(fn {old, new} -> old == new end)
        |> Enum.map(fn {_old, new} -> new.y end)

      assert changed == [5]
    end

    test "the screen is the rows joined by newlines" do
      buffer = styled_screen()

      joined =
        TerminalBridge.buffer_to_rows(buffer, use_inline_styles: true)
        |> Enum.map_join("\n", & &1.html)

      html = TerminalBridge.buffer_to_html(buffer, use_inline_styles: true)

      assert html ==
               ~s(<pre class="raxol-terminal" role="log" aria-live="polite" aria-atomic="false">) <>
                 joined <> "</pre>\n"
    end

    test "row ids carry the css prefix and survive a frame change" do
      before = styled_screen()
      after_edit = Buffer.set_cell(before, 3, 5, "X", style: %{fg_color: :red})

      ids = fn buffer ->
        buffer
        |> TerminalBridge.buffer_to_rows(css_prefix: "term")
        |> Enum.map(& &1.id)
      end

      assert ids.(before) == ids.(after_edit)
      assert Enum.take(ids.(before), 2) == ["term-row-0", "term-row-1"]
    end
  end

  describe "html_to_rows/2" do
    test "inverts buffer_to_html/2 back into buffer_to_rows/2 rows" do
      buffer = styled_screen()
      opts = [use_inline_styles: true]

      html = TerminalBridge.buffer_to_html(buffer, opts)

      assert TerminalBridge.html_to_rows(html) ==
               TerminalBridge.buffer_to_rows(buffer, opts)
    end

    test "an unrendered screen has no rows" do
      assert TerminalBridge.html_to_rows("") == []
    end
  end

  # A screen with enough style variation that rows differ from one another,
  # so "only one row changed" cannot pass by every row being identical.
  defp styled_screen do
    colors = [:cyan, :green, :yellow, :magenta, :blue, :red]

    Enum.reduce(0..11, Buffer.create_blank_buffer(30, 12), fn y, buffer ->
      buffer
      |> Buffer.write_string(0, y, "row #{y} <load>",
        style: %{fg_color: Enum.at(colors, rem(y, 6))}
      )
      |> Buffer.write_string(16, y, String.duplicate("#", rem(y * 3, 12)),
        style: %{fg_color: Enum.at(colors, rem(y + 2, 6)), bold: true}
      )
    end)
  end
end
