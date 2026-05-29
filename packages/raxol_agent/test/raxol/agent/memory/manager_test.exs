defmodule Raxol.Agent.Memory.ManagerTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Memory.Manager

  defmodule BlockProvider do
    @behaviour Raxol.Agent.Memory
    def search(_q, _o), do: []
    def store(_r, _o), do: {:error, :unused}
    def forget(_id, _o), do: :ok
    def prefetch(_q, _o), do: []
    def build_system_prompt(opts), do: "## Relevant memory\n\nquery=#{Keyword.get(opts, :query)}"
  end

  defmodule NilProvider do
    @behaviour Raxol.Agent.Memory
    def search(_q, _o), do: []
    def store(_r, _o), do: {:error, :unused}
    def forget(_id, _o), do: :ok
    def prefetch(_q, _o), do: []
    def build_system_prompt(_opts), do: nil
  end

  test "nil provider is a no-op" do
    msgs = [%{role: :user, content: "hi"}]
    assert Manager.enrich_messages(msgs, nil, "hi") == msgs
  end

  test "provider returning nil block leaves messages unchanged" do
    msgs = [%{role: :system, content: "S"}, %{role: :user, content: "hi"}]
    assert Manager.enrich_messages(msgs, {NilProvider, []}, "hi") == msgs
  end

  test "injects memory system message after the static system message" do
    msgs = [%{role: :system, content: "S"}, %{role: :user, content: "find x"}]
    [first, mem, user] = Manager.enrich_messages(msgs, {BlockProvider, []}, "find x")

    assert first == %{role: :system, content: "S"}
    assert mem.role == :system
    assert mem.content =~ "Relevant memory"
    assert mem.content =~ "query=find x"
    assert user == %{role: :user, content: "find x"}
  end

  test "prepends when there is no system message" do
    msgs = [%{role: :user, content: "hi"}]
    [mem, user] = Manager.enrich_messages(msgs, {BlockProvider, []}, "hi")
    assert mem.role == :system
    assert user == %{role: :user, content: "hi"}
  end
end
