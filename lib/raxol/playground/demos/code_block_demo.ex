defmodule Raxol.Playground.Demos.CodeBlockDemo do
  @moduledoc """
  Playground demo: code display with line numbers and language samples.

  Code lines use `white_space: :nowrap` + `text_overflow: :ellipsis`
  (`docs/core/LAYOUT.md` section 4) instead of the default word-wrap --
  code shouldn't reflow mid-token, so an overly long line truncates with
  an ellipsis instead of breaking across rows.
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2, rich_text: 2]

  @default_code_box_width 45
  @line_number_pad 2
  @border_and_padding_overhead 4

  @samples [
    %{
      lang: "Elixir",
      label: "Pattern Matching",
      code:
        "def greet(:world), do: \"Hello, world!\"\ndef greet(name), do: \"Hello, \#{name}!\""
    },
    %{
      lang: "Rust",
      label: "Hello World",
      code: "fn main() {\n    println!(\"Hello, world!\");\n}"
    },
    %{
      lang: "Python",
      label: "List Comprehension",
      code: "squares = [x ** 2 for x in range(10)]\nprint(squares)"
    }
  ]

  @impl true
  def init(_context) do
    %{current: 0, show_line_numbers: true}
  end

  @impl true
  def update(message, model) do
    max_idx = length(@samples) - 1

    case message do
      key_match("n") ->
        {%{model | current: min(model.current + 1, max_idx)}, []}

      key_match("p") ->
        {%{model | current: max(model.current - 1, 0)}, []}

      key_match("l") ->
        {%{model | show_line_numbers: not model.show_line_numbers}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    sample = Enum.at(@samples, model.current)
    lines = String.split(sample.code, "\n")
    box_width = effective_width(model, @default_code_box_width)

    code_lines =
      lines
      |> Enum.with_index(1)
      |> Enum.map(&code_line(&1, model.show_line_numbers, box_width))

    ln_label = if model.show_line_numbers, do: "ON", else: "OFF"

    column style: %{gap: 1} do
      [
        text("CodeBlock Demo", style: [:bold]),
        divider(),
        text("#{sample.lang}: #{sample.label}", style: [:bold]),
        box style: %{
              border: :single,
              padding: 1,
              width: box_width
            } do
          column style: %{gap: 0} do
            code_lines
          end
        end,
        divider(),
        row style: %{gap: 2} do
          [
            text("#{model.current + 1}/#{length(@samples)}"),
            text("Line numbers: #{ln_label}")
          ]
        end,
        text("[n] next  [p] previous  [l] toggle line numbers", style: [:dim])
      ]
    end
  end

  defp code_line({line, num}, true, box_width) do
    prefix =
      String.pad_leading(Integer.to_string(num), @line_number_pad) <> " | "

    code_width =
      max(box_width - @border_and_padding_overhead - String.length(prefix), 1)

    row style: %{gap: 0} do
      [
        text(prefix),
        rich_text(line,
          width: code_width,
          white_space: :nowrap,
          text_overflow: :ellipsis
        )
      ]
    end
  end

  defp code_line({line, _num}, false, box_width) do
    code_width = max(box_width - @border_and_padding_overhead - 2, 1)

    row style: %{gap: 0} do
      [
        text("  "),
        rich_text(line,
          width: code_width,
          white_space: :nowrap,
          text_overflow: :ellipsis
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
