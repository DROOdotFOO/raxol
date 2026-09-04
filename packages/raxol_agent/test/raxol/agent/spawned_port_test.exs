defmodule Raxol.Agent.SpawnedPortTest do
  @moduledoc """
  Contract for the shared close path. Every spawner that kills on a deadline
  reaches `close/1` with a port that has usually already died, so both the
  guard and the drain are load-bearing rather than defensive.
  """

  use ExUnit.Case, async: true

  @moduletag :unix_only

  alias Raxol.Agent.SpawnedPort

  defp spawn_sh(command) do
    Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :in, :exit_status, {:args, ["-c", command]}]
    )
  end

  test "closing a live port returns :ok" do
    assert :ok = SpawnedPort.close(spawn_sh("sleep 5"))
  end

  test "closing a port that already exited does not raise" do
    port = spawn_sh("exit 3")

    # Consume the status so the port is provably gone before the close --
    # `Port.close/1` raises on a dead port, which is what the guard exists for.
    assert_receive {^port, {:exit_status, 3}}, 5_000

    assert :ok = SpawnedPort.close(port)
  end

  test "an exit status queued before the close is drained, not left behind" do
    port = spawn_sh("exit 0")

    # Wait for the port to die on its own without consuming its message, so
    # `close/1` meets exactly the state a killed process leaves behind.
    wait_until_dead(port)

    assert :ok = SpawnedPort.close(port)
    refute_received {^port, {:exit_status, _}}
  end

  defp wait_until_dead(port, budget_ms \\ 3_000)

  defp wait_until_dead(port, budget_ms) when budget_ms <= 0,
    do: flunk("port #{inspect(port)} never exited")

  defp wait_until_dead(port, budget_ms) do
    if Port.info(port) do
      Process.sleep(25)
      wait_until_dead(port, budget_ms - 25)
    else
      :ok
    end
  end
end
