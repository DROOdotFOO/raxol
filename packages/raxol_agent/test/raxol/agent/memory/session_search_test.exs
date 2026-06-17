defmodule Raxol.Agent.Memory.SessionSearchTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Conversation.Log
  alias Raxol.Agent.Memory.SessionSearch

  setup do
    name = :"ss_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {SessionSearch, :start_link, [[name: name]]}})
    %{server: name}
  end

  defp item(conv, seq, role, content) do
    %{
      conversation_id: conv,
      seq: seq,
      id: "#{conv}:#{seq}",
      type: :message,
      data: %{role: role, content: content}
    }
  end

  test "returns the raw items matching a query, ranked", %{server: s} do
    SessionSearch.index(s, [
      item("c1", 0, :user, "how do I deploy an elixir app to fly"),
      item("c1", 1, :assistant, "run flyctl deploy from the project root"),
      item("c1", 2, :user, "what about scheduling postgres backups")
    ])

    results = SessionSearch.search(s, "deploy elixir fly")
    seqs = Enum.map(results, & &1.seq)
    assert 0 in seqs
    refute 2 in seqs
  end

  test "scopes results to one conversation", %{server: s} do
    SessionSearch.index(s, [
      item("c1", 0, :user, "deploy the staging environment"),
      item("c2", 0, :user, "deploy the production environment")
    ])

    results = SessionSearch.search(s, "deploy", conversation_id: "c1")
    assert Enum.map(results, & &1.conversation_id) == ["c1"]
  end

  test "respects the limit", %{server: s} do
    items = for seq <- 0..4, do: item("c1", seq, :user, "deploy attempt number #{seq}")
    SessionSearch.index(s, items)

    assert length(SessionSearch.search(s, "deploy", limit: 2)) == 2
  end

  test "an empty query or empty index returns nothing", %{server: s} do
    assert SessionSearch.search(s, "anything") == []
    SessionSearch.index(s, [item("c1", 0, :user, "deploy now")])
    assert SessionSearch.search(s, "") == []
  end

  test "attach indexes a Log snapshot and live appends", %{server: s} do
    log = :"log_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: log, start: {Log, :start_link, [[name: log]]}})

    Log.append(log, "c1", [
      %{type: :message, data: %{role: :user, content: "deploy with flyctl now"}}
    ])

    SessionSearch.attach(s, log, "c1")

    assert [%{conversation_id: "c1"}] = SessionSearch.search(s, "flyctl")

    Log.append(log, "c1", [
      %{type: :message, data: %{role: :assistant, content: "run the postgres migration first"}}
    ])

    # The live item is delivered to the SessionSearch mailbox during append, so a
    # subsequent call observes it without any sleep.
    assert [%{type: :message}] = SessionSearch.search(s, "migration")
  end
end
