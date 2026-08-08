defmodule Raxol.Agent.Actions.TaskTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Actions.Task
  alias Raxol.Agent.Backend.Mock

  # A probe backend at the LLM boundary: first turn asks the sub-agent to
  # read `opts[:path]`; second turn (recognized by the assistant tool-call
  # message now in history) echoes the last message verbatim, so the sub-agent's
  # final answer IS the tool result. That makes the sub-agent's jail visible.
  defmodule EchoReadBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(messages, opts) do
      path = Keyword.fetch!(opts, :path)

      if Enum.any?(messages, &(Map.get(&1, :role) == :assistant)) do
        last = messages |> List.last() |> Map.get(:content) |> to_string()
        {:ok, %{content: last, usage: %{}, metadata: %{}}}
      else
        {:ok,
         %{
           content: "",
           tool_calls: [
             %{"id" => "c1", "name" => "read_file", "arguments" => %{"path" => path}}
           ],
           usage: %{},
           metadata: %{}
         }}
      end
    end

    @impl true
    def stream(messages, opts) do
      {:ok, response} = complete(messages, opts)
      {:ok, [{:chunk, response.content}, {:done, response}]}
    end

    @impl true
    def available?, do: true
    @impl true
    def name, do: "EchoReadBackend"
    @impl true
    def capabilities, do: [:completion, :streaming, :tool_use]
  end

  defp subagent_ctx(response) do
    %{subagent: %{backend: Mock, backend_opts: [response: response]}}
  end

  # Two rounds, each reporting real usage and a billed model, so the drain has
  # something to meter on both the tool round and the final answer.
  defmodule MeteredBackend do
    @moduledoc false
    @behaviour Raxol.Agent.Backend

    @impl true
    def complete(messages, _opts) do
      if Enum.any?(messages, &(Map.get(&1, :role) == :assistant)) do
        {:ok,
         %{
           content: "done",
           usage: %{input_tokens: 20, output_tokens: 2},
           metadata: %{model: "gpt-4o"}
         }}
      else
        {:ok,
         %{
           content: "",
           tool_calls: [
             %{"id" => "c1", "name" => "glob", "arguments" => %{"pattern" => "*"}}
           ],
           usage: %{input_tokens: 10, output_tokens: 1},
           metadata: %{model: "gpt-4o"}
         }}
      end
    end

    @impl true
    def stream(messages, opts) do
      {:ok, response} = complete(messages, opts)
      {:ok, [{:chunk, response.content}, {:done, response}]}
    end

    @impl true
    def available?, do: true
    @impl true
    def name, do: "MeteredBackend"
    @impl true
    def capabilities, do: [:completion, :streaming, :tool_use]
  end

  test "each sub-agent round is reported to the usage sink" do
    # Every round is a paid provider call on the parent's executor. Without the
    # sink they died inside the nested stream, so a delegation could overrun a
    # spending cap by an arbitrary multiple while the ledger read as unspent.
    test_pid = self()

    context = %{
      subagent: %{backend: MeteredBackend, backend_opts: []},
      usage_sink: fn info -> send(test_pid, {:usage, info}) end
    }

    assert {:ok, %{result: _}} = Task.Delegate.run(%{prompt: "look"}, context)

    assert_receive {:usage, %{usage: %{input_tokens: 10}, model: "gpt-4o"}}
    assert_receive {:usage, %{usage: %{input_tokens: 20}, model: "gpt-4o"}}
  end

  test "a sub-agent still works with no usage sink wired" do
    assert {:ok, %{result: "sub result"}} =
             Task.Delegate.run(%{prompt: "investigate"}, subagent_ctx("sub result"))
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

  describe "sub-agent jail inheritance" do
    setup do
      base =
        Path.join(
          System.tmp_dir!(),
          "raxol-task-jail-#{System.os_time(:millisecond)}-" <>
            "#{System.unique_integer([:positive])}"
        )

      jail = Path.join(base, "work")
      File.mkdir_p!(jail)
      File.write!(Path.join(jail, "inside.txt"), "INSIDE-JAIL-CONTENT")

      secret = Path.join(base, "secret.txt")
      File.write!(secret, "TOP-SECRET-OUTSIDE-JAIL")

      on_exit(fn -> File.rm_rf!(base) end)
      %{jail: jail, secret: secret}
    end

    defp jailed_ctx(jail, path) do
      %{
        cwd: jail,
        jail: true,
        subagent: %{backend: EchoReadBackend, backend_opts: [path: path]}
      }
    end

    test "the sub-agent's read tool inherits the parent cwd", %{jail: jail} do
      # A relative path resolves INSIDE the parent jail only because :cwd was
      # threaded into the sub-agent context. Without it, the sub-agent re-roots
      # at the process-global cwd and this uniquely-named file does not exist.
      assert {:ok, %{result: result}} =
               Task.Delegate.run(%{prompt: "read it"}, jailed_ctx(jail, "inside.txt"))

      assert result =~ "INSIDE-JAIL-CONTENT"
    end

    test "the sub-agent cannot read outside the parent jail", %{
      jail: jail,
      secret: secret
    } do
      # An absolute path outside the jail must be refused by the sub-agent's
      # read tool (the confinement is inherited), so the secret never surfaces.
      assert {:ok, %{result: result}} =
               Task.Delegate.run(%{prompt: "read it"}, jailed_ctx(jail, secret))

      refute result =~ "TOP-SECRET-OUTSIDE-JAIL"
    end
  end
end
