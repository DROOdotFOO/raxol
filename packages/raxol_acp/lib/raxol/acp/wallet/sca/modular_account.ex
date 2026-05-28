defmodule Raxol.ACP.Wallet.SCA.ModularAccount do
  @moduledoc """
  Alchemy Modular Account v2 specifics: call encoding, nonce-key
  packing, and signature wrapping.

  Verified against `@account-kit/smart-contracts@4.88.4` (the package
  `@virtuals-protocol/acp-node` pulls in). Constants and formats are
  mirrored from that SDK's `ma-v2` modules.

  ## Canonical addresses (all chains, incl. Base 8453)

  These are deterministic-deployment addresses, identical on every
  supported chain in the SDK's switch (it falls through to the default
  for Base):

      factory                       0x00000000000017c61b5bEe81050EC8eFc9c6fecd
      implementation                0x00000000000002377B26b1EdA7b0BC371C60DD4f
      single-signer validation      0x00000000000099DE0BF6fA90dEB851E2A2df7d83

  ## Nonce key (192-bit)

  Modular Account v2 encodes the validating entity into the ERC-4337
  nonce key:

      fullNonceKey = (parallelKey << 40) | (entityId << 8) | globalFlag

  where `globalFlag` is 1 for `isGlobalValidation: true` (what the ACP
  SDK uses). EntryPoint then combines `fullNonceKey << 64 | sequence`.

  ## Signature wrapping

  - **UserOp** (`pack_uo_signature/1`): `0xFF || 0x00 || sig`. The `sig`
    is `ECDSA(eip191(userOpHash))` -- the SDK calls
    `signer.signMessage({ raw: uoHash })`, which is EIP-191 prefixed.
    The entity is carried in the nonce, not the signature.

  - **EIP-1271** (`pack_1271_eoa_signature/2`):
    `0x00 || entityId(4) || 0xFF || 0x00 || sig`. The `sig` is over the
    `ReplaySafeHash` EIP-712 envelope (see `replay_safe_digest/4`).
  """

  alias Raxol.ACP.ABI

  @factory "0x00000000000017c61b5bEe81050EC8eFc9c6fecd"
  @implementation "0x00000000000002377B26b1EdA7b0BC371C60DD4f"
  @single_signer_validation "0x00000000000099DE0BF6fA90dEB851E2A2df7d83"

  # uint128 max -- parallel key fits in (152 - 32 - 8) bits but we only
  # guard the entity and assembled key sizes.
  @uint32_max 0xFFFFFFFF
  @uint152_max 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF

  @execute_sig "execute(address,uint256,bytes)"

  @doc "Canonical Modular Account v2 factory address."
  @spec factory_address() :: String.t()
  def factory_address, do: @factory

  @doc "Canonical Modular Account v2 implementation address."
  @spec implementation_address() :: String.t()
  def implementation_address, do: @implementation

  @doc "Canonical single-signer validation module address."
  @spec single_signer_validation_address() :: String.t()
  def single_signer_validation_address, do: @single_signer_validation

  @doc """
  ABI-encode a call to `execute(address target, uint256 value, bytes data)`.

  This is the calldata you put in a UserOp to make the smart account
  perform a single outbound call (e.g. an ACP contract method).
  """
  @spec execute_calldata(String.t(), non_neg_integer(), binary()) :: binary()
  def execute_calldata(target, value, data)
      when is_binary(target) and is_integer(value) and value >= 0 and is_binary(data) do
    ABI.encode_call(@execute_sig, [
      {"address", target},
      {"uint256", value},
      {"bytes", data}
    ])
  end

  @doc """
  Build the 192-bit Modular Account v2 nonce key for a validating
  entity.

  - `entity_id` -- the session-key entity slot (uint32)
  - `global?` -- `true` for global validation (ACP default)
  - `parallel_key` -- optional parallel nonce key (default 0)

  The result is the `key` argument to `EntryPoint.getNonce(account,
  key)`; the EntryPoint adds the 64-bit sequence.
  """
  @spec nonce_key(non_neg_integer(), boolean(), non_neg_integer()) :: non_neg_integer()
  def nonce_key(entity_id, global?, parallel_key \\ 0)
      when is_integer(entity_id) and entity_id in 0..@uint32_max and
             is_integer(parallel_key) and parallel_key >= 0 do
    key =
      Bitwise.bsl(parallel_key, 40)
      |> Bitwise.bor(Bitwise.bsl(entity_id, 8))
      |> Bitwise.bor(if global?, do: 1, else: 0)

    if key > @uint152_max do
      raise ArgumentError, "Modular Account v2 nonce key exceeds 152 bits"
    end

    key
  end

  @doc """
  Wrap a raw ECDSA signature for use as a UserOperation signature.

  `0xFF || 0x00 || sig`. The `0xFF` marks global validation and the
  `0x00` indicates no pre-validation hook data.
  """
  @spec pack_uo_signature(binary()) :: binary()
  def pack_uo_signature(sig) when is_binary(sig), do: <<0xFF, 0x00>> <> sig

  # The fixed dummy validation signature the SDK's getDummySignature
  # returns (a syntactically-valid but unusable 65-byte sig). Used only
  # for gas estimation / paymaster requests, never broadcast.
  @dummy_validation_sig Base.decode16!(
                          "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000000000000000000000000000000007AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1C",
                          case: :mixed
                        )

  @doc """
  The packed dummy UserOperation signature used for gas estimation and
  the Alchemy paymaster request, before the real signature is known.
  Matches `getDummySignature` from `@account-kit/smart-contracts`.
  """
  @spec dummy_uo_signature() :: binary()
  def dummy_uo_signature, do: pack_uo_signature(@dummy_validation_sig)

  @doc """
  Wrap a raw ECDSA signature for an EIP-1271 (off-chain) signature from
  a single-signer entity.

  `0x00 || entityId(uint32, 4 bytes) || 0xFF || 0x00 || sig`. The
  leading `0x00` is "no pre-validation hooks"; the trailing `0x00` is
  the EOA signature type marker.
  """
  @spec pack_1271_eoa_signature(binary(), non_neg_integer()) :: binary()
  def pack_1271_eoa_signature(sig, entity_id)
      when is_binary(sig) and is_integer(entity_id) and entity_id in 0..@uint32_max do
    <<0x00, entity_id::unsigned-big-32, 0xFF, 0x00>> <> sig
  end

  @doc """
  Apply the EIP-191 "personal_sign" prefix to a 32-byte hash and return
  the digest that should be ECDSA-signed for a UserOperation.

      keccak256("\\x19Ethereum Signed Message:\\n32" || hash)
  """
  @spec eip191_digest(<<_::256>>) :: binary()
  def eip191_digest(<<_::256>> = hash) do
    ExKeccak.hash_256("\x19Ethereum Signed Message:\n32" <> hash)
  end

  @doc """
  Compute the EIP-712 `ReplaySafeHash` digest a single-signer entity
  signs for EIP-1271 (e.g. JWT auth challenges).

  The domain binds the signature to the single-signer validation module
  and the specific account via a salt of `bytes12(0) || accountAddress`:

      domain  = EIP712Domain(uint256 chainId, address verifyingContract, bytes32 salt)
                where verifyingContract = single-signer validation module,
                      salt = 0x000000000000000000000000 || accountAddress
      struct  = ReplaySafeHash(bytes32 hash)
      digest  = keccak256(0x1901 || domainSeparator || structHash)

  `inner_hash` is the application hash (e.g. `hashTypedData` of the
  challenge, or `hashMessage` of a personal-sign payload).
  """
  @spec replay_safe_digest(<<_::256>>, pos_integer(), String.t()) :: binary()
  def replay_safe_digest(inner_hash, chain_id, account_address) do
    domain_type_hash =
      ExKeccak.hash_256("EIP712Domain(uint256 chainId,address verifyingContract,bytes32 salt)")

    salt = <<0::96, decode_address!(account_address)::binary-size(20)>>

    domain_separator =
      ExKeccak.hash_256(
        domain_type_hash <>
          <<chain_id::unsigned-big-256>> <>
          encode_address(@single_signer_validation) <>
          salt
      )

    struct_hash =
      ExKeccak.hash_256(ExKeccak.hash_256("ReplaySafeHash(bytes32 hash)") <> inner_hash)

    ExKeccak.hash_256(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end

  # -- Internal --

  defp encode_address(addr) do
    <<0::96, decode_address!(addr)::binary-size(20)>>
  end

  defp decode_address!("0x" <> hex), do: decode_address!(hex)

  defp decode_address!(hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 -> bytes
      _ -> raise ArgumentError, "ModularAccount: invalid address #{inspect(hex)}"
    end
  end
end
