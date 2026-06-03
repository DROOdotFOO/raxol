defmodule Raxol.Core.Runtime.BackpressureTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Test.BackpressureTarget, as: TestTarget

  @telemetry_event [:raxol, :runtime, :backpressure]

  setup do
    {:ok, pid} = TestTarget.start_link()
    handler_id = "bp_test_#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    %{target: pid}
  end

  defp drain_target(target) do
    # Wait for the mailbox to drain (target processes all pending casts).
    Process.sleep(20)
    _ = TestTarget.received(target)
    :ok
  end

  defp saturate(target, count) do
    for _ <- 1..count, do: send(target, :noise)
    # Give the queue length a moment to stabilize before probing.
    Process.sleep(5)
  end

  describe "below watermark" do
    test "delivers via cast and target receives the message", %{target: target} do
      assert :ok =
               Backpressure.cast(target, {:msg, :a},
                 label: :bp_below,
                 policy: :drop_when_full,
                 watermark: 100
               )

      drain_target(target)
      assert TestTarget.received(target) == [:a]
    end

    test "emits telemetry with decision :cast", %{target: target} do
      Backpressure.cast(target, {:msg, :a},
        label: :bp_below_tm,
        policy: :drop_when_full,
        watermark: 100
      )

      assert_receive {:telemetry, %{queue_len: 0},
                      %{
                        label: :bp_below_tm,
                        policy: :drop_when_full,
                        decision: :cast
                      }}
    end
  end

  describe "above watermark, :drop_when_full" do
    test "returns {:dropped, :overflow} and target does not receive",
         %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      assert {:dropped, :overflow} =
               Backpressure.cast(target, {:msg, :a},
                 label: :bp_drop,
                 policy: :drop_when_full,
                 watermark: 1_000
               )

      TestTarget.resume(target)
      drain_target(target)
      refute :a in TestTarget.received(target)
    end

    test "emits telemetry with decision :drop", %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      Backpressure.cast(target, {:msg, :a},
        label: :bp_drop_tm,
        policy: :drop_when_full,
        watermark: 1_000
      )

      assert_receive {:telemetry, %{queue_len: queue_len},
                      %{
                        label: :bp_drop_tm,
                        policy: :drop_when_full,
                        decision: :drop
                      }}

      assert queue_len > 1_000
      TestTarget.resume(target)
    end
  end

  describe "above watermark, :call_when_full" do
    test "escalates to synchronous call; target receives the message",
         %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      # The call would block on the paused target, so drive it from a task.
      task =
        Task.async(fn ->
          Backpressure.cast(target, {:msg, :a},
            label: :bp_call,
            policy: :call_when_full,
            watermark: 1_000,
            timeout: 5_000
          )
        end)

      # Let the call queue behind the noise messages, then resume.
      Process.sleep(20)
      TestTarget.resume(target)

      assert :ok = Task.await(task)
      drain_target(target)
      assert :a in TestTarget.received(target)
    end

    test "emits telemetry with decision :call", %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      task =
        Task.async(fn ->
          Backpressure.cast(target, {:msg, :a},
            label: :bp_call_tm,
            policy: :call_when_full,
            watermark: 1_000
          )
        end)

      Process.sleep(20)
      TestTarget.resume(target)
      assert :ok = Task.await(task)

      assert_receive {:telemetry, %{queue_len: queue_len},
                      %{
                        label: :bp_call_tm,
                        policy: :call_when_full,
                        decision: :call
                      }}

      assert queue_len > 1_000
    end
  end

  describe "above watermark, :fail_when_full" do
    test "returns {:dropped, :overflow} (same shape as :drop_when_full)",
         %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      assert {:dropped, :overflow} =
               Backpressure.cast(target, {:msg, :a},
                 label: :bp_fail,
                 policy: :fail_when_full,
                 watermark: 1_000
               )

      TestTarget.resume(target)
    end

    test "telemetry policy tag distinguishes :fail_when_full from :drop_when_full",
         %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      Backpressure.cast(target, {:msg, :a},
        label: :bp_fail_tm,
        policy: :fail_when_full,
        watermark: 1_000
      )

      assert_receive {:telemetry, %{},
                      %{policy: :fail_when_full, decision: :drop}}

      TestTarget.resume(target)
    end
  end

  describe "dead target" do
    test "returns {:dropped, :no_proc} regardless of policy", %{target: target} do
      GenServer.stop(target)

      for policy <- [:call_when_full, :drop_when_full, :fail_when_full] do
        assert {:dropped, :no_proc} =
                 Backpressure.cast(target, {:msg, :a},
                   label: :bp_dead,
                   policy: policy,
                   watermark: 1_000
                 )
      end
    end

    test "returns {:dropped, :no_proc} for an unknown registered name" do
      assert {:dropped, :no_proc} =
               Backpressure.cast(:nonexistent_xyz, {:msg, :a},
                 label: :bp_unknown,
                 policy: :call_when_full,
                 watermark: 1_000
               )
    end

    test "emits telemetry with decision :no_proc" do
      Backpressure.cast(:nonexistent_xyz, {:msg, :a},
        label: :bp_no_proc_tm,
        policy: :drop_when_full,
        watermark: 1_000
      )

      assert_receive {:telemetry, %{queue_len: 0},
                      %{label: :bp_no_proc_tm, decision: :no_proc}}
    end
  end

  describe "options" do
    test "requires :label", %{target: target} do
      assert_raise KeyError, fn ->
        Backpressure.cast(target, {:msg, :a},
          policy: :drop_when_full,
          watermark: 1_000
        )
      end
    end

    test "requires :policy", %{target: target} do
      assert_raise KeyError, fn ->
        Backpressure.cast(target, {:msg, :a},
          label: :bp_no_policy,
          watermark: 1_000
        )
      end
    end

    test "watermark defaults to 1000 when omitted", %{target: target} do
      TestTarget.pause(target)
      saturate(target, 1_500)

      assert {:dropped, :overflow} =
               Backpressure.cast(target, {:msg, :a},
                 label: :bp_default_wm,
                 policy: :drop_when_full
               )

      TestTarget.resume(target)
    end
  end
end
