defmodule Raxol.Agent.StreamTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Stream, as: AgentStream

  # -- Test Actions -----------------------------------------------------------

  defmodule AddNumbers do
    use Raxol.Agent.Action,
      name: "add_numbers",
      description: "Add two numbers",
      schema: [
        input: [
          a: [type: :integer, required: true, description: "First number"],
          b: [type: :integer, required: true, description: "Second number"]
        ]
      ]

    @impl true
    def run(%{a: a, b: b}, _ctx), do: {:ok, %{result: a + b}}
  end

  defmodule FormatResult do
    use Raxol.Agent.Action,
      name: "format_result",
      description: "Format a number as text",
      schema: [
        input: [
          value: [type: :integer, required: true, description: "Value to format"]
        ]
      ]

    @impl true
    def run(%{value: v}, _ctx), do: {:ok, %{formatted: "Result: #{v}"}}
  end

  # -- Sequence Mock Backend --------------------------------------------------

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

  # -- Helpers ----------------------------------------------------------------

  defp mock_opts(response) do
    [backend: Raxol.Agent.Backend.Mock, backend_opts: [response: response]]
  end

  defp mock_error_opts(reason) do
    [backend: Raxol.Agent.Backend.Mock, backend_opts: [error: reason]]
  end

  defp sequence_opts(responses, actions \\ [AddNumbers]) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    [
      backend: SequenceMock,
      backend_opts: [counter: counter, responses: responses],
      actions: actions
    ]
  end

  defp tool_call(id, name, args) do
    %{"id" => id, "name" => name, "arguments" => args}
  end

  defp tool_response(tool_calls) do
    %{content: "", tool_calls: tool_calls, usage: %{}, metadata: %{}}
  end

  defp text_response(content, extra \\ %{}) do
    Map.merge(%{content: content, usage: %{}, metadata: %{}}, extra)
  end

  # -- run/2 tests ------------------------------------------------------------

  describe "run/2" do
    test "streams a simple completion" do
      assert [{:text_delta, "Hi there!"}, {:done, done}] =
               AgentStream.run("Hello", mock_opts("Hi there!")) |> Enum.to_list()

      assert done.content == "Hi there!"
      assert done.tool_results == []
    end

    test "with system prompt" do
      opts = mock_opts("I am helpful.") ++ [system_prompt: "You are helpful."]

      assert [{:text_delta, _}, {:done, _}] =
               AgentStream.run("Hello", opts) |> Enum.to_list()
    end

    test "with pre-built messages list" do
      messages = [
        %{role: :system, content: "Be brief."},
        %{role: :user, content: "Hi"}
      ]

      assert [{:text_delta, "Ok."}, {:done, _}] =
               AgentStream.run(messages, mock_opts("Ok.")) |> Enum.to_list()
    end

    test "handles backend error" do
      assert [{:error, :rate_limited}] =
               AgentStream.run("Will fail", mock_error_opts(:rate_limited))
               |> Enum.to_list()
    end

    test "stream: false uses sync completion" do
      opts = mock_opts("Sync response") ++ [stream: false]

      assert [{:text_delta, "Sync response"}, {:done, done}] =
               AgentStream.run("Hello", opts) |> Enum.to_list()

      assert done.content == "Sync response"
    end
  end

  # -- react/2 tests ----------------------------------------------------------

  describe "react/2" do
    test "returns done when LLM responds with text immediately" do
      opts = mock_opts("The answer is 42.") ++ [actions: [AddNumbers]]

      assert [{:done, done}] = AgentStream.react("Hello", opts) |> Enum.to_list()
      assert done.content == "The answer is 42."
    end

    test "emits tool_use and tool_result events" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 3, "b" => 4})]),
        text_response("The sum is 7.", %{usage: %{input_tokens: 10}})
      ]

      events = AgentStream.react("Add 3 and 4", sequence_opts(responses)) |> Enum.to_list()

      assert [
               {:tool_use, tu},
               {:tool_result, tr},
               {:turn_complete, tc},
               {:done, done}
             ] = events

      assert tu.name == "add_numbers"
      assert tu.arguments == %{"a" => 3, "b" => 4}
      assert tr.name == "add_numbers"
      assert tr.result == %{result: 7}
      assert tc.iteration == 0
      assert done.content == "The sum is 7."
    end

    test "handles multiple iterations" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 1, "b" => 2})]),
        tool_response([tool_call("c2", "format_result", %{"value" => 3})]),
        text_response("1+2=3, formatted as 'Result: 3'")
      ]

      events =
        AgentStream.react("Add then format", sequence_opts(responses, [AddNumbers, FormatResult]))
        |> Enum.to_list()

      assert length(Enum.filter(events, &match?({:tool_use, _}, &1))) == 2
      assert length(Enum.filter(events, &match?({:tool_result, _}, &1))) == 2
      assert length(Enum.filter(events, &match?({:turn_complete, _}, &1))) == 2

      assert {:done, done} = List.last(events)
      assert done.content == "1+2=3, formatted as 'Result: 3'"
    end

    test "respects max_iterations" do
      infinite = tool_response([tool_call("c", "add_numbers", %{"a" => 1, "b" => 1})])
      opts = sequence_opts(List.duplicate(infinite, 10)) ++ [max_iterations: 2]

      events = AgentStream.react("Loop forever", opts) |> Enum.to_list()

      assert {:error, :max_iterations_reached} = List.last(events)
    end

    test "handles backend error" do
      opts = mock_error_opts(:rate_limited) ++ [actions: [AddNumbers]]

      assert [{:error, :rate_limited}] =
               AgentStream.react("Will fail", opts) |> Enum.to_list()
    end

    test "with system prompt" do
      opts = mock_opts("I'm helpful.") ++ [actions: [], system_prompt: "You are helpful."]

      assert [{:done, done}] = AgentStream.react("Hello", opts) |> Enum.to_list()
      assert done.content == "I'm helpful."
    end
  end

  # -- Filter helpers ---------------------------------------------------------

  describe "text_deltas/1" do
    test "extracts text from deltas" do
      texts =
        AgentStream.run("Hi", mock_opts("Hello!"))
        |> AgentStream.text_deltas()
        |> Enum.to_list()

      assert texts == ["Hello!"]
    end

    test "excludes done content (only raw deltas)" do
      opts = mock_opts("World") ++ [stream: false]

      texts =
        AgentStream.run("Hi", opts)
        |> AgentStream.text_deltas()
        |> Enum.to_list()

      assert texts == ["World"]
    end
  end

  describe "tool_uses/1" do
    test "filters to tool use events only" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 1, "b" => 2})]),
        text_response("Done.")
      ]

      assert [{:tool_use, tu}] =
               AgentStream.react("Add", sequence_opts(responses))
               |> AgentStream.tool_uses()
               |> Enum.to_list()

      assert tu.name == "add_numbers"
    end
  end

  describe "tool_results/1" do
    test "filters to tool result events only" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 5, "b" => 3})]),
        text_response("8")
      ]

      assert [{:tool_result, tr}] =
               AgentStream.react("Add 5+3", sequence_opts(responses))
               |> AgentStream.tool_results()
               |> Enum.to_list()

      assert tr.name == "add_numbers"
      assert tr.result == %{result: 8}
    end
  end

  # -- collect/1 and collect_text/1 -------------------------------------------

  describe "collect/1" do
    test "collects final done info" do
      assert {:ok, done} =
               AgentStream.run("Hi", mock_opts("Hey!"))
               |> AgentStream.collect()

      assert done.content == "Hey!"
    end

    test "returns error on failure" do
      assert {:error, :rate_limited} =
               AgentStream.run("Fail", mock_error_opts(:rate_limited))
               |> AgentStream.collect()
    end
  end

  describe "collect_text/1" do
    test "joins all text into a single string" do
      text =
        AgentStream.run("Hi", mock_opts("Hello world!"))
        |> AgentStream.collect_text()

      assert text == "Hello world!"
    end
  end

  # -- Composability with Stream ----------------------------------------------

  describe "composability" do
    test "works with Stream.take" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 1, "b" => 1})]),
        tool_response([tool_call("c2", "add_numbers", %{"a" => 2, "b" => 2})]),
        text_response("Done.")
      ]

      events =
        AgentStream.react("Add things", sequence_opts(responses))
        |> Stream.take(2)
        |> Enum.to_list()

      assert length(events) == 2
    end

    test "works with Stream.filter" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 1, "b" => 2})]),
        text_response("Three.")
      ]

      assert [{:done, %{content: "Three."}}] =
               AgentStream.react("Add", sequence_opts(responses))
               |> Stream.filter(&match?({:done, _}, &1))
               |> Enum.to_list()
    end

    test "works with Enum.reduce" do
      responses = [
        tool_response([tool_call("c1", "add_numbers", %{"a" => 10, "b" => 20})]),
        text_response("30")
      ]

      tool_count =
        AgentStream.react("Add", sequence_opts(responses))
        |> Enum.count(&(match?({:tool_use, _}, &1) or match?({:tool_result, _}, &1)))

      assert tool_count == 2
    end
  end

  # -- Backend resolution (executor + model override) -------------------------

  defmodule EchoModelBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, opts) do
      {:ok, %{content: "model=#{inspect(Keyword.get(opts, :model))}", usage: %{}, metadata: %{}}}
    end

    @impl true
    def available?, do: true
    @impl true
    def name, do: "Echo Model"
    @impl true
    def capabilities, do: [:completion]
  end

  describe "backend resolution" do
    test ":model overrides the backend_opts model" do
      text =
        "hi"
        |> AgentStream.run(
          backend: EchoModelBackend,
          backend_opts: [model: "base"],
          model: "override",
          stream: false
        )
        |> AgentStream.collect_text()

      assert text == "model=\"override\""
    end

    test "backend_opts model is used when no :model override is given" do
      text =
        "hi"
        |> AgentStream.run(
          backend: EchoModelBackend,
          backend_opts: [model: "base"],
          stream: false
        )
        |> AgentStream.collect_text()

      assert text == "model=\"base\""
    end

    test ":executor selects the backend module" do
      cfg = Raxol.Agent.ExecutorConfig.new(harness: :mock)

      {:ok, info} =
        "hi"
        |> AgentStream.run(executor: cfg, backend_opts: [response: "from-mock"], stream: false)
        |> AgentStream.collect()

      assert info.content == "from-mock"
    end

    test ":executor takes precedence over :backend" do
      cfg = Raxol.Agent.ExecutorConfig.new(harness: :mock)

      {:ok, info} =
        "hi"
        |> AgentStream.run(
          executor: cfg,
          backend: EchoModelBackend,
          backend_opts: [response: "from-mock"],
          stream: false
        )
        |> AgentStream.collect()

      # Mock (resolved from executor) wins over the explicit EchoModelBackend.
      assert info.content == "from-mock"
    end

    test "falls back to :backend when the executor harness is unresolvable" do
      cfg = Raxol.Agent.ExecutorConfig.new(harness: :codex)

      text =
        "hi"
        |> AgentStream.run(
          executor: cfg,
          backend: EchoModelBackend,
          backend_opts: [model: "fallback"],
          stream: false
        )
        |> AgentStream.collect_text()

      assert text == "model=\"fallback\""
    end
  end

  # -- Native (vendor-owns-loop) backends -------------------------------------

  defmodule FakeNativeBackend do
    @behaviour Raxol.Agent.AIBackend

    @impl true
    def complete(_messages, opts) do
      report(opts)
      {:ok, %{content: "native answer", usage: %{}, metadata: %{}}}
    end

    @impl true
    def stream(_messages, opts) do
      report(opts)
      {:ok, [{:chunk, "native answer"}, {:done, %{content: "native answer", usage: %{}}}]}
    end

    @impl true
    def available?, do: true
    @impl true
    def name, do: "Fake Native"
    @impl true
    def capabilities, do: [:completion, :streaming, :tool_use]
    @impl true
    def handles_tools_internally?, do: true

    defp report(opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:native_opts, opts})
    end
  end

  describe "react/2 with a native backend" do
    test "streams the vendor output without running the framework tool loop" do
      events =
        AgentStream.react("hi",
          backend: FakeNativeBackend,
          backend_opts: [test_pid: self()],
          actions: [AddNumbers]
        )
        |> Enum.to_list()

      assert {:done, %{content: "native answer"}} = List.last(events)
      assert Enum.any?(events, &match?({:text_delta, "native answer"}, &1))
      # The vendor owns the loop, so the framework emits no tool_use events.
      refute Enum.any?(events, &match?({:tool_use, _}, &1))
    end

    test "injects the agent's Actions into the native backend opts (for MCP)" do
      AgentStream.react("hi",
        backend: FakeNativeBackend,
        backend_opts: [test_pid: self()],
        actions: [AddNumbers]
      )
      |> Stream.run()

      assert_receive {:native_opts, opts}
      assert AddNumbers in Keyword.get(opts, :actions, [])
    end
  end
end
