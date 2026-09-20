defmodule Raxol.Web3.Router do
  @moduledoc """
  Resolves a chain reference and a callback to a backend, in health order, with
  failover.

  ADR-0033 decision 3's last paragraph. No single indexer is load-bearing: each
  chain has a primary and at least one fallback, and the router is what makes
  that true at call time rather than in a table.

  ## It consumes the health gate, it does not re-implement it

  ADR-0033 requires per-backend health to be gated by
  `Raxol.MCP.CircuitBreaker`, unconditionally, so that no build of this package
  retries a hard-down primary on every call. That gate lives in
  `Raxol.Web3.HTTP`, which refuses a request to an open origin before a socket
  is opened and records every outcome against it. This module reads the same
  verdict through `Backend.health_key/1` to order candidates, and never writes
  it: a router that recorded failures too would count one bad response twice
  and open a breaker at half the configured threshold.

  An open breaker demotes a backend to last, it does not remove it. If every
  candidate is open, the alternative to trying one is answering nothing, and a
  stale breaker is a worse reason to fail than a live upstream.

  ## Per callback, not per backend

  A backend is a candidate for a call only if it declares and exports that
  callback (`Backend.supports?/2`), so the fallback chain for `get_logs` can be
  shorter than the one for `chain_info` on the same chain. `coverage/2` reports
  what is answerable right now, which is the question an operator actually has
  when an upstream starts serving challenge pages: not "is the router up" but
  "which of the fourteen callbacks still have a healthy source".

  ## Which errors fail over, and which are final

  This is the router's real content, and getting it backwards is how a router
  turns one upstream's bad minute into a wrong answer.

  Failing over is right when the error describes the SOURCE: an open breaker, a
  transport failure, a timeout, a DNS failure, a rate-limit refusal (a
  different origin has a different budget), a status that says the upstream is
  unwell, a body that would not decode, a response too large to accept (another
  source may answer the same question smaller), and two refusals that arrive
  inside a 200 rather than as a status:

    * `{:upstream_refused, :auth}` and `{:upstream_refused, :rate_limit}`. A
      credential this deployment does not hold is a fact about the source, and
      ADR-0033's coverage matrix is built on failing from a key-gated explorer
      to a keyless path. This one cannot be reached through health instead: an
      upstream that answers 404 for every path under a withdrawn key prefix
      records a breaker SUCCESS, because a definitive answer about a missing
      thing is a healthy upstream, so only the classification can move it on.
    * `{:unsupported_chain, _}`, which means "this source does not serve this
      chain" rather than "this source cannot answer this question". A sibling
      that does serve it is the clearest failover case there is. It is decided
      on a read rather than in a constructor because one upstream's network set
      is resolved at runtime (its own documentation disagrees with itself about
      coverage), so a handle can declare a chain and then learn otherwise.
    * `{:source_unavailable, _}`, which means the source went away under us:
      an endpoint it is supposed to serve unconditionally is not there. It is
      distinct from `:auth` because no credential fixes it, and distinct from
      a status because the upstream answered a perfectly healthy 404.

  Failing over is wrong when the error describes the QUESTION, because asking
  the same question of another source gets the same answer and hides the first:
  `{:upstream_refused, :not_found}`, `{:upstream_refused, :unknown}` (a refusal
  we could not classify is not evidence that another source would do better),
  `{:unsupported_account_ref, _}`, `{:unsupported, _}`, `{:blocked,
  :invalid_url}` and, load-bearingly, `{:invalid_cursor, _}`.

  ## A paging walk is pinned to the backend that started it

  A cursor carries the origin that minted it (`Raxol.Web3.Cursor`), so it
  cannot be replayed against another backend. That makes `{:invalid_cursor, _}`
  terminal here rather than a reason to try the next candidate, and the
  alternative is the bug this rule exists to prevent: failing over mid-walk
  would hand the second backend no usable cursor, it would answer with its
  FIRST page, and the caller would receive page one labelled as page two. A
  caller whose walk is interrupted gets an error and can restart the walk,
  which is recoverable; silently rewinding a paginated read is not.
  """

  require Logger

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Tables

  @enforce_keys [:chains]
  defstruct chains: %{}, breaker: []

  @type t :: %__MODULE__{
          chains: %{Backend.chain_ref() => [Backend.t()]},
          breaker: keyword()
        }

  @doc """
  Build a router from an ordered list of handles.

  Declaration order is preference order, per chain: the first handle that
  declares a chain is that chain's primary. A handle that declares several
  chains takes its place in each of their orders.

  `:breaker` is forwarded to `Raxol.MCP.CircuitBreaker.check/3`, so a
  deployment can widen the recovery window without touching the outbound path.
  """
  @spec new([Backend.t()], keyword()) :: t()
  def new(handles, opts \\ []) when is_list(handles) do
    %__MODULE__{chains: index(handles), breaker: Keyword.get(opts, :breaker, [])}
  end

  # Prepend then reverse, rather than append: declaration order is the whole
  # meaning of this list, so it is restored once at the end instead of being
  # rebuilt per handle.
  defp index(handles) do
    handles
    |> Enum.reduce(%{}, fn {module, state} = handle, acc ->
      Enum.reduce(module.supported_chain_ids(state), acc, fn chain_ref, acc ->
        Map.update(acc, chain_ref, [handle], &[handle | &1])
      end)
    end)
    |> Map.new(fn {chain_ref, for_chain} -> {chain_ref, Enum.reverse(for_chain)} end)
  end

  @doc "The chains this router can route, in no particular order."
  @spec chains(t()) :: [Backend.chain_ref()]
  def chains(%__MODULE__{chains: chains}), do: Map.keys(chains)

  @doc """
  The candidates for one callback on one chain, healthy first.

  Exposed because "why did that go to the fallback" is a question an operator
  asks, and answering it by reading the router's source is worse than asking
  the router.
  """
  @spec candidates(t(), Backend.chain_ref(), atom()) :: [Backend.t()]
  def candidates(%__MODULE__{} = router, chain_ref, callback) do
    router.chains
    |> Map.get(chain_ref, [])
    |> Enum.filter(&answers?(&1, callback))
    |> order_by_health(router.breaker)
  end

  @doc """
  What is answerable on a chain right now.

  A callback maps to the backends that declare it and are not open-breakered,
  in preference order. A callback absent from the map has no healthy source at
  this moment, which is the degradation ADR-0038 leaves open as a question and
  which is otherwise invisible until a caller gets an error.
  """
  @spec coverage(t(), Backend.chain_ref()) :: %{optional(atom()) => [atom()]}
  def coverage(%__MODULE__{} = router, chain_ref) do
    handles = Map.get(router.chains, chain_ref, [])

    for callback <- callbacks(),
        healthy = healthy_backends(handles, callback, router.breaker),
        healthy != [],
        into: %{} do
      {callback, healthy}
    end
  end

  @doc """
  Call a callback on the first candidate that can answer it.

  `{:error, :no_backend}` when the chain is not routed at all, and
  `{:error, {:unsupported, callback}}` when it is routed but nothing on it
  answers that callback: two different operator problems, so two different
  errors.
  """
  @spec call(t(), Backend.chain_ref(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(%__MODULE__{} = router, chain_ref, callback, args \\ []) do
    case Map.get(router.chains, chain_ref) do
      nil -> {:error, :no_backend}
      _handles -> attempt(candidates(router, chain_ref, callback), callback, args)
    end
  end

  defp attempt([], callback, _args), do: {:error, {:unsupported, callback}}

  defp attempt([handle | rest], callback, args) do
    case Backend.call(handle, callback, args) do
      {:ok, _value} = ok ->
        ok

      {:error, reason} = error ->
        if rest != [] and failover?(reason) do
          log_failover(handle, callback, reason)
          attempt(rest, callback, args)
        else
          error
        end
    end
  end

  # The reason, never the response: a failover decision is made from the error
  # tuple, which by construction carries no upstream text and names an origin
  # only by id.
  defp log_failover(handle, callback, reason) do
    Logger.debug(fn ->
      "raxol_web3: #{Backend.name(handle)} failed #{callback} (#{inspect(reason)}), failing over"
    end)
  end

  @source_errors [
    :breaker_open,
    :transport,
    :timeout,
    :dns_failed,
    :rate_limited,
    :too_large,
    :decode_failed,
    :unsupported_chain,
    :source_unavailable
  ]

  defp failover?({kind, _detail}) when kind in @source_errors, do: true
  # Only these two of the four refusal classes: a not-found is an answer about
  # the question, and a refusal we could not classify is not evidence that
  # another source would do better.
  defp failover?({:upstream_refused, class}), do: class in [:auth, :rate_limit]
  # The status policy is `Raxol.Web3.HTTP`'s, not a second copy of it: the
  # statuses that record a breaker failure there are the statuses worth
  # failing over from here, and two lists drift.
  defp failover?({:http, status}), do: HTTP.unhealthy_status?(status)
  defp failover?({:blocked, :address}), do: true
  defp failover?(_question), do: false

  defp answers?(handle, callback) do
    Keyword.has_key?(Backend.required(), callback) or Backend.supports?(handle, callback)
  end

  # `Backend.name/1`, not `module.backend()`: one module can carry several
  # upstreams (the Tron backend has three), and a coverage map reading
  # `[:tron, :tron, :tron]` tells an operator how many sources survive but not
  # which one dropped out, which is the whole question.
  defp healthy_backends(handles, callback, breaker_opts) do
    for handle <- handles,
        answers?(handle, callback),
        health(handle, breaker_opts) != :open,
        do: Backend.name(handle)
  end

  # A stable partition rather than a sort: within a health class, declaration
  # order is the operator's stated preference and must survive.
  defp order_by_health(handles, breaker_opts) do
    {healthy, open} = Enum.split_with(handles, &(health(&1, breaker_opts) != :open))
    healthy ++ open
  end

  defp health(handle, breaker_opts) do
    case Backend.health_key(handle) do
      nil -> :closed
      key -> CircuitBreaker.check(Tables.breakers(), key, breaker_opts)
    end
  end

  # Every callback, so `coverage/2` reports the whole surface. Everything except
  # chain identity and height sits in this list rather than in
  # `Backend.required/0` after ADR-0039: a read about a thing on the chain needs
  # an index over things of that kind, which a node does not have and an archive
  # has only over ranges, and a chain whose only source is partial is exactly
  # what coverage is for.
  defp callbacks do
    Keyword.keys(Backend.required()) ++
      [
        :get_transaction,
        :account_info,
        :list_transactions,
        :token_balances,
        :get_block,
        :list_token_transfers,
        :read_contract,
        :contract_metadata,
        :get_logs,
        :resolve_name,
        :list_nfts,
        :raw_request
      ]
  end
end
