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

  # A stand-in for a live `Raxol.AgentClientProtocol.Session` (this package does
  # not depend on the ACP package): it answers the shared `{:steer, payload}`
  # call with a configured CAS reply and echoes the received payload to a sink.
  defmodule FakeAcpSession do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts),
      do: {:ok, %{reply: Keyword.fetch!(opts, :reply), sink: Keyword.get(opts, :sink)}}

    @impl true
    def handle_call({:steer, payload}, _from, state) do
      if state.sink, do: send(state.sink, {:acp_steer_received, payload})
      {:reply, state.reply, state}
    end
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})

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

      assert_receive {:harness_command, {:interrupt, ^session_id, %{turn_id: "turn-7"}}}
    end

    test "an empty payload dispatches an empty interrupt payload" do
      session_id = unique_session_id("lane-interrupt-empty")
      session = %{session_id: session_id, pid: self()}

      assert :ok = SessionLane.interrupt(session, %{})

      assert_receive {:harness_command, {:interrupt, ^session_id, %{}}}
    end
  end

  describe "submit/2" do
    test "reaches the session pid as {:harness_command, {:start_turn, sid, %{text: ...}}}" do
      session_id = unique_session_id("lane-submit")
      session = %{session_id: session_id, pid: self()}

      assert :ok = SessionLane.submit(session, %{text: "run the tests"})

      assert_receive {:harness_command, {:start_turn, ^session_id, %{text: "run the tests"}}}
    end

    test "an empty text is rejected loudly by the codec -- nothing is routed" do
      session_id = unique_session_id("lane-submit-empty")
      session = %{session_id: session_id, pid: self()}

      assert {:error, _reason} = SessionLane.submit(session, %{text: ""})

      refute_receive {:harness_command, _}, 50
    end

    test "a request without a binary :text is refused with {:error, :invalid_request}" do
      session = %{session_id: unique_session_id("lane-submit-bad"), pid: self()}

      assert {:error, :invalid_request} = SessionLane.submit(session, %{})
      assert {:error, :invalid_request} = SessionLane.submit(session, %{text: 42})

      refute_receive {:harness_command, _}, 50
    end
  end

  describe "steer/2 — legacy (non-ACP) path" do
    test "with no :acp_session the honest {:error, :no_steer_channel} refusal STANDS" do
      session = %{session_id: unique_session_id("lane-steer")}

      assert {:error, :no_steer_channel} =
               SessionLane.steer(session, %{
                 text: "go left instead",
                 expected_turn_id: "turn-1"
               })
    end

    test "a session carrying a non-pid :acp_session is still legacy (refusal)" do
      session = %{session_id: unique_session_id("lane-steer"), acp_session: :not_a_pid}

      assert {:error, :no_steer_channel} =
               SessionLane.steer(session, %{text: "x", expected_turn_id: "turn-1"})
    end
  end

  describe "steer/2 — ACP-backed path (Track E / U6-I)" do
    test "dispatches the validated CAS payload to the ACP Session and returns its reply verbatim" do
      accepted = {:ok, {:accepted, %{turn_id: "turn-1", offset: 1, client_msg_id: "m1"}}}
      {:ok, fake} = FakeAcpSession.start_link(reply: accepted, sink: self())

      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert ^accepted =
               SessionLane.steer(session, %{
                 text: "go left instead",
                 expected_turn_id: "turn-1",
                 client_msg_id: "m1"
               })

      # The ACP Session received the CAS payload with all three fields.
      assert_receive {:acp_steer_received,
                      %{text: "go left instead", expected_turn_id: "turn-1", client_msg_id: "m1"}}
    end

    test "an omitted client_msg_id is defaulted to nil before dispatch" do
      {:ok, fake} = FakeAcpSession.start_link(reply: {:error, :no_live_turn}, sink: self())
      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert {:error, :no_live_turn} =
               SessionLane.steer(session, %{text: "hi", expected_turn_id: "turn-1"})

      assert_receive {:acp_steer_received, %{client_msg_id: nil}}
    end

    test "a stale-turn CAS rejection flows back verbatim" do
      stale = {:error, {:stale_turn, "turn-1", "turn-2"}}
      {:ok, fake} = FakeAcpSession.start_link(reply: stale, sink: self())
      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert ^stale =
               SessionLane.steer(session, %{text: "late", expected_turn_id: "turn-1"})
    end

    test "empty text is rejected by the validation seam and never reaches the Session" do
      {:ok, fake} = FakeAcpSession.start_link(reply: {:ok, :unreachable}, sink: self())
      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert {:error, {:invalid_command, :empty_text}} =
               SessionLane.steer(session, %{text: "   ", expected_turn_id: "turn-1"})

      refute_receive {:acp_steer_received, _}
    end

    test "a missing expected_turn_id is rejected by the validation seam" do
      {:ok, fake} = FakeAcpSession.start_link(reply: {:ok, :unreachable}, sink: self())
      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert {:error, {:invalid_command, :missing_expected_turn_id}} =
               SessionLane.steer(session, %{text: "go left"})

      refute_receive {:acp_steer_received, _}
    end

    test "a dead ACP Session translates to a typed {:error, :no_session}, never a hung caller" do
      {:ok, fake} = FakeAcpSession.start_link(reply: {:ok, :whatever})
      ref = Process.monitor(fake)
      GenServer.stop(fake)
      assert_receive {:DOWN, ^ref, :process, ^fake, _}

      session = %{session_id: unique_session_id("lane-steer-acp"), acp_session: fake}

      assert {:error, :no_session} =
               SessionLane.steer(session, %{text: "x", expected_turn_id: "turn-1"})
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
