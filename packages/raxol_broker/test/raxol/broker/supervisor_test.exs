defmodule Raxol.Broker.SupervisorTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal, PolicyFile}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.OrderServer

  @moduletag :capture_log

  setup do
    base = Path.join(System.tmp_dir!(), "broker-sup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, path: Path.join(base, "journal")}
  end

  test "restarts a crashed journal on the same path", %{path: path} do
    journal = :"broker_sup_journal_#{System.unique_integer([:positive])}"

    sup =
      start_supervised!(
        {Raxol.Broker.Supervisor,
         name: :"broker_sup_#{System.unique_integer([:positive])}",
         journal: [name: journal, path: path]}
      )

    first = Process.whereis(journal)
    second = kill_and_restart(sup, Journal, first)
    assert second != first
    assert :ok == Journal.verify(journal)
  end

  test "a journal crash restarts the executor, which closes the ASK it had parked",
       %{path: path} do
    journal = :"broker_sup_journal_#{System.unique_integer([:positive])}"
    executor = :"broker_sup_executor_#{System.unique_integer([:positive])}"
    server = OrderServer.start()
    OrderServer.warnings(server, ["halted"])
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))

    sup =
      start_supervised!(
        {Raxol.Broker.Supervisor,
         name: :"broker_sup_#{System.unique_integer([:positive])}",
         journal: [name: journal, path: path],
         executor: [
           name: executor,
           session: OrderServer.session(server),
           account_number: "ACC-1",
           policy: policy
         ]}
      )

    assert :ok = Executor.await_port(executor)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("2"), Decimal.new("125"),
        provenance: :strategy,
        id: "sup-parked"
      )

    context = %Context{
      policy: policy,
      portfolio_value: Decimal.new("100000"),
      start_of_day_value: Decimal.new("100000"),
      day_pnl: Decimal.new("0"),
      quotes: %{"AAPL" => Decimal.new("125")},
      market_session: :regular
    }

    assert {:ask, gid, _prompts} = Executor.run(executor, intent, context)
    assert {:ok, [^gid]} = Journal.open_groups(journal)

    old_executor = Process.whereis(executor)
    executor_ref = Process.monitor(old_executor)
    kill_and_restart(sup, Journal, Process.whereis(journal))
    assert_receive {:DOWN, ^executor_ref, :process, ^old_executor, _reason}
    new_executor = child(sup, Executor)
    assert is_pid(new_executor) and new_executor != old_executor
    assert :ok = Executor.await_port(executor)
    assert Executor.parked(executor) == []
    assert Journal.open_groups(journal) == {:ok, []}
    assert OrderServer.calls(server, "place_") == []
  end

  test "an executor bound to another journal is refused", %{path: path} do
    assert {:error, {:journal_mismatch, :elsewhere}} =
             Raxol.Broker.Supervisor.start_link(
               name: :"broker_sup_#{System.unique_integer([:positive])}",
               journal: [
                 name: :"broker_sup_journal_#{System.unique_integer([:positive])}",
                 path: path
               ],
               executor: [journal: :elsewhere, session: [], account_number: "ACC-1"]
             )
  end

  test "the executor's shutdown outlasts an order call" do
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))

    {:ok, {_flags, [_journal, %{shutdown: shutdown}]}} =
      Raxol.Broker.Supervisor.init(
        journal: [name: :j, path: "unused"],
        executor: [session: [], account_number: "ACC-1", policy: policy, place_timeout: 60_000]
      )

    assert is_integer(shutdown) and shutdown >= 60_000
  end

  test "an unreachable endpoint survives a journal crash and refuses runs", %{path: path} do
    journal = :"broker_sup_journal_#{System.unique_integer([:positive])}"
    executor = :"broker_sup_executor_#{System.unique_integer([:positive])}"
    server = OrderServer.start()
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))

    session =
      server
      |> OrderServer.session()
      |> Keyword.put(:resolver, fn _host, _family -> {:error, :nxdomain} end)

    sup =
      start_supervised!(
        {Raxol.Broker.Supervisor,
         name: :"broker_sup_#{System.unique_integer([:positive])}",
         journal: [name: journal, path: path],
         executor: [name: executor, session: session, account_number: "ACC-1", policy: policy]}
      )

    sup_ref = Process.monitor(sup)

    for _crash <- 1..2 do
      old_executor = child(sup, Executor)
      executor_ref = Process.monitor(old_executor)
      kill_and_restart(sup, Journal, child(sup, Journal))
      assert_receive {:DOWN, ^executor_ref, :process, ^old_executor, _reason}
    end

    refute_received {:DOWN, ^sup_ref, _, _, _}
    assert Process.alive?(sup)
    assert is_pid(child(sup, Journal))
    assert is_pid(child(sup, Executor))

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("1"), Decimal.new("125"),
        provenance: :strategy,
        id: "sup-not-ready"
      )

    assert {:error, :port_not_ready} = Executor.run(executor, intent, %Context{policy: policy})
    assert Journal.open_groups(journal) == {:ok, []}
    assert OrderServer.calls(server, "") == []
  end

  test "a client whose resolver raises leaves the executor and the root up", %{path: path} do
    journal = :"broker_sup_journal_#{System.unique_integer([:positive])}"
    executor = :"broker_sup_executor_#{System.unique_integer([:positive])}"
    server = OrderServer.start()
    {:ok, policy} = PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))
    test_pid = self()

    session =
      server
      |> OrderServer.session()
      |> Keyword.put(:resolver, fn _host, _family ->
        send(test_pid, :resolving)
        raise "resolver blew up"
      end)

    sup =
      start_supervised!(
        {Raxol.Broker.Supervisor,
         name: :"broker_sup_#{System.unique_integer([:positive])}",
         journal: [name: journal, path: path],
         executor: [
           name: executor,
           session: session,
           account_number: "ACC-1",
           policy: policy,
           reconnect_ms: 60_000
         ]}
      )

    sup_ref = Process.monitor(sup)
    pid = child(sup, Executor)
    executor_ref = Process.monitor(pid)

    # The client dies mid-connect: its EXIT reaches the executor while the
    # connect task still waits on it. The long backoff keeps this one death.
    assert_receive :resolving, 5_000
    %{connect: %Task{}, port: {_mod, %{pid: client}}} = :sys.get_state(pid)
    client_ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^client_ref, :process, ^client, :killed}
    assert %{connect: nil, port: nil, port_status: {:down, _}} = :sys.get_state(pid)

    refute_received {:DOWN, ^executor_ref, _, _, _}
    refute_received {:DOWN, ^sup_ref, _, _, _}
    assert child(sup, Executor) == pid
    assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
    assert OrderServer.calls(server, "") == []
  end

  # Kills the `module` child, waits for it to go down, then reads the restarted
  # child. The supervisor restarts while handling the EXIT, so the call that
  # follows the :DOWN sees the new pid without polling.
  defp kill_and_restart(sup, module, old) do
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = child(sup, module)
    assert is_pid(new) and new != old
    new
  end

  defp child(sup, module) do
    Enum.find_value(Supervisor.which_children(sup), fn
      {_id, pid, _type, [^module]} -> pid
      _other -> nil
    end)
  end
end
