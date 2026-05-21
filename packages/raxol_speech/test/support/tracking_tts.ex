defmodule Raxol.Speech.TTS.Tracking do
  @moduledoc false
  # Test-only TTS backend that records every call (speak/stop) in order.
  # Use to assert ordering, e.g. that priority interrupts call stop/1
  # before speak/1.

  @behaviour Raxol.Speech.TTS.Backend

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl true
  def speak(text) do
    Agent.update(__MODULE__, &[{:speak, text} | &1])
    :ok
  end

  @impl true
  def stop do
    Agent.update(__MODULE__, &[:stop | &1])
    :ok
  end

  @impl true
  def speaking?, do: false

  @doc "Returns calls in chronological order."
  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)

  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)
end
