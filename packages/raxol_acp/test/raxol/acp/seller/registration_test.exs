defmodule Raxol.ACP.Seller.RegistrationTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.{Chain, JobApi}
  alias Raxol.ACP.JobApi.Mock
  alias Raxol.ACP.Seller.Registration

  defp configured_chain(addr \\ "0xReg0000000000000000000000000000000000A1") do
    Map.put(Chain.mainnet(), :service_registry_address, addr)
  end

  describe "Chain.require_service_registry/1" do
    test "defaults to unset (fails closed) on mainnet and sepolia" do
      assert Chain.mainnet().service_registry_address == nil
      assert Chain.sepolia().service_registry_address == nil

      assert {:error, :service_registry_not_configured} =
               Chain.require_service_registry(Chain.mainnet())
    end

    test "returns the address once configured" do
      assert {:ok, "0xReg0000000000000000000000000000000000A1"} =
               Chain.require_service_registry(configured_chain())
    end
  end

  describe "ensure_registered/3" do
    test "fails closed when the Service Registry address is unset" do
      api = Mock.new(me: nil)

      assert {:error, :service_registry_not_configured} =
               Registration.ensure_registered(Chain.mainnet(), api, %{name: "raxol"})

      # No registration happened: the agent is still unregistered.
      assert {:error, :not_found} = JobApi.get_me(api)
    end

    test "registers when the agent is not yet registered" do
      api = Mock.new(me: nil)

      assert {:ok, :registered, detail} =
               Registration.ensure_registered(configured_chain(), api, %{
                 wallet_address: "0xabc",
                 name: "raxol-seller"
               })

      assert detail.name == "raxol-seller"
      # Idempotency substrate: the agent is now discoverable via get_me.
      assert {:ok, %{name: "raxol-seller"}} = JobApi.get_me(api)
    end

    test "is idempotent: an already-registered agent is not re-registered" do
      api = Mock.new(me: %{wallet_address: "0xabc", name: "existing"})

      assert {:ok, :already_registered, %{name: "existing"}} =
               Registration.ensure_registered(configured_chain(), api, %{name: "ignored"})
    end

    test "surfaces a lookup failure distinctly from 'not registered'" do
      api = Mock.new(me: {:error, :boom})

      assert {:error, {:lookup_failed, :boom}} =
               Registration.ensure_registered(configured_chain(), api, %{name: "raxol"})
    end

    test "register_agent falls back to :registration_unsupported when the adapter omits it" do
      assert {:error, :registration_unsupported} =
               JobApi.register_agent(%{adapter: NoRegAdapter, config: %{}}, %{})

      # Mock implements it, so the same dispatch reaches the adapter.
      assert {:ok, %{name: "x"}} = JobApi.register_agent(Mock.new(me: nil), %{name: "x"})
    end
  end
end

defmodule NoRegAdapter do
  @moduledoc false
  # Deliberately implements no JobApi callbacks -> exercises the
  # register_agent/2 dispatch guard (`:registration_unsupported`).
end
