defmodule Raxol.Broker.Test.Hostile do
  @moduledoc """
  A struct whose protocol implementations report to `owner` when they run.

  Boundary tests embed it in caller data and then `refute_received` the
  `{:hostile, callback}` messages, proving no protocol was dispatched on it.
  """

  defstruct [:owner]

  @type t :: %__MODULE__{owner: pid()}

  @doc "A hostile value reporting to the calling process."
  @spec new() :: t()
  def new, do: %__MODULE__{owner: self()}

  defimpl Enumerable do
    def count(%{owner: owner}), do: report(owner, :count, {:ok, 0})
    def member?(%{owner: owner}, _value), do: report(owner, :member?, {:ok, true})
    def slice(%{owner: owner}), do: report(owner, :slice, {:ok, 0, fn _, _, _ -> [] end})

    def reduce(%{owner: owner}, {:cont, acc}, _fun), do: report(owner, :reduce, {:done, acc})
    def reduce(_hostile, {:halt, acc}, _fun), do: {:halted, acc}
    def reduce(hostile, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(hostile, &1, fun)}

    defp report(owner, callback, result) do
      send(owner, {:hostile, callback})
      result
    end
  end

  defimpl Inspect do
    def inspect(%{owner: owner}, _opts) do
      send(owner, {:hostile, :inspect})
      "#Hostile<>"
    end
  end

  defimpl String.Chars do
    def to_string(%{owner: owner}) do
      send(owner, {:hostile, :to_string})
      "hostile"
    end
  end
end
