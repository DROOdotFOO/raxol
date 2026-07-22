defmodule Raxol.Agent.Actions.TaskTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Actions.Task
  alias Raxol.Agent.Backend.Mock

  defp subagent_ctx(response) do
    %{subagent: %{backend: Mock, backend_opts: [response: response]}}
  end

  test "delegates to a sub-agent and returns its final answer" do
    assert {:ok, %{result: "sub result"}} =
             Task.Delegate.run(%{prompt: "investigate"}, subagent_ctx("sub result"))
  end

  test "the task tool is allowed by the default policy (not sensitive)" do
    call = %{"name" => "task", "arguments" => %{"prompt" => "look around"}}

    assert {:ok, %{result: "ok"}} =
             ToolConverter.dispatch_tool_call(call, Task.all(), subagent_ctx("ok"))
  end

  test "task is registered under the read-only-safe name" do
    assert [Task.Delegate] = Task.all()
    assert Task.Delegate.__action_meta__().name == "task"
    refute Task.Delegate.__action_meta__().sensitive
  end
end
