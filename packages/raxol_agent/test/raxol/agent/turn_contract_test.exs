defmodule Raxol.Agent.TurnContractTest do
  @moduledoc """
  The agent turn contract (`Raxol.Agent.Comm`): `{:acp_prompt, text,
  approver}` answers `{:ok, text, usage}`, `approver` authorizes the turn's
  tool calls, and `{:acp_cancel, ref}` kills the in-flight turn. Driven
  through `Raxol.Agent.Reference.Counter` started by
  `Session.Supervisor.start_session/2`.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Raxol.Agent.Comm
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Agent.ToolPolicy

  @usage %{input_tokens: 0, output_tokens: 0}

  # An agent that answers a turn inline while that turn's process runs:
  # "run" starts a turn process that blocks; "answer" then replies to the
  # "run" turn from `update/2`. It records every cancel it sees.
  defmodule InlineAfterRun do
    @moduledoc false
    use Raxol.Agent

    alias Raxol.Agent.Comm

    def init(_context), do: %{running: nil, cancelled: []}

    def update(
          {:agent_message, _from, {:call, session, ref, {:acp_prompt, "run", approver}}},
          model
        ) do
      Comm.run_turn(session, ref, fn ->
        approver.("run", %{}, %{})

        receive do
          :never -> :ok
        end
      end)

      {%{model | running: ref}, []}
    end

    def update({:agent_message, _from, {:call, session, ref, {:acp_prompt, "answer", _}}}, model) do
      Comm.reply(session, model.running, {:ok, "answered inline", %{}})
      Comm.reply(session, ref, {:ok, "done", %{}})
      {model, []}
    end

    def update({:agent_message, _from, {:acp_cancel, ref}}, model),
      do: {%{model | cancelled: [ref | model.cancelled]}, []}

    def update(_msg, model), do: {model, []}
  end

  setup do
    # App-level singletons the agent's runtime Lifecycle uses (the Dispatcher
    # reads the theme from UserPreferences; the rendering engine starts its
    # component processes under Raxol.DynamicSupervisor). Other suites share
    # them, so they are started unlinked and an already-running one is kept.
    ensure_running({Raxol.Core.UserPreferences, name: Raxol.Core.UserPreferences})
    ensure_running({DynamicSupervisor, name: Raxol.DynamicSupervisor, strategy: :one_for_one})

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})

    base = Path.join(System.tmp_dir!(), "turn_contract_#{uniq()}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    id = "counter-#{uniq()}"

    {:ok, _sup} =
      Session.Supervisor.start_session(Counter,
        id: id,
        session_id: id,
        journal_opts: [base_dir: base]
      )

    %{id: id, base: base}
  end

  test "a prompt round-trips to {:ok, text, usage}", %{id: id} do
    allow = ToolPolicy.allow_all()

    assert {:ok, {:ok, "count: 1", @usage}} = prompt(id, "increment", allow)
    assert {:ok, {:ok, "count: 2", @usage}} = prompt(id, "increment", allow)
    assert {:ok, {:ok, "count: 2", @usage}} = prompt(id, "get", allow)
  end

  test "the approver authorizes the turn's tool calls", %{id: id} do
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "increment", ToolPolicy.allow_all())

    deny = ToolPolicy.deny_all(:no_grant)
    assert {:ok, {:ok, denied, _}} = prompt(id, "reset", deny)
    assert denied =~ "denied"
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "get", deny)

    # The default policy also refuses the sensitive reset; allow_all grants it.
    assert {:ok, {:ok, refused, _}} = prompt(id, "reset", ToolPolicy.deny_sensitive())
    assert refused =~ "denied"
    assert {:ok, {:ok, "count: 0", _}} = prompt(id, "reset", ToolPolicy.allow_all())
  end

  test "cancel kills a held turn and the agent answers the next prompt", %{id: id} do
    ref = make_ref()
    {held, worker} = hold(id, ref)
    worker_mon = Process.monitor(worker)

    # The call-form cancel answers :ok only once the turn's process is dead.
    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :cancelled}} = Task.await(held)

    # Idle: the turn is gone and the agent answers again.
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, ref})
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "increment", ToolPolicy.allow_all())
  end

  test "release ends a held turn with a reply", %{id: id} do
    {held, worker} = hold(id, make_ref())
    worker_mon = Process.monitor(worker)

    assert {:ok, {:ok, "released 1", _}} = prompt(id, "release", ToolPolicy.allow_all())
    assert {:ok, {:ok, "released", @usage}} = Task.await(held)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :normal}, 5_000
  end

  test "a cancel sent with from: kills the held turn", %{id: id} do
    ref = make_ref()
    {held, worker} = hold(id, ref)
    worker_mon = Process.monitor(worker)

    assert :ok = Comm.send(id, {:acp_cancel, ref}, from: "editor")
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :cancelled}} = Task.await(held)
  end

  test "a prompt whose caller times out is cancelled", %{id: id} do
    ref = make_ref()
    [{session, _}] = Registry.lookup(Raxol.Agent.Registry, id)

    # With the session suspended nothing can answer the hold, so a zero
    # timeout expires deterministically: the call casts the prompt, then its
    # cancel, and returns. The session sees both, in that order, on resume.
    :ok = :sys.suspend(session)

    assert {:error, :timeout} =
             Comm.call(id, {:acp_prompt, "hold", authorizing(self())}, 0, ref: ref)

    :ok = :sys.resume(session)

    # The abandoned prompt is answered as cancelled (a stray reply), the turn
    # is gone, and the agent saw the cancel: it holds nothing.
    assert_receive {:agent_reply, ^ref, {:error, :cancelled}}, 5_000
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, ref})
    assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", ToolPolicy.allow_all())
    refute_received {:authorizing, Counter.Hold, _worker}
  end

  test "a prompt needs an explicit timeout", %{id: id} do
    allow = ToolPolicy.allow_all()

    # Refused before it reaches the agent: the hold below is never taken.
    assert {:error, :timeout_required} = Comm.call(id, {:acp_prompt, "hold", allow})
    assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", allow)

    # Other messages keep the default timeout.
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, make_ref()})
  end

  test "a prompt whose caller goes down is cancelled", %{id: id} do
    ref = make_ref()
    approver = authorizing(self())
    caller = spawn(fn -> Comm.call(id, {:acp_prompt, "hold", approver}, 30_000, ref: ref) end)
    assert_receive {:authorizing, Counter.Hold, worker}, 5_000
    worker_mon = Process.monitor(worker)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, ref})
    assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", ToolPolicy.allow_all())
  end

  test "call/4 refuses a ref that is not a reference", %{id: id} do
    assert_raise ArgumentError, fn ->
      Comm.call(id, {:acp_prompt, "get", ToolPolicy.allow_all()}, 5_000, ref: "turn-1")
    end
  end

  test "cancel during a blocked approver kills the ask and changes nothing", %{id: id} do
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "increment", ToolPolicy.allow_all())
    ref = make_ref()
    {held, asker} = asking(id, "reset", ref)
    asker_mon = Process.monitor(asker)

    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:DOWN, ^asker_mon, :process, ^asker, :killed}, 5_000
    assert {:ok, {:error, :cancelled}} = Task.await(held)

    # The ask died with its turn, so the reset never reached the count.
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "get", ToolPolicy.allow_all())
  end

  test "the agent answers while an approver blocks", %{id: id} do
    {held, asker} = asking(id, "increment", make_ref())

    assert {:ok, %{count: 0}} = Session.get_model(id)
    assert {:ok, {:ok, "count: 0", _}} = prompt(id, "get", ToolPolicy.allow_all())

    send(asker, :approve)
    assert {:ok, {:ok, "count: 1", _}} = Task.await(held)
  end

  test "an approver that raises fails only its turn", %{id: id} do
    ref = make_ref()
    raising = fn _tool, _params, _context -> raise "approver failed" end

    assert {:ok, {:error, :turn_failed}} =
             Comm.call(id, {:acp_prompt, "reset", raising}, 5_000, ref: ref)

    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, ref})
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "increment", ToolPolicy.allow_all())
  end

  test "a failed turn logs the reason's shape, not its content", %{id: id} do
    raising = fn _tool, _params, _context -> raise "token=sk-live-123" end

    log =
      capture_log(fn ->
        assert {:ok, {:error, :turn_failed}} =
                 Comm.call(id, {:acp_prompt, "reset", raising}, 5_000)
      end)

    assert log =~ "failed: RuntimeError"
    refute log =~ "sk-live-123"
  end

  test "a turn killed from outside fails and the agent drops it", %{id: id} do
    {held, worker} = hold(id, make_ref())

    Process.exit(worker, :kill)
    assert {:ok, {:error, :turn_failed}} = Task.await(held)

    # The agent saw the turn end, so release finds nothing held.
    assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", ToolPolicy.allow_all())
  end

  test "a standalone session answers its turns when its agent goes down", %{base: base} do
    id = "standalone-#{uniq()}"

    start_supervised!(
      {Session, app_module: Counter, id: id, session_id: id, journal_opts: [base_dir: base]}
    )

    ref = make_ref()
    {held, worker} = hold(id, ref)
    worker_mon = Process.monitor(worker)
    [{lifecycle, _}] = Registry.lookup(Raxol.Agent.Registry, {:lifecycle, id})

    Process.exit(lifecycle, :kill)
    assert {:ok, {:error, :agent_down}} = Task.await(held)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, ref})
  end

  test "a change that no live turn sent is dropped", %{id: id} do
    assert {:ok, {:ok, "count: 1", _}} = prompt(id, "increment", ToolPolicy.allow_all())
    [{lifecycle, _}] = Registry.lookup(Raxol.Agent.Registry, {:lifecycle, id})
    %{dispatcher_pid: agent} = GenServer.call(lifecycle, :get_full_state)

    send(agent, {:command_result, {:counter_change, make_ref(), %{set: 0}}})

    # Same sender, so the forged change is handled before this call.
    assert {:ok, %{count: 1}} = GenServer.call(agent, :get_model)
  end

  test "a prompt sent with from: is still a turn the session owns", %{id: id} do
    ref = make_ref()

    :ok =
      Comm.send(id, {:call, self(), ref, {:acp_prompt, "hold", authorizing(self())}},
        from: "editor"
      )

    assert_receive {:authorizing, Counter.Hold, worker}, 5_000
    worker_mon = Process.monitor(worker)

    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert_receive {:agent_reply, ^ref, {:error, :cancelled}}, 5_000
    refute_received {:acp_run, ^ref, _fun}
  end

  test "a turn-failed report with the caller's ref changes nothing", %{id: id} do
    ref = make_ref()
    {held, worker} = hold(id, ref)
    [{session, _}] = Registry.lookup(Raxol.Agent.Registry, id)
    # The worker's one link is the turn's owner.
    {:links, [owner]} = Process.info(worker, :links)

    send(session, {:acp_turn_failed, ref, owner})
    send(session, {:acp_turn_failed, ref, self()})

    # Same sender, so the session has handled both reports before this call.
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, make_ref()})
    assert Process.alive?(worker)
    assert {:ok, {:ok, "released 1", _}} = prompt(id, "release", ToolPolicy.allow_all())
    assert {:ok, {:ok, "released", _}} = Task.await(held)
  end

  test "a turn-failed report for a turn not yet run leaves the session up", %{id: id} do
    ref = make_ref()
    [{session, _}] = Registry.lookup(Raxol.Agent.Registry, id)
    session_mon = Process.monitor(session)
    [{lifecycle, _}] = Registry.lookup(Raxol.Agent.Registry, {:lifecycle, id})
    %{dispatcher_pid: agent} = GenServer.call(lifecycle, :get_full_state)

    # The suspended agent cannot run the turn, so it stays registered with no
    # process while the reports arrive.
    :ok = :sys.suspend(agent)
    :ok = Comm.send(id, {:call, self(), ref, {:acp_prompt, "hold", authorizing(self())}})
    send(session, {:acp_turn_failed, ref, self()})
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, make_ref()})
    :ok = :sys.resume(agent)

    assert_receive {:authorizing, Counter.Hold, _worker}, 5_000
    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:agent_reply, ^ref, {:error, :cancelled}}, 5_000
    refute_received {:DOWN, ^session_mon, :process, ^session, _reason}
  end

  test "the caller's ref cancels a turn but cannot answer or steer it", %{id: id} do
    ref = make_ref()
    {held, worker} = hold(id, ref)
    worker_mon = Process.monitor(worker)
    [{session, _}] = Registry.lookup(Raxol.Agent.Registry, id)

    send(session, {:agent_reply, ref, {:ok, "forged", @usage}})
    send(session, {:acp_turn_message, ref, :release})

    # Same sender, so the session has handled both before this call.
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, make_ref()})
    assert Process.alive?(worker)

    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :cancelled}} = Task.await(held)
  end

  test "a run_turn sent with the caller's ref runs nothing", %{id: id} do
    ref = make_ref()
    test = self()
    [{session, _}] = Registry.lookup(Raxol.Agent.Registry, id)
    [{lifecycle, _}] = Registry.lookup(Raxol.Agent.Registry, {:lifecycle, id})
    %{dispatcher_pid: agent} = GenServer.call(lifecycle, :get_full_state)

    forged = fn ->
      send(test, :forged_work_ran)
      {:ok, "forged", @usage}
    end

    # The suspended agent cannot start its own turn before the forged one.
    :ok = :sys.suspend(agent)
    :ok = Comm.send(id, {:call, self(), ref, {:acp_prompt, "hold", authorizing(self())}})
    send(session, {:acp_run, ref, forged})
    assert {:ok, {:error, :not_found}} = Comm.call(id, {:acp_cancel, make_ref()})
    :ok = :sys.resume(agent)

    # The agent's own turn runs, and the forged work never did.
    assert_receive {:authorizing, Counter.Hold, _worker}, 5_000
    assert {:ok, :ok} = Comm.call(id, {:acp_cancel, ref})
    assert_receive {:agent_reply, ^ref, {:error, :cancelled}}, 5_000
    refute_received :forged_work_ran
  end

  test "an inline reply ends a running turn and the agent sees the cancel", %{base: base} do
    id = "inline-#{uniq()}"

    {:ok, _sup} =
      Session.Supervisor.start_session(InlineAfterRun,
        id: id,
        session_id: id,
        journal_opts: [base_dir: base]
      )

    approver = authorizing(self())
    running = Task.async(fn -> Comm.call(id, {:acp_prompt, "run", approver}, 30_000) end)
    assert_receive {:authorizing, "run", worker}, 5_000
    worker_mon = Process.monitor(worker)

    # The agent answers the running turn before its own prompt, so the turn's
    # process is dead and its cancel sent to the agent once this returns.
    assert {:ok, {:ok, "done", _}} = Comm.call(id, {:acp_prompt, "answer", approver}, 5_000)
    assert {:ok, {:ok, "answered inline", _}} = Task.await(running)
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, %{running: turn_ref, cancelled: [turn_ref]}} = Session.get_model(id)
  end

  test "a cancel call sent with from: kills the held turn and answers", %{id: id} do
    ref = make_ref()
    {held, worker} = hold(id, ref)
    worker_mon = Process.monitor(worker)
    call_ref = make_ref()

    :ok = Comm.send(id, {:call, self(), call_ref, {:acp_cancel, ref}}, from: "editor")
    assert_receive {:agent_reply, ^call_ref, :ok}, 5_000
    assert_receive {:DOWN, ^worker_mon, :process, ^worker, :killed}, 5_000
    assert {:ok, {:error, :cancelled}} = Task.await(held)
  end

  test "a malformed prompt envelope is dropped without logging its text", %{id: id} do
    allow = ToolPolicy.allow_all()
    text = "hold token=sk-live-777"

    log =
      capture_log(fn ->
        :ok = Comm.send(id, {:call, :not_a_pid, make_ref(), {:acp_prompt, text, allow}})
        :ok = Comm.send(id, {:call, self(), 123, {:acp_prompt, text, allow}}, from: "editor")
        # Same sender, so both were handled before this prompt.
        assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", allow)
      end)

    assert log =~ "dropped a prompt"
    refute log =~ "sk-live-777"
  end

  test "a denied hold is not kept", %{id: id} do
    deny = ToolPolicy.deny_all(:no_grant)

    for _ <- 1..3 do
      assert {:ok, {:ok, denied, _}} = prompt(id, "hold", deny)
      assert denied =~ "denied"
    end

    assert {:ok, {:ok, "released 0", _}} = prompt(id, "release", ToolPolicy.allow_all())
  end

  # Start a `hold` prompt and return once its action is being authorized,
  # i.e. the turn is in flight in `worker`.
  defp hold(id, ref) do
    approver = authorizing(self())
    held = Task.async(fn -> Comm.call(id, {:acp_prompt, "hold", approver}, 30_000, ref: ref) end)
    assert_receive {:authorizing, Counter.Hold, worker}, 5_000
    {held, worker}
  end

  # Start a `text` prompt whose approver blocks until it receives `:approve`;
  # return once the approver is asking, in process `asker`.
  defp asking(id, text, ref) do
    test = self()

    approver = fn _tool, _params, _context ->
      send(test, {:asking, self()})

      receive do
        :approve -> :ok
      end
    end

    held = Task.async(fn -> Comm.call(id, {:acp_prompt, text, approver}, 30_000, ref: ref) end)
    assert_receive {:asking, asker}, 5_000
    {held, asker}
  end

  # An approver that allows every call and tells `test` which process asks.
  defp authorizing(test) do
    fn tool, _params, _context ->
      send(test, {:authorizing, tool, self()})
      :ok
    end
  end

  defp prompt(id, text, approver), do: Comm.call(id, {:acp_prompt, text, approver}, 5_000)

  defp uniq, do: System.unique_integer([:positive])

  defp ensure_running({mod, opts}) do
    case mod.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end
  end
end
