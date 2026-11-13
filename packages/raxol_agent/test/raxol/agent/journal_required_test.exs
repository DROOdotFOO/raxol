defmodule Raxol.Agent.JournalRequiredTest do
  @moduledoc """
  `journal_required: true` on `Raxol.Agent.Session.Supervisor.start_session/2`:
  the journal is opened in the session tree before anything else starts, is
  private, locked and bound to its `:cwd` and `:title`, and a start that
  cannot have it starts nothing.
  """
  use ExUnit.Case, async: false

  import Bitwise

  @moduletag :capture_log
  @moduletag :unix_only

  alias Raxol.Agent.Comm
  alias Raxol.Agent.EmitBridge
  alias Raxol.Agent.ForeignBeam
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Agent.ToolPolicy
  alias Raxol.Core.Runtime.EmitBus

  @listener :journal_required_test_listener

  setup do
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    # The test hears every registration, so a restart is waited for, not polled.
    Process.register(self(), @listener)

    start_supervised!(
      {Registry, keys: :unique, name: Raxol.Agent.Registry, listeners: [@listener]}
    )

    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
    start_supervised!(Raxol.Agent.SessionStreamer)

    base = Path.join(System.tmp_dir!(), "journal_required_#{uniq()}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, id: "jr-#{uniq()}"}
  end

  test "the journal is open, private and marked before the agent runs", %{base: base, id: id} do
    assert {:ok, _sup} = start(id, base)

    dir = Path.join(base, id)
    assert File.exists?(Path.join(dir, "writer.lock"))
    assert (File.stat!(dir).mode &&& 0o777) == 0o700
    assert (File.stat!(Path.join(dir, "writer.lock")).mode &&& 0o777) == 0o600

    # Nothing was sent to the agent, and the journal already has its marker.
    assert {:ok, [marker]} = FileStore.read_records(id, base_dir: base)

    assert %{
             "id" => 1,
             "type" => "agent_started",
             "family" => "loop",
             "payload" => %{"prior_offset" => 0}
           } = marker

    assert Raxol.Agent.Journal.Tip.tip([marker]) == :no_tip
  end

  test "a restart continues the journal from where it stopped", %{base: base, id: id} do
    assert {:ok, _sup} = start(id, base)
    assert {:ok, "count: 1"} = Comm.call(id, "increment")
    :ok = Session.Supervisor.stop_session(id)
    {:ok, first} = FileStore.read_records(id, base_dir: base)
    last = List.last(first)["id"]
    refute File.exists?(Path.join([base, id, "writer.lock"]))

    assert {:ok, _sup} = start(id, base)
    assert {:ok, "count: 0"} = Comm.call(id, "get")
    :ok = Session.Supervisor.stop_session(id)

    {:ok, records} = FileStore.read_records(id, base_dir: base)
    assert Enum.take(records, length(first)) == first
    assert Enum.map(records, & &1["id"]) == Enum.to_list(1..length(records))

    assert %{"type" => "agent_started", "payload" => %{"prior_offset" => ^last}} =
             Enum.at(records, last)
  end

  test "a turn left open by the run before is closed on restart", %{base: base, id: id} do
    assert {:ok, _sup} = start(id, base)

    # Stopped mid-turn: the session dies holding a turn nobody answered.
    test = self()

    approver = fn tool, params, context ->
      send(test, :holding)
      ToolPolicy.allow_all().(tool, params, context)
    end

    spawn(fn -> Comm.call(id, {:acp_prompt, "hold", approver}, 30_000) end)
    assert_receive :holding, 5_000
    :ok = Session.Supervisor.stop_session(id)

    {:ok, before} = FileStore.read_records(id, base_dir: base)
    assert [%{"turn_id" => turn_id}] = open_turn_starts(before)
    assert "acp-" <> _ = turn_id
    assert checkpoint(id, base) == {:error, :mid_turn}

    assert {:ok, _sup} = start(id, base)
    :ok = Session.Supervisor.stop_session(id)

    {:ok, records} = FileStore.read_records(id, base_dir: base)
    assert [marker, seal] = Enum.drop(records, length(before))
    assert marker["type"] == "agent_started"

    assert %{
             "type" => "turn_canceled",
             "turn_id" => ^turn_id,
             "payload" => %{"reason" => "agent_restarted"}
           } = seal

    assert open_turn_starts(records) == []
    assert {:ok, _offset} = checkpoint(id, base)
  end

  test "a call the bridge does not know is answered and leaves it running", %{base: base, id: id} do
    {:ok, bridge} =
      EmitBridge.start_link(
        session_id: id,
        journal_required: true,
        journal_opts: [base_dir: base]
      )

    assert GenServer.call(bridge, :not_a_bridge_call) == {:error, :not_implemented}
    assert EmitBridge.prior_offset(bridge) == 0
    :ok = GenServer.stop(bridge)
  end

  test "the marker is stamped like the bridge's other durable records", %{base: base, id: id} do
    {:ok, bridge} =
      EmitBridge.start_link(
        session_id: id,
        journal_required: true,
        journal_opts: [base_dir: base],
        branch_id: "side",
        actor: %{kind: :agent, id: "a1"}
      )

    assert EmitBridge.prior_offset(bridge) == 0
    :ok = GenServer.stop(bridge)

    assert {:ok, [marker]} = FileStore.read_records(id, base_dir: base)

    assert %{
             "type" => "agent_started",
             "tier" => "durable",
             "branch_id" => "side",
             "actor" => %{"kind" => "agent", "id" => "a1"},
             "payload" => %{"prior_offset" => 0}
           } = marker

    # Stopping it closed the journal: the lock is gone.
    refute File.exists?(Path.join([base, id, "writer.lock"]))
  end

  test "a Writer that dies under a queued event stops the bridge, which reopens", %{
    base: base,
    id: id
  } do
    assert {:ok, _sup} = start(id, base)
    assert_receive {:register, Raxol.Agent.Registry, {:emit_bridge, ^id}, bridge, _}, 5_000
    assert_receive {:register, Raxol.Agent.Registry, ^id, _session, _}, 5_000
    %{journal: %{writer: writer}} = :sys.get_state(bridge)

    # The durable event is ahead of the Writer's exit in the bridge's mailbox,
    # so the bridge learns of the death from the append, not from the exit.
    :ok = :sys.suspend(bridge)
    EmitBus.publish(EmitBus.build(id, :app_update, :durable, %{}, turn_id: "t1"))
    writer_down = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^writer_down, :process, ^writer, :killed}, 5_000
    :ok = :sys.resume(bridge)

    assert_receive {:register, Raxol.Agent.Registry, {:emit_bridge, ^id}, reopened, _}, 5_000
    assert reopened != bridge
    assert_receive {:register, Raxol.Agent.Registry, ^id, _session, _}, 5_000

    assert {:ok, "count: 1"} = Comm.call(id, "increment")
    :ok = Session.Supervisor.stop_session(id)

    {:ok, records} = FileStore.read_records(id, base_dir: base)
    assert Enum.map(records, & &1["id"]) == Enum.to_list(1..length(records))
    assert [_first, _second] = Enum.filter(records, &(&1["type"] == "agent_started"))
  end

  test "a standalone session cannot require a journal", %{base: base, id: id} do
    assert_raise ArgumentError, ~r/journal_required needs/, fn ->
      Session.start_link(
        app_module: Counter,
        id: id,
        session_id: id,
        journal_required: true,
        journal_opts: [base_dir: base]
      )
    end

    refute File.exists?(Path.join(base, id))
  end

  test "a journal bound to another root or app is refused, and nothing starts", %{
    base: base,
    id: id
  } do
    assert {:ok, _sup} = start(id, base)
    :ok = Session.Supervisor.stop_session(id)
    {:ok, before} = FileStore.read_records(id, base_dir: base)

    assert {:error, {:journal_bound, bound}} = start(id, base, cwd: "/another/root")
    assert bound == %{field: :cwd, journal: "/the/root", requested: "/another/root"}

    assert {:error, {:journal_bound, bound}} = start(id, base, title: "Another.App")
    assert bound == %{field: :title, journal: "The.App", requested: "Another.App"}

    assert Session.Supervisor.whereis(id) == nil
    assert Registry.lookup(Raxol.Agent.Registry, {:emit_bridge, id}) == []
    refute File.exists?(Path.join([base, id, "writer.lock"]))
    assert FileStore.read_records(id, base_dir: base) == {:ok, before}

    assert {:ok, _sup} = start(id, base)
  end

  test "a journal a live BEAM holds is refused, naming the holder", %{base: base, id: id} do
    holder = ForeignBeam.start_supervised()

    File.mkdir_p!(Path.join(base, id))
    File.write!(Path.join([base, id, "writer.lock"]), holder.pid)

    assert start(id, base) == {:error, {:journal_locked, holder.pid}}
    assert Session.Supervisor.whereis(id) == nil
    assert Session.Supervisor.list_sessions() == []
    assert File.read!(Path.join([base, id, "writer.lock"])) == holder.pid
  end

  test "a damaged journal is not continued", %{base: base, id: id} do
    assert {:ok, _sup} = start(id, base)
    assert {:ok, "count: 1"} = Comm.call(id, "increment")
    :ok = Session.Supervisor.stop_session(id)

    segment = Path.join([base, id, "journal", "000001.jsonl"])
    [first | rest] = segment |> File.read!() |> String.split("\n", parts: 2)
    File.write!(segment, [first, "\n{not json\n", rest])

    assert start(id, base) == {:error, {:journal_damaged, id}}
    assert Session.Supervisor.whereis(id) == nil
    refute File.exists?(Path.join([base, id, "writer.lock"]))
  end

  test "a bridge that crashes comes back on the same journal", %{base: base, id: id} do
    assert {:ok, _sup} = start(id, base)
    assert_receive {:register, Raxol.Agent.Registry, {:emit_bridge, ^id}, bridge, _}, 5_000
    assert_receive {:register, Raxol.Agent.Registry, {:session, ^id}, _session, _}, 5_000
    assert {:ok, "count: 1"} = Comm.call(id, "increment")

    Process.exit(bridge, :kill)
    assert_receive {:register, Raxol.Agent.Registry, {:emit_bridge, ^id}, restarted, _}, 5_000
    assert restarted != bridge
    assert_receive {:register, Raxol.Agent.Registry, {:session, ^id}, _session, _}, 5_000
    assert_receive {:register, Raxol.Agent.Registry, ^id, _session, _}, 5_000

    # The restarted tree journals on: one journal, one more marker.
    assert {:ok, "count: 1"} = Comm.call(id, "increment")
    :ok = Session.Supervisor.stop_session(id)

    {:ok, records} = FileStore.read_records(id, base_dir: base)
    assert Enum.map(records, & &1["id"]) == Enum.to_list(1..length(records))

    assert [%{"payload" => %{"prior_offset" => 0}}, second] =
             Enum.filter(records, &(&1["type"] == "agent_started"))

    assert second["payload"]["prior_offset"] == second["id"] - 1
  end

  test "without the option the journal stays lazy", %{base: base, id: id} do
    assert {:ok, _sup} =
             Session.Supervisor.start_session(Counter,
               id: id,
               session_id: id,
               journal_opts: [base_dir: base]
             )

    refute File.exists?(Path.join(base, id))
  end

  # -- helpers ------------------------------------------------------------------

  defp start(id, base, bound \\ []) do
    journal_opts = Keyword.merge([base_dir: base, cwd: "/the/root", title: "The.App"], bound)

    Session.Supervisor.start_session(Counter,
      id: id,
      session_id: id,
      journal_required: true,
      journal_opts: journal_opts
    )
  end

  # Whether a checkpoint can be written: the rule that refuses one mid-turn.
  defp checkpoint(id, base) do
    {:ok, journal} = FileStore.open(id, base_dir: base)
    result = Checkpoint.write(journal, nil)
    :ok = FileStore.close(journal)
    result
  end

  # The `turn_started` records with no closing bracket of the same turn after them.
  defp open_turn_starts(records) do
    closed =
      for %{"type" => type, "turn_id" => turn_id} <- records,
          type in ["turn_completed", "turn_canceled", "error"],
          into: MapSet.new(),
          do: turn_id

    for %{"type" => "turn_started", "turn_id" => turn_id} = record <- records,
        not MapSet.member?(closed, turn_id),
        do: record
  end

  defp uniq, do: System.unique_integer([:positive])

  defp ensure_running({module, opts}) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end
