defmodule Raxol.Agent.Memory.Store.EtsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Memory.Record
  alias Raxol.Agent.Memory.Store.Ets, as: Store

  setup do
    name = :"mem_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Store, :start_link, [[name: name]]}})
    %{server: name}
  end

  defp put(server, content, opts \\ []) do
    {:ok, r} =
      Store.store(
        Record.new(%{
          content: content,
          agent_id: Keyword.get(opts, :agent_id, "a1"),
          tags: Keyword.get(opts, :tags, []),
          last_accessed: Keyword.get(opts, :last_accessed)
        }),
        server: server
      )

    r
  end

  test "ranks relevant matches above weaker ones, excludes non-matches", %{server: s} do
    both = put(s, "elixir genserver supervision tree")
    one = put(s, "elixir pattern matching pipes")
    _none = put(s, "python asyncio event loop")

    results = Store.search("elixir supervision", server: s, agent_id: "a1")
    ids = Enum.map(results, & &1.id)

    assert hd(ids) == both.id
    assert one.id in ids
    assert length(results) == 2
  end

  test "partitions by agent_id", %{server: s} do
    mine = put(s, "elixir supervision", agent_id: "a1")
    _theirs = put(s, "elixir supervision", agent_id: "a2")

    results = Store.search("elixir", server: s, agent_id: "a1")
    assert Enum.map(results, & &1.id) == [mine.id]
  end

  test "tag overlap boosts ranking", %{server: s} do
    plain = put(s, "deployment notes for the service", tags: [])
    tagged = put(s, "deployment notes for the service", tags: ["urgent"])

    results = Store.search("deployment", server: s, agent_id: "a1", query_tags: ["urgent"])
    assert hd(results).id == tagged.id
    assert plain.id in Enum.map(results, & &1.id)
  end

  test "empty query returns most-recently-accessed first", %{server: s} do
    now = System.system_time(:second)
    older = put(s, "older fact about elixir", last_accessed: now - 10_000)
    newer = put(s, "newer fact about elixir", last_accessed: now)

    results = Store.search("", server: s, agent_id: "a1")
    assert Enum.map(results, & &1.id) == [newer.id, older.id]
  end

  test "forget removes a record", %{server: s} do
    r = put(s, "elixir supervision tree")
    assert :ok = Store.forget(r.id, server: s)
    assert Store.search("elixir", server: s, agent_id: "a1") == []
  end

  test "re-store with same id updates the index, no stale hits", %{server: s} do
    r = put(s, "first content about rust")
    {:ok, _} = Store.store(%{r | content: "second content about elixir"}, server: s)

    assert Store.search("rust", server: s, agent_id: "a1") == []
    assert [%Record{id: id}] = Store.search("elixir", server: s, agent_id: "a1")
    assert id == r.id
  end

  test "survives a restart via DETS" do
    name = :"mem_dets_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.dets")
    on_exit(fn -> File.rm(path) end)

    {:ok, _} = Store.start_link(name: name, dets_path: path)

    {:ok, r} =
      Store.store(Record.new(%{content: "persistent elixir fact", agent_id: "a1"}), server: name)

    :ok = GenServer.stop(name)

    {:ok, _} = Store.start_link(name: name, dets_path: path)

    try do
      results = Store.search("elixir", server: name, agent_id: "a1")
      assert Enum.map(results, & &1.id) == [r.id]
    after
      GenServer.stop(name)
    end
  end
end
