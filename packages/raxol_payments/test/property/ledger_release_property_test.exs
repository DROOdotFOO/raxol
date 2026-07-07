defmodule Raxol.Payments.LedgerReleasePropertyTest do
  @moduledoc """
  Properties for `Raxol.Payments.Ledger.release/4` -- the refund path that
  compensates a `try_spend/5` reservation whose downstream execution failed
  after signing. `release` inserts a `-amount` entry, so the session/lifetime
  totals net back out.

  The existing cap properties (`ledger_property_test`) never call `release`,
  and the model-based test fixes the policy to `unrestricted` -- so nothing
  today pins release against a real cap. These do: a released amount frees
  EXACTLY that much lifetime budget, no more and no less.

  The policy is shaped so only the lifetime cap binds (per-request admits any
  single generated amount; session is set far above lifetime with a wide
  window), isolating the release netting from the other two caps.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  @agent :a

  defp fresh_ledger do
    {:ok, pid} =
      Ledger.start_link(table_name: :"prop_release_#{:erlang.unique_integer([:positive])}")

    pid
  end

  # Shaped so ONLY the lifetime cap binds: per-request and session are set far
  # above any reachable running sum, so every single amount clears them and the
  # release netting is tested against lifetime alone.
  defp policy(lifetime) do
    %SpendingPolicy{
      per_request_max: Decimal.new(lifetime + 1_000_000),
      session_max: Decimal.new(lifetime + 1_000_000),
      lifetime_max: Decimal.new(lifetime),
      session_window_ms: 3_600_000
    }
  end

  defp command do
    one_of([
      tuple({constant(:spend), integer(1..120)}),
      tuple({constant(:release), integer(1..120)})
    ])
  end

  property "try_spend decisions match the running sum with releases netted in" do
    check all(
            lifetime <- integer(50..300),
            cmds <- list_of(command(), min_length: 1, max_length: 60)
          ) do
      ledger = fresh_ledger()
      policy = policy(lifetime)

      try do
        Enum.reduce(cmds, 0, fn
          {:spend, a}, net ->
            expected = if net + a <= lifetime, do: :ok, else: {:over_limit, :lifetime}
            assert Ledger.try_spend(ledger, @agent, Decimal.new(a), policy) == expected
            if expected == :ok, do: net + a, else: net

          {:release, r}, net ->
            # Well-formed usage: never release more than is currently reserved.
            # (A cast; mailbox order guarantees the next try_spend call sees it.)
            r = min(r, net)
            :ok = Ledger.release(ledger, @agent, Decimal.new(r))
            net - r
        end)
      after
        GenServer.stop(ledger)
      end
    end
  end

  property "release frees exactly the released amount of lifetime budget" do
    check all(
            lifetime <- integer(50..300),
            refund <- integer(1..300)
          ) do
      refund = min(refund, lifetime)
      ledger = fresh_ledger()
      policy = policy(lifetime)

      try do
        # Fill the lifetime cap to the brim.
        assert Ledger.try_spend(ledger, @agent, Decimal.new(lifetime), policy) == :ok

        assert Ledger.try_spend(ledger, @agent, Decimal.new(1), policy) ==
                 {:over_limit, :lifetime}

        # Refund `refund`; exactly that much becomes spendable again.
        :ok = Ledger.release(ledger, @agent, Decimal.new(refund))
        assert Ledger.try_spend(ledger, @agent, Decimal.new(refund), policy) == :ok

        # ...and not a cent more -- we are back at the cap.
        assert Ledger.try_spend(ledger, @agent, Decimal.new(1), policy) ==
                 {:over_limit, :lifetime}
      after
        GenServer.stop(ledger)
      end
    end
  end
end
