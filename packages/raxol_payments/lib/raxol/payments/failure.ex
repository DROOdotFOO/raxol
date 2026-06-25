defmodule Raxol.Payments.Failure do
  @moduledoc """
  Normalized payment failure surfaced to the caller (agent, LLM, or human).

  Every payment error path collapses to a small closed set of reasons so the
  surface can render a clear sentence and decide whether a retry is worth it,
  instead of leaking a raw HTTP tuple or an `inspect/1` dump. `from/1` maps any
  internal error term (quote miss, terminal intent status, HTTP error, spend
  gate denial, validation error) onto a `%Failure{}`.

  The struct carries:

  * `:reason` -- one of the closed reason atoms below.
  * `:message` -- a human sentence safe to show a user.
  * `:retryable?` -- whether an immediate retry could plausibly succeed.
  * `:detail` -- the original error term, kept for logs and debugging.

  `String.Chars` returns the message; `Inspect` renders `reason: message`, so a
  generic surface that `to_string`s or `inspect`s the error still shows prose.
  """

  @enforce_keys [:reason, :message, :retryable?]
  defstruct [:reason, :message, :retryable?, :detail]

  @type reason ::
          :no_liquidity
          | :not_filled
          | :expired
          | :refunded
          | :settlement_failed
          | :timeout
          | :over_budget
          | :requires_confirmation
          | :insufficient_balance
          | :route_unsupported
          | :slippage
          | :rejected
          | :stealth_keys_required
          | :sign_failed
          | :method_mismatch
          | :invalid_request
          | :config_error
          | :network
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          message: String.t(),
          retryable?: boolean(),
          detail: term()
        }

  # Riddler structured error codes -> reason. Codes appear in the quote `reason`
  # field or an HTTP error body `{"error": code}`.
  @code_reasons %{
    "insufficient_liquidity" => :no_liquidity,
    "no_available_bridge" => :route_unsupported,
    "route_not_supported" => :route_unsupported,
    "chain_not_supported" => :route_unsupported,
    "excessive_price_impact" => :slippage,
    "intent_expired" => :expired,
    "intent_already_filled" => :rejected,
    "insufficient_balance" => :insufficient_balance,
    "validation_failed" => :invalid_request,
    "stealth_keys_required" => :stealth_keys_required
  }

  @transport_atoms [:closed, :econnrefused, :nxdomain, :enetunreach, :ehostunreach]

  @doc """
  Normalize any payment error term into a `%Failure{}`. Idempotent: passing a
  `%Failure{}` returns it unchanged.
  """
  @spec from(term()) :: t()
  def from(%__MODULE__{} = failure), do: failure

  # Terminal intent status (from PollXochiStatus): {:settlement, status, error}.
  def from({:settlement, status, error}), do: settlement_failure(status, error)

  # Quote could not be filled.
  def from({:cannot_solve, reason}), do: quote_failure(reason)

  # Execution / funding wrappers: unwrap and classify the inner reason.
  def from({:execute_failed, reason}), do: from(reason)
  def from({:deposit_broadcast_failed, reason}), do: from(reason)

  # HTTP error from the Xochi/Relay client.
  def from({:http, status, body}), do: http_failure(status, body)

  # Wallet signing.
  def from({:sign_failed, reason}),
    do: build(:sign_failed, "The wallet could not sign the transfer.", false, reason)

  def from(:no_eip712_data),
    do:
      build(:invalid_request, "The quote did not include signable data.", false, :no_eip712_data)

  # Spend gate / ledger.
  def from({:over_budget, type}),
    do: build(:over_budget, "This spend exceeds the #{type} limit.", false, {:over_budget, type})

  def from({:deny, reason}),
    do:
      build(
        :rejected,
        "The spending policy rejected this payment (#{deny_text(reason)}).",
        false,
        reason
      )

  def from({:requires_confirmation, _amount} = detail),
    do:
      build(
        :requires_confirmation,
        "This payment needs explicit confirmation before it can proceed.",
        false,
        detail
      )

  # Stealth meta-address / keys.
  def from(:stealth_meta_address_required),
    do: stealth_keys_failure(:stealth_meta_address_required)

  def from({:stealth_keys_required, _} = detail), do: stealth_keys_failure(detail)
  def from({:invalid_meta_address, _} = detail), do: stealth_keys_failure(detail)

  # Routing / settlement selection.
  def from({:not_xochi_route, _} = detail),
    do: build(:route_unsupported, "This transfer does not route through Xochi.", false, detail)

  def from({:not_relay_route, _} = detail),
    do:
      build(
        :route_unsupported,
        "This transfer does not route through the Tron rail.",
        false,
        detail
      )

  def from({:invalid_settlement, _} = detail),
    do: build(:invalid_request, "The settlement type is not valid.", false, detail)

  # The quote's chosen payment method is wrong for the token (e.g. ERC-3009 for a
  # non-USDC token would be a silently invalid signature).
  def from({:method_mismatch, :erc3009_requires_usdc} = detail),
    do:
      build(
        :method_mismatch,
        "The quote selected ERC-3009, which is USDC-only, but this transfer is not USDC.",
        false,
        detail
      )

  def from({:method_mismatch, _} = detail),
    do:
      build(
        :method_mismatch,
        "The quote's payment method is incompatible with the transfer.",
        false,
        detail
      )

  # The signable authorization the solver served did not match the intended
  # transfer (wrong signer/token/chain, or a value above what was intended).
  # Refuse to sign rather than authorize an attacker-controlled origin pull.
  def from({:authorization_mismatch, _} = detail),
    do:
      build(
        :rejected,
        "The quote's signable authorization did not match the requested transfer; refusing to sign.",
        false,
        detail
      )

  # Request validation.
  def from({:invalid_wallet, _} = detail), do: invalid_request(detail)
  def from({:invalid_from_token, _} = detail), do: invalid_request(detail)
  def from({:invalid_to_token, _} = detail), do: invalid_request(detail)
  def from({:invalid_chain_id, _} = detail), do: invalid_request(detail)

  # Relay (Tron) route and address validation.
  def from({:invalid_route, _} = detail),
    do: build(:route_unsupported, "This Tron route is not valid.", false, detail)

  def from({:invalid_from_address, _} = detail),
    do: invalid_request(detail)

  def from({:invalid_to_address, _} = detail),
    do: invalid_request(detail)

  # Configuration.
  def from({:missing_context, key}),
    do:
      build(
        :config_error,
        "Payment is not configured: missing #{key}.",
        false,
        {:missing_context, key}
      )

  # Polling timed out.
  def from(:timeout),
    do:
      build(
        :timeout,
        "Timed out waiting for the transfer to settle. It may still complete; poll again.",
        true,
        :timeout
      )

  # Anything else: transient transport errors become :network, the rest :unknown.
  def from(reason), do: network_or_unknown(reason)

  # -- Builders for each family --

  defp settlement_failure(:completed, _error),
    do: build(:unknown, "The transfer reported completion as a failure.", false, :completed)

  defp settlement_failure(:expired, error),
    do:
      build(
        :expired,
        "The quote expired before it could be filled. Request a fresh quote and retry.",
        true,
        error
      )

  defp settlement_failure(:refunded, error),
    do: build(:refunded, "The transfer failed and the funds were refunded.", false, error)

  defp settlement_failure(:settlement_failed, error),
    do: build(:settlement_failed, "Settlement failed after execution.", false, error)

  defp settlement_failure(_status, error), do: failed_settlement(error)

  defp failed_settlement(error) when is_binary(error) and error != "" do
    cond do
      contains?(error, ["liquid"]) ->
        build(
          :no_liquidity,
          "No solver could fill this transfer (insufficient liquidity).",
          false,
          error
        )

      contains?(error, ["slippage", "price impact"]) ->
        build(
          :slippage,
          "Price moved beyond the allowed slippage. Retry with a fresh quote.",
          true,
          error
        )

      true ->
        build(:not_filled, "The order did not fill: #{error}", false, error)
    end
  end

  defp failed_settlement(error),
    do: build(:not_filled, "The order did not fill.", false, error)

  defp quote_failure(reason) when is_binary(reason) and reason != "" do
    case Map.get(@code_reasons, reason) do
      nil -> classify_quote_text(reason)
      mapped -> from_mapped(mapped, reason)
    end
  end

  defp quote_failure(reason),
    do: build(:no_liquidity, "No solver could fill this transfer.", false, reason)

  defp classify_quote_text(reason) do
    cond do
      contains?(reason, ["liquid"]) ->
        build(
          :no_liquidity,
          "No solver could fill this transfer (insufficient liquidity).",
          false,
          reason
        )

      contains?(reason, ["route", "unsupported", "chain"]) ->
        build(:route_unsupported, "This route is not supported.", false, reason)

      contains?(reason, ["slippage", "price impact"]) ->
        build(
          :slippage,
          "Price moved beyond the allowed slippage. Retry with a fresh quote.",
          true,
          reason
        )

      true ->
        build(:no_liquidity, "No solver could fill this transfer.", false, reason)
    end
  end

  defp http_failure(status, body) do
    cond do
      reason = mapped_code(body) ->
        from_mapped(reason, {:http, status, body})

      status == 429 or status >= 500 ->
        build(
          :network,
          "The payment service is unavailable (HTTP #{status}). Retry shortly.",
          true,
          {:http, status}
        )

      status == 404 ->
        build(
          :not_filled,
          "The intent was not found (it may have expired).",
          false,
          {:http, status}
        )

      true ->
        build(
          :invalid_request,
          "The payment service rejected the request (HTTP #{status}).",
          false,
          {:http, status, body}
        )
    end
  end

  defp from_mapped(:no_liquidity, detail),
    do:
      build(
        :no_liquidity,
        "No solver could fill this transfer (insufficient liquidity).",
        false,
        detail
      )

  defp from_mapped(:route_unsupported, detail),
    do: build(:route_unsupported, "This route is not supported.", false, detail)

  defp from_mapped(:slippage, detail),
    do:
      build(
        :slippage,
        "Price moved beyond the allowed slippage. Retry with a fresh quote.",
        true,
        detail
      )

  defp from_mapped(:expired, detail),
    do: build(:expired, "The quote expired. Request a fresh quote and retry.", true, detail)

  defp from_mapped(:rejected, detail),
    do:
      build(:rejected, "The intent was already filled and cannot be re-executed.", false, detail)

  defp from_mapped(:insufficient_balance, detail),
    do:
      build(:insufficient_balance, "Insufficient balance to cover this transfer.", false, detail)

  defp from_mapped(:invalid_request, detail),
    do: build(:invalid_request, "The payment request was invalid.", false, detail)

  defp from_mapped(:stealth_keys_required, detail), do: stealth_keys_failure(detail)

  defp network_or_unknown(reason) do
    if transport_error?(reason) do
      build(
        :network,
        "A network error reached the payment service. This is usually transient; retry.",
        true,
        reason
      )
    else
      build(:unknown, "The payment failed for an unexpected reason.", false, reason)
    end
  end

  defp stealth_keys_failure(detail),
    do:
      build(
        :stealth_keys_required,
        "Stealth settlement needs the recipient's stealth meta-address (spending and viewing keys).",
        false,
        detail
      )

  defp invalid_request(detail),
    do: build(:invalid_request, "The payment request was invalid.", false, detail)

  # -- Helpers --

  defp mapped_code(body) when is_map(body) do
    code = body["error"] || body["reason"]
    if is_binary(code), do: Map.get(@code_reasons, code), else: nil
  end

  defp mapped_code(_), do: nil

  defp transport_error?(reason) when reason in @transport_atoms, do: true

  defp transport_error?(%{__struct__: struct}),
    do: struct in [Req.TransportError, Mint.TransportError, Req.HTTPError]

  defp transport_error?(_), do: false

  defp deny_text(reason) when is_atom(reason), do: to_string(reason)
  defp deny_text({tag, _}) when is_atom(tag), do: to_string(tag)
  defp deny_text(_), do: "denied"

  defp contains?(text, needles) do
    lower = String.downcase(text)
    Enum.any?(needles, &String.contains?(lower, &1))
  end

  defp build(reason, message, retryable?, detail) do
    %__MODULE__{reason: reason, message: message, retryable?: retryable?, detail: detail}
  end

  defimpl String.Chars do
    def to_string(%{message: message}), do: message
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{reason: reason, message: message}, _opts) do
      concat(["#Raxol.Payments.Failure<", Kernel.to_string(reason), ": ", message, ">"])
    end
  end
end
