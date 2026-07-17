defmodule Raxol.Harness.LiveSessionDriverCompactionTest do
  @moduledoc """
  The multi-turn live/fixture BYTE-parity guard for turn-granularity
  compaction (`Raxol.Harness.Surface.compact_sealed_turns/1`) — the gate
  the live-session driver's growth fix is required to sit behind.

  ## Doc guarantee -> test mapping

    1. THE GUARD: N generated multi-turn sessions driven through the
       compacted-live path (append -> advance -> flush_held -> compact on
       every bracket, exactly the driver's own sequence) and through the
       uncompacted-fixture path render **byte-identical sealed history**
       under the emulator oracle (`SealOracle.replay/2` + `history/2` —
       cell-exact, not stripped text) ->
       "compacted-live and uncompacted-fixture sealed history are byte-identical"
    2. Compaction actually engages (the guard cannot be satisfied by a
       veto-everything no-op) and retention is O(newest turn), not
       O(session) -> "compaction engages and retention is bounded by the newest turn"
    3. A surviving `refs` citation into the candidate region vetoes the
       drop — an evidence ref is never left dangling ->
       "a cross-turn evidence ref vetoes compaction"
    4. A damaged projection (interior id gap) never compacts ->
       "a damaged projection never compacts"
    5. The driver itself runs the compaction at its turn brackets
       (activation, observed via the debug state probe) ->
       "the driver compacts retired turns out of the live event list"
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.EventBoundary
  alias Raxol.Harness.LiveSessionDriver
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle

  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # How many generated sessions the parity guard sweeps. Each is seeded
  # deterministically — a failure names its seed, so any red reproduces.
  @sessions 8

  # -- generated multi-turn sessions (contract shape -> boundary shape) ---

  # A deterministic multi-turn session: `turns` turns, each with a
  # turn_started bracket, streaming deltas (ephemeral), an optional
  # tool_use/tool_result pair, a completed message item, and a
  # turn_completed bracket (final on the last turn). Ids are dense and
  # session-scoped, mirroring the journal id authority.
  defp gen_session(seed) do
    state = :rand.seed_s(:exsss, {seed, 1729, 42})
    {turns, state} = uniform_s(3, state)
    turns = turns + 2

    {events, _id, _state} =
      Enum.reduce(1..turns, {[], 0, state}, fn t, {acc, id, state} ->
        {turn_events, id, state} = gen_turn(t, t == turns, id, state)
        {acc ++ turn_events, id, state}
      end)

    Enum.map(events, &normalize!/1)
  end

  defp gen_turn(t, final?, id, state) do
    turn_id = "turn-#{t}"
    {delta_count, state} = uniform_s(2, state)
    {with_tool, state} = uniform_s(2, state)

    started = [
      event(id + 1, turn_id, :turn_started, :durable, %{prompt: "prompt #{t}"})
    ]

    id = id + 1

    {deltas, id} =
      Enum.map_reduce(1..delta_count, id, fn d, id ->
        {event(id + 1, turn_id, :item_delta, :ephemeral, %{
           chunk: "chunk #{t}.#{d}"
         }), id + 1}
      end)

    {tools, id} =
      if with_tool == 1 do
        {[
           event(id + 1, turn_id, :item_completed, :durable, %{
             item_id: "#{turn_id}-tool",
             item_type: :tool_use,
             name: "grep",
             arguments: %{pattern: "t#{t}"},
             call_id: "call-#{t}"
           }),
           event(id + 2, turn_id, :item_completed, :durable, %{
             item_id: "#{turn_id}-tool",
             item_type: :tool_result,
             name: "grep",
             result: "match #{t}"
           })
         ], id + 2}
      else
        {[], id}
      end

    message =
      event(id + 1, turn_id, :item_completed, :durable, %{
        item_id: "#{turn_id}-msg",
        item_type: :message,
        content: "turn #{t} landed its message"
      })

    bracket =
      event(id + 2, turn_id, :turn_completed, :durable, %{
        iteration: t,
        usage: %{},
        cost: 0.0,
        final: final?
      })

    {started ++ deltas ++ tools ++ [message, bracket], id + 2, state}
  end

  defp uniform_s(n, state) do
    {value, state} = :rand.uniform_s(n, state)
    {value, state}
  end

  defp event(id, turn_id, type, tier, payload) do
    %{
      id: id,
      turn_id: turn_id,
      ts: id * 1_000,
      family: :loop,
      type: type,
      tier: tier,
      payload: payload
    }
  end

  defp normalize!(contract_event) do
    {:ok, map} = EventBoundary.normalize(contract_event)
    map
  end

  # -- the two paths -------------------------------------------------------

  defp surface_opts(device, extra) do
    [
      device: device,
      width: @width,
      rows: @rows,
      footer_rows: @footer_rows,
      mode: :inline_log
    ] ++ extra
  end

  # The compacted-live path: one event per append/advance, the per-turn
  # hold released and compaction run at every turn bracket — the exact
  # sequence `LiveSessionDriver.apply_lifecycle/2` performs.
  defp run_live_compacted(events) do
    {:ok, device} = StringIO.open("")
    model = Surface.new([], surface_opts(device, stream_open: true))

    model =
      Enum.reduce(events, model, fn ev, model ->
        model = Surface.append_events(model, [ev])
        {model, _status} = Surface.advance(model)

        case ev.type do
          bracket when bracket in [:turn_completed, :turn_canceled] ->
            model
            |> Surface.flush_held()
            |> Surface.compact_sealed_turns()

          _other ->
            model
        end
      end)

    model = Surface.close_stream(model)
    {model, raw(device)}
  end

  # The uncompacted-fixture path: the whole event list up front, no
  # stream hold, driven to :done — the shipped fixture replay.
  defp run_fixture(events) do
    {:ok, device} = StringIO.open("")
    model = Surface.new(events, surface_opts(device, []))
    model = drive_to_completion(model)
    {model, raw(device)}
  end

  defp drive_to_completion(model) do
    case Surface.advance(model) do
      {model, :done} -> model
      {model, :ok} -> drive_to_completion(model)
    end
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # The emulator oracle: replay the raw byte stream through the real
  # terminal emulator and read back the terminal-owned sealed history
  # (scrollback + rows above the footer region) as rows of Cells —
  # cell-exact, independent of how the bytes were produced.
  defp sealed_history(raw) do
    raw
    |> SealOracle.replay(width: @width, height: @rows)
    |> SealOracle.history(@region_top)
  end

  defp retained_loop_turn_ids(model) do
    model.events
    |> Enum.filter(&(&1.family == :loop))
    |> Enum.map(& &1.turn_id)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------
  # 1. THE GUARD — multi-turn live/fixture byte parity
  # ---------------------------------------------------------------------

  test "compacted-live and uncompacted-fixture sealed history are byte-identical" do
    for seed <- 1..@sessions do
      events = gen_session(seed)

      {_live_model, live_raw} = run_live_compacted(events)
      {_fixture_model, fixture_raw} = run_fixture(events)

      live_history = sealed_history(live_raw)
      fixture_history = sealed_history(fixture_raw)

      assert live_history == fixture_history,
             "sealed history diverged for generated session seed=#{seed} " <>
               "(live #{length(live_history)} rows, fixture #{length(fixture_history)} rows)"

      # And the live path's own history was never rewritten: the fixture
      # history must be reachable from the live one as an exact prefix
      # relation (identical lists trivially satisfy it; this pins the
      # oracle's cell-exact comparison as the arbiter).
      assert SealOracle.immutable_prefix?(live_history, fixture_history) == :ok
    end
  end

  # ---------------------------------------------------------------------
  # 2. compaction engages, retention bounded
  # ---------------------------------------------------------------------

  test "compaction engages and retention is bounded by the newest turn" do
    # 30 turns — deep enough that an O(session) retention is unmissable.
    events =
      1..30
      |> Enum.flat_map(fn t ->
        {turn_events, _id, _state} =
          gen_turn(t, t == 30, (t - 1) * 10, :rand.seed_s(:exsss, {t, 2, 3}))

        turn_events
      end)
      |> reindex_dense()
      |> Enum.map(&normalize!/1)

    {live_model, _raw} = run_live_compacted(events)

    # The guard against a veto-everything no-op: events were actually shed.
    assert length(live_model.events) < length(events)

    # Retention rule: after the final bracket compacts, only the newest
    # bracket-carrying turn's events remain — O(newest turn), independent
    # of the 30-turn session length.
    assert retained_loop_turn_ids(live_model) == ["turn-30"]
  end

  defp reindex_dense(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {ev, id} -> %{ev | id: id, ts: id * 1_000} end)
  end

  # ---------------------------------------------------------------------
  # 3. refs veto
  # ---------------------------------------------------------------------

  test "a cross-turn evidence ref vetoes compaction" do
    {t1, id, state} = gen_turn(1, false, 0, :rand.seed_s(:exsss, {7, 7, 7}))
    {t2, _id, _state} = gen_turn(2, true, id, state)

    # Forge turn 2's bracket to cite a turn-1 event id as evidence.
    t1_id = hd(t1).id

    t2 =
      Enum.map(t2, fn
        %{type: :turn_completed} = ev ->
          %{ev | payload: Map.put(ev.payload, :refs, [t1_id])}

        ev ->
          ev
      end)

    events = Enum.map(t1 ++ t2, &normalize!/1)
    {live_model, live_raw} = run_live_compacted(events)

    # The cited turn's events must survive — the drop was vetoed.
    assert "turn-1" in retained_loop_turn_ids(live_model)

    # And the veto path still renders byte-identically to the fixture.
    {_fixture_model, fixture_raw} = run_fixture(events)
    assert sealed_history(live_raw) == sealed_history(fixture_raw)
  end

  # ---------------------------------------------------------------------
  # 4. damaged projection veto
  # ---------------------------------------------------------------------

  test "a damaged projection never compacts" do
    {t1, id, state} = gen_turn(1, false, 0, :rand.seed_s(:exsss, {9, 9, 9}))
    {t2, _id, _state} = gen_turn(2, true, id, state)

    # An interior forward id gap inside turn 2 marks the projection
    # damaged (Recovery hard-mark); compaction must refuse wholesale.
    t2 = Enum.map(t2, &%{&1 | id: &1.id + 5})

    events = Enum.map(t1 ++ t2, &normalize!/1)
    {live_model, _raw} = run_live_compacted(events)

    assert live_model.projection.damaged
    assert "turn-1" in retained_loop_turn_ids(live_model)
  end

  # ---------------------------------------------------------------------
  # 5. driver activation — the real loop compacts at its brackets
  # ---------------------------------------------------------------------

  defmodule FakeLane do
    @moduledoc false
    @behaviour Raxol.Harness.SessionLane

    @impl true
    def subscribe(%{test: test_pid}) do
      send(test_pid, {:subscribed, self()})
      :ok
    end

    @impl true
    def interrupt(_session, _payload), do: :ok

    @impl true
    def steer(_session, _request), do: {:error, :unused}

    @impl true
    def submit(_session, _request), do: :ok

    @impl true
    def answer_permission(_session, _answer), do: :ok

    @impl true
    def monitor(%{pid: pid}) when is_pid(pid), do: Process.monitor(pid)
    def monitor(_session), do: nil
  end

  test "the driver compacts retired turns out of the live event list" do
    {:ok, device} = StringIO.open("")
    {:ok, fake_session} = Agent.start(fn -> nil end)
    test_pid = self()

    {:ok, driver} =
      LiveSessionDriver.start_link(
        lane:
          {FakeLane, %{session_id: "s1", pid: fake_session, test: test_pid}},
        device: device,
        width: @width,
        rows: @rows,
        footer_rows: @footer_rows,
        mode: :inline_log,
        cadence_opts: [flush_interval_ms: 0],
        notify: test_pid
      )

    assert_receive {:subscribed, forwarder}, 2_000
    on_exit(fn -> LiveSessionDriver.halt(driver) end)

    {t1, id, state} = gen_turn(1, false, 0, :rand.seed_s(:exsss, {11, 11, 11}))
    {t2, _id, _state} = gen_turn(2, false, id, state)

    Enum.each(t1 ++ t2, fn ev -> send(forwarder, {:session_event, "s1", ev}) end)

    eventually(fn ->
      case probe(driver) do
        nil -> false
        model -> retained_loop_turn_ids(model) == ["turn-2"]
      end
    end)
  end

  defp probe(driver) do
    ref = make_ref()
    send(driver, {:debug_state_probe, self(), ref})

    receive do
      {:debug_state_reply, ^ref, state} -> state.model
    after
      500 -> nil
    end
  end

  defp eventually(fun, timeout \\ 5_000, interval \\ 25) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval, timeout)
  end

  defp do_eventually(fun, deadline, interval, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within #{timeout}ms")
      else
        Process.sleep(interval)
        do_eventually(fun, deadline, interval, timeout)
      end
    end
  end
end
