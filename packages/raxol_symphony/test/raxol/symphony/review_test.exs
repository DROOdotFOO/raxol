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
      assert {:error, :insufficient_vendors} = Review.select_reviewer("a", ["a", "b"], avail)
    end

    test "escalates when there is only one candidate" do
      assert {:error, :insufficient_vendors} =
               Review.select_reviewer("a", ["a"], always_available())
    end

    test "escalates when no available candidate differs from the implementer" do
      assert {:error, :insufficient_vendors} =
               Review.select_reviewer("a", ["a", "a"], always_available())
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
