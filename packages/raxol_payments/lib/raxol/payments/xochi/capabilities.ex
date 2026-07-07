defmodule Raxol.Payments.Xochi.Capabilities do
  @moduledoc """
  Client for the solver capability matrix -- the single source of truth for
  which chains, tokens, and pull methods the Xochi/Riddler stack can settle
  right now.

  The Xochi worker proxies Riddler's `GET /xochi/capabilities` at
  `GET /api/capabilities`, wrapping the solver's wire payload verbatim in
  `%{"source" => "live" | "fallback", "capabilities" => matrix}`. This module
  fetches that route (never `riddler.axol.io` directly -- the worker is the
  sole agent surface), parses the matrix tolerantly, and exposes the corridor
  predicates ACP offerings route through instead of the hardcoded
  `Raxol.Payments.Assets` tables. New solver chains (Tron, Solana) then light
  up for the agent with zero raxol redeploy.

  ## Wire tolerance

  - The current matrix emits chains as `chain_id` + `chain_name` only;
    `vm_type` and `address_format` arrive with Riddler's WP-E. Absent
    `vm_type` defaults to `:evm`.
  - Unknown keys are dropped; individually malformed chain/token entries are
    skipped; a structurally unusable body parses to `:error` and callers fall
    back to `fallback/0`.
  - Both the worker-wrapped shape and a bare matrix are accepted.

  ## Degrade policy

  `fallback/0` is derived from `Raxol.Payments.Assets` (the legacy hardcoded
  mirror of Riddler's token registry), so an unreachable capabilities endpoint
  degrades to exactly today's behavior -- never to rejecting jobs the solver
  could fill yesterday.

  ## Caching

  `get/1` is an ETS-backed read-through with a TTL (default 300s), following
  the `Raxol.Payments.Checkpoint.ETS` lazy-table pattern. Pure `fetch/1` /
  `parse/1` stay side-effect-free for tests and callers that manage their own
  lifetime.
  """

  alias Raxol.Payments.Assets

  @type vm_type :: :evm | :tvm | :svm
  @type role :: :origin | :destination

  @type chain :: %{
          chain_id: pos_integer(),
          chain_name: String.t(),
          vm_type: vm_type()
        }

  @type token :: %{
          symbol: String.t(),
          roles: [role()],
          addresses: %{optional(pos_integer()) => String.t()}
        }

  @type t :: %{
          source: :live | :fallback,
          chains: [chain()],
          tokens: [token()]
        }

  @table __MODULE__
  @default_ttl_ms 300_000
  @vm_types %{"evm" => :evm, "tvm" => :tvm, "svm" => :svm}

  # Solana has no EVM-style id; Relay's pseudo-id convention (Tron already
  # rides 728126428 through the whole stack) keeps chain ids integers.
  @evm_hex_re ~r/\A0x[0-9a-fA-F]{40}\z/
  @solana_base58_re ~r/\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/

  # ============================================================
  # Fetch + parse (pure network + pure parse)
  # ============================================================

  @doc """
  Fetch and parse the capability matrix from the Xochi worker.

  `config` needs `:base_url` (e.g. `%{base_url: "https://api.xochi.fi"}`);
  optional `:req_options` merge into the request (e.g. `plug:` for
  `Req.Test`). Auth is not required -- the route is public.

  Returns `{:ok, t()}` or `{:error, reason}`; callers wanting the degrade
  behavior use `get/1` or `fallback/0` instead of handling the error.
  """
  @spec fetch(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def fetch(%{base_url: base_url} = config, opts \\ []) do
    req_options = Map.get(config, :req_options, []) ++ Keyword.get(opts, :req_options, [])

    req =
      [url: base_url <> "/api/capabilities", retry: false]
      |> Keyword.merge(req_options)
      |> Req.new()

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse(body) do
          {:ok, caps} -> {:ok, caps}
          :error -> {:error, :unparseable_capabilities}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse a capability payload -- the worker's wrapped shape or a bare matrix.

  Returns `{:ok, t()}` or `:error` when the body is structurally unusable
  (callers fall back). Individually malformed entries are dropped, not fatal.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{"source" => source, "capabilities" => matrix}) when is_map(matrix) do
    with {:ok, caps} <- parse(matrix) do
      {:ok, %{caps | source: if(source == "live", do: :live, else: :fallback)}}
    end
  end

  def parse(%{"chains" => chains, "tokens" => tokens})
      when is_list(chains) and is_list(tokens) do
    case Enum.flat_map(chains, &parse_chain/1) do
      [] ->
        :error

      parsed_chains ->
        {:ok,
         %{
           source: :live,
           chains: parsed_chains,
           tokens: Enum.flat_map(tokens, &parse_token/1)
         }}
    end
  end

  def parse(_), do: :error

  @doc """
  Static fallback derived from `Raxol.Payments.Assets` -- the six EVM chains
  and the solver-fillable token set, direction-blind (both roles), exactly
  reproducing the pre-capabilities gate.
  """
  @spec fallback() :: t()
  def fallback do
    %{
      source: :fallback,
      chains:
        Enum.map(Assets.supported_chain_ids(), fn id ->
          %{chain_id: id, chain_name: Assets.chain_name(id), vm_type: :evm}
        end),
      tokens:
        Enum.map(Assets.evm_tokens(), fn {symbol, by_chain} ->
          %{symbol: symbol, roles: [:origin, :destination], addresses: by_chain}
        end)
    }
  end

  # ============================================================
  # Cached read-through
  # ============================================================

  @doc """
  Cached capabilities: serve the ETS-cached matrix while fresh, refresh from
  the worker when stale, and degrade to the previous cached value -- or
  `fallback/0` when nothing was ever fetched -- on any failure.

  `config` as in `fetch/1`; `nil` config skips the network entirely and
  returns `fallback/0`, so callers without a configured worker keep the
  static behavior. Options: `:ttl_ms` (default #{@default_ttl_ms}).
  """
  @spec get(map() | nil, keyword()) :: t()
  def get(config, opts \\ [])

  def get(nil, _opts), do: fallback()

  def get(%{base_url: _} = config, opts) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.monotonic_time(:millisecond)

    case lookup() do
      {:ok, caps, fetched_at} when now - fetched_at < ttl ->
        caps

      stale ->
        case fetch(config, opts) do
          {:ok, caps} ->
            store(caps, now)
            caps

          {:error, _reason} ->
            case stale do
              {:ok, caps, _} -> caps
              :miss -> fallback()
            end
        end
    end
  end

  def get(_config, _opts), do: fallback()

  @doc "Drop the cached matrix (tests / operator refresh)."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete(@table, :capabilities)
    :ok
  end

  # ============================================================
  # Corridor predicates (what offerings route through)
  # ============================================================

  @doc "Chain ids the solver currently offers."
  @spec chain_ids(t()) :: [pos_integer()]
  def chain_ids(%{chains: chains}), do: Enum.map(chains, & &1.chain_id)

  @doc "VM family for a chain id; `:evm` when the chain is unknown."
  @spec vm_type(t(), pos_integer() | String.t() | nil) :: vm_type()
  def vm_type(%{chains: chains}, chain_id) do
    id = normalize_chain_id(chain_id)
    Enum.find_value(chains, :evm, fn c -> if c.chain_id == id, do: c.vm_type end)
  end

  @doc """
  True when `(chain_id, token_address)` is a solver-fillable corridor leg for
  `role`. A token qualifies when the matrix registers that address on that
  chain with the given role. Address comparison is case-insensitive for EVM
  legs and case-sensitive otherwise (base58 is case-significant).
  """
  @spec fillable?(t(), pos_integer() | String.t() | nil, String.t() | nil, role()) :: boolean()
  def fillable?(%{} = caps, chain_id, token_address, role)
      when is_binary(token_address) and token_address != "" do
    id = normalize_chain_id(chain_id)
    needle = normalize_address(caps, id, token_address)

    id in chain_ids(caps) and
      Enum.any?(caps.tokens, fn token ->
        role in token.roles and
          case Map.get(token.addresses, id) do
            nil -> false
            address -> normalize_address(caps, id, address) == needle
          end
      end)
  end

  def fillable?(_caps, _chain, _token, _role), do: false

  @doc """
  Structural address validity for a chain, dispatched on the chain's VM
  family: EVM -> `0x` + 40 hex; TVM -> full Base58Check verification via
  `Raxol.Payments.Tron.Address.valid?/1`; SVM -> base58, 32-44 chars.
  """
  @spec valid_address?(t(), pos_integer() | String.t() | nil, String.t() | nil) :: boolean()
  def valid_address?(caps, chain_id, address) when is_binary(address) do
    case vm_type(caps, chain_id) do
      :evm -> Regex.match?(@evm_hex_re, address)
      :tvm -> Raxol.Payments.Tron.Address.valid?(address)
      :svm -> Regex.match?(@solana_base58_re, address)
    end
  end

  def valid_address?(_caps, _chain, _address), do: false

  # ============================================================
  # Private
  # ============================================================

  defp parse_chain(%{"chain_id" => id} = chain) when is_integer(id) and id > 0 do
    [
      %{
        chain_id: id,
        chain_name: string_or(chain["chain_name"], "Chain #{id}"),
        vm_type: Map.get(@vm_types, chain["vm_type"], :evm)
      }
    ]
  end

  defp parse_chain(_), do: []

  defp parse_token(%{"symbol" => symbol} = token) when is_binary(symbol) and symbol != "" do
    [
      %{
        symbol: symbol,
        roles: parse_roles(token["roles"]),
        addresses: parse_addresses(token["addresses"])
      }
    ]
  end

  defp parse_token(_), do: []

  defp parse_roles(roles) when is_list(roles) do
    parsed =
      Enum.flat_map(roles, fn
        "origin" -> [:origin]
        "destination" -> [:destination]
        _ -> []
      end)

    if parsed == [], do: [:origin, :destination], else: Enum.uniq(parsed)
  end

  defp parse_roles(_), do: [:origin, :destination]

  defp parse_addresses(addresses) when is_map(addresses) do
    for {key, address} <- addresses,
        is_binary(address) and address != "",
        id = normalize_chain_id(key),
        is_integer(id),
        into: %{} do
      {id, address}
    end
  end

  defp parse_addresses(_), do: %{}

  # EVM addresses compare case-insensitively; base58 forms are case-sensitive.
  defp normalize_address(caps, chain_id, address) do
    case vm_type(caps, chain_id) do
      :evm -> String.downcase(address)
      _ -> address
    end
  end

  defp normalize_chain_id(id) when is_integer(id), do: id

  defp normalize_chain_id(id) when is_binary(id) do
    # Accept "8453", "eip155:8453" (CAIP-2), and integer-keyed JSON strings.
    id
    |> String.split(":")
    |> List.last()
    |> Integer.parse()
    |> case do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_chain_id(_), do: nil

  defp string_or(value, _default) when is_binary(value) and value != "", do: value
  defp string_or(_value, default), do: default

  defp lookup do
    ensure_table()

    case :ets.lookup(@table, :capabilities) do
      [{:capabilities, caps, fetched_at}] -> {:ok, caps, fetched_at}
      [] -> :miss
    end
  end

  defp store(caps, fetched_at) do
    ensure_table()
    :ets.insert(@table, {:capabilities, caps, fetched_at})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Race-safe lazy init: a concurrent creator wins, we use theirs.
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end
end
