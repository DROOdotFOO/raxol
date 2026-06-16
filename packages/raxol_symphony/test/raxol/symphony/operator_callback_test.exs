defmodule Raxol.Symphony.OperatorCallbackTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.OperatorCallback

  doctest OperatorCallback

  describe "parse/1 - nullary actions" do
    test "sym:refresh" do
      assert OperatorCallback.parse("sym:refresh") == :refresh
    end

    test "sym:list" do
      assert OperatorCallback.parse("sym:list") == :list
    end

    test "sym:dismiss" do
      assert OperatorCallback.parse("sym:dismiss") == :dismiss
    end
  end

  describe "parse/1 - actions on an issue_id" do
    test "sym:stop:<id>" do
      assert OperatorCallback.parse("sym:stop:iss-1") == {:stop, "iss-1"}
    end

    test "sym:run:<id> (per-run detail)" do
      assert OperatorCallback.parse("sym:run:iss-2") == {:run_detail, "iss-2"}
    end

    test "sym:approve:<id> (legacy)" do
      assert OperatorCallback.parse("sym:approve:iss-3") == {:approve, "iss-3"}
    end

    test "sym:approve with no id (legacy Watch shape)" do
      assert OperatorCallback.parse("sym:approve") == {:approve, ""}
    end
  end

  describe "parse/1 - resume" do
    test "sym:resume:<id>:approved" do
      assert OperatorCallback.parse("sym:resume:iss-1:approved") ==
               {:resume, "iss-1", "approved"}
    end

    test "sym:resume:<id>:rejected" do
      assert OperatorCallback.parse("sym:resume:iss-1:rejected") ==
               {:resume, "iss-1", "rejected"}
    end

    test "non-canonical decisions are forwarded verbatim" do
      assert OperatorCallback.parse("sym:resume:iss-2:escalate") ==
               {:resume, "iss-2", "escalate"}
    end
  end

  describe "parse/1 - unknowns" do
    test "non-sym prefix is unknown" do
      assert OperatorCallback.parse("not-a-sym-callback") ==
               {:unknown, "not-a-sym-callback"}
    end

    test "sym: with unrecognised action is unknown" do
      assert OperatorCallback.parse("sym:nonsense") == {:unknown, "sym:nonsense"}
    end

    test "malformed resume (missing decision) is unknown" do
      assert OperatorCallback.parse("sym:resume:iss-1") ==
               {:unknown, "sym:resume:iss-1"}
    end

    test "empty string is unknown" do
      assert OperatorCallback.parse("") == {:unknown, ""}
    end
  end

  describe "builders + round-trip" do
    test "build_refresh round-trips" do
      assert OperatorCallback.build_refresh() |> OperatorCallback.parse() == :refresh
    end

    test "build_list round-trips" do
      assert OperatorCallback.build_list() |> OperatorCallback.parse() == :list
    end

    test "build_dismiss round-trips" do
      assert OperatorCallback.build_dismiss() |> OperatorCallback.parse() == :dismiss
    end

    test "build_stop round-trips" do
      assert OperatorCallback.build_stop("iss-9") |> OperatorCallback.parse() ==
               {:stop, "iss-9"}
    end

    test "build_run_detail round-trips" do
      assert OperatorCallback.build_run_detail("iss-7") |> OperatorCallback.parse() ==
               {:run_detail, "iss-7"}
    end

    test "build_approve round-trips" do
      assert OperatorCallback.build_approve("iss-5") |> OperatorCallback.parse() ==
               {:approve, "iss-5"}
    end

    test "build_resume round-trips for canonical decisions" do
      for decision <- ["approved", "rejected"] do
        cb = OperatorCallback.build_resume("iss-1", decision)
        assert OperatorCallback.parse(cb) == {:resume, "iss-1", decision}
      end
    end

    test "build_resume round-trips for custom decisions" do
      cb = OperatorCallback.build_resume("iss-2", "escalate-to-cfo")

      assert OperatorCallback.parse(cb) ==
               {:resume, "iss-2", "escalate-to-cfo"}
    end
  end
end
