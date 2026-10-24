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

  alias Raxol.Agent.Comm
  alias Raxol.Agent.Reference.Counter
  alias Raxol.Agent.Session
  alias Raxol.Agent.ToolPolicy

  @usage %{input_tokens: 0, output_tokens: 0}

  setup do
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

    %{id: id}
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

  # Start a `hold` prompt and return once its action is being authorized,
  # i.e. the turn is in flight in `worker`.
  defp hold(id, ref) do
    test = self()

    approver = fn tool, _params, _context ->
      send(test, {:authorizing, tool, self()})
      :ok
    end

    held = Task.async(fn -> Comm.call(id, {:acp_prompt, "hold", approver}, 30_000, ref: ref) end)
    assert_receive {:authorizing, Counter.Hold, worker}, 5_000
    {held, worker}
  end

  defp prompt(id, text, approver), do: Comm.call(id, {:acp_prompt, text, approver})

  defp uniq, do: System.unique_integer([:positive])

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
