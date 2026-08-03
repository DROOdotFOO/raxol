defmodule Raxol.Earn.Seller.OfferingsTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Offering.Registry
  alias Raxol.Earn.Seller.Offerings
  alias Raxol.Earn.Xochi.{TransferOffering, UsdcPublicOffering}

  setup do
    # The Offering.Registry is started by the application; start each test from
    # an empty table, as the registry's own tests do.
    Registry.clear()
    on_exit(fn -> Application.delete_env(:raxol_earn, :offerings) end)
    :ok
  end

  describe "register_all/0" do
    test "the default is fail-closed: only the USDC-only launch offering registers" do
      assert :ok = Offerings.register_all()

      assert {:ok, spec} = Registry.lookup("xochi_usdc_public")
      assert spec.handler == UsdcPublicOffering

      # The token-agnostic / deprecated rails are NOT advertised by default; they
      # accept tokens whose settlement is not ready and would revert.
      assert :error = Registry.lookup("xochi_cross_chain_transfer")
      assert :error = Registry.lookup("xochi_stable_public")
      assert :error = Registry.lookup("xochi_stable_stealth")
    end

    test "is idempotent across repeated calls" do
      assert :ok = Offerings.register_all()
      assert :ok = Offerings.register_all()
      assert {:ok, _spec} = Registry.lookup("xochi_usdc_public")
    end

    test "honors the :offerings config to widen the set" do
      Application.put_env(:raxol_earn, :offerings, [UsdcPublicOffering, TransferOffering])
      assert Offerings.configured() == [UsdcPublicOffering, TransferOffering]

      assert :ok = Offerings.register_all()
      assert {:ok, _} = Registry.lookup("xochi_usdc_public")
      assert {:ok, spec} = Registry.lookup("xochi_cross_chain_transfer")
      assert spec.handler == TransferOffering
    end
  end
end
