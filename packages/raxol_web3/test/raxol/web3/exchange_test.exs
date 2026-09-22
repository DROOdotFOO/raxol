defmodule Raxol.Web3.ExchangeTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Dial
  alias Raxol.Web3.Exchange
  alias Raxol.Web3.TestSupport.TLSEndpoint

  # Every bound here is a property of a peer that misbehaves, so every test
  # scripts the server rather than the client. The timings are deliberately
  # asymmetric (a bound in the low hundreds of milliseconds against a server
  # that misbehaves for seconds) so a slow machine cannot flip an outcome.

  defp endpoint(respond) do
    TLSEndpoint.start(sans: [~c"pinned.test"], respond: respond)
  end

  defp exchange(endpoint, opts) do
    {:ok, conn} =
      Dial.connect([{127, 0, 0, 1}], "pinned.test",
        port: endpoint.port,
        transport_opts: [cacerts: endpoint.cacerts]
      )

    Exchange.run(conn, %{method: "GET", path: "/api/v2/stats"}, opts)
  end

  defp send_all(sock, data), do: :ssl.send(sock, data)

  describe "a well-formed response" do
    test "comes back with its status, headers and body" do
      body = ~s({"total_blocks":"25969884"})

      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, """
          HTTP/1.1 200 OK\r
          content-type: application/json\r
          content-length: #{byte_size(body)}\r
          \r
          #{body}\
          """)
        end)

      assert {:ok, response} = exchange(endpoint, [])
      assert response.status == 200
      assert response.body == body
      assert {"content-type", "application/json"} in response.headers
    end

    test "a non-2xx status is a response, not an error" do
      # Whether a status is a failure is the router's decision, not this
      # module's. A 403 challenge page has to arrive intact for the breaker to
      # classify it.
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 403 Forbidden\r\ncontent-length: 4\r\n\r\nnope")
        end)

      assert {:ok, %{status: 403, body: "nope"}} = exchange(endpoint, [])
    end

    test "a body delimited by connection close is complete, not truncated" do
      # Mint reports the close as a transport error with the terminating
      # response alongside it. Discarding those responses would turn this into
      # `{:transport, :closed}`.
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nclosed-delimited")
        end)

      assert {:ok, %{status: 200, body: "closed-delimited"}} = exchange(endpoint, [])
    end
  end

  describe "the size ceiling" do
    test "a streamed body past the ceiling is an error, never a truncated success" do
      # Chunked, so there is no content-length to pre-reject on and the
      # streaming counter is the only bound under test. The server keeps writing
      # until the client goes away.
      chunk = String.duplicate("x", 16_384)

      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
          flood(sock, chunk, 64)
        end)

      assert {:error, {:too_large, 65_536}} = exchange(endpoint, max_bytes: 65_536)
    end

    test "a body of exactly the ceiling is accepted" do
      # The boundary is inclusive, so a response sized at the limit is not a
      # failure. Getting this backwards makes the ceiling an off-by-one that
      # only shows up on the one response that sits exactly on it.
      body = String.duplicate("y", 1_024)

      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n\r\n" <> body)
        end)

      assert {:ok, %{body: ^body}} = exchange(endpoint, max_bytes: 1_024)
    end

    test "an announced content-length past the ceiling is refused before the body" do
      test = self()

      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ncontent-length: 8388608\r\n\r\n")
          send(test, {:headers_sent, self()})

          receive do
            :send_body -> send_all(sock, "too late")
          end
        end)

      request =
        Task.async(fn ->
          exchange(endpoint, max_bytes: 65_536, chunk_timeout_ms: 5_000)
        end)

      assert_receive {:headers_sent, server}
      assert {:error, {:too_large, 65_536}} = Task.await(request, 6_000)
      send(server, :send_body)
    end
  end

  describe "the deadline" do
    test "covers the header phase, which a stream callback cannot" do
      # The whole argument for owning the read loop. Headers arrive one line at
      # a time, each well inside the chunk timeout, and no response entry is
      # emitted until the section is complete, so a deadline checked inside a
      # per-entry callback never fires. Mint's only bound here is 256 KiB of
      # header bytes.
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\n")
          drip_headers(sock, 40)
        end)

      assert {:error, {:timeout, :deadline}} =
               exchange(endpoint, deadline_ms: 300, chunk_timeout_ms: 5_000)
    end

    test "a slow drip of body bytes inside the chunk timeout still hits it" do
      chunk = String.duplicate("z", 8)

      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
          drip_chunks(sock, chunk, 40)
        end)

      assert {:error, {:timeout, :deadline}} =
               exchange(endpoint, deadline_ms: 300, chunk_timeout_ms: 5_000)
    end

    test "is distinguished from a silent peer" do
      # Same failure to a caller that only checks for a timeout, and a
      # different diagnosis: one says the upstream is slow overall, the other
      # says it stopped talking. The clamp is what tells them apart.
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n")
          Process.sleep(3_000)
        end)

      assert {:error, {:timeout, :chunk}} =
               exchange(endpoint, deadline_ms: 10_000, chunk_timeout_ms: 200)
    end

    test "an already-expired deadline puts no request on the wire" do
      # Asserted on what the SERVER read, not on a handler that refuses to run:
      # the connection is already open by the time the exchange starts, so the
      # peer accepts it either way. What distinguishes a pre-send deadline check
      # is that the peer reads no request bytes before the client hangs up.
      {:ok, endpoint} = endpoint(fn _sock, _req -> :ok end)

      assert {:error, {:timeout, :deadline}} = exchange(endpoint, deadline_ms: 0)

      assert_receive {:tls_endpoint, %{request: ""}}, 5_000
    end
  end

  describe "truncation cannot masquerade as success" do
    test "a response cut off mid-body is a transport error, not a short body" do
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          # Announces 64 bytes, sends 4, then closes.
          send_all(sock, "HTTP/1.1 200 OK\r\ncontent-length: 64\r\n\r\nfour")
        end)

      assert {:error, {:transport, _reason}} = exchange(endpoint, [])
    end

    test "headers with no body and no terminator never become an empty 200" do
      # The accumulator starts incomplete, so a read that ends without the
      # terminating response has nothing to return. A success-shaped initial
      # accumulator would answer `{:ok, %{status: 200, body: ""}}` here, which
      # for a list endpoint reads as "no results".
      {:ok, endpoint} =
        endpoint(fn sock, _req ->
          send_all(sock, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\n")
          Process.sleep(3_000)
        end)

      assert {:error, {:timeout, :chunk}} =
               exchange(endpoint, deadline_ms: 10_000, chunk_timeout_ms: 200)
    end
  end

  describe "the connection" do
    test "is closed on success and on every failure" do
      {:ok, ok_endpoint} = endpoint(&TLSEndpoint.ok/2)

      {:ok, conn} =
        Dial.connect([{127, 0, 0, 1}], "pinned.test",
          port: ok_endpoint.port,
          transport_opts: [cacerts: ok_endpoint.cacerts]
        )

      assert Mint.HTTP.open?(conn)
      assert {:ok, _response} = Exchange.run(conn, %{method: "GET", path: "/"})

      # The struct the caller still holds is the pre-close one, so open? is
      # asked of a fresh read instead: the socket is gone, so a second exchange
      # on it cannot reach the server.
      assert {:error, {:transport, _}} = Exchange.run(conn, %{method: "GET", path: "/"})
    end
  end

  describe "the request" do
    test "carries the method, path and headers it was given" do
      {:ok, endpoint} = endpoint(&TLSEndpoint.ok/2)

      {:ok, conn} =
        Dial.connect([{127, 0, 0, 1}], "pinned.test",
          port: endpoint.port,
          transport_opts: [cacerts: endpoint.cacerts]
        )

      assert {:ok, _response} =
               Exchange.run(conn, %{
                 method: "POST",
                 path: "/rpc",
                 headers: [{"content-type", "application/json"}],
                 body: ~s({"method":"eth_blockNumber"})
               })

      assert_receive {:tls_endpoint, %{request: request}}, 5_000
      assert request =~ "POST /rpc HTTP/1.1"
      assert request =~ "content-type: application/json"
      assert request =~ "content-length: 28"
    end
  end

  # -- scripted peers ----------------------------------------------------------

  defp flood(_sock, _chunk, 0), do: :ok

  defp flood(sock, chunk, remaining) do
    frame = [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]

    case :ssl.send(sock, frame) do
      :ok -> flood(sock, chunk, remaining - 1)
      {:error, _closed} -> :ok
    end
  end

  defp drip_headers(_sock, 0), do: :ok

  defp drip_headers(sock, remaining) do
    case :ssl.send(sock, "x-filler-#{remaining}: 1\r\n") do
      :ok ->
        Process.sleep(50)
        drip_headers(sock, remaining - 1)

      {:error, _closed} ->
        :ok
    end
  end

  defp drip_chunks(_sock, _chunk, 0), do: :ok

  defp drip_chunks(sock, chunk, remaining) do
    frame = [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]

    case :ssl.send(sock, frame) do
      :ok ->
        Process.sleep(50)
        drip_chunks(sock, chunk, remaining - 1)

      {:error, _closed} ->
        :ok
    end
  end
end
