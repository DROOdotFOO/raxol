defmodule Raxol.Payments.Xochi.SwapAnnouncer do
  @moduledoc """
  Bridge from the Xochi swap Actions to `Raxol.Payments.Xochi.AgentStream`.

  When an agent runs a swap under a Mandate and the caller has configured a
  capability `topic_id`, this emits a signed activity row to the user's live
  feed: once on execute (non-terminal) and once at terminal status, so the row
  advances on its own. Both emits are best-effort and non-blocking -- a failed or
  unconfigured announce never touches the swap.

  ## Configuration (per-Mandate, out of band)

  The Actions read an optional `:agent_stream` key from their context:

      context = %{
        wallet: MyAgentWallet,
        xochi_config: %{base_url: "https://api.xochi.fi", auth: {:mandate, w}},
        agent_stream: %{topic_id: "abc...", mandate_hash: "0x..."}
      }

  Fields:

    * `:topic_id` -- the capability handed to the agent out of band at Mandate
      authorization (see the "Capability handoff" section of `AgentStream`).
      Required; must match Xochi's topic format (16-64 char base64url). A missing
      or malformed topic makes every entry point here a silent no-op.
    * `:xochi_api_url` -- announce host. Optional; defaults to
      `xochi_config.base_url` (the same host the swap ran against). An explicit
      value is honored only when its host matches that swap host or the
      `config :raxol_payments, :agent_stream_hosts` allowlist; otherwise the
      announce is skipped rather than sent to an unrecognized host.
    * `:mandate_hash` -- telemetry-only, never on the wire. Optional.
    * `:jitter_ms`, `:req_options` -- forwarded to `AgentStream` when present.

  The signing wallet and the on-wire `agentWallet` come from the context
  `:wallet` (the agent's own wallet). The delegator/human wallet never appears.

  The route (chains, tokens, amounts) is captured at execute and stashed in
  `Raxol.Payments.Xochi.SwapRouteStore` keyed by the real intent id, so the later
  terminal announce can rebuild the event from only the `intent_id` it observes.

  ## Privacy: only public settlements disclose the route

  Safe by default: only a `settlement_preference` of `"public"` announces the
  full route (chains, tokens, amounts, real intent id). A `"stealth"` or
  `"shielded"` settlement (and any unset/unknown preference) announces a
  redacted row instead: the status and timestamp only, under a topic-salted
  pseudo intent id, with no amounts, chains, or tokens. Announcing the exact
  delivered amount or the real intent id of a private swap would let an observer
  join the feed row against the on-chain stealth announcement or shielded note
  and defeat the very unlinkability those modes exist for. The execute and
  terminal rows share the same pseudo id so the browser still merges them into
  one advancing row.
  """

  alias Raxol.Payments.Xochi.{AgentStream, SwapRouteStore}
  alias Raxol.Payments.Xochi.Schemas.{IntentStatus, QuoteRequest, QuoteResponse}

  # Placeholder token for a redacted row. The wire schema requires a non-empty
  # string (fromToken/toToken min length 1), so a private swap cannot send "".
  @redacted_token "redacted"
  # Chain ids and amount for a redacted row. 0 is a valid wire int; "0"/nil are
  # valid wire amounts (toAmount is nullable). None reveal the real route.
  @redacted_chain 0
  @redacted_from_amount "0"

  # Capability topic id format, byte-matching Xochi's `TOPIC_ID_RE`
  # (`agentStream.ts`): 128-bit random, base64url, 16-64 chars. A topic that does
  # not match is rejected before anything is announced.
  @topic_id_re ~r/^[A-Za-z0-9_-]{16,64}$/

  @doc """
  Announce the execute (non-terminal) event and stash the route for the terminal
  announce. No-op when no `topic_id` is configured. Always returns `:ok`.
  """
  @spec announce_execute(map(), QuoteRequest.t(), QuoteResponse.t(), map()) ::
          :ok
  def announce_execute(
        context,
        %QuoteRequest{} = request,
        %QuoteResponse{} = quote,
        exec
      ) do
    case config(context) do
      {:ok, cfg} ->
        event = execute_event(request, quote, exec, cfg.topic_id)
        # Key the stash by the REAL intent id: PollXochiStatus only ever observes
        # that. For a private swap the event's own `intent_id` is the pseudo id,
        # so the two must not be conflated.
        SwapRouteStore.remember(exec.intent_id, event)
        AgentStream.announce(cfg, event)
        :ok

      :skip ->
        :ok
    end
  end

  @doc """
  Announce the terminal event, rebuilt from the stashed route plus the observed
  terminal status. No-op when no `topic_id` is configured or no route was stashed
  for `intent_id`. Always returns `:ok`.
  """
  @spec announce_terminal(map(), String.t(), IntentStatus.t()) :: :ok
  def announce_terminal(context, intent_id, %IntentStatus{} = status) do
    case config(context) do
      {:ok, cfg} ->
        case SwapRouteStore.take(intent_id) do
          {:ok, base} ->
            AgentStream.announce(cfg, terminal_event(base, status))
            :ok

          # No stash for this intent: the execute never announced (unconfigured
          # then), or the route already expired. Emitting a blank-route terminal
          # would clobber the row, so skip and record why.
          :error ->
            emit_skipped(context, :no_route)
            :ok
        end

      # config/1 already emitted the specific skip reason.
      :skip ->
        :ok
    end
  end

  @doc """
  Resolve the `AgentStream` config from an Action context, or `:skip` when no
  `topic_id` (or no wallet / announce host) is available. Emits an
  `[:raxol, :payments, :xochi, :agent_stream, :announce_skipped]` telemetry event
  carrying the specific reason so a misconfiguration is observable rather than a
  silent no-op.
  """
  @spec config(map()) :: {:ok, map()} | :skip
  def config(context) do
    with {_, %{} = stream} <- {:not_configured, Map.get(context, :agent_stream)},
         {_, topic_id} when is_binary(topic_id) and topic_id != "" <-
           {:no_topic_id, Map.get(stream, :topic_id)},
         {_, true} <- {:bad_topic_id, Regex.match?(@topic_id_re, topic_id)},
         {_, {:ok, wallet}} <- {:no_wallet, Map.fetch(context, :wallet)},
         {_, {:ok, url}} <- {:no_announce_host, resolve_url(stream, context)} do
      {:ok, build_config(stream, url, topic_id, wallet)}
    else
      {reason, _} ->
        emit_skipped(context, reason)
        :skip
    end
  end

  # -- Private --

  # Diagnostics for the best-effort no-op paths. AgentStream emits :dropped once
  # an announce is attempted and fails; this covers the layer above, where an
  # announce is never attempted at all (misconfigured topic/wallet/host, or a
  # missing/expired route). mandate_hash and the delegator wallet never appear.
  defp emit_skipped(context, reason) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :agent_stream, :announce_skipped],
      %{count: 1},
      %{reason: reason, topic_id: topic_id_hint(context)}
    )
  end

  defp topic_id_hint(context) do
    case Map.get(context, :agent_stream) do
      %{topic_id: topic_id} -> topic_id
      _ -> nil
    end
  end

  defp build_config(stream, url, topic_id, wallet) do
    %{xochi_api_url: url, topic_id: topic_id, wallet: wallet}
    |> put_optional(:mandate_hash, Map.get(stream, :mandate_hash))
    |> put_optional(:jitter_ms, Map.get(stream, :jitter_ms))
    |> put_optional(:req_options, Map.get(stream, :req_options))
  end

  # Resolve the announce host. An explicit `xochi_api_url` is honored only when
  # its host matches the swap's own Xochi host or an operator-configured
  # allowlist; otherwise the swap's `xochi_config.base_url` is used. This stops a
  # poisoned context from redirecting signed announces (event + agentWallet +
  # signature) to an attacker-controlled endpoint.
  defp resolve_url(stream, context) do
    swap_url = get_in(context, [:xochi_config, :base_url])

    case Map.get(stream, :xochi_api_url) do
      url when is_binary(url) and url != "" ->
        if announce_host_allowed?(url, swap_url), do: {:ok, url}, else: :error

      _ ->
        case swap_url do
          url when is_binary(url) and url != "" -> {:ok, url}
          _ -> :error
        end
    end
  end

  defp announce_host_allowed?(url, swap_url) do
    host = uri_host(url)
    host != nil and (host == uri_host(swap_url) or host in allowed_hosts())
  end

  defp allowed_hosts do
    Application.get_env(:raxol_payments, :agent_stream_hosts, [])
  end

  defp uri_host(url) when is_binary(url), do: URI.parse(url).host
  defp uri_host(_url), do: nil

  # Public settlement: disclose the full route. Any other preference (stealth /
  # shielded / unset) settles privately, so the row is redacted to status only.
  defp execute_event(%QuoteRequest{} = request, %QuoteResponse{} = quote, exec, topic_id) do
    if settlement_private?(request) do
      redacted_event(pseudo_id(topic_id, exec.intent_id), execute_status(exec))
    else
      %{
        intent_id: exec.intent_id,
        from_chain_id: request.from_chain_id,
        to_chain_id: request.to_chain_id,
        from_token: request.from_token,
        to_token: request.to_token,
        from_amount: request.from_amount,
        to_amount: quote.to_amount,
        status: execute_status(exec),
        ts: now_ms()
      }
    end
  end

  # Only an explicit "public" preference discloses the route. Everything else,
  # including a nil/unknown preference, is treated as private (fail safe).
  defp settlement_private?(%QuoteRequest{settlement_preference: "public"}), do: false
  defp settlement_private?(%QuoteRequest{}), do: true

  # A redacted row carries no amounts, chains, or tokens and a pseudo intent id.
  # Fields are set to the least-revealing values the wire schema still accepts.
  defp redacted_event(pseudo_intent_id, status) do
    %{
      intent_id: pseudo_intent_id,
      from_chain_id: @redacted_chain,
      to_chain_id: @redacted_chain,
      from_token: @redacted_token,
      to_token: @redacted_token,
      from_amount: @redacted_from_amount,
      to_amount: nil,
      status: status,
      ts: now_ms()
    }
  end

  # A stable, topic-salted pseudonym for the real intent id: the same real id
  # under the same topic always yields the same pseudo id (so the execute and
  # terminal rows merge in the browser), but without the topic secret it cannot
  # be tied back to the real intent id or to on-chain settlement state.
  defp pseudo_id(topic_id, intent_id) do
    :crypto.hash(:sha256, [topic_id, "\n", to_string(intent_id)])
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  # Rebuild the terminal event from the stashed route, overriding only the status
  # and timestamp. The delivered amount is the quote's `to_amount` captured at
  # execute; the status becomes the observed terminal one (completed / failed /
  # refunded / expired).
  defp terminal_event(base, %IntentStatus{status: status}) do
    %{base | status: to_string(status), ts: now_ms()}
  end

  # In-doubt executes are still in flight, not terminal -- surface them as a
  # non-terminal status so the row shows pending until polling resolves it.
  defp execute_status(%{reconciling: true}), do: "executing"
  defp execute_status(%{status: :completed}), do: "completed"

  defp execute_status(%{status: status})
       when status in [:executing, :settling, :pending],
       do: to_string(status)

  defp execute_status(_exec), do: "submitted"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp now_ms, do: System.system_time(:millisecond)
end
