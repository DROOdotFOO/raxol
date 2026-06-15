# CodeBlock Demo
#
# Demonstrates syntax-highlighted code display using the CodeBlock widget.
#
# Usage:
#   mix run examples/components/displays/code_block_demo.exs

defmodule CodeBlockDemo do
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.CodeBlock

  @samples [
    {"Elixir - GenServer", "elixir",
     """
     defmodule Counter do
       use GenServer

       def start_link(initial) do
         GenServer.start_link(__MODULE__, initial, name: __MODULE__)
       end

       @impl true
       def init(count), do: {:ok, count}

       @impl true
       def handle_call(:get, _from, count) do
         {:reply, count, count}
       end

       @impl true
       def handle_cast(:increment, count) do
         {:noreply, count + 1}
       end
     end
     """},
    {"Elixir - Pattern Matching", "elixir",
     """
     defmodule Parser do
       def parse({:ok, data}), do: process(data)
       def parse({:error, reason}), do: {:error, reason}

       defp process(%{name: name, age: age}) when age > 0 do
         {:ok, String.upcase(name)}
       end

       defp process(_), do: {:error, :invalid}
     end
     """},
    {"Plain Text", "text",
     """
     This is plain text without syntax highlighting.
     It serves as a fallback when no lexer is available.
     Line 3 of the plain text sample.
     """}
  ]

  @impl true
  def init(_context) do
    %{current: 0, samples: @samples}
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

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "n"}} ->
        next = rem(model.current + 1, length(model.samples))
        {%{model | current: next}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "p"}} ->
        prev =
          rem(model.current - 1 + length(model.samples), length(model.samples))

        {%{model | current: prev}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    {title, language, code} = Enum.at(model.samples, model.current)

    {:ok, cb_state} =
      CodeBlock.init(%{content: String.trim(code), language: language})

    column style: %{padding: 1, gap: 1} do
      [
        text("CodeBlock Demo", style: [:bold]),
        text(
          "Sample #{model.current + 1}/#{length(model.samples)}: #{title} (#{language})"
        ),
        text("Press 'n'/'p' to cycle samples, 'q' to quit."),
        box style: %{border: :single, padding: 1} do
          CodeBlock.render(cb_state, %{})
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

{:ok, pid} = Raxol.start_link(CodeBlockDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
