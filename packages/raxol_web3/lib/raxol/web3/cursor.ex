defmodule Raxol.Web3.Cursor do
  @moduledoc """
  An opaque, authenticated, scope-bound pagination cursor.

  ADR-0038 decision 8. Every surveyed upstream paginates differently, and one
  of them caps `start + limit` at 10000, so ADR-0033 §3 requires an opaque
  cursor in both directions rather than an offset we cannot honour uniformly.
  Blockscout's own `next_page_params` proves the point from the other side:
  measured on 2026-09-13, address transactions returns seven keys, `tokens`
  four, `token-transfers` and `logs` two, and `nft` three. A typed cursor would
  need a struct per endpoint.

  Opaque is not the same as safe, and this is where an earlier draft of the
  design was wrong. Base64 is an encoding, not integrity protection, and the
  decoded map's keys become upstream QUERY PARAMETERS. Without a MAC, anyone
  who can hand a cursor back can decode it, add or rewrite keys, and re-encode:
  the next upstream request then carries attacker-chosen parameters, from our
  address, under our rate-limit budget, with our API key attached where one is
  configured. On an MCP surface the cursor is model-visible and model-settable,
  so untrusted upstream text reaches our outbound query string through a value
  a model copies forward.

  So three things, and all three are needed:

    1. **A MAC** over the whole payload, under this node's key
       (`Raxol.Web3.Tables.cursor_key/0`). A cursor that does not verify is
       refused before anything is decoded.
    2. **Scope binding**: the origin id and the endpoint travel inside the
       signed payload and must match the call. A verified cursor from
       `token-transfers` on chain 1 is still refused on `logs`, or on chain 8453.
    3. **A per-endpoint key allowlist**, applied after verification. Signing
       proves we minted it; it does not prove the upstream will not be handed a
       parameter it never offered. The allowlist is data, a key list per
       endpoint, not a struct per endpoint, so it does not reintroduce the
       coupling §3 refused.

  `items_count` is stripped rather than carried. Decision 8 says no offset-like
  field is exposed, and a Base64 payload is readable by anyone holding it, so
  "not exposed" has to mean "not there". It is safe to drop: measured on
  2026-09-14, paging `/api/v2/addresses/{hash}/transactions` with and without
  `items_count` returns the identical next page, so the keyset fields are what
  page and the counter is decoration.

  ## Wire format

      v1.<base64url(payload)>.<base64url(mac)>

  The version prefix is outside the MAC input only in the sense that it is part
  of the signed string: the MAC covers `"v1." <> payload`, so a downgrade to a
  future `v0` cannot be forged by relabelling.
  """

  alias Raxol.Web3.Tables

  @version "v1"

  # The digest `mac/1` signs with, and the size every signature it produces
  # has, read off the same digest rather than written down twice.
  @digest :sha256
  @mac_size :crypto.hash_info(@digest).size

  # Measured from live responses on 2026-09-13, minus `items_count`. An
  # endpoint absent from this table cannot mint or accept a cursor at all,
  # which is deliberate: `/api/v2/search` paginates with nulls and bracketed
  # keys, and nothing in the backend contract pages through search results.
  @allowed %{
    address_transactions: ~w(block_number fee hash index inserted_at value),
    address_tokens: ~w(id value fiat_value),
    address_token_transfers: ~w(index block_number),
    address_logs: ~w(index block_number),
    address_nft: ~w(token_type token_contract_address_hash token_id),
    # The one entry here that was not measured, and it needs no measuring:
    # a JSON-RPC node has no `next_page_params`, so `Raxol.Web3.Backend.JSONRPC`
    # mints this cursor from its own walk state. The key set is ours by
    # construction rather than an upstream's, which is why the allowlist is
    # exactly the two numbers that walk carries: the next `fromBlock` and the
    # head the walk was pinned to when it started.
    rpc_logs: ~w(from_block to_block),
    # Measured from a live `getSignaturesForAddress` response on 2026-09-14.
    # Solana's public RPC has no `next_page_params` either, but unlike the
    # entry above the key set is still the upstream's: `before` takes a
    # signature, and a signature is what every item in the response carries.
    # Paging two pages of two for one mainnet account returned disjoint
    # signatures, so one key is the whole keyset. `until` is deliberately
    # absent: it bounds the far end of a walk, and a cursor that could carry
    # it would let a held cursor narrow somebody else's walk to nothing.
    solana_address_signatures: ~w(before),
    # Measured from live TronGrid responses on 2026-09-14. Both tools page on
    # one opaque `fingerprint` and nothing else: the response's `meta` carries
    # `at`, `page_size`, `fingerprint` and a `links.next` which is a full
    # upstream URL with the fingerprint already in its query string. The URL is
    # not in the keyset, deliberately, because a cursor that carried a target
    # would let a held cursor choose where the next request goes; it is read
    # only as the signal that another page exists.
    tron_account_transactions: ~w(fingerprint),
    tron_account_trc20_transfers: ~w(fingerprint),
    # Measured from live TronScan responses on 2026-09-14. This is the one
    # upstream in the survey that pages on a bare offset, and it refuses
    # `start + limit > 10000` with an error inside a successful tool result.
    # The ceiling is the reason ADR-0033 decision 3 refuses to expose an
    # offset at all: the pair lives inside the signed payload, the caller
    # never sees either number, and a walk that would cross the ceiling fails
    # rather than being silently rewound to a page it already had.
    tronscan_account_tokens: ~w(start limit),
    tronscan_transfer_list: ~w(start limit),
    # Measured from live `POST /v0/holdings/state` responses on 2026-09-14.
    # `after` is an integer offset into one ACS snapshot, and the response's
    # `next_page_token` is the next one; `after: 8926540676` answered
    # `next_page_token: 8926540890`, while an `after` outside the snapshot's
    # range is a 400. That is why `migration_id` and `record_time` are in the
    # keyset beside it: an offset into one snapshot means nothing in another,
    # and pinning both is what keeps a held cursor walking the snapshot it was
    # minted against rather than drifting onto today's. `owner_party_ids` is
    # deliberately absent, because a cursor that carried the subject of the
    # query would let a held cursor ask about somebody else's party.
    canton_holdings_state: ~w(after migration_id record_time)
  }

  @type t :: String.t()

  @type endpoint ::
          :address_transactions
          | :address_tokens
          | :address_token_transfers
          | :address_logs
          | :address_nft
          | :rpc_logs
          | :solana_address_signatures
          | :tron_account_transactions
          | :tron_account_trc20_transfers
          | :tronscan_account_tokens
          | :tronscan_transfer_list
          | :canton_holdings_state

  @type reason ::
          :malformed
          | :bad_signature
          | :wrong_scope
          | {:unknown_endpoint, atom()}
          | {:unexpected_key, String.t()}

  @doc "The endpoints that may mint or accept a cursor."
  @spec endpoints() :: [endpoint()]
  def endpoints, do: Map.keys(@allowed)

  @doc """
  Mint a cursor for an upstream `next_page_params` map.

  `nil` in, `nil` out: the last page has no cursor, and making the caller
  branch on that would put the same `if` in every list callback.
  """
  @spec encode(map() | nil, String.t(), endpoint()) :: t() | nil
  def encode(nil, _origin_id, _endpoint), do: nil

  def encode(params, origin_id, endpoint) when is_map(params) do
    payload =
      %{"o" => origin_id, "e" => Atom.to_string(endpoint), "p" => keyset(params, endpoint)}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signed = @version <> "." <> payload

    signed <> "." <> Base.url_encode64(mac(signed), padding: false)
  end

  @doc """
  Verify a cursor and return the upstream parameters it carries.

  Refuses, in order: a shape that is not ours, a MAC that does not verify, a
  scope that is not this origin and endpoint, and a key the endpoint does not
  declare. The order matters, because every check after the first is performed
  on bytes we have already proven we minted.
  """
  @spec decode(t(), String.t(), endpoint()) :: {:ok, map()} | {:error, reason()}
  def decode(cursor, origin_id, endpoint) when is_binary(cursor) do
    with {:ok, signed, payload} <- split(cursor),
         :ok <- verify(signed, payload),
         {:ok, decoded} <- decode_payload(signed),
         :ok <- check_scope(decoded, origin_id, endpoint) do
      check_keys(decoded["p"], endpoint)
    end
  end

  def decode(_cursor, _origin_id, _endpoint), do: {:error, :malformed}

  defp split(cursor) do
    case String.split(cursor, ".") do
      [@version, payload, signature] ->
        case Base.url_decode64(signature, padding: false) do
          {:ok, mac} when byte_size(mac) == @mac_size -> {:ok, @version <> "." <> payload, mac}
          {:ok, _wrong_size} -> {:error, :bad_signature}
          :error -> {:error, :malformed}
        end

      _other ->
        {:error, :malformed}
    end
  end

  defp verify(signed, mac) do
    # Constant time, because a cursor is attacker-supplied and a byte-at-a-time
    # comparison leaks the signature one byte at a time.
    #
    # The SIZE is `split/1`'s business rather than this function's, because
    # `:crypto.hash_equals/2` raises `badarg` on two binaries of different
    # sizes instead of answering false. A model-supplied cursor carrying a
    # one-byte signature therefore raised out of `decode/3`, and
    # `Raxol.MCP.Registry.invoke_with_breaker/3` turned that raise into a
    # model-visible exception term plus a breaker failure: the closed taxonomy
    # this module documents was bypassed by the one input class it exists for.
    # By here the two binaries are the same size, and the comparison is the
    # only thing left to do.
    if :crypto.hash_equals(mac(signed), mac), do: :ok, else: {:error, :bad_signature}
  end

  defp decode_payload(@version <> "." <> payload) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"o" => _, "e" => _, "p" => params} = decoded} when is_map(params) <-
           Jason.decode(json) do
      {:ok, decoded}
    else
      _unusable -> {:error, :malformed}
    end
  end

  defp check_scope(%{"o" => origin_id, "e" => endpoint}, origin_id, endpoint_atom) do
    if endpoint == Atom.to_string(endpoint_atom), do: :ok, else: {:error, :wrong_scope}
  end

  defp check_scope(_decoded, _origin_id, _endpoint), do: {:error, :wrong_scope}

  defp check_keys(params, endpoint) do
    case Map.fetch(@allowed, endpoint) do
      :error ->
        {:error, {:unknown_endpoint, endpoint}}

      {:ok, allowed} ->
        case Enum.find(Map.keys(params), &(&1 not in allowed)) do
          nil -> {:ok, params}
          key -> {:error, {:unexpected_key, key}}
        end
    end
  end

  # Minting takes only what this endpoint pages on, rather than refusing a
  # response that carries more: an upstream that adds a field should not break
  # paging, and `items_count` is absent from every allowlist above, so taking
  # the allowlist is what strips it.
  defp keyset(params, endpoint) do
    Map.take(params, Map.get(@allowed, endpoint, []))
  end

  defp mac(signed), do: :crypto.mac(:hmac, @digest, Tables.cursor_key(), signed)
end
