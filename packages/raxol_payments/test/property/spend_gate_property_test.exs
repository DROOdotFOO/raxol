defmodule Raxol.Payments.SpendGatePropertyTest do
  @moduledoc """
  Security properties for the spend choke point (`SpendGate` + `Ledger`).

  The invariant that matters for autonomous agents moving real funds: no
  sequence of authorized spends -- sequential or concurrent -- can record more
  than the policy's lifetime cap. The concurrent case pins that the atomic
  `try_spend` reservation has no TOCTOU window.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Ledger, SpendingPolicy}

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("5.00"),
      session_window_ms: 3_600_000,
      approved_domains: nil
    }
  end

  defp amount do
    map(integer(1..150), fn n -> Decimal.div(Decimal.new(n), 100) end)
  end

  # Unique child id so repeated property iterations don't collide on the
  # default `Ledger` child-spec id under the test supervisor.
  defp start_fresh_ledger do
    spec =
      Supervisor.child_spec({Ledger, [name: nil]},
        id: {:ledger, System.unique_integer([:positive])}
      )

    start_supervised!(spec)
  end

  property "no sequence of authorized spends exceeds the lifetime cap" do
    check all(amounts <- list_of(amount(), max_length: 40)) do
      ledger = start_fresh_ledger()
      ctx = %{policy: policy(), ledger: ledger, agent_id: "a"}

      Enum.each(amounts, fn amt ->
        SpendGate.authorize(ctx, amt, target: {:domain, "x.test"})
      end)

      totals = Ledger.get_totals(ledger, "a", policy())

      assert Decimal.compare(totals.lifetime, policy().lifetime_max) != :gt,
             "recorded #{Decimal.to_string(totals.lifetime)} > cap #{Decimal.to_string(policy().lifetime_max)}"
    end
  end

  property "a denied authorize records nothing" do
    # amounts strictly above per_request are always denied
    check all(n <- integer(101..500)) do
      ledger = start_fresh_ledger()
      ctx = %{policy: policy(), ledger: ledger, agent_id: "a"}
      over = Decimal.div(Decimal.new(n), 100)

      assert {:error, {:over_budget, :per_request}} =
               SpendGate.authorize(ctx, over, target: {:domain, "x.test"})

      totals = Ledger.get_totals(ledger, "a", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  test "concurrent authorize never overspends the lifetime cap (no TOCTOU)" do
    ledger = start_supervised!({Ledger, [name: nil]})
    ctx = %{policy: policy(), ledger: ledger, agent_id: "a"}

    # 20 concurrent 0.50 spends against a 5.00 cap: at most 10 may succeed.
    results =
      1..20
      |> Task.async_stream(
        fn _ ->
          SpendGate.authorize(ctx, Decimal.new("0.50"), target: {:domain, "x.test"})
        end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    ok_count = Enum.count(results, &(&1 == :ok))
    totals = Ledger.get_totals(ledger, "a", policy())

    assert ok_count == 10
    assert Decimal.equal?(totals.lifetime, Decimal.new("5.00"))
  end
end
