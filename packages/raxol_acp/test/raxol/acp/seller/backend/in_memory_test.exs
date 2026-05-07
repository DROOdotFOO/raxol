defmodule Raxol.ACP.Seller.Backend.InMemoryTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Seller.Backend
  alias Raxol.ACP.Seller.Backend.InMemory
  alias Raxol.ACP.Seller.Runtime

  setup do
    # Detach the auto-started Runtime so its subscription doesn't show
    # up in the assertions below. Reattach in on_exit.
    Backend.unsubscribe(InMemory, Process.whereis(Runtime))
    InMemory.reset()

    on_exit(fn ->
      # The Runtime is named so picking up the (potentially new) pid here.
      case Process.whereis(Runtime) do
        nil -> :ok
        pid -> Backend.subscribe(InMemory, pid)
      end
    end)

    :ok
  end

  describe "subscribe/1" do
    test "delivers published events to a subscriber" do
      :ok = Backend.subscribe(InMemory, self())

      :ok = InMemory.publish(%{type: :job_offered, job_id: "job-1"})

      assert_receive {:acp_event, %{type: :job_offered, job_id: "job-1"}}, 100
    end

    test "is idempotent for the same pid" do
      :ok = Backend.subscribe(InMemory, self())
      :ok = Backend.subscribe(InMemory, self())

      assert InMemory.subscriber_count() == 1
    end

    test "delivers to multiple subscribers" do
      parent = self()

      pid =
        spawn_link(fn ->
          :ok = Backend.subscribe(InMemory, self())
          send(parent, {:ready, self()})

          receive do
            {:acp_event, event} -> send(parent, {:got_event, event})
          after
            500 -> send(parent, :timeout)
          end
        end)

      assert_receive {:ready, ^pid}, 200

      :ok = Backend.subscribe(InMemory, self())
      :ok = InMemory.publish(%{type: :job_offered, job_id: "job-multi"})

      assert_receive {:acp_event, %{job_id: "job-multi"}}, 200
      assert_receive {:got_event, %{type: :job_offered, job_id: "job-multi"}}, 200
    end
  end

  describe "unsubscribe/1" do
    test "stops delivering events" do
      :ok = Backend.subscribe(InMemory, self())
      :ok = Backend.unsubscribe(InMemory, self())

      :ok = InMemory.publish(%{type: :ping, job_id: nil})

      refute_receive {:acp_event, _}, 50
    end

    test "is idempotent" do
      :ok = Backend.unsubscribe(InMemory, self())
      :ok = Backend.unsubscribe(InMemory, self())
    end
  end

  describe "subscriber lifecycle" do
    test "drops a subscriber when its process dies" do
      parent = self()

      pid =
        spawn(fn ->
          :ok = Backend.subscribe(InMemory, self())
          send(parent, {:subscribed, self()})

          receive do
            :die -> :ok
          end
        end)

      ref = Process.monitor(pid)
      assert_receive {:subscribed, ^pid}, 200

      assert InMemory.subscriber_count() == 1

      send(pid, :die)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 200

      :ok = wait_for_count(0)

      assert InMemory.subscriber_count() == 0
    end
  end

  describe "publish/1" do
    test "is a no-op when no subscribers" do
      :ok = InMemory.publish(%{type: :nobody_listening, job_id: nil})
      refute_receive {:acp_event, _}, 50
    end

    test "preserves arbitrary fields on the event" do
      :ok = Backend.subscribe(InMemory, self())

      payload = %{
        type: :job_offered,
        job_id: "j-1",
        offering: "test.echo",
        request: %{"text" => "hi"},
        buyer: "0xabc"
      }

      :ok = InMemory.publish(payload)

      assert_receive {:acp_event, ^payload}, 100
    end
  end

  defp wait_for_count(target, timeout_ms \\ 200) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_count(target, deadline)
  end

  defp do_wait_for_count(target, deadline) do
    if InMemory.subscriber_count() == target do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        do_wait_for_count(target, deadline)
      else
        :timeout
      end
    end
  end
end
