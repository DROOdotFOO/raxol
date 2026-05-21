defmodule Raxol.Watch.NotifierTest do
  use ExUnit.Case

  alias Raxol.Watch.{DeviceRegistry, Formatter, Notifier, Push.Noop}

  setup do
    start_supervised!(Noop)
    start_supervised!(DeviceRegistry)
    start_supervised!({Notifier, push_backend: Noop})
    Noop.clear()
    :ok
  end

  describe "push_to_all/1" do
    test "pushes to all registered devices" do
      DeviceRegistry.register("tok_a", :apns)
      DeviceRegistry.register("tok_b", :fcm)

      notification = Formatter.format_announcement("Test alert")
      Notifier.push_to_all(notification)
      Notifier.flush()

      pushes = Noop.get_pushes()
      assert length(pushes) == 2
      tokens = Enum.map(pushes, fn {token, _} -> token end)
      assert "tok_a" in tokens
      assert "tok_b" in tokens
    end

    test "skips muted devices" do
      DeviceRegistry.register("muted", :apns, muted: true)
      DeviceRegistry.register("active", :fcm)

      Notifier.push_to_all(Formatter.format_announcement("Alert"))
      Notifier.flush()

      pushes = Noop.get_pushes()
      assert length(pushes) == 1
      assert {_, _} = hd(pushes)
    end

    test "high_priority_only devices only receive high priority" do
      DeviceRegistry.register("picky", :apns, high_priority_only: true)

      Notifier.push_to_all(Formatter.format_announcement("Normal alert"))
      Notifier.flush()

      assert Noop.get_pushes() == []

      Noop.clear()
      Notifier.push_to_all(Formatter.format_announcement("Critical!", :high))
      Notifier.flush()

      assert length(Noop.get_pushes()) == 1
    end
  end

  describe "push_to_all with no devices" do
    test "does not error when no devices registered" do
      Notifier.push_to_all(Formatter.format_announcement("No one listening"))
      Notifier.flush()

      assert Noop.get_pushes() == []
    end
  end
end
