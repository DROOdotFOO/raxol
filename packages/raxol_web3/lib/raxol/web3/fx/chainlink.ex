defmodule Raxol.Web3.FX.Chainlink do
  @moduledoc """
  The FX rate of record: Chainlink aggregator proxies read by `eth_call`
  (ADR-0040 decision 2).

  Every read goes through `Raxol.Web3.RPC`, and so through the guarded client.
  RPC URLs come from the caller; there is no default endpoint in this module.

  ## Feeds

  | Peg | Primary | Fallback |
  | --- | ------- | -------- |
  | EUR | Base EUR/USD, 1 h heartbeat, 0.10% | Ethereum EUR/USD, 24 h, 0.15% |
  | CHF | Ethereum CHF/USD, 24 h, 0.15% | none |
  | USD | the identity rate, exactly 1, never read | |

  Heartbeats and thresholds are Chainlink's reference-data directory values,
  read on 2026-09-30. Coarser proxies for the same pairs (0.5%) exist and are
  not used.

  ## When a rate is usable

  All of:

    * the proxy's `description()` names the expected pair and `decimals()` is
      8. A decodable answer that is wrong is `{:blocked, :feed_mismatch}` and
      is terminal: failing over would leave a misconfigured address answering
      about a pair nobody asked about. An answer that does not decode, such as
      the `"0x"` a node returns for an address with no code (an RPC URL that
      reaches the wrong chain), is `{:decode_failed, :identity}`, an ordinary
      failed read that fails over;
    * `answer > 0`;
    * `now - updatedAt <= heartbeat * 1.1`;
    * on Base, the L2 sequencer-uptime feed answers 0 and has been up for at
      least an hour, because a stopped sequencer freezes the price feed while
      its `updatedAt` still looks recent.

  A usable rate carries `precision_bps`, the feed's deviation threshold:
  between rounds an answer may sit that far from the market.
  """

  alias Raxol.Web3.RPC

  # An RPC URL often embeds a provider key (`/v2/<key>`, `?apikey=`), and the
  # handle sits in every agent tool context, so a crash report or a debug log
  # would print it whole. `:http_opts` may carry an authorization header.
  # Error terms name an origin by `Raxol.Web3.Origin` id instead.
  @derive {Inspect, except: [:rpc_urls, :http_opts]}
  defstruct rpc_urls: %{}, http_opts: [], now: nil, cache?: true

  @type t :: %__MODULE__{
          rpc_urls: %{pos_integer() => String.t()},
          http_opts: keyword(),
          now: (-> integer()) | nil,
          cache?: boolean()
        }

  @type rate :: %{
          peg: String.t(),
          rate: Decimal.t(),
          updated_at: integer() | nil,
          precision_bps: non_neg_integer(),
          source: {pos_integer(), String.t()} | :identity
        }

  @type reason ::
          :no_feed
          | :no_rpc
          | :stale
          | :sequencer_down
          | :bad_answer
          | {:blocked, :feed_mismatch}
          | term()

  @base 8453
  @ethereum 1

  @sequencers %{@base => "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433"}
  @sequencer_grace_s 3_600

  # peg -> feeds in failover order.
  @feeds %{
    "EUR" => [
      %{
        chain_id: @base,
        proxy: "0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F",
        description: "EUR / USD",
        heartbeat_s: 3_600,
        precision_bps: 10
      },
      %{
        chain_id: @ethereum,
        proxy: "0xb49f677943BC038e9857d61E7d053CaA2C1734C1",
        description: "EUR / USD",
        heartbeat_s: 86_400,
        precision_bps: 15
      }
    ],
    "CHF" => [
      %{
        chain_id: @ethereum,
        proxy: "0x449d117117838fFA61263B61dA6301AA2a88B13A",
        description: "CHF / USD",
        heartbeat_s: 86_400,
        precision_bps: 15
      }
    ]
  }

  @feed_decimals 8

  @description "0x7284e416"
  @decimals "0x313ce567"
  @latest_round_data "0xfeaf968c"

  # A feed's identity cannot change under a proxy address we chose, so a
  # MATCHING identity is cached for a day; any other answer is never cached,
  # so it is re-read and cannot outlive the misconfiguration that produced it.
  # The key is the origin (`scheme://host:port`, from `Raxol.Web3.HTTP`) plus a
  # digest of the whole RPC URL, chain id, proxy and selector. The digest is
  # what keeps one handle's verified identity from vouching for another handle
  # on the same host whose path or query reaches a different chain; it is a
  # truncated SHA-256, so a provider key in the path never enters the cache
  # key (`Raxol.Web3.Backend.Aztec` keys its prefix the same way).
  # A round is never cached: its age is the whole question.
  @identity_ttl_ms 86_400_000

  @doc """
  Build a handle. `:rpc_urls` maps chain id to an https JSON-RPC URL;
  `:http_opts` is forwarded to `Raxol.Web3.RPC`; `:now` is a zero-arity
  function returning unix seconds, for tests; `:cache` (default `true`) keeps
  a feed's identity for a day once it has matched. No I/O happens here: the
  identity is checked on the first `rate/2` that reads the feed.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      rpc_urls: Keyword.get(opts, :rpc_urls, %{}),
      http_opts: Keyword.get(opts, :http_opts, []),
      now: Keyword.get(opts, :now),
      cache?: Keyword.get(opts, :cache, true)
    }
  end

  @doc "The pegs this module can rate."
  @spec pegs() :: [String.t()]
  def pegs, do: ["USD" | Map.keys(@feeds)]

  @doc """
  The usable rate for `peg`, trying its feeds in order.

  `{:error, :no_feed}` for a peg with no feed. When every feed fails, the
  first feed's reason is returned, since it is the primary and the one an
  operator should look at, unless a feed's identity mismatched: that is
  terminal, so `{:blocked, :feed_mismatch}` is returned at once. Any other
  refusal, a vetted URL included, is an ordinary failure and loses to the
  primary's reason. A feed skipped for want of an RPC URL was never read, so
  `:no_rpc` is reported only when no feed was.
  """
  @spec rate(t(), String.t()) :: {:ok, rate()} | {:error, reason()}
  def rate(_chainlink, "USD"),
    do:
      {:ok,
       %{peg: "USD", rate: Decimal.new(1), updated_at: nil, precision_bps: 0, source: :identity}}

  def rate(%__MODULE__{} = chainlink, peg) when is_binary(peg) do
    case Map.fetch(@feeds, peg) do
      {:ok, feeds} -> first_usable(chainlink, peg, feeds, [])
      :error -> {:error, :no_feed}
    end
  end

  defp first_usable(_chainlink, _peg, [], reasons),
    do: {:error, pick_reason(Enum.reverse(reasons))}

  defp first_usable(chainlink, peg, [feed | rest], reasons) do
    case read_feed(chainlink, peg, feed) do
      {:ok, _rate} = ok -> ok
      {:error, {:blocked, :feed_mismatch}} = blocked -> blocked
      {:error, reason} -> first_usable(chainlink, peg, rest, [reason | reasons])
    end
  end

  defp pick_reason(reasons), do: Enum.find(reasons, :no_rpc, &(&1 != :no_rpc))

  defp read_feed(chainlink, peg, feed) do
    now = now(chainlink)

    with {:ok, url} <- rpc_url(chainlink, feed.chain_id),
         :ok <- identity(chainlink, url, feed),
         :ok <- sequencer(chainlink, url, feed.chain_id, now),
         {:ok, %{answer: answer, updated_at: updated_at}} <-
           latest_round(chainlink, url, feed.proxy),
         :ok <- positive(answer),
         :ok <- fresh(now, updated_at, feed.heartbeat_s) do
      {:ok,
       %{
         peg: peg,
         # `answer * 10^-8` built directly: a division would round to the
         # caller's `Decimal` context, or overflow its exponent to Infinity.
         rate: Decimal.new(1, answer, -@feed_decimals),
         updated_at: updated_at,
         precision_bps: feed.precision_bps,
         source: {feed.chain_id, feed.proxy}
       }}
    end
  end

  defp rpc_url(chainlink, chain_id) do
    case Map.fetch(chainlink.rpc_urls, chain_id) do
      {:ok, url} when is_binary(url) -> {:ok, url}
      _ -> {:error, :no_rpc}
    end
  end

  defp identity(chainlink, url, feed) do
    with {:ok, description} <- call(chainlink, url, feed, @description, :identity),
         {:ok, decimals} <- call(chainlink, url, feed, @decimals, :identity) do
      case {decode_string(description), decode_uint(decimals)} do
        {nil, _} -> {:error, {:decode_failed, :identity}}
        {_, nil} -> {:error, {:decode_failed, :identity}}
        {description, decimals} -> match_identity(description, decimals, feed)
      end
    end
  end

  defp match_identity(description, decimals, feed) do
    if description == feed.description and decimals == @feed_decimals,
      do: :ok,
      else: {:error, {:blocked, :feed_mismatch}}
  end

  # Whether an `eth_call` result is the answer this feed must give.
  defp expected?(@description, result, feed), do: decode_string(result) == feed.description
  defp expected?(@decimals, result, _feed), do: decode_uint(result) == @feed_decimals

  defp sequencer(chainlink, url, chain_id, now) do
    case Map.fetch(@sequencers, chain_id) do
      :error ->
        :ok

      {:ok, proxy} ->
        with {:ok, %{answer: status, started_at: started_at}} <-
               latest_round(chainlink, url, proxy) do
          if status == 0 and now - started_at >= @sequencer_grace_s,
            do: :ok,
            else: {:error, :sequencer_down}
        end
    end
  end

  defp latest_round(chainlink, url, proxy) do
    with {:ok, hex} <- call(chainlink, url, %{proxy: proxy}, @latest_round_data, :round) do
      decode_round(hex)
    end
  end

  defp positive(answer) when answer > 0, do: :ok
  defp positive(_answer), do: {:error, :bad_answer}

  # The margin absorbs block-inclusion delay and nothing more.
  defp fresh(now, updated_at, heartbeat_s) do
    if now - updated_at <= div(heartbeat_s * 11, 10), do: :ok, else: {:error, :stale}
  end

  defp call(chainlink, url, feed, selector, kind) do
    RPC.eth_call(
      url,
      %{to: feed.proxy, data: selector},
      "latest",
      call_opts(chainlink, kind, url, feed, selector)
    )
  end

  defp call_opts(%__MODULE__{cache?: false} = chainlink, :identity, _url, _feed, _selector),
    do: chainlink.http_opts

  defp call_opts(chainlink, :identity, url, feed, selector),
    do:
      Keyword.put(chainlink.http_opts, :cache,
        key: {:chainlink, url_digest(url), feed.chain_id, feed.proxy, selector},
        ttl_ms: @identity_ttl_ms,
        cacheable: &expected_response?(&1, selector, feed)
      )

  defp call_opts(chainlink, :round, _url, _feed, _selector), do: chainlink.http_opts

  # Distinguishes two URLs and carries nothing back.
  defp url_digest(url) do
    :crypto.hash(:sha256, url)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp expected_response?(%{body: body}, selector, feed) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} -> expected?(selector, result, feed)
      _ -> false
    end
  end

  defp now(%__MODULE__{now: nil}), do: System.os_time(:second)
  defp now(%__MODULE__{now: now}), do: now.()

  # -- ABI -----------------------------------------------------------------------

  @doc false
  # `latestRoundData()` returns five 32-byte words: roundId, answer (int256),
  # startedAt, updatedAt, answeredInRound.
  def decode_round("0x" <> hex) when byte_size(hex) >= 320 do
    case Base.decode16(binary_part(hex, 0, 320), case: :mixed) do
      {:ok, <<_round::256, answer::signed-256, started::256, updated::256, _answered::256>>} ->
        {:ok, %{answer: answer, started_at: started, updated_at: updated}}

      _ ->
        {:error, {:decode_failed, :latest_round_data}}
    end
  end

  def decode_round(_), do: {:error, {:decode_failed, :latest_round_data}}

  defp decode_uint("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp decode_uint(_), do: nil

  # An ABI-encoded `string`: offset word, length word, then the bytes.
  defp decode_string("0x" <> hex) do
    with {:ok, <<_offset::256, length::256, rest::binary>>} <- Base.decode16(hex, case: :mixed),
         true <- byte_size(rest) >= length do
      binary_part(rest, 0, length)
    else
      _ -> nil
    end
  end

  defp decode_string(_), do: nil
end
