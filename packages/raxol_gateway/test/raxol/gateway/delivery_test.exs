defmodule Raxol.Gateway.DeliveryTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.InMemory
  alias Raxol.Gateway.Delivery
  alias Raxol.Gateway.Route

  defp adapters do
    %{
      telegram: {InMemory, %{sink: self()}},
      discord: {InMemory, %{sink: self()}}
    }
  end

  defp route(platform), do: Route.new(%{platform: platform, chat_type: :private, chat_id: 1})

  test "direct delivery sends to the originating route" do
    route = route(:telegram)
    assert :ok = Delivery.deliver(adapters(), {:direct, route}, "hi")
    assert_receive {:gateway_sent, ^route, "hi"}
  end

  test "home delivery sends to the configured home route" do
    home = route(:discord)
    assert :ok = Delivery.deliver(adapters(), {:home, home}, "cron result")
    assert_receive {:gateway_sent, ^home, "cron result"}
  end

  test "cross-platform delivery sends to the other platform" do
    dest = Route.new(%{platform: :discord, chat_type: :channel, chat_id: "c"})
    assert :ok = Delivery.deliver(adapters(), {:cross_platform, dest}, "x")
    assert_receive {:gateway_sent, ^dest, "x"}
  end

  test "explicit target string resolves to a route and delivers" do
    assert :ok = Delivery.deliver(adapters(), {:target, "discord:chan-9"}, "yo")
    assert_receive {:gateway_sent, %Route{platform: :discord, chat_id: "chan-9"}, "yo"}
  end

  describe "errors" do
    test "a target on an unconnected platform is rejected" do
      assert {:error, {:unknown_platform, "slack"}} =
               Delivery.deliver(adapters(), {:target, "slack:1"}, "x")
    end

    test "a route to a platform with no adapter is rejected" do
      route = Route.new(%{platform: :slack, chat_type: :channel, chat_id: "c"})
      assert {:error, {:no_adapter, :slack}} = Delivery.deliver(adapters(), {:direct, route}, "x")
    end

    test "a malformed target is rejected" do
      assert {:error, {:bad_target, "notarget"}} =
               Delivery.deliver(adapters(), {:target, "notarget"}, "x")
    end
  end
end
