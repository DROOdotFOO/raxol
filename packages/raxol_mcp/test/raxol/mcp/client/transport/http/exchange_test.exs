defmodule Raxol.MCP.Client.Transport.Http.ExchangeTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Outbound
  alias Raxol.MCP.Client.Transport.Http.Exchange
  alias Raxol.MCP.TestSupport.TLSEndpoint

  # The socket half of ADR-0037 validation item 7. These tests dial loopback,
  # which `Raxol.Core.Outbound` refuses BY DESIGN, and that is the point of the
  # split: the exchange holds no policy, so it can be pointed at a local
  # listener, while the guarded path cannot reach one. Testing the handshake
  # through the policy would mean punching a hole in the policy for the tests to
  # walk through. The last test in this file pins that.

  defp vetted(endpoint, addresses \\ [{127, 0, 0, 1}], hostname \\ "pinned.test") do
    {:ok, uri} = URI.new("https://#{hostname}:#{endpoint.port}/mcp")
    %{uri: uri, addresses: addresses, hostname: hostname}
  end

  # In a module attribute rather than in a default argument: credo 1.7.17
  # crashes tokenizing a sigil in a function head under Elixir 1.20
  # (`Credo.Code.Token.position/1`), and a repo-wide `mix credo --strict` takes
  # the whole run down with it.
  @probe_body ~s({"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}})

  # Also attributes rather than inline sigils, for the same credo reason: the
  # crash is in its space-around-operators tokenizer, so a sigil immediately
  # after `==` or `=` is what takes the run down.
  @ok_body ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}})
  @empty_result_body ~s({"jsonrpc":"2.0","id":1,"result":{}})

  defp request(body \\ @probe_body) do
    %{
      method: "POST",
      path: "/mcp",
      headers: [
        {"accept", "application/json, text/event-stream"},
        {"content-type", "application/json"}
      ],
      body: body
    }
  end

  defp trust(endpoint, extra \\ []) do
    [transport_opts: [cacerts: endpoint.cacerts], connect_timeout_ms: 5_000] ++ extra
  end

  describe "identity follows the hostname while the socket goes to the address" do
    test "SNI, Host and the body all arrive as sent" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:ok, response} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint))

      assert response.status == 200
      assert response.body == @ok_body

      assert_receive {:tls_endpoint, observed}, 5_000
      assert observed.sni == "pinned.test"
      assert observed.host == "pinned.test:#{endpoint.port}"
      assert observed.request =~ "POST /mcp HTTP/1.1"
      assert observed.body == @probe_body
    end

    test "a hostname the certificate does not cover fails the handshake" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:error, {:transport, reason}} =
               Exchange.run(
                 vetted(endpoint, [{127, 0, 0, 1}], "evil.test"),
                 request(),
                 trust(endpoint)
               )

      assert is_atom(reason)
      assert_receive {:tls_endpoint, {:handshake_failed, _why}}, 5_000
      refute_receive {:tls_endpoint, %{sni: _sni}}, 200
    end

    test "verification is on, so an untrusted certificate is refused" do
      # No `:cacerts`: the peer chains to OTP's generated test root, which the
      # system trust store does not contain.
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:error, {:transport, _reason}} =
               Exchange.run(vetted(endpoint), request(), connect_timeout_ms: 5_000)
    end
  end

  describe "the address" do
    test "a name handed where an address belongs is refused, never resolved" do
      # The whole mechanism of rule 3 is that this function cannot resolve
      # anything: a caller that skipped the vet fails closed.
      {:ok, endpoint} = TLSEndpoint.start()

      for not_an_address <- ["pinned.test", "127.0.0.1", ~c"127.0.0.1", {1, 2, 3}, nil] do
        assert {:error, {:not_an_address, ^not_an_address}} =
                 Exchange.run(
                   vetted(endpoint, [not_an_address]),
                   request(),
                   trust(endpoint)
                 ),
               "#{inspect(not_an_address)} was accepted as an address"
      end

      refute_receive {:tls_endpoint, _observed}, 200
    end

    test "an empty address list is refused rather than falling back to the name" do
      {:ok, endpoint} = TLSEndpoint.start()
      assert {:error, :no_addresses} = Exchange.run(vetted(endpoint, []), request(), [])
    end

    test "every vetted address is tried in order" do
      # The failover `:gen_tcp` performs for a name, which pinning would
      # otherwise lose: the hosts this transport targets answer with several
      # addresses. The listener is on IPv4 only, so the IPv6 attempt fails first.
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      assert {:ok, %{status: 200}} =
               Exchange.run(
                 vetted(endpoint, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]),
                 request(),
                 trust(endpoint)
               )

      assert_receive {:tls_endpoint, %{sni: "pinned.test"}}, 5_000
    end
  end

  describe "transport options that would weaken the handshake" do
    test "are refused rather than merged, and no socket is opened" do
      {:ok, endpoint} = TLSEndpoint.start(sans: [~c"pinned.test"])

      for key <- [:verify, :verify_fun, :server_name_indication, :customize_hostname_check] do
        assert {:error, {:forbidden_transport_opts, [^key]}} =
                 Exchange.run(
                   vetted(endpoint),
                   request(),
                   transport_opts: [{key, :anything}]
                 )
      end

      refute_receive {:tls_endpoint, _observed}, 200
    end

    test "reports every forbidden key, not just the first" do
      {:ok, endpoint} = TLSEndpoint.start()

      assert {:error, {:forbidden_transport_opts, [:server_name_indication, :verify]}} =
               Exchange.run(
                 vetted(endpoint),
                 request(),
                 transport_opts: [verify: :verify_none, server_name_indication: ~c"evil.test"]
               )
    end
  end

  describe "the bounds" do
    test "an announced content-length over the ceiling is refused before the body" do
      # One round trip rather than the ceiling: the refusal happens on the
      # header, so the body is never read.
      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 5000000\r\n\r\n")
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:error, {:too_large, 1_024}} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint, max_bytes: 1_024))
    end

    test "a body that streams past the ceiling is refused" do
      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
        # No announced length, so only the streaming counter bounds this.
        Enum.each(1..8, fn _ -> :ssl.send(sock, :binary.copy("x", 512)) end)
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:error, {:too_large, 1_024}} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint, max_bytes: 1_024))
    end

    test "exactly the ceiling is allowed" do
      payload = :binary.copy("y", 64)

      respond = fn sock, _request, _body -> TLSEndpoint.reply(sock, payload) end
      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:ok, %{body: ^payload}} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint, max_bytes: 64))
    end

    test "a peer that goes silent mid-response is a chunk timeout" do
      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\npartial")
        Process.sleep(2_000)
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:error, {:timeout, :chunk}} =
               Exchange.run(
                 vetted(endpoint),
                 request(),
                 trust(endpoint, chunk_timeout_ms: 100, deadline_ms: 5_000)
               )
    end

    test "a slow response that outlasts the deadline is a deadline timeout" do
      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\npartial")
        Process.sleep(2_000)
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      # The deadline is shorter than the chunk timeout, so the wait is clamped
      # and the timeout is attributable to the deadline rather than to silence.
      assert {:error, {:timeout, :deadline}} =
               Exchange.run(
                 vetted(endpoint),
                 request(),
                 trust(endpoint, chunk_timeout_ms: 5_000, deadline_ms: 150)
               )
    end

    test "a truncated response is an error, never a short success" do
      # The accumulator starts incomplete and only the terminating response
      # promotes it. A reader whose accumulator looked like a success would hand
      # the session half a JSON-RPC message as an answer.
      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{\"jsonrpc\"")
        :ssl.close(sock)
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:error, {:transport, _reason}} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint))
    end

    test "a body delimited by the connection close is complete, not truncated" do
      # The contrast with the test above, and the reason responses arriving
      # alongside a transport error are absorbed before the error is reported:
      # an HTTP/1 body with no announced length is completed BY the close.
      payload = @empty_result_body

      respond = fn sock, _request, _body ->
        :ssl.send(sock, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n" <> payload)
        :ssl.close(sock)
      end

      {:ok, endpoint} = TLSEndpoint.start(respond: respond)

      assert {:ok, %{status: 200, body: ^payload}} =
               Exchange.run(vetted(endpoint), request(), trust(endpoint))
    end
  end

  describe "composition with the policy" do
    test "the guarded path cannot reach a local endpoint, which is why this file dials directly" do
      # Stated as a test rather than as a comment. `Raxol.Core.OutboundTest`
      # pins the half this cannot: a resolver that changes its answer between
      # calls yields only the first, checked answer.
      resolver = fn
        _host, :inet -> {:ok, [{127, 0, 0, 1}]}
        _host, :inet6 -> {:ok, []}
      end

      assert {:error, {:blocked_address, "pinned.test"}} =
               Outbound.vet("https://pinned.test/mcp", resolver: resolver)
    end
  end
end
