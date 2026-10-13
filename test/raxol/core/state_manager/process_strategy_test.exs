defmodule Raxol.Core.StateManager.ProcessStrategyTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.StateManager.ProcessStrategy

  defp unique_id, do: :"test_#{System.unique_integer([:positive, :monotonic])}"

  defp start_and_cleanup(state_id, initial_state) do
    {:ok, ^state_id} = ProcessStrategy.start(state_id, initial_state, [])

    on_exit(fn ->
      try do
        case Process.whereis(ProcessStrategy.process_name(state_id)) do
          nil -> :ok
          pid -> GenServer.stop(pid, :normal, 5_000)
        end
      catch
        :exit, _ -> :ok
      end
    end)

    state_id
  end

  describe "start/3" do
    test "creates a process that can be found by its registered name" do
      state_id = unique_id()
      start_and_cleanup(state_id, %{counter: 0})

      pid = Process.whereis(ProcessStrategy.process_name(state_id))
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  describe "get/1" do
    test "returns initial state" do
      state_id = unique_id()
      start_and_cleanup(state_id, %{counter: 0})

      assert {:ok, %{counter: 0}} = ProcessStrategy.get(state_id)
    end

    test "returns {:error, :state_not_found} for non-existent state_id" do
      assert {:error, :state_not_found} = ProcessStrategy.get(:nonexistent_state_id)
    end
  end

  describe "update/2" do
    test "applies function and returns new state" do
      state_id = unique_id()
      start_and_cleanup(state_id, %{counter: 0})

      assert {:ok, %{counter: 1}} =
               ProcessStrategy.update(state_id, fn state ->
                 %{state | counter: state.counter + 1}
               end)
    end

    test "get after update shows new state" do
      state_id = unique_id()
      start_and_cleanup(state_id, %{counter: 0})

      {:ok, _} =
        ProcessStrategy.update(state_id, fn state ->
          %{state | counter: 42}
        end)

      assert {:ok, %{counter: 42}} = ProcessStrategy.get(state_id)
    end

    test "returns {:error, :state_not_found} for non-existent state_id" do
      assert {:error, :state_not_found} =
               ProcessStrategy.update(:nonexistent_state_id, fn s -> s end)
    end
  end

  describe "process_name/1" do
    test "returns expected atom" do
      assert ProcessStrategy.process_name(:my_state) == :raxol_managed_state_my_state
      assert ProcessStrategy.process_name("foo") == :raxol_managed_state_foo
    end
  end

  describe "independent states" do
    test "multiple states don't interfere with each other" do
      id_a = unique_id()
      id_b = unique_id()

      start_and_cleanup(id_a, %{value: :alpha})
      start_and_cleanup(id_b, %{value: :beta})

      assert {:ok, %{value: :alpha}} = ProcessStrategy.get(id_a)
      assert {:ok, %{value: :beta}} = ProcessStrategy.get(id_b)

      {:ok, _} = ProcessStrategy.update(id_a, fn state -> %{state | value: :updated_alpha} end)

      assert {:ok, %{value: :updated_alpha}} = ProcessStrategy.get(id_a)
      assert {:ok, %{value: :beta}} = ProcessStrategy.get(id_b)
    end
  end
end
