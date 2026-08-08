defmodule Raxol.Payments.CodeLlmLedgerTest do
  # End-to-end wiring of the coding TUI's LLM cost into the shared
  # payments ledger (Raxol.Agent.Code.CostLedger). Lives in this suite
  # because raxol_agent does not depend on raxol_payments — only here
  # are both sides loadable.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Code.App
  alias Raxol.Agent.Contract
  alias Raxol.Agent.ExecutorConfig
  alias Raxol.Payments.Ledger
  alias Raxol.Payments.SpendingPolicy

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "raxol-llm-ledger-#{System.os_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"
    )
  end

  defp start_ledger do
    {:ok, ledger} =
      Ledger.start_link(table_name: :"llm_ledger_#{System.unique_integer([:positive])}")

    ledger
  end

  defp model_with(ledger, policy, executor_opts \\ [backend: :openai, model: "gpt-4o"]) do
    App.init(%{
      options: [
        runner: fn _session_id, _prompt, _opts, _app ->
          spawn(fn -> Process.sleep(60_000) end)
        end,
        sessions_dir: tmp_dir(),
        journal_opts: [base_dir: tmp_dir()],
        executor: ExecutorConfig.new(executor_opts),
        provider_status: {:ready, :openai, :env},
        ledger: ledger,
        spending_policy: policy,
        agent_id: "llm-test-agent"
      ]
    })
  end

  defp turn_completed(usage, extra \\ %{}) do
    %Contract.Event{
      id: 1,
      ts: 1,
      turn_id: "t1",
      family: :loop,
      type: :turn_completed,
      tier: :durable,
      payload: Map.merge(%{final: true, usage: usage}, extra)
    }
  end

  defp fold(model, event) do
    {model, []} = App.update({:command_result, {:contract_event, event}}, model)
    model
  end

  defp submit(model, text) do
    App.update(
      Raxol.Core.Events.Event.key_event(:enter, :pressed, []),
      %{model | input: text}
    )
  end

  setup do
    saved =
      Map.new(
        ~w(RAXOL_COST_PER_MTOK_IN RAXOL_COST_PER_MTOK_OUT),
        &{&1, System.get_env(&1)}
      )

    Enum.each(Map.keys(saved), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  test "a turn's LLM cost lands in the shared ledger" do
    ledger = start_ledger()
    :ok = Ledger.subscribe(ledger)
    model = model_with(ledger, SpendingPolicy.dev())

    # gpt-4o price table: 1M input at $2.50/M = $2.50
    fold(model, turn_completed(%{input_tokens: 1_000_000, output_tokens: 0}))

    assert_receive {:ledger_entry, entry}, 1_000
    assert entry.agent_id == "llm-test-agent"
    assert Decimal.equal?(entry.amount, Decimal.from_float(2.5))
    assert entry.metadata.type == :llm_turn
    assert entry.metadata.model == "gpt-4o"
  end

  test "an exhausted budget refuses the next turn" do
    ledger = start_ledger()

    policy = %SpendingPolicy{
      per_request_max: Decimal.new("10"),
      session_max: Decimal.new("1.0"),
      lifetime_max: Decimal.new("100"),
      session_window_ms: 3_600_000
    }

    model = model_with(ledger, policy)

    # $2.50 of LLM spend blows the $1 session budget.
    model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000_000, output_tokens: 0})
      )

    {gated, []} = submit(model, "another prompt")

    refute gated.running?
    assert gated.notice =~ "spending budget exhausted (session)"
  end

  test "a dead wired ledger fails closed with its own notice" do
    ledger = start_ledger()
    model = model_with(ledger, SpendingPolicy.dev())

    GenServer.stop(ledger)

    {gated, []} = submit(model, "a prompt")
    refute gated.running?
    assert gated.notice =~ "spending ledger unreachable"

    {model, []} = submit(model, "/usage")
    assert model.notice =~ "ledger: unreachable"
  end

  test "a frozen ledger names the unfreeze, not the policy" do
    ledger = start_ledger()
    :ok = Ledger.freeze(ledger)
    model = model_with(ledger, SpendingPolicy.dev())

    {gated, []} = submit(model, "a prompt")
    refute gated.running?
    assert gated.notice =~ "frozen — unfreeze it to continue"
  end

  test "/usage shows the shared-ledger totals" do
    ledger = start_ledger()
    policy = SpendingPolicy.dev()
    model = model_with(ledger, policy)

    # Payment spend from elsewhere shares the same budget view.
    :ok =
      Ledger.record_spend(
        ledger,
        "llm-test-agent",
        Decimal.new("0.25"),
        %{type: :payment}
      )

    model =
      fold(model, turn_completed(%{input_tokens: 100_000, output_tokens: 0}))

    {model, []} = submit(model, "/usage")

    # 0.25 payment + 0.25 LLM (100k in at $2.50/M) = 0.5 in one ledger.
    assert model.notice =~ "ledger: $0.5000 session"
  end

  test "a turn prices from the model the provider billed, not the one configured" do
    # With no :model configured the backend substitutes its own hosted default
    # and charges for it. Pricing the configured (nil) name instead yielded
    # :unknown -> $0.00 -> CostLedger.record's cost_usd > 0.0 guard no-oped, so
    # the ledger read empty and no budget could ever bind.
    ledger = start_ledger()
    :ok = Ledger.subscribe(ledger)
    model = model_with(ledger, SpendingPolicy.dev(), backend: :openai)

    refute model.executor.model

    _model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000_000, output_tokens: 0}, %{
          model: "gpt-4o"
        })
      )

    assert_receive {:ledger_entry, entry}, 2_000
    assert Decimal.eq?(entry.amount, Decimal.new("2.5"))
    assert entry.metadata.model == "gpt-4o"
  end

  test "sub-agent spend lands in the shared ledger" do
    # The task tool runs a nested react loop against the SAME paid executor.
    # Its usage never reaches the parent's turn_completed fold, so without the
    # usage sink a delegation's up-to-6 calls accrued $0.00 and the cap could
    # be overrun by an arbitrary multiple.
    ledger = start_ledger()
    :ok = Ledger.subscribe(ledger)
    model = model_with(ledger, SpendingPolicy.dev(), backend: :openai)

    {_model, []} =
      App.update(
        {:command_result,
         {:tool_usage, %{usage: %{input_tokens: 1_000_000, output_tokens: 0}, model: "gpt-4o"}}},
        model
      )

    assert_receive {:ledger_entry, entry}, 2_000
    assert Decimal.eq?(entry.amount, Decimal.new("2.5"))
    assert entry.metadata.type == :llm_subagent
    assert entry.metadata.model == "gpt-4o"
  end
end
