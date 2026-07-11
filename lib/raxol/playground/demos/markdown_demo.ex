defmodule Raxol.Playground.Demos.MarkdownDemo do
  @moduledoc """
  Playground demo: markdown rendering with raw toggle.

  Rendered mode delegates the full document to
  `Raxol.UI.Components.MarkdownRenderer` (via `DemoHelpers.markdown/2`),
  the canonical Markdown-to-styled-elements renderer: bold/italic/code
  spans render as individually-styled elements when a line fits within
  the box's prose width, headings/lists/blockquotes/code get their own
  styling, and horizontal rules are drawn to width.

  Overflowing lines are word-wrapped via `Raxol.UI.TextLayout.wrap/3`
  (greedy `:normal` wrapping) rather than Knuth-Plass `:pretty` wrapping --
  `MarkdownRenderer` does not implement span-aware wrapping (preserving
  inline styles across a wrap boundary is documented future work there),
  so once a line's segments no longer fit, styling is dropped and the
  plain text is greedy-wrapped instead. Raw mode shows the literal
  Markdown source, one line per row, untouched.
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2, markdown: 2]

  @default_content_box_width 45
  @border_and_padding_overhead 4

  @documents [
    %{
      title: "Getting Started",
      content:
        "# Welcome\n\nThis is a *simple* demo.\n\n- Item one\n- Item two\n\nUse `mix run` to start."
    },
    %{
      title: "Features",
      content:
        "# Features\n\n- *Bold* rendering\n- `Code` highlighting\n- Simple lists\n\nSee `README.md` for details."
    },
    %{
      title: "API Reference",
      content:
        "# API\n\nCall `init/1` to start.\n\n- Returns *ok* tuple\n- Accepts a *context* map\n\n# Examples\n\nSee the `examples/` folder."
    }
  ]

  @impl true
  def init(_context) do
    %{current: 0, raw: false}
  end

  @impl true
  def update(message, model) do
    max_idx = length(@documents) - 1

    case message do
      key_match("n") ->
        {%{model | current: min(model.current + 1, max_idx)}, []}

      key_match("p") ->
        {%{model | current: max(model.current - 1, 0)}, []}

      key_match("r") ->
        {%{model | raw: not model.raw}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    doc = Enum.at(@documents, model.current)
    mode_label = if model.raw, do: "RAW", else: "RENDERED"
    box_width = effective_width(model, @default_content_box_width)
    prose_width = max(box_width - @border_and_padding_overhead, 1)

    body =
      if model.raw do
        doc.content
        |> String.split("\n")
        |> Enum.map(&text/1)
      else
        [markdown(doc.content, prose_width)]
      end

    column style: %{gap: 1} do
      [
        text("Markdown Demo", style: [:bold]),
        divider(),
        row style: %{gap: 2} do
          [
            text(doc.title, style: [:bold]),
            text("[#{mode_label}]", style: [:dim])
          ]
        end,
        box style: %{
              border: :single,
              padding: 1,
              width: box_width
            } do
          column style: %{gap: 0} do
            body
          end
        end,
        divider(),
        text("#{model.current + 1}/#{length(@documents)}"),
        text("[n] next  [p] previous  [r] toggle raw/rendered", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
