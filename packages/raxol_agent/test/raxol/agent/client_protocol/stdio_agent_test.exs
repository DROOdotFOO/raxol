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

    assert {:ok, _init} =
             Connection.request(
               client_conn,
               "initialize",
               InitializeRequest.new(1),
               2_000
             )

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
