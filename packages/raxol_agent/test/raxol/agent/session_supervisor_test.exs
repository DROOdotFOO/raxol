defmodule Raxol.Agent.Session.SupervisorTest do
  @moduledoc """
  SS — the per-session OTP tree + `session_id → pid` registry that the Wave 2
  units (U4 reattach, U5/U6 turn kill/steer, U9 pointer records) resolve
  against.

  Proves:

    1. `start_session/2` brings up one supervised subtree (sink + session), both
       registered; `stop_session/1` tears it down cleanly and closes the journal.
    2. A bridge (journal-owner) crash restarts the tree in DEPENDENCY ORDER
       under `:rest_for_one` (sink first, then session) — asserted via the
       restarted session resolving the ALREADY-restarted sink.
    3. A session crash recovers with exactly one bridge and one writer, and a
       durable event round-trips (emit → journal → live tail) post-recovery.
    4. `whereis/1`, `list_sessions/0`, and duplicate-id rejection behave.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Session
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Core.Runtime.EmitBus

  # A synchronous, headless agent: one inbound message = one fold = one turn.
  defmodule EchoAgent do
    use Raxol.Agent

    def init(_context), do: %{seen: []}

    def update({:agent_message, _from, {:say, text}}, model),
      do: {%{model | seen: [text | model.seen]}, []}

    def update(_msg, model), do: {model, []}

    def view(model), do: text("seen: #{length(model.seen)}")
  end

  setup do
    # App-level singletons: tolerate an already-running instance.
    ensure_registry(:duplicate, EmitBus.registry_name())

    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    # The lifecycle's own DynamicSupervisor (used by Lifecycle.start_link).
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    # Per-test singletons owned by ExUnit (auto-stopped at test end): the agent
    # Registry, the DynSup the session trees run under, and the named
    # SessionStreamer the sink emits into.
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})

    start_supervised!(Raxol.Agent.SessionStreamer)

    :ok
  end

  describe "start_session / stop_session (one supervised subtree)" do
    test "start brings the whole tree up and registers it; stop tears it down and closes the journal" do
      base = tmp_base()
      sid = "ss-start-#{uniq()}"

      {:ok, sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_start_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      # The subtree supervisor is registered and is the returned pid.
      assert is_pid(sup)
      assert [{^sup, _}] = registry_lookup({:session_supervisor, sid})

      # Both children are up and registered.
      session = Session.Supervisor.whereis(sid)
      assert is_pid(session) and Process.alive?(session)
      assert [{bridge, _}] = registry_lookup({:emit_bridge, sid})
      assert Process.alive?(bridge)

      # Drive one durable turn so the journal actually opens, then grab the
      # writer pid to prove it closes on teardown.
      :ok = SessionStreamer.subscribe(sid)
      :ok = Session.send_message(agent_id(session), {:say, "hi"})
      assert_receive {:session_event, ^sid, %Event{type: :turn_completed}}, 1_000

      %{journal: %FileStore{writer: writer}} = :sys.get_state(bridge)
      assert Process.alive?(writer)

      # Teardown: whole subtree gone, registry clean, journal writer closed.
      assert :ok = Session.Supervisor.stop_session(sid)
      wait_until(fn -> not Process.alive?(sup) end)

      refute Process.alive?(session)
      refute Process.alive?(bridge)
      wait_until(fn -> not Process.alive?(writer) end)
      refute Process.alive?(writer)

      # Registry keys clear on each process's DOWN (just after termination).
      wait_until(fn ->
        Session.Supervisor.whereis(sid) == nil and
          registry_lookup({:session_supervisor, sid}) == [] and
          registry_lookup({:emit_bridge, sid}) == []
      end)

      assert Session.Supervisor.list_sessions() == []
    end

    test "duplicate start_session with the same session_id returns {:error, {:already_started, _}}" do
      sid = "ss-dup-#{uniq()}"
      base = tmp_base()

      {:ok, sup1} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_dup_a_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      assert {:error, {:already_started, ^sup1}} =
               Session.Supervisor.start_session(EchoAgent,
                 id: :"ss_dup_b_#{uniq()}",
                 session_id: sid,
                 journal_opts: [base_dir: base]
               )
    end

    test "stop_session on an unknown id returns {:error, :not_found}" do
      assert {:error, :not_found} =
               Session.Supervisor.stop_session("ss-nope-#{uniq()}")
    end
  end

  describe "rest_for_one dependency order (bridge crash)" do
    test "a sink crash restarts the sink FIRST, then the session — the restarted session resolves the new sink" do
      base = tmp_base()
      sid = "ss-bridgecrash-#{uniq()}"

      {:ok, _sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_bc_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      session1 = Session.Supervisor.whereis(sid)
      [{bridge1, _}] = registry_lookup({:emit_bridge, sid})
      assert %{emit_bridge: ^bridge1} = :sys.get_state(session1)

      # Brutally kill the sink (the journal owner, first in the tree).
      Process.exit(bridge1, :kill)

      # rest_for_one restarts the sink AND everything after it (the session).
      # Wait until both are fresh, live pids.
      wait_until(fn ->
        s = Session.Supervisor.whereis(sid)
        b = registry_lookup({:emit_bridge, sid})

        match?([{p, _}] when is_pid(p) and p != bridge1, b) and
          is_pid(s) and s != session1 and Process.alive?(s)
      end)

      session2 = Session.Supervisor.whereis(sid)
      [{bridge2, _}] = registry_lookup({:emit_bridge, sid})

      # The sink was restarted (new pid).
      assert bridge2 != bridge1
      # rest_for_one (not one_for_one): the SESSION restarted too.
      assert session2 != session1
      # DEPENDENCY ORDER: the restarted session resolved the ALREADY-restarted
      # sink — proving the sink came up before the session.
      assert %{emit_bridge: ^bridge2} = :sys.get_state(session2)

      # Exactly one sink for the session_id — no orphan/duplicate.
      assert [{^bridge2, _}] = registry_lookup({:emit_bridge, sid})
    end
  end

  describe "session crash recovery (sink not orphaned or duplicated)" do
    test "a killed session recovers with one sink + one writer; a durable event round-trips post-recovery" do
      base = tmp_base()
      sid = "ss-sesscrash-#{uniq()}"

      {:ok, _sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_sc_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      session1 = Session.Supervisor.whereis(sid)
      [{bridge1, _}] = registry_lookup({:emit_bridge, sid})

      # Brutal session kill — terminate/2 never runs, so the (unlinked) sink and
      # lifecycle survive.
      Process.exit(session1, :kill)

      wait_until(fn ->
        s = Session.Supervisor.whereis(sid)
        is_pid(s) and s != session1 and Process.alive?(s)
      end)

      session2 = Session.Supervisor.whereis(sid)

      # The sink survived the session crash (session-only restart) — same pid,
      # exactly one registered, and its single writer is unchanged.
      assert Process.alive?(bridge1)
      assert [{^bridge1, _}] = registry_lookup({:emit_bridge, sid})

      # A durable turn round-trips through the recovered tree: emit → journal →
      # live tail, and a duplicate sink would emit a second turn_started.
      :ok = SessionStreamer.subscribe(sid)
      :ok = Session.send_message(agent_id(session2), {:say, "after"})

      assert_receive {:session_event, ^sid, %Event{type: :turn_started}}, 1_000
      assert_receive {:session_event, ^sid, %Event{type: :turn_completed}}, 1_000

      refute_receive {:session_event, ^sid, %Event{type: :turn_started}}, 200

      # Journal on disk holds the durable trace with monotonic offsets.
      {:ok, j} = FileStore.open(sid, base_dir: base)
      {:ok, records} = FileStore.read(j)
      FileStore.close(j)

      ids = Enum.map(records, & &1["id"])
      assert ids == Enum.sort(ids)
      assert length(ids) >= 3
    end
  end

  describe "lifecycle ownership (RED 1 — no leak, no reattach-to-dead)" do
    test "stop_session tears down the tree-owned lifecycle — no orphaned runtime" do
      base = tmp_base()
      sid = "ss-lifeleak-#{uniq()}"

      {:ok, sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_ll_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      # The lifecycle is a supervised sibling, registered by session_id.
      lifecycle = lifecycle_pid(sid)
      assert is_pid(lifecycle) and Process.alive?(lifecycle)

      # Under BaseManager the session does NOT trap exits, so stop_session kills
      # it WITHOUT running terminate/2. If the lifecycle were a session-spawned
      # orphan it would leak here; as a tree child it dies with the subtree.
      assert :ok = Session.Supervisor.stop_session(sid)
      wait_until(fn -> not Process.alive?(sup) end)
      wait_until(fn -> not Process.alive?(lifecycle) end)
      refute Process.alive?(lifecycle)
      wait_until(fn -> lifecycle_pid(sid) == nil end)
    end

    test "restarting the same session_id yields a FRESH lifecycle + init model (never reattaches to the dead one)" do
      base = tmp_base()
      sid = "ss-reattach-#{uniq()}"

      {:ok, sup1} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_ra_a_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      session1 = Session.Supervisor.whereis(sid)
      life1 = lifecycle_pid(sid)
      assert is_pid(life1)

      # Accumulate model state so a reattach would be observable.
      :ok = Session.send_message(agent_id(session1), {:say, "one"})
      wait_until(fn -> get_model(session1) == {:ok, %{seen: ["one"]}} end)

      assert :ok = Session.Supervisor.stop_session(sid)
      wait_until(fn -> not Process.alive?(sup1) and lifecycle_pid(sid) == nil end)
      refute Process.alive?(life1)

      # Same session_id again: a fresh subtree, a fresh lifecycle, and — the
      # crux — the app's INIT model, not the dead session's accumulated one.
      {:ok, sup2} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_ra_b_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      session2 = Session.Supervisor.whereis(sid)
      life2 = lifecycle_pid(sid)

      assert is_pid(life2) and Process.alive?(life2)
      assert life2 != life1
      assert is_pid(sup2) and sup2 != sup1
      assert {:ok, %{seen: []}} = get_model(session2)
    end

    test "lifecycle is REUSED after a session-only crash but FRESH after a bridge crash" do
      base = tmp_base()
      sid = "ss-lifeid-#{uniq()}"

      {:ok, _sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_li_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      life0 = lifecycle_pid(sid)
      session0 = Session.Supervisor.whereis(sid)
      assert is_pid(life0)

      # Session-only crash: rest_for_one restarts only the child at/after the
      # session (the session is last), so the lifecycle before it is untouched.
      Process.exit(session0, :kill)

      wait_until(fn ->
        s = Session.Supervisor.whereis(sid)
        is_pid(s) and s != session0 and Process.alive?(s)
      end)

      # REUSED — same pid, and the restarted session re-resolved it.
      assert lifecycle_pid(sid) == life0
      session1 = Session.Supervisor.whereis(sid)
      assert %{lifecycle_pid: ^life0} = :sys.get_state(session1)

      # Accumulate model state on the REUSED lifecycle so a "fresh model" claim
      # after the bridge crash is observable at the MODEL level, not just via a
      # new pid: a reattach-to-dead would carry this state forward.
      :ok = Session.send_message(agent_id(session1), {:say, "kept"})
      wait_until(fn -> get_model(session1) == {:ok, %{seen: ["kept"]}} end)

      # Bridge crash: the bridge is first, so bridge + lifecycle + session all
      # restart — a FRESH lifecycle (no durable event is emitted into a dead
      # sink), which the restarted session re-resolves.
      [{bridge1, _}] = registry_lookup({:emit_bridge, sid})
      Process.exit(bridge1, :kill)

      wait_until(fn ->
        l = lifecycle_pid(sid)
        is_pid(l) and l != life0 and Process.alive?(l)
      end)

      life2 = lifecycle_pid(sid)
      assert life2 != life0

      wait_until(fn ->
        match?(%{lifecycle_pid: ^life2}, :sys.get_state(Session.Supervisor.whereis(sid)))
      end)

      # The crux: the fresh lifecycle carries the app's INIT model, NOT the
      # accumulated ["kept"] — proving it did not reattach to the dead runtime.
      session2 = Session.Supervisor.whereis(sid)
      wait_until(fn -> get_model(session2) == {:ok, %{seen: []}} end)
    end
  end

  describe "graceful stop drains the durable tail (YELLOW 2 — no journal-tail loss)" do
    test "durable events queued at stop_session all reach the journal" do
      base = tmp_base()
      sid = "ss-drain-#{uniq()}"

      {:ok, _sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_drain_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      session = Session.Supervisor.whereis(sid)
      aid = agent_id(session)

      # Fire several turns WITHOUT awaiting their round-trip, so their durable
      # events are still in-flight (session/dispatcher/bridge mailboxes) at stop
      # time. Each turn journals turn_started, item_completed, turn_completed.
      n = 5
      for i <- 1..n, do: :ok = Session.send_message(aid, {:say, "m#{i}"})

      # Graceful stop must flush the whole queued tail before teardown.
      assert :ok = Session.Supervisor.stop_session(sid)
      wait_until(fn -> Session.Supervisor.whereis(sid) == nil end)

      # Reopen from disk: all N turns present — none lost to a truncated tail.
      {:ok, j} = FileStore.open(sid, base_dir: base)
      {:ok, records} = FileStore.read(j)
      FileStore.close(j)

      assert Enum.count(records, &(&1["type"] == "turn_completed")) == n
      ids = Enum.map(records, & &1["id"])
      assert ids == Enum.sort(ids)
    end
  end

  describe "standalone Session under a rest_for_one parent (YELLOW 1 — no orphaned lifecycle)" do
    test "a Team-style parent shutdown honors terminate/2 and leaves no orphaned lifecycle" do
      base = tmp_base()
      sid = "ss-teardown-#{uniq()}"

      # Mirror Raxol.Agent.Team exactly: a :rest_for_one supervisor over a
      # standalone Session child spec (Session.child_spec).
      children = [
        {Session,
         [
           app_module: EchoAgent,
           id: :"ss_td_#{uniq()}",
           session_id: sid,
           journal_opts: [base_dir: base]
         ]}
      ]

      {:ok, parent} = Supervisor.start_link(children, strategy: :rest_for_one)

      session = Session.Supervisor.whereis(sid)
      assert is_pid(session) and Process.alive?(session)

      lifecycle = lifecycle_pid(sid)
      assert is_pid(lifecycle) and Process.alive?(lifecycle)

      # Tear the parent down. The child-spec shutdown budget (drain + margin) must
      # give the Session's terminate/2 long enough to run stop_lifecycle_sync to
      # completion — incl. its Process.exit(:kill) fallback — so the owned
      # lifecycle can never be orphaned by a premature parent brutal-kill.
      Supervisor.stop(parent)

      refute Process.alive?(session)
      wait_until(fn -> not Process.alive?(lifecycle) end)
      refute Process.alive?(lifecycle)
      wait_until(fn -> lifecycle_pid(sid) == nil end)
    end

    test "a graceful standalone GenServer.stop drains its durable tail" do
      base = tmp_base()
      sid = "ss-standalone-drain-#{uniq()}"

      {:ok, session} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"ss_sad_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      aid = agent_id(session)
      n = 4
      for i <- 1..n, do: :ok = Session.send_message(aid, {:say, "s#{i}"})

      # Standalone traps exits: terminate/2 runs, draining the lifecycle
      # (dispatcher) then the bridge (which flushes the journal) — no tail loss.
      :ok = GenServer.stop(session)
      wait_until(fn -> not Process.alive?(session) end)

      {:ok, j} = FileStore.open(sid, base_dir: base)
      {:ok, records} = FileStore.read(j)
      FileStore.close(j)

      assert Enum.count(records, &(&1["type"] == "turn_completed")) == n
    end
  end

  describe "whereis / list_sessions" do
    test "whereis resolves a live session and returns nil for an unknown id" do
      assert Session.Supervisor.whereis("ss-unknown-#{uniq()}") == nil

      sid = "ss-whereis-#{uniq()}"
      base = tmp_base()

      {:ok, _sup} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_wi_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> Session.Supervisor.stop_session(sid) end)

      session = Session.Supervisor.whereis(sid)
      assert is_pid(session) and Process.alive?(session)
    end

    test "list_sessions is accurate across starts, stops, and crashes" do
      base = tmp_base()
      sid_a = "ss-list-a-#{uniq()}"
      sid_b = "ss-list-b-#{uniq()}"

      {:ok, _a} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_la_#{uniq()}",
          session_id: sid_a,
          journal_opts: [base_dir: base]
        )

      {:ok, _b} =
        Session.Supervisor.start_session(EchoAgent,
          id: :"ss_lb_#{uniq()}",
          session_id: sid_b,
          journal_opts: [base_dir: base]
        )

      on_exit(fn ->
        Session.Supervisor.stop_session(sid_a)
        Session.Supervisor.stop_session(sid_b)
      end)

      listed = fn -> Session.Supervisor.list_sessions() |> Map.new() end

      m = listed.()
      assert Map.has_key?(m, sid_a)
      assert Map.has_key?(m, sid_b)

      # After a crash, the (restarted) session still lists — under its session_id.
      Process.exit(Session.Supervisor.whereis(sid_a), :kill)

      wait_until(fn ->
        s = Session.Supervisor.whereis(sid_a)
        is_pid(s) and Process.alive?(s)
      end)

      m2 = listed.()
      assert Map.has_key?(m2, sid_a)
      assert Map.has_key?(m2, sid_b)

      # After a stop, only the survivor remains.
      assert :ok = Session.Supervisor.stop_session(sid_a)
      wait_until(fn -> Session.Supervisor.whereis(sid_a) == nil end)

      m3 = listed.()
      refute Map.has_key?(m3, sid_a)
      assert Map.has_key?(m3, sid_b)
    end
  end

  describe "standalone sessions still resolve through the seam" do
    test "a bare Session.start_link registers under {:session, session_id} and stop_session stops it" do
      sid = "ss-standalone-#{uniq()}"
      base = tmp_base()

      {:ok, session} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"ss_standalone_#{uniq()}",
          session_id: sid,
          journal_opts: [base_dir: base]
        )

      on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

      # Resolvable via the shared seam even though it was NOT started under the
      # tree (no {:session_supervisor, _} key exists for it).
      assert Session.Supervisor.whereis(sid) == session
      assert registry_lookup({:session_supervisor, sid}) == []

      # stop_session falls back to stopping the standalone session directly.
      assert :ok = Session.Supervisor.stop_session(sid)
      wait_until(fn -> not Process.alive?(session) end)
      # Registry removes the {:session, _} key on the process's DOWN, which lands
      # just after GenServer.stop returns — wait for the key to clear.
      wait_until(fn -> Session.Supervisor.whereis(sid) == nil end)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp agent_id(session) do
    %{id: id} = :sys.get_state(session)
    id
  end

  # The tree-owned lifecycle for a session_id (nil if none). It registers under
  # {:lifecycle, session_id} in Raxol.Agent.Registry.
  defp lifecycle_pid(sid) do
    case Registry.lookup(Raxol.Agent.Registry, {:lifecycle, sid}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp get_model(session) when is_pid(session) do
    GenServer.call(session, :get_model)
  catch
    :exit, _ -> {:error, :down}
  end

  defp registry_lookup(key), do: Registry.lookup(Raxol.Agent.Registry, key)

  defp uniq, do: System.unique_integer([:positive])

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  defp tmp_base do
    base = Path.join(System.tmp_dir!(), "ss_journal_#{uniq()}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    base
  end

  defp ensure_registry(keys, name) do
    case Registry.start_link(keys: keys, name: name) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_running({DynamicSupervisor, opts}) do
    case DynamicSupervisor.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_running({mod, opts}) do
    case mod.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end
