defmodule Raxol.Watch.AutoPruneTest do
  use ExUnit.Case, async: false

  alias Raxol.Watch.{DeviceRegistry, Notifier}
  alias Raxol.Watch.Push.{FailingBackend, PermanentFailureBackend}

  setup do
    start_supervised!(DeviceRegistry)

    on_exit(fn ->
      Application.delete_env(:raxol_watch, PermanentFailureBackend)
    end)

    :ok
  end

  defp wait_for_unregister do
    # The auto-prune call is a sync GenServer.call inside the push task,
    # but the Task.async_stream is non-blocking from the Notifier's view.
    # Block on the GenServer mailbox until the unregister has been
    # processed: device_count goes to 0.
    Enum.reduce_while(1..50, nil, fn _, _ ->
      if DeviceRegistry.device_count() == 0 do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end)
  end

  describe "auto-prune on permanent failure" do
    for reason <- [
          :bad_device_token,
          :device_token_not_for_topic,
          :unregistered,
          :expired_token,
          :invalid_argument,
          :sender_id_mismatch
        ] do
      @reason reason

      test "unregisters device on #{reason}" do
        Application.put_env(:raxol_watch, PermanentFailureBackend, @reason)
        start_supervised!({Notifier, push_backend: PermanentFailureBackend})

        DeviceRegistry.register("doomed_tok", :apns)
        assert DeviceRegistry.device_count() == 1

        Notifier.push_to_all(%{title: "t", body: "b", priority: :normal})

        assert :ok = wait_for_unregister()
        assert DeviceRegistry.device_count() == 0
      end
    end
  end

  describe "no prune on transient failure" do
    test "leaves device registered on :too_many_requests" do
      start_supervised!({Notifier, push_backend: FailingBackend})

      DeviceRegistry.register("transient_tok", :apns)
      assert DeviceRegistry.device_count() == 1

      Notifier.push_to_all(%{title: "t", body: "b", priority: :normal})

      # Give the push task a chance to run and (not) unregister.
      Process.sleep(50)
      assert DeviceRegistry.device_count() == 1
    end
  end

  describe "auto-prune emits telemetry" do
    test "fires [:device, :unregistered] with reason :delivery_failed" do
      Application.put_env(:raxol_watch, PermanentFailureBackend, :bad_device_token)
      start_supervised!({Notifier, push_backend: PermanentFailureBackend})

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:raxol_watch, :device, :unregistered]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      DeviceRegistry.register("doomed_tok_2", :fcm)

      Notifier.push_to_all(%{title: "t", body: "b", priority: :normal})

      assert_receive {[:raxol_watch, :device, :unregistered], _ref, _,
                      %{token: "doomed_tok_2", reason: :delivery_failed}},
                     500
    end
  end
end
