defmodule Raxol.Console.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Console.Package
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

  describe "handler mode" do
    defmodule DashboardApp do
      @moduledoc false
      def init(_args), do: {:ok, %{}}
      def update(_msg, model), do: model
      def view(_model), do: nil
    end

    setup do
      Application.put_env(:raxol_console, :app_templates, %{"dashboard" => DashboardApp})
      on_exit(fn -> Application.delete_env(:raxol_console, :app_templates) end)
    end

    test "defaults to the stateless chat loop" do
      assert {:ok, cfg} = RuntimeConfig.build(package())
      assert cfg.handler_mode == :chat
      assert cfg.app_module == nil

      assert {Raxol.Gateway.Handler.Agent, opts} = RuntimeConfig.handler_spec(cfg, foo: 1)
      assert opts[:system_prompt] == cfg.system_prompt
      assert opts[:agent_opts] == [foo: 1]
    end

    test "app mode resolves a registered template to its module" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")

      assert cfg.handler_mode == :app
      assert cfg.app_module == DashboardApp
    end

    test "app mode boots Handler.Lifecycle with the persona threaded into init/1" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")

      assert {Raxol.Gateway.Handler.Lifecycle, opts} = RuntimeConfig.handler_spec(cfg, [])
      assert opts[:app_module] == DashboardApp

      # Lifecycle appends :lifecycle_opts to Lifecycle.start_link/2, and those
      # options reach the app as `init(%{options: opts})`. That is the only seam
      # a TEA app has for the persona, since it weaves it in itself.
      assert opts[:lifecycle_opts][:system_prompt] == cfg.system_prompt
    end

    test "an unregistered template is refused rather than resolved to a module" do
      assert {:error, {:unknown_app_template, "not-a-template"}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "not-a-template")
    end

    test "app mode without a template is refused" do
      assert {:error, :missing_app_template} =
               RuntimeConfig.build(package(), handler_mode: :app)
    end

    test "app mode is refused when no templates are registered at all" do
      Application.delete_env(:raxol_console, :app_templates)

      assert {:error, {:unknown_app_template, "dashboard"}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")
    end

    test "an unknown handler mode is refused" do
      assert {:error, {:unknown_handler_mode, :telepathy}} =
               RuntimeConfig.build(package(), handler_mode: :telepathy)
    end
  end

  test "rejects a non-package" do
    assert {:error, {:not_a_package, %{}}} = RuntimeConfig.build(%{})
  end
end
