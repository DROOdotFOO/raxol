defmodule Raxol.Harness.DeliveryShim do
  @moduledoc """
  The SessionPump's delivery shim into the Dispatcher (unit U6-c of the
  harness TEA migration; `Raxol.Harness.PumpContract` §3 names this the
  "transport seam ... deliberately NOT frozen"). One job: every term the
  pump sends is cast into the Dispatcher through the right ingress —

    * `%Event{type: :resize}` rides `{:dispatch, event}` (the generic
      clause, into the system-event path): the Rendering Engine's size
      sync lives there, so resize must NOT use the verbatim seam — the
      one delivery exception PumpContract §3 freezes;
    * every other term rides `{:dispatch, {:harness, term}}` (unit U6-a):
      the verbatim ingress that reaches `HarnessApp.update/2` unwrapped.

  Ordering (PumpContract §2's end-to-end claim): the shim is the pump's
  SOLE downstream sender, casts between one sender pair are FIFO, and
  the Dispatcher's mailbox preserves that order — so the input-first
  order the pump establishes in its own selective receive survives
  end-to-end.

  A plain linked loop process, not a GenServer: it never replies, holds
  nothing but the dispatcher pid, and never filters a term it does not
  recognize — an unknown term still rides the `{:harness, _}` seam,
  because the loud-loss law lives in `update/2`'s fold (PumpContract §5),
  not here. It dies by link with the pump that spawned it.
  """

  alias Raxol.Core.Events.Event

  @doc "Starts the shim, linked to the caller (the pump). Messages are cast to `dispatcher_pid`."
  @spec start_link(pid()) :: {:ok, pid()}
  def start_link(dispatcher_pid) when is_pid(dispatcher_pid) do
    {:ok, spawn_link(__MODULE__, :run, [dispatcher_pid])}
  end

  @doc "The receive loop: one term in, one cast out, forever."
  @spec run(pid()) :: no_return()
  def run(dispatcher_pid) do
    receive do
      %Event{type: :resize} = event ->
        GenServer.cast(dispatcher_pid, {:dispatch, event})

      term ->
        GenServer.cast(dispatcher_pid, {:dispatch, {:harness, term}})
    end

    run(dispatcher_pid)
  end
end
