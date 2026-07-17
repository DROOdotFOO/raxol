defmodule Raxol.Agent.Harness.LiveSessionAgentTest do
  @moduledoc """
  Agent-package integration tests for `Raxol.Harness.LiveSessionDriver`
  (main `raxol` package): the seams the main-package fake lane in
  `test/harness/live_session_driver_test.exs` cannot exercise, because
  `raxol_agent`'s real pieces aren't available there.

    a. interrupt dispatch reaches a REAL staged supervised kill
       (`Raxol.Agent.Interrupt.interrupt/3`) through the real
       `Raxol.Agent.Command.decode/1` + `route/2` codec.
    b. steer resolves through the REAL CAS decision core
       (`Raxol.Agent.Steer.resolve/2`), both accept and stale-turn arms.
    c. KEYSTONE (`@tag :integration`): the real event path end-to-end --
       a real `Raxol.Agent.SessionStreamer`, a real
       `Raxol.Agent.Harness.SessionLane`, and a real
       `Raxol.Agent.Contract.pump/3` over `Raxol.Agent.Stream.run/2`
       (Mock backend) -- no fakes on the event side at all.

  Nothing in `packages/raxol_agent` auto-starts in `:test` env (mirrors
  `session_lane_test.exs`'s own note): every test brings up
  `Raxol.Agent.SessionStreamer` itself via `start_supervised!` under its
  real registered name, which is why this file runs `async: false`.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Harness.SessionLane, as: RealLane
  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.Steer
  alias Raxol.Core.Events.Event
  alias Raxol.Harness.LiveSessionDriver

  @width 60
  @rows 20
  @footer_rows 6

  setup do
    start_supervised!(SessionStreamer)
    :ok
  end

  defp unique_session_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive])}"

  # -- shared helpers --------------------------------------------------

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # `Raxol.Test.CrossTerminal.SequenceScanner` lives in the main `raxol`
  # package's `test/support` (not compiled into this dependency's app), so
  # this package uses a self-contained regex strip instead -- good enough
  # for the plain-text substring assertions this file makes (CSI sequences
  # and DECSC/DECRC bracket the content, nothing more exotic).
  defp strip_ansi(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\e[78]/, "")
  end

  defp eventually(fun, timeout \\ 2_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        ExUnit.Assertions.flunk("condition not met within polling budget")
      else
        Process.sleep(interval)
        do_eventually(fun, deadline, interval)
      end
    end
  end

  defp start_driver(lane_mod, session, driver_overrides \\ []) do
    {:ok, device} = StringIO.open("")
    test_pid = self()

    base_opts = [
      lane: {lane_mod, session},
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log,
      cadence_opts: [flush_interval_ms: 0],
      notify: test_pid
    ]

    {:ok, driver} =
      LiveSessionDriver.start_link(Keyword.merge(base_opts, driver_overrides))

    on_exit(fn -> LiveSessionDriver.halt(driver) end)
    {driver, device}
  end

  # A minimal contract-shaped event (atom top-level fields, matching
  # `Raxol.Agent.Contract.Event`'s own struct shape) -- built by hand here
  # rather than requiring a real turn to have run, since these tests only
  # need the driver's `current_turn_id` bookkeeping seeded.
  defp turn_started_event(session_id, turn_id) do
    %Contract.Event{
      id: System.unique_integer([:positive, :monotonic]),
      session_id: session_id,
      turn_id: turn_id,
      ts: System.system_time(:microsecond),
      family: :loop,
      type: :turn_started,
      tier: :durable,
      payload: %{prompt: "hi"}
    }
  end

  # ---------------------------------------------------------------------
  # a. interrupt dispatch reaches a real staged supervised kill
  # ---------------------------------------------------------------------

  defmodule FakeSessionA do
    @moduledoc """
    A fake session process that, on receiving the REAL routed
    `{:harness_command, {:interrupt, sid, payload}}` message (delivered by
    `Raxol.Agent.Command.route/2` through the real `SessionLane.interrupt/2`
    codec), runs the REAL `Raxol.Agent.Interrupt.interrupt/3` staged
    supervised kill -- tool-less (`port: nil, os_pid: nil`, matching a
    mid-provider-stream interrupt with nothing to signal). The sink both
    emits each staged event onto the real `SessionStreamer` (contract-
    shaped, so the driver's forwarder observes it exactly like production)
    AND appends the stage to the test-owned collector Agent for the
    journal-shape assertion.
    """

    use GenServer

    alias Raxol.Agent.Contract
    alias Raxol.Agent.SessionStreamer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_info({:harness_command, {:interrupt, _sid, payload}}, state) do
      sink = fn stage, stage_payload ->
        event = %Contract.Event{
          id: System.unique_integer([:positive, :monotonic]),
          session_id: state.session_id,
          turn_id: Map.get(payload, :turn_id),
          ts: System.system_time(:microsecond),
          family: :loop,
          type: stage,
          tier: :durable,
          payload: stage_payload
        }

        SessionStreamer.emit(state.session_id, event)
        Agent.update(state.collector, &(&1 ++ [stage]))
        :ok
      end

      tool_ref = %{
        turn_id: Map.get(payload, :turn_id) || "turn-x",
        port: nil,
        os_pid: nil
      }

      {:ok, _outcome} = Interrupt.interrupt(tool_ref, sink)

      {:noreply, state}
    end

    def handle_info(_other, state), do: {:noreply, state}
  end

  defmodule ThinLaneA do
    @moduledoc """
    Wraps the REAL `Raxol.Agent.Harness.SessionLane.subscribe/1` (real
    `SessionStreamer.subscribe/1`) and `.interrupt/2` (real
    `Command.decode/1` + `route/2` codec+route path) -- only `monitor/1` is
    reimplemented, since `FakeSessionA` is not a `Raxol.Agent.Session`.
    """

    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(session), do: RealLane.subscribe(session)

    @impl true
    def interrupt(session, payload), do: RealLane.interrupt(session, payload)

    @impl true
    def submit(session, request), do: RealLane.submit(session, request)

    @impl true
    def steer(_session, _request), do: {:error, :no_steer_channel}

    @impl true
    def answer_permission(session, answer),
      do: RealLane.answer_permission(session, answer)

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  describe "a. interrupt dispatch reaches a real staged supervised kill" do
    test "the tool-less bookkeeping sequence runs and the driver renders the observed acks" do
      session_id = unique_session_id("live-interrupt")
      {:ok, collector} = Agent.start_link(fn -> [] end)

      {:ok, fake_pid} =
        FakeSessionA.start_link(session_id: session_id, collector: collector)

      session = %{session_id: session_id, pid: fake_pid}
      {driver, device} = start_driver(ThinLaneA, session)

      # Wait for the forwarder's REAL subscribe/1 call to land before
      # dispatching ESC, so the staged events are not emitted to zero
      # subscribers.
      eventually(fn -> session_id in SessionStreamer.list_sessions() end)

      send(driver, {:inline_input, Event.key(:escape)})

      eventually(fn ->
        Agent.get(collector, & &1) ==
          [
            :interrupt_signaled,
            :interrupt_waited,
            :interrupt_killed,
            :turn_canceled
          ]
      end)

      eventually(fn -> strip_ansi(raw(device)) =~ "turn canceled" end)
    end
  end

  # ---------------------------------------------------------------------
  # b. steer resolves through the real CAS decision core
  # ---------------------------------------------------------------------

  defmodule FakeSessionB do
    @moduledoc """
    Holds a real `%Raxol.Agent.Steer.TurnState{}` and resolves every steer
    request via the REAL `Raxol.Agent.Steer.resolve/2` inside `handle_call`
    -- the single-writer seam `Steer`'s own moduledoc demands (one owner
    process, one mailbox-serialized read-modify-write per decision).
    """

    use GenServer

    alias Raxol.Agent.Contract
    alias Raxol.Agent.SessionStreamer
    alias Raxol.Agent.Steer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         session_id: opts[:session_id],
         turn_state: %Steer.TurnState{turn_id: opts[:turn_id]}
       }}
    end

    @impl true
    def handle_call({:steer, request}, _from, state) do
      steer_request = struct(Steer.Request, request)
      {result, next_state} = Steer.resolve(state.turn_state, steer_request)

      case result do
        {:ok, {:accepted, _ref}} ->
          [durable_event | _rest] = next_state.log
          emit_durable_steer(state.session_id, durable_event)

        _other ->
          :ok
      end

      {:reply, result, %{state | turn_state: next_state}}
    end

    defp emit_durable_steer(session_id, durable_event) do
      event = %Contract.Event{
        id: System.unique_integer([:positive, :monotonic]),
        session_id: session_id,
        turn_id: Map.get(durable_event, :turn_id),
        ts: System.system_time(:microsecond),
        family: :loop,
        type: :steer,
        tier: :durable,
        payload: Map.get(durable_event, :payload, %{})
      }

      SessionStreamer.emit(session_id, event)
    end
  end

  defmodule ThinLaneB do
    @moduledoc """
    Real `subscribe/1`, steer dispatched via `GenServer.call/2` straight to
    `FakeSessionB` (the real decision core lives there, not behind
    `Raxol.Agent.Harness.SessionLane.steer/2`, which unconditionally
    refuses -- see that module's own moduledoc).
    """

    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(session), do: RealLane.subscribe(session)

    @impl true
    def interrupt(_session, _payload), do: {:error, :not_used_in_this_test}

    @impl true
    def submit(_session, _request), do: {:error, :not_used_in_this_test}

    @impl true
    def steer(%{pid: pid}, request), do: GenServer.call(pid, {:steer, request})

    @impl true
    def answer_permission(_session, _answer),
      do: {:error, :not_used_in_this_test}

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  describe "b. steer resolves through the real CAS decision core" do
    test "accept: the driver footer confirms and the durable steer event reaches the transcript" do
      session_id = unique_session_id("live-steer-accept")

      {:ok, fake_pid} =
        FakeSessionB.start_link(session_id: session_id, turn_id: "turn-1")

      session = %{session_id: session_id, pid: fake_pid}
      {driver, device} = start_driver(ThinLaneB, session)

      eventually(fn -> session_id in SessionStreamer.list_sessions() end)

      SessionStreamer.emit(session_id, turn_started_event(session_id, "turn-1"))
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      send(driver, {:inline_input, Event.key("h")})
      send(driver, {:inline_input, Event.key(:tab)})

      eventually(fn -> strip_ansi(raw(device)) =~ "steer accepted" end)
    end

    test "stale: a driver-observed turn id that no longer matches the fake's real state renders the honest rejection" do
      session_id = unique_session_id("live-steer-stale")

      # The fake's real TurnState is already on "turn-2"; the driver will
      # believe "turn-1" is running (from the turn_started event below),
      # so resolve/2's own CAS check rejects it -- no test-side stubbing,
      # this is the real decision core disagreeing with a stale caller.
      {:ok, fake_pid} =
        FakeSessionB.start_link(session_id: session_id, turn_id: "turn-2")

      session = %{session_id: session_id, pid: fake_pid}
      {driver, device} = start_driver(ThinLaneB, session)

      eventually(fn -> session_id in SessionStreamer.list_sessions() end)

      SessionStreamer.emit(session_id, turn_started_event(session_id, "turn-1"))
      eventually(fn -> strip_ansi(raw(device)) =~ "turn_started" end)

      send(driver, {:inline_input, Event.key("h")})
      send(driver, {:inline_input, Event.key(:tab)})

      eventually(fn -> strip_ansi(raw(device)) =~ "NOT delivered" end)

      plain = strip_ansi(raw(device))
      assert plain =~ "turn-1"
      assert plain =~ "turn-2"
    end
  end

  # ---------------------------------------------------------------------
  # c. KEYSTONE -- the real event path end-to-end, no fakes on the event side
  # ---------------------------------------------------------------------

  describe "c. the real event path end-to-end" do
    @tag :integration
    test "a real SessionStreamer + SessionLane + Contract.pump over a Mock stream reaches sealed history" do
      session_id = unique_session_id("live-keystone")
      session = %{session_id: session_id}

      {driver, device} = start_driver(RealLane, session)

      eventually(fn -> session_id in SessionStreamer.list_sessions() end)

      stream =
        Raxol.Agent.Stream.run("hello",
          backend: Raxol.Agent.Backend.Mock,
          backend_opts: [response: "the mock answer"]
        )

      assert {:ok, %{content: content}} =
               Contract.pump(session_id, stream, prompt: "hello")

      assert content =~ "the mock answer"

      eventually(fn -> strip_ansi(raw(device)) =~ "the mock answer" end)

      # The pump run closing (`final: true`) is a TURN boundary, not a
      # session boundary: a multi-turn conversation pumps one run per
      # prompt on the same session id, so the driver must not claim the
      # session is over -- the stream stays open for the next turn.
      refute strip_ansi(raw(device)) =~ "session ended"

      # Interrupt against this real stack: SessionLane.interrupt/2 decodes
      # and routes, but this session carries no :pid, so nothing ever
      # picks the routed command up. The driver must show the honest
      # PENDING state and never fabricate an ack -- no shipped runtime
      # handles the routed command yet.
      send(driver, {:inline_input, Event.key(:escape)})
      eventually(fn -> strip_ansi(raw(device)) =~ "interrupt sent" end)

      refute strip_ansi(raw(device)) =~ "turn canceled"
      refute strip_ansi(raw(device)) =~ "interrupt signaled"
    end
  end
end
