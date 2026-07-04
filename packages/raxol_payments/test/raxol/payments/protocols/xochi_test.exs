defmodule Raxol.Payments.Protocols.XochiTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  # Signs with a fixed 65-byte signature (520 bits). The signature value is
  # irrelevant to the nonce behaviour under test; this is a signing-boundary
  # stub, not a mock of an internal module.
  defmodule SignerWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_domain, _types, _message), do: {:ok, <<7::size(520)>>}
  end

  describe "Protocol behaviour stubs" do
    test "name returns Xochi" do
      assert Xochi.name() == "Xochi"
    end

    test "detect? always returns false" do
      refute Xochi.detect?(402, [{"payment-required", "test"}])
      refute Xochi.detect?(200, [])
    end

    test "parse_challenge returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_challenge([])
    end

    test "build_payment returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.build_payment(%{}, MockWallet)
    end

    test "parse_receipt returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_receipt([])
    end
  end

  describe "amount/1" do
    test "extracts to_amount as Decimal" do
      assert Decimal.equal?(
               Xochi.amount(%{to_amount: "1000000"}),
               Decimal.new("1000000")
             )
    end

    test "falls back to xochi_fee" do
      assert Decimal.equal?(
               Xochi.amount(%{xochi_fee: "3000"}),
               Decimal.new("3000")
             )
    end

    test "returns zero for unknown shape" do
      assert Decimal.equal?(Xochi.amount(%{}), Decimal.new(0))
    end
  end

  describe "validate_quote (via execute)" do
    test "rejects quotes that cannot be solved" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: false,
        error: "no liquidity"
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, {:cannot_solve, "no liquidity"}} =
               Xochi.execute(config, quote_resp, MockWallet)
    end

    test "rejects quotes without eip712 data" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: true,
        eip712_data: nil
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, :no_eip712_data} =
               Xochi.execute(config, quote_resp, MockWallet)
    end
  end

  describe "execute/3 nonce" do
    test "sends the nonce embedded in the signed eip712 message" do
      quote_resp = quote_with_nonce(42)

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 42
    end

    test "defaults to 0 when the signed message carries no nonce" do
      # The legacy/9-field Intent type the worker served has no nonce field.
      quote_resp = %QuoteResponse{
        intent_id: "xi_" <> String.duplicate("a", 32),
        quote_id: "xq_" <> String.duplicate("b", 32),
        can_solve: true,
        eip712_data: %{
          "domain" => %{"name" => "Xochi Intent", "version" => "1", "chainId" => 8453},
          "primaryType" => "Intent",
          "types" => %{"Intent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_x"}
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 0
    end
  end

  describe "execute_signed/2 (storefront relay)" do
    # raxol as pure storefront: it relays the BUYER's pre-signed intent without
    # re-signing. There is no wallet argument -- raxol never touches the transfer
    # funds; Riddler verifies the signature against its own persisted quote.
    test "relays the buyer's signed bundle verbatim, without a wallet" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute_signed(config, signed_bundle())
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)

      assert body["intent_id"] == "xi_" <> String.duplicate("a", 32)
      assert body["quote_id"] == "xq_" <> String.duplicate("b", 32)
      assert body["signature"] == "0x" <> String.duplicate("11", 65)
      assert body["pull_signature"] == "0x" <> String.duplicate("22", 65)
      assert body["nonce"] == 7
    end

    test "omits pull_signature for a non-pull bundle" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = Map.delete(signed_bundle(), :pull_signature)

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      refute Map.has_key?(Jason.decode!(raw_body), "pull_signature")
    end

    test "accepts a string-keyed bundle (as decoded from an ACP requirement)" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = %{
        "intent_id" => "xi_str",
        "quote_id" => "xq_str",
        "signature" => "0x" <> String.duplicate("33", 65),
        "nonce" => 9
      }

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)
      assert body["intent_id"] == "xi_str"
      assert body["nonce"] == 9
    end

    test "passes through an aztec_proof for a shielded claim" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = signed_bundle(%{aztec_proof: "0x" <> String.duplicate("ab", 64)})

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      assert Jason.decode!(raw_body)["aztec_proof"] == "0x" <> String.duplicate("ab", 64)
    end

    test "fails closed on a missing or malformed field, before any network call" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      for field <- [:intent_id, :quote_id, :signature] do
        bundle = Map.delete(signed_bundle(), field)
        assert {:error, {:invalid_signed_intent, ^field}} = Xochi.execute_signed(config, bundle)
      end

      # nonce must be a non-negative integer (the worker's replay-dedup key); a
      # numeric string or a negative value is rejected, not coerced.
      assert {:error, {:invalid_signed_intent, :nonce}} =
               Xochi.execute_signed(config, signed_bundle(%{nonce: -1}))

      assert {:error, {:invalid_signed_intent, :nonce}} =
               Xochi.execute_signed(config, signed_bundle(%{nonce: "7"}))

      # an empty signature is not a signature
      assert {:error, {:invalid_signed_intent, :signature}} =
               Xochi.execute_signed(config, signed_bundle(%{signature: ""}))

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end
  end

  describe "sign_intent/3 (buyer-side: quote -> sign -> bundle, no execute)" do
    @signer_addr "0x1111111111111111111111111111111111111111"

    test "returns a relayable bundle and does not POST execute" do
      quote_resp = quote_with_nonce(42)

      # No config, no network -- sign_intent never talks to the worker.
      assert {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet)
      assert bundle.intent_id == quote_resp.intent_id
      assert bundle.quote_id == quote_resp.quote_id
      assert bundle.nonce == 42
      assert is_binary(bundle.signature)
      assert String.starts_with?(bundle.signature, "0x")
      # No pull authorization in this quote -> no pull_signature key.
      refute Map.has_key?(bundle, :pull_signature)
    end

    test "the signed bundle relays verbatim through execute_signed" do
      quote_resp = quote_with_nonce(42)
      {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet)

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw}
      body = Jason.decode!(raw)
      assert body["signature"] == bundle.signature
      assert body["nonce"] == 42
      assert body["intent_id"] == quote_resp.intent_id
      assert body["quote_id"] == quote_resp.quote_id
    end

    test "sign_intent + execute_signed produces the same POST as execute" do
      # The extracted sign half composes back into the full execute: relaying the
      # signed bundle yields byte-for-byte the request execute/3 would send.
      quote_resp = quote_with_nonce(42)

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _h, direct_body}

      {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet)
      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, relayed_body}

      assert Jason.decode!(direct_body) == Jason.decode!(relayed_body)
    end

    test "includes pull_signature when the quote carries an origin pull" do
      pull = canonical_erc3009_pull(%{message: %{"from" => @signer_addr}})

      quote_resp = %QuoteResponse{
        intent_id: "xi_pull",
        quote_id: "xq_pull",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_pull"}
        },
        pull_authorization: pull
      }

      request = %QuoteRequest{
        wallet: @signer_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet, request)
      assert is_binary(bundle.pull_signature)
      assert String.starts_with?(bundle.pull_signature, "0x")
    end

    test "rejects a quote that cannot be solved, without signing" do
      quote_resp = %QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: false,
        error: "no liquidity"
      }

      assert {:error, {:cannot_solve, "no liquidity"}} =
               Xochi.sign_intent(quote_resp, SignerWallet)
    end

    test "refuses to sign a served pull authorization with no request context" do
      pull = canonical_erc3009_pull(%{message: %{"from" => @signer_addr}})

      quote_resp = %QuoteResponse{
        intent_id: "xi_noctx",
        quote_id: "xq_noctx",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_noctx"}
        },
        pull_authorization: pull
      }

      assert {:error, {:authorization_mismatch, :no_request_context}} =
               Xochi.sign_intent(quote_resp, SignerWallet)
    end
  end

  describe "quote_and_sign/3 (buyer-side one-shot)" do
    test "fetches a quote then signs it into a relayable bundle" do
      quote_json = %{
        "intentId" => "xi_qs",
        "quoteId" => "xq_qs",
        "canSolve" => true,
        "eip712Data" => %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "nonce", "type" => "uint256"}]},
          "message" => %{"nonce" => 5}
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: json_plug(quote_json)]
      }

      request = %QuoteRequest{
        wallet: "0x1111111111111111111111111111111111111111",
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:ok, bundle} = Xochi.quote_and_sign(config, request, SignerWallet)
      assert bundle.intent_id == "xi_qs"
      assert bundle.quote_id == "xq_qs"
      assert bundle.nonce == 5
      assert is_binary(bundle.signature)
    end
  end

  describe "execute/3 domain parity" do
    @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    @anvil_addr "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

    defmodule RealWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "RAXOL_XOCHI_DOMAIN_TEST_KEY"
    end

    setup do
      System.put_env("RAXOL_XOCHI_DOMAIN_TEST_KEY", @anvil_key)
      on_exit(fn -> System.delete_env("RAXOL_XOCHI_DOMAIN_TEST_KEY") end)
      :ok
    end

    test "derives a unique execute nonce from the pull authorization's bytes32 nonce" do
      # The served XochiIntent carries no nonce, and the worker dedups replays on
      # the execute nonce, so it must be unique per intent -- a constant 0 makes the
      # worker reject the wallet's second non-terminal intent. Derived from the low
      # 48 bits of the pull's server-issued nonce. High bytes 0xaa with low 6 bytes
      # 0xffffffffffff prove only the low 48 bits are taken.
      pull =
        canonical_erc3009_pull(%{
          message: %{"nonce" => "0x" <> String.duplicate("aa", 26) <> "ffffffffffff"}
        })

      quote_resp = %QuoteResponse{
        intent_id: "xi_pullnonce",
        quote_id: "xq_pullnonce",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_pullnonce"}
        },
        pull_authorization: pull
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 281_474_976_710_655
    end

    test "signs the served domain verbatim when it omits verifyingContract" do
      # Canonical 12-field XochiIntent domain has no verifyingContract.
      types_wire = [
        %{"name" => "intentId", "type" => "string"},
        %{"name" => "wallet", "type" => "address"},
        %{"name" => "nonce", "type" => "uint256"}
      ]

      message = %{"intentId" => "xi_test", "wallet" => @anvil_addr, "nonce" => 0}

      quote_resp = %QuoteResponse{
        intent_id: "xi_test",
        quote_id: "xq_test",
        can_solve: true,
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => types_wire},
          "message" => message
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      sent_sig = Jason.decode!(raw_body)["signature"]

      # The signature must be over a 3-field EIP712Domain (no verifyingContract),
      # matching what the worker and solver hash.
      types = %{"XochiIntent" => Enum.map(types_wire, fn f -> {f["name"], f["type"]} end)}
      domain = %{name: "Xochi", version: "1", chainId: 8453}
      {:ok, raw} = RealWallet.sign_typed_data(domain, types, message)
      expected_sig = "0x" <> Base.encode16(raw, case: :lower)

      assert sent_sig == expected_sig
    end

    test "includes verifyingContract in the domain when the server provides it" do
      # The legacy/9-field shape carries a verifyingContract; it must be signed
      # into a 4-field EIP712Domain, not dropped.
      vc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

      types_wire = [
        %{"name" => "intentId", "type" => "string"},
        %{"name" => "wallet", "type" => "address"},
        %{"name" => "nonce", "type" => "uint256"}
      ]

      message = %{"intentId" => "xi_test", "wallet" => @anvil_addr, "nonce" => 0}

      quote_resp = %QuoteResponse{
        intent_id: "xi_test",
        quote_id: "xq_test",
        can_solve: true,
        eip712_data: %{
          "domain" => %{
            "name" => "Xochi",
            "version" => "1",
            "chainId" => 8453,
            "verifyingContract" => vc
          },
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => types_wire},
          "message" => message
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      sent_sig = Jason.decode!(raw_body)["signature"]

      types = %{"XochiIntent" => Enum.map(types_wire, fn f -> {f["name"], f["type"]} end)}
      domain = %{name: "Xochi", version: "1", chainId: 8453, verifyingContract: vc}
      {:ok, raw} = RealWallet.sign_typed_data(domain, types, message)

      assert sent_sig == "0x" <> Base.encode16(raw, case: :lower)
    end

    property "signs the served typed data and echoes its nonce, for any served eip712" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      check all(served <- served_eip712_gen()) do
        quote_resp = %QuoteResponse{
          intent_id: served["message"]["intentId"],
          quote_id: "xq_test",
          can_solve: true,
          eip712_data: served
        }

        assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet)
        assert_receive {:req, "POST", "/api/intent/execute", _h, body}
        decoded = Jason.decode!(body)

        # 1. the execute nonce echoes the signed message nonce
        assert decoded["nonce"] == served["message"]["nonce"]

        # 2. the signature is over the canonically-rebuilt typed data (the exact
        #    domain/types/message the worker and solver hash). Built independently
        #    of the protocol's own construction so a regression diverges the sig.
        types = %{
          "XochiIntent" =>
            Enum.map(served["types"]["XochiIntent"], fn f -> {f["name"], f["type"]} end)
        }

        {:ok, raw} =
          RealWallet.sign_typed_data(build_domain(served["domain"]), types, served["message"])

        assert decoded["signature"] == "0x" <> Base.encode16(raw, case: :lower)
      end
    end

    test "signs the served pull_authorization and sends it as pull_signature" do
      pull = canonical_erc3009_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_pull",
        quote_id: "xq_pull",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_pull"}
        },
        pull_authorization: pull
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)

      # The pull_signature is over the served pull_authorization typed data,
      # rebuilt independently so a regression diverges the signature.
      pull_types = %{
        "ReceiveWithAuthorization" =>
          Enum.map(pull["types"]["ReceiveWithAuthorization"], fn f -> {f["name"], f["type"]} end)
      }

      pull_domain = %{
        name: "USD Coin",
        version: "2",
        chainId: 8453,
        verifyingContract: pull["domain"]["verifyingContract"]
      }

      {:ok, raw} = RealWallet.sign_typed_data(pull_domain, pull_types, pull["message"])

      assert body["pull_signature"] == "0x" <> Base.encode16(raw, case: :lower)
      # Distinct payload from the intent signature.
      assert body["pull_signature"] != body["signature"]
    end

    test "omits pull_signature when the quote carries no pull_authorization" do
      quote_resp = %QuoteResponse{
        intent_id: "xi_nopull",
        quote_id: "xq_nopull",
        can_solve: true,
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_nopull"}
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      refute Map.has_key?(Jason.decode!(raw_body), "pull_signature")
    end

    test "refuses to authorize a pull that exceeds the amount, retargets the token, or is not from the signer" do
      erc3009_pull = fn overrides -> canonical_erc3009_pull(overrides) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_bad",
          quote_id: "xq_bad",
          can_solve: true,
          payment_method: "erc3009",
          eip712_data: %{
            "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
            "primaryType" => "XochiIntent",
            "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
            "message" => %{"intentId" => "xi_bad"}
          },
          pull_authorization: pull
        }
      end

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # value far above the intended origin amount, redirected to an attacker -- the drain vector
      over =
        quote_for.(
          erc3009_pull.(%{
            message: %{
              "value" => "100000000",
              "to" => "0x000000000000000000000000000000000000dEaD"
            }
          })
        )

      assert {:error, {:authorization_mismatch, :pull_value}} =
               Xochi.execute(config, over, RealWallet, request)

      # retargeted to a different token contract
      wrong_token =
        quote_for.(
          erc3009_pull.(%{
            domain: %{"verifyingContract" => "0x0000000000000000000000000000000000000bad"}
          })
        )

      assert {:error, {:authorization_mismatch, :pull_token}} =
               Xochi.execute(config, wrong_token, RealWallet, request)

      # pull from someone other than the signer
      wrong_from =
        quote_for.(
          erc3009_pull.(%{message: %{"from" => "0x000000000000000000000000000000000000beef"}})
        )

      assert {:error, {:authorization_mismatch, :pull_from}} =
               Xochi.execute(config, wrong_from, RealWallet, request)

      # nothing was signed or submitted for any rejected pull
      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "binds the pull recipient to an operator solver allowlist when configured" do
      solver = "0x0000000000000000000000000000000000005011"
      attacker = "0x000000000000000000000000000000000000dEaD"

      pull_to = fn to -> canonical_erc3009_pull(%{message: %{"to" => to}}) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_sv",
          quote_id: "xq_sv",
          can_solve: true,
          payment_method: "erc3009",
          eip712_data: %{
            "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
            "primaryType" => "XochiIntent",
            "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
            "message" => %{"intentId" => "xi_sv"}
          },
          pull_authorization: pull
        }
      end

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # fail-open: with no allowlist set, any solver recipient is accepted
      assert {:ok, _} =
               Xochi.execute(config, quote_for.(pull_to.(solver)), RealWallet, request)

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [solver])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      # an allowlisted recipient still passes
      assert {:ok, _} =
               Xochi.execute(config, quote_for.(pull_to.(solver)), RealWallet, request)

      # a recipient outside the allowlist is rejected before any signature
      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_for.(pull_to.(attacker)), RealWallet, request)
    end

    test "pins the canonical solver address the live gate uses, case-insensitively" do
      # The live gate pins this checksummed (mixed-case) Riddler solver. The
      # allowlist normalizes case, so a pull to the same address as the worker
      # serves it (lowercased) passes, while any other recipient is rejected
      # before signing -- the forged-`to` abort the gate relies on.
      canonical = "0x97D447561fDe10E959E782a29411D8F89586d80b"
      attacker = "0x000000000000000000000000000000000000dEaD"

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [canonical])
      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

      on_exit(fn ->
        Application.delete_env(:raxol_payments, :pull_solver_allowlist)
        Application.delete_env(:raxol_payments, :pull_require_solver_pin)
      end)

      pull_to = fn to -> canonical_erc3009_pull(%{message: %{"to" => to}}) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_canon",
          quote_id: "xq_canon",
          can_solve: true,
          payment_method: "erc3009",
          eip712_data: %{
            "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
            "primaryType" => "XochiIntent",
            "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
            "message" => %{"intentId" => "xi_canon"}
          },
          pull_authorization: pull
        }
      end

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # the pinned solver passes even when served lowercased
      assert {:ok, _} =
               Xochi.execute(
                 config,
                 quote_for.(pull_to.(String.downcase(canonical))),
                 RealWallet,
                 request
               )

      # any other recipient aborts with :pull_to
      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_for.(pull_to.(attacker)), RealWallet, request)
    end

    test "binds the permit2 spender to the solver allowlist when configured" do
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [
        "0x0000000000000000000000000000000000005011"
      ])

      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      # spender 0x...dEaD is not in the configured allowlist
      pull = canonical_permit2_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_p2",
        quote_id: "xq_p2",
        can_solve: true,
        payment_method: "permit2",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_p2"}
        },
        pull_authorization: pull
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_spender}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "rejects a permit2 pull when no solver allowlist is configured (fail-closed)" do
      # Permit2 has NO on-chain recipient guard -- the spender picks where funds go
      # at call time -- so the pin is the only destination control and is always
      # required. With no allowlist set, a permit2 pull is unsafe to sign.
      pull = canonical_permit2_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_p2o",
        quote_id: "xq_p2o",
        can_solve: true,
        payment_method: "permit2",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_p2o"}
        },
        pull_authorization: pull
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_spender}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "rejects an erc3009 pull when pull_require_solver_pin is set and no allowlist" do
      # ERC-3009 is bounded even unpinned (the signed `to` + on-chain msg.sender ==
      # to), but an operator can demand a hard pin. With the flag on and no
      # allowlist, even a well-formed pull must be rejected before any signature.
      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_require_solver_pin) end)

      pull = canonical_erc3009_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_pin",
        quote_id: "xq_pin",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_pin"}
        },
        pull_authorization: pull
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "rejects a pull whose envelope or expiry diverges from the claimed method" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      request = %QuoteRequest{
        wallet: @anvil_addr,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_env",
          quote_id: "xq_env",
          can_solve: true,
          payment_method: "erc3009",
          eip712_data: %{
            "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
            "primaryType" => "XochiIntent",
            "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
            "message" => %{"intentId" => "xi_env"}
          },
          pull_authorization: pull
        }
      end

      # TransferWithAuthorization has the same field names but no on-chain
      # `msg.sender == to` guard -- the validator must reject the wrong primaryType.
      transfer_fields = [
        %{"name" => "from", "type" => "address"},
        %{"name" => "to", "type" => "address"},
        %{"name" => "value", "type" => "uint256"},
        %{"name" => "validAfter", "type" => "uint256"},
        %{"name" => "validBefore", "type" => "uint256"},
        %{"name" => "nonce", "type" => "bytes32"}
      ]

      transfer_auth =
        canonical_erc3009_pull(%{
          primary_type: "TransferWithAuthorization",
          types: %{"TransferWithAuthorization" => transfer_fields}
        })

      assert {:error, {:authorization_mismatch, :pull_type}} =
               Xochi.execute(config, quote_for.(transfer_auth), RealWallet, request)

      # An extra signable field the validator never inspects.
      extra =
        canonical_erc3009_pull(%{
          types: %{
            "ReceiveWithAuthorization" =>
              transfer_fields ++ [%{"name" => "evil", "type" => "address"}]
          }
        })

      assert {:error, {:authorization_mismatch, :pull_type}} =
               Xochi.execute(config, quote_for.(extra), RealWallet, request)

      # Already-expired authorization.
      expired = canonical_erc3009_pull(%{message: %{"validBefore" => "1"}})

      assert {:error, {:authorization_mismatch, :pull_expiry}} =
               Xochi.execute(config, quote_for.(expired), RealWallet, request)

      # Standing / far-future authorization beyond the bounded window.
      far =
        canonical_erc3009_pull(%{
          message: %{"validBefore" => Integer.to_string(System.system_time(:second) + 999_999)}
        })

      assert {:error, {:authorization_mismatch, :pull_expiry}} =
               Xochi.execute(config, quote_for.(far), RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "refuses to sign a pull authorization with no request context (execute/3)" do
      pull = %{
        "domain" => %{
          "name" => "USD Coin",
          "version" => "2",
          "chainId" => 8453,
          "verifyingContract" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        },
        "primaryType" => "ReceiveWithAuthorization",
        "types" => %{
          "ReceiveWithAuthorization" => [
            %{"name" => "from", "type" => "address"},
            %{"name" => "to", "type" => "address"},
            %{"name" => "value", "type" => "uint256"}
          ]
        },
        "message" => %{"from" => @anvil_addr, "to" => @anvil_addr, "value" => "1000000"}
      }

      quote_resp = %QuoteResponse{
        intent_id: "xi_noctx",
        quote_id: "xq_noctx",
        can_solve: true,
        payment_method: "erc3009",
        eip712_data: %{
          "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
          "primaryType" => "XochiIntent",
          "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_noctx"}
        },
        pull_authorization: pull
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :no_request_context}} =
               Xochi.execute(config, quote_resp, RealWallet)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end
  end

  # -- Helpers --

  defp hex_gen(len), do: StreamData.string([?0..?9, ?a..?f], length: len)

  defp address_gen, do: StreamData.map(hex_gen(40), &("0x" <> &1))

  defp domain_gen do
    base =
      StreamData.fixed_map(%{
        "name" => StreamData.constant("Xochi"),
        "version" => StreamData.member_of(["1", "1-prod", "1-staging"]),
        "chainId" => StreamData.member_of([1, 8453, 42_161, 10, 137])
      })

    StreamData.one_of([
      base,
      StreamData.bind(base, fn d ->
        StreamData.map(address_gen(), &Map.put(d, "verifyingContract", &1))
      end)
    ])
  end

  defp served_eip712_gen do
    gen all(
          domain <- domain_gen(),
          intent_id <- StreamData.map(hex_gen(32), &("xi_" <> &1)),
          wallet <- address_gen(),
          nonce <- StreamData.integer(0..1_000_000)
        ) do
      %{
        "domain" => domain,
        "primaryType" => "XochiIntent",
        "types" => %{
          "XochiIntent" => [
            %{"name" => "intentId", "type" => "string"},
            %{"name" => "wallet", "type" => "address"},
            %{"name" => "nonce", "type" => "uint256"}
          ]
        },
        "message" => %{"intentId" => intent_id, "wallet" => wallet, "nonce" => nonce}
      }
    end
  end

  # Canonical EIP-712 domain: only the keys the server actually served, atom-keyed.
  defp build_domain(d) do
    base = %{name: d["name"], version: d["version"], chainId: d["chainId"]}

    case d["verifyingContract"] do
      nil -> base
      vc -> Map.put(base, :verifyingContract, vc)
    end
  end

  defp quote_with_nonce(nonce) do
    %QuoteResponse{
      intent_id: "xi_" <> String.duplicate("a", 32),
      quote_id: "xq_" <> String.duplicate("b", 32),
      can_solve: true,
      eip712_data: %{
        "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
        "primaryType" => "XochiIntent",
        "types" => %{"XochiIntent" => [%{"name" => "nonce", "type" => "uint256"}]},
        "message" => %{"nonce" => nonce}
      }
    }
  end

  # A buyer-signed intent bundle, as handed to the storefront relay. raxol
  # relays it verbatim; there is no wallet in execute_signed/2. Signature values
  # are opaque (Riddler verifies them against its persisted quote).
  defp signed_bundle(overrides \\ %{}) do
    Map.merge(
      %{
        intent_id: "xi_" <> String.duplicate("a", 32),
        quote_id: "xq_" <> String.duplicate("b", 32),
        signature: "0x" <> String.duplicate("11", 65),
        nonce: 7,
        pull_signature: "0x" <> String.duplicate("22", 65)
      },
      overrides
    )
  end

  defp echo_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "submitted"}))
    end
  end

  # Serves a fixed JSON body on any path (used to stub a quote response).
  defp json_plug(json) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(json))
    end
  end

  # A canonical ERC-3009 ReceiveWithAuthorization pull (all six signed fields, a
  # future validBefore). `overrides` may carry :message, :domain, :primary_type,
  # :types to exercise the envelope/expiry binding.
  defp canonical_erc3009_pull(overrides \\ %{}) do
    valid_before = Integer.to_string(System.system_time(:second) + 600)

    message =
      Map.merge(
        %{
          "from" => @anvil_addr,
          "to" => @anvil_addr,
          "value" => "1000000",
          "validAfter" => "0",
          "validBefore" => valid_before,
          "nonce" => "0x" <> String.duplicate("00", 31) <> "01"
        },
        Map.get(overrides, :message, %{})
      )

    domain =
      Map.merge(
        %{
          "name" => "USD Coin",
          "version" => "2",
          "chainId" => 8453,
          "verifyingContract" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        },
        Map.get(overrides, :domain, %{})
      )

    %{
      "domain" => domain,
      "primaryType" => Map.get(overrides, :primary_type, "ReceiveWithAuthorization"),
      "types" =>
        Map.get(overrides, :types, %{
          "ReceiveWithAuthorization" => [
            %{"name" => "from", "type" => "address"},
            %{"name" => "to", "type" => "address"},
            %{"name" => "value", "type" => "uint256"},
            %{"name" => "validAfter", "type" => "uint256"},
            %{"name" => "validBefore", "type" => "uint256"},
            %{"name" => "nonce", "type" => "bytes32"}
          ]
        }),
      "message" => message
    }
  end

  # A canonical Permit2 PermitWitnessTransferFrom pull (future deadline).
  defp canonical_permit2_pull(overrides \\ %{}) do
    deadline = Integer.to_string(System.system_time(:second) + 600)

    message =
      Map.merge(
        %{
          "permitted" => %{
            "token" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
            "amount" => "1000000"
          },
          "spender" => "0x000000000000000000000000000000000000dEaD",
          "nonce" => "1",
          "deadline" => deadline,
          "witness" => %{"orderId" => "0x" <> String.duplicate("00", 32)}
        },
        Map.get(overrides, :message, %{})
      )

    %{
      "domain" => Map.merge(%{"chainId" => 8453}, Map.get(overrides, :domain, %{})),
      "primaryType" => Map.get(overrides, :primary_type, "PermitWitnessTransferFrom"),
      "types" =>
        Map.get(overrides, :types, %{
          "PermitWitnessTransferFrom" => [
            %{"name" => "permitted", "type" => "TokenPermissions"},
            %{"name" => "spender", "type" => "address"},
            %{"name" => "nonce", "type" => "uint256"},
            %{"name" => "deadline", "type" => "uint256"},
            %{"name" => "witness", "type" => "OriginPullWitness"}
          ],
          "TokenPermissions" => [
            %{"name" => "token", "type" => "address"},
            %{"name" => "amount", "type" => "uint256"}
          ],
          "OriginPullWitness" => [%{"name" => "orderId", "type" => "bytes32"}]
        }),
      "message" => message
    }
  end

  describe "origin_pull_fail_open?/2" do
    test "an empty allowlist with the pin not required is fail-open" do
      assert Xochi.origin_pull_fail_open?([], false)
      assert Xochi.origin_pull_fail_open?(nil, false)
      # Blank/non-binary entries normalize away to an empty list.
      assert Xochi.origin_pull_fail_open?(["", "  "], false)
      assert Xochi.origin_pull_fail_open?([nil, 123], false)
    end

    test "an empty allowlist with the pin required is fail-closed (not fail-open)" do
      refute Xochi.origin_pull_fail_open?([], true)
    end

    test "a populated allowlist is never fail-open, pin required or not" do
      refute Xochi.origin_pull_fail_open?(["0x97D447561fDe10E959E782a29411D8F89586d80b"], false)
      refute Xochi.origin_pull_fail_open?(["0x97D447561fDe10E959E782a29411D8F89586d80b"], true)
    end
  end

  describe "assert_origin_pull_pinned!/2" do
    test "raises when fail-open" do
      assert_raise ArgumentError, ~r/solver pin is not configured/, fn ->
        Xochi.assert_origin_pull_pinned!([], false)
      end
    end

    test "returns :ok when the pin is required, even with an empty allowlist" do
      assert :ok = Xochi.assert_origin_pull_pinned!([], true)
    end

    test "returns :ok when the allowlist is populated" do
      assert :ok =
               Xochi.assert_origin_pull_pinned!(
                 ["0x97D447561fDe10E959E782a29411D8F89586d80b"],
                 false
               )
    end
  end
end
