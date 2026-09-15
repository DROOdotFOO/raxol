defmodule Raxol.Web3.TTL do
  @moduledoc """
  How long each endpoint class may be cached, and why.

  ADR-0038 decision 5 deferred these values "except for the height-bearing
  routes, which decisions 5 and 7 settle together". So one entry here is a
  correctness rule and the rest are freshness judgements, and they sit in one
  table rather than at their call sites because the interesting property is the
  comparison between them.

  ## The rule that is not about freshness

  There is no height class, and `for(:height)` raises rather than answering.
  A cached height read alongside a live finalized height is what produces
  `finalized_height > height`, which is the invariant `Raxol.Web3.Backend`'s
  height shape exists to express, and a consumer computing confirmation depth
  from that pair reads a negative number. A height is also the cheapest thing
  on this surface to re-ask.

  ## The judgements

  | Class | TTL | Why |
  | ----- | --- | --- |
  | `:chain_stats` | 10 s | Aggregate counters that move every block, and nobody decides anything on them |
  | `:account` | 10 s | A balance is a decision input, so short enough to be current, long enough to absorb a burst of reads of one address |
  | `:list` | 15 s | A first page moves as blocks arrive and a later page is historical, but a cache key cannot tell them apart, so the shorter value wins |
  | `:transaction` | 2 s | Deliberately short, and this is the interesting one: a transaction is immutable once final, but nothing at the moment of the request knows whether this one IS final. Deciding a long TTL needs the finalized height in hand, which belongs to a layer that holds both numbers, not to a call that has not yet seen the body |
  | `:block` | 60 s | A block at a given number changes only in a reorg, which resolves in far less than a minute on the chains covered here |
  | `:contract_metadata` | 1 h | A verified contract's ABI does not change. What bounds this at an hour rather than a day is that a NEWLY verified contract appears |
  | `:catalog` | 1 h | A network or chain catalog changes on the order of an upstream release, and the cost of a stale entry is one refused chain reference rather than a wrong number. It shares a duration with `:contract_metadata` and not a meaning: an operator reading this table for "why is my network list stale" must find a row that says catalog |

  Every value is a judgement, not a measurement, which ADR-0038's mitigation
  list requires to be said out loud. None is derived from an upstream's stated
  cache policy, because none of these upstreams states one.
  """

  @ttls %{
    chain_stats: :timer.seconds(10),
    account: :timer.seconds(10),
    list: :timer.seconds(15),
    transaction: :timer.seconds(2),
    block: :timer.seconds(60),
    contract_metadata: :timer.hours(1),
    catalog: :timer.hours(1)
  }

  @type class ::
          :chain_stats
          | :account
          | :list
          | :transaction
          | :block
          | :contract_metadata
          | :catalog

  @doc """
  The TTL for a class, in milliseconds.

  `:height` raises, because every caller of this function is about to cache
  something and a height is the one thing that must not be. An unknown class
  raises for a related reason: a typo answered with `0` would mean "never
  expire", which is the worst available default, and answered with a miss would
  look like a cache that simply never helps.
  """
  @spec for(class()) :: pos_integer()
  def for(:height) do
    raise ArgumentError,
          "a height is never cached: a cached height beside a live finalized height " <>
            "breaks the monotonicity of Raxol.Web3.Backend's height shape"
  end

  def for(class) do
    case Map.fetch(@ttls, class) do
      {:ok, ttl} -> ttl
      :error -> raise ArgumentError, "unknown cache class: #{inspect(class)}"
    end
  end

  @doc "Every class and its TTL. Data, for a test and for an operator."
  @spec all() :: %{class() => pos_integer()}
  def all, do: @ttls
end
