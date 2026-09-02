defmodule Raxol.Playground.Demos.TextDemo do
  @moduledoc """
  Playground demo: text rendering with style variations, plus the
  `Raxol.UI.Components.Display.Text` wrapping/truncation affordances
  documented in `docs/core/LAYOUT.md` section 4 (`text_overflow: :ellipsis`,
  `line_clamp`, `text_wrap: :pretty`).
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [rich_text: 2]

  @sample "The quick brown fox jumps over the lazy dog"
  @long_line "This line is intentionally far too long to fit inside a narrow box"
  @prose "Raxol is a multi-surface application runtime for Elixir built on OTP, covering terminal, browser, SSH, and MCP surfaces."
  @wrap_width 24

  @variants [
    %{label: "Bold", kind: :style, style: [:bold]},
    %{label: "Italic", kind: :style, style: [:italic]},
    %{label: "Underline", kind: :style, style: [:underline]},
    %{label: "Bold + Italic", kind: :style, style: [:bold, :italic]},
    %{label: "Dim", kind: :style, style: [:dim]},
    %{label: "Bold + Underline", kind: :style, style: [:bold, :underline]},
    %{label: "Ellipsis (text_overflow)", kind: :ellipsis},
    %{label: "Line clamp (2 lines)", kind: :line_clamp},
    %{label: "Pretty wrap (Knuth-Plass)", kind: :pretty}
  ]

  @impl true
  def init(_context) do
    %{style_index: 0}
  end

  @impl true
  def update(message, model) do
    max_idx = length(@variants) - 1

    case message do
      key_match("n") ->
        {%{model | style_index: min(model.style_index + 1, max_idx)}, []}

      key_match("p") ->
        {%{model | style_index: max(model.style_index - 1, 0)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    current = Enum.at(@variants, model.style_index)

    variant_list =
      @variants
      |> Enum.with_index()
      |> Enum.map(fn {v, idx} ->
        indicator = if idx == model.style_index, do: "> ", else: "  "
        text(indicator <> v.label)
      end)

    column style: %{gap: 1} do
      [
        text("Text Demo", style: [:bold]),
        divider(),
        text("Current: #{current.label}", style: [:bold]),
        box style: %{border: :single, padding: 1, width: 44} do
          sample_for(current)
        end,
        divider(),
        text("All variants:", style: [:underline]),
        column style: %{gap: 0} do
          variant_list
        end,
        text("#{model.style_index + 1}/#{length(@variants)}"),
        text("[n] next  [p] previous", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Sample rendering per variant kind --

  # snippet:start
  defp sample_for(%{kind: :style, style: style}) do
    text(@sample, style: style)
  end

  defp sample_for(%{kind: :ellipsis}) do
    column style: %{gap: 0} do
      [
        rich_text(@long_line,
          width: @wrap_width,
          white_space: :nowrap,
          text_overflow: :ellipsis
        ),
        text(
          "white_space: :nowrap, text_overflow: :ellipsis, width: #{@wrap_width}",
          style: [:dim]
        )
      ]
    end
  end

  # snippet:end

  defp sample_for(%{kind: :line_clamp}) do
    column style: %{gap: 0} do
      [
        rich_text(@prose, width: @wrap_width, line_clamp: 2),
        text("line_clamp: 2, width: #{@wrap_width}", style: [:dim])
      ]
    end
  end

  defp sample_for(%{kind: :pretty}) do
    column style: %{gap: 1} do
      [
        column style: %{gap: 0} do
          [
            text("auto (greedy word-wrap):", style: [:dim]),
            rich_text(@prose, width: @wrap_width, wrap: :word)
          ]
        end,
        column style: %{gap: 0} do
          [
            text("pretty (Knuth-Plass, minimizes raggedness):", style: [:dim]),
            rich_text(@prose, width: @wrap_width, text_wrap: :pretty)
          ]
        end
      ]
    end
  end
end
