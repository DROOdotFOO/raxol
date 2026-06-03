defmodule Raxol.Payments.Telemetry.LoggerHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Payments.Telemetry.LoggerHandler

  setup do
    on_exit(fn -> LoggerHandler.detach() end)
    :ok
  end

  describe "attach/1 + handle_event/4" do
    test "logs :spend at :info with formatted measurements + metadata" do
      :ok = LoggerHandler.attach()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:raxol, :payments, :spend],
            %{amount: Decimal.new("1.23")},
            %{agent_id: "agent-7", currency: "USDC", metadata: %{ref: "abc"}}
          )
        end)

      assert log =~ "payments.spend"
      assert log =~ "amount=1.23"
      assert log =~ "agent_id=agent-7"
      assert log =~ "currency=USDC"
      assert log =~ "[info]"
    end

    test "logs :over_budget at :warning" do
      :ok = LoggerHandler.attach()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:raxol, :payments, :over_budget],
            %{amount: Decimal.new("100.00")},
            %{agent_id: "agent-7", limit_type: :session}
          )
        end)

      assert log =~ "payments.over_budget"
      assert log =~ "limit_type=session"
      assert log =~ "[warning]"
    end

    test "logs :freeze at :warning when frozen, :info when unfrozen" do
      :ok = LoggerHandler.attach()

      freeze_log =
        capture_log(fn ->
          :telemetry.execute([:raxol, :payments, :freeze], %{}, %{frozen?: true})
        end)

      assert freeze_log =~ "payments.freeze"
      assert freeze_log =~ "frozen?=true"
      assert freeze_log =~ "[warning]"

      unfreeze_log =
        capture_log(fn ->
          :telemetry.execute([:raxol, :payments, :freeze], %{}, %{frozen?: false})
        end)

      assert unfreeze_log =~ "frozen?=false"
      assert unfreeze_log =~ "[info]"
    end

    test "double-attach returns {:error, :already_exists}" do
      :ok = LoggerHandler.attach()
      assert {:error, :already_exists} = LoggerHandler.attach()
    end

    test "custom formatter is invoked" do
      :ok =
        LoggerHandler.attach(
          handler_id: "custom-pay",
          formatter: fn _event, _measurements, %{agent_id: id} -> "AGENT[#{id}]" end
        )

      on_exit(fn -> LoggerHandler.detach("custom-pay") end)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:raxol, :payments, :spend],
            %{amount: Decimal.new("0.01")},
            %{agent_id: "x"}
          )
        end)

      assert log =~ "AGENT[x]"
    end
  end

  describe "detach/1" do
    test "stops further logging" do
      :ok = LoggerHandler.attach()
      :ok = LoggerHandler.detach()

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:raxol, :payments, :spend],
            %{amount: Decimal.new("1.00")},
            %{agent_id: "a"}
          )
        end)

      refute log =~ "payments.spend"
    end
  end
end
