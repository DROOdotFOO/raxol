defmodule Raxol.Payments.LedgerTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  setup do
    {:ok, ledger} = Ledger.start_link(table_name: :"ledger_#{:erlang.unique_integer()}")
    %{ledger: ledger}
  end

  describe "record_spend/4 and get_history/3" do
    test "records and retrieves spend entries", %{ledger: ledger} do
      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.05"), %{domain: "api.test.com"})

      # Give cast time to process
      :timer.sleep(10)

      entries = Ledger.get_history(ledger, "agent_1")
      assert length(entries) == 1
      assert Decimal.equal?(hd(entries).amount, Decimal.new("0.05"))
    end

    test "returns empty list for unknown agent", %{ledger: ledger} do
      assert Ledger.get_history(ledger, "unknown") == []
    end

    test "respects limit option", %{ledger: ledger} do
      for i <- 1..5 do
        :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.01"), %{i: i})
      end

      :timer.sleep(10)

      entries = Ledger.get_history(ledger, "agent_1", limit: 3)
      assert length(entries) == 3
    end
  end

  describe "check_budget/4" do
    test "allows spend within limits", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("10.00"),
        lifetime_max: Decimal.new("100.00"),
        session_window_ms: 3_600_000
      }

      assert :ok = Ledger.check_budget(ledger, "agent_1", Decimal.new("0.50"), policy)
    end

    test "denies per-request over limit", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("0.10"),
        session_max: Decimal.new("10.00"),
        lifetime_max: Decimal.new("100.00"),
        session_window_ms: 3_600_000
      }

      assert {:over_limit, :per_request} =
               Ledger.check_budget(ledger, "agent_1", Decimal.new("0.50"), policy)
    end

    test "denies session over limit", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("0.10"),
        lifetime_max: Decimal.new("100.00"),
        session_window_ms: 3_600_000
      }

      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.08"), %{})
      :timer.sleep(10)

      assert {:over_limit, :session} =
               Ledger.check_budget(ledger, "agent_1", Decimal.new("0.05"), policy)
    end

    test "denies lifetime over limit", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("100.00"),
        lifetime_max: Decimal.new("0.10"),
        session_window_ms: 3_600_000
      }

      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.08"), %{})
      :timer.sleep(10)

      assert {:over_limit, :lifetime} =
               Ledger.check_budget(ledger, "agent_1", Decimal.new("0.05"), policy)
    end
  end

  describe "try_spend/5" do
    test "atomically checks and records a spend within limits", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        session_window_ms: 60_000,
        lifetime_max: Decimal.new("100.00")
      }

      assert :ok =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("0.50"), policy, %{
                 domain: "example.com"
               })

      entries = Ledger.get_history(ledger, "agent_1")
      assert length(entries) == 1
      assert Decimal.equal?(hd(entries).amount, Decimal.new("0.50"))
    end

    test "rejects spend over per_request limit", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("0.10"),
        session_max: Decimal.new("5.00"),
        session_window_ms: 60_000,
        lifetime_max: Decimal.new("100.00")
      }

      assert {:over_limit, :per_request} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("0.50"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "rejects spend over session limit after prior spends", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("0.30"),
        session_window_ms: 60_000,
        lifetime_max: Decimal.new("100.00")
      }

      assert :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("0.20"), policy)
      assert :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("0.08"), policy)

      assert {:over_limit, :session} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("0.05"), policy)

      entries = Ledger.get_history(ledger, "agent_1")
      assert length(entries) == 2

      total = Enum.reduce(entries, Decimal.new(0), &Decimal.add(&1.amount, &2))
      assert Decimal.equal?(total, Decimal.new("0.28"))
    end

    test "concurrent safety -- total recorded never exceeds session_max", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("0.20"),
        session_max: Decimal.new("1.00"),
        session_window_ms: 60_000,
        lifetime_max: Decimal.new("100.00")
      }

      # Each task gets unique metadata so ETS :bag does not dedup
      # entries that land on the same millisecond timestamp.
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Ledger.try_spend(ledger, "agent_c", Decimal.new("0.10"), policy, %{seq: i})
          end)
        end

      results = Task.await_many(tasks, 5_000)

      ok_count = Enum.count(results, &(&1 == :ok))
      over_count = Enum.count(results, &match?({:over_limit, _}, &1))
      assert ok_count + over_count == 20

      # At most 10 spends of $0.10 fit within $1.00 session_max
      assert ok_count <= 10
      assert ok_count >= 1

      entries = Ledger.get_history(ledger, "agent_c")
      total = Enum.reduce(entries, Decimal.new(0), &Decimal.add(&1.amount, &2))
      assert Decimal.compare(total, Decimal.new("1.00")) in [:lt, :eq]
    end
  end

  describe "invalid amounts" do
    setup do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        session_window_ms: 60_000,
        lifetime_max: Decimal.new("100.00")
      }

      %{policy: policy}
    end

    test "try_spend rejects a negative amount and records nothing", %{
      ledger: ledger,
      policy: policy
    } do
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("-1.00"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "try_spend rejects a zero amount", %{ledger: ledger, policy: policy} do
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("0"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "check_budget rejects a negative amount", %{ledger: ledger, policy: policy} do
      assert {:over_limit, :invalid_amount} =
               Ledger.check_budget(ledger, "agent_1", Decimal.new("-0.01"), policy)
    end

    test "try_spend rejects non-finite amounts without raising", %{
      ledger: ledger,
      policy: policy
    } do
      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("Infinity"), policy)

      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("NaN"), policy)

      assert Ledger.get_history(ledger, "agent_1") == []
    end

    test "a rejected negative amount cannot lower a prior total", %{
      ledger: ledger,
      policy: policy
    } do
      assert :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("0.50"), policy)

      assert {:over_limit, :invalid_amount} =
               Ledger.try_spend(ledger, "agent_1", Decimal.new("-0.50"), policy)

      totals = Ledger.get_totals(ledger, "agent_1", policy)
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end
  end

  describe "get_totals/3" do
    test "returns session and lifetime totals", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("10.00"),
        session_max: Decimal.new("100.00"),
        lifetime_max: Decimal.new("1000.00"),
        session_window_ms: 3_600_000
      }

      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.05"), %{})
      :ok = Ledger.record_spend(ledger, "agent_1", Decimal.new("0.10"), %{})
      :timer.sleep(10)

      totals = Ledger.get_totals(ledger, "agent_1", policy)
      assert Decimal.equal?(totals.session, Decimal.new("0.15"))
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.15"))
    end

    test "returns zero for unknown agent", %{ledger: ledger} do
      policy = SpendingPolicy.dev()
      totals = Ledger.get_totals(ledger, "unknown", policy)
      assert Decimal.equal?(totals.session, Decimal.new("0"))
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "intent-keyed reservation release" do
    setup %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("10.00"),
        session_max: Decimal.new("100.00"),
        lifetime_max: Decimal.new("1000.00"),
        session_window_ms: 3_600_000
      }

      # Reserve a spend the way the SpendGate does, then tag it with the intent id
      # the execute dispatched (as ExecuteXochiIntent does on success).
      :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("1.00"), policy, %{})
      :ok = Ledger.tag_reservation(ledger, "agent_1", "intent_1", Decimal.new("1.00"))
      %{policy: policy}
    end

    test "release_by_intent reverses the reservation exactly once", ctx do
      %{ledger: ledger, policy: policy} = ctx

      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy).lifetime, "1.00")

      assert :released = Ledger.release_by_intent(ledger, "agent_1", "intent_1")
      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy).lifetime, "0")

      # A re-poll of an already-refunded intent must not release again -- that
      # would under-count spend and hand back real headroom.
      assert :noop = Ledger.release_by_intent(ledger, "agent_1", "intent_1")
      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy).lifetime, "0")
    end

    test "release_by_intent is a no-op for an untagged intent", %{ledger: ledger} do
      assert :noop = Ledger.release_by_intent(ledger, "agent_1", "never_tagged")
    end

    test "forget_reservation drops the tag so no release can follow", ctx do
      %{ledger: ledger, policy: policy} = ctx

      :ok = Ledger.forget_reservation(ledger, "agent_1", "intent_1")
      # Cast ordering: a following call is serialized behind it.
      assert :noop = Ledger.release_by_intent(ledger, "agent_1", "intent_1")
      # The spend stands -- forget does not refund.
      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy).lifetime, "1.00")
    end

    test "a freeze does not block releasing a refund", ctx do
      %{ledger: ledger, policy: policy} = ctx

      :ok = Ledger.freeze(ledger)
      assert :released = Ledger.release_by_intent(ledger, "agent_1", "intent_1")
      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy).lifetime, "0")
    end

    test "a non-positive or empty tag is ignored", %{ledger: ledger} do
      :ok = Ledger.tag_reservation(ledger, "agent_1", "zero", Decimal.new("0"))
      :ok = Ledger.tag_reservation(ledger, "agent_1", "", Decimal.new("1.00"))
      assert :noop = Ledger.release_by_intent(ledger, "agent_1", "zero")
      assert :noop = Ledger.release_by_intent(ledger, "agent_1", "")
    end
  end
end
