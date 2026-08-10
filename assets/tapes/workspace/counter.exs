defmodule Counter do
  @moduledoc "The smallest TEA app: a number and two keys."
  use Raxol.UI, framework: :react

  def init(_), do: %{count: 0}

  def update(:increment, model), do: %{model | count: model.count + 1}
  def update(:decrement, model), do: %{model | count: model.count - 1}
  def update(_, model), do: model

  def view(model) do
    column do
      text("count: #{model.count}", fg: :cyan, style: [:bold])
      text("+/- to change, q to quit", fg: :white)
    end
  end
end
