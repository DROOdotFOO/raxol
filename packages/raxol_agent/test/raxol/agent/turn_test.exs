defmodule Raxol.Agent.TurnTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Mock
  alias Raxol.Agent.Conversation.Log
  alias Raxol.Agent.Skills.Store, as: SkillsStore
  alias Raxol.Agent.Turn

  defmodule DemoAgent do
    use Raxol.Agent
    def skills_provider, do: Raxol.Agent.Skills.Store
  end

  defmodule BareAgent do
    use Raxol.Agent
  end

  setup do
    base = Path.join(System.tmp_dir!(), "turn_#{uid()}")
    File.mkdir_p!(Path.join(base, "skills"))
    on_exit(fn -> File.rm_rf(base) end)

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
      skills_opts: [server: skills]
    ]

    %{opts: opts}
  end

  test "build_context assembles the skills provider the agent module declares", %{opts: opts} do
    ctx = Turn.build_context(DemoAgent, opts)

    assert {SkillsStore, skills_opts} = ctx.skills
    assert Keyword.get(skills_opts, :server)
  end

  test "build_context omits skills for an agent that declares none", %{opts: opts} do
    refute Map.has_key?(Turn.build_context(BareAgent, opts), :skills)
  end

  test "run records the turn into the Log", %{opts: opts} do
    {:ok, items} =
      Turn.run(
        DemoAgent,
        "how do I deploy with flyctl",
        Keyword.put(opts, :backend_opts, response: "I ran flyctl deploy to ship it")
      )

    assert items != []

    {:ok, logged} = Log.items(opts[:log], "c1")
    assert Enum.any?(logged, &(&1.type == :message))
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
