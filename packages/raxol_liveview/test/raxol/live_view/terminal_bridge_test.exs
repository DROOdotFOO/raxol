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
end
