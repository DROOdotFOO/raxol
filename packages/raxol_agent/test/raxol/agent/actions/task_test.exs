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

  describe "fan-out" do
    # A backend that blocks until released, so concurrency is observable
    # rather than inferred from wall-clock timing.
    defmodule GateBackend do
      @behaviour Raxol.Agent.AIBackend

      @impl true
      def complete(_messages, opts) do
        test = Keyword.fetch!(opts, :test)
        send(test, {:entered, self()})

        receive do
          :release -> {:ok, %{content: "done", usage: %{}, metadata: %{}}}
        after
          5_000 -> {:error, :never_released}
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
      def name, do: "GateBackend"
      @impl true
      def capabilities, do: [:completion, :streaming, :tool_use]
    end

    defmodule CrashBackend do
      @behaviour Raxol.Agent.AIBackend

      @impl true
      def complete(_messages, opts) do
        if Keyword.fetch!(opts, :crash?) do
          exit(:boom)
        else
          {:ok, %{content: "survived", usage: %{}, metadata: %{}}}
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
      def name, do: "CrashBackend"
      @impl true
      def capabilities, do: [:completion, :streaming, :tool_use]
    end

    test "runs every prompt and returns results in the order given" do
      assert {:ok, %{results: results}} =
               Task.Delegate.run(
                 %{prompts: ["one", "two", "three"]},
                 subagent_ctx("sub result")
               )

      assert length(results) == 3
      assert Enum.map(results, & &1.index) == [1, 2, 3]
      assert Enum.map(results, & &1.prompt) == ["one", "two", "three"]
      assert Enum.all?(results, &(&1.status == "ok"))
      assert Enum.all?(results, &(&1.result == "sub result"))
    end

    test "delegations run concurrently, not one after another" do
      test = self()

      spawn_link(fn ->
        send(
          test,
          {:fanout,
           Task.Delegate.run(
             %{prompts: ["a", "b", "c"]},
             %{subagent: %{backend: GateBackend, backend_opts: [test: test]}}
           )}
        )
      end)

      # All three enter the backend before any is released: they are in
      # flight together, which a sequential loop could not produce.
      entered =
        for _ <- 1..3 do
          assert_receive {:entered, pid}, 5_000
          pid
        end

      assert length(Enum.uniq(entered)) == 3
      Enum.each(entered, &send(&1, :release))

      assert_receive {:fanout, {:ok, %{results: results}}}, 5_000
      assert Enum.all?(results, &(&1.status == "ok"))
    end

    test "one crashing delegation does not take down its siblings" do
      # The supervised, unlinked path is the one under test.
      start_supervised!({Elixir.Task.Supervisor, name: Raxol.Agent.TaskSupervisor})

      assert {:ok, %{results: [first, second]}} =
               Task.Delegate.run(
                 %{prompts: ["crash", "survive"]},
                 %{subagent: %{backend: CrashBackend, backend_opts: [crash?: false]}}
               )

      assert first.status == "ok"
      assert second.status == "ok"
    end

    test "a crashing delegation is reported as a failed entry" do
      start_supervised!({Elixir.Task.Supervisor, name: Raxol.Agent.TaskSupervisor})

      assert {:ok, %{results: [entry]}} =
               Task.Delegate.run(
                 %{prompts: ["crash"]},
                 %{subagent: %{backend: CrashBackend, backend_opts: [crash?: true]}}
               )

      assert entry.status == "error"
      assert entry.index == 1
      assert entry.prompt == "crash"
    end

    test "refuses more prompts than the cap rather than trimming" do
      prompts = Enum.map(1..9, &"task #{&1}")

      assert {:error, {:too_many_prompts, 9, 8}} =
               Task.Delegate.run(%{prompts: prompts}, subagent_ctx("x"))
    end

    test "refuses a blank entry" do
      assert {:error, :blank_prompt} =
               Task.Delegate.run(%{prompts: ["fine", "  "]}, subagent_ctx("x"))
    end

    test "refuses an empty list" do
      assert {:error, :no_prompt} =
               Task.Delegate.run(%{prompts: []}, subagent_ctx("x"))
    end

    test "refuses both prompt and prompts" do
      assert {:error, :ambiguous_prompt} =
               Task.Delegate.run(
                 %{prompt: "one", prompts: ["two"]},
                 subagent_ctx("x")
               )
    end

    test "refuses neither prompt nor prompts" do
      assert {:error, :no_prompt} = Task.Delegate.run(%{}, subagent_ctx("x"))
    end
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
