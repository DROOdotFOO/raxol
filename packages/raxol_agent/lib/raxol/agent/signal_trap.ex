defmodule Raxol.Agent.SignalTrap do
  @moduledoc """
  Forward OS signals to a process instead of the BEAM default.

  The default `erl_signal_server` handler turns SIGTERM into `init:stop/0`
  -- a graceful shutdown with exit code 0 and no chance to flush anything.
  For `raxol.p` that means a harness that SIGTERMs a run on timeout reads
  the kill as success. Installing this handler routes the signal to the
  consuming process as `{:os_signal, :sigterm}` so it can emit a final
  event, write the trajectory, and exit 143.

  Install with `install/1`; the handler swaps in beside the default one
  (`:gen_event.add_handler/3` on `:erl_signal_server`) and
  `:os.set_signal(:sigterm, :handle)` claims the signal.
  """

  @behaviour :gen_event

  @doc "Route SIGTERM to `pid` as `{:os_signal, :sigterm}`."
  @spec install(pid()) :: :ok | {:error, term()}
  def install(pid) when is_pid(pid) do
    with :ok <- :gen_event.add_handler(:erl_signal_server, __MODULE__, pid) do
      :os.set_signal(:sigterm, :handle)
    end
  end

  @impl :gen_event
  def init(pid), do: {:ok, pid}

  @impl :gen_event
  def handle_event(:sigterm, pid) do
    send(pid, {:os_signal, :sigterm})
    {:ok, pid}
  end

  def handle_event(_signal, pid), do: {:ok, pid}

  @impl :gen_event
  def handle_call(_request, pid), do: {:ok, :ok, pid}
end
