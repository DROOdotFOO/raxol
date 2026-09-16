defmodule Raxol.Web3.RouterTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @chain "eip155:1"
  @account {:evm, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"}

  # Each test that touches a breaker uses its own key, because one shared table
  # holds them all and an async sibling must not inherit another test's health.
  defp key(name), do: {:origin, "router-test-#{name}-#{System.unique_integer([:positive])}"}

  defp open(key) do
    CircuitBreaker.record_failure(Tables.breakers(), key, failure_threshold: 1)
    key
  end

  defp stub(opts \\ []) do
    {:ok, handle} = Stub.new(Keyword.get(opts, :chain_ref, @chain), opts)
    handle
  end

  # Records which backend answered, so "the fallback was used" is an assertion
  # about behaviour rather than about a return value two backends share.
  #
  # `put_new`, not `put`: a caller that configures its own `chain_info` answer
  # is configuring a FAILURE, and a marker that overwrote it would make every
  # failover test pass by never failing.
  defp marked(name, opts) do
    answers = Map.put_new(answers(opts), :chain_info, {:ok, %{marker: name}})
    stub(Keyword.put(opts, :answers, answers))
  end

  defp answers(opts), do: Keyword.get(opts, :answers, %{})

  describe "routing" do
    test "a chain nobody declares is not the same error as a callback nobody answers" do
      # Two different operator problems: a missing configuration entry, and a
      # source set that cannot answer this question.
      router = Router.new([stub(capabilities: [])])

      assert {:error, :no_backend} = Router.call(router, "eip155:999", :chain_info)

      assert {:error, {:unsupported, :get_logs}} =
               Router.call(router, @chain, :get_logs, [@account, []])
    end

    test "declaration order is preference order" do
      router = Router.new([marked(:primary, []), marked(:fallback, [])])

      assert {:ok, %{marker: :primary}} = Router.call(router, @chain, :chain_info)
    end

    test "one handle declaring several chains takes its place in each" do
      multi = stub(chain_ref: "eip155:8453")
      router = Router.new([stub(), multi])

      assert @chain in Router.chains(router)
      assert "eip155:8453" in Router.chains(router)
      assert {:ok, _info} = Router.call(router, "eip155:8453", :chain_info)
    end

    test "the required two are always dispatched, whatever capabilities says" do
      # `capabilities/1` declares the optional half only, so a handle that
      # declares nothing still answers the two every backend implements: which
      # chain this is, and how far it has got.
      router = Router.new([stub(capabilities: [])])

      for {callback, arity} <- Backend.required() do
        args = List.duplicate(@account, arity - 1)
        assert {:ok, _value} = Router.call(router, @chain, callback, args)
      end
    end

    test "a read about a thing on the chain is declared now, not assumed" do
      # ADR-0039: each of these needs an index over things of its kind, over
      # accounts for three of them and over transaction ids for the fourth. A
      # node has neither and an archive has both only over ranges, so a handle
      # that declares nothing must not be dispatched them. Before that
      # amendment all four were required and this returned data.
      router = Router.new([stub(capabilities: [])])

      assert {:error, {:unsupported, :get_transaction}} =
               Router.call(router, @chain, :get_transaction, ["0xdeadbeef"])

      assert {:error, {:unsupported, :account_info}} =
               Router.call(router, @chain, :account_info, [@account])

      assert {:error, {:unsupported, :list_transactions}} =
               Router.call(router, @chain, :list_transactions, [@account, []])

      assert {:error, {:unsupported, :token_balances}} =
               Router.call(router, @chain, :token_balances, [@account])
    end
  end

  describe "per-callback candidates" do
    test "a fallback chain can be shorter for one callback than another" do
      full = stub(capabilities: [:get_logs, :get_block])
      partial = stub(capabilities: [:get_block])

      router = Router.new([full, partial])

      assert length(Router.candidates(router, @chain, :get_block)) == 2
      assert length(Router.candidates(router, @chain, :get_logs)) == 1
      assert Router.candidates(router, @chain, :raw_request) == []
    end

    test "a declared capability with no implementation is not a candidate" do
      # The half of `Backend.supports?/2` that catches a lie: a router would
      # otherwise dispatch and raise UndefinedFunctionError inside its own
      # failover, which is the one place an exception is least recoverable.
      liar = stub(capabilities: [:definitely_not_a_callback])

      assert Router.candidates(Router.new([liar]), @chain, :definitely_not_a_callback) == []
    end
  end

  describe "health ordering" do
    test "an open breaker demotes a backend to last, it does not remove it" do
      # If every candidate is open, answering nothing is worse than trying one:
      # a breaker can be stale, an upstream cannot be asked while we refuse to
      # ask it.
      sick = marked(:sick, health_key: open(key("sick")))
      well = marked(:well, [])

      router = Router.new([sick, well])

      assert {:ok, %{marker: :well}} = Router.call(router, @chain, :chain_info)

      only_sick = Router.new([sick])
      assert {:ok, %{marker: :sick}} = Router.call(only_sick, @chain, :chain_info)
      assert [_one] = Router.candidates(only_sick, @chain, :chain_info)
    end

    test "within a health class, declaration order survives" do
      # A partition, not a sort: reordering equally healthy backends would
      # silently override the operator's stated preference.
      router = Router.new([marked(:first, []), marked(:second, [])])

      assert {:ok, %{marker: :first}} = Router.call(router, @chain, :chain_info)
    end

    test "a backend with no health key is never unhealthy" do
      # The honest answer for a source that opens no socket. Inventing a key
      # for it would put a row in the breaker table that nothing can ever clear.
      assert Backend.health_key(stub()) == nil
    end

    test "a Blockscout handle reports the same key the outbound path writes" do
      # If these two disagreed, the router would order by one opinion and the
      # client would gate on another, and a tripped breaker would be invisible
      # to failover.
      {:ok, handle} = Blockscout.new(@chain)

      assert {:origin, origin_id} = Backend.health_key(handle)
      assert {:ok, "https://eth.blockscout.com:443"} = Raxol.Web3.Origin.resolve(origin_id)
    end
  end

  describe "failover decides on the error, not on the attempt" do
    test "an error about the source moves to the next backend" do
      for reason <- [
            {:breaker_open, "abc"},
            {:transport, :econnrefused},
            {:timeout, :chunk},
            {:timeout, :connect},
            {:dns_failed, "abc"},
            {:rate_limited, 500},
            {:too_large, 2048},
            {:decode_failed, :json},
            {:http, 403},
            {:http, 429},
            {:http, 503},
            {:blocked, :address},
            # A credential this deployment does not hold is a fact about the
            # source, and it cannot be reached through health: an upstream that
            # answers 404 under a withdrawn key prefix records a breaker
            # success, so only this classification moves the call on.
            {:upstream_refused, :auth},
            {:upstream_refused, :rate_limit},
            # "This source does not serve this chain", which a sibling may.
            {:unsupported_chain, "solana-mainnet"}
          ] do
        router =
          Router.new([
            marked(:primary, answers: %{chain_info: {:error, reason}}),
            marked(:fallback, [])
          ])

        assert {:ok, %{marker: :fallback}} = Router.call(router, @chain, :chain_info),
               "#{inspect(reason)} did not fail over"
      end
    end

    test "an error about the question is final, because the next source answers the same" do
      for reason <- [
            {:upstream_refused, :not_found},
            # A refusal we could not classify is not evidence that another
            # source would do better, so the caller sees the first refusal
            # rather than the last source's.
            {:upstream_refused, :unknown},
            {:unsupported_account_ref, :party},
            {:blocked, :invalid_url},
            {:http, 404},
            {:http, 400}
          ] do
        router =
          Router.new([
            marked(:primary, answers: %{chain_info: {:error, reason}}),
            marked(:fallback, [])
          ])

        assert {:error, ^reason} = Router.call(router, @chain, :chain_info),
               "#{inspect(reason)} failed over when it should not have"
      end
    end

    test "the last candidate's error is what the caller sees" do
      # Not the first one's, and not a summary: the caller needs an error it
      # can act on, and the last attempt is the freshest evidence.
      router =
        Router.new([
          stub(answers: %{chain_info: {:error, {:timeout, :chunk}}}),
          stub(answers: %{chain_info: {:error, {:transport, :econnrefused}}})
        ])

      assert {:error, {:transport, :econnrefused}} = Router.call(router, @chain, :chain_info)
    end

    test "failing over does not record health, so one failure is not counted twice" do
      # The outbound path is the only writer. A router that also recorded would
      # open a breaker at half the configured threshold, and an operator tuning
      # the threshold would be tuning something else.
      health = key("not-written")

      router =
        Router.new([
          stub(health_key: health, answers: %{chain_info: {:error, {:timeout, :chunk}}}),
          stub()
        ])

      assert {:ok, _info} = Router.call(router, @chain, :chain_info)
      assert CircuitBreaker.status(Tables.breakers(), health).failures == 0
    end
  end

  describe "a paging walk is pinned to the backend that started it" do
    test "an invalid cursor is final, so a failover cannot rewind a paginated read" do
      # The failure this rule prevents: the fallback cannot use another
      # backend's cursor, so it would answer with its FIRST page and the caller
      # would receive page one labelled page two. An error is recoverable; a
      # silent rewind is not.
      cursor = Cursor.encode(%{"block_number" => 1}, "someotherorigin", :address_transactions)

      {:ok, primary} =
        Blockscout.new(@chain, cache: false, http_opts: [exchange: refusing_exchange()])

      router = Router.new([primary, marked(:fallback, [])])

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Router.call(router, @chain, :list_transactions, [@account, [cursor: cursor]])
    end

    test "a walk that starts on the primary continues on the primary" do
      {:ok, primary} = Blockscout.new(@chain, cache: false, http_opts: paging_exchange())

      router = Router.new([primary, stub()])

      assert {:ok, %{next: cursor}} =
               Router.call(router, @chain, :list_transactions, [@account, []])

      assert is_binary(cursor)

      assert {:ok, page} =
               Router.call(router, @chain, :list_transactions, [@account, [cursor: cursor]])

      assert [%{hash: "0xpage2"}] = page.items
    end
  end

  describe "coverage/2" do
    test "reports what is answerable now, in preference order" do
      router =
        Router.new([
          stub(capabilities: [:get_logs]),
          stub(capabilities: [:get_logs, :get_block])
        ])

      coverage = Router.coverage(router, @chain)

      assert coverage[:get_logs] == [:stub, :stub]
      assert coverage[:get_block] == [:stub]
      assert coverage[:chain_info] == [:stub, :stub]
      refute Map.has_key?(coverage, :raw_request)
    end

    test "a callback whose only source is open-breakered drops out" do
      # The degradation that is otherwise invisible until a caller gets an
      # error: a challenge-serving explorer takes the explorer-only callbacks
      # with it, and the operator's question is which ones.
      sick = stub(capabilities: [:get_logs], health_key: open(key("coverage")))

      coverage = Router.coverage(Router.new([sick]), @chain)

      assert coverage == %{}
    end

    test "an unrouted chain has no coverage rather than an error" do
      assert Router.coverage(Router.new([stub()]), "eip155:999") == %{}
    end
  end

  describe "against a real upstream" do
    @tag :live_web3
    test "routes a live read and reports live coverage" do
      {:ok, blockscout} =
        Blockscout.new(@chain,
          cache: false,
          http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]
        )

      router = Router.new([blockscout])

      assert {:ok, info} = Router.call(router, @chain, :chain_info)
      assert info.total_blocks > 25_000_000

      coverage = Router.coverage(router, @chain)
      assert coverage[:chain_info] == [:blockscout]
      assert coverage[:get_logs] == [:blockscout]

      # Declined rather than declared, so it is absent from a live coverage
      # report too, not merely from the capability list.
      refute Map.has_key?(coverage, :raw_request)
    end
  end

  defp refusing_exchange do
    fn _vetted, request, _opts ->
      flunk("the router built a request from an unusable cursor: #{inspect(request.path)}")
    end
  end

  # Page one carries a cursor; page two is whatever the cursor asks for. Keyed
  # on the presence of the query string, which is the only difference between
  # the two requests.
  defp paging_exchange do
    [
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end,
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      exchange: fn _vetted, request, _opts ->
        body =
          if String.contains?(request.path, "block_number=") do
            ~s({"items":[{"hash":"0xpage2"}],"next_page_params":null})
          else
            ~s({"items":[{"hash":"0xpage1"}],"next_page_params":{"block_number":1,"index":2,"items_count":50}})
          end

        {:ok, %{status: 200, headers: [], body: body}}
      end
    ]
  end
end
