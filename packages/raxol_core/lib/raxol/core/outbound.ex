defmodule Raxol.Core.Outbound do
  @moduledoc """
  The outbound target policy: vet a URL before anything opens a socket to it.

  Anything in this repository that reaches a host the caller (or a model, or a
  config file in a cloned workspace) had a say in goes through `vet/2` first.
  Two of the five rules the policy states live here, because they need `:inet`
  and nothing else:

  1. The scheme and the port are allowed. `:schemes` defaults to `[:https]`
     and `:ports` to the ports an HTTP server listens on; a caller that
     documents `http`, or a fixed non-standard port, passes it explicitly.
     Without the port rule a vetted target is still an arbitrary-port prober
     against public hosts, because every other rule here judges the ADDRESS
     and none of them reads the port the caller is about to dial.
  2. Every resolved address is outside the reject set. Both families are
     resolved, and the whole request is refused if ANY answer is rejected,
     rather than the first: a host with one public and one loopback record must
     not be reachable by luck of resolver ordering. A lookup that FAILED is not
     an empty answer: a nameserver that SERVFAILs the A query while answering
     AAAA would otherwise choose which half of its own records was vetted, so a
     partial failure refuses the whole request.

  The third rule is the caller's, and this module is what makes it possible:
  `vet/2` returns the addresses it checked, and those are the addresses the
  caller MUST dial. Validating a hostname and then handing that hostname to an
  HTTP client re-resolves it and reopens the window a changed DNS record walks
  through. A caller that ignores `:addresses` and dials `:uri` has the same
  rebinding gap it had before calling.

  Rules 4 (no redirect following) and 5 (bounded time, size and concurrency)
  belong to whoever owns the request, since neither is expressible here.

  ## The address list, and why it is bounded

  `:addresses` carries the vetted answers, deduplicated, interleaved by family
  and capped at 8. A caller tries them in turn the way `:gen_tcp` does when it
  is handed a name, which is the failover pinning would otherwise lose.

  Everything the resolver said is CHECKED; only the dial list is bounded, so
  padding an RRset cannot walk a blocked address past the check by putting it
  beyond the cap. The cap is there because `Raxol.Web3.Dial` gives EACH address
  the full connect timeout (5000ms by default) in turn, so an uncapped list is
  a multiplier a hostile authoritative nameserver controls: 64 padded answers
  is 320 seconds of serial connects behind one call. Duplicates buy a repeated
  attempt against the same dead socket, so they go too. Interleaving is what
  makes the cap safe rather than a v6 outage: A-then-AAAA concatenated and cut
  at 8 drops every AAAA answer for a host with 8 or more A records.

  ## The reject set

  `blocked?/1` is the policy, and it is a predicate over `:inet` address
  tuples rather than over strings, so a literal in a URL and a resolver answer
  are judged by the same code. It refuses loopback, link-local, private,
  carrier-grade NAT, unspecified, multicast and reserved ranges, the blocks
  that exist only on paper (IETF protocol assignments, the v4 and v6
  documentation ranges, benchmarking, discard-only) and the 6to4 relay
  anycast address, plus every form that smuggles a v4 address through a v6
  literal: IPv4-mapped, IPv4-compatible, IPv4-translated, NAT64 (the /96 and
  the RFC 8215 local-use prefix share one clause) and 6to4, which carries the
  address in a different pair of groups than the rest. Teredo is refused
  outright rather than decomposed, since it obfuscates the addresses it
  tunnels. Anything that is not an address tuple is refused, so a malformed
  answer fails closed.

  The generic IPv6 clause is LAST, and the order is load-bearing rather than
  tidy: it answers `false` for 6to4, NAT64 and every other prefix that embeds
  or reserves an address, so moving it above them makes `2002:a9fe:a9fe::` —
  a working route to the cloud metadata address — reachable, silently.

  ## Injecting a resolver

  `:resolver` replaces `:inet.getaddrs/3` with any
  `(charlist, :inet | :inet6, timeout -> {:ok, [address]} | {:error, term})`,
  or the 2-arity form for a resolver that answers from a literal and needs no
  budget. That is the seam a resolver which changes its answer between calls
  is tested through, which is the test rule 3 exists for and which cannot be
  written against the real resolver. An IP literal never reaches the resolver
  at all, injected or not, so skipping DNS skips no part of the check.
  """

  @type address :: :inet.ip_address()

  @type vetted :: %{
          uri: URI.t(),
          addresses: [address()],
          hostname: String.t()
        }

  @type resolver ::
          (charlist(), :inet | :inet6 -> {:ok, [address()]} | {:error, term()})
          | (charlist(), :inet | :inet6, timeout() ->
               {:ok, [address()]} | {:error, term()})

  @typedoc """
  Why resolution produced no vetted address.

  `:nxdomain` is an answer: the name has no address in either family.
  `{:lookup_failed, reason}` is the absence of one, and the two are not
  interchangeable — a breaker that quarantines an origin for a nonexistent
  host should not quarantine it for a resolver hiccup.
  """
  @type dns_reason :: :nxdomain | {:lookup_failed, term()}

  # The `{:dns_failed, _}` payload is a PAIR rather than a third tuple element
  # because `Raxol.Web3.HTTP.vet_error/3` and `Raxol.MCP.Client.Transport.Http`
  # both enumerate this taxonomy clause by clause, so a three-element shape is
  # a FunctionClauseError in each rather than a reason they ignore.
  @type reason ::
          :invalid_url
          | {:blocked_address, String.t()}
          | {:dns_failed, {String.t(), dns_reason()}}

  @default_schemes [:https]

  # The reject set already removes every private destination, so what is left
  # to close is the tool being used as a port prober against PUBLIC hosts:
  # `https://example.com:22/` resolves to a public address and passes every
  # address rule, after which the connect result reports whether 22 is open.
  # `Raxol.Agent.Actions.Fetch`'s port is model-chosen, so the answer is the
  # ports that speak HTTP; a caller with a documented non-standard port passes
  # `:ports` the way it passes `:schemes`.
  @default_ports [80, 443, 8080, 8443]

  # Eight is above what any host this repository targets answers with (the
  # measurement in `Raxol.Web3.Dial`'s moduledoc is three) and below the point
  # where a serial dial through the list outlives a caller's deadline.
  @max_addresses 8

  # `:inet.getaddrs/2` is `getaddrs(Host, Family, infinity)` (kernel
  # `inet.erl`), so the only bound on a lookup is the native resolver's own
  # `res_option(timeout) * 4`, about eight seconds per family. A caller that
  # owns an end-to-end deadline cannot express it through that, so resolution
  # takes a budget of its own and the default is a bound rather than a hope.
  @default_resolve_timeout_ms 5_000

  @doc """
  Vet a URL: `{:ok, vetted}` or `{:error, reason}`.

  `:hostname` is the host with any IPv6 brackets removed, which is the form
  SNI, a certificate match and a `Host` header want. `:uri` is the parsed URL,
  unmodified.

    * `:schemes` - allowed schemes as atoms, default `[:https]`
    * `:ports` - allowed ports, default `[80, 443, 8080, 8443]`. A port outside
      it is refused as `:invalid_url`, the same answer an unallowed scheme
      gets, because it is the same answer to a caller: not a target we dial.
    * `:resolver` - a `t:resolver/0`, default `&:inet.getaddrs/3`
    * `:timeout_ms` - the total budget for resolution, default `5000`. Both
      families are looked up under it: the second gets whatever the first left,
      so the whole of `vet/2` returns within it plus the URL parse.
  """
  @spec vet(String.t(), keyword()) :: {:ok, vetted()} | {:error, reason()}
  def vet(url, opts \\ [])

  def vet(url, opts) when is_binary(url) and is_list(opts) do
    schemes = opts |> Keyword.get(:schemes, @default_schemes) |> Enum.map(&to_string/1)
    ports = Keyword.get(opts, :ports, @default_ports)

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port} = uri}
      when is_binary(host) and host != "" ->
        if scheme in schemes and port in ports,
          do: vet_host(uri, unbracket(host), resolver(opts), timeout_ms(opts)),
          else: {:error, :invalid_url}

      _other ->
        {:error, :invalid_url}
    end
  end

  def vet(_url, _opts), do: {:error, :invalid_url}

  defp vet_host(%URI{host: host} = uri, hostname, resolver, timeout_ms) do
    case resolve(hostname, resolver, timeout_ms: timeout_ms) do
      {:ok, addresses} ->
        # The reject check runs over EVERY answer and the cap applies after it,
        # in this order: capping first would let a padded RRset carry a blocked
        # address that is never checked because it is never dialled either,
        # which is a weaker policy than the one this module states.
        if Enum.any?(addresses, &blocked?/1),
          do: {:error, {:blocked_address, host}},
          else: {:ok, %{uri: uri, addresses: dial_list(addresses), hostname: hostname}}

      {:error, reason} ->
        {:error, {:dns_failed, {host, reason}}}
    end
  end

  # Only 4- and 8-tuples reach here: `blocked?/1` refuses everything else, so
  # `tuple_size/1` is a family test rather than a shape check.
  defp dial_list(addresses) do
    {v4, v6} = Enum.split_with(addresses, &(tuple_size(&1) == 4))

    v4
    |> Enum.uniq()
    |> interleave(Enum.uniq(v6))
    |> Enum.take(@max_addresses)
  end

  defp interleave([], v6), do: v6
  defp interleave(v4, []), do: v4
  defp interleave([a | v4], [b | v6]), do: [a, b | interleave(v4, v6)]

  @doc """
  Resolve a host to every address it answers with: `{:ok, addresses}` or
  `{:error, reason}`.

  An IP literal never reaches the resolver; a name is resolved over BOTH
  families, because a host with only an AAAA record must not pass by an empty A
  lookup. No address is judged here, and nothing is deduplicated or capped: a
  caller reaching for this instead of `vet/2` is opting out of the policy and
  gets exactly what the resolver said.

  A family whose lookup FAILED is not a family with no records, and the failure
  wins over the family that answered. See `t:dns_reason/0`.

  `:timeout_ms` is the budget for the whole call, default `5000`. It is a
  deadline rather than a per-family timeout: the AAAA lookup is given whatever
  the A lookup left, so two slow families cost one budget and not two.
  """
  @spec resolve(String.t(), resolver(), keyword()) ::
          {:ok, [address()]} | {:error, dns_reason()}
  def resolve(host, resolver \\ &:inet.getaddrs/3, opts \\ []) when is_binary(host) do
    charlist = host |> unbracket() |> String.to_charlist()

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        deadline = now_ms() + timeout_ms(opts)

        # Sequenced rather than written as one `++` expression, because the
        # second lookup's budget is what the first one left and that is only
        # true if the two are evaluated in this order.
        v4 = getaddrs(resolver, charlist, :inet, remaining(deadline))
        v6 = getaddrs(resolver, charlist, :inet6, remaining(deadline))

        combine(v4, v6)
    end
  end

  # Fail closed on a partial failure. Mapping an error to `[]` made
  # `{:ok, [v4]}` plus a v6 lookup that SERVFAILed byte-identical to a host
  # with no AAAA record, so a nameserver that answers one family and breaks the
  # other decided which half of its records the policy got to see, and the
  # caller could not tell a transient resolver failure from a host that does
  # not exist.
  defp combine({:error, reason}, _v6), do: {:error, {:lookup_failed, reason}}
  defp combine(_v4, {:error, reason}), do: {:error, {:lookup_failed, reason}}
  defp combine({:ok, []}, {:ok, []}), do: {:error, :nxdomain}
  defp combine({:ok, v4}, {:ok, v6}), do: {:ok, v4 ++ v6}

  defp resolver(opts) do
    case Keyword.get(opts, :resolver) do
      fun when is_function(fun, 2) or is_function(fun, 3) -> fun
      _absent -> &:inet.getaddrs/3
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_resolve_timeout_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _absent_or_nonsense -> @default_resolve_timeout_ms
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp remaining(deadline), do: max(deadline - now_ms(), 0)

  # `:inet.getaddrs/3` answers `{:error, :nxdomain}` for a family a host simply
  # has no record in — a v4-only host's AAAA lookup is the ordinary case, not a
  # failure — so `:nxdomain` is "no record here" and every other reason is a
  # lookup that did not happen. Erlang's resolver reports the rest (`:timeout`,
  # `:servfail`, `:refused`, `:formerr`) distinctly, which is what makes the
  # split possible at all.
  defp getaddrs(resolver, charlist, family, timeout) do
    case call_resolver(resolver, charlist, family, timeout) do
      {:ok, addresses} -> {:ok, addresses}
      {:error, :nxdomain} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # A 3-arity resolver is handed the remaining budget, which is how the real
  # one is bounded. The 2-arity form is the original seam and bounds itself:
  # every injected resolver in this repository answers from a literal, so
  # there is nothing there to bound.
  defp call_resolver(resolver, charlist, family, timeout) when is_function(resolver, 3),
    do: resolver.(charlist, family, timeout)

  defp call_resolver(resolver, charlist, family, _timeout) when is_function(resolver, 2),
    do: resolver.(charlist, family)

  defp unbracket(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end

  @doc """
  Whether an `:inet` address tuple is outside the public internet.

  Public because this predicate is the policy, and is tested directly.
  """
  @spec blocked?(address() | term()) :: boolean()
  def blocked?({0, _b, _c, _d}), do: true
  def blocked?({10, _b, _c, _d}), do: true
  def blocked?({127, _b, _c, _d}), do: true
  def blocked?({169, 254, _c, _d}), do: true
  def blocked?({172, b, _c, _d}) when b in 16..31, do: true
  def blocked?({192, 168, _c, _d}), do: true
  def blocked?({100, b, _c, _d}) when b in 64..127, do: true

  # Ranges that look routable and never carry a host on the public internet:
  # IETF protocol assignments (192.0.0.0/24), the three documentation blocks
  # (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), benchmarking
  # (198.18.0.0/15) and the 6to4 RELAY anycast address (192.88.99.0/24), which
  # is the v4 half of the `2002::/16` clause below: reaching a relay is how a
  # v4-only host is handed a 6to4 route in the first place.
  def blocked?({192, 0, 0, _d}), do: true
  def blocked?({192, 0, 2, _d}), do: true
  def blocked?({198, 51, 100, _d}), do: true
  def blocked?({203, 0, 113, _d}), do: true
  def blocked?({198, b, _c, _d}) when b in 18..19, do: true
  def blocked?({192, 88, 99, _d}), do: true

  # Multicast (224/4) through reserved and broadcast (240/4).
  def blocked?({a, _b, _c, _d}) when a >= 224, do: true
  def blocked?({_a, _b, _c, _d}), do: false

  # Every way a v4 address hides inside a v6 one. Each is decomposed and judged
  # as the v4 address it carries, so `http://[::ffff:169.254.169.254]/` cannot
  # walk past the v4 clauses above.
  #
  # `::` and `::1` have no clause of their own: both are
  # `{0, 0, 0, 0, 0, 0, hi, lo}`, which decomposes to 0.0.0.0 and 0.0.0.1, and
  # 0.0.0.0/8 is refused above. A row that can never be reached makes a policy
  # table look more thorough than it is.
  #
  # ::ffff:a.b.c.d (IPv4-mapped) and ::a.b.c.d (IPv4-compatible).
  def blocked?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: blocked?(v4_from(hi, lo))
  def blocked?({0, 0, 0, 0, 0, 0, hi, lo}), do: blocked?(v4_from(hi, lo))

  # ::ffff:0:a.b.c.d (IPv4-translated, RFC 2765). A different prefix from
  # IPv4-mapped, so it needs its own clause or it falls through to the generic
  # one below and is allowed.
  def blocked?({0, 0, 0, 0, 0xFFFF, 0, hi, lo}), do: blocked?(v4_from(hi, lo))

  # 64:ff9b::/96 (NAT64, RFC 6052) and 64:ff9b:1::/48 (local-use, RFC 8215).
  # One clause for both: the /96 form is this prefix with the middle groups
  # zero, so a pattern pinning them to 0 matched nothing this does not.
  def blocked?({0x64, 0xFF9B, _u, _v, _w, _x, hi, lo}), do: blocked?(v4_from(hi, lo))

  # 2002::/16 (6to4, RFC 3056) embeds the v4 address in the SECOND and THIRD
  # groups, so `2002:a9fe:a9fe::` is a route to 169.254.169.254 and
  # `2002:7f00:1::` one to 127.0.0.1. Neither matches anything above.
  def blocked?({0x2002, hi, lo, _d, _e, _f, _g, _h}), do: blocked?(v4_from(hi, lo))

  # 100::/64 (discard-only, RFC 6666), 2001:2::/48 (benchmarking, RFC 5180) and
  # 2001:db8::/32 (documentation, RFC 3849). The generic clause below answers
  # `false` for all three — none is fc00/fe80/fec0/ff00 and only Teredo's
  # `2001:0::/32` is carved out of 2001::/16 — so each needs a row here, ABOVE
  # it.
  def blocked?({0x100, 0, 0, 0, _e, _f, _g, _h}), do: true
  def blocked?({0x2001, 0x2, 0, _d, _e, _f, _g, _h}), do: true
  def blocked?({0x2001, 0xDB8, _c, _d, _e, _f, _g, _h}), do: true

  def blocked?({a, b, _c, _d, _e, _f, _g, _h}) do
    # fc00::/7 unique-local, fe80::/10 link-local, fec0::/10 site-local,
    # ff00::/8 multicast, 2001:0::/32 Teredo (a v4 tunnel whose server and
    # client addresses are obfuscated rather than plainly embedded, so it is
    # refused outright instead of decomposed).
    #
    # fec0::/10 is deprecated (RFC 3879) and no resolver this repository
    # reaches should answer with one, which is why it is here: defence in
    # depth against a resolver that does, not a range anything is known to
    # return.
    Bitwise.band(a, 0xFE00) == 0xFC00 or
      Bitwise.band(a, 0xFFC0) == 0xFE80 or
      Bitwise.band(a, 0xFFC0) == 0xFEC0 or
      Bitwise.band(a, 0xFF00) == 0xFF00 or
      (a == 0x2001 and b == 0)
  end

  # Anything that is not an address tuple is not something to connect to.
  def blocked?(_other), do: true

  defp v4_from(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end
end
