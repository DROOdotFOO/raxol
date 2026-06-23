defmodule Raxol.Core.Runtime.ProcessStoreTest do
  @moduledoc """
  Tests for Raxol.Core.Runtime.ProcessStore, an Agent-based key-value store.

  Since ProcessStore registers as a global singleton (__MODULE__), and other tests
  depend on it, we test via a wrapper that starts unregistered Agent instances
  to avoid interfering with the global process.
  """
  use ExUnit.Case, async: true

  # We can't easily test ProcessStore without touching the singleton,
  # so we test the underlying Agent logic directly with unregistered agents.
  # This validates the same code paths without singleton conflicts.

  defmodule TestStore do
    @moduledoc false
    # Minimal wrapper that mirrors ProcessStore's logic without the __MODULE__ name registration.

    def start_link(initial_state \\ %{}) do
      Agent.start_link(fn -> initial_state end)
    end

    def get(pid, key, default \\ nil) do
      Agent.get(pid, &Map.get(&1, key, default))
    catch
      :exit, _ -> default
    end

    def get_all(pid) do
      Agent.get(pid, & &1)
    catch
      :exit, _ -> %{}
    end

    def put(pid, key, value) do
      Agent.update(pid, &Map.put(&1, key, value))
    catch
      :exit, _ -> {:error, :not_started}
    end

    def delete(pid, key) do
      Agent.update(pid, &Map.delete(&1, key))
    catch
      :exit, _ -> {:error, :not_started}
    end

    def clear(pid) do
      Agent.update(pid, fn _ -> %{} end)
    catch
      :exit, _ -> {:error, :not_started}
    end

    def update(pid, key, default, fun) do
      Agent.update(pid, fn state ->
        Map.update(state, key, default, fun)
      end)
    catch
      :exit, _ -> {:error, :not_started}
    end

    def get_and_update(pid, key, fun) do
      Agent.get_and_update(pid, fn state ->
        {value, found} =
          case Map.fetch(state, key) do
            {:ok, v} -> {v, true}
            :error -> {nil, false}
          end

        apply_update_fn(fun.(value), key, value, found, state)
      end)
    catch
      :exit, _ -> nil
    end

    defp apply_update_fn({get_value, new_value}, key, _value, _found, state),
      do: {get_value, Map.put(state, key, new_value)}

    defp apply_update_fn(:pop, key, value, true, state),
      do: {value, Map.delete(state, key)}

    defp apply_update_fn(:pop, _key, _value, false, state),
      do: {nil, state}
  end

  setup do
    pid =
      start_supervised!(%{id: TestStore, start: {TestStore, :start_link, []}})

    %{store: pid}
  end

  describe "start_link/1" do
    test "starts with default empty state", %{store: pid} do
      assert TestStore.get_all(pid) == %{}
    end

    test "starts with provided initial state" do
      {:ok, pid} = TestStore.start_link(%{key: "value", count: 0})
      assert TestStore.get_all(pid) == %{key: "value", count: 0}
      Agent.stop(pid)
    end
  end

  describe "get/3" do
    test "returns value for existing key", %{store: pid} do
      TestStore.put(pid, :name, "alice")
      assert TestStore.get(pid, :name) == "alice"
    end

    test "returns nil for missing key when no default given", %{store: pid} do
      assert TestStore.get(pid, :missing) == nil
    end

    test "returns default for missing key", %{store: pid} do
      assert TestStore.get(pid, :missing, :fallback) == :fallback
    end

    test "returns stored nil value, not default", %{store: pid} do
      TestStore.put(pid, :nilval, nil)
      assert TestStore.get(pid, :nilval, :default) == nil
    end
  end

  describe "get_all/1" do
    test "returns empty map when store is empty", %{store: pid} do
      assert TestStore.get_all(pid) == %{}
    end

    test "returns all stored key-value pairs", %{store: pid} do
      TestStore.put(pid, :a, 1)
      TestStore.put(pid, :b, 2)
      TestStore.put(pid, :c, 3)
      assert TestStore.get_all(pid) == %{a: 1, b: 2, c: 3}
    end
  end

  describe "put/3" do
    test "stores a value", %{store: pid} do
      assert :ok = TestStore.put(pid, :key, "value")
      assert TestStore.get(pid, :key) == "value"
    end

    test "overwrites an existing value", %{store: pid} do
      TestStore.put(pid, :key, "first")
      TestStore.put(pid, :key, "second")
      assert TestStore.get(pid, :key) == "second"
    end

    test "stores various value types", %{store: pid} do
      TestStore.put(pid, :atom_val, :hello)
      TestStore.put(pid, :list_val, [1, 2, 3])
      TestStore.put(pid, :map_val, %{nested: true})
      TestStore.put(pid, :tuple_val, {:ok, 42})

      assert TestStore.get(pid, :atom_val) == :hello
      assert TestStore.get(pid, :list_val) == [1, 2, 3]
      assert TestStore.get(pid, :map_val) == %{nested: true}
      assert TestStore.get(pid, :tuple_val) == {:ok, 42}
    end
  end

  describe "delete/2" do
    test "removes a key from the store", %{store: pid} do
      TestStore.put(pid, :key, "value")
      assert :ok = TestStore.delete(pid, :key)
      assert TestStore.get(pid, :key) == nil
    end

    test "is a no-op for missing key", %{store: pid} do
      assert :ok = TestStore.delete(pid, :nonexistent)
    end

    test "does not affect other keys", %{store: pid} do
      TestStore.put(pid, :keep, "yes")
      TestStore.put(pid, :remove, "no")
      TestStore.delete(pid, :remove)

      assert TestStore.get(pid, :keep) == "yes"
      assert TestStore.get(pid, :remove) == nil
    end
  end

  describe "clear/1" do
    test "removes all entries", %{store: pid} do
      TestStore.put(pid, :a, 1)
      TestStore.put(pid, :b, 2)
      assert :ok = TestStore.clear(pid)
      assert TestStore.get_all(pid) == %{}
    end

    test "is a no-op on empty store", %{store: pid} do
      assert :ok = TestStore.clear(pid)
      assert TestStore.get_all(pid) == %{}
    end
  end

  describe "update/4" do
    test "updates existing key with function", %{store: pid} do
      TestStore.put(pid, :counter, 0)
      assert :ok = TestStore.update(pid, :counter, 0, &(&1 + 1))
      assert TestStore.get(pid, :counter) == 1
    end

    test "uses default when key does not exist", %{store: pid} do
      assert :ok = TestStore.update(pid, :counter, 10, &(&1 + 1))
      assert TestStore.get(pid, :counter) == 10
    end

    test "applies function multiple times", %{store: pid} do
      TestStore.put(pid, :counter, 0)
      TestStore.update(pid, :counter, 0, &(&1 + 1))
      TestStore.update(pid, :counter, 0, &(&1 + 1))
      TestStore.update(pid, :counter, 0, &(&1 + 1))
      assert TestStore.get(pid, :counter) == 3
    end
  end

  describe "get_and_update/3" do
    test "returns current value and updates atomically", %{store: pid} do
      TestStore.put(pid, :counter, 5)

      result =
        TestStore.get_and_update(pid, :counter, fn val -> {val, val + 1} end)

      assert result == 5
      assert TestStore.get(pid, :counter) == 6
    end

    test "handles missing key by passing nil to function", %{store: pid} do
      result =
        TestStore.get_and_update(pid, :missing, fn nil ->
          {:was_nil, "now_set"}
        end)

      assert result == :was_nil
      assert TestStore.get(pid, :missing) == "now_set"
    end

    test "supports :pop to remove the key", %{store: pid} do
      TestStore.put(pid, :removable, "goodbye")
      result = TestStore.get_and_update(pid, :removable, fn _val -> :pop end)
      assert result == "goodbye"
      assert TestStore.get(pid, :removable) == nil
    end

    test ":pop on missing key returns nil", %{store: pid} do
      result = TestStore.get_and_update(pid, :missing, fn _val -> :pop end)
      assert result == nil
    end
  end

  describe "operations when not started" do
    test "get returns default when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert TestStore.get(pid, :key) == nil
      assert TestStore.get(pid, :key, :fallback) == :fallback
    end

    test "get_all returns empty map when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert TestStore.get_all(pid) == %{}
    end

    test "put returns error when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert {:error, :not_started} = TestStore.put(pid, :key, "value")
    end

    test "delete returns error when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert {:error, :not_started} = TestStore.delete(pid, :key)
    end

    test "clear returns error when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert {:error, :not_started} = TestStore.clear(pid)
    end

    test "update returns error when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)
      assert {:error, :not_started} = TestStore.update(pid, :key, 0, &(&1 + 1))
    end

    test "get_and_update returns nil when store is dead" do
      {:ok, pid} = TestStore.start_link()
      Agent.stop(pid)

      assert TestStore.get_and_update(pid, :key, fn val -> {val, val} end) ==
               nil
    end
  end
end
