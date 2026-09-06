defmodule Raxol.Agent.Code.AppMeteringTest do
  # The metering path: what a turn_completed frame costs, and what happens
  # when it cannot be costed (ADR-0035).
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Contract
  alias Raxol.Agent.ExecutorConfig

  @env ~w(RAXOL_COST_PER_MTOK_IN RAXOL_COST_PER_MTOK_OUT)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  defp metered_model(opts) do
    opts =
      opts
      |> Keyword.put_new(:runner, fn _id, _prompt, _opts, _app -> self() end)
      |> Keyword.put_new(:sessions_dir, tmp_dir())
      |> Keyword.put_new(
        :executor,
        ExecutorConfig.new(backend: :openai, model: "gpt-4o")
      )

    %{App.init(%{options: opts}) | running?: true}
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "raxol-metering-#{System.os_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"
    )
  end

  defp turn(usage, model) do
    %Contract.Event{
      id: 1,
      ts: 1,
      turn_id: "t1",
      family: :loop,
      type: :turn_completed,
      tier: :durable,
      payload: %{final: false, usage: usage, model: model}
    }
  end

  defp meter(model, usage, billed) do
    {model, []} =
      App.update({:command_result, {:contract_event, turn(usage, billed)}}, model)

    model
  end

  @billed %{input_tokens: 1_000, output_tokens: 100}

  test "an unpriced model under a ledger and a policy halts the turn" do
    model =
      metered_model(ledger: :test_ledger, spending_policy: %{cap_usd: 10.0})
      |> meter(@billed, "mystery-model-9")

    # Zero recorded dollars for real billed tokens is a hole in the cap, so
    # the gate refuses rather than proceeding silently at $0.00.
    assert model.unpriced_model == "mystery-model-9"
    assert model.running? == false
    assert model.status_line =~ "spending halted: no price for mystery-model-9"
    assert model.status_line =~ "RAXOL_COST_PER_MTOK_IN/OUT"
  end

  test "a local session with no ledger keeps its best-effort estimate" do
    model = meter(metered_model([]), @billed, "mystery-model-9")

    assert model.unpriced_model == nil
    assert model.running? == true
    refute model.status_line =~ "spending halted"
  end

  test "a provider-reported USD cost prices a model no table knows" do
    # The reorder's payoff: usage["cost"] was a dead key, so this turn used to
    # halt. Pricing from the raw map before it collapses reads it.
    usage = Map.put(@billed, :cost, %{amount: 0.05, currency: "USD"})

    model =
      metered_model(ledger: :test_ledger, spending_policy: %{cap_usd: 10.0})
      |> meter(usage, "mystery-model-9")

    assert model.unpriced_model == nil
    assert model.running? == true
  end

  test "a non-USD reported cost is not coerced, so the gate still fires" do
    usage = Map.put(@billed, :cost, %{amount: 0.05, currency: "EUR"})

    model =
      metered_model(ledger: :test_ledger, spending_policy: %{cap_usd: 10.0})
      |> meter(usage, "mystery-model-9")

    assert model.unpriced_model == "mystery-model-9"
  end

  test "the env rates still win outright over any table" do
    System.put_env("RAXOL_COST_PER_MTOK_IN", "1.0")
    System.put_env("RAXOL_COST_PER_MTOK_OUT", "2.0")

    model =
      metered_model(ledger: :test_ledger, spending_policy: %{cap_usd: 10.0})
      |> meter(%{input_tokens: 1_000_000, output_tokens: 0}, "mystery-model-9")

    # An operator who states a rate is not second-guessed by a table, and an
    # unpriced model under stated rates is priced, not halted.
    assert model.unpriced_model == nil
    assert model.running? == true
  end

  # -- telemetry (ADR-0036) ---------------------------------------------------
  #
  # Observed through a real `:telemetry.attach_many/4` handler, not reasoned
  # about: `[:raxol, :acp, :zero_updates_turn]` once shipped as dead code
  # behind a guard that a test shim satisfied, so an event that "should" fire
  # is not evidence. The handler runs in the emitting process, which here is
  # the test process, so the pid is passed as handler config rather than read
  # from `self()` inside it.

  @cost_events [
    [:raxol, :agent, :cost, :priced],
    [:raxol, :agent, :cost, :unpriced],
    [:raxol, :agent, :budget, :halt, :unpriced],
    [:raxol, :agent, :budget, :halt, :over_limit]
  ]

  @doc false
  def forward(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp attach_cost_events(context) do
    id = {__MODULE__, context.test}
    :ok = :telemetry.attach_many(id, @cost_events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  describe "cost telemetry" do
    setup :attach_cost_events

    test "a flat-table turn emits :priced with its source and correlation ids" do
      model = meter(metered_model([]), @billed, "gpt-4o")

      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], measurements, metadata}

      # 1000 in at $2.50/Mtok + 100 out at $10/Mtok, the flat gpt-4o row.
      assert_in_delta measurements.cost_usd, 0.0035, 1.0e-9
      assert measurements.input_tokens == 1_000
      assert measurements.output_tokens == 100

      assert metadata.source == :flat_table
      assert metadata.backend == :openai
      assert metadata.model == "gpt-4o"
      assert metadata.kind == :llm_turn
      assert metadata.turn_id == "t1"
      assert metadata.session_id == model.session_key
      assert metadata.ledger? == false

      refute_received {:telemetry, [:raxol, :agent, :cost, :unpriced], _, _}
      refute_received {:telemetry, [:raxol, :agent, :budget, :halt, _], _, _}
    end

    test "a provider-reported cost is attributed to :reported, not to a table" do
      usage = Map.put(@billed, :cost, %{amount: 0.05, currency: "USD"})
      meter(metered_model([]), usage, "gpt-4o")

      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], %{cost_usd: 0.05},
                       %{source: :reported}}
    end

    test "env rates are attributed to :env" do
      System.put_env("RAXOL_COST_PER_MTOK_IN", "1.0")
      System.put_env("RAXOL_COST_PER_MTOK_OUT", "2.0")

      meter(metered_model([]), %{input_tokens: 1_000_000, output_tokens: 0}, "mystery-model-9")

      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], %{cost_usd: cost},
                       %{source: :env}}

      assert_in_delta cost, 1.0, 1.0e-9
    end

    test "an unpriced turn is reported even when no ledger arms the halt" do
      meter(metered_model([]), @billed, "mystery-model-9")

      assert_received {:telemetry, [:raxol, :agent, :cost, :unpriced], measurements, metadata}
      assert measurements == %{input_tokens: 1_000, output_tokens: 100}
      assert metadata.source == :unknown
      assert metadata.model == "mystery-model-9"
      assert metadata.armed? == false

      refute_received {:telemetry, [:raxol, :agent, :cost, :priced], _, _}
      refute_received {:telemetry, [:raxol, :agent, :budget, :halt, _], _, _}
    end

    test "an unpriced turn under a ledger and policy emits the halt after the hole" do
      model =
        metered_model(ledger: :test_ledger, spending_policy: %{cap_usd: 10.0})
        |> meter(@billed, "mystery-model-9")

      assert model.running? == false

      assert_received {:telemetry, [:raxol, :agent, :cost, :unpriced], _, %{armed?: true}}

      assert_received {:telemetry, [:raxol, :agent, :budget, :halt, :unpriced], %{count: 1},
                       metadata}

      assert metadata.model == "mystery-model-9"
      assert metadata.session_id == model.session_key
      assert metadata.turn_id == "t1"
      assert metadata.kind == :llm_turn

      refute_received {:telemetry, [:raxol, :agent, :budget, :halt, :over_limit], _, _}
    end

    test "a sub-agent round is metered as :llm_subagent under the running turn's id" do
      # The parent's turn has folded at least turn_started by the time any
      # sub-agent can report, so the round joins the parent's turn_id and a
      # per-turn cost sum does not silently drop nested spend.
      model = meter(metered_model([]), @billed, "gpt-4o")
      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], _, %{kind: :llm_turn}}

      {_model, []} =
        App.update(
          {:command_result, {:tool_usage, %{usage: @billed, model: "gpt-4o"}}},
          model
        )

      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], _,
                       %{kind: :llm_subagent, turn_id: "t1", source: :flat_table}}

      # With no turn running there is nothing to inherit.
      {_model, []} =
        App.update(
          {:command_result, {:tool_usage, %{usage: @billed, model: "gpt-4o"}}},
          %{model | running?: false}
        )

      assert_received {:telemetry, [:raxol, :agent, :cost, :priced], _,
                       %{kind: :llm_subagent, turn_id: nil}}
    end

    test "a call with no usage and no price emits nothing" do
      # A local backend reporting `usage: %{}` on an unpriced model says
      # nothing about money; an event here would page on every ollama turn.
      meter(metered_model([]), %{}, "llama3")

      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end
end
