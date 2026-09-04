defmodule Raxol.Symphony.ConfigTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Config

  describe "from_workflow/2 -- codex.auth" do
    test "parses a configured auth block and normalizes the mode to an atom" do
      workflow = %{
        config: %{
          codex: %{
            auth: %{mode: "api_key", api_key_env: "MY_KEY", require_login: true}
          }
        },
        prompt_template: ""
      }

      auth = Config.from_workflow(workflow).codex.auth
      assert auth.mode == :api_key
      assert auth.api_key_env == "MY_KEY"
      assert auth.require_login == true
    end

    test "expands ~ in codex_home" do
      workflow = %{
        config: %{codex: %{auth: %{mode: "codex_home", codex_home: "~/.codex"}}},
        prompt_template: ""
      }

      auth = Config.from_workflow(workflow).codex.auth
      assert auth.mode == :codex_home
      assert auth.codex_home == Path.join(System.user_home!(), ".codex")
    end

    test "leaves an unknown mode intact for the schema to reject" do
      workflow = %{
        config: %{codex: %{auth: %{mode: "bogus"}}},
        prompt_template: ""
      }

      assert Config.from_workflow(workflow).codex.auth.mode == "bogus"
    end
  end

  describe "from_workflow/2 -- defaults" do
    test "applies defaults for an empty config" do
      workflow = %{config: %{}, prompt_template: ""}
      config = Config.from_workflow(workflow)

      assert config.polling.interval_ms == 30_000
      assert config.hooks.timeout_ms == 60_000
      assert config.agent.max_concurrent_agents == 10
      assert config.agent.max_turns == 20
      assert config.agent.max_retry_backoff_ms == 300_000
      assert config.codex.command == "codex app-server"
      assert config.codex.turn_timeout_ms == 3_600_000
      assert config.codex.read_timeout_ms == 5_000
      assert config.codex.stall_timeout_ms == 300_000
      assert config.codex.auth.mode == :inherit
      assert config.codex.auth.api_key_env == "OPENAI_API_KEY"
      assert config.codex.auth.codex_home == nil
      assert config.codex.auth.require_login == false
      assert config.runner.kind == "raxol_agent"
      assert config.worker.ssh_hosts == []
      assert config.workflow_mode == :default
      assert config.workflow_parallelism == 3
      assert config.tracker.active_states == ["Todo", "In Progress"]

      assert config.tracker.terminal_states == [
               "Closed",
               "Cancelled",
               "Canceled",
               "Duplicate",
               "Done"
             ]
    end

    test "default linear endpoint applied when kind is linear" do
      workflow = %{config: %{tracker: %{kind: "linear"}}, prompt_template: ""}
      config = Config.from_workflow(workflow)

      assert config.tracker.endpoint == "https://api.linear.app/graphql"
    end

    test "default workspace root is under system temp" do
      workflow = %{config: %{}, prompt_template: ""}
      config = Config.from_workflow(workflow)

      assert config.workspace.root |> String.contains?("symphony_workspaces")
      assert Path.type(config.workspace.root) == :absolute
    end
  end

  describe "workflow_mode + workflow_parallelism" do
    test "parses graph and graph_parallel from strings and atoms" do
      for value <- ["graph", :graph] do
        config = Config.from_workflow(%{config: %{workflow_mode: value}, prompt_template: ""})
        assert config.workflow_mode == :graph
      end

      for value <- ["graph_parallel", :graph_parallel] do
        config = Config.from_workflow(%{config: %{workflow_mode: value}, prompt_template: ""})
        assert config.workflow_mode == :graph_parallel
      end
    end

    test "an unknown workflow_mode falls back to :default" do
      config = Config.from_workflow(%{config: %{workflow_mode: "bogus"}, prompt_template: ""})
      assert config.workflow_mode == :default
    end

    test "workflow_parallelism takes a positive integer and clamps invalid values" do
      config = Config.from_workflow(%{config: %{workflow_parallelism: 5}, prompt_template: ""})
      assert config.workflow_parallelism == 5

      for bad <- [0, -2, "3", nil] do
        config =
          Config.from_workflow(%{config: %{workflow_parallelism: bad}, prompt_template: ""})

        assert config.workflow_parallelism == 3
      end
    end
  end

  describe "$VAR resolution" do
    test "resolves $VAR from environment" do
      System.put_env("SYMPHONY_TEST_KEY", "secret-token")

      workflow = %{
        config: %{tracker: %{kind: "linear", api_key: "$SYMPHONY_TEST_KEY"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.tracker.api_key == "secret-token"
    after
      System.delete_env("SYMPHONY_TEST_KEY")
    end

    test "treats unset env var as nil" do
      System.delete_env("SYMPHONY_DEFINITELY_UNSET")

      workflow = %{
        config: %{tracker: %{kind: "linear", api_key: "$SYMPHONY_DEFINITELY_UNSET"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.tracker.api_key == nil
    end

    test "treats empty env var as nil" do
      System.put_env("SYMPHONY_EMPTY", "")

      workflow = %{
        config: %{tracker: %{kind: "linear", api_key: "$SYMPHONY_EMPTY"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.tracker.api_key == nil
    after
      System.delete_env("SYMPHONY_EMPTY")
    end

    test "default api_key for linear pulls LINEAR_API_KEY" do
      System.put_env("LINEAR_API_KEY", "lin_abc")

      workflow = %{config: %{tracker: %{kind: "linear"}}, prompt_template: ""}
      config = Config.from_workflow(workflow)

      assert config.tracker.api_key == "lin_abc"
    after
      System.delete_env("LINEAR_API_KEY")
    end

    test "literal values pass through" do
      workflow = %{
        config: %{tracker: %{kind: "linear", api_key: "literal"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.tracker.api_key == "literal"
    end
  end

  describe "workspace root normalization" do
    test "expands ~" do
      workflow = %{
        config: %{workspace: %{root: "~/code/symphony"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)

      assert Path.type(config.workspace.root) == :absolute
      assert config.workspace.root == Path.join(System.user_home!(), "code/symphony")
    end

    test "resolves relative paths against workflow path directory" do
      workflow_path = "/tmp/proj/WORKFLOW.md"

      workflow = %{
        config: %{workspace: %{root: "workspaces"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow, workflow_path)
      assert config.workspace.root == "/tmp/proj/workspaces"
    end

    test "leaves absolute paths alone (just normalizes)" do
      workflow = %{
        config: %{workspace: %{root: "/abs/path/workspaces"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.workspace.root == "/abs/path/workspaces"
    end

    test "resolves $VAR in workspace root" do
      System.put_env("SYMPHONY_WS", "/var/lib/sym")

      workflow = %{
        config: %{workspace: %{root: "$SYMPHONY_WS"}},
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.workspace.root == "/var/lib/sym"
    after
      System.delete_env("SYMPHONY_WS")
    end
  end

  describe "max_concurrent_agents_by_state" do
    test "normalizes state keys to lowercase strings" do
      workflow = %{
        config: %{
          agent: %{
            max_concurrent_agents_by_state: %{
              "In Progress" => 5,
              "Todo" => 2
            }
          }
        },
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.agent.max_concurrent_agents_by_state == %{"in progress" => 5, "todo" => 2}
    end

    test "drops invalid (non-positive) entries" do
      workflow = %{
        config: %{
          agent: %{
            max_concurrent_agents_by_state: %{
              "Todo" => -1,
              "In Progress" => 0,
              "Done" => 3
            }
          }
        },
        prompt_template: ""
      }

      config = Config.from_workflow(workflow)
      assert config.agent.max_concurrent_agents_by_state == %{"done" => 3}
    end
  end

  describe "load_and_validate/1" do
    @tag :tmp_dir
    test "returns the validated config", %{tmp_dir: tmp_dir} do
      System.put_env("LINEAR_API_KEY", "lin_xyz")
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: linear
        project_slug: "demo-project"
      ---
      hello
      """)

      assert {:ok, config} = Config.load_and_validate(path)
      assert config.tracker.kind == "linear"
      assert config.tracker.project_slug == "demo-project"
      assert config.tracker.api_key == "lin_xyz"
      assert config.prompt_template == "hello"
    after
      System.delete_env("LINEAR_API_KEY")
    end

    @tag :tmp_dir
    test "fails when validation fails", %{tmp_dir: tmp_dir} do
      System.delete_env("LINEAR_API_KEY")
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: linear
        project_slug: "demo-project"
      ---
      hello
      """)

      assert {:error, :missing_tracker_api_key} = Config.load_and_validate(path)
    end
  end

  describe "load_and_validate/1 -- malformed front-matter sections" do
    @tag :tmp_dir
    test "rejects a section written with no body", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      polling:
        # interval_ms: 30000
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:polling]}} =
               Config.load_and_validate(path)
    end

    @tag :tmp_dir
    test "rejects a section written as a scalar", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker: memory
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:tracker]}} =
               Config.load_and_validate(path)
    end

    @tag :tmp_dir
    test "rejects a section written as a list", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      workspace:
        - /tmp/symphony
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:workspace]}} =
               Config.load_and_validate(path)
    end

    @tag :tmp_dir
    test "rejects a malformed nested codex.auth section", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      codex:
        auth: api_key
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:codex, :auth]}} =
               Config.load_and_validate(path)
    end

    @tag :tmp_dir
    test "rejects a runner.agent block that lost its body", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      runner:
        kind: raxol_agent
        agent:
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:runner, :agent]}} =
               Config.load_and_validate(path)
    end

    @tag :tmp_dir
    test "rejects a scalar runner.agent", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      runner:
        kind: raxol_agent
        agent: workflow_mode
      ---
      hello
      """)

      assert {:error, {:workflow_section_not_a_map, [:runner, :agent]}} =
               Config.load_and_validate(path)
    end
  end

  describe "worker.ssh_hosts (issue #742)" do
    alias Raxol.Symphony.Config.Schema

    defp memory_workflow(worker) do
      %{
        config: %{
          tracker: %{kind: "memory"},
          runner: %{kind: "raxol_agent"},
          worker: worker
        },
        prompt_template: ""
      }
    end

    test "parses string and map host forms verbatim" do
      config =
        Config.from_workflow(
          memory_workflow(%{ssh_hosts: ["ci@build-1", %{host: "build-2", port: 2222}]})
        )

      assert config.worker.ssh_hosts == ["ci@build-1", %{host: "build-2", port: 2222}]
    end

    test "validate accepts well-formed hosts" do
      config = Config.from_workflow(memory_workflow(%{ssh_hosts: ["ci@build-1", %{host: "b2"}]}))
      assert Schema.validate(config) == :ok
    end

    test "validate rejects a malformed host entry" do
      config = Config.from_workflow(memory_workflow(%{ssh_hosts: ["ci@build-1", %{user: "ci"}]}))
      assert {:error, {:invalid_ssh_host, %{user: "ci"}}} = Schema.validate(config)
    end

    test "validate rejects a non-list ssh_hosts" do
      config = Config.from_workflow(memory_workflow(%{ssh_hosts: "build-1"}))
      assert {:error, {:invalid_value, :worker_ssh_hosts, "build-1"}} = Schema.validate(config)
    end

    test "an empty/absent worker section validates and defaults to []" do
      config = Config.from_workflow(memory_workflow(%{}))
      assert config.worker.ssh_hosts == []
      assert Schema.validate(config) == :ok
    end
  end
end
