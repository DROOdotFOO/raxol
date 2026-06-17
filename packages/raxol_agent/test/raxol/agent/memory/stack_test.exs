defmodule Raxol.Agent.Memory.StackTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Memory
  alias Raxol.Agent.Memory.Record
  alias Raxol.Agent.Memory.Stack
  alias Raxol.Agent.Memory.Store.Ets

  defmodule Boom do
    @moduledoc false
    def search(_query, _opts), do: raise("boom")
    def store(_record, _opts), do: raise("boom")
    def forget(_id, _opts), do: raise("boom")
  end

  setup do
    a = :"a_#{System.unique_integer([:positive])}"
    b = :"b_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: a, start: {Ets, :start_link, [[name: a]]}})
    start_supervised!(%{id: b, start: {Ets, :start_link, [[name: b]]}})

    {Stack, opts} = Memory.stack_context([{Ets, [server: a]}, {Ets, [server: b]}], "u1")
    %{a: a, b: b, opts: opts}
  end

  defp rec(content), do: Record.new(%{content: content, agent_id: "u1"})

  test "store fans out to every provider", %{a: a, b: b, opts: opts} do
    Stack.store(rec("elixir genserver supervision"), opts)
    assert length(Ets.list_all(a)) == 1
    assert length(Ets.list_all(b)) == 1
  end

  test "forget fans out to every provider", %{a: a, b: b, opts: opts} do
    record = rec("transient note")
    Stack.store(record, opts)
    Stack.forget(record.id, opts)
    assert Ets.list_all(a) == []
    assert Ets.list_all(b) == []
  end

  test "search merges results from all providers", %{a: a, b: b, opts: opts} do
    Ets.store(rec("elixir supervision tree"), server: a)
    Ets.store(rec("elixir pattern matching pipes"), server: b)

    contents = "elixir" |> search(opts) |> Enum.map(& &1.content)
    assert "elixir supervision tree" in contents
    assert "elixir pattern matching pipes" in contents
    assert length(contents) == 2
  end

  test "search dedupes identical content across providers", %{a: a, b: b, opts: opts} do
    Ets.store(rec("shared deployment runbook"), server: a)
    Ets.store(rec("shared deployment runbook"), server: b)

    results = search("deployment runbook", opts)
    assert Enum.count(results, &(&1.content == "shared deployment runbook")) == 1
  end

  test "a failing provider degrades to a no-op, not a crash", %{a: a} do
    {Stack, opts} = Memory.stack_context([{Ets, [server: a]}, Boom], "u1")
    Ets.store(rec("resilient recall"), server: a)

    assert [%{content: "resilient recall"}] = search("resilient recall", opts)
    assert {:ok, _} = Stack.store(rec("still writes"), opts)
  end

  defp search(query, opts), do: Stack.search(query, Keyword.put(opts, :limit, 5))
end
