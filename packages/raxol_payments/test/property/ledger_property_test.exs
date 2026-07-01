defmodule Raxol.Payments.LedgerPropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.Ledger`. The cumulative-spend cap is
  the load-bearing math behind the entire payments subsystem -- if it
  drifts, an agent under volume can quietly burn past the lifetime
  limit. These properties pin it from several angles.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  # Generators -----------------------------------------------------------

  defp small_amount do
    # Atomic-style integers; keep them small so a long sequence still
    # fits under realistic lifetime caps without rejecting everything.
    map(integer(1..100), &Decimal.new/1)
  end

  defp adversarial_amount do
    # A mix a hostile or hallucinating agent could produce: legitimate
    # positives interleaved with zero, negatives, and non-finite Decimals.
    one_of([
      map(integer(1..100), &Decimal.new/1),
      constant(Decimal.new(0)),
      map(integer(1..100), &Decimal.new(-&1)),
      member_of([
        Decimal.new("NaN"),
        Decimal.new("Infinity"),
        Decimal.new("-Infinity")
      ])
    ])
  end

  defp policy_with_caps do
    gen all(
          per_req <- integer(10..1_000),
          session_extra <- integer(0..10_000),
          lifetime_extra <- integer(0..100_000)
        ) do
      session = per_req + session_extra
      lifetime = session + lifetime_extra

      %SpendingPolicy{
        per_request_max: Decimal.new(per_req),
        session_max: Decimal.new(session),
        lifetime_max: Decimal.new(lifetime),
        # Wide window so session cap is meaningful across the property's
        # generated sequence.
        session_window_ms: 3_600_000
      }
    end
  end

  # Helpers --------------------------------------------------------------

  defp fresh_ledger do
    {:ok, pid} =
      Ledger.start_link(table_name: :"prop_ledger_#{:erlang.unique_integer([:positive])}")

    pid
  end

  defp stop_ledger(pid) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end
  end

  defp run_sequence(ledger, agent_id, policy, amounts) do
    Enum.reduce(amounts, Decimal.new(0), fn amount, acc ->
      case Ledger.try_spend(ledger, agent_id, amount, policy) do
        :ok -> Decimal.add(acc, amount)
        {:over_limit, _} -> acc
      end
    end)
  end

  # Properties -----------------------------------------------------------

  property "sum of accepted spends never exceeds policy.lifetime_max" do
    check all(
            policy <- policy_with_caps(),
            amounts <- list_of(small_amount(), max_length: 50)
          ) do
      ledger = fresh_ledger()

      try do
        total = run_sequence(ledger, :agent_a, policy, amounts)

        assert Decimal.compare(total, policy.lifetime_max) != :gt,
               "accepted total #{Decimal.to_string(total)} exceeded lifetime cap #{Decimal.to_string(policy.lifetime_max)}"
      after
        stop_ledger(ledger)
      end
    end
  end

  property "sum of accepted spends never exceeds session_max within the window" do
    check all(
            policy <- policy_with_caps(),
            amounts <- list_of(small_amount(), max_length: 30)
          ) do
      ledger = fresh_ledger()

      try do
        total = run_sequence(ledger, :agent_b, policy, amounts)

        # Because the test runs faster than session_window_ms, every accepted
        # entry counts against the session bucket.
        assert Decimal.compare(total, policy.session_max) != :gt,
               "accepted total #{Decimal.to_string(total)} exceeded session cap #{Decimal.to_string(policy.session_max)}"
      after
        stop_ledger(ledger)
      end
    end
  end

  property "no single accepted spend exceeds per_request_max" do
    check all(
            policy <- policy_with_caps(),
            amounts <- list_of(small_amount(), max_length: 20)
          ) do
      ledger = fresh_ledger()

      try do
        Enum.each(amounts, fn amount ->
          if Ledger.try_spend(ledger, :agent_c, amount, policy) == :ok do
            assert Decimal.compare(amount, policy.per_request_max) != :gt,
                   "accepted per-request amount #{Decimal.to_string(amount)} > cap #{Decimal.to_string(policy.per_request_max)}"
          end
        end)
      after
        stop_ledger(ledger)
      end
    end
  end

  property "freeze is absorbing: every gated call returns :frozen until unfreeze" do
    check all(
            amounts <- list_of(small_amount(), min_length: 1, max_length: 20),
            policy <- policy_with_caps()
          ) do
      ledger = fresh_ledger()

      try do
        :ok = Ledger.freeze(ledger)

        Enum.each(amounts, fn amount ->
          assert {:over_limit, :frozen} =
                   Ledger.try_spend(ledger, :agent_f, amount, policy)

          assert {:over_limit, :frozen} =
                   Ledger.check_budget(ledger, :agent_f, amount, policy)
        end)

        # No spend was accepted -> history is empty.
        assert Ledger.get_history(ledger, :agent_f) == []
      after
        stop_ledger(ledger)
      end
    end
  end

  property "unfreeze restores behavior identical to never-frozen" do
    check all(
            amounts <- list_of(small_amount(), max_length: 10),
            policy <- policy_with_caps()
          ) do
      # Run the same sequence on two ledgers; one undergoes a freeze/unfreeze
      # cycle before the spends, the other doesn't. Outcomes must match.
      a = fresh_ledger()
      b = fresh_ledger()

      try do
        :ok = Ledger.freeze(a)
        :ok = Ledger.unfreeze(a)

        results_a = Enum.map(amounts, &Ledger.try_spend(a, :x, &1, policy))
        results_b = Enum.map(amounts, &Ledger.try_spend(b, :x, &1, policy))

        assert results_a == results_b
      after
        stop_ledger(a)
        stop_ledger(b)
      end
    end
  end

  property "no adversarial amount can lower the recorded total or be recorded (anti-poisoning)" do
    check all(amounts <- list_of(adversarial_amount(), max_length: 40)) do
      ledger = fresh_ledger()
      policy = SpendingPolicy.unrestricted()

      try do
        {_final, decreases} =
          Enum.reduce(amounts, {Decimal.new(0), []}, fn amount, {prev_total, viols} ->
            _ = Ledger.try_spend(ledger, :agent_p, amount, policy)
            total = Ledger.get_totals(ledger, :agent_p, policy).lifetime

            if Decimal.compare(total, prev_total) == :lt do
              {total, [{amount, prev_total, total} | viols]}
            else
              {total, viols}
            end
          end)

        # A negative amount slipping into the ledger would net the running
        # total downward, freeing budget headroom. The total must only ever
        # rise or hold.
        assert decreases == [], "recorded total decreased: #{inspect(decreases)}"

        # Every entry that made it into the ledger is a real, strictly
        # positive spend -- no zero, negative, or non-finite amount.
        Enum.each(Ledger.get_history(ledger, :agent_p), fn entry ->
          assert Decimal.compare(entry.amount, Decimal.new(0)) == :gt,
                 "non-positive amount recorded: #{Decimal.to_string(entry.amount)}"
        end)
      after
        stop_ledger(ledger)
      end
    end
  end

  property "history length is monotonically non-decreasing across operations" do
    check all(amounts <- list_of(small_amount(), max_length: 30)) do
      ledger = fresh_ledger()
      policy = SpendingPolicy.unrestricted()

      try do
        {_final, lengths} =
          Enum.reduce(amounts, {0, [0]}, fn amount, {prev_len, acc} ->
            _ = Ledger.try_spend(ledger, :agent_h, amount, policy)
            len = length(Ledger.get_history(ledger, :agent_h))

            assert len >= prev_len,
                   "history length went backwards: #{prev_len} -> #{len}"

            {len, [len | acc]}
          end)

        # And the final length equals the count of try_spend calls
        # (unrestricted policy accepts every positive amount).
        assert List.first(lengths) == length(amounts)
      after
        stop_ledger(ledger)
      end
    end
  end
end
