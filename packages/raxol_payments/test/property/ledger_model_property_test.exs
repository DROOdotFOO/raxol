defmodule Raxol.Payments.LedgerModelPropertyTest do
  @moduledoc """
  Model-based property test for `Raxol.Payments.Ledger`.

  Generates a random sequence of operations -- `spend`, `freeze`,
  `unfreeze`, `history` -- and applies each one to both:

    * the real `Raxol.Payments.Ledger` GenServer, and
    * a pure-Elixir reference model that owns the same intended semantics.

  At every step the two outputs must agree. This catches refactors that
  silently break invariants no example test exercises -- e.g. a freeze
  that fails to block a subsequent record_spend cast, or a try_spend
  whose receipt drifts from the history view.

  The policy is fixed to `unrestricted/0` for every spend so the property
  isolates state-machine behavior from cap arithmetic (P3 covers that).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  # Command shape --------------------------------------------------------

  defp command do
    one_of([
      tuple({constant(:spend), member_of([:a, :b]), integer(1..100)}),
      constant(:freeze),
      constant(:unfreeze),
      tuple({constant(:history), member_of([:a, :b])})
    ])
  end

  defp commands do
    list_of(command(), min_length: 1, max_length: 50)
  end

  # Reference model ------------------------------------------------------

  defp empty_model, do: %{frozen?: false, history: %{}}

  defp model_step({:spend, agent_id, amount}, model) do
    cond do
      model.frozen? ->
        {{:over_limit, :frozen}, model}

      true ->
        new_history =
          Map.update(model.history, agent_id, [amount], &[amount | &1])

        {:ok, %{model | history: new_history}}
    end
  end

  defp model_step(:freeze, model), do: {:ok, %{model | frozen?: true}}
  defp model_step(:unfreeze, model), do: {:ok, %{model | frozen?: false}}

  defp model_step({:history, agent_id}, model) do
    len = Map.get(model.history, agent_id, []) |> length()
    {len, model}
  end

  # Real-Ledger executor -------------------------------------------------

  defp ledger_step({:spend, agent_id, amount}, ledger) do
    Ledger.try_spend(
      ledger,
      agent_id,
      Decimal.new(amount),
      SpendingPolicy.unrestricted()
    )
  end

  defp ledger_step(:freeze, ledger), do: Ledger.freeze(ledger)
  defp ledger_step(:unfreeze, ledger), do: Ledger.unfreeze(ledger)

  defp ledger_step({:history, agent_id}, ledger) do
    Ledger.get_history(ledger, agent_id) |> length()
  end

  # Property -------------------------------------------------------------

  property "Ledger outcomes match the pure-Elixir reference model" do
    check all(cmds <- commands()) do
      ledger =
        case Ledger.start_link(
               table_name:
                 :"model_ledger_#{:erlang.unique_integer([:positive])}"
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      try do
        {final_model, mismatches} =
          Enum.reduce(cmds, {empty_model(), []}, fn cmd, {model, errs} ->
            {model_out, next_model} = model_step(cmd, model)
            real_out = ledger_step(cmd, ledger)

            if model_out == real_out do
              {next_model, errs}
            else
              {next_model, [{cmd, %{model: model_out, real: real_out}} | errs]}
            end
          end)

        assert mismatches == [],
               "model/ledger disagreed:\n" <>
                 Enum.map_join(mismatches, "\n", fn {cmd, %{model: m, real: r}} ->
                   "  on #{inspect(cmd)}: model=#{inspect(m)} real=#{inspect(r)}"
                 end) <>
                 "\nfinal_model=#{inspect(final_model)}"
      after
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end
end
