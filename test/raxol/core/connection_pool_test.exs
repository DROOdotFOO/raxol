defmodule Raxol.Core.ConnectionPoolTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.ConnectionPool

  # max_overflow: 0 so an unreturned connection shows up as a refused
  # checkout rather than being papered over by a fresh overflow connection.
  defp start_pool!(opts) do
    name = :"connection_pool_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ConnectionPool, Keyword.merge([name: name, max_overflow: 0], opts)}
    )

    name
  end

  describe "transaction/3" do
    test "sequential transactions on a size-1 pool each get the connection back" do
      pool = start_pool!(pool_size: 1)

      assert ConnectionPool.transaction(pool, fn _conn -> :first end) == :first

      assert ConnectionPool.transaction(pool, fn _conn -> :second end) ==
               :second

      assert %{busy: 0, available: 1} = ConnectionPool.stats(pool)
    end

    test "a raising transaction still returns its connection" do
      pool = start_pool!(pool_size: 1)

      assert {:error, %RuntimeError{message: "boom"}} =
               ConnectionPool.transaction(pool, fn _conn -> raise "boom" end)

      assert ConnectionPool.transaction(pool, fn _conn -> :after end) == :after
      assert %{busy: 0, available: 1} = ConnectionPool.stats(pool)
    end

    test "a blocked transaction does not stall other pool operations" do
      pool = start_pool!(pool_size: 2)
      test_pid = self()

      holder =
        spawn(fn ->
          ConnectionPool.transaction(pool, fn conn ->
            send(test_pid, {:holding, conn})

            receive do
              :release -> :ok
            end
          end)

          send(test_pid, :released)
        end)

      assert_receive {:holding, held}

      # The call timeout is the hang bound: a pool serialized behind the
      # holder's callback exits here instead of answering.
      other = ConnectionPool.transaction(pool, fn conn -> conn end, 500)
      refute other == held
      assert %{busy: 1, available: 1} = ConnectionPool.stats(pool)

      send(holder, :release)
      assert_receive :released
      assert %{busy: 0, available: 2} = ConnectionPool.stats(pool)
    end
  end

  describe "caller death" do
    test "a connection checked out by a process that dies goes back to the pool" do
      pool = start_pool!(pool_size: 1)
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, _conn} = ConnectionPool.checkout(pool)
          send(test_pid, :checked_out)
          Process.sleep(:infinity)
        end)

      assert_receive :checked_out
      assert %{busy: 1} = ConnectionPool.stats(pool)

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      # The pool monitors the same pid, so its own DOWN was enqueued during
      # that termination -- ahead of this call, which is therefore a barrier.
      assert ConnectionPool.transaction(pool, fn _conn -> :reclaimed end) ==
               :reclaimed

      assert %{busy: 0, available: 1} = ConnectionPool.stats(pool)
    end
  end
end
