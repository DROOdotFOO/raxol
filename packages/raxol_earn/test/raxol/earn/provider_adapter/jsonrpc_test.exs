defmodule Raxol.Earn.ProviderAdapter.JSONRPCTest do
  @moduledoc """
  Real-endpoint test for `Raxol.Earn.ProviderAdapter.JSONRPC` against a
  Base mainnet fork (anvil). No mocks -- every assertion goes through
  real ABI encoding, real ECDSA signing, real RPC.

  Tagged `:live_chain` (requires foundry on PATH); opt-in via
  `mix test --include live_chain`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.ProviderAdapter
  alias Raxol.Earn.ProviderAdapter.JSONRPC
  alias Raxol.Earn.Test.AnvilHarness

  @moduletag :live_chain

  # USDC on Base mainnet. The fork has the real bytecode + storage.
  # Use lowercase -- some RPC providers reject mixed-case (non-checksummed)
  # addresses but accept lowercase canonical form.
  @base_usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  setup_all do
    rpc = AnvilHarness.start!(port: 8610, chain_id: 8453)
    %{address: addr, private_key: pk} = AnvilHarness.anvil_account(0)
    AnvilHarness.anvil_set_balance(rpc, addr, 10 * 10 ** 18)

    adapter =
      JSONRPC.new(
        chains: %{8453 => rpc},
        private_key: pk,
        fee_overrides: %{
          8453 => %{
            max_priority_fee_per_gas: 1_000_000_000,
            max_fee_per_gas: 5_000_000_000
          }
        }
      )

    %{adapter: adapter, address: addr, private_key: pk, rpc: rpc}
  end

  describe "identity" do
    test "get_address/1 derives the EOA from the private key", %{adapter: a, address: addr} do
      assert String.downcase(ProviderAdapter.get_address(a)) == String.downcase(addr)
    end

    test "supported_chain_ids/1 lists configured chains", %{adapter: a} do
      assert ProviderAdapter.supported_chain_ids(a) == [8453]
    end
  end

  describe "read_contract/3 against real USDC bytecode on the fork" do
    test "name() returns 'USD Coin'", %{adapter: a} do
      assert {:ok, "0x" <> _ = result} =
               ProviderAdapter.read_contract(a, 8453, %{
                 address: @base_usdc,
                 signature: "name()",
                 args: []
               })

      # ABI returns a string -- offset(32) + length(32) + data, length-padded.
      # Skip the boilerplate and check the substring.
      assert result =~ "5553442043"
    end

    test "symbol() returns 'USDC'", %{adapter: a} do
      assert {:ok, "0x" <> _ = result} =
               ProviderAdapter.read_contract(a, 8453, %{
                 address: @base_usdc,
                 signature: "symbol()",
                 args: []
               })

      # "USDC" hex = 55534443
      assert result =~ "55534443"
    end

    test "decimals() returns 6", %{adapter: a} do
      assert {:ok, hex} =
               ProviderAdapter.read_contract(a, 8453, %{
                 address: @base_usdc,
                 signature: "decimals()",
                 args: []
               })

      "0x" <> tail = hex
      assert String.to_integer(tail, 16) == 6
    end

    test "balanceOf(random_address) returns a well-formed uint256", %{adapter: a} do
      # Randomize per-run so we don't accidentally collide with a real
      # USDC holder on the Base mainnet fork.
      addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

      assert {:ok, "0x" <> hex} =
               ProviderAdapter.read_contract(a, 8453, %{
                 address: @base_usdc,
                 signature: "balanceOf(address)",
                 args: [{"address", addr}]
               })

      assert byte_size(hex) == 64
      # A freshly random address has astronomically low odds of holding USDC.
      assert String.to_integer(hex, 16) == 0
    end
  end

  describe "sign_message/3" do
    test "produces a recoverable EIP-191 signature", %{adapter: a, address: addr} do
      message = "hello raxol"

      assert {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>} =
               ProviderAdapter.sign_message(a, 8453, message)

      assert v in [27, 28]

      # Recover and assert the address matches.
      digest = ExKeccak.hash_256("\x19Ethereum Signed Message:\n#{byte_size(message)}" <> message)

      {:ok, recovered_pubkey} =
        ExSecp256k1.recover_compact(digest, <<r::binary, s::binary>>, v - 27)

      <<_::binary-size(1), payload::binary-size(64)>> = recovered_pubkey
      hash = ExKeccak.hash_256(payload)
      <<_::binary-size(12), addr_bytes::binary-size(20)>> = hash
      recovered = "0x" <> Base.encode16(addr_bytes, case: :lower)

      assert String.downcase(recovered) == String.downcase(addr)
    end
  end

  describe "sign_typed_data/3" do
    test "EIP-712 signature recovers to the configured address", %{adapter: a, address: addr} do
      typed_data = %{
        domain: %{name: "ACP", version: "1", chainId: 8453},
        types: %{
          "AgentAuth" => [
            {"wallet", "address"},
            {"chainId", "uint256"},
            {"issuedAt", "uint256"}
          ]
        },
        message: %{"wallet" => addr, "chainId" => 8453, "issuedAt" => 1_900_000_000}
      }

      assert {:ok, sig} = ProviderAdapter.sign_typed_data(a, 8453, typed_data)
      assert byte_size(sig) == 65

      {:ok, digest} =
        Raxol.Payments.EIP712.hash(typed_data.domain, typed_data.types, typed_data.message)

      <<r::binary-size(32), s::binary-size(32), v::8>> = sig

      {:ok, recovered_pubkey} =
        ExSecp256k1.recover_compact(digest, <<r::binary, s::binary>>, v - 27)

      <<_::binary-size(1), payload::binary-size(64)>> = recovered_pubkey
      hash = ExKeccak.hash_256(payload)
      <<_::binary-size(12), addr_bytes::binary-size(20)>> = hash
      recovered = "0x" <> Base.encode16(addr_bytes, case: :lower)

      assert String.downcase(recovered) == String.downcase(addr)
    end
  end

  describe "send_calls/3 + get_transaction_receipt/3" do
    test "transfer 1 wei to a fresh address gets a receipt", %{adapter: a, rpc: rpc} do
      recipient = "0x" <> String.duplicate("aa", 20)

      # Capture pre-balance.
      {pre_out, 0} = AnvilHarness.cast(["balance", recipient, "--rpc-url", rpc])
      pre_balance = String.to_integer(String.trim(pre_out))

      call = %{
        to: recipient,
        value: 1,
        data: <<>>
      }

      assert {:ok, [tx_hash]} = ProviderAdapter.send_calls(a, 8453, [call])
      assert String.starts_with?(tx_hash, "0x")
      assert byte_size(tx_hash) == 66

      # Wait briefly for inclusion (anvil mines immediately).
      Process.sleep(100)
      assert {:ok, receipt} = ProviderAdapter.get_transaction_receipt(a, 8453, tx_hash)
      assert receipt != nil
      assert receipt["status"] == "0x1"

      # Recipient got the value.
      {post_out, 0} = AnvilHarness.cast(["balance", recipient, "--rpc-url", rpc])
      assert String.to_integer(String.trim(post_out)) == pre_balance + 1
    end

    test "multiple calls use sequential nonces", %{adapter: a, rpc: _rpc} do
      recipient = "0x" <> String.duplicate("bb", 20)

      calls = [
        %{to: recipient, value: 1, data: <<>>},
        %{to: recipient, value: 2, data: <<>>}
      ]

      assert {:ok, [h1, h2]} = ProviderAdapter.send_calls(a, 8453, calls)
      assert h1 != h2

      Process.sleep(100)
      assert {:ok, %{"status" => "0x1"}} = ProviderAdapter.get_transaction_receipt(a, 8453, h1)
      assert {:ok, %{"status" => "0x1"}} = ProviderAdapter.get_transaction_receipt(a, 8453, h2)
    end

    test "unsupported chain returns error", %{adapter: a} do
      assert {:error, {:unsupported_chain, 999}} =
               ProviderAdapter.send_calls(a, 999, [%{to: "0x", value: 0, data: <<>>}])
    end
  end

  describe "get_logs/3" do
    test "returns an empty list for a filter with no matches", %{adapter: a} do
      assert {:ok, []} =
               ProviderAdapter.get_logs(a, 8453, %{
                 address: "0x" <> String.duplicate("00", 20),
                 from_block: "latest",
                 to_block: "latest"
               })
    end

    test "filters by topic", %{adapter: a, rpc: rpc} do
      # Send a tx so there's a log to find.
      recipient = "0x" <> String.duplicate("cc", 20)
      AnvilHarness.anvil_set_balance(rpc, recipient, 1)

      # USDC Transfer event topic.
      transfer_topic =
        "0x" <>
          (ExKeccak.hash_256("Transfer(address,address,uint256)") |> Base.encode16(case: :lower))

      assert {:ok, logs} =
               ProviderAdapter.get_logs(a, 8453, %{
                 address: @base_usdc,
                 topics: [transfer_topic],
                 from_block: "latest",
                 to_block: "latest"
               })

      assert is_list(logs)
    end
  end
end
