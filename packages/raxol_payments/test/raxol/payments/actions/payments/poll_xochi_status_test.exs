defmodule Raxol.Payments.Actions.Payments.PollXochiStatusTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.PollXochiStatus
  alias Raxol.Payments.Failure

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "t",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  test "Failure.from classifies a stranded intent as retryable with the id in detail" do
    assert %Failure{reason: :stranded, retryable?: true, detail: {:stranded, "int_9"}} =
             Failure.from({:stranded, "int_9"})
  end

  test "a poll that never reaches terminal returns :stranded and signals for reconcile" do
    # The intent stays non-terminal, so the poll gives up at the deadline. The
    # origin funds may already have moved, so this is a stranded intent, not a
    # clean failure.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intentId" => "int_x", "status" => "executing", "terminal" => false})
    end)

    handler_id = "stranded-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:raxol, :payments, :xochi, :intent_stranded],
      fn _e, _m, meta, _ -> send(test_pid, {:stranded, meta}) end,
      nil
    )

    try do
      params = %{intent_id: "int_x", timeout_ms: 40, interval_ms: 10}

      assert {:error, %Failure{reason: :stranded, retryable?: true}} =
               PollXochiStatus.run(params, %{xochi_config: config()})

      # The id rides the telemetry so operator tooling can reconcile THIS intent.
      assert_received {:stranded, %{intent_id: "int_x"}}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "a refunded terminal status surfaces as a :refunded failure carrying the reason" do
    # The worker reports the intent refunded and terminal, with a refundReason.
    # The poll must stop (refunded is terminal), fail (not {:ok, ...}), and carry
    # the reason so the agent sees why the funds came back.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "intent_id" => "int_r",
        "status" => "refunded",
        "terminal" => true,
        "refundReason" => "solver timeout"
      })
    end)

    params = %{intent_id: "int_r", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded, retryable?: false, detail: "solver timeout"}} =
             PollXochiStatus.run(params, %{xochi_config: config()})
  end

  test "a refunded status without a refundReason still surfaces as :refunded" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intent_id" => "int_r2", "status" => "refunded", "terminal" => true})
    end)

    params = %{intent_id: "int_r2", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded} = failure} =
             PollXochiStatus.run(params, %{xochi_config: config()})

    assert to_string(failure) == "The transfer failed and the funds were refunded."
  end
end
