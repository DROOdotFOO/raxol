defmodule Raxol.Agent.ClientProtocol.StdioAgentLoadTest do
  @moduledoc """
  `session/load`: a session recorded by one connection, replayed to another.

  The claim worth having is END TO END across connections. A test that loads a
  session on the connection that created it proves almost nothing -- the
  Session is still alive and the journal need never be read. Each test here
  tears the first connection down and brings a second one up, which is the
  shape a client actually meets: an editor reopened, an agent process restarted.

  Also pinned: the capability, because the handler is unreachable without it
  (`Capabilities.negotiated?/2` resolves `session/load` against the agent's own
  advertised `AgentCapabilities`, and a non-negotiated method is refused with
  -32601 before it is decoded); and the two refusals that must not be an empty
  replay -- an id that cannot be a path, and an id with no journal.
  """

  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Transport.Paired

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  defmodule RecordingClient do
    @moduledoc "Forwards every session/update to the test process."
    use Raxol.AgentClientProtocol.Client

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def session_update(notification, ctx) do
      send(ctx.handler_state.owner, {:client_update, notification})
      :ok
    end
  end

  defmodule HistoryBackend do
    @moduledoc "Reports the messages it was handed, then replies `ok`."
    def stream(messages, opts) do
      send(Keyword.fetch!(opts, :owner), {:backend_saw, messages})
      {:ok, [{:chunk, "ok"}, {:done, %{content: "ok", usage: %{}}}]}
    end

    def complete(_messages, _opts), do: {:error, :stream_only}
  end

  defmodule EchoAction do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "echo",
      description: "echoes v",
      schema: [input: [v: [type: :integer, required: true]]]

    @impl true
    def run(%{v: v}, _context), do: {:ok, %{v: v}}
  end

  defmodule ToolBackend do
    @moduledoc """
    Drives one tool round trip, then answers. Reports every message list it is
    handed so a test can see what the resumed turn knew.
    """
    def complete(messages, opts) do
      send(Keyword.fetch!(opts, :owner), {:backend_saw, messages})

      if called_a_tool?(messages) do
        {:ok, %{content: "done", usage: %{}}}
      else
        {:ok,
         %{
           content: "",
           usage: %{},
           tool_calls: [%{"name" => "echo", "arguments" => %{"v" => 7}, "id" => "t1"}]
         }}
      end
    end

    def stream(_messages, _opts), do: {:error, :complete_only}

    defp called_a_tool?(messages) do
      Enum.any?(messages, fn message ->
        content = Map.get(message, :content) || ""
        is_binary(content) and String.starts_with?(content, "[Tool result for ")
      end)
    end
  end

  setup do
    if Process.whereis(Session.registry()) == nil do
      RaxolAgentClientProtocol.Application.children()
      |> Enum.with_index()
      |> Enum.each(fn {spec, i} ->
        start_supervised!(Supervisor.child_spec(spec, id: {:acp_tree, i}))
      end)
    end

    :ok
  end

  # -- harness ------------------------------------------------------------------

  defp connect!(turn_opts) do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right], is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:load_agent, make_ref()},
            handler: Raxol.Agent.ClientProtocol.StdioAgent,
            handler_arg: %{turn_opts: turn_opts},
            transport: {Paired, left}
          ),
          :restart,
          :temporary
        ),
        id: {:load_agent_sup, make_ref()}
      )

    client_sup =
      start_supervised!(
        Map.put(
          AcpClient.child_spec(
            id: {:load_client, make_ref()},
            handler: RecordingClient,
            handler_arg: %{owner: self()},
            transport: {Paired, right}
          ),
          :restart,
          :temporary
        ),
        id: {:load_client_sup, make_ref()}
      )

    agent_conn = connection_of(agent_sup)
    client_conn = connection_of(client_sup)
    assert_adopted(agent_conn)
    assert_adopted(client_conn)

    %{client: client_conn, agent_sup: agent_sup, client_sup: client_sup}
  end

  defp initialize!(conn) do
    assert {:ok, init} =
             Connection.request(conn, "initialize", InitializeRequest.new(1), 2_000)

    init
  end

  defp drop!(%{agent_sup: agent_sup, client_sup: client_sup}) do
    for sup <- [agent_sup, client_sup], Process.alive?(sup) do
      Process.exit(sup, :kill)
    end

    :ok
  end

  defp turn_opts(dir) do
    [
      executor: Raxol.Agent.ExecutorConfig.new(backend: :mock),
      actions: [],
      journal_opts: [base_dir: dir]
    ]
  end

  defp drain_updates(acc \\ []) do
    receive do
      {:client_update, notification} -> drain_updates([notification | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # -- capability ---------------------------------------------------------------

  @tag :tmp_dir
  test "initialize advertises loadSession", %{tmp_dir: dir} do
    conn = connect!(turn_opts(dir))
    init = initialize!(conn.client)

    assert %{load_session: true} = init.agent_capabilities
  end

  # -- the round trip -----------------------------------------------------------

  @tag :tmp_dir
  test "a session recorded on one connection replays on the next", %{tmp_dir: dir} do
    first = connect!(turn_opts(dir))
    initialize!(first.client)

    assert {:ok, %{session_id: sid}} =
             Connection.request(
               first.client,
               "session/new",
               NewSessionRequest.new("/"),
               2_000
             )

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("hello")])
    assert {:ok, _resp} = Connection.request(first.client, "session/prompt", prompt, 5_000)

    live = drain_updates()
    assert live != [], "the turn produced no updates, so the replay claim is vacuous"

    # The connection that made the session is gone: no live Session, nothing
    # cached. Anything the next connection reports has come off disk.
    drop!(first)

    second = connect!(turn_opts(dir))
    initialize!(second.client)

    assert {:ok, _loaded} =
             Connection.request(
               second.client,
               "session/load",
               LoadSessionRequest.new(sid, "/"),
               5_000
             )

    replayed = drain_updates()

    assert Enum.map(replayed, & &1.session_id) == Enum.map(live, & &1.session_id)
    assert Enum.map(replayed, & &1.update) == Enum.map(live, & &1.update)
  end

  @tag :tmp_dir
  test "a loaded session accepts the next prompt", %{tmp_dir: dir} do
    first = connect!(turn_opts(dir))
    initialize!(first.client)

    assert {:ok, %{session_id: sid}} =
             Connection.request(
               first.client,
               "session/new",
               NewSessionRequest.new("/"),
               2_000
             )

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("hello")])
    assert {:ok, _resp} = Connection.request(first.client, "session/prompt", prompt, 5_000)
    drop!(first)

    second = connect!(turn_opts(dir))
    initialize!(second.client)

    assert {:ok, _loaded} =
             Connection.request(
               second.client,
               "session/load",
               LoadSessionRequest.new(sid, "/"),
               5_000
             )

    # The point of loading rather than replaying: the session is bound, so the
    # conversation continues instead of needing a new one.
    next = PromptRequest.new(sid, [ContentBlock.from_string("again")])

    assert {:ok, %{stop_reason: _}} =
             Connection.request(second.client, "session/prompt", next, 5_000)
  end

  # -- context across the reconnect ---------------------------------------------

  # The point of the whole feature. Replaying the transcript to the editor is
  # only half a resume: if the next turn reaches the model with an empty
  # history, the session looks continued and is not.
  @tag :tmp_dir
  test "a loaded session's next turn reaches the model with the prior exchange",
       %{tmp_dir: dir} do
    opts = [
      backend: HistoryBackend,
      backend_opts: [owner: self()],
      actions: [],
      journal_opts: [base_dir: dir]
    ]

    first = connect!(opts)
    initialize!(first.client)

    assert {:ok, %{session_id: sid}} =
             Connection.request(
               first.client,
               "session/new",
               NewSessionRequest.new("/"),
               2_000
             )

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("first")])
    assert {:ok, _resp} = Connection.request(first.client, "session/prompt", prompt, 5_000)
    assert_receive {:backend_saw, [%{role: :user, content: "first"}]}, 2_000

    drop!(first)

    second = connect!(opts)
    initialize!(second.client)

    assert {:ok, _loaded} =
             Connection.request(
               second.client,
               "session/load",
               LoadSessionRequest.new(sid, "/"),
               5_000
             )

    next = PromptRequest.new(sid, [ContentBlock.from_string("second")])
    assert {:ok, _resp} = Connection.request(second.client, "session/prompt", next, 5_000)

    assert_receive {:backend_saw, seen}, 2_000

    assert seen == [
             %{role: :user, content: "first"},
             %{role: :assistant, content: "ok"},
             %{role: :user, content: "second"}
           ]
  end

  # A resumed agent has to know what it READ, not only what it concluded. With
  # the reply alone as history, the tool call and its result vanish and the
  # next turn re-derives them -- re-running the work, or contradicting it.
  @tag :tmp_dir
  test "a resumed turn still carries the tool exchange", %{tmp_dir: dir} do
    opts = [
      backend: ToolBackend,
      backend_opts: [owner: self()],
      actions: [EchoAction],
      journal_opts: [base_dir: dir]
    ]

    first = connect!(opts)
    initialize!(first.client)

    assert {:ok, %{session_id: sid}} =
             Connection.request(
               first.client,
               "session/new",
               NewSessionRequest.new("/"),
               2_000
             )

    prompt = PromptRequest.new(sid, [ContentBlock.from_string("use the tool")])
    assert {:ok, _resp} = Connection.request(first.client, "session/prompt", prompt, 5_000)

    drop!(first)
    flush_backend_saw()

    second = connect!(opts)
    initialize!(second.client)

    assert {:ok, _loaded} =
             Connection.request(
               second.client,
               "session/load",
               LoadSessionRequest.new(sid, "/"),
               5_000
             )

    next = PromptRequest.new(sid, [ContentBlock.from_string("and again")])
    assert {:ok, _resp} = Connection.request(second.client, "session/prompt", next, 5_000)

    assert_receive {:backend_saw, seen}, 2_000
    contents = Enum.map(seen, &Map.get(&1, :content))

    assert "use the tool" in contents
    assert Enum.any?(contents, &String.starts_with?(&1, "[Calling tools: echo"))
    assert Enum.any?(contents, &String.starts_with?(&1, "[Tool result for echo]"))
    assert "and again" in contents
  end

  defp flush_backend_saw do
    receive do
      {:backend_saw, _} -> flush_backend_saw()
    after
      50 -> :ok
    end
  end

  # -- refusals -----------------------------------------------------------------

  @tag :tmp_dir
  test "an id that cannot be a path is refused, not read", %{tmp_dir: dir} do
    conn = connect!(turn_opts(dir))
    initialize!(conn.client)

    assert {:error, error} =
             Connection.request(
               conn.client,
               "session/load",
               LoadSessionRequest.new("../../etc", "/"),
               2_000
             )

    assert error.code == -32_602
  end

  @tag :tmp_dir
  test "an id with no journal is unknown, not an empty session", %{tmp_dir: dir} do
    conn = connect!(turn_opts(dir))
    initialize!(conn.client)

    assert {:error, error} =
             Connection.request(
               conn.client,
               "session/load",
               LoadSessionRequest.new("sess-does-not-exist", "/"),
               2_000
             )

    assert error.code == -32_602
    assert drain_updates() == []
  end

  # -- helpers ------------------------------------------------------------------

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
