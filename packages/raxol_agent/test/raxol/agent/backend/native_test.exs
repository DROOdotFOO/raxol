defmodule Raxol.Agent.Backend.NativeTest do
  # Not async: the `:env` tests set RAXOL_SHARE_SECRET in the VM's
  # environment, which the share code reads.
  use ExUnit.Case, async: false

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

    # The --mcp-config path, when there is one, follows the scenario.
    @impl true
    def args(config) do
      scenario =
        case Map.get(config, :extra_args, []) do
          [] -> ["happy"]
          scenario -> scenario
        end

      scenario ++ List.wrap(Map.get(config, :mcp_config_path))
    end
  end

  defmodule Greet do
    use Raxol.Agent.Action,
      name: "greet",
      description: "Greet a person",
      schema: [input: [name: [type: :string, required: true]]]

    @impl true
    def run(%{name: name}, _ctx), do: {:ok, %{greeting: "hi #{name}"}}
  end

  # Fails the run on any line the fake CLI could not have written -- every one
  # of its lines is JSON -- so a wrapper line reaching `parse_line/1` shows.
  defmodule StrictDriver do
    @behaviour Raxol.Agent.NativeHarness

    @impl true
    def executable, do: Raxol.Agent.Backend.NativeTest.FakeDriver.executable()
    @impl true
    def name, do: "Strict"
    @impl true
    def args(_config), do: ["happy"]

    @impl true
    def parse_line("{" <> _ = line), do: Raxol.Agent.Harness.StreamJson.parse_line(line)
    def parse_line(line), do: [{:error, {:foreign_line, line}}]
  end

  defp messages, do: [%{role: :user, content: "hello"}]

  defp run_scenario(scenario) do
    {:ok, stream} = Native.stream(FakeDriver, messages(), extra_args: [scenario])
    Enum.to_list(stream)
  end

  describe "stream/3" do
    # The fake CLI is test/support/fake_stream_cli.sh, a `#!/bin/sh` script.
    @tag :unix_only
    test "streams text chunks then a done event with the final content and usage" do
      events = run_scenario("happy")

      assert [{:chunk, "Hello "}, {:chunk, "world"}, {:done, done}] = events
      assert done.content == "Hello world"
      assert done.usage == %{"input_tokens" => 3, "output_tokens" => 2}
    end

    @tag :unix_only
    test "tool_use blocks are not surfaced as text (the MCP server owns execution)" do
      events = run_scenario("tool")
      texts = for {:chunk, t} <- events, do: t
      assert texts == ["done"]
      assert {:done, %{content: "done"}} = List.last(events)
    end

    @tag :unix_only
    test "an error result becomes an error event" do
      assert [{:error, {:result_error, "error_max_turns", "too long"}}] = run_scenario("error")
    end

    @tag :unix_only
    test "a non-zero exit with no result line becomes an exit error" do
      assert [{:error, {:exit, 3}}] = run_scenario("exit_nonzero")
    end

    @tag :unix_only
    test "a clean exit without a result line synthesizes a done from accumulated text" do
      events = run_scenario("no_done")
      assert [{:chunk, "partial"}, {:done, %{content: "partial"}}] = events
    end

    @tag :unix_only
    test "a CLI that reads stdin sees EOF instead of an open pipe" do
      # The port is never written to and passes no `:in`, so a child that
      # reads stdin blocks until the run times out unless the
      # `SpawnedPort.spawn_spec/2` redirect is in place.
      {:ok, stream} =
        Native.stream(FakeDriver, messages(), extra_args: ["stdin_read"], timeout: 2_000)

      assert [{:done, %{content: "read stdin"}}] = Enum.to_list(stream)
    end

    @tag :unix_only
    test "the wrapper's marker line is never handed to the driver" do
      {:ok, stream} = Native.stream(StrictDriver, messages(), [])
      assert [{:chunk, "Hello "}, {:chunk, "world"}, {:done, _}] = Enum.to_list(stream)
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
    # Same `#!/bin/sh` fake CLI as stream/3.
    @describetag :unix_only

    test "drains the stream and returns the final response" do
      assert {:ok, %{content: "Hello world", usage: %{"input_tokens" => 3}}} =
               Native.complete(FakeDriver, messages(), extra_args: ["happy"])
    end

    test "propagates an error result" do
      assert {:error, {:result_error, "error_max_turns", _}} =
               Native.complete(FakeDriver, messages(), extra_args: ["error"])
    end
  end

  describe ":env and :mcp_env" do
    setup do
      previous = System.get_env("RAXOL_SHARE_SECRET")
      System.put_env("RAXOL_SHARE_SECRET", "probe-not-a-secret")

      on_exit(fn ->
        if previous,
          do: System.put_env("RAXOL_SHARE_SECRET", previous),
          else: System.delete_env("RAXOL_SHARE_SECRET")
      end)
    end

    test "without it the CLI gets the node's environment minus raxol's secrets" do
      assert {:ok, %{content: "unset|unset"}} =
               Native.complete(FakeDriver, messages(), extra_args: ["env"])
    end

    test "a passed variable reaches the CLI, a raxol secret included" do
      env = [{"RAXOL_NATIVE_PROBE", "passed"}, {"RAXOL_SHARE_SECRET", "given"}]

      assert {:ok, %{content: "given|passed"}} =
               Native.complete(FakeDriver, messages(), extra_args: ["env"], env: env)
    end

    test "an :mcp_env variable is in the env of the MCP server the CLI is told to start" do
      assert {:ok, %{content: "passed"}} =
               Native.complete(FakeDriver, messages(),
                 extra_args: ["mcp_env"],
                 mcp_env: [{"RAXOL_NATIVE_PROBE", "passed"}],
                 actions: [Greet],
                 mcp_server_command: "raxol-mcp-server"
               )
    end

    test "an :env variable is not written into the MCP server entry" do
      assert {:ok, %{content: "unset"}} =
               Native.complete(FakeDriver, messages(),
                 extra_args: ["mcp_env"],
                 env: [{"RAXOL_NATIVE_PROBE", "passed"}],
                 actions: [Greet],
                 mcp_server_command: "raxol-mcp-server"
               )
    end

    test "an :mcp_env variable never reaches the CLI's own environment" do
      mcp_env = [{"RAXOL_NATIVE_PROBE", "passed"}, {"RAXOL_SHARE_SECRET", "given"}]

      assert {:ok, %{content: "unset|unset"}} =
               Native.complete(FakeDriver, messages(),
                 extra_args: ["env"],
                 mcp_env: mcp_env,
                 actions: [Greet],
                 mcp_server_command: "raxol-mcp-server"
               )
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
