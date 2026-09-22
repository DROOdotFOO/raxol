defmodule Raxol.MCP.TestSupport.TLSEndpoint do
  @moduledoc """
  A real TLS listener with a real certificate, for testing a real handshake.

  Test support rather than a `lib/` reference implementation: nothing here fakes
  a behaviour of this package. It is a server, and what it proves is that
  `Raxol.MCP.Client.Transport.Http.Exchange` presents the right SNI, verifies
  against the right name, sends the right `Host` header and the right body, and
  holds its bounds against a peer that misbehaves on purpose. None of that is
  observable without something on the other end of a socket, and a mock of the
  dial would prove the opposite of the property under test.

  The same shape as `Raxol.Web3.TestSupport.TLSEndpoint`, for the same reason
  ADR-0037 decision 5 gives for the dial itself: one design in two packages,
  since `raxol_web3` depends on `raxol_mcp` and the dependency cannot run the
  other way.

  The trust anchor comes from OTP's own test PKI, `:public_key.pkix_test_data/1`,
  so there is no new dependency, no `openssl` shell-out and no certificate
  committed to the tree. `start/1` returns the generated `:cacerts`, which a
  test passes to the exchange as its trust store.

  Each accepted connection sends one message to the process that called
  `start/1`:

      {:tls_endpoint, %{sni: String.t() | nil, host: String.t() | nil,
                        request: binary(), body: binary()}}

  and a failed handshake sends `{:tls_endpoint, {:handshake_failed, reason}}`, so
  a test can assert that a mismatched hostname was refused by the handshake
  rather than merely unanswered.
  """

  require Record

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  # id-ce-subjectAltName
  @san_oid {2, 5, 29, 17}

  @accept_timeout_ms 5_000
  @handshake_timeout_ms 5_000
  @recv_timeout_ms 5_000

  @type t :: %{pid: pid(), port: :inet.port_number(), cacerts: [binary()]}

  @doc """
  Start a listener and return `{:ok, endpoint}`.

  Options:

    * `:sans` - `subjectAltName` dNSName entries as charlists, default
      `[~c"pinned.test"]`.
    * `:ip` - the address to bind, default `{127, 0, 0, 1}`.
    * `:respond` - `(sslsocket, request :: binary(), body :: binary() -> any())`,
      default a minimal JSON-RPC 200. This is how a test scripts a peer the
      client has to survive: an enormous announced `content-length`, a body
      that never comes, a body larger than the ceiling, a connection closed
      mid-response. Each of those is a bound in the exchange, and none of them
      is expressible against a server that only answers correctly.

  """
  @spec start(keyword()) :: {:ok, t()}
  def start(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:ssl)

    sans = Keyword.get(opts, :sans, [~c"pinned.test"])
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    respond = Keyword.get(opts, :respond, &ok/3)
    config = cert_config(sans)
    owner = self()

    pid = spawn_link(fn -> init(owner, ip, config, respond) end)

    receive do
      {:tls_endpoint_ready, ^pid, port} ->
        {:ok, %{pid: pid, port: port, cacerts: Keyword.fetch!(config, :cacerts)}}
    after
      @accept_timeout_ms -> exit({:tls_endpoint_never_listened, pid})
    end
  end

  @doc "The default responder: a minimal, correct JSON-RPC 200."
  @spec ok(:ssl.sslsocket(), binary(), binary()) :: :ok | {:error, term()}
  def ok(sock, _request, _body) do
    reply(sock, ~s({"jsonrpc":"2.0","id":1,"result":{"ok":true}}))
  end

  @doc "Send a 200 whose body is `payload`, with a correct content-length."
  @spec reply(:ssl.sslsocket(), binary()) :: :ok | {:error, term()}
  def reply(sock, payload) do
    :ssl.send(sock, [
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
      Integer.to_string(byte_size(payload)),
      "\r\nconnection: close\r\n\r\n",
      payload
    ])
  end

  @doc "Stop a listener. Linked to the test process, so this is for clarity."
  @spec stop(t()) :: :ok
  def stop(%{pid: pid}) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  defp init(owner, ip, config, respond) do
    {:ok, lsock} = :ssl.listen(0, listen_opts(ip, config))
    {:ok, {_ip, port}} = :ssl.sockname(lsock)
    send(owner, {:tls_endpoint_ready, self(), port})
    accept_loop(lsock, owner, respond)
  end

  defp listen_opts(ip, config) do
    [
      :binary,
      {:ip, ip},
      {:active, false},
      {:reuseaddr, true},
      {:cert, Keyword.fetch!(config, :cert)},
      {:key, Keyword.fetch!(config, :key)}
    ]
  end

  defp accept_loop(lsock, owner, respond) do
    case accept_one(lsock, owner, respond) do
      :cont -> accept_loop(lsock, owner, respond)
      :stop -> :ssl.close(lsock)
    end
  end

  defp accept_one(lsock, owner, respond) do
    case :ssl.transport_accept(lsock, @accept_timeout_ms) do
      {:ok, tsock} -> handshake(tsock, owner, respond)
      {:error, _reason} -> :stop
    end
  end

  defp handshake(tsock, owner, respond) do
    case :ssl.handshake(tsock, @handshake_timeout_ms) do
      {:ok, sock} ->
        serve(sock, owner, respond)
        :cont

      {:error, reason} ->
        send(owner, {:tls_endpoint, {:handshake_failed, reason}})
        :cont
    end
  end

  defp serve(sock, owner, respond) do
    request = read_headers(sock, "")
    body = read_body(sock, request)

    send(
      owner,
      {:tls_endpoint,
       %{sni: sni(sock), host: header(request, "host"), request: request, body: body}}
    )

    respond.(sock, request, body)
    :ssl.close(sock)
  end

  defp read_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :ssl.recv(sock, 0, @recv_timeout_ms) do
        {:ok, data} -> read_headers(sock, acc <> IO.iodata_to_binary(data))
        {:error, _reason} -> acc
      end
    end
  end

  # The transport only ever POSTs, so the body is what the assertion about
  # "the request that went out" is actually about.
  defp read_body(sock, request) do
    with [_headers, rest] <- String.split(request, "\r\n\r\n", parts: 2),
         length when is_integer(length) <- content_length(request) do
      read_more(sock, rest, length)
    else
      _no_body -> ""
    end
  end

  defp read_more(_sock, acc, length) when byte_size(acc) >= length, do: acc

  defp read_more(sock, acc, length) do
    case :ssl.recv(sock, 0, @recv_timeout_ms) do
      {:ok, data} -> read_more(sock, acc <> IO.iodata_to_binary(data), length)
      {:error, _reason} -> acc
    end
  end

  defp content_length(request) do
    with value when is_binary(value) <- header(request, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _absent -> nil
    end
  end

  defp sni(sock) do
    case :ssl.connection_information(sock, [:sni_hostname]) do
      {:ok, [sni_hostname: name]} when is_list(name) -> List.to_string(name)
      _absent -> nil
    end
  end

  defp header(request, name) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(&header_value(&1, name))
  end

  defp header_value(line, name) do
    case String.split(line, ":", parts: 2) do
      [key, value] -> if String.downcase(key) == name, do: String.trim(value)
      _other -> nil
    end
  end

  # OTP's test PKI: a root plus one peer carrying the requested subjectAltName
  # entries. The key type and digest are pinned rather than defaulted: left to
  # itself `pkix_test_data/1` signs with ecdsa-with-SHA1, which TLS 1.3
  # refuses, and every handshake then fails server-side in a way that reads on
  # the client as a certificate mismatch.
  defp cert_config(sans) do
    san =
      extension(
        extnID: @san_oid,
        critical: false,
        extnValue: Enum.map(sans, &{:dNSName, &1})
      )

    chain = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    :public_key.pkix_test_data(%{
      root: chain,
      peer: Keyword.put(chain, :extensions, [san])
    })
  end
end
