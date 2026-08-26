defmodule Raxol.Core.Stores.NamingTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Stores.Naming

  defmodule SomeStore do
  end

  # Both tests spawn a process and give it `assert_receive`'s 100ms to answer.
  # That budget is for the BEHAVIOUR, and the first `registered_name!/1` call
  # anywhere in a run spends more than it on loading code on demand: measured at
  # 112ms, 181ms and 182ms, against a 100ms deadline.
  #
  # It is not one module. Loading `Naming` up front is not enough, because the
  # failing path raises, and `raise` + the `inspect(module)` inside the message
  # pull in `RuntimeError`, `Exception`, `Inspect`, `Inspect.Atom` and
  # `Inspect.Opts` -- all five confirmed cold via `:code.is_loaded/1` at that
  # point. So the warm-up has to be the CALL, not a module list that would
  # quietly stop covering the path the day the message changes.
  #
  # `setup_all` has no registered name either, so this takes the same branch the
  # second test asserts on, and rescues it the same way.
  #
  # This is why the failure looked like a flake without being one: it failed 17
  # runs in 20 in isolation, but only occasionally in a full run, where whether
  # some earlier test had already loaded that machinery decided it -- and test
  # order is seeded per run. Raising the timeout would only widen the race.
  setup_all do
    try do
      Naming.registered_name!(SomeStore)
    rescue
      e -> Exception.message(e)
    end

    :ok
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
