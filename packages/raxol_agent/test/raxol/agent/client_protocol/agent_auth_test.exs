defmodule Raxol.Agent.ClientProtocol.AgentAuthTest do
  @moduledoc """
  Agent Auth on the ACP surface: what `initialize` advertises, and what
  `authenticate` actually does when a client picks it.

  The sign-in runs over a real connection with a real loopback socket; only
  the browser, the token exchange, and the credential store are injected, so
  nothing here opens a window, reaches the network, or touches 1Password.
  """
  # async: false — uses the ACP package's named shared tree.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Auth.Flow
  alias Raxol.Agent.ClientProtocol.StdioAgent
  alias Raxol.AgentClientProtocol.Agent, as: AcpAgent
  alias Raxol.AgentClientProtocol.Client, as: AcpClient
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Transport.Paired

  @key "sk-or-v1-minted"

  defmodule MiniClient do
    @moduledoc false
    use Raxol.AgentClientProtocol.Client

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def session_update(_notification, _ctx), do: :ok
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

  describe "what initialize advertises" do
    test "offers both of the registry's accepted methods, Agent Auth first" do
      assert [agent_method, terminal_method] = StdioAgent.auth_methods()

      assert %{"agent-auth" => _} = agent_method._meta
      assert %{"terminal-auth" => _} = terminal_method._meta
    end

    # The registry's parser reads the type off this key and defaults an
    # untyped method to `agent`. An untyped entry would silently claim a flow
    # we do not run.
    test "types every method explicitly, since untyped defaults to agent" do
      for method <- StdioAgent.auth_methods() do
        assert Map.has_key?(method._meta, "agent-auth") or
                 Map.has_key?(method._meta, "terminal-auth"),
               "auth method #{method.id} carries no type marker"
      end
    end

    # This is the honesty check: an advertised Agent Auth method whose provider
    # has no flow behind it is a sign-in that hangs.
    test "only claims Agent Auth for providers with a flow behind them" do
      for method <- StdioAgent.auth_methods(),
          Map.has_key?(method._meta, "agent-auth") do
        assert Enum.any?(Flow.providers(), &(to_string(&1) == method.id)),
               "advertised #{method.id} with no flow behind it"
      end
    end

    test "reaches the client on the wire, not just the struct" do
      {_client, init} = connect(auth_opts: [])

      ids = Enum.map(init.auth_methods, & &1.id)

      assert "openrouter" in ids
      assert "terminal" in ids
    end
  end

  describe "authenticate" do
    test "runs the browser flow and reports success once the key is stored" do
      caller = self()

      {client, _init} =
        connect(
          auth_opts: [
            browser_fn: browser(),
            http_fn: fn _url, _body, _opts -> {:ok, %{"key" => @key}} end,
            store_fn: fn provider, key ->
              send(caller, {:stored, provider, key})
              {:ok, provider, "op://Private/OpenRouter/api_key", :valid}
            end,
            timeout: 3_000
          ]
        )

      assert {:ok, _response} =
               Connection.request(
                 client,
                 "authenticate",
                 AuthenticateRequest.new("openrouter"),
                 8_000
               )

      assert_receive {:stored, :openrouter, @key}
    end

    # Fail-closed: a client must not come away thinking it can open a session.
    test "is an error when the sign-in does not complete" do
      {client, _init} =
        connect(
          auth_opts: [
            browser_fn: fn _url -> :ok end,
            store_fn: fn _provider, _key ->
              flunk("stored a key for an incomplete sign-in")
            end,
            timeout: 50
          ]
        )

      assert {:error, error} =
               Connection.request(
                 client,
                 "authenticate",
                 AuthenticateRequest.new("openrouter"),
                 8_000
               )

      assert error.message =~ "timed out"
    end

    # Terminal Auth happens by relaunching the binary, not over the wire; say
    # so instead of hanging or pretending it worked.
    test "refuses the terminal method and names the command instead" do
      {client, _init} = connect(auth_opts: [])

      assert {:error, error} =
               Connection.request(
                 client,
                 "authenticate",
                 AuthenticateRequest.new("terminal"),
                 2_000
               )

      assert error.message =~ "raxol login"
    end

    test "refuses a method id it never advertised" do
      {client, _init} = connect(auth_opts: [])

      assert {:error, error} =
               Connection.request(
                 client,
                 "authenticate",
                 AuthenticateRequest.new("anthropic"),
                 2_000
               )

      assert error.message =~ "unknown auth method"
    end
  end

  # -- scaffolding ------------------------------------------------------------

  # Stands in for the user approving in a browser: fetch the callback URL the
  # flow put in the authorization URL, with a code attached.
  defp browser do
    fn url ->
      callback =
        url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("callback_url")

      uri = URI.parse(callback <> "?code=the-code")

      spawn_link(fn ->
        {:ok, socket} =
          :gen_tcp.connect(
            ~c"127.0.0.1",
            uri.port,
            [:binary, active: false, packet: :raw],
            2_000
          )

        :gen_tcp.send(
          socket,
          "GET #{uri.path}?#{uri.query} HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )

        :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
      end)

      :ok
    end
  end

  # A live agent/client pair past the handshake: every other method is
  # `:not_initialized` until `initialize` lands, so no test can skip it.
  defp connect(handler_extra) do
    {left, right} = Paired.create_pair()

    on_exit(fn ->
      for %Paired{pid: p} <- [left, right], is_pid(p) and Process.alive?(p) do
        Process.exit(p, :kill)
      end
    end)

    handler_arg =
      Enum.into(handler_extra, %{
        turn_opts: [
          executor: Raxol.Agent.ExecutorConfig.new(backend: :mock),
          actions: []
        ]
      })

    agent_sup =
      start_supervised!(
        Map.put(
          AcpAgent.child_spec(
            id: {:auth_agent, make_ref()},
            handler: StdioAgent,
            handler_arg: handler_arg,
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
            id: {:auth_client, make_ref()},
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

    {:ok, init} =
      Connection.request(
        client_conn,
        "initialize",
        InitializeRequest.new(1),
        2_000
      )

    {client_conn, init}
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
