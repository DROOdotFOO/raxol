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
      Required; absent, every entry point here is a silent no-op.
    * `:xochi_api_url` -- announce host. Optional; defaults to
      `xochi_config.base_url` (the same host the swap ran against).
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

  ## Trust boundary: where and under whose topic a signed row may go

  The `topic_id` is a capability and the announce host is signature-free, so a
  context that names a hostile host or a wrong topic would exfiltrate a signed
  activity row to an attacker or into another user's feed. `config/1` therefore
  fails closed on three axes before it will announce:

    * The announce host must be the swap's own Xochi host, `localhost`, or a
      host on the operator's allowlist (`config :raxol_payments,
      :xochi_announce_hosts`). An injected `agent_stream.xochi_api_url` pointing
      elsewhere is rejected.
    * The `topic_id` must match the Xochi capability format
      (`[A-Za-z0-9_-]{16,64}`), so a truncated or malformed topic never ships.
    * The topic is bound to its authorizing Mandate. When the swap surfaces the
      authorizing mandate hash (`context.authorizing_mandate_hash`), the topic's
      declared `mandate_hash` must equal it. Absent that, a binding-required
      deployment (production by default, or `config :raxol_payments,
      :require_topic_mandate_binding`) still requires the topic to declare which
      mandate it serves. Full cryptographic ownership is a Xochi-side check
      (the worker verifying the signature against the mandate the topic was
      issued for) and lands with the authorization handoff.
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

  # Xochi capability topic format (mirrors TOPIC_ID_RE in the shared contract):
  # 16-64 base64url characters. A topic that does not match never ships.
  @topic_id_re ~r/^[A-Za-z0-9_-]{16,64}$/
  # Announce hosts allowed in addition to the swap's own Xochi host. Localhost
  # covers `wrangler dev`; production is added via config. The swap's own host is
  # always allowed (it is already trusted to move the funds).
  @default_announce_hosts ["api.xochi.fi", "localhost", "127.0.0.1"]

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
  Announce a `stranded` row for an intent whose poll timed out before any
  terminal status. The row was left at its non-terminal execute state, so this
  advances it to a distinct in-doubt state (the client keeps it out of
  completed/failed, which is honest: the origin funds may still settle late).

  Reads the route with `peek/1`, NOT `take/1`: if the intent later resolves to a
  real terminal status on a re-poll, `announce_terminal/3` must still find its
  route. No-op when no `topic_id` is configured or no route is stashed.
  """
  @spec announce_stranded(map(), String.t()) :: :ok
  def announce_stranded(context, intent_id) do
    case config(context) do
      {:ok, cfg} ->
        case SwapRouteStore.peek(intent_id) do
          {:ok, base} ->
            AgentStream.announce(cfg, %{base | status: "stranded", ts: now_ms()})
            :ok

          :error ->
            emit_skipped(context, :no_route)
            :ok
        end

      :skip ->
        :ok
    end
  end

  @doc """
  Resolve the `AgentStream` config from an Action context, or `:skip` when it
  fails a validation. Emits an
  `[:raxol, :payments, :xochi, :agent_stream, :announce_skipped]` telemetry event
  carrying the specific reason (`:not_configured`, `:no_topic_id`,
  `:invalid_topic_id`, `:mandate_binding_required`, `:no_wallet`,
  `:no_announce_host`, `:host_not_allowed`) so a misconfiguration or a rejected
  host/topic is observable rather than a silent no-op. See the "Trust boundary"
  section for the host, topic-format, and Mandate-binding rules.
  """
  @spec config(map()) :: {:ok, map()} | :skip
  def config(context) do
    with {:ok, {stream, topic_id}} <- validate_topic(context),
         {:ok, {wallet, url}} <- validate_target(context, stream) do
      {:ok, build_config(stream, url, topic_id, wallet)}
    else
      {:skip, reason} ->
        emit_skipped(context, reason)
        :skip
    end
  end

  # -- Private --

  # The topic axis: a configured, well-formed topic, bound to its mandate.
  defp validate_topic(context) do
    with {_, %{} = stream} <- {:not_configured, Map.get(context, :agent_stream)},
         {_, topic_id} when is_binary(topic_id) and topic_id != "" <-
           {:no_topic_id, Map.get(stream, :topic_id)},
         {_, true} <- {:invalid_topic_id, valid_topic_id?(topic_id)},
         {_, :ok} <- {:mandate_binding_required, mandate_bound(stream, context)} do
      {:ok, {stream, topic_id}}
    else
      {reason, _} -> {:skip, reason}
    end
  end

  # The target axis: a signing wallet and an allowlisted announce host.
  defp validate_target(context, stream) do
    with {_, {:ok, wallet}} <- {:no_wallet, Map.fetch(context, :wallet)},
         {_, {:ok, url}} <- {:no_announce_host, resolve_url(stream, context)},
         {_, :ok} <- {:host_not_allowed, allowed_host(url, context)} do
      {:ok, {wallet, url}}
    else
      {reason, _} -> {:skip, reason}
    end
  end

  defp valid_topic_id?(topic_id), do: Regex.match?(@topic_id_re, topic_id)

  # The announce host must be the swap's own Xochi host (already trusted to move
  # the funds), or a host the operator explicitly allowlisted. A context-injected
  # override to any other host is rejected so a signed row cannot be exfiltrated.
  defp allowed_host(url, context) do
    host = url_host(url)
    base_host = url_host(get_in(context, [:xochi_config, :base_url]))

    cond do
      is_nil(host) -> :error
      host == base_host -> :ok
      host in configured_hosts() -> :ok
      true -> :error
    end
  end

  defp configured_hosts do
    Application.get_env(
      :raxol_payments,
      :xochi_announce_hosts,
      @default_announce_hosts
    )
  end

  defp url_host(url) when is_binary(url), do: URI.parse(url).host
  defp url_host(_url), do: nil

  # Bind the topic to the mandate that authorized the swap. When the swap
  # surfaces that mandate (`context.authorizing_mandate_hash`), the topic's
  # declared `mandate_hash` must match it byte-for-byte (case-insensitively) so a
  # topic issued for one mandate cannot ride a swap under another. Absent that
  # context, a binding-required deployment still requires the topic to name a
  # mandate; otherwise the check is a no-op.
  defp mandate_bound(stream, context) do
    configured = Map.get(stream, :mandate_hash)
    authorizing = Map.get(context, :authorizing_mandate_hash)

    cond do
      is_binary(authorizing) and authorizing != "" ->
        ok_if(is_binary(configured) and hash_eq?(configured, authorizing))

      require_mandate_binding?(context) ->
        ok_if(present?(configured))

      true ->
        :ok
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp ok_if(true), do: :ok
  defp ok_if(_false), do: :error

  defp require_mandate_binding?(context) do
    case Map.get(context, :require_topic_mandate_binding) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        Application.get_env(
          :raxol_payments,
          :require_topic_mandate_binding,
          Raxol.Payments.Deployment.production?()
        )
    end
  end

  defp hash_eq?(a, b), do: String.downcase(a) == String.downcase(b)

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

  # An explicit announce host wins; otherwise reuse the swap's Xochi base_url.
  defp resolve_url(stream, context) do
    case Map.get(stream, :xochi_api_url) do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        case get_in(context, [:xochi_config, :base_url]) do
          url when is_binary(url) and url != "" -> {:ok, url}
          _ -> :error
        end
    end
  end

  # Public settlement: disclose the full route. Any other preference (stealth /
  # shielded / unset) settles privately, so the row is redacted to status only.
  defp execute_event(
         %QuoteRequest{} = request,
         %QuoteResponse{} = quote,
         exec,
         topic_id
       ) do
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
  defp settlement_private?(%QuoteRequest{settlement_preference: "public"}),
    do: false

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
