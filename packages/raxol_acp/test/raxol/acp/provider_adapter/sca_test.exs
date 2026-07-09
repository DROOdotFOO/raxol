defmodule Raxol.ACP.ProviderAdapter.SCATest do
  @moduledoc """
  Stubbed coverage for `Raxol.ACP.ProviderAdapter.SCA`.

  A single method-keyed Plug stub serves the node RPC (getNonce /
  getCode / installed? / reads / receipt / logs) plus the wallet's
  paymaster + bundler legs, so the whole gasless UserOperation pipeline
  -- including two-op auto-provisioning -- runs without a real endpoint.
  The end-to-end path against the real EntryPoint is deferred to
  `Raxol.ACP.Wallet.SCA.BundlerHarnessTest` (`:live_bundler`).
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.ProviderAdapter.SCA
  alias Raxol.ACP.Wallet.SCA.ModularAccount

  @session_env "RAXOL_ACP_SCA_ADAPTER_KEY"
  # Anvil dev key #0; well-known, not a secret.
  @session_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @sca_account "0x9a96e767bfcce8e80370be00821ed5ba283d4a17"
  @acp_core "0x" <> String.duplicate("11", 20)
  @read_contract "0x" <> String.duplicate("22", 20)
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @op_hash "0x" <> String.duplicate("cd", 32)
  @chain_id 8453
  @rpc_url "http://stub.invalid/rpc"

  # Owner (entity 0) vs session (entity 1) nonce keys.
  @owner_key ModularAccount.nonce_key(0, true)
  @session_key ModularAccount.nonce_key(1, true)

  defmodule SessionKey do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_SCA_ADAPTER_KEY", chain_id: 8453
  end

  defmodule SCAWallet do
    use Raxol.ACP.Wallet.SCA,
      account_address: "0x9a96e767bfcce8e80370be00821ed5ba283d4a17",
      chain_id: 8453,
      signer: Raxol.ACP.ProviderAdapter.SCATest.SessionKey,
      signer_entity_id: 1,
      bundler_url: "http://stub.invalid/bundler",
      paymaster_policy_id: "186aaa4a-5f57-4156-83fb-e456365a8820"
  end

  @gm_result %{
    "paymaster" => "0xabababababababababababababababababababab",
    "paymasterData" => "0xcafe",
    "paymasterVerificationGasLimit" => "0x7530",
    "paymasterPostOpGasLimit" => "0x2710",
    "callGasLimit" => "0xc350",
    "verificationGasLimit" => "0x186a0",
    "preVerificationGas" => "0x5208",
    "maxFeePerGas" => "0x3b9aca00",
    "maxPriorityFeePerGas" => "0x3b9aca00"
  }

  @receipt %{
    "transactionHash" => @tx_hash,
    "status" => "0x1",
    "blockNumber" => "0x100",
    "logs" => []
  }

  @logs [
    %{
      "address" => @acp_core,
      "topics" => ["0x" <> String.duplicate("ee", 32)],
      "data" => "0x",
      "blockNumber" => "0x100"
    }
  ]

  setup do
    System.put_env(@session_env, @session_privkey)

    on_exit(fn ->
      System.delete_env(@session_env)
      Application.delete_env(:raxol_acp, :rpc)
    end)

    :ok
  end

  describe "new/1 + identity" do
    test "get_address returns the SCA address" do
      adapter = build_adapter()
      assert ProviderAdapter.get_address(adapter) == @sca_account
    end

    test "supported_chain_ids lists the configured chains" do
      adapter = build_adapter()
      assert ProviderAdapter.supported_chain_ids(adapter) == [@chain_id]
    end

    test "raises when the wallet is not an SCA module" do
      assert_raise ArgumentError, fn ->
        SCA.new(wallet: __MODULE__, chains: %{@chain_id => @rpc_url})
      end
    end

    test "raises when chains omit the wallet's chain_id" do
      assert_raise ArgumentError, fn ->
        SCA.new(wallet: SCAWallet, chains: %{999 => @rpc_url})
      end
    end
  end

  describe "send_calls/3 -- deployed + installed" do
    test "runs one write UserOp and returns the inner tx hash" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:ok, [@tx_hash]} = ProviderAdapter.send_calls(adapter, @chain_id, [acp_call()])

      calls = drain_rpc_calls()
      sends = for {"eth_sendUserOperation", [op, _ep]} <- calls, do: op

      # Exactly one UserOp -- no provisioning ops.
      assert length(sends) == 1
      [write_op] = sends

      # Its callData wraps the ACP call in execute(address,uint256,bytes),
      # the signature is the 0xff00 UO frame, and there's no factory (the
      # account is already deployed).
      assert execute_wrapped?(write_op["callData"])
      assert String.starts_with?(write_op["signature"], "0xff00")
      refute Map.has_key?(write_op, "factory")

      # The write op uses the session-entity nonce.
      assert nonce_key_of_userop(write_op) == @session_key
    end
  end

  describe "send_calls/3 -- auto-provisioning (not deployed, not installed)" do
    test "submits deploy + install + write in order, owner then session nonce" do
      adapter = build_adapter(deployed: false, installed: false)

      assert {:ok, [@tx_hash]} = ProviderAdapter.send_calls(adapter, @chain_id, [acp_call()])

      calls = drain_rpc_calls()
      sends = for {"eth_sendUserOperation", [op, _ep]} <- calls, do: op

      assert length(sends) == 3
      [deploy_op, install_op, write_op] = sends

      # op1: deploy -- factory initCode + empty callData, owner nonce.
      assert Map.has_key?(deploy_op, "factory")
      assert deploy_op["callData"] == "0x"
      assert nonce_key_of_userop(deploy_op) == @owner_key

      # op2: installValidation, used directly (NOT execute-wrapped), no
      # factory, owner nonce.
      refute Map.has_key?(install_op, "factory")
      assert install_op["callData"] == hex(SCAWallet.own_session_key_install_calldata())
      refute execute_wrapped?(install_op["callData"])
      assert nonce_key_of_userop(install_op) == @owner_key

      # op3: the actual write -- execute-wrapped, no factory, session nonce.
      assert execute_wrapped?(write_op["callData"])
      refute Map.has_key?(write_op, "factory")
      assert nonce_key_of_userop(write_op) == @session_key
    end

    test "auto_provision: false skips provisioning entirely" do
      adapter = build_adapter(deployed: false, installed: false, auto_provision: false)

      assert {:ok, [@tx_hash]} = ProviderAdapter.send_calls(adapter, @chain_id, [acp_call()])

      calls = drain_rpc_calls()
      sends = for {"eth_sendUserOperation", [op, _ep]} <- calls, do: op
      assert length(sends) == 1
    end
  end

  describe "send_calls/3 -- edge cases" do
    test "empty call list is a no-op" do
      adapter = build_adapter(deployed: true, installed: true)
      assert {:ok, []} = ProviderAdapter.send_calls(adapter, @chain_id, [])
    end

    test "a multi-call batch is unsupported" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:error, :batch_unsupported} =
               ProviderAdapter.send_calls(adapter, @chain_id, [acp_call(), acp_call()])
    end

    test "an unsupported chain id errors before any RPC" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:error, {:unsupported_chain, 999}} =
               ProviderAdapter.send_calls(adapter, 999, [acp_call()])

      assert [] == drain_rpc_calls()
    end

    test "a mined-but-reverted UserOp is not reported as a successful write" do
      # The op passed validation (so it's included and the nonce is burned) but
      # its inner execute() reverted: the receipt says success: false. Reporting
      # {:ok, tx_hash} would let the Provider mirror a status the chain never
      # reached; the adapter must surface the revert instead.
      adapter = build_adapter(deployed: true, installed: true, op_success: false)

      assert {:error, {:user_op_reverted, "AA23 reverted"}} =
               ProviderAdapter.send_calls(adapter, @chain_id, [acp_call()])
    end
  end

  describe "signing" do
    test "sign_message returns the EIP-1271 single-signer frame" do
      adapter = build_adapter()

      assert {:ok, packed} = ProviderAdapter.sign_message(adapter, @chain_id, "hello agent")
      # 0x00 || entityId(4) || 0xFF || 0x00 || sig
      assert <<0x00, entity::unsigned-big-32, 0xFF, 0x00, sig::binary>> = packed
      assert entity == SCAWallet.signer_entity_id()
      assert byte_size(sig) == 65
    end

    test "sign_typed_data wraps an EIP-712 hash in the 1271 frame" do
      adapter = build_adapter()

      typed = %{
        domain: %{name: "ACP Auth", version: "1", chainId: @chain_id},
        types: %{"Challenge" => [{"nonce", "uint256"}]},
        message: %{"nonce" => 7}
      }

      assert {:ok, packed} = ProviderAdapter.sign_typed_data(adapter, @chain_id, typed)
      assert <<0x00, 1::unsigned-big-32, 0xFF, 0x00, sig::binary>> = packed
      assert byte_size(sig) == 65
    end
  end

  describe "reads" do
    test "read_contract encodes the call and returns the eth_call result" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:ok, "0x" <> hex} =
               ProviderAdapter.read_contract(adapter, @chain_id, %{
                 address: @read_contract,
                 signature: "decimals()",
                 args: []
               })

      assert String.to_integer(hex, 16) == 6
    end

    test "get_transaction_receipt returns the stub receipt" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:ok, @receipt} =
               ProviderAdapter.get_transaction_receipt(adapter, @chain_id, @tx_hash)
    end

    test "get_logs returns the stub logs" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:ok, @logs} =
               ProviderAdapter.get_logs(adapter, @chain_id, %{
                 address: @acp_core,
                 from_block: "latest",
                 to_block: "latest"
               })
    end

    test "reads on an unsupported chain error" do
      adapter = build_adapter(deployed: true, installed: true)

      assert {:error, {:unsupported_chain, 999}} =
               ProviderAdapter.get_transaction_receipt(adapter, 999, @tx_hash)
    end
  end

  # -- Scaffolding --

  defp acp_call do
    %{
      to: @acp_core,
      data: Raxol.ACP.ABI.encode_call("claimBudget(uint256)", [{"uint256", 42}]),
      value: 0
    }
  end

  defp build_adapter(opts \\ []) do
    deployed = Keyword.get(opts, :deployed, true)
    installed = Keyword.get(opts, :installed, true)
    auto_provision = Keyword.get(opts, :auto_provision, true)
    op_success = Keyword.get(opts, :op_success, true)

    plug = install_stub(self(), deployed: deployed, installed: installed, op_success: op_success)

    SCA.new(
      wallet: SCAWallet,
      chains: %{@chain_id => @rpc_url},
      auto_provision: auto_provision,
      wallet_opts: [
        req: Req.new(plug: plug),
        bundler_url: "http://stub.invalid/bundler",
        paymaster_url: "http://stub.invalid/bundler"
      ]
    )
  end

  # One plug for node RPC + paymaster + bundler, keyed on method. The node
  # legs are picked up via the :raxol_acp :rpc app config; the bundler /
  # paymaster legs via wallet_opts[:req].
  defp install_stub(events, opts) do
    deployed = Keyword.fetch!(opts, :deployed)
    installed = Keyword.fetch!(opts, :installed)
    op_success = Keyword.fetch!(opts, :op_success)
    entry_point = SCAWallet.entry_point()
    single_signer = ModularAccount.single_signer_validation_address()
    owner = SessionKey.address()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      send(events, {:rpc_call, req["method"], req["params"]})

      result =
        case req["method"] do
          "eth_call" ->
            eth_call_result(req["params"], entry_point, single_signer, owner, installed)

          "eth_getCode" ->
            if deployed, do: "0x60806040", else: "0x"

          "alchemy_requestGasAndPaymasterAndData" ->
            @gm_result

          "eth_sendUserOperation" ->
            @op_hash

          "eth_getUserOperationReceipt" ->
            user_op_receipt(req["params"], op_success)

          "eth_getTransactionReceipt" ->
            @receipt

          "eth_getLogs" ->
            @logs

          _ ->
            nil
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
      )
    end

    Application.put_env(:raxol_acp, :rpc, url: @rpc_url, plug: plug)
    plug
  end

  # eth_call dispatches on `to`: getNonce (EntryPoint), installed? getter
  # (single-signer module), or an arbitrary read (returns decimals = 6).
  defp eth_call_result(
         [%{"to" => to, "data" => data} | _],
         entry_point,
         single_signer,
         owner,
         inst
       ) do
    cond do
      down(to) == down(entry_point) -> nonce_word(data)
      down(to) == down(single_signer) -> if(inst, do: signer_word(owner), else: zero_word())
      true -> word_hex(6)
    end
  end

  defp nonce_word("0x" <> hex) do
    raw = Base.decode16!(hex, case: :mixed)
    <<_selector::binary-size(4), _account::binary-size(32), key::unsigned-big-256>> = raw
    word_hex(key <<< 64)
  end

  defp user_op_receipt([op_hash | _], true) do
    %{"userOpHash" => op_hash, "success" => true, "logs" => [], "receipt" => @receipt}
  end

  defp user_op_receipt([op_hash | _], false) do
    # A UserOp included on-chain whose inner execute() reverted: success: false
    # with the EntryPoint revert reason.
    %{
      "userOpHash" => op_hash,
      "success" => false,
      "reason" => "AA23 reverted",
      "logs" => [],
      "receipt" => @receipt
    }
  end

  # -- Assertion helpers --

  defp nonce_key_of_userop(%{"nonce" => "0x" <> hex}) do
    {nonce, ""} = Integer.parse(hex, 16)
    nonce >>> 64
  end

  defp execute_wrapped?("0x" <> hex) do
    selector = binary_part(Base.decode16!(hex, case: :mixed), 0, 4)
    expected = binary_part(ExKeccak.hash_256("execute(address,uint256,bytes)"), 0, 4)
    selector == expected
  end

  defp drain_rpc_calls(acc \\ []) do
    receive do
      {:rpc_call, method, params} -> drain_rpc_calls([{method, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # -- Byte helpers --

  defp down(s), do: String.downcase(s)
  defp hex(bin), do: "0x" <> Base.encode16(bin, case: :lower)
  defp word_hex(n), do: "0x" <> (n |> Integer.to_string(16) |> String.pad_leading(64, "0"))
  defp zero_word, do: "0x" <> String.duplicate("0", 64)

  defp signer_word("0x" <> hex) do
    bytes = Base.decode16!(hex, case: :mixed)
    "0x" <> Base.encode16(<<0::96, bytes::binary-size(20)>>, case: :lower)
  end
end
