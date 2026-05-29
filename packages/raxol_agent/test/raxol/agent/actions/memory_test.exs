defmodule Raxol.Agent.Actions.MemoryTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Memory.{Forget, Recall, Remember}
  alias Raxol.Agent.Memory.Store.Ets, as: Store

  setup do
    name = :"mem_act_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Store, :start_link, [[name: name]]}})
    %{ctx: %{memory: {Store, [server: name, agent_id: "a1"]}}}
  end

  test "remember then recall round-trips through the provider", %{ctx: ctx} do
    assert {:ok, %{stored: true, id: id}} =
             Remember.run(%{content: "the build uses mix raxol.check", tags: ["build"]}, ctx)

    assert {:ok, %{results: [hit]}} = Recall.run(%{query: "build"}, ctx)
    assert hit.id == id
    assert hit.content =~ "raxol.check"
  end

  test "forget removes the memory", %{ctx: ctx} do
    {:ok, %{id: id}} = Remember.run(%{content: "ephemeral elixir note"}, ctx)
    assert {:ok, %{forgotten: true}} = Forget.run(%{id: id}, ctx)
    assert {:ok, %{results: []}} = Recall.run(%{query: "elixir"}, ctx)
  end

  test "recall honors limit", %{ctx: ctx} do
    for n <- 1..4, do: Remember.run(%{content: "elixir fact number #{n}"}, ctx)
    assert {:ok, %{results: results}} = Recall.run(%{query: "elixir", limit: 2}, ctx)
    assert length(results) == 2
  end

  test "errors when memory is not configured" do
    assert {:error, :memory_not_configured} =
             Remember.run(%{content: "x"}, %{})
  end

  test "tool definitions expose the expected names" do
    assert Remember.to_tool_definition()["function"]["name"] == "memory_remember"
    assert Recall.to_tool_definition()["function"]["name"] == "memory_recall"
    assert Forget.to_tool_definition()["function"]["name"] == "memory_forget"
  end
end
