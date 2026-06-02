defmodule Raxol.Payments.PolicyGate do
  @moduledoc """
  Single source of truth for non-budget policy checks.

  Composes `Raxol.Payments.SpendingPolicy.domain_approved?/2` and
  `requires_confirmation?/2` into one decision used by every payment
  entry point. Budget caps (per-request, session window, lifetime) stay
  in `Raxol.Payments.Ledger` so spend recording remains atomic.

  ## Trust model

  * `domain` MUST be the host the agent declared intent toward -- for
    HTTP flows that is the request URL host, not anything supplied by
    the server (challenge body, response headers).
  * `amount` is the server-claimed amount from the protocol challenge,
    so the per-request cap and confirmation threshold are evaluated
    against the server's claim.

  ## Confirmation gate

  When the amount exceeds `policy.require_confirmation_above`, the gate
  consults the caller-supplied `:on_confirm` callback. With no callback
  the gate denies, which is the safe default for non-interactive paths
  (e.g. HTTP 402 auto-pay). Callers that can surface a prompt synchronously
  -- agent Command hooks, interactive shells -- can pass a 2-arity
  function returning `:approve` or `:deny`.
  """

  alias Raxol.Payments.SpendingPolicy

  @type deny_reason ::
          {:domain_not_approved, String.t()}
          | {:requires_confirmation, Decimal.t(), String.t()}

  @type decision :: :ok | {:deny, deny_reason()}

  @type confirm_fn :: (Decimal.t(), String.t() -> :approve | :deny)
  @type opts :: [on_confirm: confirm_fn() | nil]

  @doc """
  Evaluate the non-budget policy gates for a payment attempt.

  Returns `:ok` if the payment may proceed, or `{:deny, reason}` if the
  domain is not approved or the amount requires confirmation that was
  not granted.
  """
  @spec evaluate(SpendingPolicy.t(), Decimal.t(), String.t(), opts()) ::
          decision()
  def evaluate(
        %SpendingPolicy{} = policy,
        %Decimal{} = amount,
        domain,
        opts \\ []
      )
      when is_binary(domain) do
    with :ok <- check_domain(policy, domain) do
      check_confirmation(policy, amount, domain, Keyword.get(opts, :on_confirm))
    end
  end

  defp check_domain(policy, domain) do
    if SpendingPolicy.domain_approved?(policy, domain),
      do: :ok,
      else: {:deny, {:domain_not_approved, domain}}
  end

  defp check_confirmation(policy, amount, domain, on_confirm) do
    if SpendingPolicy.requires_confirmation?(policy, amount) do
      case run_confirmation(on_confirm, amount, domain) do
        :approve -> :ok
        :deny -> {:deny, {:requires_confirmation, amount, domain}}
      end
    else
      :ok
    end
  end

  defp run_confirmation(fun, amount, domain) when is_function(fun, 2) do
    case fun.(amount, domain) do
      :approve -> :approve
      _ -> :deny
    end
  end

  defp run_confirmation(_, _, _), do: :deny
end
