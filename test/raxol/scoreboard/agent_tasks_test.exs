defmodule Raxol.Scoreboard.AgentTasksTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Playground.Demos.TabsDemo
  alias Raxol.Scoreboard.AgentTasks

  test "two runs give identical metrics, every path reaches its goal, no pid or ref text" do
    first = AgentTasks.run()
    second = AgentTasks.run()

    for %{name: name} = result <- first, path <- [:tool, :key] do
      assert {:ok, %{calls: calls}} = Map.fetch!(result, path),
             "#{name} #{path}"

      assert calls > 0
    end

    metrics = AgentTasks.metrics(first)
    assert metrics == AgentTasks.metrics(second)
    assert map_size(metrics) == 4 * length(AgentTasks.tasks())

    # Every id is defined for the record and the CI comparison.
    assert %{"metrics" => ^metrics} =
             Raxol.Scoreboard.record(metrics, String.duplicate("0", 40))

    for result <- first ++ second,
        path <- [:tool, :key],
        {:ok, %{stream: stream}} <- [Map.fetch!(result, path)],
        bytes <- stream do
      refute bytes =~ "#PID<"
      refute bytes =~ "#Reference<"
    end
  end

  test "a path that does not reach its goal is reported as failed, not measured" do
    task = %{
      name: "tabs_switch",
      app: TabsDemo,
      setup: [],
      tool_path: [{"tabs.select_tab", %{"index" => 1}}],
      key_path: ["3"],
      goal: [{[:active], 2}]
    }

    assert {metrics, failures} = AgentTasks.collect([task])

    assert failures == [
             "agent task tabs_switch: the tool path does not reach its goal; not measured"
           ]

    assert metrics |> Map.keys() |> Enum.sort() ==
             ["agent.tabs_switch.key_bytes", "agent.tabs_switch.key_calls"]
  end
end
