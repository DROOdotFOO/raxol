defmodule Raxol.Core.Stores.NamingTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Stores.Naming

  defmodule SomeStore do
  end

  test "returns the registered name of the calling process" do
    name = :"core_stores_naming_#{System.unique_integer([:positive])}"
    parent = self()

    spawn(fn ->
      Process.register(self(), name)
      send(parent, {:result, Naming.registered_name!(SomeStore)})
    end)

    assert_receive {:result, ^name}
  end

  test "raises when the calling process has no registered name" do
    parent = self()

    spawn(fn ->
      result =
        try do
          Naming.registered_name!(SomeStore)
          :no_raise
        rescue
          e -> {:raised, Exception.message(e)}
        end

      send(parent, result)
    end)

    assert_receive {:raised, message}
    assert message =~ "registered :name"
    assert message =~ "SomeStore"
  end
end
