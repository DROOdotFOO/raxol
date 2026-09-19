defmodule Raxol.Web3.MCP.Tools do
  @moduledoc """
  The served MCP surface: thirteen read tools over a `Raxol.Web3.Router`.

  ADR-0033 decision 4. `tool_def` maps are written directly rather than derived
  through `Raxol.MCP.AgentBridge`, which that decision rejects on three
  grounds: it has no caller anywhere in the repository, it drops the
  `sensitive` flag instead of emitting an annotation, and it formats results
  with `inspect/2` rather than JSON.

  ## Read-only does not mean authorization-free

  Every tool here is a chain read: `raw_request/2` has **no tool**, and the RPC
  backend admits only its compile-time method allowlist. The calls nevertheless
  disclose an operator's addresses, names and query intent to an upstream
  service and can consume a paid provider quota. They are therefore annotated
  both `readOnlyHint: true` and `sensitive: true`.

  `Raxol.MCP.Server.refuse_unguarded_sensitive_tools!/2` makes that annotation
  load-bearing: this surface cannot be served without an authorizer. Read-only
  describes chain state; sensitive describes the external capability exercised
  to retrieve it.

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

  ## Not every error is evidence against the tool

  `Raxol.MCP.Registry` keeps a breaker per tool and would otherwise count any
  `{:error, _}` toward it, so a handful of reads of accounts that do not exist
  would quarantine a tool that is working. `fault?/1` declares which of this
  package's reasons are faults of the SOURCE and which are answers about the
  QUESTION, along the same line `Raxol.Web3.Router.failover?/1` draws.
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
        annotations: %{readOnlyHint: true, sensitive: true},
        fault?: &__MODULE__.fault?/1,
        callback: fn arguments -> dispatch(router, callback, args, arguments) end
      }
    end)
  end

  # Every reason that is an answer about the question rather than a fault of
  # the source, as `Raxol.Web3.Serialize.error/1` renders its code.
  #
  # `blocked` is the one entry where this split and the router's disagree, and
  # deliberately. The router fails a blocked ADDRESS over, because a sibling
  # source has a different host. The breaker does not count it, because no
  # socket was opened: a refusal decided before the vet costs nothing to
  # repeat, and quarantining the tool would replace a legible `blocked` with
  # `:circuit_open` for every chain the tool serves.
  @answers ~w(
    unsupported unsupported_chain unsupported_account_ref unsupported_source
    invalid_cursor missing_argument invalid_argument no_backend blocked
  )

  @doc """
  Whether an error this surface returned is evidence against the TOOL.

  `Raxol.MCP.Registry` opens a per-tool circuit breaker on repeated
  `{:error, _}`, and without this predicate every error counted: five
  `web3_account_info` probes of unfunded wallets opened `web3_account_info`
  for the whole recovery window on every chain at once, because an account
  nobody has funded is `{:upstream_refused, :not_found}` and that is an
  `{:error, _}`.

  The line is the one `Raxol.Web3.Router.failover?/1` already draws and
  `Raxol.Web3.Backend`'s taxonomy documents: a reason about the SOURCE is a
  fault, a reason about the QUESTION is the answer the caller asked for. An
  answer is not evidence either way, so the registry records neither a
  failure nor a success for it.

  The argument is the SERIALIZED term, because that is what a callback here
  returns: `Raxol.Web3.Serialize.error/1` renders `{:upstream_refused,
  :not_found}` as `%{code: "upstream_refused", detail: :not_found}`, so the
  one class that splits on its detail is read that way.
  """
  @spec fault?(term()) :: boolean()
  def fault?(%{code: "upstream_refused", detail: detail}),
    do: detail not in [:not_found, :unknown]

  def fault?(%{code: code}), do: code not in @answers

  # Anything this surface did not shape. Unrecognised counts as a fault, which
  # is the safe direction: a breaker that opens too eagerly degrades a tool, a
  # breaker that never opens is not one.
  def fault?(_unrecognised), do: true

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
    with {:ok, number} <- fetch(arguments, "number"),
         {:ok, block} <- block_ref(number) do
      {:ok, [block]}
    end
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

  # The schema types `number` as an integer and a model sends a string
  # anyway, so the coercion is here, at the one boundary every chain crosses,
  # rather than four times behind it. Uncoerced, the chains disagreed:
  # `Raxol.Web3.Backend.Solana` and `Raxol.Web3.Backend.Aztec` parse a decimal
  # string, while `Raxol.Web3.Backend.JSONRPC` reads any non-hash binary as a
  # block TAG, so `"12345"` went to the node as a tag, came back -32602, and
  # `Raxol.Web3.RPC`'s classifier turned that into `{:upstream_refused,
  # :not_found}`: a final, non-failover "no such block" for a block the node
  # has.
  #
  # A tag and a `0x` value still pass through as strings. Both are things a
  # backend can answer -- a tag names a moving head, a `0x` value is a hash or
  # a quantity -- and narrowing them here would take away reads that work
  # today. What is refused is the remainder, which is exactly the set that
  # reached a backend and came back as a wrong answer.
  @block_tags ~w(latest earliest pending safe finalized)

  defp block_ref(number) when is_integer(number), do: {:ok, number}
  defp block_ref(tag) when tag in @block_tags, do: {:ok, tag}
  defp block_ref("0x" <> _rest = hex), do: {:ok, hex}

  defp block_ref(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> {:ok, number}
      _unparseable -> {:error, {:invalid_argument, "number"}}
    end
  end

  defp block_ref(_other), do: {:error, {:invalid_argument, "number"}}

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
