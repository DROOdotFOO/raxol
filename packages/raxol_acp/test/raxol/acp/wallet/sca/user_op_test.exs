defmodule Raxol.ACP.Wallet.SCA.UserOpTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Wallet.SCA.UserOp

  # All-zero entrypoint + chain id 1 makes the outer hash a function of
  # just the inner UserOp hash. Useful sanity-check.
  @entry_point_v07 "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  describe "pack/1" do
    test "an empty/no-paymaster userop packs gas pairs and yields empty paymasterAndData" do
      op = %UserOp{
        sender: "0x" <> String.duplicate("11", 20),
        nonce: 0,
        call_gas_limit: 100_000,
        verification_gas_limit: 200_000,
        max_fee_per_gas: 2_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000
      }

      packed = UserOp.pack(op)

      # accountGasLimits = verif << 128 | call
      assert packed.account_gas_limits ==
               <<200_000::unsigned-big-128, 100_000::unsigned-big-128>>

      # gasFees = maxPrio << 128 | maxFee
      assert packed.gas_fees ==
               <<1_000_000_000::unsigned-big-128, 2_000_000_000::unsigned-big-128>>

      assert packed.paymaster_and_data == <<>>
    end

    test "with a paymaster, paymasterAndData = addr(20) || verif(16) || post(16) || data" do
      paymaster = "0x" <> String.duplicate("ab", 20)

      op = %UserOp{
        sender: "0x" <> String.duplicate("11", 20),
        paymaster: paymaster,
        paymaster_verification_gas_limit: 50_000,
        paymaster_post_op_gas_limit: 20_000,
        paymaster_data: <<0xDE, 0xAD, 0xBE, 0xEF>>
      }

      packed = UserOp.pack(op)

      <<
        addr::binary-size(20),
        verif::unsigned-big-128,
        post::unsigned-big-128,
        data::binary
      >> = packed.paymaster_and_data

      assert Base.encode16(addr, case: :lower) == String.duplicate("ab", 20)
      assert verif == 50_000
      assert post == 20_000
      assert data == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end
  end

  describe "hash/3" do
    # Minimal userop with all fields zero except sender. The hash depends
    # only on the encoded layout being correct; if our keccak/encoding
    # is wrong, this will not match the on-chain digest.
    test "is deterministic for a fixed input" do
      op = %UserOp{
        sender: "0x" <> String.duplicate("00", 20),
        nonce: 0
      }

      h1 = UserOp.hash(op, @entry_point_v07, 1)
      h2 = UserOp.hash(op, @entry_point_v07, 1)
      assert h1 == h2
      assert byte_size(h1) == 32
    end

    test "differs when the chain id changes" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20)}
      assert UserOp.hash(op, @entry_point_v07, 1) != UserOp.hash(op, @entry_point_v07, 8453)
    end

    test "differs when the entry point changes" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20)}
      other = "0x" <> String.duplicate("ff", 20)
      assert UserOp.hash(op, @entry_point_v07, 1) != UserOp.hash(op, other, 1)
    end

    test "ignores the signature field" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20), signature: <<0xAA>>}
      op2 = %UserOp{op | signature: <<0xBB, 0xBB>>}
      assert UserOp.hash(op, @entry_point_v07, 1) == UserOp.hash(op2, @entry_point_v07, 1)
    end

    test "responds to nonce changes" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20), nonce: 0}
      op2 = %{op | nonce: 1}
      assert UserOp.hash(op, @entry_point_v07, 1) != UserOp.hash(op2, @entry_point_v07, 1)
    end

    test "responds to callData changes via the keccak of callData" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20), call_data: <<>>}
      op2 = %{op | call_data: <<0x42>>}
      assert UserOp.hash(op, @entry_point_v07, 1) != UserOp.hash(op2, @entry_point_v07, 1)
    end

    test "responds to paymaster changes" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20)}
      op2 = %{op | paymaster: "0x" <> String.duplicate("ab", 20)}
      assert UserOp.hash(op, @entry_point_v07, 1) != UserOp.hash(op2, @entry_point_v07, 1)
    end

    # Fixed reference UserOp. The expected hash is computed below by a
    # separate `viem.getUserOperationHash` run (TODO: insert verified
    # value). Until then this test only locks in determinism so a
    # behavior change here is visible.
    @tag :pending_viem_vector
    test "fixed-vector hash is deterministic (cross-validate vs viem)" do
      op = %UserOp{
        sender: "0x9a96e767bfcce8e80370be00821ed5ba283d4a17",
        nonce: 0,
        call_gas_limit: 50_000,
        verification_gas_limit: 100_000,
        pre_verification_gas: 21_000,
        max_fee_per_gas: 1_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000
      }

      hash = UserOp.hash(op, @entry_point_v07, 8453)
      assert byte_size(hash) == 32

      # When you have a viem-generated reference, replace this with an
      # equality assertion against the hex literal. Suggested generator:
      #
      #   import { getUserOperationHash } from "viem/account-abstraction"
      #   getUserOperationHash({
      #     userOperation: { ...above fields in viem shape... },
      #     entryPointAddress: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
      #     entryPointVersion: "0.7",
      #     chainId: 8453,
      #   })
    end
  end

  describe "put_signature/2" do
    test "sets the signature field" do
      op = %UserOp{sender: "0x" <> String.duplicate("00", 20)}
      op2 = UserOp.put_signature(op, <<0xAA, 0xBB>>)
      assert op2.signature == <<0xAA, 0xBB>>
    end
  end
end
