defmodule Raxol.ACP.Wallet.Sma7702 do
  @moduledoc """
  A `Raxol.Payments.Wallet` that produces ERC-1271 signatures a live Alchemy
  EIP-7702 Semi-Modular Account (`SemiModularAccount7702`) accepts, so a managed
  7702 buyer can sign Xochi intents (and origin-pull authorizations) that Riddler
  verifies on-chain via `isValidSignature`.

  Unlike `Raxol.ACP.Wallet.SCA` -- which targets a DEPLOYED Modular Account v2
  validating through an installed single-signer validation MODULE -- a 7702 SMA
  validates through its NATIVE fallback path. Verified byte-for-byte on Base
  against the live account (`isValidSignature -> 0x1626ba7e`), that path differs
  in two ways:

    * **Replay-safe digest domain.** The account wraps the app digest with its
      OWN EIP-712 domain -- `EIP712Domain(uint256 chainId, address
      verifyingContract)` where `verifyingContract` is the ACCOUNT itself, with no
      `salt` and no name/version -- not the single-signer module's
      `{module, salt = account}` domain that `Raxol.ACP.Wallet.SCA` builds.
    * **Signer.** The only authorized signer is the account's fallback signer (the
      7702 authority itself), NOT a local session key. Signing therefore goes
      through the managed authority (the Privy/Alchemy `ProviderAdapter`), which
      holds the key.

  The managed signer has no raw-hash endpoint, so to make it sign the account's
  replay-safe hash we hand it that wrapper AS EIP-712 typed data --
  `ReplaySafeHash(bytes32 hash)` over the account domain, `hash` = the app digest
  `D`. The signer hashes and signs it, yielding a signature over exactly
  `_replaySafeHash(D)`. We then wrap the 65-byte ECDSA signature in the Modular
  Account v2 fallback envelope `0x00 || uint32(0) || 0xFF || 0x00 || sig` (entity
  id 0, global flag, no pre-validation hook data, `SignatureType.EOA`).

  ## Usage

      defmodule MyBuyer do
        use Raxol.ACP.Wallet.Sma7702,
          account_address: "0x468a...",
          chain_id: 8453,
          # {module, fun} resolved at call time -- the managed ProviderAdapter is
          # runtime state (built from env), so the wallet stays a plain behaviour.
          provider: {MyApp, :privy_provider}
      end
  """

  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.Wallet.SCA.ModularAccount
  alias Raxol.Payments.EIP712

  @replay_safe_types %{"ReplaySafeHash" => [%{name: "hash", type: "bytes32"}]}

  defmacro __using__(opts) do
    account = Keyword.fetch!(opts, :account_address)
    chain = Keyword.fetch!(opts, :chain_id)
    provider = Keyword.fetch!(opts, :provider)

    quote do
      @behaviour Raxol.Payments.Wallet

      @impl true
      def address, do: unquote(account)

      @impl true
      def chain_id, do: unquote(chain)

      @impl true
      def sign_message(message) do
        Raxol.ACP.Wallet.Sma7702.sign_message(
          message,
          unquote(provider),
          unquote(chain),
          unquote(account)
        )
      end

      @impl true
      def sign_typed_data(domain, types, message) do
        Raxol.ACP.Wallet.Sma7702.sign_typed_data(
          domain,
          types,
          message,
          unquote(provider),
          unquote(chain),
          unquote(account)
        )
      end

      # Signing goes through the managed authority, never a raw local key.
      @impl true
      def sign_hash(_digest), do: {:error, :sma7702_requires_managed_signer}
    end
  end

  @typedoc "A `{module, function}` resolving to the managed `ProviderAdapter` at call time."
  @type provider_ref :: {module(), atom()}

  @doc false
  @spec sign_typed_data(map(), map(), map(), provider_ref(), pos_integer(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def sign_typed_data(domain, types, message, provider_ref, chain_id, account) do
    with {:ok, inner} <- EIP712.hash(domain, types, message) do
      sign_inner(inner, provider_ref, chain_id, account)
    end
  end

  @doc false
  @spec sign_message(binary(), provider_ref(), pos_integer(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def sign_message(message, provider_ref, chain_id, account) do
    sign_inner(hash_message(message), provider_ref, chain_id, account)
  end

  # Sign the account's replay-safe wrapper of `inner_hash` via the managed
  # authority, then pack it into the fallback ERC-1271 envelope.
  defp sign_inner(inner_hash, {mod, fun}, chain_id, account) do
    provider = apply(mod, fun, [])

    wrapper = %{
      domain: %{chainId: chain_id, verifyingContract: account},
      types: @replay_safe_types,
      message: %{"hash" => "0x" <> Base.encode16(inner_hash, case: :lower)}
    }

    with {:ok, raw} <- ProviderAdapter.sign_typed_data(provider, chain_id, wrapper) do
      {:ok, ModularAccount.pack_1271_eoa_signature(normalize_v(raw), 0)}
    end
  end

  # EIP-191 personal-sign hash of arbitrary-length data (matches
  # `Raxol.ACP.Wallet.SCA`'s message hashing).
  defp hash_message(message) do
    prefix = "\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(message))
    ExKeccak.hash_256(prefix <> message)
  end

  # secp256k1 recovery id -> Ethereum v (27/28); leave already-normalized sigs.
  defp normalize_v(<<r::binary-size(32), s::binary-size(32), v::8>>) when v < 27,
    do: <<r::binary-size(32), s::binary-size(32), v + 27::8>>

  defp normalize_v(<<_::binary-size(64), _v::8>> = sig), do: sig
end
