defmodule Raxol.ACP.Seller.RuntimeTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Seller.Backend.InMemory
  alias Raxol.ACP.Seller.Runtime
  alias Raxol.ACP.TestSupport.SellerHelper

  setup do
    :ok = SellerHelper.reset_seller([])
    :ok
  end

  describe "subscription on init" do
    test "the auto-started Runtime subscribes to the configured Backend" do
      assert Runtime.backend() == InMemory
      # Plus the Runtime itself.
      assert InMemory.subscriber_count() >= 1

      pid = Process.whereis(Runtime)
      assert pid in InMemory.subscribers()
    end
  end

  describe "event forwarding" do
    test "every published event reaches the Queue (telemetry signal)" do
      handler_id = "runtime-event-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :acp, :seller, :runtime, :event_received],
        fn _event, _measurements, metadata, _ -> send(test_pid, {:runtime_event, metadata}) end,
        nil
      )

      try do
        InMemory.publish(%{type: :ping, job_id: "j-runtime"})

        assert_receive {:runtime_event, %{type: :ping, job_id: "j-runtime"}}, 200
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "subscription survives backend restart" do
    test "after Backend dies, rest_for_one restarts Runtime which re-subscribes" do
      old_backend_pid = Process.whereis(InMemory)
      old_runtime_pid = Process.whereis(Runtime)

      ref_b = Process.monitor(old_backend_pid)
      ref_r = Process.monitor(old_runtime_pid)

      Process.exit(old_backend_pid, :kill)

      assert_receive {:DOWN, ^ref_b, :process, ^old_backend_pid, :killed}, 500
      # Runtime is restarted by :rest_for_one (Backend is upstream of it).
      assert_receive {:DOWN, ^ref_r, :process, ^old_runtime_pid, _}, 500

      new_runtime_pid = wait_for_named(Runtime, old_runtime_pid)

      assert new_runtime_pid != old_runtime_pid
      assert new_runtime_pid in InMemory.subscribers()
    end
  end

  defp wait_for_named(name, old_pid, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_named(name, old_pid, deadline)
  end

  defp do_wait_for_named(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_for_named(name, old_pid, deadline)
        else
          flunk("#{inspect(name)} never came back online with a new pid")
        end
    end
  end
end
