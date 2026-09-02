defmodule Raxol.Playground.Demos.CodeBlockDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.CodeBlock` — real component using
  `Raxol.UI.SyntaxHighlighter` (same token path as Pierre DiffViewer).

  Tokens paint as styled `text/1` spans with hex `fg` from the Makeup
  theme (`:one_dark` default). Unknown languages degrade to plain text.
  CodeBlock has no line numbers / scroll / key handling — this demo only
  cycles samples with [n]/[p].
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.CodeBlock

  @samples [
    %{
      language: "elixir",
      label: "Elixir (SyntaxHighlighter / Makeup)",
      content: """
      defmodule Greeter do
        def greet(:world), do: "Hello, world!"
        def greet(name), do: "Hello, \#{name}!"
      end
      """
    },
    %{
      language: "ex",
      label: "Elixir extension \"ex\"",
      content: """
      defimpl Enumerable, for: MyStruct do
        def count(_), do: {:error, __MODULE__}
        def member?(_, _), do: {:error, __MODULE__}
        def slice(_), do: {:error, __MODULE__}
        def reduce(_, {:halt, acc}, _), do: {:halted, acc}
      end
      """
    },
    %{
      language: "text",
      label: "Plain text (no lexer)",
      content: """
      # no Makeup lexer registered for this language
      fn main() {
          println!("Hello, world!");
      }
      """
    },
    %{
      language: "python",
      label: "Python (syntect if makeup_syntect loaded, else plain)",
      content: """
      squares = [x ** 2 for x in range(10)]
      print(squares)
      """
    }
  ]

  @impl true
  def init(_context) do
    # snippet:start
    blocks =
      Enum.with_index(@samples)
      |> Map.new(fn {sample, idx} ->
        {:ok, state} =
          CodeBlock.init(%{
            id: "code-#{idx}",
            content: String.trim_trailing(sample.content),
            language: sample.language
          })

        {idx, state}
      end)

    # snippet:end

    %{current: 0, blocks: blocks, event_log: []}
  end

  @impl true
  def update(message, model) do
    max_idx = length(@samples) - 1

    case message do
      key_match("n") ->
        current = min(model.current + 1, max_idx)
        sample = Enum.at(@samples, current)

        model =
          DemoHelpers.log_event(
            model,
            "next -> #{current}: #{sample.language} (#{sample.label})"
          )

        {%{model | current: current}, []}

      key_match("p") ->
        current = max(model.current - 1, 0)
        sample = Enum.at(@samples, current)

        model =
          DemoHelpers.log_event(
            model,
            "prev -> #{current}: #{sample.language} (#{sample.label})"
          )

        {%{model | current: current}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    sample = Enum.at(@samples, model.current)
    block = Map.fetch!(model.blocks, model.current)
    elixir_block = Map.fetch!(model.blocks, 0)

    highlight_note =
      "Raxol.UI.SyntaxHighlighter (shared with DiffViewer) · theme :one_dark"

    column style: %{gap: 1} do
      [
        text("CodeBlock: Raxol.UI.Components.CodeBlock", style: [:bold]),
        text(
          " structured tokens via SyntaxHighlighter (not HTML→strip)",
          style: [:dim]
        ),
        text(""),
        text(
          " interactive sample (#{model.current + 1}/#{length(@samples)}):",
          style: [:dim]
        ),
        text(" #{sample.label}", style: [:bold]),
        box style: %{border: :single, padding: 1, width: 52} do
          CodeBlock.render(block, %{})
        end,
        text(" #{highlight_note}", style: [:dim]),
        text(""),
        text(" always-mounted Elixir story:", style: [:dim]),
        box style: %{border: :single, padding: 1, width: 52} do
          CodeBlock.render(elixir_block, %{})
        end,
        text(""),
        text("[n] next sample  [p] previous sample", style: [:dim]),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
