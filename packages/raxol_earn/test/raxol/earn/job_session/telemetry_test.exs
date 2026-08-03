defmodule Raxol.Earn.JobSession.TelemetryTest do
  @moduledoc """
  The `[:raxol, :earn, :job_session, :transition]` telemetry event is a
  cross-package contract: `raxol_symphony`'s `Raxol.Symphony.ResumeOn` /
  `Raxol.Symphony.Resumer` match on its metadata to auto-resume paused runs.
  These tests pin the event name and the full metadata shape so a change can't
  silently break that consumer.
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.{AssetToken, JobSession}

  @event [:raxol, :earn, :job_session, :transition]
  @chain 8453
  @contract_keys [:action, :chain_id, :from, :job_id, :role, :to]

  setup do
    handler = {__MODULE__, System.unique_integer([:positive])}
    test = self()

    :telemetry.attach(
      handler,
      @event,
      fn event, measurements, metadata, _config ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp start_session(role, status) do
    job_id = "tel-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      JobSession.Supervisor.start_session(
        chain_id: @chain,
        job_id: job_id,
        role: role,
        initial_status: status
      )

    {pid, job_id}
  end

  test "a role-gated transition emits exactly the 6-key metadata contract" do
    {session, job_id} = start_session(:provider, :open)

    assert {:ok, :budget_set} = JobSession.set_budget(session, AssetToken.usdc(0.25, @chain))

    assert_receive {:telemetry, @event, measurements, metadata}, 500
    assert measurements == %{}

    assert %{
             chain_id: @chain,
             job_id: ^job_id,
             role: :provider,
             action: :set_budget,
             from: :open,
             to: :budget_set
           } = metadata

    # The Resumer subset-matches on this metadata; pin the exact key set so no
    # field is added or dropped without updating the cross-package contract.
    assert metadata |> Map.keys() |> Enum.sort() == @contract_keys
  end

  test "an observed apply_event emits the same contract with action :apply_event" do
    {session, job_id} = start_session(:provider, :budget_set)

    assert {:ok, :funded} = JobSession.apply_event(session, :funded, %{observed: true})

    assert_receive {:telemetry, @event, _measurements, metadata}, 500

    assert %{
             chain_id: @chain,
             job_id: ^job_id,
             role: :provider,
             action: :apply_event,
             from: :budget_set,
             to: :funded
           } = metadata

    assert metadata |> Map.keys() |> Enum.sort() == @contract_keys
  end

  test "a terminal transition still emits the contract before the session stops" do
    {session, job_id} = start_session(:evaluator, :submitted)

    assert {:ok, :completed} = JobSession.complete(session, "looks good")

    assert_receive {:telemetry, @event, _measurements, metadata}, 500

    assert %{
             chain_id: @chain,
             job_id: ^job_id,
             role: :evaluator,
             action: :complete,
             from: :submitted,
             to: :completed
           } = metadata
  end
end
