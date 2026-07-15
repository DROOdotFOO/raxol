defmodule Raxol.Agent.ToolCall.HookTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Stream, as: AgentStream
  alias Raxol.Agent.ToolCall.Hook

  # -- Probe action -----------------------------------------------------------
  # Sends a trace when run so tests can assert it was (or was NOT) executed.

  defmodule Probe do
    use Raxol.Agent.Action,
      name: "probe",
      description: "Test probe action",
      schema: [
        input: [
          a: [type: :integer, required: true, description: "A number"]
        ]
      ]

    @impl true
    def run(%{a: a} = params, context) do
      if pid = Map.get(context, :test_pid), do: send(pid, {:trace, {:ran, params}})
      {:ok, %{result: a}}
    end
  end

  # -- Test hooks ---------------------------------------------------------------

  defmodule Observer do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(call, context) do
      send(context.test_pid, {:trace, {:observed, call}})
      {:cont, call}
    end
  end

  defmodule TransformingObserver do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(%{params: %{a: a}} = call, context) do
      send(context.test_pid, {:trace, {:hook1, call.params}})
      {:cont, %{call | params: %{call.params | a: a * 2}}}
    end
  end

  defmodule SecondObserver do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(call, context) do
      send(context.test_pid, {:trace, {:hook2, call.params}})
      {:cont, call}
    end
  end

  defmodule Veto do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(_call, context),
      do: {:halt, Map.get(context, :veto_reason, :not_allowed)}
  end

  defmodule Raiser do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(_call, _context), do: raise("hook exploded")
  end

  defmodule BadReturn do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(_call, _context), do: :ok
  end

  defmodule ResultTagger do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(call, _context), do: {:cont, call}

    @impl true
    def after_call(_call, {:ok, output}, _context),
      do: {:ok, Map.put(output, :tagged, true)}

    def after_call(_call, result, _context), do: result
  end

  defmodule AfterRaiser do
    @behaviour Raxol.Agent.ToolCall.Hook

    @impl true
    def before_call(call, _context), do: {:cont, call}

    @impl true
    def after_call(_call, _result, _context), do: raise("after exploded")
  end

  # -- Sequence mock backend (per-call response queue) --------------------------

  defmodule SequenceMock do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, opts) do
      counter = Keyword.fetch!(opts, :counter)
      idx = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      responses = Keyword.get(opts, :responses, [])

      case Enum.at(responses, idx) do
        nil -> {:ok, %{content: "Done.", usage: %{}, metadata: %{}}}
        response -> {:ok, response}
      end
    end

    @impl true
    def available?, do: true
    @impl true
    def name, do: "Sequence Mock"
    @impl true
    def capabilities, do: [:completion, :tool_use]
  end

  # -- Helpers ------------------------------------------------------------------

  defp tool_call(id, name, args), do: %{"id" => id, "name" => name, "arguments" => args}

  defp tool_response(tool_calls),
    do: %{content: "", tool_calls: tool_calls, usage: %{}, metadata: %{}}

  defp text_response(content), do: %{content: content, usage: %{}, metadata: %{}}

  defp context(hooks, extra \\ %{}) do
    Map.merge(%{test_pid: self(), tool_call_hooks: hooks}, extra)
  end

  defp sequence_opts(responses, hooks) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    [
      backend: SequenceMock,
      backend_opts: [counter: counter, responses: responses],
      actions: [Probe],
      context: context(hooks)
    ]
  end

  # Drain all {:trace, t} messages from the mailbox, preserving order.
  defp drain_traces(acc \\ []) do
    receive do
      {:trace, t} -> drain_traces([t | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # -- dispatch_tool_call/3 with hooks ------------------------------------------

  describe "dispatch_tool_call/3 with hooks" do
    test "a no-op observer sees every call with parsed args before execution" do
      tc = tool_call("call_1", "probe", %{"a" => 7})

      assert {:ok, %{result: 7}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([Observer]))

      assert [{:observed, call}, {:ran, ran_params}] = drain_traces()
      assert %{action: Probe, name: "probe", params: %{a: 7}, call_id: "call_1"} = call
      assert ran_params == %{a: 7}
    end

    test "two hooks run in declared order; the second sees the first's transformation" do
      tc = tool_call("call_2", "probe", %{"a" => 3})
      ctx = context([TransformingObserver, SecondObserver])

      assert {:ok, %{result: 6}} = ToolConverter.dispatch_tool_call(tc, [Probe], ctx)

      assert [{:hook1, %{a: 3}}, {:hook2, %{a: 6}}, {:ran, %{a: 6}}] = drain_traces()
    end

    test "a vetoing hook returns a typed error and the action never runs" do
      tc = tool_call("call_3", "probe", %{"a" => 1})

      assert {:error, {:vetoed, :not_allowed}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([Veto]))

      assert drain_traces() == []
    end

    test "the first halt short-circuits later hooks" do
      tc = tool_call("call_4", "probe", %{"a" => 1})

      assert {:error, {:vetoed, :not_allowed}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([Veto, Observer]))

      assert drain_traces() == []
    end

    test "a raising hook is contained as a veto, not a crash" do
      tc = tool_call("call_5", "probe", %{"a" => 1})

      assert {:error, {:vetoed, {:hook_raised, Raiser, "hook exploded"}}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([Raiser]))

      assert drain_traces() == []
    end

    test "an invalid hook return halts with a typed reason" do
      tc = tool_call("call_6", "probe", %{"a" => 1})

      assert {:error, {:vetoed, {:invalid_hook_return, BadReturn, :ok}}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([BadReturn]))

      assert drain_traces() == []
    end

    test "zero hooks: dispatch is identical to the direct action call" do
      tc = tool_call("call_7", "probe", %{"a" => 5})
      ctx = %{test_pid: self()}

      assert ToolConverter.dispatch_tool_call(tc, [Probe], ctx) ==
               Probe.call(%{a: 5}, ctx)
    end

    test "after_call may transform the result" do
      tc = tool_call("call_8", "probe", %{"a" => 2})

      assert {:ok, %{result: 2, tagged: true}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([ResultTagger]))
    end

    test "a raise inside after_call is contained; result passes through unchanged" do
      tc = tool_call("call_9", "probe", %{"a" => 4})

      assert {:ok, %{result: 4}} =
               ToolConverter.dispatch_tool_call(tc, [Probe], context([AfterRaiser]))
    end
  end

  # -- Pipeline unit tests -------------------------------------------------------

  describe "run_before/3" do
    test "empty pipeline passes the call through" do
      call = %{action: Probe, name: "probe", params: %{a: 1}, call_id: nil}
      assert {:cont, ^call} = Hook.run_before([], call, %{})
    end
  end

  describe "from_context/1" do
    test "reads the ordered list, defaulting to []" do
      assert Hook.from_context(%{tool_call_hooks: [Observer]}) == [Observer]
      assert Hook.from_context(%{}) == []
      assert Hook.from_context(nil) == []
    end
  end

  # -- React loop integration ----------------------------------------------------

  describe "Stream.react/2 with hooks" do
    test "a veto surfaces on the tool_result event and the loop continues" do
      responses = [
        tool_response([tool_call("1", "probe", %{"a" => 1})]),
        text_response("Recovered")
      ]

      events = AgentStream.react("go", sequence_opts(responses, [Veto])) |> Enum.to_list()

      assert Enum.any?(
               events,
               &match?(
                 {:tool_result, %{name: "probe", result: {:error, {:vetoed, :not_allowed}}}},
                 &1
               )
             )

      assert {:done, %{content: "Recovered"}} = List.last(events)
      assert drain_traces() == []
    end

    test "an observer sees every tool call in order before execution" do
      responses = [
        tool_response([
          tool_call("1", "probe", %{"a" => 1}),
          tool_call("2", "probe", %{"a" => 2})
        ]),
        text_response("Done")
      ]

      events =
        AgentStream.react("go", sequence_opts(responses, [Observer])) |> Enum.to_list()

      assert {:done, %{content: "Done"}} = List.last(events)

      assert [
               {:observed, %{name: "probe", params: %{a: 1}, call_id: "1"}},
               {:ran, %{a: 1}},
               {:observed, %{name: "probe", params: %{a: 2}, call_id: "2"}},
               {:ran, %{a: 2}}
             ] = drain_traces()
    end

    test "a raising hook does not crash the loop" do
      responses = [
        tool_response([tool_call("1", "probe", %{"a" => 1})]),
        text_response("Still alive")
      ]

      events = AgentStream.react("go", sequence_opts(responses, [Raiser])) |> Enum.to_list()

      assert Enum.any?(
               events,
               &match?(
                 {:tool_result, %{result: {:error, {:vetoed, {:hook_raised, Raiser, _}}}}},
                 &1
               )
             )

      assert {:done, %{content: "Still alive"}} = List.last(events)
      assert drain_traces() == []
    end
  end
end
