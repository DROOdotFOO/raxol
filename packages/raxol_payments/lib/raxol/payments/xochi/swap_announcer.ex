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
  `Raxol.Payments.Xochi.SwapRouteStore` keyed by intent id, so the later terminal
  announce can rebuild the full event from only the `intent_id` it observes.
  """

  alias Raxol.Payments.Xochi.{AgentStream, SwapRouteStore}
  alias Raxol.Payments.Xochi.Schemas.{IntentStatus, QuoteRequest, QuoteResponse}

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
        event = execute_event(request, quote, exec)
        SwapRouteStore.remember(event.intent_id, event)
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
    with {:ok, cfg} <- config(context),
         {:ok, base} <- SwapRouteStore.take(intent_id) do
      AgentStream.announce(cfg, terminal_event(base, status))
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Resolve the `AgentStream` config from an Action context, or `:skip` when no
  `topic_id` (or no wallet / announce host) is available.
  """
  @spec config(map()) :: {:ok, map()} | :skip
  def config(context) do
    with %{} = stream <- Map.get(context, :agent_stream),
         topic_id when is_binary(topic_id) and topic_id != "" <-
           Map.get(stream, :topic_id),
         {:ok, wallet} <- Map.fetch(context, :wallet),
         {:ok, url} <- resolve_url(stream, context) do
      {:ok, build_config(stream, url, topic_id, wallet)}
    else
      _ -> :skip
    end
  end

  # -- Private --

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

  defp execute_event(%QuoteRequest{} = request, %QuoteResponse{} = quote, exec) do
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
