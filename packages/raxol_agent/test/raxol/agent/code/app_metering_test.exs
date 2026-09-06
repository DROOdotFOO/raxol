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
end
