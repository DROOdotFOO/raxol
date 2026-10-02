defmodule Raxol.Payments.Actions.Payments.ExecuteDepositRouteTest do
  # #400: the deposit-route action fetches a Tron-origin quote and verifies its
  # deposit_attestation before returning the deposit instructions. raxol never
  # sends the funds; the agent's own Tron wallet funds the verified address.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments
  alias Raxol.Payments.Actions.Payments.ExecuteDepositRoute
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Xochi.Capabilities
  alias Raxol.Payments.Xochi.DepositAttestation

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @evm_recipient "0x" <> String.duplicate("ab", 20)

  @intent_id "xi_dep_1"
  @quote_id "xq_dep_1"
  @amount "1000000"
  @priv <<9::256>>

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: @tron_wallet,
        from_chain_id: 728_126_428,
        to_chain_id: 8453,
        from_token: @tron_usdt,
        to_token: @evm_recipient,
        amount_atomic: @amount,
        recipient_address: @evm_recipient,
        slippage_bps: 50
      },
      overrides
    )
  end

  defp signer_address do
    {:ok, <<_prefix::8, xy::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv)
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp attestation do
    msg =
      DepositAttestation.message(%{
        intent_id: @intent_id,
        quote_id: @quote_id,
        from_chain_id: 728_126_428,
        from_token: @tron_usdt,
        from_amount: @amount,
        deposit_address: @deposit_addr
      })

    digest =
      ("\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(msg)) <> msg)
      |> ExKeccak.hash_256()

    {:ok, sig} = ExSecp256k1.sign(digest, @priv)
    "0x" <> Base.encode16(EIP712.pack_signature(sig), case: :lower)
  end

  defp config(quote \\ %{}) do
    body =
      Map.merge(
        %{
          "intent_id" => @intent_id,
          "quote_id" => @quote_id,
          "can_solve" => true,
          "to_amount" => "995000",
          "deposit_address" => @deposit_addr,
          "deposit_attestation" => attestation(),
          "deposit_deadline" => 1_900_000_000
        },
        quote
      )

    test = self()

    plug = fn conn ->
      send(test, :quote_requested)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://xochi.test", req_options: [plug: plug]}
  end

  describe "run/2" do
    test "verifies the attestation and returns the deposit instructions" do
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      assert {:ok, result} = ExecuteDepositRoute.run(params(), ctx)
      assert result.intent_id == @intent_id
      assert result.deposit_address == @deposit_addr
      assert result.deposit_deadline == 1_900_000_000
      assert result.from_amount == @amount
      assert result.recipient_address == @evm_recipient
    end

    test "fails closed when the attestation does not recover to the pinned signer" do
      ctx = %{
        xochi_config: config(),
        deposit_attestation_signer: "0x000000000000000000000000000000000000dead"
      }

      assert {:error, :attestation_mismatch} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "fails closed when no signer is pinned" do
      ctx = %{xochi_config: config(), capabilities: Capabilities.fallback()}
      assert {:error, :deposit_signer_unavailable} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "rejects an EVM origin (deposit routes are non-EVM only)" do
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      assert {:error, {:unsupported_origin_vm, _}} =
               ExecuteDepositRoute.run(params(%{from_chain_id: 8453}), ctx)
    end

    test "errors when :xochi_config is absent from the context" do
      assert {:error, {:missing_context, :xochi_config}} =
               ExecuteDepositRoute.run(params(), %{})
    end

    # ADR-0040 decision 7: no FX rate gates a conversion yet, so a non-USD
    # destination has no par to floor against and must carry its own.
    @eure_base "0xbf6e2966A9C3D99C9E4D069E04f7Bdb9C8aa762C"

    test "a non-USD destination without a positive min_to_amount is refused before any quote" do
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      for floor <- [nil, "0", " 0 "] do
        assert {:error, {:unpriced_asset, %{side: :destination, chain_id: 8453, peg: "EUR"}}} =
                 ExecuteDepositRoute.run(
                   params(%{to_token: @eure_base, min_to_amount: floor}),
                   ctx
                 )
      end

      refute_received :quote_requested
    end

    # 1 USDT (6 decimals) into EURe (18 decimals): 0.87 EURe estimated, 0.865
    # stated as the minimum.
    @eure_quote %{
      "to_amount" => "870000000000000000",
      "min_to_amount" => "865000000000000000"
    }

    test "a quote is judged on the lowest amount it states" do
      ctx = %{xochi_config: config(@eure_quote), deposit_attestation_signer: signer_address()}
      run = &ExecuteDepositRoute.run(params(%{to_token: @eure_base, min_to_amount: &1}), ctx)

      assert {:ok, %{deposit_address: @deposit_addr, min_to_amount: "865000000000000000"}} =
               run.("865000000000000000")

      # Below the estimate, above the stated minimum.
      assert {:error,
              {:delivery_below_floor,
               %{floor: 866_000_000_000_000_000, lowest: 865_000_000_000_000_000}}} =
               run.("866000000000000000")

      # Authoritative for a dollar destination too; this quote states no minimum.
      ctx = %{xochi_config: config(), deposit_attestation_signer: signer_address()}

      assert {:error, {:delivery_below_floor, %{to_amount: "995000", lowest: 995_000}}} =
               ExecuteDepositRoute.run(params(%{min_to_amount: "995001"}), ctx)
    end

    test "a high stated minimum does not hide a low estimate" do
      # A hostile quote: 1 wei estimated, a reassuring minimum beside it.
      quote = %{"to_amount" => "1", "min_to_amount" => "900000000000000000"}
      ctx = %{xochi_config: config(quote), deposit_attestation_signer: signer_address()}

      assert {:error, {:delivery_below_floor, %{lowest: 1}}} =
               ExecuteDepositRoute.run(
                 params(%{to_token: @eure_base, min_to_amount: "850000000000000000"}),
                 ctx
               )
    end

    test "amounts served as JSON numbers come back as the strings the output declares" do
      quote = %{
        "to_amount" => 870_000_000_000_000_000,
        "min_to_amount" => 865_000_000_000_000_000
      }

      ctx = %{xochi_config: config(quote), deposit_attestation_signer: signer_address()}

      # Through `call/2`, which validates the output schema: an integer
      # `min_to_amount` passed the floor and then failed `:string`.
      assert {:ok, %{to_amount: "870000000000000000", min_to_amount: "865000000000000000"}} =
               ExecuteDepositRoute.call(
                 params(%{to_token: @eure_base, min_to_amount: "865000000000000000"}),
                 ctx
               )
    end

    test "a floor in the source's units on a non-USD destination is refused before any quote" do
      ctx = %{xochi_config: config(@eure_quote), deposit_attestation_signer: signer_address()}

      # 0.99 written at USDT's 6 decimals: about 10^-12 EURe at EURe's 18.
      assert {:error, {:implausible_min_to_amount, %{par_to_amount: 1_000_000_000_000_000_000}}} =
               ExecuteDepositRoute.run(
                 params(%{to_token: @eure_base, min_to_amount: "990000"}),
                 ctx
               )

      refute_received :quote_requested
    end

    test "a floor that is not an integer of atomic units is refused, not ignored" do
      # This quote would deliver 0.000001 USDC for 1 USDT.
      ctx = %{
        xochi_config: config(%{"to_amount" => "1"}),
        deposit_attestation_signer: signer_address()
      }

      # 79 digits is past any uint256; a million took a quarter second to parse,
      # and a few million raised `SystemLimitError` rather than a refusal.
      too_long = String.duplicate("9", 79)
      huge = String.duplicate("9", 1_000_000)

      for floor <-
            ["1e6", "995000.0", "1,000,000", "1_000_000", "-1", "abc", -5, 995_000.0] ++
              [too_long, huge] do
        assert {:error, {:invalid_min_to_amount, ^floor}} =
                 ExecuteDepositRoute.run(params(%{min_to_amount: floor}), ctx)
      end

      refute_received :quote_requested
    end
  end

  describe "registration" do
    test "is registered in the payment action set" do
      assert ExecuteDepositRoute in Payments.actions()
    end

    test "exposes the payment_execute_deposit_route tool name" do
      assert ExecuteDepositRoute.__action_meta__().name == "payment_execute_deposit_route"
    end
  end
end
