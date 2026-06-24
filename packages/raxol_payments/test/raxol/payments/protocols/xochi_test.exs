defmodule Raxol.Payments.Protocols.XochiTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

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

  defp echo_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "submitted"}))
    end
  end
end
