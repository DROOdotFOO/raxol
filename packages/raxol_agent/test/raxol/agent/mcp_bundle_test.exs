defmodule Raxol.Agent.McpBundleTest.FakeServer do
  @moduledoc """
  A real GenServer standing in for an external MCP stdio server at the process
  boundary: it answers the exact `GenServer.call`s `Raxol.MCP.Client` makes
  (`:list_tools`, `{:call_tool, name, args}`), so the bundle -> Dynamic ->
  ToolConverter chain is exercised for real without spawning npx/uvx.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         tools: Keyword.get(opts, :tools, []),
         test_pid: Keyword.get(opts, :test_pid)
       }}

  @impl true
  def handle_call(:list_tools, _from, state),
    do: {:reply, {:ok, state.tools}, state}

  def handle_call({:call_tool, name, args}, _from, state) do
    if state.test_pid, do: send(state.test_pid, {:fake_called, name, args})

    {:reply,
     {:ok, %{"content" => [%{"type" => "text", "text" => "ok:#{name}"}]}},
     state}
  end
end

defmodule Raxol.Agent.McpBundleTest.SlowServer do
  @moduledoc """
  A server that reports `{:not_ready, :initializing}` for its first `:not_ready`
  `:list_tools` calls, then answers with its tools -- standing in for an MCP
  client whose initialize handshake has not yet round-tripped.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         tools: Keyword.get(opts, :tools, []),
         not_ready: Keyword.get(opts, :not_ready, 0)
       }}

  @impl true
  def handle_call(:list_tools, _from, %{not_ready: n} = state) when n > 0,
    do:
      {:reply, {:error, {:not_ready, :initializing}},
       %{state | not_ready: n - 1}}

  def handle_call(:list_tools, _from, state),
    do: {:reply, {:ok, state.tools}, state}
end

defmodule Raxol.Agent.McpBundleTest.ClosedServer do
  @moduledoc "A server whose port has already exited: `:list_tools` is terminal."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:list_tools, _from, state),
    do: {:reply, {:error, {:not_ready, :closed}}, state}
end

defmodule Raxol.Agent.McpBundleTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.McpBundleTest.{ClosedServer, SlowServer}

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.McpBundle
  alias Raxol.Agent.McpBundleTest.FakeServer

  # A start fn that maps a spec name to a fake server with canned tools, and
  # fails the `:bad` server so the fail-open path is exercised.
  defp start_fn(test_pid) do
    tools = %{
      git: [
        %{
          "name" => "status",
          "description" => "git status",
          "inputSchema" => %{"type" => "object"}
        }
      ],
      fetch: [
        %{
          "name" => "fetch",
          "description" => "fetch url",
          "inputSchema" => %{"type" => "object"}
        }
      ]
    }

    fn opts ->
      case Keyword.fetch!(opts, :name) do
        :bad ->
          {:error, :enoent}

        name ->
          FakeServer.start_link(
            tools: Map.fetch!(tools, name),
            test_pid: test_pid
          )
      end
    end
  end

  describe "default_servers/1" do
    test "returns the catalog with the workspace scoping the filesystem server" do
      servers = McpBundle.default_servers(workspace: "/w")
      names = Enum.map(servers, & &1.name)

      assert :filesystem in names
      assert :fetch in names
      assert :git in names

      fs = Enum.find(servers, &(&1.name == :filesystem))
      assert "/w" in fs.args
    end
  end

  describe "load/2" do
    test "aggregates tools across servers, namespaced per server; fails open on a bad server" do
      specs = [
        %{name: :git, command: "x"},
        %{name: :bad, command: "x"},
        %{name: :fetch, command: "x"}
      ]

      loaded = McpBundle.load(specs, start: start_fn(self()))

      names = Enum.map(loaded.tools, & &1.name)
      assert "mcp__git__status" in names
      assert "mcp__fetch__fetch" in names
      assert length(loaded.tools) == 2

      assert Enum.map(loaded.servers, &elem(&1, 0)) == [:git, :fetch]
      assert loaded.failed == [{:bad, :enoent}]
    end

    test "loaded tools dispatch through ToolConverter to the server (un-namespaced at the boundary)" do
      loaded =
        McpBundle.load([%{name: :git, command: "x"}], start: start_fn(self()))

      tool_call = %{
        "name" => "mcp__git__status",
        "arguments" => %{"path" => "."},
        "id" => "c1"
      }

      assert {:ok, %{"content" => _}} =
               ToolConverter.dispatch_tool_call(tool_call, loaded.tools, %{})

      # The server receives the ORIGINAL tool name, not the namespaced one, with
      # string-keyed args.
      assert_receive {:fake_called, "status", %{"path" => "."}}
    end

    test "an empty spec list loads nothing" do
      assert %{tools: [], servers: [], failed: []} = McpBundle.load([])
    end

    test "waits for an initializing server to become ready before listing its tools" do
      tools = [
        %{
          "name" => "read",
          "description" => "read",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      start = fn opts ->
        assert Keyword.fetch!(opts, :name) == :filesystem
        SlowServer.start_link(tools: tools, not_ready: 2)
      end

      loaded =
        McpBundle.load([%{name: :filesystem, command: "x"}],
          start: start,
          ready_interval: 1
        )

      assert Enum.map(loaded.tools, & &1.name) == ["mcp__filesystem__read"]
      assert loaded.failed == []
    end

    test "fails open on a server that never finishes initializing" do
      start = fn _opts ->
        SlowServer.start_link(tools: [], not_ready: 1_000_000)
      end

      loaded =
        McpBundle.load([%{name: :slow, command: "x"}],
          start: start,
          ready_timeout: 5,
          ready_interval: 1
        )

      assert loaded.tools == []
      assert [{:slow, {:not_ready, :initializing}}] = loaded.failed
    end

    test "fails open at once on an already-closed server without polling to timeout" do
      start = fn _opts -> ClosedServer.start_link([]) end

      # A large timeout must NOT block: `:closed` is terminal, so no retry. If it
      # were retried, this test would hang until the ExUnit timeout.
      loaded =
        McpBundle.load([%{name: :dead, command: "x"}],
          start: start,
          ready_timeout: 60_000,
          ready_interval: 50
        )

      assert loaded.tools == []
      assert [{:dead, {:not_ready, :closed}}] = loaded.failed
    end
  end
end
