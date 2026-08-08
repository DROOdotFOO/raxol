defmodule Raxol.Agent.ClientProtocol.StdioAgentTest do
  # async: false — uses the ACP package's named shared tree (SessionRegistry,
  # journal registries, AttachPolicy task supervisor).
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  defmodule MiniClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def session_update(_notification, _ctx), do: :ok
  end

  # Reports the working directory the fs tool context resolves to, and sends it
  # to the test process threaded through the SAME tool context. Proves the
  # session/new cwd reaches a real tool's context via Fs.working_dir/1.
  defmodule ReportCwd do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "report_cwd",
      description: "Report the fs working directory",
      schema: [input: []]

    @impl true
    def run(_params, context) do
      dir = Raxol.Agent.Actions.Fs.working_dir(context)

      if pid = is_map(context) && Map.get(context, :test_pid) do
        send(pid, {:probed_cwd, dir})
      end

      {:ok, %{cwd: dir}}
    end
  end

  setup do
    # The package Application auto-starts its shared tree when the dep app
    # boots; inject it only when absent so this test never double-starts
    # named processes.
    if Process.whereis(Session.registry()) == nil do
      RaxolAgentClientProtocol.Application.children()
      |> Enum.with_index()
      |> Enum.each(fn {spec, i} ->
        start_supervised!(Supervisor.child_spec(spec, id: {:acp_tree, i}))
      end)
    end

    :ok
  end

  test "an editor can initialize, open a session, and run a prompt turn" do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right],
          is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    turn_opts = [
      executor: Raxol.Agent.ExecutorConfig.new(backend: :mock),
      actions: []
    ]

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:stdio_agent, make_ref()},
            handler: Raxol.Agent.ClientProtocol.StdioAgent,
            handler_arg: %{turn_opts: turn_opts},
            transport: {Paired, left}
          ),
          :restart,
          :temporary
        )
      )

    client_sup =
      start_supervised!(
        Map.put(
          AcpClient.child_spec(
            id: {:stdio_client, make_ref()},
            handler: MiniClient,
            handler_arg: %{},
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        )
      )

    agent_conn = connection_of(agent_sup)
    client_conn = connection_of(client_sup)
    assert_adopted(agent_conn)
    assert_adopted(client_conn)

    assert {:ok, init} =
             Connection.request(
               client_conn,
               "initialize",
               InitializeRequest.new(1),
               2_000
             )

    # Clients and benchmark harnesses record `agentInfo` as the agent under
    # test; without it the run is attributed to an unnamed agent.
    assert %{agent_info: %{name: "raxol", version: version}} = init
    assert is_binary(version) and version != ""

    assert {:ok, %{session_id: sid}} =
             Connection.request(
               client_conn,
               "session/new",
               NewSessionRequest.new("/"),
               2_000
             )

    assert is_binary(sid) and sid =~ "acp-"

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("hello")])

    assert {:ok, response} =
             Connection.request(client_conn, "session/prompt", prompt, 5_000)

    assert %{stop_reason: _reason} = response
  end

  test "session/new cwd scopes the session's fs tool context" do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right],
          is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    session_cwd =
      Path.join(
        System.tmp_dir!(),
        "acp_cwd_#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(session_cwd)
    on_exit(fn -> File.rm_rf(session_cwd) end)

    # One-shot: emit the tool call on the first turn, nothing after, so react
    # executes the tool then completes on the plain second response.
    fired = :counters.new(1, [])

    tool_calls_fn = fn ->
      if :counters.get(fired, 1) == 0 do
        :counters.add(fired, 1, 1)
        [%{"id" => "c1", "name" => "report_cwd", "arguments" => %{}}]
      else
        nil
      end
    end

    turn_opts = [
      executor: Raxol.Agent.ExecutorConfig.new(backend: :mock),
      backend_opts: [tool_calls_fn: tool_calls_fn],
      actions: [ReportCwd],
      context: %{test_pid: self()}
    ]

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:stdio_agent_cwd, make_ref()},
            handler: Raxol.Agent.ClientProtocol.StdioAgent,
            handler_arg: %{turn_opts: turn_opts},
            transport: {Paired, left}
          ),
          :restart,
          :temporary
        )
      )

    client_sup =
      start_supervised!(
        Map.put(
          AcpClient.child_spec(
            id: {:stdio_client_cwd, make_ref()},
            handler: MiniClient,
            handler_arg: %{},
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        )
      )

    agent_conn = connection_of(agent_sup)
    client_conn = connection_of(client_sup)
    assert_adopted(agent_conn)
    assert_adopted(client_conn)

    {:ok, _} =
      Connection.request(client_conn, "initialize", InitializeRequest.new(1), 2_000)

    {:ok, %{session_id: sid}} =
      Connection.request(
        client_conn,
        "session/new",
        NewSessionRequest.new(session_cwd),
        2_000
      )

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("where are you")])
    {:ok, _response} = Connection.request(client_conn, "session/prompt", prompt, 5_000)

    assert_receive {:probed_cwd, probed}, 2_000
    assert probed == Path.expand(session_cwd)
  end

  test "a prompt against an unknown session is a clean protocol error" do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right],
          is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:stdio_agent2, make_ref()},
            handler: Raxol.Agent.ClientProtocol.StdioAgent,
            handler_arg: %{turn_opts: [executor: Raxol.Agent.ExecutorConfig.new(backend: :mock)]},
            transport: {Paired, left}
          ),
          :restart,
          :temporary
        )
      )

    client_sup =
      start_supervised!(
        Map.put(
          AcpClient.child_spec(
            id: {:stdio_client2, make_ref()},
            handler: MiniClient,
            handler_arg: %{},
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        )
      )

    agent_conn = connection_of(agent_sup)
    client_conn = connection_of(client_sup)
    assert_adopted(agent_conn)
    assert_adopted(client_conn)

    {:ok, _} =
      Connection.request(client_conn, "initialize", InitializeRequest.new(1), 2_000)

    prompt = PromptRequest.new("no-such-session", [ContentBlock.from_string("hi")])

    assert {:error, error} =
             Connection.request(client_conn, "session/prompt", prompt, 2_000)

    assert error.message =~ "unknown session"
  end

  defp connection_of(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn {_id, pid, _type, mods} ->
      if is_pid(pid) and Connection in mods, do: pid
    end)
  end

  defp assert_adopted(conn) do
    wait_until(fn -> :sys.get_state(conn).phase != :booting end)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end
end
