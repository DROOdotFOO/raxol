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

    start_supervised!(
      {Raxol.Broker.Supervisor,
       name: :"broker_sup_#{System.unique_integer([:positive])}",
       journal: [name: journal, path: path]}
    )

    first = Process.whereis(journal)
    ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}

    second = wait_for_restart(journal, first)
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
    Process.exit(Process.whereis(journal), :kill)

    wait_for_restart(executor, old_executor)
    assert Executor.parked(executor) == []
    assert Journal.open_groups(journal) == {:ok, []}
    assert OrderServer.calls(server, "place_") == []
  end

  defp wait_for_restart(name, old) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        receive after: (10 -> wait_for_restart(name, old))
    end
  end
end
