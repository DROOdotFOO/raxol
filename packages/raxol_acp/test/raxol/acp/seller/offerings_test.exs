defmodule Raxol.ACP.Seller.OfferingsTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Offering.Registry
  alias Raxol.ACP.Seller.Offerings
  alias Raxol.ACP.Xochi.{TransferOffering, UsdcPublicOffering}

  @offering "xochi_cross_chain_transfer"

  setup do
    # The Offering.Registry is started by the application; start each test from
    # an empty table, as the registry's own tests do.
    Registry.clear()
    on_exit(fn -> Application.delete_env(:raxol_acp, :offerings) end)
    :ok
  end

  describe "register_all/0" do
    test "registers the default offerings into the registry" do
      assert :error = Registry.lookup(@offering)

      assert :ok = Offerings.register_all()

      assert {:ok, spec} = Registry.lookup(@offering)
      assert spec.handler == TransferOffering
    end

    test "registers the USDC-only launch offering by default" do
      assert :ok = Offerings.register_all()

      assert {:ok, spec} = Registry.lookup("xochi_usdc_public")
      assert spec.handler == UsdcPublicOffering
    end

    test "is idempotent across repeated calls" do
      assert :ok = Offerings.register_all()
      assert :ok = Offerings.register_all()
      assert {:ok, _spec} = Registry.lookup(@offering)
    end

    test "honors the :offerings config" do
      Application.put_env(:raxol_acp, :offerings, [TransferOffering])
      assert Offerings.configured() == [TransferOffering]
    end
  end
end
