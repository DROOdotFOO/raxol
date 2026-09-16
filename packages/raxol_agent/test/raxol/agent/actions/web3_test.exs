defmodule Raxol.Agent.Actions.Web3Test do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Actions.Web3
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.Router

  @chain "eip155:1"
  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  # `Raxol.Web3.Backend.Stub` is the reference backend that ships in
  # `raxol_web3`'s `lib/`, which is what lets this suite exercise the tool with
  # no network and no fixtures of its own.
  defp context(opts \\ []) do
    {:ok, handle} = Stub.new(@chain, opts)
    %{web3_router: Router.new([handle])}
  end

  describe "configuration and gating" do
    test "an unconfigured session says so rather than guessing at an upstream" do
      assert {:error, :web3_not_configured} =
               Web3.call(%{operation: "chain_info", chain: @chain}, %{})
    end

    test "a jailed session with no network grant is refused before any read" do
      # This tool spends the operator's rate-limit budget against a third party
      # from the operator's address, which is what the coarse jail gate is for.
      jailed = Map.merge(context(), %{jail: true, network: false})

      assert {:error, :network_disabled} =
               Web3.call(%{operation: "chain_info", chain: @chain}, jailed)
    end

    test "it is sensitive, for the reason fetch is" do
      # A read is not free of consequence: it discloses to a third party what
      # the session is working on, and "which address is this user
      # researching" is exactly that.
      assert Web3.__action_meta__().sensitive == true
    end
  end

  describe "operations" do
    test "the enum and the dispatch table are the same set" do
      # Both are written out, in one module, and this is what catches an
      # operation added to one and not the other.
      enum = Web3.__action_meta__().input_schema[:operation][:enum]

      assert Enum.sort(enum) == Enum.sort(Web3.operations())
      assert length(enum) == 13
    end

    test "no operation names an RPC method, so this is a router tool and not a passthrough" do
      refute "raw_request" in Web3.operations()

      schema = Web3.__action_meta__().input_schema
      refute Keyword.has_key?(schema, :method)
    end

    test "an unknown operation is refused by the schema before it reaches dispatch" do
      assert {:error, _reason} =
               Web3.call(%{operation: "send_transaction", chain: @chain}, context())
    end
  end

  describe "reads" do
    test "a successful read names the operation and the chain it answered for" do
      assert {:ok, result} = Web3.call(%{operation: "chain_info", chain: @chain}, context())

      assert result.operation == "chain_info"
      assert result.chain == @chain
      assert result.result.total_blocks == 1_000_000
    end

    test "an account reference is parsed, and a tagged one keeps its tag" do
      assert {:ok, %{result: %{ref: "evm:" <> _}}} =
               Web3.call(
                 %{operation: "account_info", chain: @chain, account: @address},
                 context()
               )

      assert {:ok, %{result: %{ref: "party:Alice::1220abcd"}}} =
               Web3.call(
                 %{operation: "account_info", chain: @chain, account: "party:Alice::1220abcd"},
                 context()
               )
    end

    test "a page's items are JSON-safe, timestamps and references included" do
      assert {:ok, %{result: page}} =
               Web3.call(
                 %{operation: "list_transactions", chain: @chain, account: @address},
                 context()
               )

      assert [item] = page.items
      assert item.from == "evm:#{@address}"
      assert item.status == :success
      assert is_binary(item.timestamp)
      assert {:ok, _json} = Jason.encode(page)
    end

    test "a scalar answer is wrapped, so the declared output shape holds for every operation" do
      assert {:ok, %{result: %{value: "0x" <> _}}} =
               Web3.call(
                 %{operation: "read_contract", chain: @chain, to: "0xabc", data: "0x70a08231"},
                 context()
               )

      assert {:ok, %{result: %{account: "evm:" <> _}}} =
               Web3.call(
                 %{operation: "resolve_name", chain: @chain, name: "vitalik.eth"},
                 context()
               )
    end
  end

  describe "errors" do
    test "a missing operation argument names the argument" do
      assert {:error, {:missing_argument, "hash"}} =
               Web3.call(%{operation: "get_transaction", chain: @chain}, context())
    end

    test "a router error travels as its own term, carrying no upstream text" do
      # An Action error becomes a `[Tool error for ...]` message, so the term
      # is what the model sees. The MCP surface renders the same taxonomy into
      # JSON instead, because there a result is data rather than prose.
      ctx = context(answers: %{chain_info: {:error, {:rate_limited, 500}}})

      assert {:error, {:rate_limited, 500}} =
               Web3.call(%{operation: "chain_info", chain: @chain}, ctx)
    end

    test "an unroutable chain is reported rather than attempted" do
      assert {:error, :no_backend} =
               Web3.call(%{operation: "chain_info", chain: "eip155:999999"}, context())
    end

    test "a callback no backend answers is unsupported, not a crash" do
      ctx = context(capabilities: [])

      assert {:error, {:unsupported, :get_logs}} =
               Web3.call(%{operation: "get_logs", chain: @chain, account: @address}, ctx)
    end
  end
end
