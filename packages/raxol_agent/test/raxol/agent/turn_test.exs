defmodule Raxol.Agent.TurnTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Mock
  alias Raxol.Agent.Conversation.Log
  alias Raxol.Agent.Memory.SessionSearch
  alias Raxol.Agent.Memory.Store.Ets, as: MemStore
  alias Raxol.Agent.Skills.Store, as: SkillsStore
  alias Raxol.Agent.Turn
  alias Raxol.Agent.UserModel

  defmodule DemoAgent do
    use Raxol.Agent
    def memory_provider, do: Raxol.Agent.Memory.Store.Ets
    def skills_provider, do: Raxol.Agent.Skills.Store

    def self_improve do
      %{
        enabled: true,
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [response: ~s({"memories":[],"skills":[]})],
        min_tool_calls: 0
      }
    end
  end

  defmodule BareAgent do
    use Raxol.Agent
  end

  setup do
    base = Path.join(System.tmp_dir!(), "turn_#{uid()}")
    File.mkdir_p!(Path.join(base, "skills"))
    on_exit(fn -> File.rm_rf(base) end)

    mem = start(MemStore, name: :"mem_#{uid()}")

    skills =
      start(SkillsStore,
        name: :"sk_#{uid()}",
        skills_root: Path.join(base, "skills"),
        external_dirs: []
      )

    opts = [
      backend: Mock,
      log: start(Log, name: :"log_#{uid()}"),
      conversation_id: "c1",
      agent_id: "a1",
      user_id: "u1",
      memory_opts: [server: mem],
      skills_opts: [server: skills],
      user_model: start(UserModel, name: :"um_#{uid()}"),
      session_search: start(SessionSearch, name: :"ss_#{uid()}")
    ]

    %{opts: opts}
  end

  test "build_context assembles every configured provider from the agent module", %{opts: opts} do
    ctx = Turn.build_context(DemoAgent, opts)

    assert {MemStore, mem_opts} = ctx.memory
    assert Keyword.get(mem_opts, :server)
    assert Keyword.get(mem_opts, :agent_id) == "a1"
    assert {SkillsStore, _} = ctx.skills
    assert {UserModel, um_opts} = ctx.user_context
    assert Keyword.get(um_opts, :user_id) == "u1"
    assert {SessionSearch, _} = ctx.session_search
  end

  test "build_context omits capabilities the agent does not declare", %{opts: opts} do
    bare = Turn.build_context(BareAgent, Keyword.drop(opts, [:user_model, :session_search]))
    refute Map.has_key?(bare, :memory)
    refute Map.has_key?(bare, :skills)
    refute Map.has_key?(bare, :user_context)
    refute Map.has_key?(bare, :session_search)
  end

  test "run records the turn into the Log and feeds the session-search index", %{opts: opts} do
    {:ok, items} =
      Turn.run(
        DemoAgent,
        "how do I deploy with flyctl",
        Keyword.put(opts, :backend_opts, response: "I ran flyctl deploy to ship it")
      )

    assert items != []

    {:ok, logged} = Log.items(opts[:log], "c1")
    assert Enum.any?(logged, &(&1.type == :message))

    assert [%{conversation_id: "c1"}] = SessionSearch.search(opts[:session_search], "flyctl")
  end

  test "a turn for an agent with no providers still runs and records", %{opts: opts} do
    {:ok, items} =
      Turn.run(BareAgent, "say hi",
        backend: Mock,
        backend_opts: [response: "hi there"],
        log: opts[:log],
        conversation_id: "bare"
      )

    assert items != []
    {:ok, logged} = Log.items(opts[:log], "bare")
    assert Enum.any?(logged, &(&1.type == :message))
  end

  defp start(mod, opts) do
    name = Keyword.fetch!(opts, :name)
    start_supervised!(%{id: name, start: {mod, :start_link, [opts]}})
    name
  end

  defp uid, do: System.unique_integer([:positive])
end
