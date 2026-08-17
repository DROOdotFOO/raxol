defmodule Raxol.Payments.Xochi.AgentStream do
  @moduledoc """
  Emit signed swap activity to Xochi's privacy-first live agent stream.

  A user subscribes their browser to a capability-scoped topic and watches their
  own agents execute swaps in real time, with nothing identity-linked persisted
  server-side. When a raxol agent executes a swap under a Mandate, it POSTs a
  signed activity event to the user's topic via `POST /api/agent/announce`. The
  worker relays it (no persistence) to the topic's Durable Object, which fans it
  out to the browser. The client verifies each event's signature against the
  Mandate it holds.

  This module is the agent side of that contract. It byte-matches the Xochi wire
  contract (`packages/shared/src/agentStream.ts` in `xochi-fi/xochi`) so client,
  worker, and agent can never drift.

  ## Capability model

  There is NO auth header. The capability is possession of the `topicId`;
  integrity is the agent's signature, verified authoritatively on the client. An
  attacker who learns a leaked `topicId` can spam the channel but cannot forge a
  row that verifies against an authorized agent's wallet.

  ## Emitting

  Call `announce/2` once when the agent executes a swap under a mandate (on
  execute, and optionally again on terminal status). It is best-effort and
  non-blocking: a failed announce never affects the swap itself. The announce is
  jittered by a small random delay to reduce timing correlation with the agent's
  quote/execute calls.

      config = %{
        xochi_api_url: "https://api.xochi.fi",
        topic_id: "verifytopicabcdef1234",
        wallet: MyAgentWallet
      }

      event = %{
        intent_id: "intent-abc",
        from_chain_id: 8453,
        to_chain_id: 42161,
        from_token: "0x...",
        to_token: "0x...",
        from_amount: "100000000",
        to_amount: "99780000",
        status: "completed",
        ts: 1_700_000_000_000
      }

      :ok = Raxol.Payments.Xochi.AgentStream.announce(config, event)

  ## Capability handoff

  `topic_id` is handed to the agent out of band at Mandate authorization (agent
  config), never derived, never placed inside the signed Mandate envelope (the
  worker parses that and must not learn the topic), and never accompanied by the
  human/delegator wallet. Only the agent's own wallet appears in the payload.

  ## Signing scheme (matches viem `verifyMessage`)

  1. Canonical event: a fixed-order JSON array (no object keys, no whitespace) --
     `[intent_id, from_chain_id, to_chain_id, from_token, to_token, from_amount,
     to_amount, status, ts]`. `to_amount` may be `nil` (`"null"`).
  2. Signed message: `topic_id <> "\\n" <> canonical_event`.
  3. EIP-191 `personal_sign`: keccak256 over
     `"\\x19Ethereum Signed Message:\\n" <> byte_size(message) <> message`, then
     secp256k1, producing a 65-byte `r || s || v` (`v` in {27, 28}), hex
     `0x`-prefixed.
  """

  require Logger

  @default_jitter_ms 250
  @announce_path "/api/agent/announce"

  @type event :: %{
          required(:intent_id) => String.t(),
          required(:from_chain_id) => integer(),
          required(:to_chain_id) => integer(),
          required(:from_token) => String.t(),
          required(:to_token) => String.t(),
          required(:from_amount) => String.t(),
          required(:to_amount) => String.t() | nil,
          required(:status) => String.t(),
          required(:ts) => integer()
        }

  @type config :: %{
          required(:xochi_api_url) => String.t(),
          required(:topic_id) => String.t(),
          required(:wallet) => module(),
          optional(:agent_wallet) => String.t(),
          optional(:mandate_hash) => String.t(),
          optional(:jitter_ms) => non_neg_integer(),
          optional(:req_options) => keyword()
        }

  @doc """
  Announce a swap activity event to the user's topic. Best-effort, non-blocking.

  Returns `:ok` immediately. The build/sign/POST runs in a fire-and-forget
  `Task`, delayed by a small random jitter. Any failure -- config, signing,
  network, or rate limit -- is logged and dropped; it never propagates to the
  caller and never affects the swap.
  """
  @spec announce(config(), event()) :: :ok
  def announce(config, event) do
    jitter = Map.get(config, :jitter_ms, @default_jitter_ms)

    Task.start(fn ->
      if jitter > 0, do: Process.sleep(:rand.uniform(jitter))

      case announce_sync(config, event) do
        {:ok, _status} -> :ok
        {:error, _reason} -> :ok
      end
    end)

    :ok
  end

  @doc """
  Build, sign, and POST the announce synchronously.

  Returns `{:ok, 202}` on success, or `{:error, reason}`:

    * `{:error, :rate_limited}` -- the topic hit its per-topic ceiling (HTTP 429).
      Dropped, not retried.
    * `{:error, {:http, status, body}}` -- any other non-2xx response.
    * `{:error, reason}` -- a build/sign or transport failure.

  Prefer `announce/2` from a live swap path; this exists for tests and for a
  synchronous caller (e.g. asserting a 202 against a local worker).
  """
  @spec announce_sync(config(), event()) :: {:ok, 202} | {:error, term()}
  def announce_sync(config, event) do
    case build_body(config, event) do
      {:ok, body} ->
        config
        |> build_req()
        |> Req.post(url: @announce_path, json: body)
        |> handle_response(config)

      {:error, reason} = err ->
        emit_dropped(config, reason)
        err
    end
  end

  @doc """
  Canonical event serialization: a fixed-order JSON array, no object keys, no
  whitespace. Byte-matches `canonicalizeEvent` in `agentStream.ts`. Do not
  reorder the fields.
  """
  @spec canonical_event(event()) :: String.t()
  def canonical_event(%{} = e) do
    Jason.encode!([
      e.intent_id,
      e.from_chain_id,
      e.to_chain_id,
      e.from_token,
      e.to_token,
      e.from_amount,
      e.to_amount,
      e.status,
      e.ts
    ])
  end

  @doc """
  The exact message the agent signs and the client verifies with viem
  `verifyMessage`. Binds the event to its topic. Matches `agentActivityDigest`.
  """
  @spec digest_message(String.t(), event()) :: String.t()
  def digest_message(topic_id, %{} = event) when is_binary(topic_id) do
    topic_id <> "\n" <> canonical_event(event)
  end

  @doc """
  Sign `digest_message(topic_id, event)` with `wallet` using EIP-191
  `personal_sign`. Returns `{:ok, "0x" <> hex}` (65-byte `r || s || v`).
  """
  @spec sign_event(module(), String.t(), event()) ::
          {:ok, String.t()} | {:error, term()}
  def sign_event(wallet, topic_id, event) do
    digest = Raxol.Payments.Eip191.digest(digest_message(topic_id, event))

    case wallet.sign_hash(digest) do
      {:ok, sig} when byte_size(sig) == 65 ->
        {:ok, "0x" <> Base.encode16(sig, case: :lower)}

      {:ok, sig} ->
        {:error, {:invalid_signature_length, byte_size(sig)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Recover the signer address (lowercased `0x`) from a signature over the topic
  and event. This is exactly the check viem `verifyMessage` runs, so a match
  guarantees the Xochi client accepts the announce.
  """
  @spec recover_signer(String.t(), event(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def recover_signer(topic_id, event, "0x" <> hex),
    do: recover_signer(topic_id, event, hex)

  def recover_signer(topic_id, event, hex)
      when is_binary(hex) and byte_size(hex) == 130 do
    with {:ok, {r, s, recovery_id}} <- decode_signature(hex),
         digest = Raxol.Payments.Eip191.digest(digest_message(topic_id, event)),
         {:ok, pubkey} <- ExSecp256k1.recover(digest, r, s, recovery_id) do
      {:ok, Raxol.Payments.EIP712.address_from_pubkey(pubkey)}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def recover_signer(_topic_id, _event, _sig), do: {:error, :invalid_signature}

  @doc """
  Verify `signature` over `topic_id`/`event` recovers to `expected_wallet`.
  """
  @spec verify(String.t(), event(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def verify(topic_id, event, signature, expected_wallet) do
    case recover_signer(topic_id, event, signature) do
      {:ok, recovered} ->
        if addr_eq?(recovered, expected_wallet),
          do: :ok,
          else: {:error, :signer_mismatch}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Build the announce request body. The `event` object uses camelCase keys (the
  worker validates `AgentAnnounceBodySchema`); the signature is over the
  canonical array, so internal snake_case is irrelevant to it. Never includes
  the human/delegator wallet or the mandate.
  """
  @spec build_body(config(), event()) :: {:ok, map()} | {:error, term()}
  def build_body(%{topic_id: topic_id, wallet: wallet} = config, event) do
    with {:ok, agent_sig} <- sign_event(wallet, topic_id, event) do
      {:ok,
       %{
         "topicId" => topic_id,
         "agentWallet" => Map.get(config, :agent_wallet) || wallet.address(),
         "event" => %{
           "intentId" => event.intent_id,
           "fromChainId" => event.from_chain_id,
           "toChainId" => event.to_chain_id,
           "fromToken" => event.from_token,
           "toToken" => event.to_token,
           "fromAmount" => event.from_amount,
           "toAmount" => event.to_amount,
           "status" => event.status,
           "ts" => event.ts
         },
         "agentSig" => agent_sig
       }}
    end
  end

  # -- Private --

  defp build_req(config) do
    validate_base_url!(config.xochi_api_url)

    [base_url: config.xochi_api_url, receive_timeout: 10_000, retry: false]
    |> Keyword.merge(Map.get(config, :req_options, []))
    |> Req.new()
  end

  defp handle_response({:ok, %Req.Response{status: 202}}, config) do
    emit_announced(config, 202)
    {:ok, 202}
  end

  # Per-topic rate limit: drop rather than retry aggressively. The topic's DO
  # enforces this in memory; backing off hard would only extend the correlation
  # window the jitter exists to shrink.
  defp handle_response({:ok, %Req.Response{status: 429}}, config) do
    Logger.debug("[agent-stream] announce rate limited for topic")
    emit_dropped(config, :rate_limited)
    {:error, :rate_limited}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, config) do
    Logger.warning("[agent-stream] announce failed: HTTP #{status}")
    emit_dropped(config, {:http, status})
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}, config) do
    Logger.warning("[agent-stream] announce transport error: #{inspect(reason)}")

    emit_dropped(config, reason)
    {:error, reason}
  end

  defp emit_announced(config, status) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :agent_stream, :announced],
      %{count: 1},
      telemetry_meta(config, status)
    )
  end

  defp emit_dropped(config, reason) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :agent_stream, :dropped],
      %{count: 1},
      telemetry_meta(config, reason)
    )
  end

  # mandate_hash is the agent's own trace of which delegation authorized the
  # swap. It stays in telemetry only; it never enters the wire payload or the
  # signed message.
  defp telemetry_meta(config, status) do
    %{
      topic_id: Map.get(config, :topic_id),
      mandate_hash: Map.get(config, :mandate_hash),
      status: status
    }
  end

  # secp256k1 group order halved. A canonical (low-s) signature has
  # 1 <= s <= n/2. Because (r, n - s) recovers the same key, accepting a high-s
  # signature would let a third party malleate a posted announce into a second
  # signature over the same event that still verifies, so the relay fans out a
  # duplicate row. Reject high-s; our own signer (libsecp256k1) already emits
  # low-s, and the client's viem check is over the canonical form.
  @secp256k1_half_n 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0

  # EIP-191/personal_sign is canonical: v is 27 or 28 (never the raw 0/1 recovery
  # id here) and s is low. Enforce both so a malformed or malleated signature is
  # rejected rather than recovered. ExSecp256k1.recover wants a 0/1 recovery id.
  defp decode_signature(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}
      when v in [27, 28] ->
        if low_s?(s),
          do: {:ok, {r, s, v - 27}},
          else: {:error, :malleable_signature}

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp low_s?(<<s::unsigned-big-256>>), do: s >= 1 and s <= @secp256k1_half_n

  defp addr_eq?(a, b), do: String.downcase(a) == String.downcase(b)

  defp validate_base_url!("https://" <> _), do: :ok
  defp validate_base_url!("http://localhost" <> _), do: :ok
  defp validate_base_url!("http://127.0.0.1" <> _), do: :ok

  defp validate_base_url!(url) do
    raise ArgumentError,
          "Xochi agent-stream requires HTTPS base_url, got: #{inspect(url)}"
  end
end
