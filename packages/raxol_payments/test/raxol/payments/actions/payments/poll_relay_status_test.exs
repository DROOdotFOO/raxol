defmodule Raxol.Payments.Actions.Payments.PollRelayStatusTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.PollRelayStatus
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}

  defp config do
    %{
      base_url: "https://relay.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("10.00"),
      session_max: Decimal.new("100.00"),
      lifetime_max: Decimal.new("1000.00"),
      session_window_ms: 3_600_000
    }
  end

  defp reserve_and_tag(ledger, transfer_id) do
    :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("1.00"), policy(), %{})
    :ok = Ledger.tag_reservation(ledger, "agent_1", transfer_id, Decimal.new("1.00"))
  end

  defp start_ledger do
    {:ok, ledger} = Ledger.start_link(table_name: :"relay_poll_#{:erlang.unique_integer()}")
    ledger
  end

  test "a refunded transfer surfaces as :refunded and releases the reservation" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "transfer_id" => "t_r",
        "status" => "refunded",
        "refundReason" => "reverted on Tron"
      })
    end)

    ledger = start_ledger()
    reserve_and_tag(ledger, "t_r")
    ctx = %{relay_config: config(), ledger: ledger, agent_id: "agent_1"}
    params = %{transfer_id: "t_r", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded, detail: "reverted on Tron"}} =
             PollRelayStatus.run(params, ctx)

    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "0")

    # Idempotent: a re-poll of the already-refunded transfer releases nothing more.
    assert {:error, %Failure{reason: :refunded}} = PollRelayStatus.run(params, ctx)
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "0")
  end

  test "a failed transfer keeps the spend and forgets the tag" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"transfer_id" => "t_f", "status" => "failed", "error" => "reverted"})
    end)

    ledger = start_ledger()
    reserve_and_tag(ledger, "t_f")
    ctx = %{relay_config: config(), ledger: ledger, agent_id: "agent_1"}
    params = %{transfer_id: "t_f", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{}} = PollRelayStatus.run(params, ctx)
    # A failure may have moved funds, so the spend stands; only the tag is dropped.
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "1.00")
    assert :noop = Ledger.release_by_intent(ledger, "agent_1", "t_f")
  end

  test "a completed transfer keeps the spend and forgets the tag" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"transfer_id" => "t_c", "status" => "completed", "tx_hash" => "0xabc"})
    end)

    ledger = start_ledger()
    reserve_and_tag(ledger, "t_c")
    ctx = %{relay_config: config(), ledger: ledger, agent_id: "agent_1"}
    params = %{transfer_id: "t_c", timeout_ms: 40, interval_ms: 10}

    assert {:ok, %{status: "completed"}} = PollRelayStatus.run(params, ctx)
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "1.00")
    assert :noop = Ledger.release_by_intent(ledger, "agent_1", "t_c")
  end
end
