defmodule Raxol.Payments.CheckpointTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Checkpoint.ETS

  describe "nil store" do
    test "fetch is a miss, put and delete are no-ops" do
      assert :error = Checkpoint.fetch(nil, "k")
      assert :ok = Checkpoint.put(nil, "k", %{intent_id: "i"})
      assert :ok = Checkpoint.delete(nil, "k")
    end
  end

  describe "ETS store" do
    test "round-trips a record" do
      store = ETS.new()
      assert :error = Checkpoint.fetch(store, "k")

      assert :ok = Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
      assert {:ok, %{intent_id: "int_1", status: :dispatched}} = Checkpoint.fetch(store, "k")

      assert :ok = Checkpoint.delete(store, "k")
      assert :error = Checkpoint.fetch(store, "k")
    end

    test "put overwrites the prior record" do
      store = ETS.new()
      Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
      Checkpoint.put(store, "k", %{intent_id: "int_1", status: :in_flight})

      assert {:ok, %{status: :in_flight}} = Checkpoint.fetch(store, "k")
    end

    test "put_new has exactly one owner under concurrent acquisition" do
      store = ETS.new()
      parent = self()

      tasks =
        for owner <- 1..32 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Checkpoint.put_new(store, "shared", %{owner: owner})
            end
          end)
        end

      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}
          pid
        end

      Enum.each(pids, &send(&1, :go))
      results = Task.await_many(tasks)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :exists})) == 31
      assert {:ok, %{owner: owner}} = Checkpoint.fetch(store, "shared")
      assert owner in 1..32
    end

    test "sweep removes only expired records" do
      store = ETS.new()
      Checkpoint.put(store, "expired", %{expires_at: 10})
      Checkpoint.put(store, "fresh", %{expires_at: 12})
      Checkpoint.put(store, "in_flight", %{status: :dispatched})

      assert :ok = Checkpoint.sweep_expired(store, 10)
      assert :error = Checkpoint.fetch(store, "expired")
      assert {:ok, %{expires_at: 12}} = Checkpoint.fetch(store, "fresh")
      assert {:ok, %{status: :dispatched}} = Checkpoint.fetch(store, "in_flight")
    end

    test "a named table is shared by name and reused on re-create" do
      assert {ETS, :checkpoint_named_test} = ETS.new(:checkpoint_named_test)
      Checkpoint.put({ETS, :checkpoint_named_test}, "k", %{intent_id: "int_1"})

      # Re-creating by the same name returns the existing table, not a fresh one.
      assert {ETS, :checkpoint_named_test} = ETS.new(:checkpoint_named_test)
      assert {:ok, %{intent_id: "int_1"}} = Checkpoint.fetch({ETS, :checkpoint_named_test}, "k")
    end

    test "the table survives the process that wrote it" do
      store = ETS.new()
      Checkpoint.put(store, "k", %{intent_id: "int_1"})

      task = Task.async(fn -> Checkpoint.fetch(store, "k") end)
      assert {:ok, %{intent_id: "int_1"}} = Task.await(task)
    end
  end

  describe "derive_key/1" do
    test "is stable for the same fields" do
      fields = ["0xwallet", 8453, 42_161, "0xusdc", "0xusdc", "500000", "stealth", nil, nil]
      assert Checkpoint.derive_key(fields) == Checkpoint.derive_key(fields)
    end

    test "differs when any field differs" do
      base = ["0xwallet", 8453, 42_161, "0xusdc", "0xusdc", "500000", "stealth", nil, nil]
      diff_amount = List.replace_at(base, 5, "400000")

      refute Checkpoint.derive_key(base) == Checkpoint.derive_key(diff_amount)
    end

    test "is a lowercase hex digest" do
      assert Checkpoint.derive_key(["a", "b"]) =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
