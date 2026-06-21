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
