defmodule Raxol.Agent.LlmPricesTurnCostTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.LlmPrices

  # 2026-09-02 is a Wednesday and 2026-09-05 a Saturday. Every clock here is
  # injected: pricing from observed usage means the same prompt costs
  # different amounts on consecutive runs, so a live call could never assert
  # any of this (ADR-0035).
  defp wed(hour), do: at(~D[2026-09-02], hour)
  defp sat(hour), do: at(~D[2026-09-05], hour)

  defp at(date, hour),
    do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  # The ADR's representative coding turn: 40k input of which 35k cached, 1.5k
  # output, off-peak.
  defp coding_turn do
    %{
      "prompt_tokens" => 40_000,
      "prompt_cache_hit_tokens" => 35_000,
      "prompt_cache_miss_tokens" => 5_000,
      "completion_tokens" => 1_500
    }
  end

  # 1M input tokens, all misses, no output: the cost IS the miss rate, so the
  # peak tier is readable straight off the number.
  defp all_miss do
    %{
      prompt_cache_hit_tokens: 0,
      prompt_cache_miss_tokens: 1_000_000,
      completion_tokens: 0
    }
  end

  describe "a cache split prices exactly" do
    test "hit tokens bill at the hit rate and miss tokens at the miss rate" do
      # 35_000 hits at 0.007 + 5_000 misses at 0.22 + 1_500 out at 0.66.
      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 coding_turn(),
                 wed(12)
               )

      assert_in_delta cost, 0.002335, 1.0e-9
    end

    test "the two tiers are not blended into one input rate" do
      # Same 40k input and 1.5k output, cache split inverted. A blended input
      # rate would price both turns identically; a hit costs ~1/31 of a miss,
      # so the inverted turn costs nearly four times as much.
      inverted = %{
        coding_turn()
        | "prompt_cache_hit_tokens" => 5_000,
          "prompt_cache_miss_tokens" => 35_000
      }

      assert {:ok, exact} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 coding_turn(),
                 wed(12)
               )

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 inverted,
                 wed(12)
               )

      assert_in_delta cost, 0.008725, 1.0e-9
      assert cost > exact
    end

    test "a reported zero-hit count is a fact, not a missing split" do
      # An explicit 0 must price off-peak, not fall through to the peak
      # worst case: the provider said there were no cached reads.
      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 all_miss(),
                 wed(12)
               )

      assert_in_delta cost, 0.22, 1.0e-9
    end
  end

  describe "the conservative fallback" do
    test "no split prices at peak with every input token a miss" do
      # A resumed session's journal payload is string-keyed and may predate
      # the cache fields entirely; the Anthropic-compatible surface never
      # emits them. 40_000 misses at peak 0.44 + 1_500 out at peak 1.32.
      no_split = %{"prompt_tokens" => 40_000, "completion_tokens" => 1_500}

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 no_split,
                 wed(12)
               )

      assert_in_delta cost, 0.01958, 1.0e-9
    end

    test "the fallback is strictly more expensive than the exact figure" do
      no_split = %{"prompt_tokens" => 40_000, "completion_tokens" => 1_500}

      assert {:ok, exact} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 coding_turn(),
                 wed(12)
               )

      assert {:ok, conservative} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 no_split,
                 wed(12)
               )

      # The direction is the whole point: under-metering is unbounded real
      # spend against a budget that never trips.
      assert conservative > exact
    end

    test "an empty trailing usage frame costs nothing rather than guessing" do
      assert {:ok, +0.0} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 %{},
                 wed(12)
               )
    end
  end

  describe "the UTC peak clock" do
    test "the peak windows open at 01:00 and 06:00 UTC" do
      for hour <- [1, 2, 3, 6, 7, 8, 9] do
        assert {:ok, cost} =
                 LlmPrices.turn_cost_usd(
                   :deepseek,
                   "deepseek-v4-flash",
                   all_miss(),
                   wed(hour)
                 )

        assert_in_delta cost, 0.44, 1.0e-9
      end
    end

    test "04:00 and 10:00 UTC are the first off-peak hours" do
      # Half-open at the top: the published windows are 01:00-04:00 and
      # 06:00-10:00, so the closing hour is already off-peak.
      for hour <- [0, 4, 5, 10, 23] do
        assert {:ok, cost} =
                 LlmPrices.turn_cost_usd(
                   :deepseek,
                   "deepseek-v4-flash",
                   all_miss(),
                   wed(hour)
                 )

        assert_in_delta cost, 0.22, 1.0e-9
      end
    end

    test "every weekend hour is peak, including one that is off-peak midweek" do
      # DeepSeek publishes peak hours as Monday-Friday without saying how a
      # weekend hour inside a peak window bills. Resolved upward, and pinned
      # here so a later answer from upstream is a deliberate change.
      for hour <- [2, 12] do
        assert {:ok, cost} =
                 LlmPrices.turn_cost_usd(
                   :deepseek,
                   "deepseek-v4-flash",
                   all_miss(),
                   sat(hour)
                 )

        assert_in_delta cost, 0.44, 1.0e-9
      end
    end
  end

  describe "backend scoping (the Gap 3 fail-closed regressions)" do
    test "rates/2 still refuses a DeepSeek name on a reseller or a free host" do
      assert :unknown = LlmPrices.rates(:openrouter, "deepseek/deepseek-v4-pro")
      assert :unknown = LlmPrices.rates(:llm7, "deepseek-v4-flash")
    end

    test "the scoped entry point refuses them too" do
      # OpenRouter marks the same model up and LLM7 serves it free. Both must
      # keep failing closed rather than borrow the direct vendor's rate.
      assert :unknown =
               LlmPrices.turn_cost_usd(
                 :openrouter,
                 "deepseek/deepseek-v4-pro",
                 coding_turn(),
                 wed(12)
               )

      assert :unknown =
               LlmPrices.turn_cost_usd(
                 :llm7,
                 "deepseek-v4-flash",
                 coding_turn(),
                 wed(12)
               )
    end

    test "a retired alias stays unpriced" do
      # deepseek-chat and deepseek-reasoner were announced retired and still
      # observed routing, so their target is not stable.
      for model <- ["deepseek-chat", "deepseek-reasoner", "deepseek-v3"] do
        assert :unknown =
                 LlmPrices.turn_cost_usd(
                   :deepseek,
                   model,
                   coding_turn(),
                   wed(12)
                 )
      end
    end

    test "the longest scoped prefix wins within a backend" do
      # vision-exp must not fall through to the shorter flash row by accident;
      # it happens to share flash's rates, so assert the pro row differs.
      assert {:ok, flash} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash-vision-exp",
                 coding_turn(),
                 wed(12)
               )

      assert {:ok, pro} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-pro",
                 coding_turn(),
                 wed(12)
               )

      assert_in_delta flash, 0.002335, 1.0e-9
      # 35_000 at 0.022 + 5_000 at 0.66 + 1_500 at 1.98.
      assert_in_delta pro, 0.00704, 1.0e-9
    end
  end

  describe "provider-reported cost" do
    test "a USD cost outranks the scoped table" do
      # The shape an ACP peer sends (Schema.Cost): whoever billed the turn
      # knows its price, and no table can compete with that.
      usage = Map.put(coding_turn(), :cost, %{amount: 0.11544, currency: "USD"})

      assert {:ok, 0.11544} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 usage,
                 wed(12)
               )
    end

    test "GrokBuild's stamped shape carries its currency" do
      # Harness.GrokBuild stamps usage["cost"] from total_cost_usd as
      # %{amount, currency}: the field name asserts USD, and the harness
      # makes that explicit where the name is known.
      usage = %{
        "cost" => %{"amount" => 0.42, "currency" => "USD"},
        "prompt_tokens" => 10,
        "completion_tokens" => 2
      }

      assert {:ok, 0.42} =
               LlmPrices.turn_cost_usd(:xai, "grok-4", usage, wed(12))
    end

    test "a bare number is not a cost: a figure with no currency is a unit bug waiting" do
      usage = %{"cost" => 0.42, "prompt_tokens" => 10, "completion_tokens" => 2}
      assert :unknown = LlmPrices.turn_cost_usd(:xai, "grok-4", usage, wed(12))
    end

    test "an amount a float cannot carry reads as no claim" do
      usage = Map.put(coding_turn(), :cost, %{amount: Integer.pow(10, 400), currency: "USD"})

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(:deepseek, "deepseek-v4-flash", usage, wed(12))

      assert_in_delta cost, 0.002335, 1.0e-9
    end

    test "a non-USD cost is never coerced" do
      usage = Map.put(coding_turn(), :cost, %{amount: 5.0, currency: "EUR"})

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 usage,
                 wed(12)
               )

      # Falls through to the table verbatim rather than being converted.
      assert_in_delta cost, 0.002335, 1.0e-9
    end

    test "a non-USD cost on an unknown model still fails closed" do
      usage = %{
        "cost" => %{"amount" => 5.0, "currency" => "EUR"},
        "prompt_tokens" => 10
      }

      assert :unknown =
               LlmPrices.turn_cost_usd(:llm7, "mystery-9", usage, wed(12))
    end

    test "a non-positive amount is treated as no claim at all" do
      # A zero or negative figure is indistinguishable from an absent one, and
      # a negative session-cost delta should be impossible in the first place.
      for amount <- [0.0, -1.5] do
        usage = Map.put(coding_turn(), :cost, %{amount: amount, currency: "USD"})

        assert {:ok, cost} =
                 LlmPrices.turn_cost_usd(
                   :deepseek,
                   "deepseek-v4-flash",
                   usage,
                   wed(12)
                 )

        assert_in_delta cost, 0.002335, 1.0e-9
      end
    end

    test ":cost is this turn's cost and :session_cost is never added to it" do
      # UsageUpdate documents `cost` as the cumulative session figure, so the
      # ACP adapter emits the per-turn delta as :cost and carries the
      # cumulative through as :session_cost for display. Summing them would
      # re-bill the whole session every turn.
      usage =
        coding_turn()
        |> Map.put(:cost, %{amount: 0.02, currency: "USD"})
        |> Map.put(:session_cost, %{amount: 3.5, currency: "USD"})

      assert {:ok, 0.02} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 usage,
                 wed(12)
               )
    end
  end

  describe "provider-raw cache keys" do
    test "Anthropic's read and creation counts sit beside its input count" do
      # The flat table has no cache dimension, so a hit bills what a miss
      # bills: 1_000 + 9_000 + 500 input at 3.0, plus 200 out at 15.0. This is
      # the over-meter Gap 5 records, now visible instead of silently dropped.
      usage = %{
        "input_tokens" => 1_000,
        "cache_read_input_tokens" => 9_000,
        "cache_creation_input_tokens" => 500,
        "output_tokens" => 200
      }

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :anthropic,
                 "claude-sonnet-5",
                 usage,
                 wed(12)
               )

      assert_in_delta cost, 10_500 / 1_000_000 * 3.0 + 200 / 1_000_000 * 15.0, 1.0e-9
    end

    test "the ACP wire field and the adapter's atom form agree" do
      # The probed frame: 1_997 input, 44_032 cached reads, 52 output. Pricing
      # inputTokens alone under-bills by an order of magnitude.
      wire = %{
        "inputTokens" => 1_997,
        "cachedReadTokens" => 44_032,
        "outputTokens" => 52
      }

      adapter = %{
        input_tokens: 1_997,
        cached_read_tokens: 44_032,
        output_tokens: 52
      }

      expected = 46_029 / 1_000_000 * 3.0 + 52 / 1_000_000 * 15.0

      # "inputTokens" is not a raxol vocabulary key, so only the cached reads
      # are billed on the wire form; the adapter's canonical map carries both.
      assert {:ok, wire_cost} =
               LlmPrices.turn_cost_usd(:anthropic, "claude-sonnet-5", wire, wed(12))

      assert {:ok, adapter_cost} =
               LlmPrices.turn_cost_usd(
                 :anthropic,
                 "claude-sonnet-5",
                 adapter,
                 wed(12)
               )

      assert_in_delta adapter_cost, expected, 1.0e-9
      assert_in_delta wire_cost, 44_032 / 1_000_000 * 3.0, 1.0e-9
    end

    test "a usage map with no cache fields prices exactly as rates/2 did" do
      # The number the /usage estimate has always shown for this turn.
      usage = %{input_tokens: 1_000_000, output_tokens: 100_000}

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(:openai, "gpt-4o", usage, wed(12))

      assert_in_delta cost, 3.5, 1.0e-9
    end

    # A provider's JSON can spell any integer; Jason decodes a 400-digit
    # literal into a bignum that `/ 1_000_000` raises on. Past the largest
    # exactly-representable float the figure is garbage and reads as absent.
    test "a token count a float cannot carry reads as absent, never a crash" do
      huge = Integer.pow(10, 400)

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :openai,
                 "gpt-4o",
                 %{input_tokens: huge, output_tokens: 100_000},
                 wed(12)
               )

      # Only the 100k output tokens at $10/M survive.
      assert_in_delta cost, 1.0, 1.0e-9

      assert {:ok, cost} =
               LlmPrices.turn_cost_usd(
                 :deepseek,
                 "deepseek-v4-flash",
                 %{prompt_cache_hit_tokens: huge, prompt_cache_miss_tokens: 1_000_000},
                 wed(12)
               )

      # The hit count is absent, the miss count still prices (off-peak miss).
      assert_in_delta cost, 0.22, 1.0e-9
    end

    test "an unknown model and a non-map usage both fail closed" do
      assert :unknown =
               LlmPrices.turn_cost_usd(:openai, "some-future-model", %{}, wed(12))

      assert :unknown = LlmPrices.turn_cost_usd(:openai, "gpt-4o", nil, wed(12))
      assert :unknown = LlmPrices.turn_cost_usd(nil, nil, %{}, wed(12))
    end
  end
end
