defmodule Raxol.Agent.Harness.SessionLaneTest do
  @moduledoc """
  `Raxol.Agent.Harness.SessionLane` — the agent-side implementation of
  `Raxol.Harness.SessionLane` (main `raxol` package).

  Nothing in `packages/raxol_agent` auto-starts in `:test` env (see
  `mix.exs`: `:mod` is only set outside `:test`) -- every test that needs
  `Raxol.Agent.Registry` / `Raxol.Agent.DynSup` / `Raxol.Agent.SessionStreamer`
  brings them up itself via `start_supervised!` under their real registered
  names (mirroring `session_supervisor_test.exs`'s own setup), which is why
  this file runs `async: false`: two test files both claiming the same
  global names concurrently would collide.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Harness.SessionLane
  alias Raxol.Agent.SessionStreamer

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    start_supervised!(
      {DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one}
    )

    start_supervised!(Raxol.Agent.SessionStreamer)
    :ok
  end

  defp unique_session_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "subscribe/1" do
    test "delivers a pumped event to the calling process" do
      session_id = unique_session_id("lane-subscribe")

      assert :ok = SessionLane.subscribe(%{session_id: session_id})

      event = %{family: :loop, type: :item_delta, payload: %{chunk: "hi"}}
      SessionStreamer.emit(session_id, event)

      assert_receive {:session_event, ^session_id, ^event}
    end
  end

  describe "interrupt/2" do
    test "reaches the session pid as {:harness_command, {:interrupt, sid, %{turn_id: ...}}}" do
      session_id = unique_session_id("lane-interrupt")
      session = %{session_id: session_id, pid: self()}

      assert :ok = SessionLane.interrupt(session, %{turn_id: "turn-7"})

      assert_receive {:harness_command,
                      {:interrupt, ^session_id, %{turn_id: "turn-7"}}}
    end

    test "an empty payload dispatches an empty interrupt payload" do
      session_id = unique_session_id("lane-interrupt-empty")
      session = %{session_id: session_id, pid: self()}

      assert :ok = SessionLane.interrupt(session, %{})

      assert_receive {:harness_command, {:interrupt, ^session_id, %{}}}
    end
  end

  describe "steer/2" do
    test "always returns {:error, :no_steer_channel} -- honest, no shipped runtime owns the CAS" do
      session = %{session_id: unique_session_id("lane-steer")}

      assert {:error, :no_steer_channel} =
               SessionLane.steer(session, %{
                 text: "go left instead",
                 expected_turn_id: "turn-1"
               })
    end
  end

  describe "monitor/1" do
    test "returns a reference for a pid-carrying session" do
      session = %{session_id: unique_session_id("lane-monitor"), pid: self()}
      ref = SessionLane.monitor(session)

      assert is_reference(ref)
    end

    test "returns nil for a session with no pid" do
      session = %{session_id: unique_session_id("lane-monitor-nopid")}
      assert nil == SessionLane.monitor(session)
    end
  end

  describe "resolve/1" do
    test "returns nil for a session_id with no live process registered" do
      assert nil == SessionLane.resolve(unique_session_id("lane-resolve-none"))
    end

    test "returns a session map when a process is registered under {:session, id}" do
      session_id = unique_session_id("lane-resolve-live")

      {:ok, _owner} =
        Registry.register(Raxol.Agent.Registry, {:session, session_id}, nil)

      assert %{session_id: ^session_id, pid: pid} =
               SessionLane.resolve(session_id)

      assert pid == self()
    end
  end

  test "implements the Raxol.Harness.SessionLane behaviour" do
    assert Raxol.Harness.SessionLane in (SessionLane.__info__(:attributes)
                                         |> Keyword.get_values(:behaviour)
                                         |> List.flatten())
  end
end
