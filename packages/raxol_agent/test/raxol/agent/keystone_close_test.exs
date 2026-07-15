defmodule Raxol.Agent.KeystoneCloseTest do
  @moduledoc """
  U1.5 — close the keystone. Proves "replay-as-truth" is real and the dual-id
  landmine is dead:

    1. a durable event's live-tail id == its journal offset == its replayed id,
    2. the durable trace survives a writer death (close/reopen), ids intact,
    3. a turn is bracketed by `turn_started` … items … `turn_completed` with one
       stable `turn_id`, and an errored turn emits `:error`,
    4. `session_id` is non-nil on emitted events for a live agent session.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.EmitBridge
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

    def update({:agent_message, _from, :boom}, _model),
      do: raise("boom in a live turn")

    def update(_msg, model), do: {model, []}

    def view(model), do: text("seen: #{length(model.seen)}")
  end

  setup do
    # App-level singletons: tolerate an already-running instance, never leak a
    # named singleton that a later start_supervised!-based test would collide on.
    ensure_registry(:duplicate, EmitBus.registry_name())
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})

    ensure_running(
      {DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one}
    )

    # Per-test singletons owned by ExUnit (auto-stopped at test end): the agent
    # Registry (matches session_test/team_test) and the named SessionStreamer the
    # sink emits into.
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!(Raxol.Agent.SessionStreamer)

    :ok
  end

  describe "the dual-id regression (id authority)" do
    test "durable live-tail ids == journal offsets == replayed ids (one identity)" do
      session_id = "u15-dualid-#{uniq()}"

      {:ok, sess} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"u15_dualid_#{uniq()}",
          session_id: session_id
        )

      on_exit(fn -> stop(sess) end)

      :ok = SessionStreamer.subscribe(session_id)
      :ok = Session.send_message(agent_id(sess), {:say, "hello"})

      durable = collect_until_turn_completed(session_id)
      live_ids = Enum.map(durable, & &1.id)

      # The live tail carried a monotonic run of durable ids.
      assert live_ids == Enum.sort(live_ids)
      assert length(live_ids) >= 3
      assert Enum.map(durable, & &1.type) == [:turn_started, :item_completed, :turn_completed]

      # Reopen the journal from disk (same session dir via RAXOL_SESSIONS_DIR)
      # and replay it. One identity: replayed id == journal offset == live id.
      {:ok, j} = FileStore.open(session_id, [])
      {:ok, records} = FileStore.read(j)
      FileStore.close(j)

      replay_ids = Enum.map(records, & &1["id"])
      assert replay_ids == live_ids
      assert replay_ids == Enum.to_list(1..length(replay_ids))
    end
  end

  describe "survives a writer death (BEAM kill)" do
    test "durable trace is fully readable after close/reopen; ids intact and monotonic" do
      base = tmp_base()
      session_id = "u15-kill-#{uniq()}"
      {:ok, streamer} = SessionStreamer.start_link(name: nil)

      {:ok, bridge} =
        EmitBridge.start_link(
          session_id: session_id,
          streamer: streamer,
          journal_opts: [base_dir: base]
        )

      SessionStreamer.subscribe(session_id, streamer)

      # A full turn's worth of events, durable + one ephemeral delta.
      publish(session_id, :turn_started, :durable, %{prompt: "p"}, "t1")
      publish(session_id, :app_update, :durable, %{message: {:agent_message, :x, :go}}, "t1")
      publish(session_id, :command_result, :ephemeral, %{chunk: "streamed"}, "t1")
      publish(session_id, :turn_completed, :durable, %{}, "t1")

      # Wait until the sink has emitted turn_completed — guarantees all four were
      # processed (durable ones appended before publish).
      assert_receive {:session_event, ^session_id, %Event{type: :turn_completed}}, 1_000

      # Simulate the BEAM going away: stop the sink, which flushes + closes the
      # journal writer in terminate/2.
      GenServer.stop(bridge)

      # Reopen from disk. The ephemeral delta was never journaled; the three
      # durable events are present with monotonic offsets 1..3.
      {:ok, j} = FileStore.open(session_id, base_dir: base)
      {:ok, records} = FileStore.read(j)

      ids = Enum.map(records, & &1["id"])
      assert ids == [1, 2, 3]
      assert ids == Enum.sort(ids)

      assert Enum.map(records, & &1["type"]) ==
               ["turn_started", "item_completed", "turn_completed"]

      # The non-JSON tuple in the app_update payload was sanitized, not crashed.
      assert FileStore.status(j) == :ok
      FileStore.close(j)
    end
  end

  describe "turn brackets (loop vocabulary)" do
    test "a turn is turn_started{turn_id} … items … turn_completed{turn_id}, one stable turn_id" do
      session_id = "u15-turn-#{uniq()}"

      {:ok, sess} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"u15_turn_#{uniq()}",
          session_id: session_id
        )

      on_exit(fn -> stop(sess) end)

      :ok = SessionStreamer.subscribe(session_id)
      :ok = Session.send_message(agent_id(sess), {:say, "hi"})

      assert_receive {:session_event, ^session_id, %Event{type: :turn_started} = started}, 1_000
      assert_receive {:session_event, ^session_id, %Event{type: :item_completed} = item}, 1_000
      assert_receive {:session_event, ^session_id, %Event{type: :turn_completed} = completed}, 1_000

      # session_id is non-nil (acceptance #4) and the turn_id is one stable value
      # across every item in the turn.
      assert started.session_id == session_id
      assert is_binary(started.turn_id)
      assert started.turn_id == item.turn_id
      assert started.turn_id == completed.turn_id
    end

    test "an errored turn emits :error after turn_started" do
      session_id = "u15-err-#{uniq()}"

      {:ok, sess} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"u15_err_#{uniq()}",
          session_id: session_id
        )

      on_exit(fn -> stop(sess) end)

      :ok = SessionStreamer.subscribe(session_id)
      :ok = Session.send_message(agent_id(sess), :boom)

      assert_receive {:session_event, ^session_id, %Event{type: :turn_started} = started}, 1_000
      assert_receive {:session_event, ^session_id, %Event{type: :error} = error}, 1_000

      assert error.tier == :durable
      assert error.turn_id == started.turn_id
      assert Map.has_key?(error.payload, :reason)
    end
  end

  describe "session_id flows for a live agent session" do
    test "emitted events carry a non-nil session_id" do
      session_id = "u15-sid-#{uniq()}"

      {:ok, sess} =
        Session.start_link(
          app_module: EchoAgent,
          id: :"u15_sid_#{uniq()}",
          session_id: session_id
        )

      on_exit(fn -> stop(sess) end)

      assert {:ok, ^session_id} = Session.session_id(agent_id(sess))

      :ok = SessionStreamer.subscribe(session_id)
      :ok = Session.send_message(agent_id(sess), {:say, "x"})

      assert_receive {:session_event, ^session_id, %Event{} = event}, 1_000
      refute is_nil(event.session_id)
      assert event.session_id == session_id
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp collect_until_turn_completed(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{tier: :durable} = ev} ->
        acc = acc ++ [ev]
        if ev.type == :turn_completed, do: acc, else: collect_until_turn_completed(session_id, acc)

      {:session_event, ^session_id, %Event{}} ->
        # ephemeral — ignore for the durable-identity check
        collect_until_turn_completed(session_id, acc)
    after
      2_000 -> flunk("timed out collecting durable turn events; got: #{inspect(acc)}")
    end
  end

  defp publish(session_id, type, tier, payload, turn_id) do
    EmitBus.publish(EmitBus.build(session_id, type, tier, payload, turn_id: turn_id))
  end

  defp agent_id(sess) do
    %{id: id} = :sys.get_state(sess)
    id
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp tmp_base do
    base = Path.join(System.tmp_dir!(), "u15_journal_#{uniq()}")
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

  defp ensure_running({mod, opts}) do
    case start_child(mod, opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_child(DynamicSupervisor, opts), do: DynamicSupervisor.start_link(opts)
  defp start_child(mod, opts), do: mod.start_link(opts)
end
