defmodule Raxol.Earn.Xochi.Heartbeat do
  @moduledoc """
  Periodic liveness signal for the Xochi storefront solver.

  The solver is an outbound SSE client with NO inbound port, so a silently-stalled
  stream (expired auth, half-open socket) neither crashes nor is reschedulable by a fly
  health check, and an idle-but-alive node looks identical to a wedged one. This
  GenServer emits a heartbeat on a fixed interval regardless of job flow:

    * a `Logger.info("xochi solver heartbeat", ...)` line, and
    * a `[:raxol, :earn, :xochi, :solver, :heartbeat]` telemetry event
      (measurements: `%{ticks, uptime_ms}`).

  External monitoring should alert when the heartbeat goes stale (no log/metric within a
  few intervals) and restart the machine. Started last in
  `Raxol.Earn.Xochi.SolverApplication`'s tree so a heartbeat crash restarts nothing above
  it under `:rest_for_one`.
  """

  use GenServer

  require Logger

  @telemetry_event [:raxol, :earn, :xochi, :solver, :heartbeat]
  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      ticks: 0,
      started_at: System.monotonic_time(:millisecond)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    ticks = state.ticks + 1
    uptime_ms = System.monotonic_time(:millisecond) - state.started_at

    :telemetry.execute(@telemetry_event, %{ticks: ticks, uptime_ms: uptime_ms}, %{})
    Logger.info("xochi solver heartbeat", ticks: ticks, uptime_ms: uptime_ms)

    {:noreply, schedule(%{state | ticks: ticks})}
  end

  defp schedule(state) do
    Process.send_after(self(), :heartbeat, state.interval_ms)
    state
  end
end
