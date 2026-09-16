if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Raxol.MCP.Client.Transport.Http.Exchange do
    @moduledoc """
    The pinned dial and the bounded read: one request, one bounded response.

    ADR-0037 decision 5, which says explicitly that this transport takes the
    shape ADR-0038 decision 3 and 4 already implement for the REST side
    (`packages/raxol_web3/lib/raxol/web3/dial.ex`,
    `packages/raxol_web3/lib/raxol/web3/exchange.ex`). One design in two
    packages rather than two: copying is forced by the package graph, since
    `raxol_web3` depends on `raxol_mcp` and not the other way round.

    ## The checked address is the address dialled

    `run/3` takes the `:inet` address tuples `Raxol.Core.Outbound.vet/2`
    checked, never a name, so there is no code path here that could consult a
    resolver and no window for a record that changes between the check and the
    connect. A binary where an address belongs is refused as
    `{:not_an_address, value}` rather than resolved.

    Mint derives everything that must follow the NAME from one `:hostname`
    option: SNI, the certificate match function, and the HTTP/1 `Host` header.
    So `:server_name_indication` and `:customize_hostname_check` are never set
    by hand -- setting either replaces a value Mint already derived correctly
    -- and `:verify` and `:verify_fun` are refused outright, because a silently
    weakened handshake is the failure this module exists to prevent. A
    caller-supplied `:transport_opts` never reaches here: the only caller is
    `Raxol.MCP.Client.Transport.Http`, which does not accept one.

    There is no connection pool. A pool key is `{scheme, host, port, tag}`, so
    a vetted IP in the host position makes every hostname that resolves to that
    address share one pool and inherit whichever identity opened it first.

    ## The bounded read

    The send, the four bounds (size ceiling, content-length pre-rejection,
    wall-clock deadline, per-`recv` silence) and the close are
    `Raxol.MCP.BoundedExchange`, which `Raxol.Web3.Exchange` reads through too:
    the two used to be identical copies, down to the read-phase taxonomy. The
    reasoning for each bound is in that module. What stays here is the dial and
    the connect-side reasons, which are this transport's alone.

    ## Truncation is never a success

    The accumulator is `Raxol.Core.Outbound.Response`: it starts `:incomplete`
    and only the terminating response promotes it, so `run/3` cannot return
    `{:ok, _}` for a partial response by construction. That matters more here
    than for a REST body: a truncated SSE stream still contains whole frames,
    so a reader that returned what it had would hand the session a
    plausible-looking response to a request that never completed.

    ## Redirects

    A 3xx is returned as a response, not followed, and the caller refuses it.
    Following one would replay this transport's `Authorization` header at an
    origin the upstream chose.
    """

    alias Raxol.MCP.BoundedExchange

    @default_connect_timeout_ms 5_000

    # Each either replaces a value Mint derives from `:hostname`, or weakens
    # verification outright.
    @forbidden_transport_opts [
      :server_name_indication,
      :customize_hostname_check,
      :verify,
      :verify_fun
    ]

    @type vetted :: %{uri: URI.t(), addresses: [:inet.ip_address()], hostname: String.t()}

    @type request :: %{
            required(:method) => String.t(),
            required(:path) => String.t(),
            optional(:headers) => Mint.Types.headers(),
            optional(:body) => iodata() | nil
          }

    @type response :: BoundedExchange.response()

    @type reason ::
            :no_addresses
            | {:not_an_address, term()}
            | {:forbidden_transport_opts, [atom()]}
            | {:too_large, pos_integer()}
            | {:timeout, :connect | :chunk | :deadline}
            | {:transport, term()}

    @doc """
    Dial a vetted target and read one bounded response.

    Options: `:port` (defaults to the vetted URI's port), `:connect_timeout_ms`,
    `:deadline_ms`, `:chunk_timeout_ms`, `:max_bytes`, and `:transport_opts`
    for a test's own trust store. The connection is closed on every path.
    """
    @spec run(vetted(), request(), keyword()) :: {:ok, response()} | {:error, reason()}
    def run(vetted, request, opts \\ []) do
      case connect(vetted, opts) do
        {:ok, conn} -> BoundedExchange.run(conn, request, opts)
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Connect to the first reachable vetted address, presenting `hostname` as the
    identity.

    Every address is tried in turn, which is the failover `:gen_tcp` performs
    for a name and which pinning would otherwise lose. Public so that the dial
    can be tested against a real local TLS listener, which the reject set
    refuses to let the guarded path reach.
    """
    @spec connect(vetted(), keyword()) :: {:ok, Mint.HTTP.t()} | {:error, reason()}
    def connect(%{addresses: [], hostname: _hostname}, _opts), do: {:error, :no_addresses}

    def connect(%{addresses: addresses, hostname: hostname} = vetted, opts) do
      with :ok <- check_addresses(addresses),
           {:ok, transport_opts} <- check_transport_opts(opts) do
        timeout = Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)
        port = Keyword.get(opts, :port) || vetted.uri.port || 443

        connect_opts = [
          hostname: hostname,
          protocols: [:http1],
          mode: :passive,
          transport_opts: Keyword.put(transport_opts, :timeout, timeout)
        ]

        try_each(addresses, port, connect_opts, [])
      end
    end

    # Every address was tried and every one failed. A list of nothing but
    # timeouts is a connect timeout; anything else reports the LAST attempt,
    # collapsed to an atom so that no address, port or peer detail rides out in
    # the error term. `failures` is newest-first, so the head is that attempt.
    defp try_each([], _port, _opts, [{_address, reason} | _earlier] = failures) do
      if Enum.all?(failures, fn {_address, reason} -> timeout?(reason) end),
        do: {:error, {:timeout, :connect}},
        else: {:error, {:transport, transport_atom(reason)}}
    end

    defp try_each([address | rest], port, opts, failures) do
      case Mint.HTTP.connect(:https, address, port, opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> try_each(rest, port, opts, [{address, reason} | failures])
      end
    end

    defp transport_atom(%Mint.TransportError{reason: reason}), do: transport_atom(reason)
    defp transport_atom(%Mint.HTTPError{reason: reason}), do: transport_atom(reason)
    defp transport_atom(reason) when is_atom(reason), do: reason

    # A TLS alert arrives as `{:tls_alert, {name, charlist}}`, whose payload is
    # peer text. The tag is kept and the text is not.
    defp transport_atom(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
      case elem(reason, 0) do
        tag when is_atom(tag) -> tag
        _other -> :unknown
      end
    end

    defp transport_atom(_other), do: :unknown

    defp timeout?(%Mint.TransportError{reason: :timeout}), do: true
    defp timeout?(_reason), do: false

    # A name reaching here is a caller that skipped the vet, so it fails closed
    # rather than being resolved as a convenience. `Enum.reject/2` rather than
    # `Enum.find/2` because `nil` is both a plausible mistake and `find/2`'s
    # not-found sentinel.
    defp check_addresses(addresses) do
      case Enum.reject(addresses, &address?/1) do
        [] -> :ok
        [other | _rest] -> {:error, {:not_an_address, other}}
      end
    end

    defp address?(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
      address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0))
    end

    defp address?(_other), do: false

    defp check_transport_opts(opts) do
      transport_opts = Keyword.get(opts, :transport_opts, [])

      case Enum.filter(@forbidden_transport_opts, &Keyword.has_key?(transport_opts, &1)) do
        [] -> {:ok, transport_opts}
        forbidden -> {:error, {:forbidden_transport_opts, forbidden}}
      end
    end
  end
end
