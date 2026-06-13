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

  ## Session-key registration

  `install_session_key_calldata/3` builds the `installValidation` call
  that registers a session key on the single-signer validation module
  as a new entity. Use the result **directly** as `UserOp.call_data` --
  the EntryPoint calls `sender.<call_data>`, which is exactly
  `account.installValidation(...)`.

  **Do NOT wrap it in `ModularAccount.execute_calldata(account, 0, ...)`.**
  MAv2 SMA forbids self-calls (`execute(self, 0, ...)`) and reverts with
  `SelfCallRecursionDepthExceeded()` during validation -- the bundler
  surfaces this as "AA23 reverted" with selector `0x54ff929d`. In
  production Virtuals' `acp setup` usually does this; the helper exists
  for self-provisioning.

  ## Provisioning vs. raxol

  In production an agent's SMA is usually deployed and its session key
  registered by Virtuals' `acp setup`. These helpers let raxol (a)
  compute the agent's address up front, (b) self-deploy on first use,
  and (c) register a session key against its own account.
  """

  alias Raxol.ACP.ABI
  alias Raxol.ACP.Wallet.SCA.ModularAccount

  # MAv2 factory hard-codes this entity id for the SMA fallback signer.
  @sma_fallback_entity_id 0xFFFFFFFF

  @create_sma_sig "createSemiModularAccount(address,uint256)"
  @install_validation_sig "installValidation(bytes25,bytes4[],bytes,bytes[])"
  # installValidation has 4 args -> 4 head words.
  @head_size 4 * 32

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

  @doc """
  Build the `installValidation` calldata that registers `signer` as a
  new session-key entity on the single-signer validation module:

      installValidation(bytes25 validationConfig, bytes4[] selectors,
                        bytes installData, bytes[] hooks)

  Use the result directly as `UserOp.call_data` and send it as a UserOp
  signed by the owner. Do NOT wrap it in `execute(account, 0, calldata)`
  -- MAv2 rejects self-calls with `SelfCallRecursionDepthExceeded()`
  (AA23 / selector 0x54ff929d). The EntryPoint dispatches the userOp's
  call_data directly to the sender, so `installValidation` is invoked
  on the account itself without any wrapper.

  `validationConfig` packs `moduleAddress(20) || entityId(uint32) ||
  flags(1)`, where flags = userOp(1) | signature(2) | global(4).
  `installData` is the module's `onInstall` payload,
  `abi.encode(uint32 entityId, address signer)`.

  Options:
  - `:global` (default `true`), `:user_op_validation` (default `true`),
    `:signature_validation` (default `true`) -- the validation flags.

  This builds the common case only: **no** selectors and **no** hooks
  (empty arrays), which is what a global session key needs.
  """
  @spec install_session_key_calldata(String.t(), non_neg_integer(), keyword()) :: binary()
  def install_session_key_calldata(signer, entity_id, opts \\ [])
      when is_binary(signer) and is_integer(entity_id) and entity_id in 0..0xFFFFFFFF do
    module = decode_address!(ModularAccount.single_signer_validation_address())
    validation_config = module <> <<entity_id::unsigned-big-32>> <> <<validation_flags(opts)>>

    # single-signer onInstall data: abi.encode(uint32 entityId, address signer)
    install_data =
      <<entity_id::unsigned-big-256>> <> <<0::96, decode_address!(signer)::binary-size(20)>>

    selector = ABI.function_selector(@install_validation_sig)

    # Head (4 words): bytes25 (right-padded), then offsets to the three
    # dynamic args. Tail: empty selectors[], installData bytes, empty hooks[].
    # Tail layout, by offset (relative to the start of the args):
    #   selectors[]  @ head_size            -> 1 word (length 0)
    #   installData  @ head_size + 32       -> 1 length word + data
    #   hooks[]      @ head_size + 32 + 32 + len(installData)
    selectors_off = @head_size
    install_off = @head_size + 32
    hooks_off = @head_size + 32 + 32 + byte_size(install_data)

    head =
      pad_right_word(validation_config) <>
        word(selectors_off) <>
        word(install_off) <>
        word(hooks_off)

    tail =
      word(0) <>
        word(byte_size(install_data)) <>
        install_data <>
        word(0)

    selector <> head <> tail
  end

  # -- Internal --

  defp validation_flags(opts) do
    user_op = if Keyword.get(opts, :user_op_validation, true), do: 1, else: 0
    signature = if Keyword.get(opts, :signature_validation, true), do: 2, else: 0
    global = if Keyword.get(opts, :global, true), do: 4, else: 0
    user_op + signature + global
  end

  defp word(n), do: <<n::unsigned-big-256>>

  defp pad_right_word(bin) when byte_size(bin) <= 32 do
    bin <> <<0::size((32 - byte_size(bin)) * 8)>>
  end

  defp decode_address!("0x" <> hex), do: decode_address!(hex)

  defp decode_address!(hex) when is_binary(hex) and byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 -> bytes
      _ -> raise ArgumentError, "Provisioning: invalid address #{inspect(hex)}"
    end
  end
end
