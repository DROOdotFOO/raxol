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

  alias Raxol.ACP.Wallet.SCA.{Bundler, ModularAccount, Paymaster, UserOp}

  @default_entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  defmacro __using__(opts) do
    account = Keyword.fetch!(opts, :account_address)
    chain = Keyword.fetch!(opts, :chain_id)
    signer = Keyword.fetch!(opts, :signer)
    entity_id = Keyword.get(opts, :signer_entity_id, 0)
    bundler_url = Keyword.get(opts, :bundler_url)
    entry_point = Keyword.get(opts, :entry_point, @default_entry_point)
    paymaster_policy_id = Keyword.get(opts, :paymaster_policy_id)
    # Alchemy multiplexes bundler + paymaster on one URL; default to it.
    paymaster_url = Keyword.get(opts, :paymaster_url, bundler_url)

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

      @doc """
      Counterfactual SMA address for this wallet's session key as owner
      at `salt` (default 0). Should match `address/0` when the account
      was deployed by this signer with the same salt.
      """
      @spec predicted_address(non_neg_integer()) :: String.t()
      def predicted_address(salt \\ 0) do
        Raxol.ACP.Wallet.SCA.Provisioning.predict_address(unquote(signer).address(), salt)
      end

      @doc """
      ERC-4337 `initCode` that self-deploys this account on its first
      UserOperation. Set it on the UserOp via `%UserOp{init_code: ...}`
      when the account is not yet deployed on chain.
      """
      @spec deploy_init_code(non_neg_integer()) :: binary()
      def deploy_init_code(salt \\ 0) do
        Raxol.ACP.Wallet.SCA.Provisioning.deploy_init_code(unquote(signer).address(), salt)
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

      @doc """
      Fill gas + paymaster data via the Alchemy gas manager, returning
      a sponsored UserOp ready to sign and send. Requires
      `:paymaster_policy_id` in config.
      """
      @spec sponsor(Raxol.ACP.Wallet.SCA.UserOp.t(), keyword()) ::
              {:ok, Raxol.ACP.Wallet.SCA.UserOp.t()} | {:error, term()}
      def sponsor(op, opts \\ []) do
        Raxol.ACP.Wallet.SCA.sponsor(
          op,
          unquote(paymaster_url),
          unquote(paymaster_policy_id),
          unquote(entry_point),
          opts
        )
      end

      @doc """
      One-shot gasless send: sponsor via the gas manager, then sign and
      submit to the bundler. Requires `:paymaster_policy_id`.
      """
      @spec send_sponsored_user_operation(Raxol.ACP.Wallet.SCA.UserOp.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
      def send_sponsored_user_operation(op, opts \\ []) do
        with {:ok, sponsored} <- sponsor(op, opts) do
          send_user_operation(sponsored, opts)
        end
      end

      @doc "The configured EntryPoint address."
      @spec entry_point() :: String.t()
      def entry_point, do: unquote(entry_point)

      @doc "The configured bundler URL (resolving `{:system, var}`)."
      @spec bundler_url() :: {:ok, String.t()} | {:error, term()}
      def bundler_url, do: Raxol.ACP.Wallet.SCA.resolve_bundler_url(unquote(bundler_url))

      @doc """
      Poll the bundler for a UserOperation receipt by its hash. Returns
      the bundler receipt (which embeds the on-chain tx receipt + logs).
      """
      @spec await_user_operation(String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
      def await_user_operation(op_hash, opts \\ []) do
        Raxol.ACP.Wallet.SCA.await_user_operation(op_hash, unquote(bundler_url), opts)
      end
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

  @doc false
  @spec sponsor(
          UserOp.t(),
          String.t() | {:system, String.t()} | nil,
          String.t() | nil,
          String.t(),
          keyword()
        ) :: {:ok, UserOp.t()} | {:error, term()}
  def sponsor(_op, _url, nil, _entry_point, _opts), do: {:error, :no_paymaster_policy_id}

  def sponsor(op, paymaster_url, policy_id, entry_point, opts) do
    configured = Keyword.get(opts, :paymaster_url, paymaster_url)

    with {:ok, url} <- resolve_url(configured, :no_paymaster_url) do
      Paymaster.sponsor(url, policy_id, entry_point, op, opts)
    end
  end

  @doc false
  @spec await_user_operation(String.t(), String.t() | {:system, String.t()} | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def await_user_operation(op_hash, bundler_url, opts) do
    configured = Keyword.get(opts, :bundler_url, bundler_url)

    with {:ok, url} <- resolve_bundler_url(configured) do
      Bundler.wait_for_receipt(url, op_hash, opts)
    end
  end

  @doc false
  @spec resolve_bundler_url(String.t() | {:system, String.t()} | nil) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_bundler_url(url), do: resolve_url(url, :no_bundler_url)

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

  # Resolve a URL that may be a literal string, a `{:system, var}`
  # env-var reference, or nil (returns the supplied error atom).
  defp resolve_url(nil, missing_error), do: {:error, missing_error}

  defp resolve_url({:system, var}, _missing_error) do
    case System.get_env(var) do
      nil -> {:error, {:env_not_set, var}}
      url -> {:ok, url}
    end
  end

  defp resolve_url(url, _missing_error) when is_binary(url), do: {:ok, url}
end
