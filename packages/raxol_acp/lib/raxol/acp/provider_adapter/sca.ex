defmodule Raxol.ACP.ProviderAdapter.SCA do
  @moduledoc """
  Production `Raxol.ACP.ProviderAdapter` backed by an Elixir-native
  Alchemy Modular Account v2 smart account (`Raxol.ACP.Wallet.SCA`).

  Writes flow as gasless ERC-4337 UserOperations: the call is wrapped in
  the account's `execute(...)`, sponsored by the Alchemy gas manager, and
  submitted to a bundler -- no EOA gas, no Privy. Reads
  (`get_transaction_receipt` / `read_contract` / `get_logs`) go straight
  to the chain's JSON-RPC via `Raxol.ACP.Onchain.RPC`; they never touch a
  key.

  ## Construction

      adapter =
        Raxol.ACP.ProviderAdapter.SCA.new(
          wallet: MyAgent.SCA,               # a `use Raxol.ACP.Wallet.SCA` module
          chains: %{8453 => "https://mainnet.base.org"},
          wallet_opts: [],                   # threaded into the wallet's sponsor/send/await
          auto_provision: true               # self-deploy + install session key on first write
        )

  `wallet_opts` is passed verbatim to `send_sponsored_user_operation/2`
  and `await_user_operation/2` -- in tests it carries
  `[req: Req.new(plug: ...), bundler_url: ..., paymaster_url: ...]`; in
  production it is usually `[]` (the wallet's compile-time bundler /
  paymaster URLs win). The node RPC client for reads + nonce + deploy
  checks is built from `chains[chain_id]`; tests inject a stub via
  `config :raxol_acp, rpc: [url: ..., plug: ...]`.

  ## Provisioning

  On the first write, if `auto_provision` is true (default), the adapter
  runs `Raxol.ACP.Wallet.SCA.Provisioner.ensure_provisioned/3` **before**
  building the write op: it deploys the SMA (owner-signed UserOp with
  factory `initCode`) and registers the session key (owner-signed
  `installValidation`, NOT `execute`-wrapped). Both steps are idempotent
  -- once done, subsequent writes submit exactly one UserOp. The write op
  itself carries `init_code: <<>>` and the session-entity nonce; it never
  re-attaches initCode.

  ## Signing shapes

  - `sign_message/3` -> the wallet's EIP-1271 single-signer frame
    (`0x00 || entityId(4) || 0xFF || 0x00 || sig` over a ReplaySafeHash
    envelope), NOT a bare EIP-191 signature. Use it for off-chain auth
    (the ACP JWT challenge).
  - `sign_typed_data/3` -> the same 1271 frame over an EIP-712 hash.

  ## Batch semantics

  `send_calls/3` accepts a single call and returns a one-element hash
  list. A multi-call batch returns `{:error, :batch_unsupported}`: no v2
  caller needs `executeBatch` (`Raxol.ACP.HookClient.submit_single/5`
  always passes exactly one call), and the minimal ABI encoder has no
  array-of-tuple support. Building `executeBatch` is a deliberate
  follow-up, not done here. An empty list is a no-op (`{:ok, []}`).
  """

  @behaviour Raxol.ACP.ProviderAdapter

  alias Raxol.ACP.ABI
  alias Raxol.ACP.Onchain.RPC
  alias Raxol.ACP.Wallet.SCA.{EntryPoint, ModularAccount, Provisioner, UserOp}

  @type config :: %{
          wallet: module(),
          chains: %{required(pos_integer()) => String.t()},
          wallet_opts: keyword(),
          auto_provision: boolean()
        }

  @doc """
  Build an SCA adapter map.

  ## Required options

  - `:wallet` -- a `use Raxol.ACP.Wallet.SCA` module.
  - `:chains` -- `%{chain_id => rpc_url}`; must include the wallet's
    `chain_id/0`.

  ## Optional

  - `:wallet_opts` -- keyword threaded into the wallet's sponsored-send /
    await calls (default `[]`).
  - `:auto_provision` -- deploy + install the session key on first write
    (default `true`).
  """
  @spec new(keyword()) :: Raxol.ACP.ProviderAdapter.adapter()
  def new(opts) do
    wallet = Keyword.fetch!(opts, :wallet)
    chains = Keyword.fetch!(opts, :chains)

    validate_wallet!(wallet)
    validate_chains!(wallet, chains)

    config = %{
      wallet: wallet,
      chains: chains,
      wallet_opts: Keyword.get(opts, :wallet_opts, []),
      auto_provision: Keyword.get(opts, :auto_provision, true)
    }

    %{adapter: __MODULE__, config: config}
  end

  defp validate_wallet!(wallet) do
    Code.ensure_loaded(wallet)

    if not (function_exported?(wallet, :send_sponsored_user_operation, 2) and
              function_exported?(wallet, :address, 0)) do
      raise ArgumentError,
            ":wallet must be a Raxol.ACP.Wallet.SCA module " <>
              "(needs send_sponsored_user_operation/2 and address/0), got #{inspect(wallet)}"
    end
  end

  defp validate_chains!(wallet, chains) do
    if not (is_map(chains) and Map.has_key?(chains, wallet.chain_id())) do
      raise ArgumentError,
            ":chains must include the wallet's chain_id #{inspect(wallet.chain_id())}"
    end
  end

  # -- Behaviour callbacks --

  @impl Raxol.ACP.ProviderAdapter
  def get_address(%{config: %{wallet: wallet}}), do: wallet.address()

  @impl Raxol.ACP.ProviderAdapter
  def supported_chain_ids(%{config: %{chains: chains}}),
    do: chains |> Map.keys() |> Enum.sort()

  @impl Raxol.ACP.ProviderAdapter
  def send_calls(%{config: cfg}, chain_id, calls) do
    with :ok <- validate_chain(cfg, chain_id) do
      dispatch_calls(cfg, chain_id, calls)
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def sign_message(%{config: %{wallet: wallet}}, _chain_id, message),
    do: wallet.sign_message(message)

  @impl Raxol.ACP.ProviderAdapter
  def sign_typed_data(%{config: %{wallet: wallet}}, _chain_id, %{
        domain: domain,
        types: types,
        message: message
      }),
      do: wallet.sign_typed_data(domain, types, message)

  @impl Raxol.ACP.ProviderAdapter
  def get_transaction_receipt(%{config: cfg}, chain_id, tx_hash) do
    with {:ok, client} <- node_client(cfg, chain_id) do
      RPC.get_transaction_receipt(client, tx_hash)
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def read_contract(%{config: cfg}, chain_id, %{
        address: address,
        signature: signature,
        args: args
      }) do
    with {:ok, client} <- node_client(cfg, chain_id) do
      # Pass raw binary; RPC.eth_call hex-encodes the calldata for us.
      data = ABI.encode_call(signature, args)
      RPC.eth_call(client, %{to: address, data: data})
    end
  end

  @impl Raxol.ACP.ProviderAdapter
  def get_logs(%{config: cfg}, chain_id, filter) do
    with {:ok, client} <- node_client(cfg, chain_id) do
      RPC.request(client, "eth_getLogs", [build_log_filter(filter)])
    end
  end

  # -- Write dispatch --

  defp dispatch_calls(_cfg, _chain_id, []), do: {:ok, []}
  defp dispatch_calls(cfg, chain_id, [call]), do: send_one(cfg, chain_id, call)
  defp dispatch_calls(_cfg, _chain_id, [_, _ | _]), do: {:error, :batch_unsupported}

  defp send_one(cfg, chain_id, call) do
    wallet = cfg.wallet

    with {:ok, client} <- node_client(cfg, chain_id),
         :ok <- maybe_provision(cfg, client),
         {:ok, nonce} <-
           EntryPoint.get_nonce(
             client,
             wallet.entry_point(),
             wallet.address(),
             wallet.nonce_key()
           ),
         {:ok, op_hash} <- send_write_op(cfg, call, nonce),
         {:ok, uo_receipt} <- wallet.await_user_operation(op_hash, cfg.wallet_opts) do
      # A single call maps to one atomic UserOp; the on-chain tx hash is
      # in the bundler receipt (or the op hash if the receipt omits it).
      tx_hash = get_in(uo_receipt, ["receipt", "transactionHash"]) || op_hash
      {:ok, [tx_hash]}
    end
  end

  # The write op wraps the ACP call in execute(), carries the
  # session-entity nonce, and NEVER attaches initCode -- provisioning
  # already deployed the account.
  defp send_write_op(cfg, call, nonce) do
    wallet = cfg.wallet

    call_data =
      ModularAccount.execute_calldata(
        Map.fetch!(call, :to),
        Map.get(call, :value, 0),
        normalize_data(Map.get(call, :data, <<>>))
      )

    op = %UserOp{
      sender: wallet.address(),
      nonce: nonce,
      call_data: call_data,
      init_code: <<>>
    }

    wallet.send_sponsored_user_operation(op, cfg.wallet_opts)
  end

  defp maybe_provision(%{auto_provision: false}, _client), do: :ok

  defp maybe_provision(cfg, client) do
    case Provisioner.ensure_provisioned(cfg.wallet, client, cfg.wallet_opts) do
      {:ok, _status} -> :ok
      {:error, _} = err -> err
    end
  end

  # -- Internals --

  defp validate_chain(cfg, chain_id) do
    if chain_id == cfg.wallet.chain_id() and Map.has_key?(cfg.chains, chain_id) do
      :ok
    else
      {:error, {:unsupported_chain, chain_id}}
    end
  end

  # Node RPC client for reads + nonce + deploy checks. The URL comes from
  # the chains map; a test stub plug is picked up from the :raxol_acp :rpc
  # app config (mirrors ContractClient.Onchain). No private key is ever
  # involved on this path.
  defp node_client(%{chains: chains}, chain_id) do
    case Map.fetch(chains, chain_id) do
      {:ok, url} -> {:ok, RPC.client(url: url)}
      :error -> {:error, {:unsupported_chain, chain_id}}
    end
  end

  defp build_log_filter(filter) do
    Enum.reduce(filter, %{}, fn
      {:address, addr}, acc -> Map.put(acc, "address", addr)
      {:topics, topics}, acc -> Map.put(acc, "topics", topics)
      {:from_block, b}, acc -> Map.put(acc, "fromBlock", encode_block(b))
      {:to_block, b}, acc -> Map.put(acc, "toBlock", encode_block(b))
      _, acc -> acc
    end)
  end

  defp encode_block(n) when is_integer(n) and n >= 0, do: "0x" <> Integer.to_string(n, 16)
  defp encode_block(b) when is_binary(b), do: b

  defp normalize_data("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp normalize_data(bin) when is_binary(bin), do: bin
end
