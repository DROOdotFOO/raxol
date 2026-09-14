defmodule Raxol.Web3.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Registry
  alias Raxol.MCP.ToolDef
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Router

  @chain "eip155:1"
  @address "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  defp router(opts \\ []) do
    {:ok, handle} = Stub.new(@chain, opts)
    Router.new([handle])
  end

  defp tool(router, name) do
    Enum.find(Tools.tool_defs(router), &(&1.name == name))
  end

  defp call(router, name, arguments) do
    tool(router, name).callback.(arguments)
  end

  defp registry do
    name = :"web3_tools_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name, table_name: name})
    name
  end

  describe "the registered surface is read-only by construction" do
    test "no tool takes a method name, because raw_request has no tool at all" do
      # The contract's one passthrough callback is absent from the surface, so
      # there is no served path that can name an RPC method. This is stronger
      # than annotating the tools, which enforces nothing on its own.
      refute :raw_request in Tools.callbacks()
      refute Enum.any?(Tools.names(), &String.contains?(&1, "raw"))

      assert Enum.all?(Tools.tool_defs(router()), fn tool ->
               not String.contains?(Jason.encode!(tool.inputSchema), "method")
             end)
    end

    test "every registered tool is one this package declared" do
      # ADR-0033 section 4's check, and the one the MCP server does not perform:
      # enumerate the registry after registration and fail on anything else.
      registry = registry()

      assert :ok = Tools.register(registry, router())

      registered = registry |> Registry.list_tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert registered == Enum.sort(Tools.names())
    end

    test "no registered tool is sensitive, which is what lets the server run unauthorized" do
      # `refuse_unguarded_sensitive_tools!/2` raises at boot when a sensitive
      # tool is registered with no authorizer. Every tool here is a read, so
      # that boot check passes, and this test is what keeps it true.
      for tool <- Tools.tool_defs(router()) do
        refute ToolDef.sensitive?(tool), "#{tool.name} is annotated sensitive"
      end
    end

    test "every tool declares itself read-only to a host" do
      for tool <- Tools.tool_defs(router()) do
        assert tool.annotations == %{readOnlyHint: true}
      end
    end

    test "every tool passes the registry's own shape validation" do
      for tool <- Tools.tool_defs(router()) do
        assert :ok = ToolDef.validate(tool), "#{tool.name} is not a valid tool_def"
      end
    end

    test "the tool list and the callback list are the same length, in the same order" do
      # Both are derived from one table, and this is what catches a hand-edit
      # that adds a name without a callback or the reverse.
      assert length(Tools.names()) == length(Tools.callbacks())
      assert length(Tools.names()) == 13
    end
  end

  describe "arguments" do
    test "a chain is required on every tool" do
      for tool <- Tools.tool_defs(router()) do
        assert "chain" in tool.inputSchema["required"]
        assert tool.inputSchema["properties"]["chain"]["type"] == "string"
      end
    end

    test "a missing required argument is refused without reaching a backend" do
      router = router(answers: %{chain_info: {:error, :should_not_be_called}})

      assert {:error, %{code: "missing_argument", detail: "chain"}} =
               call(router, "web3_chain_info", %{})

      assert {:error, %{code: "missing_argument", detail: "hash"}} =
               call(router, "web3_get_transaction", %{"chain" => @chain})
    end

    test "atom keys and string keys both work" do
      # JSON arrives with string keys; a local Elixir caller writes atoms.
      # Guessing wrong reports a supplied argument as missing.
      router = router()

      assert {:ok, _} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert {:ok, _} = call(router, "web3_chain_info", %{chain: @chain})
    end

    test "a bare address becomes an EVM account reference" do
      router = router()

      assert {:ok, account} =
               call(router, "web3_account_info", %{"chain" => @chain, "account" => @address})

      assert account.ref == "evm:#{@address}"
    end

    test "an explicitly tagged reference keeps its tag" do
      # The tag is what distinguishes a Tron account from an EVM one and a
      # Canton party from either. A surface that flattened it would have to
      # guess on the way back in.
      router = router()

      assert {:ok, account} =
               call(router, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => "party:Alice::1220abcd"
               })

      assert account.ref == "party:Alice::1220abcd"
    end

    test "an optional cursor is passed through and an absent one is not invented" do
      router = router(answers: %{list_transactions: {:ok, %{items: [], next: "opaque"}}})

      assert {:ok, %{next: "opaque"}} =
               call(router, "web3_list_transactions", %{"chain" => @chain, "account" => @address})

      assert {:ok, %{next: "opaque"}} =
               call(router, "web3_list_transactions", %{
                 "chain" => @chain,
                 "account" => @address,
                 "cursor" => "somecursor"
               })
    end
  end

  describe "results are JSON, not Elixir terms" do
    test "a whole page encodes, tagged references and timestamps included" do
      # The defect ADR-0033 section 4 rejects AgentBridge for: a result
      # rendered with inspect/2 is Elixir term syntax that a client decoding
      # JSON receives as a string, if at all.
      router = router()

      assert {:ok, page} =
               call(router, "web3_list_transactions", %{"chain" => @chain, "account" => @address})

      assert {:ok, json} = Jason.encode(page)
      assert {:ok, decoded} = Jason.decode(json)

      assert [item] = decoded["items"]
      assert item["from"] == "evm:#{@address}"
      assert item["status"] == "success"
      assert item["timestamp"] =~ "2026-"
    end

    test "every tool's result encodes as JSON" do
      router = router()

      for {name, arguments} <- every_call() do
        assert {:ok, result} = call(router, name, arguments), "#{name} did not answer"
        assert {:ok, _json} = Jason.encode(result), "#{name} returned a term JSON cannot encode"
      end
    end
  end

  describe "errors" do
    test "an error is a code and its own datum, with no message field" do
      # The taxonomy has no text to put in one, which is the property ADR-0038
      # decision 6 spends its rules on. This surface is where a leak would be
      # worst: a tool result is text a model reads and may act on.
      router = router(answers: %{chain_info: {:error, {:rate_limited, 500}}})

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert error == %{code: "rate_limited", detail: 500}
      refute Map.has_key?(error, :message)
    end

    test "an unrouted chain says so rather than failing opaquely" do
      assert {:error, %{code: "no_backend"}} =
               call(router(), "web3_chain_info", %{"chain" => "eip155:999999"})
    end

    test "a callback no backend answers is reported as unsupported" do
      router = router(capabilities: [])

      assert {:error, %{code: "unsupported", detail: :get_logs}} =
               call(router, "web3_get_logs", %{"chain" => @chain, "account" => @address})
    end

    test "an unrecognised error term becomes a bare code rather than being inspected" do
      router = router(answers: %{chain_info: {:error, {:weird, %{body: "upstream text"}}}})

      assert {:error, error} = call(router, "web3_chain_info", %{"chain" => @chain})
      assert error == %{code: "error", detail: nil}
      refute inspect(error) =~ "upstream text"
    end
  end

  defp every_call do
    [
      {"web3_chain_info", %{"chain" => @chain}},
      {"web3_block_height", %{"chain" => @chain}},
      {"web3_get_transaction", %{"chain" => @chain, "hash" => "0xabc"}},
      {"web3_account_info", %{"chain" => @chain, "account" => @address}},
      {"web3_list_transactions", %{"chain" => @chain, "account" => @address}},
      {"web3_token_balances", %{"chain" => @chain, "account" => @address}},
      {"web3_list_token_transfers", %{"chain" => @chain, "account" => @address}},
      {"web3_get_logs", %{"chain" => @chain, "account" => @address}},
      {"web3_list_nfts", %{"chain" => @chain, "account" => @address}},
      {"web3_contract_metadata", %{"chain" => @chain, "account" => @address}},
      {"web3_get_block", %{"chain" => @chain, "number" => 1_000_000}},
      {"web3_resolve_name", %{"chain" => @chain, "name" => "vitalik.eth"}},
      {"web3_read_contract", %{"chain" => @chain, "to" => "0xabc", "data" => "0x70a08231"}}
    ]
  end
end
