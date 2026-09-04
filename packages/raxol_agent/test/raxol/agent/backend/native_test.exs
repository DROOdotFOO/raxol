defmodule Raxol.Agent.Backend.NativeTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Backend.Native

  @fake_cli Path.expand("../../../support/fake_stream_cli.sh", __DIR__)

  # A driver whose "CLI" is the fake stream-json script. The scenario is passed
  # through `extra_args` so each test can drive a different code path.
  defmodule FakeDriver do
    @behaviour Raxol.Agent.NativeHarness

    @script Path.expand("../../../support/fake_stream_cli.sh", __DIR__)

    @impl true
    def executable, do: @script
    @impl true
    def name, do: "Fake"
    @impl true
    def parse_line(line), do: Raxol.Agent.Harness.StreamJson.parse_line(line)

    @impl true
    def args(config) do
      case Map.get(config, :extra_args, []) do
        [] -> ["happy"]
        scenario -> scenario
      end
    end
  end

  defp messages, do: [%{role: :user, content: "hello"}]

  defp run_scenario(scenario) do
    {:ok, stream} = Native.stream(FakeDriver, messages(), extra_args: [scenario])
    Enum.to_list(stream)
  end

  describe "stream/3" do
    test "streams text chunks then a done event with the final content and usage" do
      events = run_scenario("happy")

      assert [{:chunk, "Hello "}, {:chunk, "world"}, {:done, done}] = events
      assert done.content == "Hello world"
      assert done.usage == %{"input_tokens" => 3, "output_tokens" => 2}
    end

    test "tool_use blocks are not surfaced as text (the MCP server owns execution)" do
      events = run_scenario("tool")
      texts = for {:chunk, t} <- events, do: t
      assert texts == ["done"]
      assert {:done, %{content: "done"}} = List.last(events)
    end

    test "an error result becomes an error event" do
      assert [{:error, {:result_error, "error_max_turns", "too long"}}] = run_scenario("error")
    end

    test "a non-zero exit with no result line becomes an exit error" do
      assert [{:error, {:exit, 3}}] = run_scenario("exit_nonzero")
    end

    test "a clean exit without a result line synthesizes a done from accumulated text" do
      events = run_scenario("no_done")
      assert [{:chunk, "partial"}, {:done, %{content: "partial"}}] = events
    end

    test "a CLI that reads stdin sees EOF instead of an open pipe" do
      # The port is never written to, so a child that reads stdin before doing
      # its work blocks until the run times out. The short timeout keeps the
      # regression cheap to observe: without `:in` this is `{:error, :timeout}`.
      {:ok, stream} =
        Native.stream(FakeDriver, messages(), extra_args: ["stdin_read"], timeout: 2_000)

      assert [{:done, %{content: "read stdin"}}] = Enum.to_list(stream)
    end

    test "returns an error when the executable is not found" do
      defmodule MissingDriver do
        @behaviour Raxol.Agent.NativeHarness
        @impl true
        def executable, do: "definitely_not_a_real_binary_xyz"
        @impl true
        def name, do: "Missing"
        @impl true
        def args(_), do: []
        @impl true
        def parse_line(_), do: []
      end

      assert {:error, {:executable_not_found, "definitely_not_a_real_binary_xyz"}} =
               Native.stream(MissingDriver, messages(), [])
    end
  end

  describe "complete/3" do
    test "drains the stream and returns the final response" do
      assert {:ok, %{content: "Hello world", usage: %{"input_tokens" => 3}}} =
               Native.complete(FakeDriver, messages(), extra_args: ["happy"])
    end

    test "propagates an error result" do
      assert {:error, {:result_error, "error_max_turns", _}} =
               Native.complete(FakeDriver, messages(), extra_args: ["error"])
    end
  end

  test "the fake CLI script exists and is executable" do
    assert File.exists?(@fake_cli)
  end

  # -- Macro-built vendor backends --------------------------------------------

  describe "Backend.ClaudeCode / Backend.Cursor" do
    test "report they handle tools internally" do
      assert Raxol.Agent.Backend.ClaudeCode.handles_tools_internally?()
      assert Raxol.Agent.Backend.Cursor.handles_tools_internally?()
    end

    test "expose their driver and a streaming capability" do
      assert Raxol.Agent.Backend.ClaudeCode.driver() == Raxol.Agent.Harness.ClaudeCode
      assert Raxol.Agent.Backend.Cursor.driver() == Raxol.Agent.Harness.Cursor
      assert :streaming in Raxol.Agent.Backend.ClaudeCode.capabilities()
    end

    test "available?/0 returns a boolean (depends on the CLI being installed)" do
      assert is_boolean(Raxol.Agent.Backend.ClaudeCode.available?())
      assert is_boolean(Raxol.Agent.Backend.Cursor.available?())
    end

    test "names come from the driver" do
      assert Raxol.Agent.Backend.ClaudeCode.name() == "Claude Code"
      assert Raxol.Agent.Backend.Cursor.name() == "Cursor"
    end
  end
end
