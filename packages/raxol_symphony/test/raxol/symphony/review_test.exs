defmodule Raxol.Symphony.ReviewTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Review
  alias Raxol.Symphony.Review.Contract

  defp always_available, do: fn _ -> true end

  describe "select_reviewer/3" do
    test "picks a different vendor when two are available" do
      assert {:ok, "b"} = Review.select_reviewer("a", ["a", "b"], always_available())
    end

    test "picks the first available different vendor" do
      avail = fn k -> k in ["a", "c"] end
      assert {:ok, "c"} = Review.select_reviewer("a", ["a", "b", "c"], avail)
    end

    test "deduplicates candidate kinds" do
      assert {:ok, "b"} = Review.select_reviewer("a", ["a", "b", "b", "a"], always_available())
    end

    test "escalates when only the implementer is available" do
      avail = fn k -> k == "a" end

      assert {:error, {:insufficient_vendors, _}} =
               Review.select_reviewer("a", ["a", "b"], avail)
    end

    test "escalates when there is only one candidate" do
      assert {:error, {:insufficient_vendors, _}} =
               Review.select_reviewer("a", ["a"], always_available())
    end

    test "escalates when no available candidate differs from the implementer" do
      assert {:error, {:insufficient_vendors, _}} =
               Review.select_reviewer("a", ["a", "a"], always_available())
    end
  end

  # ADR-0034 Gap 5. Before vendor identity these kinds were two distinct
  # candidates and paired happily, so review "passed" with one vendor
  # reviewing itself.
  describe "select_reviewer/3 -- vendor distinctness" do
    test "refuses to pair raxol_agent with raxol_agent_session" do
      assert {:error, {:insufficient_vendors, details}} =
               Review.select_reviewer(
                 "raxol_agent",
                 ["raxol_agent", "raxol_agent_session"],
                 always_available()
               )

      assert details.implementer_vendor == :raxol
      assert details.available_vendors == [:raxol]
      assert details.available_kinds == ["raxol_agent", "raxol_agent_session"]
    end

    test "pairs raxol with codex when both are available" do
      assert {:ok, "codex"} =
               Review.select_reviewer(
                 "raxol_agent",
                 ["raxol_agent", "raxol_agent_session", "codex"],
                 always_available()
               )
    end

    test "a raxol_agent_session implementer cannot be reviewed by raxol_agent either" do
      assert {:error, {:insufficient_vendors, details}} =
               Review.select_reviewer(
                 "raxol_agent_session",
                 ["raxol_agent_session", "raxol_agent"],
                 always_available()
               )

      assert details.implementer_vendor == :raxol
    end

    test "vendorless kinds are never candidates even when reported available" do
      # An inert runner returns :ok for anything, so a "noop" reviewer would
      # approve every diff; "review" is a decorator, not a vendor.
      assert {:error, {:insufficient_vendors, details}} =
               Review.select_reviewer(
                 "raxol_agent",
                 ["raxol_agent", "noop", "review"],
                 always_available()
               )

      assert details.available_kinds == ["raxol_agent"]
    end
  end

  describe "escalation_reason/0" do
    test "is :awaiting_human" do
      assert Review.escalation_reason() == :awaiting_human
    end
  end

  describe "review_prompt/1" do
    test "includes the issue, diff, criteria, and implementer -- but never a workspace" do
      contract =
        Contract.build(
          %Raxol.Symphony.Issue{id: "i", identifier: "MT-9", title: "T", state: "Todo"},
          diff: "the-diff",
          implementer_kind: "codex",
          acceptance_criteria: "must pass tests"
        )

      prompt = Review.review_prompt(contract)

      assert prompt =~ "MT-9"
      assert prompt =~ "the-diff"
      assert prompt =~ "must pass tests"
      assert prompt =~ "codex"
      # review_prompt only ever sees a Contract, which has no path field, so a
      # filesystem path can never leak into the reviewer's input.
      refute prompt =~ "/tmp"
    end

    test "renders placeholders when fields are blank" do
      contract =
        Contract.build(
          %Raxol.Symphony.Issue{id: "i", identifier: "MT-1", title: "T", state: "Todo"},
          []
        )

      prompt = Review.review_prompt(contract)
      assert prompt =~ "(no diff captured)"
      assert prompt =~ "(none provided)"
    end
  end
end
