defmodule Raxol.Core.RendererOSC8Test do
  @moduledoc """
  OSC 8 hyperlink emission in the core/compat renderer path.

  Covers the View DSL `link:` attribute and the `apply_diff/1` /
  `render_to_ansi/1` emission that wraps runs of linked cells in the
  OSC 8 open/close pair while leaving unlinked cells byte-identical.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.{Buffer, Renderer}
  alias Raxol.Core.Renderer.View
  alias Raxol.Core.Renderer.View.Components.Text

  # OSC 8 bare form: ESC ] 8 ; ; URL ST  ...  ESC ] 8 ; ; ST  (ST = ESC \)
  defp osc8_open(url), do: "\e]8;;" <> url <> "\e\\"
  @osc8_close "\e]8;;\e\\"

  describe "View DSL link: attribute" do
    test "Text.new/2 carries the link onto the element" do
      el = Text.new("0x7f3a", link: "https://basescan.org/tx/0x7f3a")
      assert el.link == "https://basescan.org/tx/0x7f3a"
    end

    test "Text.new/2 link defaults to nil when omitted" do
      assert Text.new("plain").link == nil
    end

    test "View.text/2 forwards the link option" do
      assert View.text("x", link: "https://example.com").link ==
               "https://example.com"
    end
  end

  describe "apply_diff/1 OSC 8 emission" do
    test "wraps a run of linked cells in the OSC 8 open/close pair" do
      url = "https://basescan.org/tx/0xabc"
      blank = Buffer.create_blank_buffer(10, 1)
      linked = Buffer.write_at(blank, 0, 0, "tx", %{hyperlink: url})

      out = Renderer.apply_diff(Renderer.render_diff(blank, linked))

      assert String.contains?(out, osc8_open(url))
      assert String.contains?(out, @osc8_close)
      # the link text sits between the open and the close
      assert out =~
               ~r/#{Regex.escape(osc8_open(url))}.*tx.*#{Regex.escape(@osc8_close)}/s
    end

    test "leaves unlinked cells untouched (no OSC 8)" do
      blank = Buffer.create_blank_buffer(10, 1)
      plain = Buffer.write_at(blank, 0, 0, "tx", %{})

      out = Renderer.apply_diff(Renderer.render_diff(blank, plain))

      refute String.contains?(out, "\e]8")
    end

    test "an empty-string link is treated as no link" do
      blank = Buffer.create_blank_buffer(10, 1)
      empty = Buffer.write_at(blank, 0, 0, "tx", %{hyperlink: ""})

      out = Renderer.apply_diff(Renderer.render_diff(blank, empty))

      refute String.contains?(out, "\e]8")
    end
  end

  describe "render_to_ansi/1 OSC 8 emission" do
    test "wraps linked cells and closes the link" do
      url = "https://example.com/x"
      blank = Buffer.create_blank_buffer(6, 1)
      linked = Buffer.write_at(blank, 0, 0, "go", %{hyperlink: url})

      out = Renderer.render_to_ansi(linked)

      assert String.contains?(out, osc8_open(url))
      assert String.contains?(out, @osc8_close)
    end
  end

  property "apply_diff wraps iff a hyperlink is present" do
    check all(
            text <- string(:alphanumeric, min_length: 1, max_length: 8),
            host <- string(:alphanumeric, min_length: 1, max_length: 12)
          ) do
      url = "https://" <> host <> ".com"
      width = String.length(text)
      blank = Buffer.create_blank_buffer(width, 1)

      linked_out =
        blank
        |> Buffer.write_at(0, 0, text, %{hyperlink: url})
        |> then(&Renderer.apply_diff(Renderer.render_diff(blank, &1)))

      plain_out =
        blank
        |> Buffer.write_at(0, 0, text, %{})
        |> then(&Renderer.apply_diff(Renderer.render_diff(blank, &1)))

      assert String.contains?(linked_out, osc8_open(url))
      assert String.contains?(linked_out, @osc8_close)
      refute String.contains?(plain_out, "\e]8")
    end
  end
end
