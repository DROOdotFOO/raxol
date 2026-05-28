defmodule Raxol.ACP.Wallet.SCATest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Wallet.SCA.{ModularAccount, UserOp}

  @session_key_env "RAXOL_SCA_TEST_SESSION_KEY"
  # Anvil dev key #0; well-known, not a secret.
  @session_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @account "0x1234567890123456789012345678901234567890"
  @entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  defmodule SessionKey do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_SCA_TEST_SESSION_KEY", chain_id: 8453
  end

  defmodule Account do
    use Raxol.ACP.Wallet.SCA,
      account_address: "0x1234567890123456789012345678901234567890",
      chain_id: 8453,
      signer: Raxol.ACP.Wallet.SCATest.SessionKey,
      signer_entity_id: 1,
      entry_point: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
      paymaster_policy_id: "186aaa4a-5f57-4156-83fb-e456365a8820"
  end

  setup do
    System.put_env(@session_key_env, @session_privkey)
    on_exit(fn -> System.delete_env(@session_key_env) end)
    :ok
  end

  describe "identity" do
    test "address returns the SCA address, not the session key's" do
      assert Account.address() == @account
      assert Account.address() != SessionKey.address()
    end

    test "chain_id is configured" do
      assert Account.chain_id() == 8453
    end

    test "entry_point is configured" do
      assert Account.entry_point() == @entry_point
    end
  end

  describe "sign_hash/1" do
    test "errors -- SCAs do not sign raw transactions" do
      assert {:error, :sca_uses_user_operations} = Account.sign_hash(:binary.copy(<<0>>, 32))
    end
  end

  describe "nonce_key/1" do
    test "encodes the session entity with global validation" do
      assert Account.nonce_key() == ModularAccount.nonce_key(1, true, 0)
      assert Account.nonce_key(0) == 0x101
    end
  end

  describe "sign_user_op_hash/1" do
    test "produces a globally-validated UO signature recoverable to the session key" do
      uo_hash = :crypto.hash(:sha256, "user-op")
      assert {:ok, packed} = Account.sign_user_op_hash(uo_hash)

      # 0xFF 0x00 prefix + 65-byte ECDSA signature
      assert <<0xFF, 0x00, r::binary-size(32), s::binary-size(32), v::8>> = packed
      assert v in [27, 28]

      # The signature is over the EIP-191 digest of the UO hash; recover
      # and confirm it's the session key's address.
      digest = ModularAccount.eip191_digest(uo_hash)
      recovery_id = v - 27
      {:ok, pubkey} = ExSecp256k1.recover(digest, r, s, recovery_id)
      assert recovered_address(pubkey) == String.downcase(SessionKey.address())
    end
  end

  describe "sign_message/1 (EIP-1271)" do
    test "produces the single-signer 1271 frame with the configured entity" do
      assert {:ok, packed} = Account.sign_message("hello agent")

      assert <<0x00, entity::unsigned-big-32, 0xFF, 0x00, sig::binary>> = packed
      assert entity == 1
      assert byte_size(sig) == 65
      <<_r::binary-size(32), _s::binary-size(32), v::8>> = sig
      assert v in [27, 28]
    end
  end

  describe "sign_typed_data/3 (EIP-1271)" do
    test "wraps an EIP-712 hash in the replay-safe envelope and packs it" do
      domain = %{name: "ACP Auth", version: "1", chainId: 8453}
      types = %{"Challenge" => [{"nonce", "uint256"}]}
      message = %{"nonce" => 42}

      assert {:ok, packed} = Account.sign_typed_data(domain, types, message)
      assert <<0x00, 1::unsigned-big-32, 0xFF, 0x00, sig::binary>> = packed
      assert byte_size(sig) == 65
    end
  end

  describe "send_user_operation/2" do
    test "signs the op and posts it to the bundler" do
      op = %UserOp{
        sender: @account,
        nonce: 0,
        call_data: ModularAccount.execute_calldata(@account, 0, <<>>),
        call_gas_limit: 100_000,
        verification_gas_limit: 200_000,
        pre_verification_gas: 21_000,
        max_fee_per_gas: 1_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000
      }

      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:bundler_request, decoded})

        payload =
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => decoded["id"], "result" => "0xdeadbeef"})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end

      assert {:ok, "0xdeadbeef"} =
               Account.send_user_operation(op,
                 bundler_url: "http://bundler.test",
                 req: Req.new(plug: plug)
               )

      assert_received {:bundler_request,
                       %{"method" => "eth_sendUserOperation", "params" => params}}

      [sent_op, entry_point] = params
      assert entry_point == @entry_point
      # The signature was attached before sending.
      assert String.starts_with?(sent_op["signature"], "0xff00")
    end

    test "errors when no bundler url is configured or passed" do
      op = %UserOp{sender: @account}
      assert {:error, :no_bundler_url} = Account.send_user_operation(op)
    end
  end

  describe "sponsor/2 + send_sponsored_user_operation/2" do
    @gm_result %{
      "paymaster" => "0xabababababababababababababababababababab",
      "paymasterData" => "0xcafe",
      "paymasterVerificationGasLimit" => "0x7530",
      "paymasterPostOpGasLimit" => "0x2710",
      "callGasLimit" => "0xc350",
      "verificationGasLimit" => "0x186a0",
      "preVerificationGas" => "0x5208",
      "maxFeePerGas" => "0x3b9aca00",
      "maxPriorityFeePerGas" => "0x3b9aca00"
    }

    defp json_rpc_plug(result) do
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"id" => id} = Jason.decode!(body)
        payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end
    end

    test "sponsor fills gas + paymaster from the gas manager" do
      op = %UserOp{sender: @account, nonce: 0, call_data: <<0x12>>}

      assert {:ok, sponsored} =
               Account.sponsor(op,
                 paymaster_url: "http://alchemy.test",
                 req: Req.new(plug: json_rpc_plug(@gm_result))
               )

      assert sponsored.paymaster == "0xabababababababababababababababababababab"
      assert sponsored.call_gas_limit == 50_000
      assert sponsored.max_fee_per_gas == 1_000_000_000
    end

    test "errors when no policy id is configured" do
      defmodule NoPolicyAccount do
        use Raxol.ACP.Wallet.SCA,
          account_address: "0x1234567890123456789012345678901234567890",
          chain_id: 8453,
          signer: Raxol.ACP.Wallet.SCATest.SessionKey,
          signer_entity_id: 1
      end

      assert {:error, :no_paymaster_policy_id} =
               NoPolicyAccount.sponsor(%UserOp{sender: @account})
    end

    test "send_sponsored_user_operation sponsors then signs then sends" do
      op = %UserOp{sender: @account, nonce: 0, call_data: <<0x12>>}
      test_pid = self()

      # One plug serving both the gas manager and the bundler, keyed on
      # the JSON-RPC method.
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:rpc, decoded["method"]})

        result =
          case decoded["method"] do
            "alchemy_requestGasAndPaymasterAndData" -> @gm_result
            "eth_sendUserOperation" -> "0xfeedface"
          end

        payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => decoded["id"], "result" => result})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end

      assert {:ok, "0xfeedface"} =
               Account.send_sponsored_user_operation(op,
                 paymaster_url: "http://alchemy.test",
                 bundler_url: "http://alchemy.test",
                 req: Req.new(plug: plug)
               )

      # Both legs were called, in order.
      assert_received {:rpc, "alchemy_requestGasAndPaymasterAndData"}
      assert_received {:rpc, "eth_sendUserOperation"}
    end
  end

  # Drop the 0x04 uncompressed prefix, keccak the 64-byte pubkey, take
  # the last 20 bytes. Mirrors Wallets.Env address derivation.
  defp recovered_address(<<4, key_bytes::binary-size(64)>>) do
    <<_::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(key_bytes)
    "0x" <> Base.encode16(addr, case: :lower)
  end
end
