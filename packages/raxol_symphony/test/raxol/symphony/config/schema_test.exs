defmodule Raxol.Symphony.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Config.Schema

  defp build_config(overrides \\ %{}) do
    base = %{
      tracker: %{
        kind: "linear",
        project_slug: "demo",
        api_key: "lin_abc"
      }
    }

    workflow = %{config: deep_merge(base, overrides), prompt_template: ""}
    Config.from_workflow(workflow)
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  describe "validate/1 -- success" do
    test "valid linear config passes" do
      assert :ok = Schema.validate(build_config())
    end

    test "memory tracker does not require api_key or project_slug" do
      workflow = %{config: %{tracker: %{kind: "memory"}}, prompt_template: ""}
      assert :ok = Schema.validate(Config.from_workflow(workflow))
    end

    test "github tracker requires api_key but not project_slug" do
      workflow = %{
        config: %{tracker: %{kind: "github", api_key: "ghp_xyz"}},
        prompt_template: ""
      }

      assert :ok = Schema.validate(Config.from_workflow(workflow))
    end

    test "codex runner with command passes" do
      assert :ok =
               Schema.validate(
                 build_config(%{
                   runner: %{kind: "codex"},
                   codex: %{command: "codex app-server --foo"}
                 })
               )
    end

    test "codex api_key auth passes" do
      assert :ok =
               Schema.validate(
                 build_config(%{codex: %{auth: %{mode: "api_key", api_key_env: "MY_KEY"}}})
               )
    end
  end

  describe "validate/1 -- failures" do
    test "missing tracker kind" do
      workflow = %{config: %{}, prompt_template: ""}
      assert {:error, :missing_tracker_kind} = Schema.validate(Config.from_workflow(workflow))
    end

    test "unsupported tracker kind" do
      workflow = %{config: %{tracker: %{kind: "jira"}}, prompt_template: ""}

      assert {:error, {:unsupported_tracker_kind, "jira"}} =
               Schema.validate(Config.from_workflow(workflow))
    end

    test "linear without api_key" do
      workflow = %{
        config: %{tracker: %{kind: "linear", project_slug: "demo"}},
        prompt_template: ""
      }

      System.delete_env("LINEAR_API_KEY")

      assert {:error, :missing_tracker_api_key} =
               Schema.validate(Config.from_workflow(workflow))
    end

    test "linear without project_slug" do
      workflow = %{
        config: %{tracker: %{kind: "linear", api_key: "lin_abc"}},
        prompt_template: ""
      }

      assert {:error, :missing_tracker_project_slug} =
               Schema.validate(Config.from_workflow(workflow))
    end

    test "codex runner without command" do
      assert {:error, :missing_codex_command} =
               Schema.validate(
                 build_config(%{
                   runner: %{kind: "codex"},
                   codex: %{command: ""}
                 })
               )
    end

    test "codex auth with an unknown mode" do
      assert {:error, {:invalid_value, :codex_auth_mode, "bogus"}} =
               Schema.validate(build_config(%{codex: %{auth: %{mode: "bogus"}}}))
    end

    test "codex api_key mode with a blank env var name" do
      assert {:error, {:invalid_value, :codex_auth_api_key_env, ""}} =
               Schema.validate(
                 build_config(%{codex: %{auth: %{mode: "api_key", api_key_env: ""}}})
               )
    end

    test "codex_home mode without a path" do
      assert {:error, {:invalid_value, :codex_auth_codex_home, nil}} =
               Schema.validate(build_config(%{codex: %{auth: %{mode: "codex_home"}}}))
    end

    test "unsupported runner kind" do
      assert {:error, {:unsupported_runner_kind, "magic"}} =
               Schema.validate(build_config(%{runner: %{kind: "magic"}}))
    end

    test "non-positive max_concurrent_agents" do
      assert {:error, {:invalid_value, :max_concurrent_agents, 0}} =
               Schema.validate(build_config(%{agent: %{max_concurrent_agents: 0}}))
    end

    test "non-positive max_turns" do
      assert {:error, {:invalid_value, :max_turns, -1}} =
               Schema.validate(build_config(%{agent: %{max_turns: -1}}))
    end

    test "non-positive polling interval_ms" do
      assert {:error, {:invalid_value, :polling_interval_ms, 0}} =
               Schema.validate(build_config(%{polling: %{interval_ms: 0}}))
    end

    test "non-positive hooks timeout_ms" do
      assert {:error, {:invalid_value, :hooks_timeout_ms, 0}} =
               Schema.validate(build_config(%{hooks: %{timeout_ms: 0}}))
    end
  end

  describe "validate/1 -- tracker state lists" do
    defp memory_config(tracker) do
      Config.from_workflow(%{
        config: %{tracker: Map.merge(%{kind: "memory"}, tracker)},
        prompt_template: ""
      })
    end

    test "an empty active_states key is rejected" do
      assert {:error, {:invalid_value, :tracker_active_states, nil}} =
               Schema.validate(memory_config(%{active_states: nil}))
    end

    test "a scalar active_states is rejected" do
      assert {:error, {:invalid_value, :tracker_active_states, "Todo"}} =
               Schema.validate(memory_config(%{active_states: "Todo"}))
    end

    test "a non-binary state name is rejected" do
      assert {:error, {:invalid_value, :tracker_terminal_states, [1]}} =
               Schema.validate(memory_config(%{terminal_states: [1]}))
    end

    test "an empty list is accepted -- it matches nothing, it does not crash" do
      assert :ok = Schema.validate(memory_config(%{terminal_states: []}))
    end
  end
end
