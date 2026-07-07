defmodule Raxol.ACP.Wallet.SCA.ProvisionerTest do
  @moduledoc """
  Stubbed coverage for the two-UserOp provisioning driver.

  A single method-keyed Plug stub serves the node RPC (eth_getCode /
  eth_call getNonce / eth_call installed?) and the wallet's paymaster +
  bundler legs, so the whole deploy + installValidation flow runs without
  a real endpoint or a live bundler. The end-to-end path against the real
  EntryPoint is deferred to `bundler_harness_test.exs` (`:live_bundler`).
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Raxol.ACP.Onchain.RPC
  alias Raxol.ACP.Wallet.SCA.{ModularAccount, Provisioner}

  @session_env "RAXOL_ACP_PROVISIONER_KEY"
  # Anvil dev key #0; well-known, not a secret.
  @session_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @tx_hash "0x" <> String.duplicate("ab", 32)
  @op_hash "0x" <> String.duplicate("cd", 32)

  # Owner (entity 0) nonce key; provisioning ops are always owner-signed.
  @owner_key ModularAccount.nonce_key(0, true)

  defmodule SessionKey do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_PROVISIONER_KEY", chain_id: 8453
  end

  defmodule SCAWallet do
    use Raxol.ACP.Wallet.SCA,
      account_address: "0x9a96e767bfcce8e80370be00821ed5ba283d4a17",
      chain_id: 8453,
      signer: Raxol.ACP.Wallet.SCA.ProvisionerTest.SessionKey,
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

  setup do
    System.put_env(@session_env, @session_privkey)

    on_exit(fn ->
      System.delete_env(@session_env)
      Application.delete_env(:raxol_acp, :rpc)
    end)

    :ok
  end

  describe "provision/3 (deploy + install)" do
    test "deploys then installs, re-querying the owner nonce between the two ops" do
      wallet_opts = install_stub(self(), deployed: false, installed: false)
      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, %{deploy: :ok, install: :ok}} =
               Provisioner.provision(SCAWallet, client, wallet_opts)

      calls = drain_rpc_calls()

      # Exactly two UserOps were submitted: deploy then install.
      sends = for {"eth_sendUserOperation", [op, _ep]} <- calls, do: op
      assert length(sends) == 2
      [deploy_op, install_op] = sends

      # op1: factory initCode + empty callData (deploy-only).
      assert Map.has_key?(deploy_op, "factory")
      assert deploy_op["callData"] == "0x"

      # op2: installValidation callData, used directly (NOT execute-wrapped),
      # and no factory (account already deployed by op1).
      refute Map.has_key?(install_op, "factory")
      assert install_op["callData"] == hex(SCAWallet.own_session_key_install_calldata())
      refute execute_wrapped?(install_op["callData"])

      # The owner nonce was queried twice -- once per op -- never locally
      # incremented. Both getNonce calls carry the owner (entity 0) key.
      owner_nonce_calls = getnonce_calls(calls, @owner_key)
      assert length(owner_nonce_calls) == 2
    end

    test "the install op re-reads getNonce rather than reusing op1's value" do
      wallet_opts = install_stub(self(), deployed: false, installed: false)
      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, _} = Provisioner.provision(SCAWallet, client, wallet_opts)

      calls = drain_rpc_calls()
      # Two separate EntryPoint getNonce reads with the owner key means the
      # install op did not reuse a locally-incremented nonce.
      assert length(getnonce_calls(calls, @owner_key)) == 2
    end
  end

  describe "provision/3 idempotency" do
    test "deployed + installed -> both skipped, zero UserOps sent" do
      wallet_opts = install_stub(self(), deployed: true, installed: true)
      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, %{deploy: :skipped, install: :skipped}} =
               Provisioner.provision(SCAWallet, client, wallet_opts)

      calls = drain_rpc_calls()
      assert [] == for({"eth_sendUserOperation", _} <- calls, do: :sent)
    end

    test "deployed but not installed -> deploy skipped, install runs" do
      wallet_opts = install_stub(self(), deployed: true, installed: false)
      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, %{deploy: :skipped, install: :ok}} =
               Provisioner.provision(SCAWallet, client, wallet_opts)

      calls = drain_rpc_calls()
      sends = for {"eth_sendUserOperation", [op, _ep]} <- calls, do: op
      assert length(sends) == 1
      [install_op] = sends
      assert install_op["callData"] == hex(SCAWallet.own_session_key_install_calldata())
    end
  end

  describe "provision/3 options" do
    test ":assume_installed skips the install op without reading the module" do
      wallet_opts =
        install_stub(self(), deployed: true, installed: false) ++ [assume_installed: true]

      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, %{deploy: :skipped, install: :skipped}} =
               Provisioner.provision(SCAWallet, client, wallet_opts)

      calls = drain_rpc_calls()
      assert [] == for({"eth_sendUserOperation", _} <- calls, do: :sent)
    end

    test "ensure_provisioned/3 delegates to provision/3" do
      wallet_opts = install_stub(self(), deployed: true, installed: true)
      client = RPC.client(url: "http://stub.invalid/rpc")

      assert {:ok, %{deploy: :skipped, install: :skipped}} =
               Provisioner.ensure_provisioned(SCAWallet, client, wallet_opts)
    end
  end

  # -- Stub scaffolding --

  # One plug for the node RPC (getCode/getNonce/installed?) + paymaster +
  # bundler, keyed on method. Returns the wallet_opts the caller threads
  # into Provisioner (carrying the same plug as a Req for the bundler /
  # paymaster legs).
  defp install_stub(events, opts) do
    deployed = Keyword.fetch!(opts, :deployed)
    installed = Keyword.fetch!(opts, :installed)
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
            user_op_receipt(req["params"])

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

    Application.put_env(:raxol_acp, :rpc, url: "http://stub.invalid/rpc", plug: plug)

    [
      req: Req.new(plug: plug),
      bundler_url: "http://stub.invalid/bundler",
      paymaster_url: "http://stub.invalid/bundler"
    ]
  end

  # eth_call dispatches on `to`: EntryPoint.getNonce, the single-signer
  # installed? getter, or an arbitrary read.
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
      true -> zero_word()
    end
  end

  # EntryPoint.getNonce returns (key << 64) | sequence; sequence 0 here.
  # Encodes which validating entity was queried into the returned nonce.
  defp nonce_word("0x" <> hex) do
    raw = Base.decode16!(hex, case: :mixed)
    <<_selector::binary-size(4), _account::binary-size(32), key::unsigned-big-256>> = raw
    word_hex(key <<< 64)
  end

  defp user_op_receipt([op_hash | _]) do
    %{
      "userOpHash" => op_hash,
      "success" => true,
      "logs" => [],
      "receipt" => %{
        "transactionHash" => @tx_hash,
        "status" => "0x1",
        "blockNumber" => "0x100",
        "logs" => []
      }
    }
  end

  # -- Assertion helpers --

  # getNonce calls to the EntryPoint whose uint192 key equals `key`.
  defp getnonce_calls(calls, key) do
    for {"eth_call", [%{"to" => to, "data" => data} | _]} <- calls,
        down(to) == down(SCAWallet.entry_point()),
        nonce_key_of(data) == key,
        do: data
  end

  defp nonce_key_of("0x" <> hex) do
    raw = Base.decode16!(hex, case: :mixed)
    <<_selector::binary-size(4), _account::binary-size(32), key::unsigned-big-256>> = raw
    key
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
