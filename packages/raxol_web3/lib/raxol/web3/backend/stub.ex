defmodule Raxol.Web3.Backend.Stub do
  @moduledoc """
  A complete, in-memory reference backend. Answers from data, never from a socket.

  This ships in `lib/` rather than `test/` on purpose, which is the convention
  ADR-0033 §3 sets and which `Raxol.Payments.ChainReader.Stub`,
  `Raxol.Gateway.Adapter.InMemory` and `Raxol.Earn.ProviderAdapter.Mock`
  already follow: no mocking library is introduced, and a consumer of this
  package can exercise the read contract, and the router's failover, without
  network access or a fixture directory of its own.

  It implements all fourteen callbacks, with defaults that answer plausibly out
  of the box, so it is a working backend rather than a shape. `:answers`
  overrides any callback with a canned result, which is how a test drives the
  paths a real upstream reaches only on a bad day:

      Stub.new("eip155:1", answers: %{chain_info: {:error, {:timeout, :chunk}}})

  ## What it is not

  It is not a simulator. Nothing here parses an address, walks a chain, or
  validates a cursor against the data it returns: a canned page carries a
  canned cursor. A test that needs an upstream's actual shape wants a recorded
  response through the `:exchange` seam (see
  `Raxol.Web3.Backend.BlockscoutTest`), and one that needs a real socket wants
  the live tag. This is for exercising the contract and the router around it.
  """

  @behaviour Raxol.Web3.Backend

  alias Raxol.Web3.Backend

  @enforce_keys [:chain_ref]
  defstruct chain_ref: nil, answers: %{}, capabilities: nil, health_key: nil, name: :stub

  @type t :: %__MODULE__{
          chain_ref: Backend.chain_ref(),
          answers: %{optional(atom()) => {:ok, term()} | {:error, term()}},
          capabilities: [atom()] | nil,
          health_key: Raxol.MCP.CircuitBreaker.key() | nil,
          name: atom()
        }

  @all_optional [
    :get_transaction,
    :account_info,
    :list_transactions,
    :token_balances,
    :get_block,
    :list_token_transfers,
    :read_contract,
    :contract_metadata,
    :get_logs,
    :resolve_name,
    :list_nfts,
    :raw_request
  ]

  @doc """
  Build a handle.

  Options:

    * `:answers` - a map of callback name to the result it should return,
      overriding the defaults.
    * `:capabilities` - which optional callbacks this handle declares. Defaults
      to all of them, so the default handle is the most capable one; pass a
      shorter list to model a source that answers less, which is the case the
      router exists to route around.
    * `:health_key` - a `Raxol.MCP.CircuitBreaker` key, or `nil` (the default)
      for a backend with no health to check. In-memory means never unhealthy.
    * `:name` - what this handle calls itself, default `:stub`. Two handles of
      one module is the normal case for a real backend with several upstreams,
      so a reference backend has to be able to model it: `Backend.name/1` and
      `Raxol.Web3.Router.coverage/2` report this rather than the module.

  """
  @spec new(Backend.chain_ref(), keyword()) :: {:ok, Backend.t()}
  def new(chain_ref, opts \\ []) do
    state = %__MODULE__{
      chain_ref: chain_ref,
      answers: Keyword.get(opts, :answers, %{}),
      capabilities: Keyword.get(opts, :capabilities),
      health_key: Keyword.get(opts, :health_key),
      name: Keyword.get(opts, :name, :stub)
    }

    {:ok, {__MODULE__, state}}
  end

  @impl Backend
  def backend, do: :stub

  @impl Backend
  def backend(%__MODULE__{name: name}), do: name

  @impl Backend
  def supported_chain_ids(%__MODULE__{chain_ref: chain_ref}), do: [chain_ref]

  @impl Backend
  def capabilities(%__MODULE__{capabilities: nil}), do: @all_optional
  def capabilities(%__MODULE__{capabilities: declared}), do: declared

  @impl Backend
  def health_key(%__MODULE__{health_key: key}), do: key

  # -- required ----------------------------------------------------------------

  @impl Backend
  def chain_info(%__MODULE__{} = state) do
    answer(state, :chain_info, %{
      chain_ref: state.chain_ref,
      average_block_time_ms: 12_000,
      total_blocks: 1_000_000,
      total_transactions: 2_000_000,
      total_addresses: 3_000
    })
  end

  @impl Backend
  def block_height(%__MODULE__{} = state) do
    answer(state, :block_height, %{
      height: 1_000_000,
      finalized_height: 999_936,
      unit: :block,
      indexer: %{finished?: true, indexed_ratio: 1.0}
    })
  end

  @impl Backend
  def get_transaction(%__MODULE__{} = state, hash) do
    answer(state, :get_transaction, %{
      hash: hash,
      status: :success,
      block: 1_000_000,
      timestamp: ~U[2026-09-14 00:00:00Z],
      from: {:evm, "0x0000000000000000000000000000000000000001"},
      to: {:evm, "0x0000000000000000000000000000000000000002"},
      value: 1_000_000_000_000_000_000,
      fee: 21_000,
      method: nil
    })
  end

  @impl Backend
  def account_info(%__MODULE__{} = state, account_ref) do
    answer(state, :account_info, %{
      ref: account_ref,
      balance: 1_000_000_000_000_000_000,
      contract?: false,
      verified?: false,
      name: nil,
      ens: nil
    })
  end

  @impl Backend
  def list_transactions(%__MODULE__{} = state, account_ref, _opts \\ []) do
    {:ok, transaction} = get_transaction(state, "0xstub")

    answer(state, :list_transactions, %{
      items: [%{transaction | from: account_ref}],
      next: nil
    })
  end

  @impl Backend
  def token_balances(%__MODULE__{} = state, _account_ref, _opts \\ []) do
    answer(state, :token_balances, %{
      items: [%{token: token(), amount: 42, token_id: nil}],
      next: nil
    })
  end

  # -- optional ----------------------------------------------------------------

  @impl Backend
  def get_block(%__MODULE__{} = state, number) do
    answer(state, :get_block, %{
      height: if(is_integer(number), do: number, else: 1_000_000),
      hash: "0xstubblock",
      timestamp: ~U[2026-09-14 00:00:00Z],
      transactions_count: 1,
      miner: {:evm, "0x0000000000000000000000000000000000000003"}
    })
  end

  @impl Backend
  def list_token_transfers(%__MODULE__{} = state, account_ref, _opts \\ []) do
    answer(state, :list_token_transfers, %{
      items: [
        %{
          token: token(),
          amount: 7,
          from: account_ref,
          to: {:evm, "0x0000000000000000000000000000000000000002"},
          block: 1_000_000,
          timestamp: ~U[2026-09-14 00:00:00Z],
          transaction: "0xstub"
        }
      ],
      next: nil
    })
  end

  @impl Backend
  def get_logs(%__MODULE__{} = state, account_ref, _opts \\ []) do
    {:evm, address} = account_ref

    answer(state, :get_logs, %{
      items: [
        %{
          address: address,
          topics: ["0xstubtopic"],
          data: "0x",
          block: 1_000_000,
          transaction: "0xstub",
          index: 0
        }
      ],
      next: nil
    })
  end

  @impl Backend
  def list_nfts(%__MODULE__{} = state, _account_ref, _opts \\ []) do
    answer(state, :list_nfts, %{
      items: [%{token: token(), token_id: "1", name: "Stub NFT", image_url: nil}],
      next: nil
    })
  end

  @impl Backend
  def contract_metadata(%__MODULE__{} = state, _account_ref) do
    answer(state, :contract_metadata, %{
      name: "Stub",
      verified?: true,
      language: "solidity",
      compiler_version: "v0.8.24",
      abi: [],
      proxy_type: nil
    })
  end

  @impl Backend
  def resolve_name(%__MODULE__{} = state, _name) do
    answer(state, :resolve_name, {:evm, "0x0000000000000000000000000000000000000001"})
  end

  @impl Backend
  def read_contract(%__MODULE__{} = state, _call) do
    answer(
      state,
      :read_contract,
      "0x0000000000000000000000000000000000000000000000000000000000000000"
    )
  end

  # Implemented here, unlike in the Blockscout backend, because a reference
  # backend has to be able to model a source that offers a passthrough at all.
  # The allowlist is still what bounds it: a method outside `@read_methods` is
  # refused before anything is answered, so this cannot be the thing that makes
  # the served surface writable.
  @impl Backend
  def raw_request(%__MODULE__{} = state, %{method: method} = request) do
    if method in Raxol.Web3.RPC.read_methods() do
      answer(state, :raw_request, %{method: method, params: Map.get(request, :params, [])})
    else
      {:error, {:unsupported, :rpc_method}}
    end
  end

  defp token do
    %{
      address: "0x0000000000000000000000000000000000000004",
      symbol: "STUB",
      name: "Stub Token",
      decimals: 18,
      type: "ERC-20"
    }
  end

  # A configured answer wins, including a configured error; otherwise the
  # default. Written this way so `:answers` can inject a failure into any
  # callback without the callback knowing about failure at all.
  defp answer(%__MODULE__{answers: answers}, callback, default) do
    case Map.fetch(answers, callback) do
      {:ok, {:ok, _value} = ok} -> ok
      {:ok, {:error, _reason} = error} -> error
      {:ok, value} -> {:ok, value}
      :error -> {:ok, default}
    end
  end
end
