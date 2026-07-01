defmodule Raxol.Payments.SpendingHook do
  @moduledoc """
  CommandHook that enforces spending policy on payment operations.

  Integrates with the agent harness hook chain to check budget
  before allowing payment-related commands. Requires a Ledger and
  SpendingPolicy to be configured in the hook context.

  ## Setup

      defmodule MyAgent do
        use Raxol.Agent

        def command_hooks do
          Raxol.Payments.SpendingHook.set_config(%{
            ledger: :my_ledger,
            policy: SpendingPolicy.dev()
          })

          [Raxol.Payments.SpendingHook]
        end
      end
  """

  @compile {:no_warn_undefined, Raxol.Agent.CommandHook}
  @behaviour Raxol.Agent.CommandHook

  alias Raxol.Payments.Directive.Pay
  alias Raxol.Payments.{Ledger, PolicyGate, SpendingPolicy}

  @type config :: %{
          required(:ledger) => GenServer.server(),
          required(:policy) => SpendingPolicy.t(),
          optional(:on_confirm) => PolicyGate.confirm_fn()
        }

  @doc """
  Store spending hook config in the process dictionary.
  """
  @spec set_config(config()) :: :ok
  def set_config(config) do
    Process.put({__MODULE__, :config}, config)
    :ok
  end

  @doc """
  Get the active config from the process dictionary.
  """
  @spec get_config() :: config() | nil
  def get_config do
    Process.get({__MODULE__, :config})
  end

  @spec pre_execute(map(), map()) :: {:ok, map()} | {:deny, term()}
  @impl Raxol.Agent.CommandHook
  def pre_execute(command, context) do
    case get_config() do
      nil ->
        {:ok, command}

      config ->
        check_payment_command(command, context, config)
    end
  end

  @spec post_execute(map(), term(), map()) :: {:ok, term()}
  @impl Raxol.Agent.CommandHook
  def post_execute(command, result, context) do
    case get_config() do
      nil ->
        {:ok, result}

      config ->
        maybe_refund_payment(command, result, config, context)
        {:ok, result}
    end
  end

  # -- Private --

  # Reserve the spend atomically in the gate so two concurrent Pay commands
  # cannot both pass a check before either records (the TOCTOU that a separate
  # check-then-record opens). `try_spend` checks the caps and records in one
  # GenServer call; `post_execute` refunds only if the command then failed.
  defp check_payment_command(%Pay{} = pay, context, config) do
    gate_opts = [on_confirm: Map.get(config, :on_confirm)]

    with :ok <- PolicyGate.evaluate(config.policy, pay.amount, pay.domain, gate_opts),
         :ok <-
           Ledger.try_spend(
             config.ledger,
             payment_agent_id(pay, context),
             pay.amount,
             config.policy,
             pay.meta || %{}
           ) do
      {:ok, pay}
    else
      {:deny, _reason} = denied -> denied
      {:over_limit, limit_type} -> {:deny, {:over_budget, limit_type, pay.amount}}
    end
  end

  defp check_payment_command(command, _context, _config), do: {:ok, command}

  # The budget was reserved atomically in `pre_execute`. Refund it only when the
  # command failed, so a failed payment does not permanently consume budget; a
  # success needs no further recording. The refund uses the same agent id the
  # reservation did so session and lifetime totals net back out.
  defp maybe_refund_payment(%Pay{} = pay, result, config, context) do
    if failed?(result) do
      Ledger.release(config.ledger, payment_agent_id(pay, context), pay.amount, pay.meta || %{})
    end

    :ok
  end

  defp maybe_refund_payment(_command, _result, _config, _context), do: :ok

  defp payment_agent_id(%Pay{} = pay, context) do
    pay.agent_id || Map.get(pay.meta || %{}, :agent_id) || Map.get(context, :agent_id, :unknown)
  end

  defp failed?({:error, _}), do: true
  defp failed?(_), do: false
end
