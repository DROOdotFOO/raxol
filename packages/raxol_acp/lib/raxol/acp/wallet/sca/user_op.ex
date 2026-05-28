defmodule Raxol.ACP.Wallet.SCA.UserOp do
  @moduledoc """
  ERC-4337 v0.7 `UserOperation` struct, packing, and hashing.

  Mirrors the `PackedUserOperation` layout from EntryPoint v0.7:

      struct PackedUserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;            // empty when account already deployed
        bytes callData;
        bytes32 accountGasLimits;  // verificationGasLimit << 128 | callGasLimit
        uint256 preVerificationGas;
        bytes32 gasFees;           // maxPriorityFeePerGas << 128 | maxFeePerGas
        bytes paymasterAndData;    // paymaster (20) || verif_gas (16) || post_gas (16) || data
        bytes signature;
      }

  The struct here keeps fields **unpacked** for readability. `pack/1`
  converts to the on-chain shape. `hash/3` computes the standard
  `userOpHash`:

      keccak256(abi.encode(
        keccak256(abi.encode(
          sender, nonce, keccak256(initCode), keccak256(callData),
          accountGasLimits, preVerificationGas, gasFees,
          keccak256(paymasterAndData)
        )),
        entryPoint,
        chainId
      ))

  The signature field is **excluded** from the hash (that's what gets
  signed, then appended).
  """

  @typedoc "Hex-encoded address, 0x-prefixed lowercase, 42 chars."
  @type address :: <<_::336>>

  @typedoc "Non-negative integer, fits in uint256."
  @type uint256 :: non_neg_integer()

  @typedoc "Non-negative integer, fits in uint128. Used for packed gas slots."
  @type uint128 :: non_neg_integer()

  defstruct sender: nil,
            nonce: 0,
            init_code: <<>>,
            call_data: <<>>,
            call_gas_limit: 0,
            verification_gas_limit: 0,
            pre_verification_gas: 0,
            max_priority_fee_per_gas: 0,
            max_fee_per_gas: 0,
            paymaster: nil,
            paymaster_verification_gas_limit: 0,
            paymaster_post_op_gas_limit: 0,
            paymaster_data: <<>>,
            signature: <<>>

  @type t :: %__MODULE__{
          sender: address(),
          nonce: uint256(),
          init_code: binary(),
          call_data: binary(),
          call_gas_limit: uint128(),
          verification_gas_limit: uint128(),
          pre_verification_gas: uint256(),
          max_priority_fee_per_gas: uint128(),
          max_fee_per_gas: uint128(),
          paymaster: address() | nil,
          paymaster_verification_gas_limit: uint128(),
          paymaster_post_op_gas_limit: uint128(),
          paymaster_data: binary(),
          signature: binary()
        }

  @doc """
  Pack a `UserOp` into its on-chain bytes32 representations.

  Returns a map with the same fields but with `accountGasLimits`,
  `gasFees`, and `paymasterAndData` materialized.
  """
  @spec pack(t()) :: %{required(atom()) => binary() | uint256()}
  def pack(%__MODULE__{} = op) do
    %{
      sender: op.sender,
      nonce: op.nonce,
      init_code: op.init_code,
      call_data: op.call_data,
      account_gas_limits: pack_gas_pair(op.verification_gas_limit, op.call_gas_limit),
      pre_verification_gas: op.pre_verification_gas,
      gas_fees: pack_gas_pair(op.max_priority_fee_per_gas, op.max_fee_per_gas),
      paymaster_and_data: pack_paymaster_and_data(op),
      signature: op.signature
    }
  end

  @doc """
  Compute the canonical `userOpHash` for the given UserOp under a
  specific EntryPoint and chain id.

  The signature field of the UserOp is ignored -- this is the hash that
  gets signed, before the signature is set.
  """
  @spec hash(t(), address(), pos_integer()) :: binary()
  def hash(%__MODULE__{} = op, entry_point, chain_id) do
    packed = pack(op)

    inner_encoded =
      [
        encode_address(packed.sender),
        encode_uint256(packed.nonce),
        ExKeccak.hash_256(packed.init_code),
        ExKeccak.hash_256(packed.call_data),
        packed.account_gas_limits,
        encode_uint256(packed.pre_verification_gas),
        packed.gas_fees,
        ExKeccak.hash_256(packed.paymaster_and_data)
      ]
      |> IO.iodata_to_binary()

    inner_hash = ExKeccak.hash_256(inner_encoded)

    outer_encoded =
      [
        inner_hash,
        encode_address(entry_point),
        encode_uint256(chain_id)
      ]
      |> IO.iodata_to_binary()

    ExKeccak.hash_256(outer_encoded)
  end

  @doc """
  Set the signature field and return the updated struct.

  Conventionally this is called after `hash/3` is signed by the
  authorized signer (session key, etc).
  """
  @spec put_signature(t(), binary()) :: t()
  def put_signature(%__MODULE__{} = op, signature) when is_binary(signature) do
    %{op | signature: signature}
  end

  # -- Internal --

  # `accountGasLimits` and `gasFees` are bytes32 packed as
  # `(uint128(high) << 128) | uint128(low)` and stored big-endian.
  defp pack_gas_pair(high, low)
       when is_integer(high) and is_integer(low) and high in 0..0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF and
              low in 0..0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
    <<high::unsigned-big-128, low::unsigned-big-128>>
  end

  # When the UserOp uses no paymaster, paymasterAndData is empty.
  # Otherwise it's the 20-byte paymaster address followed by two packed
  # gas limits (16 bytes each) and an arbitrary data tail.
  defp pack_paymaster_and_data(%__MODULE__{paymaster: nil}), do: <<>>

  defp pack_paymaster_and_data(%__MODULE__{paymaster: paymaster} = op) do
    addr = decode_address!(paymaster)

    <<
      addr::binary-size(20),
      op.paymaster_verification_gas_limit::unsigned-big-128,
      op.paymaster_post_op_gas_limit::unsigned-big-128,
      op.paymaster_data::binary
    >>
  end

  # Solidity abi.encode for a single address: 32 bytes, left-padded zero.
  defp encode_address(addr) when is_binary(addr) do
    bytes = decode_address!(addr)
    <<0::96, bytes::binary-size(20)>>
  end

  # Solidity abi.encode for uint256: 32 bytes big-endian.
  defp encode_uint256(value) when is_integer(value) and value >= 0 do
    <<value::unsigned-big-256>>
  end

  defp decode_address!("0x" <> hex), do: decode_address!(hex)

  defp decode_address!(hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 -> bytes
      _ -> raise ArgumentError, "Raxol.ACP.Wallet.SCA.UserOp: invalid address #{inspect(hex)}"
    end
  end

  defp decode_address!(other) do
    raise ArgumentError, "Raxol.ACP.Wallet.SCA.UserOp: invalid address #{inspect(other)}"
  end
end
