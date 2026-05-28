defmodule Raxol.ACP.Wallet.SCA do
  @moduledoc """
  Smart Contract Account wallet for Alchemy Modular Account v2, the
  account type every Virtuals ACP agent runs.

  Unlike `Raxol.Payments.Wallets.Env`/`Op` (which are EOAs that sign
  raw transactions), an SCA does not have its own private key. It is a
  deployed contract controlled by a **session key** -- an EOA
  registered as an authorized signer entity on the account. On-chain
  actions are submitted as ERC-4337 `UserOperation`s, signed by the
  session key and validated by the account's single-signer module.

  ## Configuration

      defmodule MyAgent.SCA do
        use Raxol.ACP.Wallet.SCA,
          account_address: "0x...",          # the deployed SCA
          chain_id: 8453,
          signer: MyAgent.SessionKey,        # a Raxol.Payments.Wallet (EOA)
          signer_entity_id: 1,               # session key's entity slot
          bundler_url: {:system, "ALCHEMY_BUNDLER_URL"},
          entry_point: "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
      end

  `signer` is any `Raxol.Payments.Wallet` impl holding the session-key
  private key; this module delegates raw secp256k1 signing to its
  `sign_hash/1` and wraps the result per Modular Account v2's rules
  (see `Raxol.ACP.Wallet.SCA.ModularAccount`).

  ## Wallet behaviour mapping

  - `address/0` -- returns the **SCA** address, not the session key's.
  - `chain_id/0` -- configured.
  - `sign_message/1`, `sign_typed_data/3` -- produce **EIP-1271**
    signatures (replay-safe-hash wrapped, packed for the single-signer
    entity). Used for off-chain auth (e.g. the ACP JWT challenge).
  - `sign_hash/1` -- **errors**. SCAs do not sign raw EIP-1559
    transactions; use `sign_user_op_hash/1` + a bundler instead.

  ## UserOperation flow

      op = %UserOp{sender: account_address, nonce: nonce, call_data: ...}
      hash = UserOp.hash(op, entry_point, chain_id)
      {:ok, sig} = MyAgent.SCA.sign_user_op_hash(hash)
      op = UserOp.put_signature(op, sig)
      {:ok, op_hash} = MyAgent.SCA.send_user_operation(op)

  Building the call data is `ModularAccount.execute_calldata/3`; the
  nonce key is `MyAgent.SCA.nonce_key/0` (feed it to
  `EntryPoint.getNonce`).
  """

  alias Raxol.ACP.Wallet.SCA.{Bundler, ModularAccount, UserOp}

  @default_entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  defmacro __using__(opts) do
    account = Keyword.fetch!(opts, :account_address)
    chain = Keyword.fetch!(opts, :chain_id)
    signer = Keyword.fetch!(opts, :signer)
    entity_id = Keyword.get(opts, :signer_entity_id, 0)
    bundler_url = Keyword.get(opts, :bundler_url)
    entry_point = Keyword.get(opts, :entry_point, @default_entry_point)

    quote do
      @behaviour Raxol.Payments.Wallet

      @impl true
      def address, do: unquote(account)

      @impl true
      def chain_id, do: unquote(chain)

      @impl true
      def sign_message(message) do
        Raxol.ACP.Wallet.SCA.sign_message(
          message,
          unquote(signer),
          unquote(chain),
          unquote(account),
          unquote(entity_id)
        )
      end

      @impl true
      def sign_typed_data(domain, types, message) do
        Raxol.ACP.Wallet.SCA.sign_typed_data(
          domain,
          types,
          message,
          unquote(signer),
          unquote(chain),
          unquote(account),
          unquote(entity_id)
        )
      end

      @impl true
      def sign_hash(_digest), do: {:error, :sca_uses_user_operations}

      @doc "Sign a UserOperation hash and return the packed UO signature."
      @spec sign_user_op_hash(<<_::256>>) :: {:ok, binary()} | {:error, term()}
      def sign_user_op_hash(uo_hash) do
        Raxol.ACP.Wallet.SCA.sign_user_op_hash(uo_hash, unquote(signer))
      end

      @doc "Modular Account v2 nonce key for this account's session entity."
      @spec nonce_key(non_neg_integer()) :: non_neg_integer()
      def nonce_key(parallel_key \\ 0) do
        Raxol.ACP.Wallet.SCA.ModularAccount.nonce_key(unquote(entity_id), true, parallel_key)
      end

      @doc "Sign and send a UserOperation via the configured bundler."
      @spec send_user_operation(Raxol.ACP.Wallet.SCA.UserOp.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
      def send_user_operation(op, opts \\ []) do
        Raxol.ACP.Wallet.SCA.send_user_operation(
          op,
          unquote(signer),
          unquote(bundler_url),
          unquote(entry_point),
          unquote(chain),
          opts
        )
      end

      @doc "The configured EntryPoint address."
      @spec entry_point() :: String.t()
      def entry_point, do: unquote(entry_point)
    end
  end

  # -- Shared implementation (called by generated functions) --

  @doc false
  @spec sign_message(binary(), module(), pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def sign_message(message, signer, chain_id, account, entity_id) do
    inner = hash_message(message)
    digest = ModularAccount.replay_safe_digest(inner, chain_id, account)

    with {:ok, raw} <- signer.sign_hash(digest) do
      {:ok, ModularAccount.pack_1271_eoa_signature(normalize_v(raw), entity_id)}
    end
  end

  @doc false
  @spec sign_typed_data(
          map(),
          map(),
          map(),
          module(),
          pos_integer(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, binary()} | {:error, term()}
  def sign_typed_data(domain, types, message, signer, chain_id, account, entity_id) do
    with {:ok, inner} <- Raxol.Payments.EIP712.hash(domain, types, message),
         digest = ModularAccount.replay_safe_digest(inner, chain_id, account),
         {:ok, raw} <- signer.sign_hash(digest) do
      {:ok, ModularAccount.pack_1271_eoa_signature(normalize_v(raw), entity_id)}
    end
  end

  @doc false
  @spec sign_user_op_hash(<<_::256>>, module()) :: {:ok, binary()} | {:error, term()}
  def sign_user_op_hash(uo_hash, signer) do
    digest = ModularAccount.eip191_digest(uo_hash)

    with {:ok, raw} <- signer.sign_hash(digest) do
      {:ok, ModularAccount.pack_uo_signature(normalize_v(raw))}
    end
  end

  @doc false
  @spec send_user_operation(
          UserOp.t(),
          module(),
          String.t() | {:system, String.t()} | nil,
          String.t(),
          pos_integer(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def send_user_operation(op, signer, bundler_url, entry_point, chain_id, opts) do
    # A runtime `:bundler_url` opt overrides the compile-time config.
    configured = Keyword.get(opts, :bundler_url, bundler_url)

    uo_hash = UserOp.hash(op, entry_point, chain_id)

    with {:ok, url} <- resolve_bundler_url(configured),
         {:ok, sig} <- sign_user_op_hash(uo_hash, signer) do
      signed = UserOp.put_signature(op, sig)
      Bundler.send_user_operation(url, signed, entry_point, opts)
    end
  end

  # -- Helpers --

  # viem's hashMessage: keccak256("\x19Ethereum Signed Message:\n" <> len <> data).
  # Operates on arbitrary-length data, unlike eip191_digest/1 (32-byte hash).
  defp hash_message(message) when is_binary(message) do
    prefix = "\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(message))
    ExKeccak.hash_256(prefix <> message)
  end

  # ExSecp256k1 returns recovery id v ∈ {0, 1}; Ethereum ecrecover (and
  # Account Kit's validation) expects v ∈ {27, 28}.
  defp normalize_v(<<r::binary-size(32), s::binary-size(32), v::8>>) when v < 27 do
    <<r::binary-size(32), s::binary-size(32), v + 27::8>>
  end

  defp normalize_v(<<_::binary-size(64), _v::8>> = sig), do: sig

  defp resolve_bundler_url(nil), do: {:error, :no_bundler_url}

  defp resolve_bundler_url({:system, var}) do
    case System.get_env(var) do
      nil -> {:error, {:env_not_set, var}}
      url -> {:ok, url}
    end
  end

  defp resolve_bundler_url(url) when is_binary(url), do: {:ok, url}
end
