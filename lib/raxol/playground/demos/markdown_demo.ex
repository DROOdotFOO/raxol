defmodule Raxol.Playground.Demos.MarkdownDemo do
  @moduledoc """
  Playground demo: full Markdown feature surface via
  `Raxol.UI.Components.MarkdownRenderer`.

  Rendered mode uses EarmarkParser (when loaded) + CodeBlock/SyntaxHighlighter
  for fenced code. Raw mode shows the literal source. Cycle documents with
  [n]/[p]; toggle raw with [r].
  """
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2, markdown: 2]

  @default_content_box_width 56
  @border_and_padding_overhead 4

  # One document per major feature cluster so the catalog can page through
  # the full renderer surface without a single wall of text.
  @documents [
    %{
      title: "Feature catalog",
      content: """
      # Markdown feature catalog

      Full surface of **MarkdownRenderer**. Cycle docs with n / p.

      | Feature | Status |
      | --- | --- |
      | Headings h1-h6 | yes |
      | Bold / italic | yes |
      | Inline code spans | yes |
      | Fenced code + highlight | yes (CodeBlock) |
      | Lists (ul/ol) | yes |
      | Blockquotes | yes |
      | Links | yes |
      | Horizontal rules | yes |
      | GFM tables | yes |
      """
    },
    %{
      title: "Headings & emphasis",
      content: """
      # Heading 1
      ## Heading 2
      ### Heading 3
      #### Heading 4

      Paragraph with **bold**, *italic*, and ***both***.

      Inline code: `Map.get/3` and `Enum.map/2`.

      ---

      A horizontal rule sits above this line.
      """
    },
    %{
      title: "Lists & quotes",
      content: """
      ## Unordered

      - Alpha
      - *Bravo* with emphasis
      - Charlie with `inline`

      ## Ordered

      1. First step
      2. Second step
      3. Third step

      ## Blockquote

      > Quoted prose can carry **bold** and `code`.
      > Second quoted line.
      """
    },
    %{
      title: "Links & table",
      content: """
      Read the [Raxol docs](https://raxol.io) and the [Hex package](https://hex.pm/packages/raxol).

      | Framework | Language | Stars |
      | --- | --- | ---: |
      | Raxol | Elixir | 500 |
      | Bubble Tea | Go | 39k |
      | Ratatui | Rust | 19k |
      """
    },
    %{
      title: "Fenced code (highlighted)",
      content: """
      Elixir fence — token colors from `SyntaxHighlighter` / CodeBlock:

      ```elixir
      defmodule Greeter do
        @moduledoc "Hello"

        def greet(name) when is_binary(name) do
          "Hello, \#{name}!"
        end

        def greet(_), do: :error
      end
      ```

      Untagged fence (plain, still indented):

      ```
      plain line one
      plain line two
      ```

      Tilde fence with language tag:

      ~~~elixir
      IO.puts(:ok)
      ~~~
      """
    },
    # Characters whose byte length, grapheme count and display width are
    # three different numbers, in every placement at once. Two renderer
    # bugs have already hidden in exactly this gap, so this doc is the
    # eyeball counterpart to the unit tests: if a column is misaligned, a
    # span is mis-coloured, or a line overflows the frame, it is visible
    # here immediately.
    %{
      title: "Unicode & wide characters",
      content: """
      ## 日本語の見出し — CJK heading

      Wide 日本語 runs, an em dash —, a ZWJ family 👨‍👩‍👧‍👦, a flag 🇯🇵 and a combining é all sit inline with **太字 bold**, *斜体 italic*, `コード code` and [リンク link](https://raxol.io) on one source line long enough to wrap several times.

      日本語だけの段落は空白がないため、折り返しは表意文字の間で起こります。行はきちんと詰まっていなければならず、途中で文字が壊れてはいけません。

      - 項目：全角文字を含む長い箇条書きの行で、折り返した続きが箇条書きの下に揃うことを確認します
      - Emoji bullet 🎉 with `インライン` code
      - Combining marks: éàü and ZWJ 👩‍💻 mid-sentence

      > 引用文に **太字** と `コード` が入ります。全角の引用が折り返しても、行頭の罫線は揃ったままでなければなりません。

      | 名前 | Width | 説明 |
      | --- | ---: | :---: |
      | 日本語 | 6 | 全角文字 |
      | emoji 🎉 | 2 | ZWJ 👨‍👩‍👧‍👦 |
      | ascii | 5 | narrow |

      ```elixir
      # 全角コメント — must survive byte-for-byte 👨‍👩‍👧‍👦
      def greet(名前), do: "こんにちは、\#{名前}！"
      ```
      """
    },
    %{
      title: "Mixed document",
      content: """
      # Getting started

      Install with `mix deps.get`, then:

      1. Write a TEA app
      2. Call `Raxol.start_link/2`
      3. Ship over SSH or MCP

      > Prefer **structured** styles — never embed raw ANSI in View DSL strings.

      ```elixir
      def update({:key, k}, model), do: {model, []}
      def view(model), do: text("hi")
      ```

      ---

      See [examples/](https://github.com/raxol) for more.
      """
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

    # snippet:start
    body =
      if model.raw do
        doc.content
        |> String.split("\n")
        |> Enum.map(&text/1)
      else
        [markdown(doc.content, prose_width)]
      end

    # snippet:end

    column style: %{gap: 1} do
      [
        text("Markdown: Raxol.UI.Components.MarkdownRenderer", style: [:bold]),
        text(
          " fenced code → CodeBlock/SyntaxHighlighter · [r] raw source",
          style: [:dim]
        ),
        text(""),
        row style: %{gap: 2} do
          [
            text(doc.title, style: [:bold]),
            text("[#{mode_label}]", style: [:dim]),
            text("#{model.current + 1}/#{length(@documents)}", style: [:dim])
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
        text(""),
        text("[n] next  [p] previous  [r] toggle raw/rendered", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
