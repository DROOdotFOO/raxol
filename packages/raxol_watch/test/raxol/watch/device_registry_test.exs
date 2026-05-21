defmodule Raxol.Watch.DeviceRegistryTest do
  use ExUnit.Case

  alias Raxol.Watch.DeviceRegistry

  setup do
    start_supervised!(DeviceRegistry)
    :ok
  end

  describe "register/3" do
    test "registers an APNS device" do
      assert :ok = DeviceRegistry.register("apns_token_1", :apns)
      assert DeviceRegistry.device_count() == 1
    end

    test "registers an FCM device" do
      assert :ok = DeviceRegistry.register("fcm_token_1", :fcm)
      assert DeviceRegistry.device_count() == 1
    end

    test "stores device preferences" do
      DeviceRegistry.register("tok", :apns, muted: true, high_priority_only: true)
      [{_token, :apns, prefs}] = DeviceRegistry.list_devices()
      assert prefs.muted == true
      assert prefs.high_priority_only == true
    end

    test "defaults preferences to false" do
      DeviceRegistry.register("tok", :fcm)
      [{_token, :fcm, prefs}] = DeviceRegistry.list_devices()
      assert prefs.muted == false
      assert prefs.high_priority_only == false
    end
  end

  describe "unregister/1" do
    test "removes a registered device" do
      DeviceRegistry.register("tok", :apns)
      assert DeviceRegistry.device_count() == 1

      DeviceRegistry.unregister("tok")
      assert DeviceRegistry.device_count() == 0
    end

    test "is a no-op for unknown tokens" do
      assert :ok = DeviceRegistry.unregister("unknown")
    end
  end

  describe "list_devices/0" do
    test "returns all registered devices" do
      DeviceRegistry.register("a", :apns)
      DeviceRegistry.register("b", :fcm)
      assert length(DeviceRegistry.list_devices()) == 2
    end
  end

  describe "list_devices/1" do
    test "filters by platform" do
      DeviceRegistry.register("a", :apns)
      DeviceRegistry.register("b", :fcm)
      DeviceRegistry.register("c", :apns)

      assert length(DeviceRegistry.list_devices(:apns)) == 2
      assert length(DeviceRegistry.list_devices(:fcm)) == 1
    end
  end

  describe "clear_all/0" do
    test "removes every registered device" do
      DeviceRegistry.register("a", :apns)
      DeviceRegistry.register("b", :fcm)
      assert DeviceRegistry.device_count() == 2

      assert :ok = DeviceRegistry.clear_all()

      assert DeviceRegistry.device_count() == 0
      assert DeviceRegistry.list_devices() == []
    end

    test "is a no-op on an empty registry" do
      assert :ok = DeviceRegistry.clear_all()
      assert DeviceRegistry.device_count() == 0
    end
  end
end
