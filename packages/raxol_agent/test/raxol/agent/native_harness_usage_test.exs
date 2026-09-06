defmodule Raxol.Agent.NativeHarnessUsageTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.BenchmarkProfile

  # Fake vendor wire, keyed the way ADR-0034 measured pi: "input"/"output"
  # rather than raxol's "input_tokens"/"output_tokens". It reports usage two
  # ways so both halves of the NativeHarness contract are drivable from one
  # fixture: a cumulative figure on the terminal frame, and a per-call figure on
  # each LLM round trip.
  @settled_with_usage ~s({"type":"agent_settled","content":"done","usage":{"input":100,"output":50}})
  @settled_bare ~s({"type":"agent_settled","content":"done"})
  @call_one ~s({"type":"call_end","usage":{"input":1200,"output":80}})
  @call_two ~s({"type":"call_end","usage":{"input":1500,"output":40}})

  # A driver that honours the contract: usage leaves `parse_line/1` in raxol's
  # vocabulary, and per-call figures are summed for the run.
  defmodule TranslatingDriver do
    @moduledoc false
    @behaviour Raxol.Agent.NativeHarness

    @impl true
    def executable, do: "fake-vendor-cli"

    @impl true
    def name, do: "Translating"

    @impl true
    def args(_config), do: []

    @impl true
    def parse_line(line) do
      case Jason.decode(line) do
        {:ok, %{"type" => "agent_settled"} = frame} ->
          [{:done, %{content: Map.get(frame, "content", ""), usage: translate(frame["usage"])}}]

        # Per-call usage cannot be emitted as its own `{:done, _}`:
        # `Backend.Native` halts on the first one (native.ex:172, :182-186), so
        # a second event would be dropped and the first would understate the
        # run. The run-level fold in `run/1` is where it lands instead.
        _other ->
          []
      end
    end

    @doc "One vendor usage map in raxol's vocabulary."
    def translate(%{} = usage) do
      %{
        input_tokens: Map.get(usage, "input", 0),
        output_tokens: Map.get(usage, "output", 0)
      }
    end

    def translate(_absent), do: %{}

    @doc """
    Events for a whole run, summing per-call usage into the single `{:done, _}`.

    `parse_line/1` sees one line at a time and cannot accumulate, so a driver
    facing a vendor that bills per call needs run-scoped folding; this fixture
    keeps it here so the arithmetic is assertable.
    """
    def run(lines) do
      total =
        lines
        |> Enum.flat_map(&call_usage/1)
        |> Enum.reduce(%{}, fn usage, acc -> BenchmarkProfile.add_usage(acc, usage) end)

      for line <- lines,
          [{:done, done}] <- [parse_line(line)],
          do: {:done, %{done | usage: total}}
    end

    defp call_usage(line) do
      case Jason.decode(line) do
        {:ok, %{"type" => "call_end", "usage" => usage}} -> [translate(usage)]
        _other -> []
      end
    end
  end

  # The trap the contract exists to close: the vendor's keys, forwarded.
  defmodule PassthroughDriver do
    @moduledoc false
    @behaviour Raxol.Agent.NativeHarness

    @impl true
    def executable, do: "fake-vendor-cli"

    @impl true
    def name, do: "Passthrough"

    @impl true
    def args(_config), do: []

    @impl true
    def parse_line(line) do
      case Jason.decode(line) do
        {:ok, %{"type" => "agent_settled"} = frame} ->
          [
            {:done,
             %{content: Map.get(frame, "content", ""), usage: Map.get(frame, "usage", %{})}}
          ]

        _other ->
          []
      end
    end
  end

  # `flag_unpriced/4` arms the fail-closed halt only when a $0.00 turn burned
  # tokens, and it decides that through this exact expression
  # (code/app.ex:1085-1093). Replicated because it is private there.
  defp billed_tokens?(usage) do
    acc = BenchmarkProfile.add_usage(%{input_tokens: 0, output_tokens: 0}, usage)
    acc.input_tokens > 0 or acc.output_tokens > 0
  end

  defp priced_profile do
    {:ok, profile} =
      BenchmarkProfile.from_env(%{
        "RAXOL_COST_PER_MTOK_IN" => "3.0",
        "RAXOL_COST_PER_MTOK_OUT" => "15.0"
      })

    profile
  end

  describe "a driver that translates usage at the parse boundary" do
    test "raxol's vocabulary survives add_usage/2 with the exact token counts" do
      assert [{:done, done}] = TranslatingDriver.parse_line(@settled_with_usage)
      assert done.usage == %{input_tokens: 100, output_tokens: 50}

      assert BenchmarkProfile.add_usage(%{}, done.usage) == %{
               input_tokens: 100,
               output_tokens: 50
             }
    end

    test "the translated turn prices above CostLedger's record guard" do
      [{:done, done}] = TranslatingDriver.parse_line(@settled_with_usage)
      accumulated = BenchmarkProfile.add_usage(%{}, done.usage)

      cost = BenchmarkProfile.cost_usd(priced_profile(), accumulated)

      # 100/1e6 * 3.0 + 50/1e6 * 15.0, within float noise. What matters to
      # CostLedger.record/4 is that it clears the cost_usd > 0.0 guard
      # (code/cost_ledger.ex:33-34), which the vendor-keyed map does not.
      assert_in_delta cost, 0.00105, 1.0e-9
      assert cost > 0.0
      assert billed_tokens?(done.usage)
    end
  end

  describe "a driver that forwards the vendor's vocabulary" do
    test "vendor keys collapse to zeros through add_usage/2" do
      assert [{:done, done}] = PassthroughDriver.parse_line(@settled_with_usage)
      assert done.usage == %{"input" => 100, "output" => 50}

      # 150 tokens were burned and every consumer reads zero, because
      # add_usage/2 knows only input_tokens/prompt_tokens and
      # output_tokens/completion_tokens (benchmark_profile.ex:114-134).
      assert BenchmarkProfile.add_usage(%{}, done.usage) == %{
               input_tokens: 0,
               output_tokens: 0
             }
    end

    test "the collapse prices the turn at $0.00, so the ledger records nothing" do
      [{:done, done}] = PassthroughDriver.parse_line(@settled_with_usage)
      accumulated = BenchmarkProfile.add_usage(%{}, done.usage)

      # Zero cost fails CostLedger.record/4's cost_usd > 0.0 guard
      # (code/cost_ledger.ex:33-34), so the spend never reaches the ledger.
      assert BenchmarkProfile.cost_usd(priced_profile(), accumulated) == 0.0
    end

    test "flag_unpriced's token check also reads zero, so the halt never arms" do
      [{:done, vendor}] = PassthroughDriver.parse_line(@settled_with_usage)
      [{:done, translated}] = TranslatingDriver.parse_line(@settled_with_usage)

      # This is the second silent failure: the guard that exists to catch a
      # $0.00 turn that burned tokens asks add_usage/2 too, so a vendor-keyed
      # map defeats the ledger and its backstop with one mistake.
      refute billed_tokens?(vendor.usage)
      assert billed_tokens?(translated.usage)
    end
  end

  describe "per-call usage" do
    test "sums across calls rather than taking the last" do
      # The vendor re-sends the conversation each call, so each call's input is
      # separately billed and the run total is the sum.
      assert [{:done, done}] =
               TranslatingDriver.run([@call_one, @call_two, @settled_bare])

      assert done.usage == %{input_tokens: 2700, output_tokens: 120}

      assert BenchmarkProfile.add_usage(%{}, done.usage) == %{
               input_tokens: 2700,
               output_tokens: 120
             }
    end

    test "the last call alone understates the run" do
      # What the rule prevents: reporting the final call's figure loses 1200
      # input tokens, and no consumer can tell.
      last_only = TranslatingDriver.translate(%{"input" => 1500, "output" => 40})

      assert BenchmarkProfile.add_usage(%{}, last_only) == %{
               input_tokens: 1500,
               output_tokens: 40
             }

      [{:done, done}] = TranslatingDriver.run([@call_one, @call_two, @settled_bare])
      assert done.usage.input_tokens > last_only.input_tokens
    end
  end
end
