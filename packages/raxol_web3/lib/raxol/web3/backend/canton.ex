defmodule Raxol.Web3.Backend.Canton do
  @moduledoc """
  The Canton backend, against the Splice Scan v0 surface plus ccscan's MCP tools.

  This is the chain that three of `Raxol.Web3.Backend`'s shapes exist for, so
  each one is exercised here rather than asserted: there are no addresses, only
  party ids; there are no blocks, only rounds; and pagination is a POST carrying
  an after-cursor, which is a fourth scheme beside Blockscout's keyset, a
  `start`/`limit` ceiling and a signature cursor.

  ## The keyless story, corrected 2026-09-14

  ADR-0033 and the upstream survey both record that Canton has **no fully
  keyless path**, and call that a first for this package. Measured on
  2026-09-14, that is too pessimistic, and the correction is large enough to
  change which source answers what:

    * `GET /v0/round-of-latest-data` answers 200 with no credential, carrying
      `{"round": 113141, "effectiveAt": "2026-09-14T10:39:37Z"}`.
    * `GET /v0/dso` answers 200 with no credential, 72,339 bytes, carrying
      `dso_party_id`, the voting threshold, the latest mining round and every
      super-validator's declared synchronizer migration id.
    * `POST /v0/holdings/summary` and `POST /v0/holdings/state` both answer 200
      with no credential for a real party id, which means the **party-scoped**
      reads are keyless too and not only the two required callbacks.
    * `GET /v0/updates/{update_id}` answers 200 with no credential.

  So every callback this backend declares except `raw_request/2` answers without
  a credential, and the ccscan account is needed only for the passthrough. The
  survey's "there is no fully keyless path" line needs amending.

  Two path guesses from the Splice specification were wrong on the same host,
  which is why the table below is probe-derived rather than ported:
  `/v0/total-amulet-balance?asOfEndOfRound=N` is a 404, and `/v0/acs/{party}` is
  a 404. `POST /v0/holdings/summary` rejects `party_ids` and requires
  `owner_party_ids`, which a specification reader would not guess either.

  ## Two hosts, one surface, one prefix that moves

  `api.cantonnodes.com` serves the Splice Scan v0 surface under `/v0`. A
  configured Splice Scan instance serves the same surface under `/api/scan/v0`:
  measured 2026-09-14, `scan.sv-1.global.canton.network.digitalasset.com` answers
  403 `RBAC: access denied` for `/api/scan/v0/dso`, which is an authorization
  refusal rather than a 404, so the prefix is right and that particular host is
  not open from this network. The prefix therefore travels inside `:scan_url`
  rather than being hardcoded, and pointing this backend at an operator's own
  Scan instance is a URL change and no code change.

  Splice Scan is Apache-2.0 and publishes an OpenAPI specification, which is the
  licence that permits reuse. ccscan is closed and governed by its terms of
  service, so its **design is not ported**: what is used from it is its public
  MCP tool surface, through `raw_request/2`, and nothing else.

  ## No addresses: a party id

  `account_info/2` and `token_balances/3` take `{:party, "name::fingerprint"}`.
  A party id is a name, two colons and a fingerprint, and it is
  `Raxol.Web3.Serialize`'s `party` tag that carries it across the served
  surface: `"party:Alice::1220abcd"` parses back to `{:party, "Alice::1220abcd"}`
  because that parse splits on the FIRST colon only.

  The `::` never needs URL escaping here, because every party-scoped read this
  backend uses is a POST whose party travels in the body. The one keyless GET
  that takes a party in its path, `/v0/ans-entries/by-party/{party}`, takes it
  unescaped without complaint and answered a structured 404 echoing the party
  back for every party probed on 2026-09-14, so the Canton Name Service
  directory is empty on this host and `resolve_name/2` is not declared: a read
  whose only observed answer is a refusal is not a read.

  `:kind` is **omitted** from the account map rather than set. Canton has no
  account-kind taxonomy that changes how a balance must be read: every party is
  a party, and the distinctions that exist (a super-validator, a validator, an
  end user) are roles in governance rather than in custody. An absent key means
  the question does not apply here, which is a different fact from `nil`.

  `contract?` and `verified?` are both `false` by construction: a party holds no
  code and there is no source-verification notion to report. `name` is the party
  id's own name component, which is self-asserted by whoever allocated the
  party and is not unique, exactly as an explorer's address label is.

  ## No blocks: a round, and what the two heights mean

  `block_height/1` returns `unit: :round`, and neither number is a height in the
  EVM sense. `GET /v0/round-of-latest-data` names the round whose data the
  source has complete, so:

    * `height` is that round. It is a **lower bound on chain progress** rather
      than a tip: the open mining rounds run ahead of it, and this keyless
      surface publishes no tip round.
    * `finalized_height` is the **same number, deliberately and not by
      omission**. Canton commits through BFT consensus with no fork choice, so a
      round whose data is complete cannot be reorganized. The pair is equal by
      construction, a consumer's confirmation depth is 0, and 0 is the true
      answer on this chain rather than an absence to be reported as `nil`.

  `indexer` reports `finished?: true`, which is the endpoint's own claim and not
  ours (it is named for the round whose data is complete), plus `lag_seconds`
  from the age of the `effectiveAt` the same response carries. `:indexed_ratio`
  and `:lag_blocks` are omitted: no ratio is published, and there are no blocks
  to lag by.

  `get_block/2` is **not declared**, so `Raxol.Web3.Router.coverage/2` reports
  its absence for this chain. None of the Splice Scan paths returns a block,
  because there is none to return.

  ## A POST with an after-cursor

  `POST /v0/holdings/state` is the fourth pagination scheme in this package.
  Measured 2026-09-14 and every part of it measured rather than read:

    * the request carries `after`, an integer offset into the ACS snapshot,
      beside `migration_id`, `record_time`, `owner_party_ids` and `page_size`;
    * the response carries `next_page_token`, an integer or `null`;
    * `after: 8926540676` returned `next_page_token: 8926540890`, so the walk
      advances, while the plausible `page_token` name is silently ignored;
    * an `after` outside the snapshot range is a 400 carrying the range, which
      is what a caller sees when the daily snapshot rolls over mid-walk: restart
      the walk;
    * **a non-null `next_page_token` beside an EMPTY `created_events` means keep
      going, not done.** The scan pages through the snapshot and a page can
      filter to nothing. So `next` is minted from the token's presence and never
      from whether the page had items.

  The cursor carries `migration_id` and `record_time` alongside `after`, because
  an offset into one snapshot is meaningless in another, and pinning them is
  what makes a held cursor keep walking the snapshot it was minted against.

  ## Amounts, and the fee this backend does not net out

  Canton Coin carries exactly 10 decimal places in every figure of every
  response probed, so an amount is reported in the smallest unit as an integer,
  the way wei and lamports are.

  `account_info/2` reports `total_coin_holdings`, the gross holding. Measured
  2026-09-14, a party's gross total equalled its single Amulet contract's
  `initialAmount` to the digit, so the gross figure and the sum of a
  `token_balances/3` page agree, which is the property that matters when both
  are read together. The upstream publishes an accrued holding fee separately
  (`accumulated_holding_fees_total`, 0.0122197152 against a 1,844,175 holding),
  and neither field here nets it out; a caller needing the spendable figure
  wants `total_available_coin`, which this contract has nowhere to put.

  A party with no summary row reports `balance: nil` rather than `0`. The two
  are indistinguishable in the response, and ADR-0039's rule is that no gate may
  read a non-answer as zero.

  ## `list_transactions/3` is not declared, and that is a measurement

  No surveyed source lists transactions by party. `POST /v0/transactions`
  answers 200 keyless and is chain-wide, taking only `page_end_event_id`,
  `sort_order` and `page_size`; `POST /v0/updates` is chain-wide too; and
  ccscan's `get_transactions` takes only a `limit`. `get_transaction/2` is
  answerable, from `GET /v0/updates/{update_id}`, and its normalization is thin
  on purpose: a Daml update has no single sender, recipient, value or fee, since
  those live inside per-template choice arguments, and extracting them would be
  a Daml interpreter rather than a normalization. What travels is the update id,
  the record time, and the root exercised choice as `method`.

  ## The ccscan account requirement

  ccscan's `tools/list` is open and stateless: 13 tools, plain
  `application/json`, no session at all. Every `tools/call` answers **HTTP 200**
  with `result.isError: true` and `content[0].text` holding
  `{"error": "account_required", ...}`. That recognised body shape maps onto
  `{:upstream_refused, :auth}`, and the upstream's own sentence does not travel:
  the actionable part is here, in this moduledoc, and in the origin id the error
  path names. **What an operator must do: create a free ccscan account and pass
  its key as `:ccscan_key`.** Nothing else in this backend needs it.

  A handle with no `:ccscan_key` fails `raw_request/2` with the same
  `{:upstream_refused, :auth}` without spending a request, so the answer is the
  named one whether the credential is missing or rejected. It is never the
  reason a required callback fails, because those go to the keyless host.

  The key is held in transit only: it is composed into a request header per call
  and appears in no log line, no telemetry measurement, no cache key and no
  durable store. `raw_request/2` is not cached at all, since a passthrough's
  cache key would have to be composed from caller-supplied arguments.

  ## Chain reference

  There is no registered CAIP-2 namespace for Canton, so `canton:global` is
  **ours rather than registered**, naming the Global Synchronizer.
  `canton:mainnet` is accepted as an alias and normalized to it, so a caller
  that reached for the EVM habit still routes.

  ## Rate limits

  Neither upstream publishes a figure. `api.cantonnodes.com` answered 429 after
  roughly three requests spaced a few seconds apart on 2026-09-14, and answered
  every request spaced twelve seconds apart, so the refill rate below is **a
  guess anchored on that observed threshold** rather than a published number.
  ccscan's limits are **unverified**, because the endpoint that would document
  them is itself account-gated, so it gets the same conservative seed.

  The capacity is not a guess: it is the cold cost of the most expensive single
  read here. `token_balances/3` with nothing cached is four requests, the DSO
  body, the ACS snapshot, the asset catalog and the page itself, so a capacity
  below four would make one logical read fail on its own budget. Three of those
  four are `:catalog`-cached for an hour, so the steady-state cost is one.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.MCPCall
  alias Raxol.Web3.Origin
  alias Raxol.Web3.TTL

  @enforce_keys [:chain_ref, :scan_url]
  defstruct [
    :chain_ref,
    :scan_url,
    :ccscan_url,
    :ccscan_key,
    :migration_id,
    ccscan_auth_header: "authorization",
    http_opts: [],
    cache?: true
  ]

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          scan_url: String.t(),
          ccscan_url: String.t(),
          ccscan_key: String.t() | nil,
          migration_id: non_neg_integer() | nil,
          ccscan_auth_header: String.t(),
          http_opts: keyword(),
          cache?: boolean()
        }

  @chain_ref "canton:global"

  # Ours, not registered: no CAIP-2 namespace exists for Canton. The alias is
  # here so a caller reaching for the EVM habit still routes.
  @chain_refs %{@chain_ref => @chain_ref, "canton:mainnet" => @chain_ref}

  @default_scan_url "https://api.cantonnodes.com/v0"
  @default_ccscan_url "https://ccscan.xyz/mcp"

  # Every path probed 2026-09-14 against api.cantonnodes.com, all 200 keyless.
  # Data, not behaviour: the method is part of the row because two of the five
  # are POSTs whose parameters travel in a body rather than a query string.
  @paths %{
    round_of_latest_data: {:get, "/round-of-latest-data"},
    dso: {:get, "/dso"},
    acs_snapshot: {:get, "/state/acs/snapshot-timestamp"},
    instance_names: {:get, "/splice-instance-names"},
    holdings_summary: {:post, "/holdings/summary"},
    holdings_state: {:post, "/holdings/state"}
  }

  # Measured 2026-09-14: `tools/list` on the ccscan endpoint answers 200 with
  # exactly these 13 names and issues no session. Names only. The upstream's own
  # descriptions are not copied anywhere, which is ADR-0033 section 7's rule
  # about third-party prose and is also what keeps a served tool definition free
  # of em-dashes this repository's prose lint would refuse.
  @ccscan_tools ~w(search get_network_overview get_economics get_price get_assets
                   get_transactions get_transaction get_party get_validators
                   get_sv_locking get_app_locking get_governance get_round)

  # Splice's Daml `Decimal`, and measured: every amulet figure in every response
  # probed carries exactly ten fractional digits.
  @amulet_decimals 10

  # `page_size` is a REQUIRED field on `POST /v0/holdings/state`, measured
  # 2026-09-14: omitting it answers 400 with `DecodingFailure at .page_size:
  # Missing required field`, which is the one field a specification reader
  # would assume optional. The upstream's own ceiling is 1000, measured the
  # same way: 1001 answers 400 naming the limit. 100 is this backend's choice
  # inside that ceiling, and it is a judgement rather than a measurement: a
  # party typically holds ONE consolidated Amulet contract, so a page rarely
  # fills, and the cost of a larger one is bytes for a walk that will not
  # happen. The ceiling enforces itself below rather than being a comment, so
  # raising the page size past what the upstream accepts fails the build rather
  # than a request.
  @page_size 100
  @max_page_size 1000

  if @page_size > @max_page_size do
    raise "page_size #{@page_size} exceeds the upstream ceiling of #{@max_page_size}, " <>
            "measured 2026-09-14 on POST /v0/holdings/state"
  end

  # The refill is a guess, the capacity is derived. See "Rate limits" above.
  @rate_limit [capacity: 4, refill_per_second: 0.2]

  @optional_callbacks_declared [:get_transaction, :account_info, :token_balances, :raw_request]

  @doc """
  Build a handle for a Canton chain reference.

  Options:

    * `:scan_url` - the Splice Scan v0 base, prefix included. Defaults to
      `#{@default_scan_url}`, the keyless host. A configured Scan instance is
      `https://<host>/api/scan/v0`.
    * `:ccscan_url` - the ccscan MCP endpoint, default `#{@default_ccscan_url}`.
    * `:ccscan_key` - the ccscan account credential. Without it `raw_request/2`
      refuses with `{:upstream_refused, :auth}` and nothing else changes.
    * `:ccscan_auth_header` - the header the credential travels in, default
      `authorization` with a `Bearer` scheme. **This name is a guess**: the
      upstream's refusal says "or use an API key" without naming a header, and
      the endpoint that would document it is account-gated. An operator who
      knows better overrides it here rather than patching this module.
    * `:migration_id` - pins the synchronizer migration the party-scoped reads
      query. Derived from `/v0/dso` when absent, which is the honest default;
      pass it to read a historical migration deliberately.
    * `:http_opts` - forwarded to `Raxol.Web3.HTTP` unchanged.
    * `:cache` - default `true`. `false` turns off the response cache for this
      handle. A height is never cached either way.
  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()} | {:error, term()}
  def new(chain_ref, opts \\ []) do
    with {:ok, canonical} <- Map.fetch(@chain_refs, chain_ref) |> ok_or(chain_ref) do
      state = %__MODULE__{
        chain_ref: canonical,
        scan_url: opts |> Keyword.get(:scan_url, @default_scan_url) |> String.trim_trailing("/"),
        ccscan_url: Keyword.get(opts, :ccscan_url, @default_ccscan_url),
        ccscan_key: Keyword.get(opts, :ccscan_key),
        migration_id: Keyword.get(opts, :migration_id),
        ccscan_auth_header: Keyword.get(opts, :ccscan_auth_header, "authorization"),
        http_opts: Keyword.get(opts, :http_opts, []),
        cache?: Keyword.get(opts, :cache, true)
      }

      {:ok, {__MODULE__, state}}
    end
  end

  @doc "The probed endpoint table, as `{method, path}`. Data, not behaviour."
  @spec paths() :: %{atom() => {:get | :post, String.t()}}
  def paths, do: @paths

  @doc "The ccscan tool names `raw_request/2` will dispatch."
  @spec raw_request_allowlist() :: [String.t()]
  def raw_request_allowlist, do: @ccscan_tools

  @doc "The chain references this backend answers for, canonical and aliased."
  @spec chain_refs() :: [Backend.chain_ref()]
  def chain_refs, do: Map.keys(@chain_refs)

  @doc """
  The token-bucket seed both upstreams get unless a handle overrides it.

  Data, so the derivation in "Rate limits" is checkable rather than asserted.
  """
  @spec rate_limit() :: keyword()
  def rate_limit, do: @rate_limit

  @impl Backend
  def backend, do: :canton

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  # The same list with and without a credential. `raw_request/2` is declared
  # either way so that a missing key is a named, actionable refusal rather than
  # `{:unsupported, :raw_request}`, which would tell an operator that the source
  # cannot answer when in fact it can, with an account.
  @impl Backend
  def capabilities(%__MODULE__{}), do: @optional_callbacks_declared

  # The keyless Scan host, because that is where the two required callbacks go.
  # ccscan is a second origin with its own bucket and breaker inside
  # `Raxol.Web3.HTTP`; a router ordering candidates cares about the origin that
  # answers the reads every source must answer.
  @impl Backend
  def health_key(%__MODULE__{} = state), do: {:origin, scan_origin_id(state)}

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    with {:ok, body} <- dso(state) do
      {:ok,
       %{
         chain_ref: state.chain_ref,
         # The mining round's tick duration, which is this chain's cadence. It
         # is not a block time, because there are no blocks.
         average_block_time_ms: tick_duration_ms(body),
         # Three nils, and each is a fact rather than a gap: Canton has no
         # blocks to count and no addresses to count, and the keyless surface
         # publishes no chain-wide transaction total.
         total_blocks: nil,
         total_transactions: nil,
         total_addresses: nil
       }}
    end
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    with {:ok, body} <- get(state, :round_of_latest_data),
         {:ok, round} <- fetch_round(body) do
      {:ok,
       %{
         height: round,
         finalized_height: round,
         unit: :round,
         indexer: indexer(body)
       }}
    end
  end

  # -- optional ----------------------------------------------------------------

  @impl Backend
  def get_transaction(%__MODULE__{} = state, update_id) when is_binary(update_id) do
    with {:ok, body} <- get_update(state, update_id) do
      {:ok, transaction(body)}
    end
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    with {:ok, party} <- party(account_ref),
         {:ok, snapshot} <- snapshot(state),
         request = Map.put(snapshot, "owner_party_ids", [party]),
         {:ok, body} <- post(state, :holdings_summary, request, :account) do
      {:ok, account(party, body)}
    end
  end

  @impl Backend
  def token_balances(%__MODULE__{} = state, account_ref, opts \\ []) do
    with {:ok, party} <- party(account_ref),
         {:ok, request} <- holdings_request(state, party, Keyword.get(opts, :cursor)),
         {:ok, symbol} <- amulet_names(state),
         {:ok, body} <- post(state, :holdings_state, request, :list) do
      {:ok, holdings_page(state, request, body, symbol)}
    end
  end

  @doc """
  Dispatch one allowlisted ccscan tool and return its payload.

  The allowlist is `raw_request_allowlist/0`, the 13 read-only tool names
  measured from a live `tools/list`. Arguments must be a flat map of scalars: a
  nested structure is refused here rather than forwarded, because these values
  are the one thing on this path a caller chooses.

  Requires `:ccscan_key`. Without one this is `{:upstream_refused, :auth}` and
  no request is made.
  """
  @impl Backend
  def raw_request(%__MODULE__{ccscan_key: nil}, _call), do: {:error, {:upstream_refused, :auth}}

  def raw_request(%__MODULE__{} = state, %{tool: tool} = call) when is_binary(tool) do
    with :ok <- allowed_tool(tool),
         {:ok, arguments} <- scalar_arguments(Map.get(call, :arguments, %{})) do
      state.ccscan_url
      |> MCPCall.call(tool, arguments, ccscan_opts(state))
      |> ccscan_result()
    end
  end

  def raw_request(%__MODULE__{}, _call), do: {:error, {:unsupported, :raw_request}}

  # -- the outbound path -------------------------------------------------------

  # `class` names the cache class, or `nil` for a request that must not be
  # cached. The key fragment is built from the endpoint's own path and its own
  # parameters, never from an assembled URI, which is what keeps a credential
  # out of a cache key structurally rather than by review.
  defp get(state, endpoint, query \\ %{}, class \\ nil) do
    {:get, path} = Map.fetch!(@paths, endpoint)

    state
    |> url(path, query)
    |> HTTP.get(scan_opts(state, path, query, class))
    |> decode()
  end

  defp post(state, endpoint, request, class) do
    {:post, path} = Map.fetch!(@paths, endpoint)

    opts =
      state
      |> scan_opts(path, request, class)
      |> Keyword.put(:headers, [{"content-type", "application/json"}])

    state
    |> url(path, %{})
    |> HTTP.post(Jason.encode!(request), opts)
    |> decode()
  end

  # A path parameter rather than a table row, so it composes the path itself.
  # The id reaches here from a caller, so it is percent-encoded against the
  # unreserved set rather than with `URI.encode/1`'s default predicate: that
  # predicate leaves `/`, `?` and `#` alone, so it is not a defence at all --
  # `URI.encode("../../v0/admin?x=1")` is its own input, and an id shaped like
  # that would walk off `/updates/` on a credentialed host and pick its own
  # path and query.
  defp get_update(state, update_id) do
    state
    |> url("/updates/#{URI.encode(update_id, &URI.char_unreserved?/1)}", %{})
    |> HTTP.get(scan_opts(state, "/updates", %{"id" => update_id}, :transaction))
    |> decode()
  end

  defp scan_opts(state, path, fragment, class) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, @rate_limit)
    |> cache_opts(state, path, fragment, class)
  end

  defp cache_opts(opts, _state, _path, _fragment, nil), do: opts
  defp cache_opts(opts, %{cache?: false}, _path, _fragment, _class), do: opts

  defp cache_opts(opts, _state, path, fragment, class) do
    Keyword.put(opts, :cache, key: {path, fragment}, ttl_ms: TTL.for(class))
  end

  defp url(state, path, query) when map_size(query) == 0, do: state.scan_url <> path

  defp url(state, path, query) do
    "#{state.scan_url}#{path}?#{URI.encode_query(query)}"
  end

  # A non-2xx carries no body onward. The one 400 this surface produces is an
  # `after` outside the current snapshot range, which a caller answers by
  # restarting the walk; the range itself is upstream text and stays there.
  defp decode({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  defp decode({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp decode({:error, _reason} = error), do: error

  defp scan_origin_id(state), do: Origin.id(URI.new!(state.scan_url))

  # -- ccscan ------------------------------------------------------------------

  # The credential is composed into a header here, per call, and nowhere else.
  # It is not in the cache options, because `raw_request/2` is not cached, and
  # it is not in any error term, because none of them carries a header.
  defp ccscan_opts(state) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, @rate_limit)
    |> Keyword.put(:headers, [{state.ccscan_auth_header, "Bearer " <> state.ccscan_key}])
  end

  # The one recognised body shape this backend declares. `account_required` was
  # measured 2026-09-14 inside an HTTP 200 with `isError: true`, so it is mapped
  # from the body and never from a status. The payload is dropped rather than
  # carried: ADR-0038 decision 6 keeps upstream text out of an error term, and
  # the actionable part is in this module's moduledoc instead.
  defp ccscan_result({:ok, payload}), do: {:ok, payload}

  defp ccscan_result({:tool_error, %{"error" => "account_required"}}) do
    {:error, {:upstream_refused, :auth}}
  end

  defp ccscan_result({:tool_error, _payload}), do: {:error, {:upstream_refused, :unknown}}
  defp ccscan_result({:error, _reason} = error), do: error

  defp allowed_tool(tool) do
    if tool in @ccscan_tools, do: :ok, else: {:error, {:unsupported, :raw_request}}
  end

  defp scalar_arguments(arguments) when is_map(arguments) do
    if Enum.all?(arguments, &scalar_argument?/1) do
      {:ok, Map.new(arguments, fn {key, value} -> {to_string(key), value} end)}
    else
      {:error, {:unsupported, :raw_request}}
    end
  end

  defp scalar_arguments(_other), do: {:error, {:unsupported, :raw_request}}

  defp scalar_argument?({key, value}) do
    (is_binary(key) or is_atom(key)) and
      (is_binary(value) or is_number(value) or is_boolean(value))
  end

  # -- the DSO reference read --------------------------------------------------

  # `:catalog` rather than `:chain_stats`: this body is governance and topology
  # reference data, it changes on a vote rather than on a round, and it is the
  # only place the current synchronizer migration id is published. 72 KB an hour
  # buys both `chain_info/1` and the migration id every party-scoped read needs.
  defp dso(state), do: get(state, :dso, %{}, :catalog)

  defp tick_duration_ms(body) do
    case get_in(body, ["latest_mining_round", "contract", "payload", "tickDuration"]) do
      %{"microseconds" => micros} -> div_or_nil(int(micros), 1000)
      _absent -> nil
    end
  end

  defp div_or_nil(nil, _divisor), do: nil
  defp div_or_nil(value, divisor), do: div(value, divisor)

  # Every super-validator declares a migration id for its sequencer, nested
  # inside a Daml-encoded map whose shape differs per node, so the highest id
  # published anywhere in the body is taken rather than one path walked. The
  # current migration is by definition the highest any node has moved to.
  # Measured 2026-09-14: every id in the body is "4".
  #
  # A pinned id short-circuits the read rather than overriding it afterwards,
  # so reading a historical migration deliberately costs no 72 KB fetch.
  defp resolve_migration(%__MODULE__{migration_id: id}) when is_integer(id), do: {:ok, id}

  defp resolve_migration(%__MODULE__{} = state) do
    with {:ok, body} <- dso(state) do
      body |> collect_migration_ids() |> Enum.max(fn -> nil end) |> highest_migration()
    end
  end

  defp highest_migration(nil), do: {:error, {:decode_failed, :migration_id}}
  defp highest_migration(id) when is_integer(id), do: {:ok, id}

  defp collect_migration_ids(%{} = map) do
    own = map |> Map.get("migrationId") |> int() |> List.wrap()
    own ++ Enum.flat_map(Map.values(map), &collect_migration_ids/1)
  end

  defp collect_migration_ids(list) when is_list(list) do
    Enum.flat_map(list, &collect_migration_ids/1)
  end

  defp collect_migration_ids(_scalar), do: []

  # -- the ACS snapshot a party-scoped read is taken against -------------------

  # Both party-scoped reads are as-of a snapshot, so the snapshot has to be
  # resolved first: a migration id from the DSO body and the latest snapshot
  # record time at or before now. `before` is truncated to the hour so the cache
  # key is stable for one, which is safe because snapshots land daily (measured
  # 2026-09-14: midnight for migration 4, noon for migration 0) and `before` is
  # inclusive.
  defp snapshot(state) do
    with {:ok, migration} <- resolve_migration(state),
         query = %{"before" => hour_boundary(), "migration_id" => migration},
         {:ok, body} <- get(state, :acs_snapshot, query, :catalog),
         {:ok, record_time} <- fetch_record_time(body) do
      {:ok, %{"migration_id" => migration, "record_time" => record_time}}
    end
  end

  defp hour_boundary do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Map.merge(%{minute: 0, second: 0})
    |> DateTime.to_iso8601()
  end

  defp fetch_record_time(%{"record_time" => record_time}) when is_binary(record_time) do
    {:ok, record_time}
  end

  defp fetch_record_time(_body), do: {:error, {:decode_failed, :acs_snapshot}}

  # -- holdings pagination -----------------------------------------------------

  # Without a cursor the snapshot is resolved live; with one it comes from
  # inside the signed payload, which is what pins a walk to the snapshot it
  # started against rather than letting it drift onto today's. `page_size` is
  # added here rather than carried in the cursor, deliberately: it is a
  # required field and it is ours, so a held cursor cannot choose how much of
  # somebody else's budget the next request spends.
  defp holdings_request(state, party, nil) do
    with {:ok, snapshot} <- snapshot(state) do
      {:ok, holdings_body(snapshot, party)}
    end
  end

  defp holdings_request(state, party, cursor) do
    case Cursor.decode(cursor, scan_origin_id(state), :canton_holdings_state) do
      {:ok, params} -> {:ok, holdings_body(params, party)}
      {:error, reason} -> {:error, {:invalid_cursor, reason}}
    end
  end

  defp holdings_body(params, party) do
    params
    |> Map.put("owner_party_ids", [party])
    |> Map.put("page_size", @page_size)
  end

  # `next` is minted from the token's presence and never from whether the page
  # had items: measured 2026-09-14, a page with zero `created_events` came back
  # with a non-null `next_page_token`, and reading that as the end of the walk
  # would report a party as holding nothing while its holdings were one page
  # further on.
  defp holdings_page(state, request, body, symbol) do
    %{
      items: body |> Map.get("created_events", []) |> Enum.map(&token_balance(&1, symbol)),
      next: next_cursor(state, request, body["next_page_token"])
    }
  end

  defp next_cursor(_state, _request, nil), do: nil

  defp next_cursor(state, request, token) do
    request
    |> Map.take(["migration_id", "record_time"])
    |> Map.put("after", token)
    |> Cursor.encode(scan_origin_id(state), :canton_holdings_state)
  end

  # The asset catalog, `:catalog` class: the amulet's name and acronym are an
  # upstream release's worth of stable and the cost of a stale row is a label
  # rather than a number.
  defp amulet_names(state) do
    with {:ok, body} <- get(state, :instance_names, %{}, :catalog) do
      {:ok, %{symbol: body["amulet_name_acronym"], name: body["amulet_name"]}}
    end
  end

  # -- normalization -----------------------------------------------------------

  defp account(party, body) do
    summary = body |> Map.get("summaries", []) |> List.first()

    %{
      ref: {:party, party},
      # `nil` and not `0` for an absent summary: see the moduledoc.
      balance: summary && amulet(summary["total_coin_holdings"]),
      # A party holds no code and there is nothing to verify.
      contract?: false,
      verified?: false,
      # Self-asserted by whoever allocated the party, and not unique.
      name: party_name(party),
      ens: nil
      # `:kind` is omitted, not nil: Canton has no account-kind taxonomy.
    }
  end

  # Thin on purpose: a Daml update carries no single sender, recipient, value or
  # fee. `method` is the root exercised choice, which is the operation invoked.
  defp transaction(body) do
    %{
      hash: body["update_id"],
      # An update in the Scan's history is a committed transaction. A rejected
      # Canton command never becomes one, so there is no reverted state to
      # report and `:pending` cannot be observed from this endpoint either.
      status: :success,
      block: nil,
      timestamp: timestamp(body["record_time"]),
      from: nil,
      to: nil,
      value: nil,
      fee: nil,
      method: root_choice(body)
    }
  end

  defp root_choice(body) do
    events = Map.get(body, "events_by_id", %{})

    body
    |> Map.get("root_event_ids", [])
    |> Enum.find_value(fn id -> exercised_choice(Map.get(events, id)) end)
  end

  defp exercised_choice(%{"event_type" => "exercised_event", "choice" => choice})
       when is_binary(choice),
       do: choice

  defp exercised_choice(_event), do: nil

  # The Amulet contract's own recorded amount. A caller summing a page gets the
  # gross holding, which the upstream's `total_coin_holdings` agrees with to the
  # digit; the accrued holding fee is a party-level figure and is not netted out
  # here. `template_id` is the asset's identity on this chain, which is a Daml
  # template rather than a contract address.
  defp token_balance(event, names) do
    %{
      token: %{
        address: event["template_id"],
        symbol: names.symbol,
        name: names.name,
        decimals: @amulet_decimals,
        type: event["package_name"]
      },
      amount: event |> get_in(["create_arguments", "amount", "initialAmount"]) |> amulet(),
      token_id: event["contract_id"]
    }
  end

  # Reported in the smallest unit, the way wei and lamports are. A figure with
  # more than ten fractional digits is a shape change rather than a rounding
  # opportunity, so it is `nil`.
  defp amulet(nil), do: nil

  defp amulet(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [whole] -> units(whole, "")
      [whole, fraction] -> units(whole, fraction)
    end
  end

  defp amulet(_other), do: nil

  defp units(whole, fraction) when byte_size(fraction) <= @amulet_decimals do
    padding = String.duplicate("0", @amulet_decimals - byte_size(fraction))

    case Integer.parse(whole <> fraction <> padding) do
      {units, ""} when units >= 0 -> units
      _unparseable -> nil
    end
  end

  defp units(_whole, _fraction), do: nil

  # `finished?` is the endpoint's own claim: it is named for the round whose
  # data is complete. `lag_seconds` is the age of that data, which is the one
  # freshness figure this host publishes. No ratio is published and there are no
  # blocks to lag by, so both of those keys are absent rather than computed.
  defp indexer(%{"effectiveAt" => effective_at}) when is_binary(effective_at) do
    case timestamp(effective_at) do
      nil -> %{finished?: true}
      datetime -> %{finished?: true, lag_seconds: max(0, DateTime.diff(utc_now(), datetime))}
    end
  end

  defp indexer(_body), do: %{finished?: true}

  defp utc_now, do: DateTime.utc_now()

  defp fetch_round(%{"round" => round}) do
    case int(round) do
      nil -> {:error, {:decode_failed, :round}}
      value -> {:ok, value}
    end
  end

  defp fetch_round(_body), do: {:error, {:decode_failed, :round}}

  # A party id is `name::fingerprint`, so the name is the part before the first
  # pair of colons. A party id with no name part reports `nil` rather than "".
  defp party_name(party) do
    case String.split(party, "::", parts: 2) do
      [name, _fingerprint] when name != "" -> name
      _unnamed -> nil
    end
  end

  defp party({:party, id}) when is_binary(id) and id != "", do: {:ok, id}
  defp party({tag, _value}), do: {:error, {:unsupported_account_ref, tag}}
  defp party(_other), do: {:error, {:unsupported_account_ref, :unknown}}

  defp ok_or({:ok, _value} = ok, _reason), do: ok
  defp ok_or(:error, reason), do: {:error, {:unsupported_chain, reason}}

  defp int(nil), do: nil
  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _unparseable -> nil
    end
  end

  defp int(_other), do: nil

  defp timestamp(nil), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_other), do: nil
end
