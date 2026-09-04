defmodule Raxol.Symphony.Runners.RaxolAgent.SelfImproveTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Memory.SessionSearch
  alias Raxol.Agent.Memory.Store.Ets, as: Mem
  alias Raxol.Agent.Skills.Store, as: Skills
  alias Raxol.Symphony.Runners.RaxolAgent.SelfImprove

  # The orchestrator allocates a per-issue workspace and the runner requires
  # it; these cases assert other behaviour, so any path will do.
  @workspace "/tmp/raxol-symphony-test-workspace"

  defmodule DemoAgent do
    use Raxol.Agent
    def skills_provider, do: Raxol.Agent.Skills.Store
    def memory_provider, do: Raxol.Agent.Memory.Store.Ets

    def self_improve do
      %{
        enabled: true,
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [response: ~s({"memories":[],"skills":[]})],
        min_tool_calls: 0
      }
    end
  end

  defmodule PlainAgent do
    use Raxol.Agent
  end

  setup do
    base = Path.join(System.tmp_dir!(), "symsi_#{uid()}")
    File.mkdir_p!(Path.join(base, "skills"))
    on_exit(fn -> File.rm_rf(base) end)

    mem = start(Mem, name: :"mem_#{uid()}")

    skills =
      start(Skills,
        name: :"sk_#{uid()}",
        skills_root: Path.join(base, "skills"),
        external_dirs: []
      )

    ss = start(SessionSearch, name: :"ss_#{uid()}")

    config = %{
      runner: %{
        agent: %{
          module: DemoAgent,
          self_improve_opts: %{
            memory_opts: [server: mem],
            skills_opts: [server: skills],
            session_search: ss
          }
        }
      }
    }

    %{config: config, ss: ss, mem: mem, skills: skills}
  end

  describe "configured?/1" do
    test "true for a self-improving agent module", %{config: config} do
      assert SelfImprove.configured?(config)
    end

    test "false without a module or without self_improve" do
      refute SelfImprove.configured?(%{runner: %{agent: %{module: PlainAgent}}})
      refute SelfImprove.configured?(%{runner: %{agent: %{}}})
      refute SelfImprove.configured?(%{})
    end
  end

  describe "events_to_items/2" do
    test "maps forwarded payloads to items with identity" do
      events = [
        %{event: :text_delta, message: "I ran "},
        %{event: :tool_use, payload: %{name: "shell", arguments: %{cmd: "ls"}, id: "t1"}},
        %{event: :text_delta, message: "flyctl deploy"},
        %{event: :turn_completed, usage: %{}}
      ]

      items = SelfImprove.events_to_items(events, "c1")

      tool = Enum.find(items, &(&1.type == :tool_call))
      assert tool.data.name == "shell"
      assert tool.conversation_id == "c1"

      message = Enum.find(items, &(&1.type == :message))
      assert message.data.content == "I ran flyctl deploy"
      assert is_integer(message.seq)
    end

    test "a failure becomes an error item" do
      items = SelfImprove.events_to_items([%{event: :turn_failed, message: "boom"}], "c1")
      assert [%{type: :error, data: %{reason: "boom"}}] = items
    end
  end

  describe "fire/3" do
    test "feeds the turn into the session-search index", %{config: config, ss: ss} do
      events = [%{event: :text_delta, message: "deployed with flyctl"}, %{event: :turn_completed}]

      assert :ok = SelfImprove.fire(config, %{id: 42}, events)
      assert [%{conversation_id: "42"}] = SessionSearch.search(ss, "flyctl")
    end

    test "is a no-op when not configured", %{ss: ss} do
      assert :ok = SelfImprove.fire(%{runner: %{agent: %{module: PlainAgent}}}, %{id: 1}, [])
      assert SessionSearch.search(ss, "anything") == []
    end

    test "never raises when a configured store is missing" do
      config = %{
        runner: %{
          agent: %{module: DemoAgent, self_improve_opts: %{session_search: :missing_server}}
        }
      }

      assert :ok = SelfImprove.fire(config, %{id: 1}, [%{event: :text_delta, message: "x"}])
    end
  end

  describe "simple run/3 path" do
    alias Raxol.Symphony.Config
    alias Raxol.Symphony.Issue
    alias Raxol.Symphony.Runners.RaxolAgent
    alias Raxol.Symphony.Trackers.Memory, as: Tracker

    test "fires the hook and feeds session_search after a real turn", %{
      ss: ss,
      mem: mem,
      skills: skills
    } do
      start_supervised!({Tracker, []})
      issue = %Issue{id: "issue-9", identifier: "MT-9", title: "Ship it", state: "Todo"}
      Tracker.put_issue(%{issue | state: "Done"})

      config =
        Config.from_workflow(%{
          config: %{
            tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
            agent: %{max_turns: 1},
            runner: %{
              kind: "raxol_agent",
              agent: %{
                backend: "mock",
                response: "deployed via flyctl",
                module: DemoAgent,
                self_improve_opts: %{
                  memory_opts: [server: mem],
                  skills_opts: [server: skills],
                  session_search: ss
                }
              }
            }
          },
          prompt_template: "Work on {{ issue.identifier }}"
        })

      assert :ok = RaxolAgent.run(issue, config, parent: self(), workspace_path: @workspace)
      assert [%{conversation_id: "issue-9"}] = SessionSearch.search(ss, "flyctl")
    end
  end

  defp start(mod, opts) do
    name = Keyword.fetch!(opts, :name)
    start_supervised!(%{id: name, start: {mod, :start_link, [opts]}})
    name
  end

  defp uid, do: System.unique_integer([:positive])
end
