# Red-first regression for drew-preview disposition N2 (New Hire, HIGH):
# `Client.start_link/2` / `Client.child_spec/1` (and their `Agent` mirrors)
# return/register the `ConnectionSupervisor`, not the `Connection` pid --
# but every request-driving function (`Connection.request/4`,
# `Client.prompt/3`, `subscribe/3`, ...) needs the `Connection` pid. Before
# this fix, the ONLY place that pid could be resolved from was a PRIVATE
# `connection_of/1` helper hand-rolled inside
# `test/integration/end_to_end_test.exs` -- the README's own documented
# quickstart could not actually drive a turn using only its own public API.
#
# This test proves the fix by driving one full `initialize` -> `session/new`
# -> `session/prompt` turn using ONLY public API: `Agent.connection/1`,
# `Client.connection/1`, `Connection.request/4`, `Client.prompt/3` -- the
# exact shape the rewritten README quickstart now uses. No private helper is
# reimplemented or imported anywhere in this file.
defmodule Raxol.AgentClientProtocol.Client.ConnectionAccessorTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.ContentChunk
  alias Raxol.AgentClientProtocol.Schema.TextContent

  # Exactly the README quickstart's "MyAgent" shape: no Session process, no
  # journal -- the simplest agent that answers a turn synchronously.
  defmodule QuickstartAgent do
    @moduledoc false
    use Raxol.AgentClientProtocol.Agent

    alias Raxol.AgentClientProtocol.Connection
    alias Raxol.AgentClientProtocol.Schema.ContentChunk
    alias Raxol.AgentClientProtocol.Schema.TextContent
    alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

    alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
      InitializeResponse,
      NewSessionResponse,
      PromptResponse
    }

    @impl true
    def initialize(req, _ctx), do: {:ok, InitializeResponse.new(req.protocol_version)}

    @impl true
    def new_session(_params, _ctx), do: {:ok, NewSessionResponse.new("sess-1")}

    @impl true
    def prompt(%{session_id: session_id, prompt: blocks}, ctx) do
      text =
        Enum.map_join(blocks, "", fn
          {:text, tc} -> tc.text
          _ -> ""
        end)

      chunk = ContentChunk.new({:text, TextContent.new("echo: #{text}")})
      notification = SessionNotification.new(session_id, {:agent_message_chunk, chunk})
      Connection.notify(ctx.conn, "session/update", notification)

      {:ok, PromptResponse.new(:end_turn)}
    end
  end

  defmodule QuickstartClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client
  end

  test "Agent.connection/1 and Client.connection/1 drive one full turn via public API only" do
    {left, right} = Paired.create_pair()

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:agent, make_ref()},
            handler: QuickstartAgent,
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
            id: {:client, make_ref()},
            handler: QuickstartClient,
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        )
      )

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right], is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    # The point of the fix: reach the Connection pid through PUBLIC API only.
    assert {:ok, agent_conn} = AcpAgent.connection(agent_sup)
    assert {:ok, client_conn} = AcpClient.connection(client_sup)
    assert is_pid(agent_conn)
    assert is_pid(client_conn)

    wait_until_adopted(agent_conn)
    wait_until_adopted(client_conn)

    assert {:ok, %InitializeResponse{}} =
             Connection.request(client_conn, "initialize", InitializeRequest.new(1), 2_000)

    assert {:ok, %NewSessionResponse{session_id: session_id}} =
             Connection.request(client_conn, "session/new", NewSessionRequest.new("/tmp"), 2_000)

    prompt = PromptRequest.new(session_id, [ContentBlock.from_string("hello, agent")])

    assert {:ok, {updates, %PromptResponse{stop_reason: :end_turn}}} =
             AcpClient.prompt(client_conn, prompt)

    assert [{:agent_message_chunk, %ContentChunk{content: content}}] = updates
    assert content == {:text, %TextContent{text: "echo: hello, agent"}}
  end

  test "connection/1 reports :not_found for a supervisor pid with no Connection child" do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

    assert AcpClient.connection(sup) == {:error, :not_found}
    assert AcpAgent.connection(sup) == {:error, :not_found}

    Supervisor.stop(sup)
  end

  defp wait_until_adopted(conn), do: wait_until(fn -> :sys.get_state(conn).phase != :booting end)

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("connection never adopted its transport")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end
end
