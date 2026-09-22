defmodule Raxol.Web3.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Registry
  alias Raxol.MCP.Server
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

  describe "the registered surface is read-only and authorization-gated" do
    test "no tool takes a method name, because raw_request has no tool at all" do
      # The contract's one passthrough callback is absent from the surface, so
      # there is no served path that can name an RPC method.
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

    test "every registered tool is sensitive as well as read-only" do
      # Reads still disclose query intent and can consume provider quota, so
      # the MCP server must refuse an unguarded deployment.
      for tool <- Tools.tool_defs(router()) do
        assert ToolDef.sensitive?(tool), "#{tool.name} is not authorization-gated"
        assert tool.annotations == %{readOnlyHint: true, sensitive: true}
      end
    end

    test "an MCP server refuses this surface without an authorizer" do
      registry = registry()
      assert :ok = Tools.register(registry, router())
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Server.start_link(
                 name: :"web3_unguarded_#{System.unique_integer([:positive])}",
                 registry: registry
               )

      assert message =~ "refuses to boot"
      assert message =~ "web3_"
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

    test "an answer about the question does not open the tool's breaker" do
      # `Raxol.MCP.Registry` opens a per-tool breaker after five `{:error, _}`
      # results, and five is one probe short of a working day's worth of empty
      # wallets. An unfunded account is `{:upstream_refused, :not_found}`,
      # which is the answer the caller asked for, and quarantining
      # `web3_account_info` for it took the tool out on every chain at once.
      registry = registry()
      router = router(answers: %{account_info: {:error, {:upstream_refused, :not_found}}})

      assert :ok = Tools.register(registry, router)

      for _probe <- 1..6 do
        assert {:error, %{code: "upstream_refused", detail: :not_found}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => @address
                 })
      end

      assert Registry.circuit_status(registry, {:tool, "web3_account_info"}).state == :closed
    end

    test "a fault of the source does open it, so the classification is a split and not a mute" do
      registry = registry()
      router = router(answers: %{account_info: {:error, {:timeout, :deadline}}})

      assert :ok = Tools.register(registry, router)

      for _attempt <- 1..5 do
        assert {:error, %{code: "timeout"}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => @address
                 })
      end

      assert {:error, :circuit_open} =
               Registry.call_tool(registry, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => @address
               })
    end

    test "a 404 an upstream never classified is an answer, not a fault" do
      # A backend that cannot classify a status hands it through as
      # `{:http, status}`, and Blockscout answers an unknown hash with a
      # plain 404: five lookups of hashes that do not exist, from one client,
      # took `web3_get_transaction` out for every client of the server.
      registry = registry()
      router = router(answers: %{get_transaction: {:error, {:http, 404}}})
      arguments = %{"chain" => @chain, "hash" => "0xdeadbeef"}

      assert :ok = Tools.register(registry, router)

      for _probe <- 1..6 do
        assert {:error, %{code: "http", detail: 404}} =
                 Registry.call_tool(registry, "web3_get_transaction", arguments)
      end

      assert Registry.circuit_status(registry, {:tool, "web3_get_transaction"}).state == :closed
    end

    test "a 5xx from the same upstream still is a fault" do
      # The other side of the split, so that classifying `{:http, _}` as an
      # answer wholesale fails here. The line is
      # `Raxol.Web3.HTTP.unhealthy_status?/1`, the one the origin breaker and
      # the router's failover already use.
      registry = registry()
      router = router(answers: %{get_transaction: {:error, {:http, 503}}})
      arguments = %{"chain" => @chain, "hash" => "0xdeadbeef"}

      assert :ok = Tools.register(registry, router)

      for _attempt <- 1..5 do
        assert {:error, %{code: "http", detail: 503}} =
                 Registry.call_tool(registry, "web3_get_transaction", arguments)
      end

      assert {:error, :circuit_open} =
               Registry.call_tool(registry, "web3_get_transaction", arguments)
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

    test "no tool raises on an absent argument, whatever interned its name" do
      # The lookup was `Map.get(arguments, name) ||
      # Map.get(arguments, String.to_existing_atom(name))`, so EVERY absent
      # argument evaluated `String.to_existing_atom/1`. No `:chain` literal
      # exists in `raxol_web3/lib`, so the test above passed only because
      # `%{chain: @chain}` below interned that atom while this file compiled;
      # in a release the tool raised `ArgumentError` instead of naming the
      # missing argument. The names now come from a compile-time table in the
      # module itself, and this covers every one of them.
      router = router()
      refused = {:error, %{code: "missing_argument", detail: "chain"}}

      assert Map.new(Tools.names(), &{&1, call(router, &1, %{})}) ==
               Map.new(Tools.names(), &{&1, refused})
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

    test "an argument of the wrong type is a closed error rather than a raise" do
      # Neither `Raxol.MCP.Server` nor `Raxol.MCP.Registry` enforces
      # `inputSchema`, so an argument's type is whatever the peer sent.
      # Unchecked, `{"account": 123}` reached `Serialize.account_ref/1`,
      # which is guarded `when is_binary(value)`: the `FunctionClauseError`
      # was rendered into the result a model reads AND counted against the
      # tool's breaker, so five wrong-typed calls disabled the tool for every
      # client.
      router = router()

      wrong = [
        {"web3_account_info", %{"chain" => @chain, "account" => 123}, "account"},
        {"web3_contract_metadata", %{"chain" => @chain, "account" => %{}}, "account"},
        {"web3_get_transaction", %{"chain" => @chain, "hash" => 42}, "hash"},
        {"web3_resolve_name", %{"chain" => @chain, "name" => ["vitalik.eth"]}, "name"},
        {"web3_read_contract", %{"chain" => @chain, "to" => "0xabc", "data" => %{}}, "data"},
        {"web3_read_contract",
         %{"chain" => @chain, "to" => "0xabc", "data" => "0x70a08231", "block" => 3.5}, "block"},
        {"web3_list_transactions", %{"chain" => @chain, "account" => @address, "cursor" => 7},
         "cursor"},
        {"web3_chain_info", %{"chain" => 1}, "chain"},
        {"web3_get_block", %{"chain" => @chain, "number" => 1.5}, "number"},
        {"web3_get_block", %{"chain" => @chain, "number" => %{"n" => 1}}, "number"}
      ]

      for {name, arguments, detail} <- wrong do
        assert {:error, %{code: "invalid_argument", detail: ^detail}} =
                 call(router, name, arguments),
               "#{name} did not refuse #{inspect(arguments)}"
      end
    end

    test "a wrong-typed argument is not evidence against the tool" do
      # The other half: a closed refusal that still counted as a fault would
      # let a model disable a working tool by sending the wrong JSON type
      # five times.
      registry = registry()
      assert :ok = Tools.register(registry, router())

      for _attempt <- 1..6 do
        assert {:error, %{code: "invalid_argument", detail: "account"}} =
                 Registry.call_tool(registry, "web3_account_info", %{
                   "chain" => @chain,
                   "account" => 123
                 })
      end

      assert {:ok, _account} =
               Registry.call_tool(registry, "web3_account_info", %{
                 "chain" => @chain,
                 "account" => @address
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
