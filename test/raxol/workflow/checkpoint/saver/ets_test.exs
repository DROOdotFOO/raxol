defmodule Raxol.Workflow.Checkpoint.Saver.EtsTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver.Ets

  setup do
    table = :"ets_test_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, config: %{table: table}}
  end

  defp make_cp(thread_id, step, state \\ %{}) do
    Checkpoint.new(thread_id: thread_id, step: step, state: state)
  end

  describe "put + get_latest" do
    test "writes a checkpoint and reads it back", %{config: config} do
      cp = make_cp("thr", 0, %{a: 1})
      assert :ok = Ets.put(config, "thr", cp)
      assert {:ok, ^cp} = Ets.get_latest(config, "thr")
    end

    test "latest is the highest step", %{config: config} do
      Ets.put(config, "thr", make_cp("thr", 0))
      Ets.put(config, "thr", make_cp("thr", 1))
      Ets.put(config, "thr", make_cp("thr", 2))

      assert {:ok, %Checkpoint{step: 2}} = Ets.get_latest(config, "thr")
    end

    test "get_latest returns :not_found for unknown thread", %{config: config} do
      assert {:error, :not_found} = Ets.get_latest(config, "ghost")
    end

    test "put is append-only: second write to same (thread, step) is no-op", %{
      config: config
    } do
      original = make_cp("thr", 0, %{value: :first})
      attempted_overwrite = make_cp("thr", 0, %{value: :second})

      Ets.put(config, "thr", original)
      Ets.put(config, "thr", attempted_overwrite)

      assert {:ok, %Checkpoint{state: %{value: :first}}} =
               Ets.get_latest(config, "thr")
    end
  end

  describe "list" do
    test "returns checkpoints in newest-first order", %{config: config} do
      for step <- 0..4, do: Ets.put(config, "thr", make_cp("thr", step))

      assert {:ok, listed} = Ets.list(config, "thr", 10)
      steps = Enum.map(listed, & &1.step)
      assert steps == [4, 3, 2, 1, 0]
    end

    test "respects the limit", %{config: config} do
      for step <- 0..9, do: Ets.put(config, "thr", make_cp("thr", step))

      assert {:ok, [%{step: 9}, %{step: 8}, %{step: 7}]} =
               Ets.list(config, "thr", 3)
    end

    test "returns empty for unknown thread", %{config: config} do
      assert {:ok, []} = Ets.list(config, "ghost", 5)
    end

    test "isolates threads", %{config: config} do
      Ets.put(config, "thr_a", make_cp("thr_a", 0, %{which: :a}))
      Ets.put(config, "thr_b", make_cp("thr_b", 0, %{which: :b}))

      assert {:ok, [%{state: %{which: :a}}]} = Ets.list(config, "thr_a", 5)
      assert {:ok, [%{state: %{which: :b}}]} = Ets.list(config, "thr_b", 5)
    end
  end

  describe "delete_thread" do
    test "removes all checkpoints for a thread", %{config: config} do
      for step <- 0..3, do: Ets.put(config, "thr", make_cp("thr", step))

      assert :ok = Ets.delete_thread(config, "thr")
      assert {:ok, []} = Ets.list(config, "thr", 10)
      assert {:error, :not_found} = Ets.get_latest(config, "thr")
    end

    test "does not touch other threads", %{config: config} do
      Ets.put(config, "keep", make_cp("keep", 0))
      Ets.put(config, "drop", make_cp("drop", 0))

      Ets.delete_thread(config, "drop")

      assert {:ok, %Checkpoint{}} = Ets.get_latest(config, "keep")
      assert {:error, :not_found} = Ets.get_latest(config, "drop")
    end

    test "is idempotent for unknown thread", %{config: config} do
      assert :ok = Ets.delete_thread(config, "ghost")
    end
  end
end
