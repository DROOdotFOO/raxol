defmodule Raxol.Agent.Test.EtsTablesTest do
  # Not async: each test owns a uniquely named table, but `:protected` ownership
  # is asserted across processes and the names are global to the VM.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Test.EtsTables

  test "deleting a live table the caller owns succeeds" do
    table = unique(:owned)
    :ets.new(table, [:set, :public, :named_table])

    assert EtsTables.drop(table) == :ok
    assert :ets.whereis(table) == :undefined
  end

  test "deleting a table that is already gone is the goal state, not an error" do
    table = unique(:absent)

    assert :ets.whereis(table) == :undefined
    assert EtsTables.drop(table) == :ok
  end

  test "a table whose owner has exited is tolerated even when whereis still resolves" do
    # The race the helper exists for: the owner dies, ERTS reaps the table
    # concurrently, and the delete lands on either side of the reap. Both
    # outcomes must be :ok.
    table = unique(:reaped)

    owner =
      spawn(fn ->
        :ets.new(table, [:set, :public, :named_table])
        receive do: (:die -> :ok)
      end)

    ref = Process.monitor(owner)
    send(owner, :die)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

    assert EtsTables.drop(table) == :ok
  end

  test "a live table that refuses the delete is reraised, not swallowed" do
    # `:protected` is the case the rescue's else branch defends against: a
    # non-owner delete raises and the table is still there afterwards. No
    # adapter in this repo does this today, so without this test the branch
    # that distinguishes the helper from `rescue -> :ok` is unverified.
    table = unique(:protected)
    test_pid = self()

    owner =
      spawn_link(fn ->
        :ets.new(table, [:set, :protected, :named_table])
        send(test_pid, :created)
        receive do: (:die -> :ok)
      end)

    assert_receive :created, 1_000

    assert_raise ArgumentError, fn -> EtsTables.drop(table) end
    assert :ets.whereis(table) != :undefined

    send(owner, :die)
  end

  test "a non-atom is rejected at the call site rather than inside the rescue" do
    # Without the is_atom guard, `:ets.delete/1` raises and then the rescue's
    # own `:ets.whereis/1` raises a second, different ArgumentError, discarding
    # the original stacktrace and blaming the helper.
    tid = :ets.new(:anonymous, [:set])

    assert_raise FunctionClauseError, fn -> EtsTables.drop(tid) end

    :ets.delete(tid)
  end

  test "a list drops every table" do
    tables = [unique(:list_a), unique(:list_b)]
    Enum.each(tables, &:ets.new(&1, [:set, :public, :named_table]))

    assert EtsTables.drop(tables) == :ok
    assert Enum.all?(tables, &(:ets.whereis(&1) == :undefined))
  end

  defp unique(prefix),
    do: :"ets_tables_test_#{prefix}_#{System.unique_integer([:positive])}"
end
