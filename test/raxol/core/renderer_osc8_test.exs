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
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.View.Components

  # OSC 8 bare form: ESC ] 8 ; ; URL ST  ...  ESC ] 8 ; ; ST  (ST = ESC \)
  defp osc8_open(url), do: "\e]8;;" <> url <> "\e\\"
  @osc8_close "\e]8;;\e\\"

  # Counting ESCs is how a smuggled one is caught: a correct OSC 8
  # emission is itself made of ESCs, so absence is not assertable -- only
  # a surplus over an equivalent clean render is.
  defp esc_count(output), do: length(String.split(output, "\e")) - 1

  # `apply_diff/1` output for a one-cell write carrying `url`.
  defp linked_output(url) do
    blank = Buffer.create_blank_buffer(10, 1)

    blank
    |> Buffer.write_at(0, 0, "tx", %{hyperlink: url})
    |> then(&Renderer.apply_diff(Renderer.render_diff(blank, &1)))
  end

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

  describe "layout link propagation" do
    test "layout sanitizes the top-level link value it propagates" do
      [positioned] =
        Components.text(content: "go", link: "https://ok\e]52;c;payload\a\r\n")
        |> LayoutEngine.apply_layout(%{width: 20, height: 1})

      assert positioned.link == "https://ok"

      [non_binary] =
        Components.text(content: "go", link: %{unsafe: true})
        |> LayoutEngine.apply_layout(%{width: 20, height: 1})

      assert non_binary.link == ""
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

    # The URL is spliced into `ESC ] 8 ;; <url> ST` verbatim, so an ESC in
    # it closes our sequence and opens an attacker-chosen one -- here an
    # OSC 52 clipboard write. The emitter is the sink: it has to confine
    # the URL itself, because a `:hyperlink` arrives from a Markdown link
    # an LLM wrote, from an OSC 8 sequence the emulator parsed out of
    # untrusted program output, and from any `text(link: ...)` caller.
    #
    # The assertion is on the ESC COUNT against a clean render of the same
    # shape, not on ESC absence: a correct OSC 8 emission is itself made
    # of ESCs, so a smuggled one can only show up as a surplus.
    test "a URL cannot smuggle an escape sequence into the OSC 8 open" do
      out = linked_output("http://x\e]52;c;cHduZWQ=\a")

      assert String.contains?(out, osc8_open("http://x"))
      assert String.contains?(out, @osc8_close)
      assert esc_count(out) == esc_count(linked_output("http://x"))
    end

    # Every control class an OSC 8 URL can carry, minus ESC (the test
    # above owns that one, since a correct OSC 8 emission supplies ESCs of
    # its own). An OSC body only ends at BEL or ST, so a URL the emulator
    # parsed out of real input can hold CR, BS, DEL and a raw 8-bit CSI
    # (0x9B) with no ESC at all -- re-emitted inside our own OSC 8, those
    # are executed.
    test "no control byte of any class survives into the emitted URL" do
      for {name, byte} <- [
            {"BEL", "\a"},
            {"CR", "\r"},
            {"LF", "\n"},
            {"TAB", "\t"},
            {"BS", "\b"},
            {"DEL", <<0x7F>>},
            {"raw 8-bit CSI", <<0x9B>>},
            {"C1 CSI (U+009B)", "\u009B"}
          ] do
        out = linked_output("http://ok" <> byte <> "tail")

        # Dropped in place, so the URL's surrounding text survives and the
        # emission is byte-identical to the clean one.
        assert out == linked_output("http://oktail"), "#{name}: #{inspect(out)}"

        refute String.contains?(out, byte),
               "#{name} survived into the emitted URL: #{inspect(out)}"
      end
    end

    # A URL made only of control bytes sanitizes to "", and an empty URL
    # is already "no link" -- so no bare OSC 8 pair wraps the content.
    test "a URL that is entirely control bytes emits no hyperlink at all" do
      refute String.contains?(linked_output("\e[2J\r" <> <<0x7F>>), "\e]8")
    end
  end

  describe "display text confinement" do
    test "display text is confined before OSC 8 assembly" do
      url = "https://example.com"

      output =
        Renderer.apply_diff([
          {:write, "safe\e[2J\e]52;c;payload\a\r\n\t tail", %{hyperlink: url}}
        ])

      assert output == osc8_open(url) <> "safe tail" <> @osc8_close
      refute output =~ "\e]52"
      refute output =~ "\e[2J"
    end

    test "non-binary display content fails closed" do
      refute Renderer.apply_diff([
               {:write, %{unsafe: "\e]52;c;payload\a"}, %{hyperlink: "https://example.com"}}
             ]) =~ "\e]8"
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
