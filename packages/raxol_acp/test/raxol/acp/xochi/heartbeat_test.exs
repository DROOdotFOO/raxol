defmodule Raxol.ACP.Xochi.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.Heartbeat

  @event [:raxol, :acp, :xochi, :solver, :heartbeat]

  test "emits a heartbeat telemetry event with monotonic tick + uptime when driven" do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @event,
      fn @event, measurements, _meta, test_pid -> send(test_pid, {:heartbeat, measurements}) end,
      self()
    )

    # Long interval so the process's own timer never fires during the test; we drive the
    # tick deterministically by sending :heartbeat ourselves (no sleeps, no flakiness).
    {:ok, pid} =
      Heartbeat.start_link(
        interval_ms: 60_000,
        name: :"heartbeat_#{System.unique_integer([:positive])}"
      )

    send(pid, :heartbeat)
    assert_receive {:heartbeat, %{ticks: 1, uptime_ms: uptime}}
    assert is_integer(uptime) and uptime >= 0

    send(pid, :heartbeat)
    assert_receive {:heartbeat, %{ticks: 2}}

    :telemetry.detach(handler_id)
    GenServer.stop(pid)
  end
end
