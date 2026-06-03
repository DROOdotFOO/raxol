defmodule Raxol.Test.BackpressureTarget do
  @moduledoc """
  Controllable GenServer fixture for `Raxol.Core.Runtime.Backpressure` tests.

  Records every `{:msg, payload}` it receives via cast or call. `pause/1`
  blocks the receive loop until `resume/1` is sent, so callers can saturate
  the process mailbox without it being drained.
  """

  use GenServer

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, [])

  def received(pid), do: GenServer.call(pid, :received)
  def pause(pid), do: GenServer.cast(pid, :pause)
  def resume(pid), do: send(pid, :resume)

  @impl true
  def init(_), do: {:ok, %{received: []}}

  @impl true
  def handle_cast(:pause, state) do
    receive do
      :resume -> {:noreply, state}
    end
  end

  def handle_cast({:msg, payload}, state) do
    {:noreply, %{state | received: [payload | state.received]}}
  end

  @impl true
  def handle_call(:received, _from, state) do
    {:reply, Enum.reverse(state.received), state}
  end

  def handle_call({:msg, payload}, _from, state) do
    {:reply, :ok, %{state | received: [payload | state.received]}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}
end
