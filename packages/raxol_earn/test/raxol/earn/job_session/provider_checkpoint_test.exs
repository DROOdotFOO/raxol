defmodule Raxol.Earn.JobSession.ProviderCheckpointTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.{AssetToken, JobSession}
  alias Raxol.Earn.JobSession.Provider
  alias Raxol.Earn.ProviderAdapter.Mock
  alias Raxol.Payments.Checkpoint

  @chain 84_532
  @counter :provider_ck_test_counters

  # Deliberately NOT deterministic: every invocation yields different bytes, so
  # any second handler run would produce a different hash -- exactly what the
  # checkpoint must make impossible.
  defmodule Handler do
    def handle_request(request, _ctx) do
      :ets.update_counter(:provider_ck_test_counters, :request, 1, {:request, 0})
      {:accept, request}
    end

    def handle_deliver(_request, _ctx) do
      :ets.update_counter(:provider_ck_test_counters, :deliver, 1, {:deliver, 0})
      {:deliver, %{"payload" => "run-#{System.unique_integer([:positive])}"}}
    end
  end

  setup do
    if :ets.whereis(@counter) == :undefined,
      do: :ets.new(@counter, [:set, :public, :named_table])

    :ets.insert(@counter, [{:request, 0}, {:deliver, 0}])

    ensure_session_infra()

    job_id = System.unique_integer([:positive])
    store = Checkpoint.ETS.new()
    adapter = Mock.new()

    {:ok, job_id: job_id, store: store, adapter: adapter}
  end

  defp ensure_session_infra do
    unless Process.whereis(Raxol.Earn.JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Raxol.Earn.JobSession.Registry)
    end

    unless Process.whereis(Raxol.Earn.JobSession.Supervisor) do
      start_supervised!(Raxol.Earn.JobSession.Supervisor)
    end
  end

  defp provider(ctx, opts \\ []) do
    Provider.new(
      session: {@chain, ctx.job_id},
      handler: Handler,
      adapter: ctx.adapter,
      chain_id: @chain,
      acp_core_address: "0x" <> String.duplicate("ab", 20),
      job_id: ctx.job_id,
      checkpoint: Keyword.get(opts, :checkpoint, ctx.store)
    )
  end

  defp start_session!(ctx, status) do
    {:ok, pid} =
      JobSession.Supervisor.start_session(
        chain_id: @chain,
        job_id: ctx.job_id,
        role: :provider,
        initial_status: status
      )

    pid
  end

  # The Supervisor is transient, so a killed session is auto-restarted with its
  # original opts (initial_status) -- this IS the BEAM-restart simulation: the
  # session comes back at the pre-submit phase, and only the checkpoint carries
  # the fact that the write already landed. Wait for that restart rather than
  # racing the supervisor with a manual start_session.
  defp kill_and_restart!(ctx, pid, _status) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    wait_for_restart(ctx, 50)
  end

  defp wait_for_restart(ctx, attempts) do
    JobSession.status({@chain, ctx.job_id})
  catch
    :exit, _ when attempts > 0 ->
      Process.sleep(10)
      wait_for_restart(ctx, attempts - 1)
  end

  defp counter(key), do: :ets.lookup_element(@counter, key, 2)
  defp submits(ctx), do: length(Mock.sent_calls(ctx.adapter))
  defp ck_key(ctx, step), do: Raxol.Earn.Checkpoint.key(@chain, ctx.job_id, step)

  test "deliver pins encoded deliverable + hash before signing, records tx after", ctx do
    start_session!(ctx, :funded)
    p = provider(ctx)

    assert {:ok, %{status: :submitted, tx_hash: tx, deliverable: d}} = Provider.deliver(p, %{})
    assert counter(:deliver) == 1
    assert submits(ctx) == 1

    assert {:ok, rec} = Checkpoint.fetch(ctx.store, ck_key(ctx, :submit))
    assert rec["tx_hash"] == tx
    assert Jason.decode!(rec["deliverable_json"]) == d

    expected = rec["deliverable_json"] |> ExKeccak.hash_256() |> Base.encode16(case: :lower)
    assert rec["hash_hex"] == expected
  end

  test "replay across a dead session resumes the recorded tx: no handler, no second submit",
       ctx do
    pid = start_session!(ctx, :funded)
    p = provider(ctx)
    assert {:ok, %{tx_hash: tx}} = Provider.deliver(p, %{})

    # BEAM-restart simulation: session gone, rebuilt at the (API-lagged)
    # pre-submit phase. The checkpoint, not the session, must carry the truth.
    kill_and_restart!(ctx, pid, :funded)

    assert {:ok, %{status: :submitted, tx_hash: ^tx, resumed: true, deliverable: d}} =
             Provider.deliver(p, %{})

    assert counter(:deliver) == 1
    assert submits(ctx) == 1
    assert is_map(d)
    assert JobSession.status({@chain, ctx.job_id}) == :submitted
  end

  test "a pinned-but-unsigned record is submitted verbatim, handler skipped", ctx do
    start_session!(ctx, :funded)
    p = provider(ctx)

    json = Jason.encode!(%{"payload" => "pinned-before-crash"})
    hex = json |> ExKeccak.hash_256() |> Base.encode16(case: :lower)

    :ok =
      Checkpoint.put(ctx.store, ck_key(ctx, :submit), %{
        "deliverable_json" => json,
        "hash_hex" => hex
      })

    assert {:ok, %{status: :submitted, deliverable: %{"payload" => "pinned-before-crash"}}} =
             Provider.deliver(p, %{})

    assert counter(:deliver) == 0
    assert submits(ctx) == 1
    assert {:ok, %{"tx_hash" => _}} = Checkpoint.fetch(ctx.store, ck_key(ctx, :submit))
  end

  test "fail-closed: require_checkpoint with no store refuses before the handler", ctx do
    Application.put_env(:raxol_earn, :require_checkpoint, true)
    on_exit(fn -> Application.delete_env(:raxol_earn, :require_checkpoint) end)

    start_session!(ctx, :funded)
    p = provider(ctx, checkpoint: nil)

    assert {:error, :checkpoint_required} = Provider.deliver(p, %{})
    assert counter(:deliver) == 0
    assert submits(ctx) == 0

    # accept_request only reaches the checkpoint gate from `:open` (the status
    # guard fires first on a later phase), so exercise it on its own session.
    open_ctx = %{ctx | job_id: System.unique_integer([:positive])}
    start_session!(open_ctx, :open)
    open_p = provider(open_ctx, checkpoint: nil)

    assert {:error, :checkpoint_required} =
             Provider.accept_request(open_p, %{}, AssetToken.usdc(Decimal.new(1), @chain))

    assert counter(:request) == 0
  end

  test "accept resumes a recorded setBudget instead of re-signing", ctx do
    start_session!(ctx, :open)
    p = provider(ctx)
    :ok = Checkpoint.put(ctx.store, ck_key(ctx, :accept), %{"tx_hash" => "0xrecorded"})

    assert {:ok, %{status: :budget_set, tx_hash: "0xrecorded", resumed: true}} =
             Provider.accept_request(p, %{}, AssetToken.usdc(Decimal.new(1), @chain))

    assert counter(:request) == 0
    assert submits(ctx) == 0
    assert JobSession.status({@chain, ctx.job_id}) == :budget_set
  end

  test "cleanup drops both step records", ctx do
    start_session!(ctx, :funded)
    p = provider(ctx)
    assert {:ok, _} = Provider.deliver(p, %{})

    assert :ok = Provider.cleanup(p)
    assert :error = Checkpoint.fetch(ctx.store, ck_key(ctx, :submit))
    assert :error = Checkpoint.fetch(ctx.store, ck_key(ctx, :accept))
  end
end
