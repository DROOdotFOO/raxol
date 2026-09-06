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

  # A cap that only the SESSION total can trip, so the per-request and lifetime
  # limits do not mask what these tests are about.
  defp policy_capped(session_max) do
    %SpendingPolicy{
      per_request_max: Decimal.new("1000"),
      session_max: Decimal.new(session_max),
      lifetime_max: Decimal.new("1000"),
      currency: "USDC"
    }
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

  test "an exhausted budget halts the running turn, not just the next prompt" do
    # The submit gate only refuses the NEXT prompt. One accepted prompt then
    # ran the react loop for up to max_iterations more provider calls with no
    # re-check, so a session could close far past its cap while the ledger had
    # recorded the overshoot call by call in real time.
    ledger = start_ledger()
    policy = policy_capped("1.0")
    model = model_with(ledger, policy, backend: :openai, model: "gpt-4o")

    {model, _cmds} = submit(model, "go")
    assert model.running?
    worker = model.worker
    ref = Process.monitor(worker)

    # A NON-final round: the turn is still running when the cap blows.
    model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000_000, output_tokens: 0}, %{
          final: false,
          model: "gpt-4o"
        })
      )

    refute model.running?
    refute model.worker
    assert model.status_line =~ "spending budget exhausted"
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 2_000
  end

  # The over-limit halt's telemetry can only be proven here: in raxol_agent's
  # own suite the Ledger module is absent, so `CostLedger.check/3` never
  # returns `{:over, _}` and the event site is unreachable (ADR-0036). The
  # handler is a real `:telemetry.attach_many/4`; it runs in the emitting
  # process, which is this test process, so the pid travels as config.
  @doc false
  def forward(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  test "an over-limit halt emits its event with the ledger's limit" do
    id = {__MODULE__, :over_limit}

    :ok =
      :telemetry.attach_many(
        id,
        [[:raxol, :agent, :cost, :priced], [:raxol, :agent, :budget, :halt, :over_limit]],
        &__MODULE__.forward/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    ledger = start_ledger()
    model = model_with(ledger, policy_capped("1.0"), backend: :openai, model: "gpt-4o")
    {model, _cmds} = submit(model, "go")

    model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000_000, output_tokens: 0}, %{
          final: false,
          model: "gpt-4o"
        })
      )

    refute model.running?

    # The call was priced and recorded against a wired ledger...
    assert_received {:telemetry, [:raxol, :agent, :cost, :priced], %{cost_usd: cost},
                     %{source: :flat_table, ledger?: true, turn_id: "t1"}}

    assert_in_delta cost, 2.5, 1.0e-9

    # ...and the ledger's own limit type rides on the halt.
    assert_received {:telemetry, [:raxol, :agent, :budget, :halt, :over_limit], %{count: 1},
                     metadata}

    assert metadata.limit == :session
    assert metadata.session_id == model.session_key
    assert metadata.turn_id == "t1"
    assert metadata.backend == :openai
    assert metadata.model == "gpt-4o"
  end

  test "a ledger that dies mid-turn halts with its own event, not an over-limit one" do
    # The remedy is a process, not a policy, so it is not folded into
    # :over_limit under a `limit` discriminator (ADR-0036, rule 1).
    id = {__MODULE__, :ledger_unreachable}

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:raxol, :agent, :budget, :halt, :over_limit],
          [:raxol, :agent, :budget, :halt, :ledger_unreachable]
        ],
        &__MODULE__.forward/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    ledger = start_ledger()
    model = model_with(ledger, policy_capped("1000"), backend: :openai, model: "gpt-4o")
    {model, _cmds} = submit(model, "go")
    assert model.running?

    GenServer.stop(ledger)

    model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000, output_tokens: 0}, %{
          final: false,
          model: "gpt-4o"
        })
      )

    refute model.running?
    assert model.status_line =~ "unreachable"

    assert_received {:telemetry, [:raxol, :agent, :budget, :halt, :ledger_unreachable],
                     %{count: 1}, metadata}

    assert metadata.session_id == model.session_key
    assert metadata.turn_id == "t1"
    refute Map.has_key?(metadata, :limit)
    refute_received {:telemetry, [:raxol, :agent, :budget, :halt, :over_limit], _, _}
  end

  test "a model with no price halts a wired budget rather than billing $0" do
    # Fail closed: an unpriced model bills real tokens while the ledger records
    # nothing, so the cap would read untouched no matter how much was spent.
    ledger = start_ledger()
    policy = policy_capped("10.0")
    model = model_with(ledger, policy, backend: :openai, model: "mystery-9")

    {model, _cmds} = submit(model, "go")
    assert model.running?

    model =
      fold(
        model,
        turn_completed(%{input_tokens: 500_000, output_tokens: 1_000}, %{
          final: false,
          model: "mystery-9"
        })
      )

    refute model.running?
    assert model.status_line =~ "no price for mystery-9"

    # And the next prompt is refused too, until the operator fixes it.
    {refused, _} = submit(model, "again")
    refute refused.running?
    assert refused.notice =~ "no price for mystery-9"
  end

  test "a priced model does not trip the unpriced halt" do
    ledger = start_ledger()
    policy = policy_capped("10.0")
    model = model_with(ledger, policy, backend: :openai, model: "gpt-4o")

    {model, _cmds} = submit(model, "go")

    model =
      fold(
        model,
        turn_completed(%{input_tokens: 1_000, output_tokens: 10}, %{
          final: false,
          model: "gpt-4o"
        })
      )

    assert model.running?
    refute model.unpriced_model
  end
end
