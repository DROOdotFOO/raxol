defmodule Raxol.Web3.TestSupport.TLSEndpoint do
  @moduledoc """
  A real TLS listener with a real certificate, for testing a real handshake.

  This is test support rather than a `lib/` reference implementation, and the
  distinction matters to the house rule about stubs. Nothing here fakes a
  behaviour of this package: it is a server, and what it proves is that
  `Raxol.Web3.Dial` presents the right SNI, verifies against the right name,
  and sends the right `Host` header, none of which can be observed without
  something on the other end of a socket. A mock of the dial would prove the
  opposite of the property under test.

  The trust anchor comes from OTP's own test PKI,
  `:public_key.pkix_test_data/1`, so there is no new dependency, no `openssl`
  shell-out and no certificate committed to the tree. `start/1` returns the
  generated `:cacerts`, which the test passes to the dial as its trust store,
  and the peer certificate carries exactly the `subjectAltName` entries the
  test asked for. That is what makes "two hostnames on one address" expressible
  as a local test.

  Each accepted connection sends one message to the process that called
  `start/1`:

      {:tls_endpoint, %{sni: String.t() | nil, host: String.t() | nil, request: binary()}}

  and a failed handshake sends `{:tls_endpoint, {:handshake_failed, reason}}`,
  so a test can assert that a mismatched hostname was refused by the handshake
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

  @ok_response "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"

  @type t :: %{pid: pid(), port: :inet.port_number(), cacerts: [binary()]}

  @doc """
  Start a listener and return `{:ok, endpoint}`.

  Options:

    * `:sans` - `subjectAltName` dNSName entries as charlists, default
      `[~c"pinned.test"]`. More than one is how a certificate that covers two
      hostnames on one address is built.
    * `:ip` - the address to bind, default `{127, 0, 0, 1}`. Pass
      `{0, 0, 0, 0, 0, 0, 0, 1}` for the IPv6 case.
    * `:respond` - `(sslsocket, request :: binary() -> any())`, default a
      minimal 200. This is how a test scripts a peer the client has to survive:
      a header section arriving one line at a time, a body that never comes
      after an enormous `content-length`, a chunked body with no end. Each of
      those is a bound in `Raxol.Web3.Exchange`, and none of them is
      expressible against a server that only knows how to answer correctly.

  """
  @spec start(keyword()) :: {:ok, t()}
  def start(opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:ssl)

    sans = Keyword.get(opts, :sans, [~c"pinned.test"])
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    respond = Keyword.get(opts, :respond, &ok/2)
    config = cert_config(sans)
    owner = self()

    pid = spawn_link(fn -> init(owner, ip, config, respond) end)

    receive do
      {:tls_endpoint_ready, ^pid, port} ->
        {:ok, %{pid: pid, port: port, cacerts: Keyword.fetch!(config, :cacerts)}}
    after
      @accept_timeout_ms ->
        exit({:tls_endpoint_never_listened, pid})
    end
  end

  @doc "The default responder: a minimal, correct 200."
  @spec ok(:ssl.sslsocket(), binary()) :: :ok | {:error, term()}
  def ok(sock, _request), do: :ssl.send(sock, @ok_response)

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
    request = read_request(sock, "")

    send(
      owner,
      {:tls_endpoint, %{sni: sni(sock), host: header(request, "host"), request: request}}
    )

    respond.(sock, request)
    :ssl.close(sock)
  end

  # Reads until the end of the header section. The dial sends no body, so the
  # blank line is the whole request.
  defp read_request(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :ssl.recv(sock, 0, @recv_timeout_ms) do
        {:ok, data} -> read_request(sock, acc <> IO.iodata_to_binary(data))
        {:error, _reason} -> acc
      end
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

  # OTP's test PKI: a root plus one peer, with the peer carrying the requested
  # subjectAltName entries. Returns `[cert: der, key: {type, der}, cacerts: [der]]`.
  #
  # The key type and digest are pinned rather than defaulted. Left to itself,
  # `pkix_test_data/1` signs with ecdsa-with-SHA1, which TLS 1.3 refuses, and
  # the listener then fails every handshake with
  # `:unable_to_supply_acceptable_cert`: a server-side refusal that reads, on
  # the client, as the certificate-mismatch error two tests here assert for the
  # opposite reason.
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
