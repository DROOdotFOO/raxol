defmodule Raxol.Web3.Dial do
  @moduledoc """
  The pinned dial: connect to a vetted ADDRESS while the hostname carries identity.

  This is ADR-0033 section 7's third rule, "the checked address is the address
  dialled", and it is the first implementation of it in this repository. The
  rule exists because validating a hostname and then handing that hostname to an
  HTTP client makes the client resolve it a second time, so a record that
  changes between the two resolutions (DNS rebinding) is never checked.

  `connect/3` takes `:inet` address tuples, never names. That is the whole
  mechanism: there is no code path here that could consult a resolver, so the
  property is structural rather than a convention a later edit can break. A
  binary handed where an address belongs is refused with
  `{:not_an_address, value}` rather than resolved.

  ## How one option carries three things

  Mint takes the dialled address and the verification identity separately, and
  derives everything that must follow the name from the `:hostname` option:

    * SNI, through `server_name_indication: hostname`
      (`deps/mint/lib/mint/core/transport/ssl.ex:561-573`)
    * the certificate match function, through `customize_hostname_check`
      derived from the same value (`ssl.ex:459-501`)
    * the HTTP/1 `Host` header, from the connection's `host` field, which is
      set from `:hostname` at connect time (`deps/mint/lib/mint/http1.ex:170-178`,
      `:244`, `:1265-1278`)

  So `:server_name_indication` and `:customize_hostname_check` are never set by
  hand: setting either replaces a value Mint already derived correctly, and
  setting `verify` or `verify_fun` can switch verification off entirely.
  `connect/3` refuses all four rather than merging them, because a silently
  weakened handshake is the failure this module exists to prevent.

  ## No pool, one connection per request

  There is deliberately no connection pool. A pool is keyed by `{scheme, host,
  port, tag}`, so putting a vetted IP in the host makes every hostname that
  resolves to that address share one pool and inherit whichever identity opened
  it first. Measured on 2026-09-13, all five EVM explorer hosts this package
  targets, plus one more, resolve to the same three Cloudflare addresses, so
  that is the normal case rather than an edge. ADR-0038 decision 3 records the
  other two failures (no IPv6 path through a host string, and a lazily created
  default pool inheriting no `:hostname`) and the full argument.

  An address tuple also carries its own family, which a host string does not:
  `:ssl.connect/4` resolves a string with family `inet` unless told otherwise,
  so a pinned IPv6 dial through a URL fails as `:nxdomain` on an address that
  resolves perfectly well.

  ## No policy

  Nothing here checks an address against the reject set. `Raxol.Core.Outbound`
  does that, and `Raxol.Web3.HTTP` is the one caller that runs the two in
  order. Repeating the check here would be a second copy of a policy, and it
  would make this module untestable without punching a hole in that policy,
  since a local test endpoint necessarily listens on loopback, which the reject
  set refuses. The tests dial loopback directly for exactly that reason.

  ## Mode

  Connections are opened in `mode: :passive`. The bounded read this dial feeds
  is a synchronous `Mint.HTTP.recv/3` loop that owns its own deadline, and
  `recv/3` requires a passive socket. This is not overridable.
  """

  @default_port 443
  @default_timeout_ms 5_000

  # Each of these either replaces a value Mint derives from `:hostname`, or
  # weakens verification outright.
  #
  # `:partial_chain` and `:versions` are defence in depth rather than a fix:
  # neither is reachable through `Raxol.Web3.HTTP`, which refuses
  # `:transport_opts` outright. `:partial_chain` lets a caller declare an
  # intermediate trusted and so accept a chain that does not reach a root,
  # and `:versions` can put TLS 1.0 back on the wire. Both belong on the
  # same list as `:verify` for the same reason.
  @forbidden_transport_opts [
    :server_name_indication,
    :customize_hostname_check,
    :verify,
    :verify_fun,
    :partial_chain,
    :versions
  ]

  @type address :: :inet.ip_address()

  @type reason ::
          :no_addresses
          | {:not_an_address, term()}
          | {:forbidden_transport_opts, [atom()]}
          | {:dial_failed, [{address(), term()}]}
          | {:budget_exhausted, [{address(), term()}]}

  @doc """
  Connect to the first reachable address, presenting `hostname` as the identity.

  `addresses` is the vetted list from `Raxol.Core.Outbound.vet/2`, in
  resolution order. Each is tried in turn, which is the failover `:gen_tcp`
  performs when it is handed a name and which pinning would otherwise lose:
  the hosts this package targets answer with three addresses each. Every
  failure is collected, so `{:dial_failed, failures}` names what was attempted
  rather than only what failed last.

  Options:

    * `:port` - default `443`
    * `:timeout` - per-address connect timeout in milliseconds, default `5000`.
      Authoritative: a `:timeout` inside `:transport_opts` is overwritten with
      it, so the budget cannot be widened from two places at once.
    * `:budget_ms` - the total across every address, default `:infinity`.
      `:timeout` alone bounds one attempt, and a vetted list carries every A
      and AAAA answer the host gave, so a black-holed host costs
      `:timeout * length(addresses)` before the caller's read deadline has
      even started. With a budget, each attempt gets
      `min(:timeout, what is left)` and the rest of the list is abandoned as
      `{:budget_exhausted, failures}` when nothing is. `Raxol.Web3.HTTP`
      always passes one, computed from its own end-to-end deadline.
    * `:transport_opts` - passed to `:ssl`, minus the six keys above. A test
      supplies its own `:cacerts` here.

  """
  @spec connect([address()], String.t(), keyword()) ::
          {:ok, Mint.HTTP.t()} | {:error, reason()}
  def connect(addresses, hostname, opts \\ [])

  def connect([], hostname, _opts) when is_binary(hostname), do: {:error, :no_addresses}

  def connect(addresses, hostname, opts)
      when is_list(addresses) and is_binary(hostname) and is_list(opts) do
    with :ok <- check_addresses(addresses),
         {:ok, transport_opts} <- check_transport_opts(opts) do
      port = Keyword.get(opts, :port, @default_port)
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

      connect_opts = [
        hostname: hostname,
        protocols: [:http1],
        mode: :passive,
        transport_opts: transport_opts
      ]

      try_each(addresses, port, connect_opts, timeout, deadline(opts), [])
    end
  end

  defp try_each([], _port, _opts, _timeout, _deadline, failures),
    do: {:error, {:dial_failed, Enum.reverse(failures)}}

  defp try_each([address | rest], port, opts, timeout, deadline, failures) do
    case attempt_timeout(timeout, deadline) do
      0 ->
        {:error, {:budget_exhausted, Enum.reverse(failures)}}

      attempt ->
        case Mint.HTTP.connect(:https, address, port, with_timeout(opts, attempt)) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, reason} ->
            try_each(rest, port, opts, timeout, deadline, [{address, reason} | failures])
        end
    end
  end

  defp deadline(opts) do
    case Keyword.get(opts, :budget_ms, :infinity) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms >= 0 -> now_ms() + ms
    end
  end

  defp attempt_timeout(timeout, :infinity), do: timeout
  defp attempt_timeout(timeout, deadline), do: min(timeout, max(deadline - now_ms(), 0))

  defp with_timeout(opts, timeout) do
    Keyword.update!(opts, :transport_opts, &Keyword.put(&1, :timeout, timeout))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A name reaching this function is a caller that skipped the vet, so it fails
  # closed rather than being resolved here as a convenience. `:inet` address
  # tuples are the only accepted shape, and the size check is what separates
  # them from any other tuple.
  #
  # `Enum.reject/2` rather than `Enum.find/2`: `nil` is a perfectly good thing
  # for a caller to pass by mistake and it is also `find/2`'s not-found
  # sentinel, so the obvious version accepted `nil` as an address and handed it
  # to `Mint.HTTP.connect/4`, which resolved it and returned `:nxdomain`.
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
