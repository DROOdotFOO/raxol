defmodule Raxol.Symphony.PauseReasonTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.PauseReason

  doctest PauseReason

  describe "canonical/0" do
    test "returns the ADR-0018 documented set" do
      assert PauseReason.canonical() == [
               :awaiting_request_response,
               :awaiting_buyer_payment,
               :awaiting_delivery,
               :awaiting_evaluator_approval,
               :awaiting_approval,
               :awaiting_review
             ]
    end

    test "every canonical atom matches the :awaiting_<subject> convention" do
      for atom <- PauseReason.canonical() do
        assert PauseReason.awaiting?(atom),
               "canonical atom #{inspect(atom)} fails awaiting? predicate"
      end
    end
  end

  describe "awaiting?/1" do
    test "true for atoms with :awaiting_ prefix + at least one char" do
      assert PauseReason.awaiting?(:awaiting_buyer_payment)
      assert PauseReason.awaiting?(:awaiting_x)
      assert PauseReason.awaiting?(:awaiting_some_long_subject)
    end

    test "false for the bare :awaiting_ atom (no subject)" do
      refute PauseReason.awaiting?(:awaiting_)
    end

    test "false for other shapes" do
      refute PauseReason.awaiting?(:waiting_for_buyer)
      refute PauseReason.awaiting?(:blocked_on_x)
      refute PauseReason.awaiting?(:needs_review)
      refute PauseReason.awaiting?(nil)
      refute PauseReason.awaiting?(true)
      refute PauseReason.awaiting?("awaiting_x")
      refute PauseReason.awaiting?({:awaiting, :buyer})
    end
  end

  describe "format/1" do
    test "atoms stringify" do
      assert PauseReason.format(:awaiting_buyer_payment) == "awaiting_buyer_payment"
    end

    test "binaries pass through unchanged" do
      assert PauseReason.format("custom-string") == "custom-string"
    end

    test "nil renders as the explicit placeholder" do
      assert PauseReason.format(nil) == "(unspecified)"
    end

    test "non-string non-atom values fall back to inspect/1" do
      assert PauseReason.format({:nonstandard, :tuple}) == "{:nonstandard, :tuple}"
      assert PauseReason.format(42) == "42"
      assert PauseReason.format([:a, :b]) == "[:a, :b]"
    end

    test "round-trips canonical atoms" do
      for atom <- PauseReason.canonical() do
        assert PauseReason.format(atom) == Atom.to_string(atom)
      end
    end
  end
end
