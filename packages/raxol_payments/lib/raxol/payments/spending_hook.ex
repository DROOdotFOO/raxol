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
  def post_execute(command, result, _context) do
    case get_config() do
      nil ->
        {:ok, result}

      config ->
        maybe_record_payment(command, result, config)
        {:ok, result}
    end
  end

  # -- Private --

  defp check_payment_command(%{type: type} = command, context, config)
       when type in [:async, :shell] do
    command
    |> extract_payment_info()
    |> apply_gate(command, context, config)
  end

  defp check_payment_command(command, _context, _config), do: {:ok, command}

  defp apply_gate(nil, command, _context, _config), do: {:ok, command}

  defp apply_gate({amount, domain}, command, context, config) do
    agent_id = Map.get(context, :agent_id, :unknown)
    gate_opts = [on_confirm: Map.get(config, :on_confirm)]

    with :ok <- PolicyGate.evaluate(config.policy, amount, domain, gate_opts),
         :ok <-
           Ledger.check_budget(config.ledger, agent_id, amount, config.policy) do
      {:ok, command}
    else
      {:deny, _reason} = denied -> denied
      {:over_limit, limit_type} -> {:deny, {:over_budget, limit_type, amount}}
    end
  end

  # Payment info is attached to command data as a tagged map.
  # The auto-pay plugin wraps the original data with payment metadata.
  defp extract_payment_info(%{
         data: %{__payment__: %{amount: amount, domain: domain}}
       }) do
    {amount, domain}
  end

  defp extract_payment_info(_command), do: nil

  defp maybe_record_payment(
         %{data: %{__payment__: %{amount: amount} = meta}},
         _result,
         config
       ) do
    agent_id = Map.get(meta, :agent_id, :unknown)
    Ledger.record_spend(config.ledger, agent_id, amount, meta)
  end

  defp maybe_record_payment(_command, _result, _config), do: :ok
end
