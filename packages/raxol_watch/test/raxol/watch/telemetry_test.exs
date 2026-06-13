defmodule Raxol.Watch.TelemetryTest do
  use ExUnit.Case, async: false

  alias Raxol.Watch.{DeviceRegistry, Notifier}
  alias Raxol.Watch.Push.Noop

  setup do
    start_supervised!(DeviceRegistry)
    start_supervised!(Noop)
    start_supervised!({Notifier, push_backend: Noop})
    Noop.clear()

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:raxol_watch, :device, :registered],
        [:raxol_watch, :device, :unregistered],
        [:raxol_watch, :device, :cleared],
        [:raxol_watch, :push, :start],
        [:raxol_watch, :push, :stop],
        [:raxol_watch, :notifier, :coalesced]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    :ok
  end

  describe "device telemetry" do
    test "register emits [:raxol_watch, :device, :registered]" do
      DeviceRegistry.register("tok_abc", :apns, muted: true)

      assert_receive {[:raxol_watch, :device, :registered], _ref, %{system_time: _},
                      %{token: "tok_abc", platform: :apns, prefs: prefs}}

      assert prefs.muted == true
    end

    test "unregister emits [:raxol_watch, :device, :unregistered] with reason" do
      DeviceRegistry.register("tok", :apns)
      DeviceRegistry.unregister("tok", :delivery_failed)

      assert_receive {[:raxol_watch, :device, :unregistered], _ref, _measurements,
                      %{token: "tok", reason: :delivery_failed}}
    end

    test "default unregister reason is :explicit" do
      DeviceRegistry.register("tok", :fcm)
      DeviceRegistry.unregister("tok")

      assert_receive {[:raxol_watch, :device, :unregistered], _ref, _, %{reason: :explicit}}
    end

    test "clear_all emits [:raxol_watch, :device, :cleared] with count" do
      DeviceRegistry.register("a", :apns)
      DeviceRegistry.register("b", :fcm)
      # Drain the two :registered events first
      assert_receive {[:raxol_watch, :device, :registered], _, _, _}
      assert_receive {[:raxol_watch, :device, :registered], _, _, _}

      DeviceRegistry.clear_all()

      assert_receive {[:raxol_watch, :device, :cleared], _ref, %{count: 2}, _}
    end
  end

  describe "push telemetry" do
    test "Notifier.push_to_all emits a :start/:stop span per device" do
      DeviceRegistry.register("apns_tok", :apns)
      assert_receive {[:raxol_watch, :device, :registered], _, _, _}

      Notifier.push_to_all(%{title: "t", body: "b", priority: :normal})

      assert_receive {[:raxol_watch, :push, :start], _ref, _,
                      %{token: "apns_tok", platform: :apns, priority: :normal}}

      assert_receive {[:raxol_watch, :push, :stop], _ref, %{duration: duration},
                      %{token: "apns_tok", result: :ok}}

      assert is_integer(duration) and duration >= 0
    end

    test "stop event metadata includes the result tuple on error" do
      :ok = stop_supervised(Notifier)
      start_supervised!({Notifier, push_backend: Raxol.Watch.Push.FailingBackend})

      DeviceRegistry.register("fail_tok", :fcm)
      assert_receive {[:raxol_watch, :device, :registered], _, _, _}

      Notifier.push_to_all(%{title: "t", body: "b", priority: :normal})

      assert_receive {[:raxol_watch, :push, :stop], _ref, _,
                      %{result: {:error, :too_many_requests}}}
    end
  end

  describe "debounce telemetry" do
    test "two rapid announcements emit a :coalesced event" do
      DeviceRegistry.register("tok", :apns)
      assert_receive {[:raxol_watch, :device, :registered], _, _, _}

      # Hand-craft two announcement_added messages back-to-back. The second
      # arrives while the first is still pending in the debounce timer.
      send(Notifier, {:announcement_added, make_ref(), %{message: "one", priority: :normal}})
      send(Notifier, {:announcement_added, make_ref(), %{message: "two", priority: :normal}})

      assert_receive {[:raxol_watch, :notifier, :coalesced], _ref, %{count: 1},
                      %{priority: :normal}}
    end
  end
end
