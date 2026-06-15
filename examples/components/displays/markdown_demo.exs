# Markdown Renderer Demo
#
# Demonstrates terminal markdown rendering with headings, lists,
# code blocks, bold, italic, blockquotes, and links.
#
# Usage:
#   mix run examples/components/displays/markdown_demo.exs

defmodule MarkdownDemo do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.MarkdownRenderer

  @sample_markdown """
  # Raxol Markdown Demo

  This is a **bold** statement and this is _italic_ text.

  ## Features

  - Terminal-native rendering
  - Syntax highlighting via `Makeup`
  - Theme-aware styling
  - Scrollable with Viewport

  ### Ordered List

  1. First item
  2. Second item
  3. Third item

  ## Code Example

  ```elixir
  defmodule Hello do
    def greet(name) do
      IO.puts("Hello, \#{name}!")
    end
  end
  ```

  > This is a blockquote.
  > It can span multiple lines.

  ---

  Visit [Raxol](https://github.com/raxol/raxol) for more info.
  """

  @impl true
  def init(_context) do
    {:ok, md_state} =
      MarkdownRenderer.init(%{markdown_text: @sample_markdown, width: 60})

    %{markdown: md_state, scroll: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
      when key in [:down, "Down"] ->
        {%{model | scroll: model.scroll + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
      when key in [:up, "Up"] ->
        {%{model | scroll: max(0, model.scroll - 1)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    rendered = MarkdownRenderer.render(model.markdown, %{})

    column style: %{padding: 1, gap: 1} do
      [
        text("Markdown Renderer Demo", style: [:bold]),
        text("Use Up/Down to scroll. Press 'q' to quit."),
        box style: %{border: :single, width: 65, height: 20} do
          rendered
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

{:ok, pid} = Raxol.start_link(MarkdownDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
