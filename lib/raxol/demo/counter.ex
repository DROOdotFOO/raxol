defmodule Raxol.Demo.Counter do
  @moduledoc """
  Simple counter demo for `mix raxol.demo counter`.

  Demonstrates basic TEA pattern: init/update/view with keyboard and button input.

  Controls: =/- to count, q/Ctrl+C to quit.
  """

  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context), do: %{count: 0}

  @impl true
  def update(message, model) do
    case message do
      :increment ->
        {%{model | count: model.count + 1}, []}

      :decrement ->
        {%{model | count: model.count - 1}, []}

      :reset ->
        {%{model | count: 0}, []}

      key_match("=") ->
        {%{model | count: model.count + 1}, []}

      key_match("-") ->
        {%{model | count: model.count - 1}, []}

      key_match("q") ->
        {model, [Directive.stop()]}

      key_match("c", ctrl: true) ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1, align_items: :center} do
      [
        text("Counter Demo", style: [:bold]),
        box style: %{
              padding: 1,
              border: :single,
              width: 20,
              justify_content: :center
            } do
          text("Count: #{model.count}", style: [:bold])
        end,
        row style: %{gap: 1} do
          [
            button("Increment (=)", on_click: :increment),
            button("Reset", on_click: :reset),
            button("Decrement (-)", on_click: :decrement)
          ]
        end,
        text("Press '=' or '-' keys, or click buttons."),
        text("Press 'q' or Ctrl+C to quit")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
