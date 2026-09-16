if Code.ensure_loaded?(Raxol.Web3.Router) do
  defmodule Raxol.Agent.Actions.Web3 do
    @moduledoc """
    The `web3` tool: read on-chain data through a `Raxol.Web3.Router`.

    ADR-0033 decision 4's agent surface. It lives in `raxol_agent` rather than
    in `raxol_web3` because `use Raxol.Agent.Action` is a macro from this
    package, and defining the Action over there would pull the framework and
    the agent runtime underneath a read-only package: exactly the graph
    inversion ADR-0033 decision 2 exists to fix. The dependency edge points
    from consumer to provider, and `raxol_web3` is an optional dependency here,
    so this module is absent from a build without it.

    ## One tool, not thirteen

    The MCP surface (`Raxol.Web3.MCP.Tools`) serves thirteen typed tools; this
    serves one with an `operation` enum, and the asymmetry is deliberate. An
    MCP server is something an operator connects on purpose, and its tool list
    is scoped to that connection. An agent Action sits in a coding agent's
    toolset for the whole session, where the survey's finding binds: 268
    pass-through tools consumed a large share of a context window, and Helius
    reached ten router tools for all of Solana instead. Thirteen more tool
    definitions in every prompt is a real cost paid by every turn, including
    the turns that never touch a chain.

    The operation is validated against a compile-time list, so this is a router
    tool and not a passthrough: `raw_request` is not in it, and no operation
    takes an RPC method name.

    ## Configuration and gating

    The router comes from `context[:web3_router]`, following
    `Raxol.Agent.Actions.SessionSearch`'s pattern: an unconfigured tool is
    `{:error, :web3_not_configured}` rather than a tool that guesses at an
    upstream.

    `Raxol.Agent.Actions.Code.network_allow/1` refuses outright in a jailed
    (multi-tenant) session unless the context says `network: true`, because this
    tool spends the operator's rate-limit budget against a third party from the
    operator's address.

    `sensitive: true`, for the reason `Raxol.Agent.Actions.Fetch` gives: a read
    is not free of consequence, because it discloses to a third party what the
    session is working on, and "which address is this user researching" is
    exactly that. The MCP surface applies the same gate while additionally
    advertising `readOnlyHint` to describe the chain operation accurately.
    """

    use Raxol.Agent.Action,
      name: "web3",
      sensitive: true,
      description:
        "Read on-chain data: chain stats, heights, transactions, accounts, token " <>
          "balances, transfers, logs, NFTs, contract metadata and read-only contract " <>
          "calls. Read-only: there is no operation that can send a transaction.",
      schema: [
        input: [
          operation: [
            type: :string,
            required: true,
            enum: [
              "chain_info",
              "block_height",
              "get_transaction",
              "account_info",
              "list_transactions",
              "token_balances",
              "list_token_transfers",
              "get_logs",
              "list_nfts",
              "contract_metadata",
              "get_block",
              "resolve_name",
              "read_contract"
            ],
            description: "Which read to perform."
          ],
          chain: [
            type: :string,
            required: true,
            description: "CAIP-2 chain reference, e.g. \"eip155:1\" for Ethereum mainnet."
          ],
          account: [
            type: :string,
            description: "Account reference: an address, or \"evm:0x...\" to be explicit."
          ],
          hash: [type: :string, description: "Transaction hash, for get_transaction."],
          number: [type: :integer, description: "Block number, for get_block."],
          name: [type: :string, description: "Name to resolve, for resolve_name."],
          cursor: [type: :string, description: "Opaque cursor from a previous page."],
          to: [type: :string, description: "Contract address, for read_contract."],
          data: [type: :string, description: "ABI-encoded call data, for read_contract."],
          block: [type: :string, description: "Block tag or number, for read_contract."]
        ],
        output: [
          operation: [type: :string],
          chain: [type: :string],
          result: [type: :map]
        ]
      ]

    alias Raxol.Web3.Router
    alias Raxol.Web3.Serialize

    @operations %{
      "chain_info" => :chain_info,
      "block_height" => :block_height,
      "get_transaction" => :get_transaction,
      "account_info" => :account_info,
      "list_transactions" => :list_transactions,
      "token_balances" => :token_balances,
      "list_token_transfers" => :list_token_transfers,
      "get_logs" => :get_logs,
      "list_nfts" => :list_nfts,
      "contract_metadata" => :contract_metadata,
      "get_block" => :get_block,
      "resolve_name" => :resolve_name,
      "read_contract" => :read_contract
    }

    @impl true
    def run(%{operation: operation, chain: chain} = params, context) do
      with :ok <- Raxol.Agent.Actions.Code.network_allow(context),
           {:ok, router} <- router(context),
           {:ok, callback} <- callback(operation),
           {:ok, args} <- args(callback, params) do
        call(router, chain, operation, callback, args)
      end
    end

    @doc "The operations this tool accepts. The enum and the dispatch come from one table."
    @spec operations() :: [String.t()]
    def operations, do: Map.keys(@operations)

    defp call(router, chain, operation, callback, args) do
      case Router.call(router, chain, callback, args) do
        {:ok, value} ->
          {:ok, %{operation: operation, chain: chain, result: wrap(value)}}

        {:error, reason} ->
          # Returned as-is, not rendered. `Raxol.Web3.MCP.Tools` renders the
          # same taxonomy into `%{code:, detail:}` because MCP is a JSON
          # protocol and a tool result is data; here the error becomes a
          # `[Tool error for ...]` message in the react loop, so an Elixir term
          # is what every other Action in this package returns and a map would
          # be a second style in one function. Nothing is lost: the taxonomy is
          # atoms and integers, which is the property ADR-0038 decision 6 is
          # about, and a term carries no upstream text either.
          {:error, reason}
      end
    end

    defp router(context) do
      case Map.fetch(context, :web3_router) do
        {:ok, %Router{} = router} -> {:ok, router}
        _absent -> {:error, :web3_not_configured}
      end
    end

    defp callback(operation) do
      case Map.fetch(@operations, operation) do
        {:ok, callback} -> {:ok, callback}
        :error -> {:error, {:unknown_operation, operation}}
      end
    end

    defp args(callback, _params) when callback in [:chain_info, :block_height], do: {:ok, []}

    defp args(:get_transaction, params) do
      with {:ok, hash} <- fetch(params, :hash), do: {:ok, [hash]}
    end

    defp args(:resolve_name, params) do
      with {:ok, name} <- fetch(params, :name), do: {:ok, [name]}
    end

    defp args(:get_block, params) do
      with {:ok, number} <- fetch(params, :number), do: {:ok, [number]}
    end

    defp args(:read_contract, params) do
      with {:ok, to} <- fetch(params, :to),
           {:ok, data} <- fetch(params, :data) do
        call_args = %{to: to, data: data}

        {:ok, [maybe_put(call_args, :block, Map.get(params, :block))]}
      end
    end

    defp args(callback, params)
         when callback in [:account_info, :contract_metadata] do
      with {:ok, account} <- fetch(params, :account) do
        {:ok, [Serialize.account_ref(account)]}
      end
    end

    defp args(callback, params)
         when callback in [
                :list_transactions,
                :token_balances,
                :list_token_transfers,
                :get_logs,
                :list_nfts
              ] do
      with {:ok, account} <- fetch(params, :account) do
        opts = maybe_put([], :cursor, Map.get(params, :cursor))

        {:ok, [Serialize.account_ref(account), opts]}
      end
    end

    defp fetch(params, key) do
      case Map.get(params, key) do
        nil -> {:error, {:missing_argument, Atom.to_string(key)}}
        value -> {:ok, value}
      end
    end

    # A scalar answer is wrapped so the declared output type holds for every
    # operation. It also reads better to a model: `%{value: "0x2a"}` says what
    # it is where a bare `"0x2a"` does not.
    defp wrap(value) when is_map(value), do: Serialize.result(value)
    defp wrap({tag, _value} = ref) when is_atom(tag), do: %{account: Serialize.result(ref)}
    defp wrap(value) when is_binary(value), do: %{value: value}

    defp maybe_put(target, _key, nil), do: target
    defp maybe_put(target, key, value) when is_map(target), do: Map.put(target, key, value)
    defp maybe_put(target, key, value) when is_list(target), do: Keyword.put(target, key, value)
  end
end
