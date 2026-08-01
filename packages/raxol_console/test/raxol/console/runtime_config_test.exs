defmodule Raxol.Console.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Console.Package
  alias Raxol.Console.RuntimeConfig

  defp package(attrs \\ %{}) do
    %Package{
      runtime: :raxol,
      soul_md: Map.get(attrs, :soul_md, "# Bot\n\nYou are Bot.\n"),
      agents_md: Map.get(attrs, :agents_md),
      tasks: Map.get(attrs, :tasks, []),
      skills: Map.get(attrs, :skills, [])
    }
  end

  test "composes the persona from soul.md, appending AGENTS.md under a heading" do
    pkg = package(%{soul_md: "# Bot\n\nBe helpful.", agents_md: "Always cite sources."})

    assert {:ok, cfg} = RuntimeConfig.build(pkg)
    assert cfg.system_prompt =~ "Be helpful."
    assert cfg.system_prompt =~ "## Operating rules"
    assert cfg.system_prompt =~ "Always cite sources."
    assert String.length(cfg.persona_sha256) == 64
  end

  test "persona is soul.md alone when there is no AGENTS.md" do
    assert {:ok, cfg} = RuntimeConfig.build(package(%{soul_md: "# Bot\n\nHi.", agents_md: nil}))
    assert cfg.system_prompt == "# Bot\n\nHi."
  end

  test "maps tasks.json tasks to scheduler-create attrs keyed by name" do
    tasks = [
      %{name: "daily", description: "d", cron: "0 9 * * *", prompt: "summarize"},
      %{name: "weekly", description: "d", cron: "0 9 * * 1", prompt: "digest"}
    ]

    assert {:ok, cfg} =
             RuntimeConfig.build(package(%{tasks: tasks}), default_target: "telegram:42")

    assert [
             %{
               id: "daily",
               schedule: "0 9 * * *",
               prompt: "summarize",
               target: "telegram:42",
               enabled: true
             },
             %{id: "weekly", schedule: "0 9 * * 1", prompt: "digest", target: "telegram:42"}
           ] = cfg.scheduler_jobs
  end

  test "bundles the default MCP server set by default, scoped to the workspace" do
    assert {:ok, cfg} = RuntimeConfig.build(package(), workspace: "/agent")
    names = Enum.map(cfg.mcp_servers, & &1.name)

    assert :filesystem in names
    assert :git in names
    fs = Enum.find(cfg.mcp_servers, &(&1.name == :filesystem))
    assert "/agent" in fs.args
  end

  test "omits MCP servers when bundling is disabled" do
    assert {:ok, %{mcp_servers: []}} = RuntimeConfig.build(package(), bundle_default_mcp: false)
  end

  test "carries skills through and forwards agent_opts" do
    pkg = package(%{skills: [%{name: "greet", skill_md: "hi"}]})
    assert {:ok, cfg} = RuntimeConfig.build(pkg, agent_opts: [executor: :x])
    assert cfg.skills == [%{name: "greet", skill_md: "hi"}]
    assert cfg.agent_opts == [executor: :x]
  end

  test "rejects a non-package" do
    assert {:error, {:not_a_package, %{}}} = RuntimeConfig.build(%{})
  end
end
