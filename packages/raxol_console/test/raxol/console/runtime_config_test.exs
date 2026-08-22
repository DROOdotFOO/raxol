defmodule Raxol.Console.RuntimeConfigTest do
  # Not async: the handler-mode tests set and delete `:app_templates`, which is
  # global application env. BootTest writes the same key.
  use ExUnit.Case, async: false

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

    # The boot resolves agent_opts either way -- bundled MCP servers are running
    # subprocesses by this point. Dropping them in :app mode paid for a toolset
    # nothing could reach.
    test "app mode threads the resolved agent_opts to the app rather than dropping them" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")

      assert {Raxol.Gateway.Handler.Lifecycle, opts} =
               RuntimeConfig.handler_spec(cfg, actions: [:tool_a], context: %{skills: :store})

      assert opts[:lifecycle_opts][:agent_opts][:actions] == [:tool_a]
      assert opts[:lifecycle_opts][:agent_opts][:context] == %{skills: :store}
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

  # Being an atom is not evidence of being a bookable app. Resolving on `is_atom`
  # alone let a typo boot green and then drop every chat: the failure surfaced
  # only per-chat, inside Handler.Lifecycle, behind a route/3 that had already
  # answered :ok. A config error has to fail at boot, which is here.
  describe "app template validation" do
    defmodule NotATeaApp do
      @moduledoc false
      def init(_args), do: {:ok, %{}}
    end

    test "a registered module that does not exist is refused at build time" do
      Application.put_env(:raxol_console, :app_templates, %{"typo" => MyConsole.Dashbaord})
      on_exit(fn -> Application.delete_env(:raxol_console, :app_templates) end)

      assert {:error, {:invalid_app_template, "typo", MyConsole.Dashbaord, :module_not_loaded}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "typo")
    end

    test "a registered module missing the TEA callbacks is refused at build time" do
      Application.put_env(:raxol_console, :app_templates, %{"wrong" => NotATeaApp})
      on_exit(fn -> Application.delete_env(:raxol_console, :app_templates) end)

      assert {:error, {:invalid_app_template, "wrong", NotATeaApp, {:missing_callbacks, missing}}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "wrong")

      assert missing == [update: 2, view: 1]
    end
  end

  # `templates/0` is read at boot, so a malformed shape must produce a diagnosis
  # rather than an exception from inside config reading -- and the keyword list
  # is the shape an operator is most likely to actually write.
  describe "app template config shapes" do
    defmodule KeywordApp do
      @moduledoc false
      def init(_args), do: {:ok, %{}}
      def update(_msg, model), do: model
      def view(_model), do: nil
    end

    setup do
      on_exit(fn -> Application.delete_env(:raxol_console, :app_templates) end)
    end

    test "a keyword list resolves the same as a map" do
      Application.put_env(:raxol_console, :app_templates, dashboard: KeywordApp)

      assert {:ok, cfg} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")

      assert cfg.app_module == KeywordApp
    end

    test "a malformed list is a refusal, not an ArgumentError from Map.new/1" do
      Application.put_env(:raxol_console, :app_templates, ["dashboard"])

      assert {:error, {:unknown_app_template, "dashboard"}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")
    end

    test "a garbage entry is dropped without taking the well-formed ones with it" do
      Application.put_env(:raxol_console, :app_templates, [
        "junk",
        {"dashboard", KeywordApp},
        {"nil-module", nil}
      ])

      assert {:ok, cfg} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "dashboard")

      assert cfg.app_module == KeywordApp

      assert {:error, {:unknown_app_template, "nil-module"}} =
               RuntimeConfig.build(package(), handler_mode: :app, app_template: "nil-module")
    end
  end

  describe "idle timeout" do
    test "is unset by default, leaving the gateway's own default in force" do
      assert {:ok, cfg} = RuntimeConfig.build(package())
      assert cfg.idle_timeout == nil
    end

    test "carries a positive integer through" do
      assert {:ok, cfg} = RuntimeConfig.build(package(), idle_timeout: 3_600_000)
      assert cfg.idle_timeout == 3_600_000
    end

    # A string compares against an integer by term order rather than raising, so
    # an unvalidated one would arm a timer that never fires the branch it feeds.
    test "refuses a value that is not a positive integer" do
      assert {:error, {:invalid_idle_timeout, "3600000"}} =
               RuntimeConfig.build(package(), idle_timeout: "3600000")

      assert {:error, {:invalid_idle_timeout, 0}} =
               RuntimeConfig.build(package(), idle_timeout: 0)

      assert {:error, {:invalid_idle_timeout, -1}} =
               RuntimeConfig.build(package(), idle_timeout: -1)
    end
  end

  # In :app mode a session is a running TEA app rather than a message list, so
  # the ceiling on concurrent chats is a sizing decision a deployment has to be
  # able to make. It was unreachable while RuntimeConfig knew nothing about it.
  describe "max sessions" do
    test "is unset by default, leaving the gateway's own default in force" do
      assert {:ok, cfg} = RuntimeConfig.build(package())
      assert cfg.max_sessions == nil
    end

    test "carries a positive integer through" do
      assert {:ok, cfg} = RuntimeConfig.build(package(), max_sessions: 200)
      assert cfg.max_sessions == 200
    end

    test "refuses a value that is not a positive integer" do
      assert {:error, {:invalid_max_sessions, "200"}} =
               RuntimeConfig.build(package(), max_sessions: "200")

      assert {:error, {:invalid_max_sessions, 0}} =
               RuntimeConfig.build(package(), max_sessions: 0)
    end
  end

  # Who may open a chat. Unset means open, because Pairing's allowlists boot
  # empty and enforcing by default would deny every Console running today --
  # which makes silence the permissive answer, so Boot makes silence loud.
  describe "pairing" do
    test "unset is open and undeclared, which is what earns the boot warning" do
      assert {:ok, cfg} = RuntimeConfig.build(package())
      assert cfg.pairing.mode == :open
      refute cfg.pairing.declared?
    end

    test "an explicit :open is open and declared" do
      assert {:ok, cfg} = RuntimeConfig.build(package(), pairing: :open)
      assert cfg.pairing.mode == :open
      assert cfg.pairing.declared?
    end

    test "an empty list enforces with nothing seeded" do
      assert {:ok, cfg} = RuntimeConfig.build(package(), pairing: [])
      assert cfg.pairing.mode == :enforce
      assert cfg.pairing.allow_platforms == []
      assert cfg.pairing.allowed_users == []
      assert cfg.pairing.platform_users == []
    end

    test "carries the three allowlists through" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(),
                 pairing: [
                   allow_platforms: [:telegram],
                   allowed_users: ["alice"],
                   platform_users: [discord: ["bob"]]
                 ]
               )

      assert cfg.pairing.mode == :enforce
      assert cfg.pairing.allow_platforms == [:telegram]
      assert cfg.pairing.allowed_users == ["alice"]
      assert cfg.pairing.platform_users == [discord: ["bob"]]
    end

    # Pairing stringifies on both allow/3 and the authorize check, so an integer
    # Telegram id written as an integer has to normalize to the same thing.
    test "stringifies integer user ids so they match the route's" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(),
                 pairing: [allowed_users: [12_345], platform_users: [telegram: [678]]]
               )

      assert cfg.pairing.allowed_users == ["12345"]
      assert cfg.pairing.platform_users == [telegram: ["678"]]
    end

    # A typo'd key would seed nothing and read as a deliberate deny-all, which is
    # indistinguishable from `pairing: []` and locks the operator out silently.
    test "refuses an unknown key rather than ignoring it" do
      assert {:error, {:unknown_pairing_keys, [:allowed_user]}} =
               RuntimeConfig.build(package(), pairing: [allowed_user: ["alice"]])
    end

    test "refuses a malformed posture" do
      assert {:error, {:invalid_pairing, :everyone}} =
               RuntimeConfig.build(package(), pairing: :everyone)

      assert {:error, {:invalid_pairing, {:allow_platforms, ["telegram"]}}} =
               RuntimeConfig.build(package(), pairing: [allow_platforms: ["telegram"]])

      assert {:error, {:invalid_pairing, {:allowed_users, [%{}]}}} =
               RuntimeConfig.build(package(), pairing: [allowed_users: [%{}]])

      assert {:error, {:invalid_pairing, {:platform_users, :discord, "bob"}}} =
               RuntimeConfig.build(package(), pairing: [platform_users: [discord: "bob"]])
    end

    # `nil` is an atom, so a platform resolved from a lookup that missed would
    # pass an `is_atom/1` check, name no channel, and grant nothing -- the same
    # silent lockout an unknown key is refused for.
    test "refuses nil and booleans as platform atoms" do
      assert {:error, {:invalid_pairing, {:allow_platforms, [nil]}}} =
               RuntimeConfig.build(package(), pairing: [allow_platforms: [nil]])

      assert {:error, {:invalid_pairing, {:allow_platforms, [true]}}} =
               RuntimeConfig.build(package(), pairing: [allow_platforms: [true]])

      assert {:error, {:invalid_pairing, {:platform_users, nil, ["bob"]}}} =
               RuntimeConfig.build(package(), pairing: [platform_users: [{nil, ["bob"]}]])
    end

    # `:global` is Pairing's key for the cross-platform bucket. Accepted here it
    # would file ids written under "per platform" where every platform reads --
    # a silent widening of the grant the scoping exists to narrow.
    test "refuses :global as a platform, since :allowed_users is how you ask for that" do
      assert {:error, {:invalid_pairing, {:platform_users, :global, ["bob"]}}} =
               RuntimeConfig.build(package(), pairing: [platform_users: [global: ["bob"]]])

      assert {:error, {:invalid_pairing, {:allow_platforms, [:global]}}} =
               RuntimeConfig.build(package(), pairing: [allow_platforms: [:global]])
    end

    # A keyword list admits duplicates; Pairing unions them when it seeds, so
    # both sets are carried through here rather than the last one winning.
    test "carries a platform named twice through as written" do
      assert {:ok, cfg} =
               RuntimeConfig.build(package(),
                 pairing: [platform_users: [telegram: ["a"], telegram: ["b"]]]
               )

      assert cfg.pairing.platform_users == [telegram: ["a"], telegram: ["b"]]
    end
  end

  test "rejects a non-package" do
    assert {:error, {:not_a_package, %{}}} = RuntimeConfig.build(%{})
  end
end
