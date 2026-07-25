defmodule Raxol.Agent.Scheduler.DeliveryTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Scheduler.Delivery

  describe "local/1" do
    test "delivers to the in-process callback" do
      parent = self()

      deliver =
        Delivery.local(fn target, rendered ->
          send(parent, {:delivered, target, rendered})
          :ok
        end)

      assert :ok = deliver.("home:1", "hello")
      assert_receive {:delivered, "home:1", "hello"}
    end

    test "returns whatever the callback returns" do
      deliver = Delivery.local(fn _t, _r -> {:error, :boom} end)
      assert {:error, :boom} = deliver.("t:1", "x")
    end
  end

  describe "gateway/1" do
    test "returns gateway_unavailable when the gateway package is not loaded" do
      # raxol_agent does not depend on raxol_gateway, so Raxol.Gateway.Delivery
      # is absent here and the seam degrades rather than crashing.
      refute Code.ensure_loaded?(Raxol.Gateway.Delivery)

      deliver = Delivery.gateway(%{telegram: {SomeAdapter, :conn}})
      assert {:error, :gateway_unavailable} = deliver.("telegram:-100", "hi")
    end
  end
end
