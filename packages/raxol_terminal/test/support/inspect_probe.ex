defmodule Raxol.Test.InspectProbe do
  @moduledoc false
  # A value that reports every time it is inspected: its `Inspect`
  # implementation sends `{:inspected, tag}` to the process that built it.
  # Put one where a log message could dump it, run the path with that log
  # level disabled, and `refute_received {:inspected, _}` proves no message
  # was built. It lives in test/support so the implementation is part of the
  # consolidated `Inspect` protocol.

  defstruct [:owner, :tag]

  @type t :: %__MODULE__{owner: pid(), tag: term()}

  @spec new(term()) :: t()
  def new(tag), do: %__MODULE__{owner: self(), tag: tag}

  defimpl Inspect do
    def inspect(%{owner: owner, tag: tag}, _opts) do
      send(owner, {:inspected, tag})
      "#InspectProbe<" <> Kernel.inspect(tag) <> ">"
    end
  end
end
