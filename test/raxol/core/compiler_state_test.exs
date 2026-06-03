defmodule Raxol.Core.CompilerStateTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.CompilerState

  setup do
    name = :"compiler_state_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> if :ets.info(name) != :undefined, do: :ets.delete(name) end)
    %{table: name}
  end

  describe "ensure_table/2" do
    test "creates a new ETS table", %{table: t} do
      assert :ok = CompilerState.ensure_table(t)
      assert :ets.info(t) != :undefined
    end

    test "is idempotent when table already exists", %{table: t} do
      assert :ok = CompilerState.ensure_table(t)
      assert :ok = CompilerState.ensure_table(t)
    end
  end

  describe "safe_lookup/2" do
    test "returns {:ok, rows} for existing key", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      true = :ets.insert(t, {:k, 1})
      assert {:ok, [{:k, 1}]} = CompilerState.safe_lookup(t, :k)
    end

    test "returns {:ok, []} for missing key in existing table", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      assert {:ok, []} = CompilerState.safe_lookup(t, :nope)
    end

    test "returns {:error, :table_not_found} when table is missing" do
      assert {:error, :table_not_found} =
               CompilerState.safe_lookup(:no_such_table_xyz, :k)
    end
  end

  describe "safe_insert/2" do
    test "inserts a row and returns :ok", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      assert :ok = CompilerState.safe_insert(t, {:a, 1})
      assert [{:a, 1}] = :ets.lookup(t, :a)
    end

    test "returns {:error, :table_not_found} when table is missing" do
      assert {:error, :table_not_found} =
               CompilerState.safe_insert(:no_such_table_xyz, {:a, 1})
    end
  end

  describe "safe_delete/2" do
    test "deletes the row and returns :ok", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      true = :ets.insert(t, {:a, 1})
      assert :ok = CompilerState.safe_delete(t, :a)
      assert [] = :ets.lookup(t, :a)
    end

    test "is :ok on missing key", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      assert :ok = CompilerState.safe_delete(t, :missing)
    end

    test "returns {:error, :table_not_found} when table is missing" do
      assert {:error, :table_not_found} =
               CompilerState.safe_delete(:no_such_table_xyz, :a)
    end
  end

  describe "safe_delete_table/1" do
    test "deletes the table and returns :ok", %{table: t} do
      :ok = CompilerState.ensure_table(t)
      assert :ok = CompilerState.safe_delete_table(t)
      assert :undefined = :ets.info(t)
    end

    test "returns {:error, :table_not_found} when table is missing" do
      assert {:error, :table_not_found} =
               CompilerState.safe_delete_table(:no_such_table_xyz)
    end
  end
end
