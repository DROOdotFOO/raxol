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
  alias Raxol.Agent.Test.AcpPipe
  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest

  @key "sk-or-v1-minted"

  describe "what initialize advertises" do
    test "offers Agent Auth for each provider with a flow, and nothing else" do
      methods = StdioAgent.auth_methods()

      assert Enum.map(methods, & &1.id) == Enum.map(Flow.providers(), &to_string/1)
      for method <- methods, do: assert(%{"agent-auth" => _} = method._meta)
    end

    test "reaches the client on the wire, not just the struct" do
      {_client, init} = connect(auth_opts: [])

      assert Enum.map(init.auth_methods, & &1.id) == Enum.map(Flow.providers(), &to_string/1)
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

    test "refuses a method id it never advertised" do
      {client, _init} = connect(auth_opts: [])

      for method_id <- ["anthropic", "terminal"] do
        assert {:error, error} =
                 Connection.request(
                   client,
                   "authenticate",
                   AuthenticateRequest.new(method_id),
                   2_000
                 )

        assert error.message =~ "unknown auth method"
      end
    end

    # Robinhood has a flow (`Flow.run(:robinhood, ...)`), but a brokerage
    # consent is not something an editor may start over ACP.
    test "neither advertises nor runs the brokerage sign-in" do
      refute Enum.any?(StdioAgent.auth_methods(), &(&1.id == "robinhood"))

      {client, _init} = connect(auth_opts: [])

      assert {:error, error} =
               Connection.request(
                 client,
                 "authenticate",
                 AuthenticateRequest.new("robinhood"),
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

  # A client past the handshake: every other method is refused until
  # `initialize` lands.
  defp connect(opts) do
    AcpPipe.start_trees()
    %{conn: conn, init: init} = AcpPipe.connect(nil, opts)
    {conn, init}
  end
end
