defmodule Raxol.ACP.ProviderAdapter do
  @moduledoc """
  Low-level EVM provider behaviour. Mirrors `IEvmProviderAdapter` in
  `acp-node-v2`:

      sendCalls(chainId, calls)           # submit a batch of transactions
      signMessage(chainId, message)       # personal_sign / EIP-191
      signTypedData(chainId, typedData)   # EIP-712
      getTransactionReceipt(chainId, hash)
      readContract(chainId, params)
      getLogs(chainId, params)

  Two concrete implementations:

  - `Raxol.ACP.ProviderAdapter.Mock` -- in-process; records
    every call and returns canned responses. Used by `Raxol.ACP.Agent`
    and `Raxol.ACP.HookClient` tests so the full v2 lifecycle can be
    exercised without an RPC or a wallet.
  - `Raxol.ACP.ProviderAdapter.SCA` (not yet implemented) -- production:
    wraps `Raxol.ACP.Wallet.SCA` so calls flow through the
    Elixir-native MAv2 wallet + Alchemy paymaster + session key. No
    Privy dependency.

  ## Adapter shape

  An adapter is a map carrying the implementing module and its config:

      %{adapter: Raxol.ACP.ProviderAdapter.Mock, config: %{table: ...}}

  All callbacks take the adapter map as the first argument so that the
  implementation can stash whatever state it needs in `config`. This
  matches the pattern used by `Raxol.ACP.Transport` and
  `Raxol.ACP.JobApi`.

  ## Call shape

  `sendCalls` accepts a list of `call()` maps. Each carries the target
  address, value (wei), data (ABI calldata), and an optional gas hint.
  Returning a list of tx hashes (one per call) preserves the SDK's
  batch semantics: a single bundled UserOp will return one hash array;
  individual EOA calls return per-call hashes.
  """

  @type adapter :: %{required(:adapter) => module(), optional(:config) => map()}

  @type call :: %{
          required(:to) => String.t(),
          required(:data) => binary() | String.t(),
          optional(:value) => non_neg_integer(),
          optional(:gas) => non_neg_integer()
        }

  @type chain_id :: pos_integer()

  @type typed_data :: %{
          required(:domain) => map(),
          required(:types) => map(),
          required(:message) => map()
        }

  @type read_params :: %{
          required(:address) => String.t(),
          required(:signature) => String.t(),
          required(:args) => [{String.t(), term()}]
        }

  @type log_filter :: %{
          optional(:address) => String.t() | [String.t()],
          optional(:topics) => [String.t() | nil | [String.t()]],
          optional(:from_block) => non_neg_integer() | String.t(),
          optional(:to_block) => non_neg_integer() | String.t()
        }

  @callback send_calls(adapter(), chain_id(), [call()]) ::
              {:ok, [String.t()]} | {:error, term()}

  @callback sign_message(adapter(), chain_id(), binary()) ::
              {:ok, binary()} | {:error, term()}

  @callback sign_typed_data(adapter(), chain_id(), typed_data()) ::
              {:ok, binary()} | {:error, term()}

  @callback get_transaction_receipt(adapter(), chain_id(), String.t()) ::
              {:ok, map() | nil} | {:error, term()}

  @callback read_contract(adapter(), chain_id(), read_params()) ::
              {:ok, term()} | {:error, term()}

  @callback get_logs(adapter(), chain_id(), log_filter()) ::
              {:ok, [map()]} | {:error, term()}

  @callback get_address(adapter()) :: String.t()

  @callback supported_chain_ids(adapter()) :: [chain_id()]

  # -- Dispatch helpers --

  @spec send_calls(adapter(), chain_id(), [call()]) :: {:ok, [String.t()]} | {:error, term()}
  def send_calls(adapter, chain_id, calls),
    do: adapter.adapter.send_calls(adapter, chain_id, calls)

  @spec sign_message(adapter(), chain_id(), binary()) :: {:ok, binary()} | {:error, term()}
  def sign_message(adapter, chain_id, message),
    do: adapter.adapter.sign_message(adapter, chain_id, message)

  @spec sign_typed_data(adapter(), chain_id(), typed_data()) :: {:ok, binary()} | {:error, term()}
  def sign_typed_data(adapter, chain_id, typed_data),
    do: adapter.adapter.sign_typed_data(adapter, chain_id, typed_data)

  @spec get_transaction_receipt(adapter(), chain_id(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def get_transaction_receipt(adapter, chain_id, hash),
    do: adapter.adapter.get_transaction_receipt(adapter, chain_id, hash)

  @spec read_contract(adapter(), chain_id(), read_params()) :: {:ok, term()} | {:error, term()}
  def read_contract(adapter, chain_id, params),
    do: adapter.adapter.read_contract(adapter, chain_id, params)

  @spec get_logs(adapter(), chain_id(), log_filter()) :: {:ok, [map()]} | {:error, term()}
  def get_logs(adapter, chain_id, filter),
    do: adapter.adapter.get_logs(adapter, chain_id, filter)

  @spec get_address(adapter()) :: String.t()
  def get_address(adapter), do: adapter.adapter.get_address(adapter)

  @spec supported_chain_ids(adapter()) :: [chain_id()]
  def supported_chain_ids(adapter), do: adapter.adapter.supported_chain_ids(adapter)
end
