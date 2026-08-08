defmodule Raxol.Agent.LlmPricesTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.LlmPrices

  test "known model families resolve to rate pairs" do
    assert {:ok, {3.0, 15.0}} = LlmPrices.rates(:anthropic, "claude-sonnet-5")
    assert {:ok, {15.0, 75.0}} = LlmPrices.rates(:anthropic, "claude-opus-5")
    assert {:ok, {2.5, 10.0}} = LlmPrices.rates(:openai, "gpt-4o")
  end

  test "the longest prefix wins" do
    # gpt-4o-mini must not match the shorter gpt-4o entry.
    assert {:ok, {0.15, 0.6}} = LlmPrices.rates(:openai, "gpt-4o-mini-2024")
  end

  test "variant models do not fall through to their family row" do
    # gpt-5-mini/nano/pro price very differently from base gpt-5; a
    # family-only match would mis-bill a real spending budget.
    assert {:ok, {0.25, 2.0}} = LlmPrices.rates(:openai, "gpt-5-mini")
    assert {:ok, {0.05, 0.4}} = LlmPrices.rates(:openai, "gpt-5-nano")
    assert {:ok, {15.0, 120.0}} = LlmPrices.rates(:openai, "gpt-5-pro")
    # Opus dropped to 5/25 with 4.5; earlier opus keeps the family rate.
    assert {:ok, {5.0, 25.0}} = LlmPrices.rates(:anthropic, "claude-opus-4-5")
    assert {:ok, {15.0, 75.0}} = LlmPrices.rates(:anthropic, "claude-opus-4-1")
  end

  test "unknown models and local backends estimate nothing" do
    assert :unknown = LlmPrices.rates(:ollama, "llama3.3")
    assert :unknown = LlmPrices.rates(:openai, "some-future-model")
    assert :unknown = LlmPrices.rates(nil, nil)
  end
end
