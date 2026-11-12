defmodule Raxol.Agent.Test.AcpPipe do
  @moduledoc """
  The `raxol acp` server loop and an ACP client joined by a
  `Raxol.AgentClientProtocol.Transport.Paired`, for tests that drive the
  server the way an editor does.

  `connect/2` runs `Raxol.Agent.ClientProtocol.Serve.serve_connection/2` in a
  process of its own, which sends the test `{:acp_exit, pid, code}` when the
  loop returns. The client's prompts are sent with `prompt/3`, so the test
  process receives the turn's frames itself, in wire order:
  `{:acp_turn_update, tag, ordinal, notification}`, then
  `{:acp_result, tag, result}`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Raxol.Agent.ClientProtocol.Serve
  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Transport.Paired

  @request_ms 5_000

  defmodule Editor do
    @moduledoc """
    The client side. `handler_arg` is `%{test: pid, permission: option_id}`:
    every `session/request_permission` is reported to `test` and answered by
    selecting `option_id`.
    """
    use Raxol.AgentClientProtocol.Client

    alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse
    alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def request_permission(request, ctx) do
      %{test: test, permission: option_id} = ctx.handler_state
      send(test, {:permission_asked, request})
      {:ok, RequestPermissionResponse.new({:selected, SelectedPermissionOutcome.new(option_id)})}
    end
  end

  defmodule SilentEditor do
    @moduledoc "A client that does not implement `session/request_permission`."
    use Raxol.AgentClientProtocol.Client
  end

  @doc "A project root of the test's own, removed when it ends."
  @spec tmp_root(String.t()) :: Path.t()
  def tmp_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  @doc "The directory running agent `id`'s journal is kept under, as its session tree records it."
  @spec journal_base(String.t()) :: Path.t()
  def journal_base(id) do
    {:ok, {_owner, %{base_dir: base}}} = Raxol.Agent.Session.Supervisor.owner(id)
    base
  end

  @doc "Start what an agent session tree and an ACP connection need, if absent."
  @spec start_trees() :: :ok
  def start_trees do
    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
    start_supervised!(Raxol.Agent.SessionStreamer)

    if Process.whereis(Session.registry()) == nil do
      RaxolAgentClientProtocol.Application.children()
      |> Enum.with_index()
      |> Enum.each(fn {spec, index} ->
        start_supervised!(Supervisor.child_spec(spec, id: {:acp_tree, index}))
      end)
    end

    :ok
  end

  @doc """
  Serve `agent` (what `--agent` parsed to, or `nil`) and connect a client
  past `initialize`.

  Options: `:permission` (the option id the client selects; without it the
  client does not implement the method) and `:auth_opts`.
  """
  @spec connect(Serve.agent() | nil, keyword()) :: map()
  def connect(agent, opts \\ []) do
    {left, right} = Paired.create_pair()
    test = self()
    handler_arg = %{agent: agent, auth_opts: Keyword.get(opts, :auth_opts, [])}

    {serving, _ref} =
      spawn_monitor(fn ->
        send(test, {:acp_exit, self(), Serve.serve_connection({Paired, left}, handler_arg)})
      end)

    client = start_supervised!(client_spec(right, Keyword.get(opts, :permission)))
    {:ok, conn} = Client.connection(client)

    assert {:ok, init} =
             Connection.request(conn, "initialize", InitializeRequest.new(1), @request_ms)

    %{conn: conn, init: init, serving: serving, server: left, peer: right}
  end

  defp client_spec(transport, permission) do
    {handler, handler_arg} =
      if permission,
        do: {Editor, %{test: self(), permission: permission}},
        else: {SilentEditor, nil}

    Client.child_spec(
      id: {:acp_editor, make_ref()},
      handler: handler,
      handler_arg: handler_arg,
      transport: {Paired, transport}
    )
  end

  @doc "`session/new` for project root `root`."
  @spec new_session(map(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def new_session(%{conn: conn}, root) do
    case Connection.request(conn, "session/new", NewSessionRequest.new(root), @request_ms) do
      {:ok, %{session_id: session_id}} -> {:ok, session_id}
      {:error, _error} = refusal -> refusal
    end
  end

  @doc "Send `session/prompt` and return the tag its frames arrive under."
  @spec prompt(map(), String.t(), String.t()) :: reference()
  def prompt(%{conn: conn}, session_id, text) do
    tag = make_ref()
    request = PromptRequest.new(session_id, [ContentBlock.from_string(text)])
    :ok = Connection.async_request(conn, "session/prompt", request, self(), tag, 30_000)
    tag
  end

  @doc "Run one prompt to its end: `{updates, result}`, the updates oldest first."
  @spec turn(map(), String.t(), String.t()) :: {[term()], {:ok, struct()} | {:error, term()}}
  def turn(pipe, session_id, text), do: collect(prompt(pipe, session_id, text), [])

  @doc "Collect the rest of the turn sent under `tag`."
  @spec collect(reference(), [term()]) :: {[term()], {:ok, struct()} | {:error, term()}}
  def collect(tag, updates \\ []) do
    receive do
      {:acp_turn_update, ^tag, _ordinal, notification} ->
        collect(tag, [notification.update | updates])

      {:acp_result, ^tag, result} ->
        {Enum.reverse(updates), result}
    after
      @request_ms -> flunk("the turn did not end; updates so far: #{inspect(updates)}")
    end
  end

  @doc "Send `session/cancel`."
  @spec cancel(map(), String.t()) :: :ok
  def cancel(%{conn: conn}, session_id),
    do: Connection.notify(conn, "session/cancel", %CancelNotification{session_id: session_id})

  @doc "Close the client's end and return the server loop's exit code."
  @spec disconnect(map()) :: non_neg_integer()
  def disconnect(%{peer: peer, serving: serving}) do
    Paired.close(peer)
    assert_receive {:acp_exit, ^serving, code}, @request_ms
    code
  end

  @doc "The text of the `agent_message_chunk` updates in `updates`."
  @spec reply_text([term()]) :: String.t()
  def reply_text(updates) do
    for {:agent_message_chunk, %{content: {:text, %{text: text}}}} <- updates, into: "", do: text
  end

  @doc "`{title, status}` of each tool call announced or updated in `updates`."
  @spec tool_statuses([term()]) :: [{String.t() | nil, atom()}]
  def tool_statuses(updates) do
    Enum.flat_map(updates, fn
      {:tool_call, call} -> [{call.title, call.status}]
      {:tool_call_update, update} -> [{update.fields.title, update.fields.status}]
      _other -> []
    end)
  end
end
