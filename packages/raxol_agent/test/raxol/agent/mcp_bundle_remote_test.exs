defmodule Raxol.Agent.McpBundleRemoteTest.RemoteServer do
  @moduledoc "Stands in for a started remote MCP client at the process boundary."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools = [%{"name" => "lookup", "description" => "d", "inputSchema" => %{"type" => "object"}}]
    {:reply, {:ok, tools}, state}
  end
end

defmodule Raxol.Agent.McpBundleRemoteTest do
  # PATH, the allowlist path and the referenced env var are process-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.McpBundle
  alias Raxol.Agent.McpBundleRemoteTest.RemoteServer
  alias Raxol.Agent.McpSpendHook
  alias Raxol.Agent.ToolPolicy
  alias Raxol.MCP.Client.ReferenceServer

  @url "https://mcp.example.com/v1"
  @env_secret "env-resolved-s3cr3t"
  @op_secret "op-resolved-s3cr3t"
  @literal "Bearer sk-live-DEADBEEF"

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # A real `op` on PATH whose every invocation leaves a file behind, so "no
    # op process was spawned" is a filesystem fact rather than a flag this
    # test sets. The user-level test below asserts the same file DOES appear,
    # which is what keeps the negative assertion from being vacuous.
    log = Path.join(dir, "op.log")
    op = Path.join(dir, "op")
    File.write!(op, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{log}\"\nprintf '#{@op_secret}\\n'\n")
    File.chmod!(op, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (previous_path || ""))

    allowlist = Path.join(dir, "mcp_headers.json")
    previous_allowlist = System.get_env("RAXOL_MCP_HEADER_ALLOWLIST")
    System.put_env("RAXOL_MCP_HEADER_ALLOWLIST", allowlist)
    System.put_env("INTEL_TOKEN", @env_secret)

    on_exit(fn ->
      restore("PATH", previous_path)
      restore("RAXOL_MCP_HEADER_ALLOWLIST", previous_allowlist)
      System.delete_env("INTEL_TOKEN")
      File.rm_rf!(dir)
    end)

    %{op_log: log, allowlist: allowlist}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp start_fn do
    parent = self()

    fn opts ->
      send(parent, {:started, opts})
      RemoteServer.start_link(opts)
    end
  end

  defp spec(overrides) do
    Map.merge(%{name: :intel, url: @url, headers: [], source: :workspace}, Map.new(overrides))
  end

  # Load one spec, returning `{loaded, log}`. The literal-header warning is
  # expected noise in most of these, and the log is itself under test.
  defp load(specs) do
    parent = self()
    log = capture_log(fn -> send(parent, {:loaded, McpBundle.load(specs, start: start_fn())}) end)

    receive do
      {:loaded, loaded} -> {loaded, log}
    after
      0 -> flunk("McpBundle.load/2 did not return")
    end
  end

  test "a remote spec starts a client with its url and lists the server's tools" do
    {loaded, _log} =
      load([
        spec(
          headers: [{"Authorization", @literal}],
          concurrency: :serialized,
          metered: true,
          prices: %{"lookup" => 150}
        )
      ])

    assert loaded.failed == []
    assert [{:intel, _pid}] = loaded.servers
    assert Enum.map(loaded.tools, & &1.name) == ["mcp__intel__lookup"]

    assert_receive {:started, opts}
    assert Keyword.fetch!(opts, :url) == @url
    assert Keyword.fetch!(opts, :headers) == [{"Authorization", @literal}]
    assert Keyword.fetch!(opts, :concurrency) == :serialized
    refute Keyword.has_key?(opts, :command)

    # The transport enforces the reservation the hook makes, so it has to learn
    # the prices too; without these it cannot refuse an unmetered call on the
    # path that bypasses the hook chain.
    assert Keyword.fetch!(opts, :metered) == true
    assert Keyword.fetch!(opts, :prices) == %{"lookup" => 150}
  end

  test "an absent concurrency policy is not passed as nil" do
    {_loaded, _log} = load([spec([])])

    assert_receive {:started, opts}
    refute Keyword.has_key?(opts, :concurrency)
  end

  describe "a workspace spec whose header is a reference" do
    test "is refused by name, starts no server, and spawns no op", %{op_log: op_log} do
      for value <- ["${env:INTEL_TOKEN}", "op://Employee/Intel/token"] do
        {loaded, _log} = load([spec(headers: [{"Authorization", value}])])

        assert loaded.servers == []
        assert loaded.tools == []
        assert loaded.failed == [{:intel, {:workspace_header_reference, "Authorization"}}]

        refute_received {:started, _opts}
        refute File.exists?(op_log)
      end
    end

    test "leaks no value into the refusal reason or the log line" do
      {loaded, log} = load([spec(headers: [{"Authorization", "${env:INTEL_TOKEN}"}])])

      assert [{:intel, reason}] = loaded.failed
      refute inspect(reason) =~ @env_secret
      refute log =~ @env_secret
    end
  end

  test "a user-level spec resolves the same reference and hands over the resolved value", %{
    op_log: op_log
  } do
    {loaded, _log} =
      load([
        spec(
          source: :user,
          headers: [
            {"Authorization", "op://Employee/Intel/token"},
            {"X-Key", "${env:INTEL_TOKEN}"}
          ]
        )
      ])

    assert loaded.failed == []
    assert_receive {:started, opts}

    assert Keyword.fetch!(opts, :headers) == [
             {"Authorization", @op_secret},
             {"X-Key", @env_secret}
           ]

    # Calibration for the negative assertion above: the shim is reachable.
    assert File.read!(op_log) =~ "read op://Employee/Intel/token"
  end

  # ADR-0037 validation item 1, joined to the real transport: the spec is
  # parsed and resolved here, and the client, the era probe, the era headers
  # and the SSE parser are the real ones. `:start` (the documented injection
  # point) adds the two seams that belong to the transport's own tests: the
  # reference server in `lib/` standing in for the socket, and a resolver, so
  # the address vet runs without DNS. Everything between the spec and the tool
  # list is production code.
  test "a remote spec reaches a real client and lists the server's tools", %{op_log: op_log} do
    # The HTTP transport, its exchange and the shared bounded read all sit
    # behind a compile-time `Code.ensure_loaded?(Mint.HTTP)` in raxol_mcp, and
    # a half-compiled `_build` answers `{:error, :no_http_client}` instead. Say
    # so here rather than letting it read as an empty tool list.
    assert Enum.all?(
             [
               Raxol.MCP.Client.Transport.Http,
               Raxol.MCP.Client.Transport.Http.Exchange,
               Raxol.MCP.BoundedExchange
             ],
             &Code.ensure_loaded?/1
           ),
           "the raxol_mcp HTTP transport is not compiled in this build shape"

    parent = self()

    state =
      ReferenceServer.state(:modern,
        observer: parent,
        tools: [%{"name" => "echo", "description" => "echo", "inputSchema" => %{}}]
      )

    start = fn opts ->
      opts
      |> Keyword.merge(
        exchange: ReferenceServer.seam(ReferenceServer.Modern, state),
        resolver: fn
          _host, :inet -> {:ok, [{93, 184, 216, 34}]}
          _host, :inet6 -> {:error, :nxdomain}
        end
      )
      |> Raxol.MCP.Client.start_link()
    end

    spec =
      spec(source: :user, headers: [{"Authorization", "Bearer ${op://Employee/Intel/token}"}])

    capture_log(fn -> send(parent, {:loaded, McpBundle.load([spec], start: start)}) end)

    assert_received {:loaded, %{failed: [], tools: tools}}
    assert Enum.map(tools, & &1.name) == ["mcp__intel__echo"]

    # The header the server saw is the resolved literal, so resolution happened
    # here and the client was handed no reference to resolve.
    assert_received {:reference_server, %{headers: headers}}
    assert {"authorization", "Bearer " <> @op_secret} in headers
    assert File.read!(op_log) =~ "read op://Employee/Intel/token"
  end

  # ADR-0037 validation item 9 across the seam between the two halves: the hook
  # mints the handle, the transport enforces it. Both directions matter, and the
  # refusal is the native-harness shape, where no hook runs at all.
  test "a priced remote tool is reserved by the hook and accepted by the transport" do
    parent = self()
    state = ReferenceServer.state(:modern, observer: parent)

    start = fn opts ->
      opts
      |> Keyword.merge(
        exchange: ReferenceServer.seam(ReferenceServer.Modern, state),
        resolver: fn
          _host, :inet -> {:ok, [{93, 184, 216, 34}]}
          _host, :inet6 -> {:error, :nxdomain}
        end
      )
      |> Raxol.MCP.Client.start_link()
    end

    spec = spec(source: :user, metered: true, prices: %{"echo" => 150})

    capture_log(fn -> send(parent, {:loaded, McpBundle.load([spec], start: start)}) end)
    assert_received {:loaded, %{failed: [], tools: tools}}

    gate = %{
      budget_id: {:test, parent},
      emit: fn record -> send(parent, {:cost, record.kind}) end,
      try_reserve: fn 150 -> {:ok, 850} end
    }

    call = %{"name" => "mcp__intel__echo", "arguments" => %{"text" => "hi"}}
    authorizer = ToolPolicy.allow_all()

    assert {:ok, _output} =
             ToolConverter.dispatch_tool_call(call, tools, %{
               tool_authorizer: authorizer,
               tool_call_hooks: [McpSpendHook],
               spend_gate: gate
             })

    assert_received {:cost, :reserve}

    # Same tool, same transport, no hook in the pipeline: the request is never
    # issued, which is the enforcement site the hook cannot cover.
    assert {:error, :unmetered_call} =
             ToolConverter.dispatch_tool_call(call, tools, %{tool_authorizer: authorizer})
  end

  test "a client that raises with its opts in the message leaks nothing" do
    parent = self()

    start = fn opts ->
      send(parent, {:started, opts})
      raise ArgumentError, "cannot start with #{inspect(opts)}"
    end

    log =
      capture_log(fn ->
        loaded =
          McpBundle.load([spec(source: :user, headers: [{"Authorization", @literal}])],
            start: start
          )

        send(parent, {:loaded, loaded})
      end)

    assert_received {:started, _opts}
    assert_received {:loaded, %{failed: [{:intel, reason}]}}
    assert reason == {:start_raised, ArgumentError}
    refute inspect(reason) =~ "sk-live-DEADBEEF"
    refute log =~ "sk-live-DEADBEEF"
  end

  test "an operator allowlist lets one named workspace reference through", %{
    allowlist: allowlist
  } do
    File.write!(allowlist, Jason.encode!(%{"Authorization" => ["${env:INTEL_TOKEN}"]}))

    {loaded, _log} = load([spec(headers: [{"Authorization", "${env:INTEL_TOKEN}"}])])

    assert loaded.failed == []
    assert_receive {:started, opts}
    assert Keyword.fetch!(opts, :headers) == [{"Authorization", @env_secret}]
  end

  describe "a spec that is neither one transport nor the other" do
    test "carrying both a command and a url is refused, and starts nothing" do
      {loaded, _log} = load([spec(command: "npx", headers: [{"Authorization", @literal}])])

      assert [{:intel, {:invalid_spec, detail}}] = loaded.failed
      assert detail == %{name: :intel, reason: :command_and_url}
      refute_received {:started, _opts}
    end

    test "carrying neither is refused by name rather than dropped" do
      {loaded, _log} = load([%{name: :broken}])

      assert [{:broken, {:invalid_spec, %{reason: :no_command_or_url}}}] = loaded.failed
      refute_received {:started, _opts}
    end

    test "the refusal carries no header or env value, in the term or the log" do
      {loaded, log} =
        load([
          spec(
            command: "npx",
            env: [{"GITHUB_TOKEN", "env-secret-DEADBEEF"}],
            headers: [{"Authorization", @literal}]
          )
        ])

      assert [{:intel, reason}] = loaded.failed
      refute inspect(reason) =~ "sk-live-DEADBEEF"
      refute inspect(reason) =~ "env-secret-DEADBEEF"
      refute log =~ "sk-live-DEADBEEF"
      refute log =~ "env-secret-DEADBEEF"
    end
  end
end
