defmodule Raxol.UI.TextAttributesLivePathTest do
  @moduledoc """
  `style: [:dim]`, `[:reverse]` and `[:strikethrough]` reach every surface
  through the live render pipeline (#1132):

      View DSL -> layout -> UIRenderer.render_to_cells  (attrs list)
        -> Backends.apply_cells_to_buffer               (cell.style)
        -> render_to_terminal / render_to_ssh           (SGR 2 / 7 / 9)
        -> render_to_liveview                           (inline CSS)

  The bridge used to keep only bold, underline and italic, so each of these
  drew plain on every surface.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Renderer.View
  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Renderer, as: UIRenderer

  @width 40
  @height 4

  # One line per attribute, plus an unstyled control line.
  defp cells do
    View.column(
      children: [
        View.text("dimmed", style: [:dim]),
        View.text("reversed", style: [:reverse], fg: :red, bg: :blue),
        View.text("struck", style: [:strikethrough]),
        View.text("plain")
      ]
    )
    |> LayoutEngine.apply_layout(%{width: @width, height: @height})
    |> UIRenderer.render_to_cells(nil)
  end

  describe "the ANSI surfaces" do
    test "render_to_ssh emits SGR 2, 7 and 9 on the styled runs only" do
      parent = self()

      state = %{
        width: @width,
        height: @height,
        buffer: nil,
        sync_output: false,
        io_writer: &send(parent, {:ssh_write, &1})
      }

      {:ok, _state} = Backends.render_to_ssh(cells(), state)
      assert_receive {:ssh_write, output}

      assert_sgr(output, "dimmed", "2")
      assert_sgr(output, "reversed", "7")
      assert_sgr(output, "struck", "9")
      refute_any_sgr(output, "plain", ["2", "7", "9"])
    end

    test "render_to_terminal emits SGR 2, 7 and 9 on the styled runs only" do
      state = %{
        width: @width,
        height: @height,
        buffer: nil,
        sync_output: false,
        force_repaint: false
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, _state} = Backends.render_to_terminal(cells(), state)
        end)

      assert_sgr(output, "dimmed", "2")
      assert_sgr(output, "reversed", "7")
      assert_sgr(output, "struck", "9")
      refute_any_sgr(output, "plain", ["2", "7", "9"])
    end
  end

  describe "the LiveView surface" do
    setup do
      case Process.whereis(Raxol.PubSub) do
        nil -> start_supervised!({Phoenix.PubSub, name: Raxol.PubSub})
        _pid -> :ok
      end

      topic = "text_attributes_live_path:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(Raxol.PubSub, topic)
      %{topic: topic}
    end

    test "render_to_liveview styles each attribute's span", %{topic: topic} do
      state = %{
        width: @width,
        height: @height,
        buffer: nil,
        liveview_topic: topic
      }

      {:ok, _state} = Backends.render_to_liveview(cells(), state)
      assert_receive {:render_update, html, _animation_css}

      # Faint: the text colour at half strength, the cell background untouched.
      assert span_style(html, "dimmed") =~
               ~r/(^|; )color: color-mix\(in srgb, [^;]+ 50%, transparent\)/

      # Reverse video swaps the two colours.
      reversed = span_style(html, "reversed")
      assert reversed =~ ~r/(^|; )color: #0000ff(;|$)/
      assert reversed =~ ~r/(^|; )background-color: #ff0000(;|$)/

      assert span_style(html, "struck") =~ "text-decoration: line-through"

      plain = span_style(html, "plain") || ""
      refute plain =~ "color-mix"
      refute plain =~ "line-through"
    end
  end

  # The SGR codes of the run that draws `text`: the escape sequences directly
  # in front of it.
  defp sgr_codes(output, text) do
    case Regex.run(~r/((?:\e\[[0-9;:]*m)*)#{Regex.escape(text)}/, output) do
      [_, prefix] ->
        ~r/\e\[([0-9;:]*)m/
        |> Regex.scan(prefix, capture: :all_but_first)
        |> Enum.flat_map(fn [params] -> String.split(params, ";") end)

      nil ->
        flunk("#{inspect(text)} was not drawn in #{inspect(output)}")
    end
  end

  defp assert_sgr(output, text, code) do
    codes = sgr_codes(output, text)

    assert code in codes,
           "expected SGR #{code} on #{inspect(text)}, its run carries #{inspect(codes)}"
  end

  defp refute_any_sgr(output, text, forbidden) do
    codes = sgr_codes(output, text)

    assert Enum.all?(forbidden, &(&1 not in codes)),
           "#{inspect(text)} carries #{inspect(codes)}, none of #{inspect(forbidden)} expected"
  end

  # The inline style of the span holding `text`, or nil when it is unstyled.
  defp span_style(html, text) do
    case Regex.run(
           ~r/<span style="([^"]*)"[^>]*>[^<]*#{Regex.escape(text)}/,
           html
         ) do
      [_, style] -> style
      nil -> nil
    end
  end
end
