defmodule Raxol.Payments.Checkpoint.ContextStoreTest do
  # async: false -- Raxol.Agent.ContextStore is a single global named ETS table.
  use ExUnit.Case, async: false

  alias Raxol.Agent.ContextStore
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Checkpoint.ContextStore, as: Bridge

  @ids [:cp_bridge_a, :cp_bridge_b, :cp_bridge_crash]

  setup do
    ContextStore.init()
    on_exit(fn -> Enum.each(@ids, &ContextStore.delete/1) end)
    :ok
  end

  test "round-trips a record" do
    store = Bridge.new(:cp_bridge_a)

    assert :error = Checkpoint.fetch(store, "k")
    assert :ok = Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
    assert {:ok, %{intent_id: "int_1", status: :dispatched}} = Checkpoint.fetch(store, "k")
    assert :ok = Checkpoint.delete(store, "k")
    assert :error = Checkpoint.fetch(store, "k")
  end

  test "put overwrites the prior record" do
    store = Bridge.new(:cp_bridge_a)
    Checkpoint.put(store, "k", %{intent_id: "int_1", status: :dispatched})
    Checkpoint.put(store, "k", %{intent_id: "int_1", status: :in_flight})

    assert {:ok, %{status: :in_flight}} = Checkpoint.fetch(store, "k")
  end

  test "put_new has one owner under concurrent acquisition" do
    store = Bridge.new(:cp_bridge_a)
    parent = self()

    tasks =
      for owner <- 1..16 do
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
    assert Enum.count(results, &(&1 == {:error, :exists})) == 15
    assert {:ok, %{owner: owner}} = Checkpoint.fetch(store, "shared")
    assert owner in 1..16
  end

  test "a dead lock holder cannot leak the ContextStore acquisition lock" do
    store = Bridge.new(:cp_bridge_a)
    parent = self()
    resource = {Bridge, :cp_bridge_a}

    holder =
      spawn(fn ->
        :global.set_lock({resource, self()}, [node()])
        send(parent, {:locked, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:locked, ^holder}
    ref = Process.monitor(holder)
    task = Task.async(fn -> Checkpoint.put_new(store, "after_crash", %{owner: :survivor}) end)

    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}
    assert :ok = Task.await(task)
    assert {:ok, %{owner: :survivor}} = Checkpoint.fetch(store, "after_crash")
  end

  test "sweep removes only expired records" do
    store = Bridge.new(:cp_bridge_a)
    Checkpoint.put(store, "expired", %{expires_at: 10})
    Checkpoint.put(store, "fresh", %{expires_at: 12})

    assert :ok = Checkpoint.sweep_expired(store, 10)
    assert :error = Checkpoint.fetch(store, "expired")
    assert {:ok, %{expires_at: 12}} = Checkpoint.fetch(store, "fresh")
  end

  test "two store ids are isolated" do
    a = Bridge.new(:cp_bridge_a)
    b = Bridge.new(:cp_bridge_b)

    Checkpoint.put(a, "k", %{intent_id: "from_a"})
    Checkpoint.put(b, "k", %{intent_id: "from_b"})

    assert {:ok, %{intent_id: "from_a"}} = Checkpoint.fetch(a, "k")
    assert {:ok, %{intent_id: "from_b"}} = Checkpoint.fetch(b, "k")
  end

  test "a record survives the process that wrote it (the crash it protects against)" do
    store = Bridge.new(:cp_bridge_crash)

    {:ok, writer} = Task.start(fn -> Checkpoint.put(store, "k", %{intent_id: "int_1"}) end)
    ref = Process.monitor(writer)
    assert_receive {:DOWN, ^ref, :process, ^writer, _reason}, 1000

    # The writer is gone; the record persists in the store the test process owns,
    # the way an agent's in-flight intent outlives the crashed agent.
    assert {:ok, %{intent_id: "int_1"}} = Checkpoint.fetch(store, "k")
  end
end
