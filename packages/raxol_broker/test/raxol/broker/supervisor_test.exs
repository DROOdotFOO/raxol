defmodule Raxol.Broker.SupervisorTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Journal

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

  defp wait_for_restart(name, old) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        receive after: (10 -> wait_for_restart(name, old))
    end
  end
end
