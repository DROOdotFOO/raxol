defmodule Raxol.ACP.Wallet.SCA.Provisioning do
  @moduledoc """
  Counterfactual address prediction and deploy calldata for Alchemy
  Semi-Modular Account v2 (the default Modular Account v2 type Virtuals
  agents run).

  Verified against `@account-kit/smart-contracts@4.88.4`
  (`predictModularAccountV2Address` + the `createSemiModularAccount`
  factory call).

  ## Counterfactual address (CREATE2)

  An SMA's address is deterministic in its owner + salt, so it can be
  known before deployment:

      combinedSalt = keccak256(packed(owner:address, salt:uint256, 0xffffffff:uint32))
      initcode     = SMA proxy bytecode with `owner` as an immutable arg
      address      = CREATE2(factory, combinedSalt, initcode)

  The `0xffffffff` is the SMA fallback-signer entity id the MAv2
  factory hard-codes.

  ## Deployment

  ERC-4337 accounts self-deploy on their first UserOperation via the
  `initCode` field. `deploy_init_code/2` builds that field:

      initCode = factory_address || createSemiModularAccount(owner, salt)

  Drop it into `%UserOp{init_code: ...}` for the agent's first
  transaction; the EntryPoint invokes the factory, which CREATE2-
  deploys the account at the predicted address.

  ## Provisioning vs. raxol

  In production an agent's SMA is usually deployed and its session key
  registered by Virtuals' `acp setup`. These helpers let raxol (a)
  compute the agent's address up front and (b) self-deploy on first use
  when running against its own factory. Session-key installation
  (`installValidation`) is not yet built -- see the module TODO.
  """

  alias Raxol.ACP.ABI
  alias Raxol.ACP.Wallet.SCA.ModularAccount

  # MAv2 factory hard-codes this entity id for the SMA fallback signer.
  @sma_fallback_entity_id 0xFFFFFFFF

  @create_sma_sig "createSemiModularAccount(address,uint256)"

  # Account Kit's SMA proxy creation bytecode, split around the
  # implementation address and the trailing immutable args (owner).
  # From getProxyBytecodeWithImmutableArgs/2.
  @proxy_prefix "6100513d8160233d3973"
  @proxy_suffix "60095155f3363d3d373d3d363d7f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc545af43d6000803e6038573d6000fd5b3d6000f3"

  @doc """
  Predict the counterfactual SMA address for `owner` (the EOA signer)
  at the given `salt` (default `0`).
  """
  @spec predict_address(String.t(), non_neg_integer()) :: String.t()
  def predict_address(owner, salt \\ 0)
      when is_binary(owner) and is_integer(salt) and salt >= 0 do
    owner_bytes = decode_address!(owner)
    impl_bytes = decode_address!(ModularAccount.sma_bytecode_address())
    factory_bytes = decode_address!(ModularAccount.factory_address())

    combined_salt =
      ExKeccak.hash_256(
        owner_bytes <> <<salt::unsigned-big-256>> <> <<@sma_fallback_entity_id::unsigned-big-32>>
      )

    init_code =
      Base.decode16!(@proxy_prefix, case: :mixed) <>
        impl_bytes <>
        Base.decode16!(@proxy_suffix, case: :mixed) <>
        owner_bytes

    init_code_hash = ExKeccak.hash_256(init_code)

    addr =
      ExKeccak.hash_256(<<0xFF>> <> factory_bytes <> combined_salt <> init_code_hash)
      |> binary_part(12, 20)

    "0x" <> Base.encode16(addr, case: :lower)
  end

  @doc """
  Build the ERC-4337 `initCode` that deploys `owner`'s SMA on its first
  UserOperation: `factory_address || createSemiModularAccount(owner, salt)`.
  """
  @spec deploy_init_code(String.t(), non_neg_integer()) :: binary()
  def deploy_init_code(owner, salt \\ 0)
      when is_binary(owner) and is_integer(salt) and salt >= 0 do
    factory_bytes = decode_address!(ModularAccount.factory_address())
    factory_call = ABI.encode_call(@create_sma_sig, [{"address", owner}, {"uint256", salt}])
    factory_bytes <> factory_call
  end

  # -- Internal --

  defp decode_address!("0x" <> hex), do: decode_address!(hex)

  defp decode_address!(hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 -> bytes
      _ -> raise ArgumentError, "Provisioning: invalid address #{inspect(hex)}"
    end
  end
end
