defmodule Raxol.Web3.MCP.Tools do
  @moduledoc """
  The served MCP surface: thirteen read tools over a `Raxol.Web3.Router`.

  ADR-0033 decision 4. `tool_def` maps are written directly rather than derived
  through `Raxol.MCP.AgentBridge`, which that decision rejects on three
  grounds: it has no caller anywhere in the repository, it drops the
  `sensitive` flag instead of emitting an annotation, and it formats results
  with `inspect/2` rather than JSON.

  ## Read-only by construction, not by annotation

  Every tool here is a read, and the reason that claim holds is structural
  rather than declared. `raw_request/2` has **no tool**: the contract's one
  passthrough callback is absent from this module, so there is no served path
  that takes a method name from a caller. `Raxol.Web3.Backend.Blockscout`
  declines the callback entirely and `Raxol.Web3.RPC` bounds its own methods to
  a compile-time allowlist, so the surface is read-only at three layers and
  annotated at none of them.

  That matters because the annotation enforces nothing on its own.
  `Raxol.MCP.Server.refuse_unguarded_sensitive_tools!/2` raises at boot only
  when a registered tool is annotated sensitive and no authorizer is
  configured; an UNannotated write tool passes it unimpeded. So the annotation
  records an intent, and the absence of a write path is what makes the intent
  true. `readOnlyHint` is set because it is accurate and useful to a host, not
  because it is load-bearing.

  ## Why thirteen tools and not one

  The survey's own finding is that 268 pass-through tools from two servers
  consume a large share of a context window, and that Helius reached ten router
  tools for all of Solana instead. Thirteen typed tools is the normalized
  contract that finding argues for: each one names its arguments, so a model
  does not have to be told the shape of an untyped `params` map in prose. The
  agent Action surface makes the opposite trade for the opposite reason, and
  `Raxol.Agent.Actions.Web3` says why.

  ## Errors carry no upstream text

  A failure is rendered by `Raxol.Web3.Serialize.error/1` as a code plus its
  own datum. The taxonomy has no message field to fill, which is the whole
  point of ADR-0038 decision 6, and this is the surface where a leak would be
  worst: an MCP tool result is text a model reads and may act on.
  """

  alias Raxol.MCP.Registry
  alias Raxol.Web3.Router
  alias Raxol.Web3.Serialize

  @prefix "web3_"

  # One description for the eight `account` arguments, and the one place to
  # change when a family lands. `Raxol.Web3.Serialize.account_ref/1` reads an
  # unprefixed value as EVM, so every other family has to be named here: a
  # model that sends a bare Solana pubkey gets `{:unsupported_account_ref,
  # :evm}` and no way to tell from the schema why.
  @families ~s(An unprefixed value is read as EVM; every other family must ) <>
              ~s(name itself: "tron:T...", "solana:<pubkey>", ) <>
              ~s("party:<party-id>", "aztec:0x...".)

  @account_ref "Account reference. " <> @families
  @contract_ref "Contract account reference. " <> @families

  # Every served tool, as {tool suffix, callback, [arg]}, where an arg is
  # {name, type, required?, description}. Data rather than thirteen functions,
  # because the interesting property is that this list and the callback set
  # agree, and a test asserts it.
  @tools [
    {:chain_info, :chain_info, [],
     "Chain statistics: block time, and counts of blocks, transactions and addresses."},
    {:block_height, :block_height, [],
     "The chain's height and its finalized height, with the unit they are counted in and the indexer's lag."},
    {:get_transaction, :get_transaction, [{"hash", :string, true, "Transaction hash."}],
     "One transaction: status, value, fee and counterparties."},
    {:account_info, :account_info, [{"account", :string, true, @account_ref}],
     "One account: native balance, whether it has code, and its primary name."},
    {:list_transactions, :list_transactions,
     [
       {"account", :string, true, @account_ref},
       {"cursor", :string, false, "Opaque cursor from a previous page."}
     ], "A page of an account's transactions, newest first."},
    {:token_balances, :token_balances,
     [
       {"account", :string, true, @account_ref},
       {"cursor", :string, false, "Opaque cursor from a previous page."}
     ], "A page of the tokens an account holds, with amounts."},
    {:list_token_transfers, :list_token_transfers,
     [
       {"account", :string, true, @account_ref},
       {"cursor", :string, false, "Opaque cursor from a previous page."}
     ], "A page of token transfers involving an account."},
    {:get_logs, :get_logs,
     [
       {"account", :string, true, @contract_ref},
       {"cursor", :string, false, "Opaque cursor from a previous page."}
     ], "A page of event logs emitted by a contract."},
    {:list_nfts, :list_nfts,
     [
       {"account", :string, true, @account_ref},
       {"cursor", :string, false, "Opaque cursor from a previous page."}
     ], "A page of the NFTs an account holds."},
    {:contract_metadata, :contract_metadata, [{"account", :string, true, @contract_ref}],
     "A contract's verification state, language, compiler and ABI."},
    {:get_block, :get_block, [{"number", :integer, true, "Block number."}],
     "One block: height, hash, timestamp, transaction count and proposer."},
    {:resolve_name, :resolve_name,
     [{"name", :string, true, "A name to resolve, e.g. \"vitalik.eth\"."}],
     "The account a name resolves to."},
    {:read_contract, :read_contract,
     [
       {"to", :string, true, "Contract address."},
       {"data", :string, true, "ABI-encoded call data, hex."},
       {"block", :string, false, "Block tag or number, default \"latest\"."}
     ],
     "A read-only contract call. Never a write: this is eth_call, and the method allowlist admits nothing else."}
  ]

  # The atom form of every argument name, interned at compile time off the
  # table above plus the chain every tool takes.
  #
  # `String.to_existing_atom/1` was the wrong tool here. It does not raise only
  # when something else already interned the atom, so EVERY absent argument
  # evaluated it and raised `ArgumentError` instead of being reported missing:
  # no `:chain` literal exists anywhere in this package's `lib/`, so in a
  # release `web3_chain_info` with no arguments crashed rather than answering
  # `{:missing_argument, "chain"}`. A compile-time table cannot create an atom
  # at runtime and cannot fail to find one, which is the reasoning
  # `Raxol.Web3.Serialize`'s tag table already records.
  @atom_keys Map.new(
               [
                 "chain"
                 | for(
                     {_suffix, _callback, args, _doc} <- @tools,
                     {name, _type, _required?, _description} <- args,
                     do: name
                   )
               ],
               &{&1, String.to_atom(&1)}
             )

  @doc "The names of every tool this module serves."
  @spec names() :: [String.t()]
  def names,
    do: Enum.map(@tools, fn {suffix, _callback, _args, _doc} -> @prefix <> "#{suffix}" end)

  @doc "The backend callbacks this surface exposes. `raw_request` is not among them."
  @spec callbacks() :: [atom()]
  def callbacks, do: Enum.map(@tools, fn {_suffix, callback, _args, _doc} -> callback end)

  @doc """
  Tool definitions bound to a router.

  Each callback closes over the router, so a tool call is a router call: the
  vet, the budget, the breaker, the pinned dial and the bounds are all
  upstream of it and none of them can be skipped by reaching this surface.
  """
  @spec tool_defs(Router.t()) :: [Registry.tool_def()]
  def tool_defs(%Router{} = router) do
    Enum.map(@tools, fn {suffix, callback, args, description} ->
      %{
        name: @prefix <> "#{suffix}",
        description: description,
        inputSchema: schema(args),
        annotations: %{readOnlyHint: true},
        callback: fn arguments -> dispatch(router, callback, args, arguments) end
      }
    end)
  end

  @doc """
  Register every tool with an `Raxol.MCP.Registry`.

  `register_all/2` validates each tool's shape first and registers nothing if
  any one of them fails, which is the behaviour to want here: a half-registered
  surface is worse than an absent one.
  """
  @spec register(GenServer.server(), Router.t()) :: :ok | {:error, term()}
  def register(registry, %Router{} = router) do
    Registry.register_all(registry, tools: tool_defs(router))
  end

  defp schema(args) do
    properties =
      Map.new([{"chain", chain_property()} | Enum.map(args, &property/1)])

    required = ["chain" | for({name, _type, true, _doc} <- args, do: name)]

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  defp chain_property do
    %{
      "type" => "string",
      "description" => "CAIP-2 chain reference, e.g. \"eip155:1\" for Ethereum mainnet."
    }
  end

  defp property({name, type, _required?, description}) do
    {name, %{"type" => Atom.to_string(type), "description" => description}}
  end

  # Arguments arrive JSON-decoded, so string keys, but a local Elixir caller
  # writes atoms. Both are accepted rather than one being documented, because
  # the failure mode of guessing wrong is a required argument reported missing
  # when it was supplied.
  defp dispatch(router, callback, arg_spec, arguments) do
    with {:ok, chain} <- fetch(arguments, "chain"),
         {:ok, args} <- build_args(callback, arg_spec, arguments) do
      call(router, chain, callback, args)
    else
      {:error, reason} -> {:error, Serialize.error(reason)}
    end
  end

  defp call(router, chain, callback, args) do
    case Router.call(router, chain, callback, args) do
      {:ok, value} -> {:ok, Serialize.result(value)}
      {:error, reason} -> {:error, Serialize.error(reason)}
    end
  end

  defp build_args(:chain_info, _spec, _arguments), do: {:ok, []}
  defp build_args(:block_height, _spec, _arguments), do: {:ok, []}

  defp build_args(:get_transaction, _spec, arguments) do
    with {:ok, hash} <- fetch(arguments, "hash"), do: {:ok, [hash]}
  end

  defp build_args(:resolve_name, _spec, arguments) do
    with {:ok, name} <- fetch(arguments, "name"), do: {:ok, [name]}
  end

  defp build_args(:get_block, _spec, arguments) do
    with {:ok, number} <- fetch(arguments, "number"), do: {:ok, [number]}
  end

  defp build_args(:read_contract, _spec, arguments) do
    with {:ok, to} <- fetch(arguments, "to"),
         {:ok, data} <- fetch(arguments, "data") do
      call = %{to: to, data: data}

      {:ok, [maybe_put(call, :block, get(arguments, "block"))]}
    end
  end

  defp build_args(callback, _spec, arguments)
       when callback in [:account_info, :contract_metadata] do
    with {:ok, account} <- fetch(arguments, "account") do
      {:ok, [Serialize.account_ref(account)]}
    end
  end

  defp build_args(callback, _spec, arguments)
       when callback in [
              :list_transactions,
              :token_balances,
              :list_token_transfers,
              :get_logs,
              :list_nfts
            ] do
    with {:ok, account} <- fetch(arguments, "account") do
      opts = maybe_put([], :cursor, get(arguments, "cursor"))

      {:ok, [Serialize.account_ref(account), opts]}
    end
  end

  defp fetch(arguments, name) do
    case get(arguments, name) do
      nil -> {:error, {:missing_argument, name}}
      value -> {:ok, value}
    end
  end

  defp get(arguments, name) when is_map(arguments) do
    Map.get(arguments, name) || Map.get(arguments, Map.fetch!(@atom_keys, name))
  end

  defp get(_arguments, _name), do: nil

  defp maybe_put(target, _key, nil), do: target
  defp maybe_put(target, key, value) when is_map(target), do: Map.put(target, key, value)
  defp maybe_put(target, key, value) when is_list(target), do: Keyword.put(target, key, value)
end
