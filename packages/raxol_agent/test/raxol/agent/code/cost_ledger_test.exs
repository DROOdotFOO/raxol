defmodule Raxol.Agent.Code.CostLedgerTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.CostLedger

  # raxol_agent does not depend on raxol_payments, so in this package's
  # test env the Ledger module is absent and every call must degrade to
  # its no-op result. The wired end-to-end path is covered from the
  # raxol_payments suite (which has both packages).

  test "record/4 is a no-op without a ledger or a positive cost" do
    assert :ok = CostLedger.record(nil, "a", 1.0, %{})
    assert :ok = CostLedger.record(:some_ledger, "a", 0.0, %{})
    assert :ok = CostLedger.record(:some_ledger, "a", -1.0, %{})
  end

  test "check/3 passes without a ledger or policy" do
    assert :ok = CostLedger.check(nil, "a", %{})
    assert :ok = CostLedger.check(:some_ledger, "a", nil)
  end

  test "totals_text/3 is nil without a ledger or policy" do
    assert CostLedger.totals_text(nil, "a", %{}) == nil
    assert CostLedger.totals_text(:some_ledger, "a", nil) == nil
  end

  test "with a ledger ref but no raxol_payments loaded, everything degrades" do
    refute CostLedger.available?()
    assert :ok = CostLedger.record(:some_ledger, "a", 1.0, %{})
    assert :ok = CostLedger.check(:some_ledger, "a", %{fake: :policy})
    assert CostLedger.totals_text(:some_ledger, "a", %{fake: :policy}) == nil
  end
end
