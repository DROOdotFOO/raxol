defmodule Raxol.Core.Outbound do
  @moduledoc """
  The outbound target policy: vet a URL before anything opens a socket to it.

  Anything in this repository that reaches a host the caller (or a model, or a
  config file in a cloned workspace) had a say in goes through `vet/2` first.
  Two of the five rules the policy states live here, because they need `:inet`
  and nothing else:

  1. The scheme is allowed. `:schemes` defaults to `[:https]`; a caller that
     documents `http` support passes it explicitly.
  2. Every resolved address is outside the reject set. Both families are
     resolved, and the whole request is refused if ANY answer is rejected,
     rather than the first: a host with one public and one loopback record must
     not be reachable by luck of resolver ordering.

  The third rule is the caller's, and this module is what makes it possible:
  `vet/2` returns the addresses it checked, and those are the addresses the
  caller MUST dial. Validating a hostname and then handing that hostname to an
  HTTP client re-resolves it and reopens the window a changed DNS record walks
  through. A caller that ignores `:addresses` and dials `:uri` has the same
  rebinding gap it had before calling.

  Rules 4 (no redirect following) and 5 (bounded time, size and concurrency)
  belong to whoever owns the request, since neither is expressible here.

  ## The address list, and why it is a list

  `:addresses` carries every vetted answer, in resolution order (A records
  first, then AAAA), so a caller can try them in turn the way `:gen_tcp` does
  when it is handed a name. Collapsing to one address would trade the rebinding
  fix for a loss of multi-address failover, which matters most against exactly
  the anycast hosts this is used for. Duplicates are not removed: a repeated
  answer costs a repeated attempt, and filtering it would be the only place in
  this module that rewrites what the resolver said.

  ## The reject set

  `blocked?/1` is the policy, and it is a predicate over `:inet` address
  tuples rather than over strings, so a literal in a URL and a resolver answer
  are judged by the same code. It refuses loopback, link-local, private,
  carrier-grade NAT, unspecified, multicast and reserved ranges, and every form
  that smuggles a v4 address through a v6 literal: IPv4-mapped,
  IPv4-compatible, IPv4-translated, NAT64 (both the /96 and the RFC 8215
  local-use prefix) and 6to4, which carries the address in a different pair of
  groups than the rest. Teredo is refused outright rather than decomposed,
  since it obfuscates the addresses it tunnels. Anything that is not an address
  tuple is refused, so a malformed answer fails closed.

  ## Injecting a resolver

  `:resolver` replaces `:inet.getaddrs/2` with any
  `(charlist, :inet | :inet6 -> {:ok, [address]} | {:error, term})`. That is
  the seam a resolver which changes its answer between calls is tested through,
  which is the test rule 3 exists for and which cannot be written against the
  real resolver. An IP literal never reaches the resolver at all, injected or
  not, so skipping DNS skips no part of the check.
  """

  @type address :: :inet.ip_address()

  @type vetted :: %{
          uri: URI.t(),
          addresses: [address()],
          hostname: String.t()
        }

  @type resolver :: (charlist(), :inet | :inet6 -> {:ok, [address()]} | {:error, term()})

  @type reason ::
          :invalid_url
          | {:blocked_address, String.t()}
          | {:dns_failed, String.t()}

  @default_schemes [:https]

  @doc """
  Vet a URL: `{:ok, vetted}` or `{:error, reason}`.

  `:hostname` is the host with any IPv6 brackets removed, which is the form
  SNI, a certificate match and a `Host` header want. `:uri` is the parsed URL,
  unmodified.

  Options:

    * `:schemes` - allowed schemes as atoms, default `[:https]`
    * `:resolver` - a `t:resolver/0`, default `&:inet.getaddrs/2`

  """
  @spec vet(String.t(), keyword()) :: {:ok, vetted()} | {:error, reason()}
  def vet(url, opts \\ [])

  def vet(url, opts) when is_binary(url) and is_list(opts) do
    schemes = opts |> Keyword.get(:schemes, @default_schemes) |> Enum.map(&to_string/1)

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(host) and host != "" ->
        if scheme in schemes,
          do: vet_host(uri, unbracket(host), resolver(opts)),
          else: {:error, :invalid_url}

      _other ->
        {:error, :invalid_url}
    end
  end

  def vet(_url, _opts), do: {:error, :invalid_url}

  defp vet_host(%URI{host: host} = uri, hostname, resolver) do
    case resolve(hostname, resolver) do
      {:ok, addresses} ->
        if Enum.any?(addresses, &blocked?/1),
          do: {:error, {:blocked_address, host}},
          else: {:ok, %{uri: uri, addresses: addresses, hostname: hostname}}

      :error ->
        {:error, {:dns_failed, host}}
    end
  end

  @doc """
  Resolve a host to every address it answers with: `{:ok, addresses}` or `:error`.

  An IP literal never reaches the resolver; a name is resolved over BOTH
  families, because a host with only an AAAA record must not pass by an empty A
  lookup. No address is judged here, so a caller reaching for this instead of
  `vet/2` is opting out of the policy.
  """
  @spec resolve(String.t(), resolver()) :: {:ok, [address()]} | :error
  def resolve(host, resolver \\ &:inet.getaddrs/2) when is_binary(host) do
    charlist = host |> unbracket() |> String.to_charlist()

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        case getaddrs(resolver, charlist, :inet) ++ getaddrs(resolver, charlist, :inet6) do
          [] -> :error
          addresses -> {:ok, addresses}
        end
    end
  end

  defp resolver(opts) do
    case Keyword.get(opts, :resolver) do
      fun when is_function(fun, 2) -> fun
      _absent -> &:inet.getaddrs/2
    end
  end

  defp getaddrs(resolver, charlist, family) do
    case resolver.(charlist, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

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
  # Multicast (224/4) through reserved and broadcast (240/4).
  def blocked?({a, _b, _c, _d}) when a >= 224, do: true
  def blocked?({_a, _b, _c, _d}), do: false

  def blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  def blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # Every way a v4 address hides inside a v6 one. Each is decomposed and judged
  # as the v4 address it carries, so `http://[::ffff:169.254.169.254]/` cannot
  # walk past the v4 clauses above.
  #
  # ::ffff:a.b.c.d (IPv4-mapped) and ::a.b.c.d (IPv4-compatible).
  def blocked?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: blocked?(v4_from(hi, lo))
  def blocked?({0, 0, 0, 0, 0, 0, hi, lo}), do: blocked?(v4_from(hi, lo))

  # ::ffff:0:a.b.c.d (IPv4-translated, RFC 2765). A different prefix from
  # IPv4-mapped, so it needs its own clause or it falls through to the generic
  # one below and is allowed.
  def blocked?({0, 0, 0, 0, 0xFFFF, 0, hi, lo}), do: blocked?(v4_from(hi, lo))

  # 64:ff9b::/96 (NAT64, RFC 6052) and 64:ff9b:1::/48 (local-use, RFC 8215).
  # The local-use form carries a nonzero third group, which the /96 pattern
  # pins to 0, so it too needs the wider clause.
  def blocked?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: blocked?(v4_from(hi, lo))
  def blocked?({0x64, 0xFF9B, _u, _v, _w, _x, hi, lo}), do: blocked?(v4_from(hi, lo))

  # 2002::/16 (6to4, RFC 3056) embeds the v4 address in the SECOND and THIRD
  # groups, so `2002:a9fe:a9fe::` is a route to 169.254.169.254 and
  # `2002:7f00:1::` one to 127.0.0.1. Neither matches anything above.
  def blocked?({0x2002, hi, lo, _d, _e, _f, _g, _h}), do: blocked?(v4_from(hi, lo))

  def blocked?({a, b, _c, _d, _e, _f, _g, _h}) do
    # fc00::/7 unique-local, fe80::/10 link-local, ff00::/8 multicast,
    # 2001:0::/32 Teredo (a v4 tunnel whose server and client addresses are
    # obfuscated rather than plainly embedded, so it is refused outright
    # instead of decomposed).
    Bitwise.band(a, 0xFE00) == 0xFC00 or
      Bitwise.band(a, 0xFFC0) == 0xFE80 or
      Bitwise.band(a, 0xFF00) == 0xFF00 or
      (a == 0x2001 and b == 0)
  end

  # Anything that is not an address tuple is not something to connect to.
  def blocked?(_other), do: true

  defp v4_from(hi, lo) do
    {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
  end
end
