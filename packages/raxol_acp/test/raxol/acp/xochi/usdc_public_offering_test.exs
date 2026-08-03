defmodule Raxol.ACP.Xochi.UsdcPublicOfferingTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.{TransferCore, UsdcPublicOffering}

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  # A supported stablecoin that is NOT USDC, to prove the USDC gate short-circuits
  # before the shared token guards ever run.
  @usdt_base "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2"

  @cctp_chains [1, 10, 137, 8453, 42_161]

  @ctx %{job_id: "j1", buyer: "0xbuyer", seller: "0xseller", state: :request}

  setup do
    Application.delete_env(:raxol_acp, :xochi_transfer_settler)
    Raxol.Payments.Xochi.Capabilities.reset()

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :xochi_transfer_settler)
      Raxol.Payments.Xochi.Capabilities.reset()
    end)

    :ok
  end

  defp req(overrides) do
    Map.merge(
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 42_161,
        "src_token" => @usdc_base,
        "dst_token" => @usdc_arb,
        "amount_atomic" => "1100000",
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7,
          "pull_signature" => "0x" <> String.duplicate("22", 65)
        }
      },
      overrides
    )
  end

  describe "offering metadata + schema" do
    test "declares the USDC-only public offering" do
      assert UsdcPublicOffering.offering_name() == "xochi_usdc_public"
      assert UsdcPublicOffering.cluster() == "on_chain"
    end

    test "requirement schema pins public settlement and the CCTP chain mesh" do
      schema = UsdcPublicOffering.requirements_schema()
      assert schema["properties"]["settlement_preference"]["enum"] == ["public"]
      assert schema["properties"]["src_chain_id"]["enum"] == @cctp_chains
      assert schema["properties"]["dst_chain_id"]["enum"] == @cctp_chains
    end

    test "requirement schema documents the USDC-only token constraint" do
      props = UsdcPublicOffering.requirements_schema()["properties"]
      assert props["src_token"]["description"] =~ "Only USDC is accepted"
      assert props["dst_token"]["description"] =~ "Only USDC is accepted"
    end

    test "deliverable schema drops the stealth announcement fields" do
      props = UsdcPublicOffering.deliverables_schema()["properties"]
      refute Map.has_key?(props, "stealth_address")
      refute Map.has_key?(props, "settlement_type")
    end
  end

  describe "handle_request/2" do
    test "accepts a USDC->USDC cross-chain corridor" do
      r = req(%{})
      assert {:accept, ^r} = UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "rejects a non-USDC src leg with no fallback to an unready rail" do
      r = req(%{"src_token" => @usdt_base})

      assert {:reject, {:wrong_offering, :expected_usdc}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "rejects a non-USDC dst leg too" do
      r = req(%{"dst_token" => @usdt_base})

      assert {:reject, {:wrong_offering, :expected_usdc}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "the USDC gate short-circuits before the shared token guard" do
      # A completely unknown token still reports :expected_usdc, not
      # :unsupported_src_token -- the USDC check runs first.
      bogus = "0x" <> String.duplicate("ab", 20)

      assert {:reject, {:wrong_offering, :expected_usdc}} =
               UsdcPublicOffering.handle_request(req(%{"src_token" => bogus}), @ctx)
    end

    test "rejects an order below the minimum (anti-spam)" do
      # 0.50 USDC, under the 1 USDC floor.
      r = req(%{"amount_atomic" => "500000"})

      assert {:reject, {:order_below_min, 1_000_000}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "rejects an order above the maximum ceiling" do
      # 3_001 USDC, over the 3_000 USDC ceiling.
      r = req(%{"amount_atomic" => "3001000000"})

      assert {:reject, {:order_above_max, 3_000_000_000}} =
               UsdcPublicOffering.handle_request(r, @ctx)
    end

    test "honors configured order-band overrides" do
      Application.put_env(:raxol_acp, :usdc_public_min_atomic, 2_000_000)
      on_exit(fn -> Application.delete_env(:raxol_acp, :usdc_public_min_atomic) end)

      # 1.10 USDC now falls under the raised 2 USDC floor.
      assert {:reject, {:order_below_min, 2_000_000}} =
               UsdcPublicOffering.handle_request(req(%{}), @ctx)
    end

    test "shared guards still fire once both legs are USDC (same-chain corridor)" do
      r = req(%{"dst_chain_id" => 8453, "dst_token" => @usdc_base})

      assert {:reject, :not_cross_chain} = UsdcPublicOffering.handle_request(r, @ctx)
    end
  end

  describe "resolve_accept/2" do
    # The Xochi worker's GET /api/intent/:id shape (snake_case, string amounts).
    defp intent_json(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "xi_1",
          "status" => "quoted",
          "from_chain_id" => 8453,
          "to_chain_id" => 42_161,
          "from_token" => @usdc_base,
          "to_token" => @usdc_arb,
          # 1_000 USDC principal (6dp).
          "from_amount" => "1000000000",
          "to_amount" => "999000000",
          "quote_id" => "xq_1",
          "fee_rate" => 0.003,
          "settlement_type" => "public"
        },
        overrides
      )
    end

    defp intent_plug(body, status \\ 200) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    end

    defp accept_ctx(plug) do
      %{
        chain_id: 8453,
        xochi_config: %{
          base_url: "https://api.xochi.fi",
          req_options: [plug: plug, retry: false]
        }
      }
    end

    test "derives the corridor from Xochi and sizes the fee at 8 bps of the principal" do
      ctx = accept_ctx(intent_plug(intent_json()))

      assert {:ok, resolved, budget} = UsdcPublicOffering.resolve_accept(req(%{}), ctx)

      # Authoritative corridor + amount replace whatever the buyer declared.
      assert resolved["src_chain_id"] == 8453
      assert resolved["dst_chain_id"] == 42_161
      assert resolved["src_token"] == @usdc_base
      assert resolved["dst_token"] == @usdc_arb
      assert resolved["amount_atomic"] == "1000000000"

      # 8 bps of 1_000 USDC = 0.8 USDC = 800_000 base units.
      assert budget.raw_amount == 800_000
      assert budget.symbol == "USDC"
    end

    test "ignores the buyer's declared amount, sizing the fee on the signed amount" do
      # Buyer understates amount_atomic to 1 base unit; the fee must still be
      # sized on Xochi's authoritative 1_000 USDC.
      ctx = accept_ctx(intent_plug(intent_json()))

      assert {:ok, resolved, budget} =
               UsdcPublicOffering.resolve_accept(req(%{"amount_atomic" => "1"}), ctx)

      assert resolved["amount_atomic"] == "1000000000"
      assert budget.raw_amount == 800_000
    end

    test "the derived request still passes the USDC + order-band gate" do
      ctx = accept_ctx(intent_plug(intent_json()))
      {:ok, resolved, _budget} = UsdcPublicOffering.resolve_accept(req(%{}), ctx)
      assert {:accept, ^resolved} = UsdcPublicOffering.handle_request(resolved, @ctx)
    end

    test "fails closed when no Xochi config is available" do
      ctx = %{chain_id: 8453, xochi_config: nil}
      assert {:error, :no_xochi_config} = UsdcPublicOffering.resolve_accept(req(%{}), ctx)
    end

    test "fails closed when the request carries no intent id" do
      ctx = accept_ctx(intent_plug(intent_json()))
      r = req(%{"signed_intent" => %{"quote_id" => "xq_1"}})
      assert {:reject, :missing_intent_id} = UsdcPublicOffering.resolve_accept(r, ctx)
    end

    test "rejects an intent that is not in the quoted state" do
      ctx = accept_ctx(intent_plug(intent_json(%{"status" => "executing"})))

      assert {:reject, {:intent_not_quoted, :executing}} =
               UsdcPublicOffering.resolve_accept(req(%{}), ctx)
    end

    test "rejects an unknown intent (404)" do
      ctx = accept_ctx(intent_plug(%{"error" => "Intent not found"}, 404))

      assert {:reject, {:intent_not_found, "xi_1"}} =
               UsdcPublicOffering.resolve_accept(req(%{}), ctx)
    end

    test "fails closed when Xochi is unreachable (5xx)" do
      ctx = accept_ctx(intent_plug(%{"error" => "down"}, 503))

      assert {:error, {:xochi_unreachable, {:http, 503, _}}} =
               UsdcPublicOffering.resolve_accept(req(%{}), ctx)
    end
  end

  describe "describe_rejection/1" do
    test "explains the :expected_usdc rejection without pointing at an unready rail" do
      msg = TransferCore.describe_rejection({:wrong_offering, :expected_usdc})
      assert msg =~ "USDC only"
      assert msg =~ "not settle-ready"
      refute msg =~ "xochi_stable_public"
    end

    test "explains the order-band rejections" do
      assert TransferCore.describe_rejection({:order_below_min, 1_000_000}) =~ "minimum"
      assert TransferCore.describe_rejection({:order_above_max, 3_000_000_000}) =~ "maximum"
    end
  end
end
