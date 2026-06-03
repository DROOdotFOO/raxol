defmodule Raxol.ACP.Wallet.SCA.BundlerHarnessTest do
  @moduledoc """
  Live ERC-4337 harness for the SCA wallet against the REAL deployed
  contracts on a Base mainnet fork.

  Opt-in (`mix test --include live_bundler`); needs foundry (`anvil`,
  `cast`) and network access to a Base RPC to fork from
  (`RAXOL_ACP_FORK_URL`, default `https://mainnet.base.org`).

  Anvil forks Base, so the canonical EntryPoint v0.7, the Modular
  Account v2 factory, and the single-signer validation module all
  exist on-chain. The test:

    1. predicts the SMA address and asserts it matches what the real
       factory's `createSemiModularAccount` returns,
    2. builds + signs a UserOperation with our own code (initCode that
       self-deploys the SMA, owner-signed via `sign_user_op_hash`),
    3. submits it through the real `EntryPoint.handleOps` -- here
       `cast` plays the bundler role, since Anvil itself doesn't bundle,
    4. asserts the EntryPoint deployed the account and the
       `UserOperationEvent` reports success.

  This validates the full stack -- counterfactual address, initCode,
  UserOp packing, EIP-191 + Modular Account v2 signature wrapping --
  against the actual on-chain validator, not a stub.
  """
  use ExUnit.Case, async: false

  @moduletag :live_bundler

  alias Raxol.ACP.Wallet.SCA.{ModularAccount, Provisioning, UserOp}

  @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @owner "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @beneficiary "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
  @env_var "RAXOL_ACP_HARNESS_KEY"
  # keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
  @user_op_event_topic "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"

  defmodule SessionKey do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_HARNESS_KEY", chain_id: 8453
  end

  defmodule Account do
    # Owner is the SMA's native (entity 0) signer, which is what a
    # freshly-deployed SMA validates against.
    use Raxol.ACP.Wallet.SCA,
      account_address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      chain_id: 8453,
      signer: Raxol.ACP.Wallet.SCA.BundlerHarnessTest.SessionKey,
      signer_entity_id: 0,
      bundler_url: "http://stub.invalid"
  end

  # Session key for the entity-1 path. Anvil pre-funded key #1.
  @session_anvil_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @session_addr "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @session_env_var "RAXOL_ACP_SESSION_KEY"

  defmodule SessionSigner do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_SESSION_KEY",
      chain_id: 8453
  end

  setup_all do
    ensure_foundry!()
    System.put_env(@env_var, @anvil_key)
    System.put_env(@session_env_var, @session_anvil_key)

    fork_url = System.get_env("RAXOL_ACP_FORK_URL", "https://mainnet.base.org")
    port = 8599
    rpc = "http://127.0.0.1:#{port}"
    os_pid = start_anvil_fork(fork_url, port)
    on_exit(fn -> System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true) end)

    wait_until_forked(rpc)
    %{rpc: rpc}
  end

  test "deploys + executes a UserOp through the real EntryPoint", %{rpc: rpc} do
    sca = Provisioning.predict_address(@owner, 0)

    # 1. Our prediction must match the real factory's computation.
    {factory_addr, 0} =
      cast([
        "call",
        factory(),
        "createSemiModularAccount(address,uint256)(address)",
        @owner,
        "0",
        "--rpc-url",
        rpc
      ])

    assert String.downcase(String.trim(factory_addr)) == sca

    # 2. The account isn't deployed yet on the fork.
    refute deployed?(rpc, sca)

    # 3. Fund the SCA so it can prefund the EntryPoint (no paymaster here).
    cast(["rpc", "anvil_setBalance", sca, "0xDE0B6B3A7640000", "--rpc-url", rpc])

    # 4. Build + sign the UserOp: deploy via initCode, execute a harmless
    #    call to the owner EOA.
    {nonce_hex, 0} =
      cast([
        "call",
        @entry_point,
        "getNonce(address,uint192)(uint256)",
        sca,
        "#{ModularAccount.nonce_key(0, true)}",
        "--rpc-url",
        rpc
      ])

    # cast prints numbers as "<dec> [<sci>]"; take the decimal token.
    nonce = nonce_hex |> String.split() |> hd() |> String.to_integer()

    op = %UserOp{
      sender: sca,
      nonce: nonce,
      init_code: Provisioning.deploy_init_code(@owner, 0),
      call_data: ModularAccount.execute_calldata(@owner, 0, <<>>),
      call_gas_limit: 300_000,
      verification_gas_limit: 1_500_000,
      pre_verification_gas: 200_000,
      max_fee_per_gas: 2_000_000_000,
      max_priority_fee_per_gas: 1_000_000_000
    }

    uo_hash = UserOp.hash(op, @entry_point, 8453)
    {:ok, signature} = Account.sign_user_op_hash(uo_hash)
    op = UserOp.put_signature(op, signature)

    # 5. Submit through the real EntryPoint -- cast is the bundler.
    {out, 0} = submit_handle_ops(rpc, op)
    assert out =~ ~r/status\s+1/

    # 6. The account is now deployed and the UserOp event reports success.
    assert deployed?(rpc, sca)
    assert out =~ @user_op_event_topic
  end

  test "session-key (entity 1) UserOp after owner deploy + installValidation", %{rpc: rpc} do
    sca = Provisioning.predict_address(@owner, 1)

    refute deployed?(rpc, sca)
    cast(["rpc", "anvil_setBalance", sca, "0xDE0B6B3A7640000", "--rpc-url", rpc])

    # 1. Owner deploys + registers session key in a single UserOp.
    install_data =
      Raxol.ACP.Wallet.SCA.Provisioning.install_session_key_calldata(@session_addr, 1)

    {nonce_hex, 0} =
      cast([
        "call",
        @entry_point,
        "getNonce(address,uint192)(uint256)",
        sca,
        "#{ModularAccount.nonce_key(0, true)}",
        "--rpc-url",
        rpc
      ])

    nonce0 = nonce_hex |> String.split() |> hd() |> String.to_integer()

    deploy_op = %UserOp{
      sender: sca,
      nonce: nonce0,
      init_code: Provisioning.deploy_init_code(@owner, 1),
      call_data: ModularAccount.execute_calldata(sca, 0, install_data),
      call_gas_limit: 800_000,
      verification_gas_limit: 1_500_000,
      pre_verification_gas: 200_000,
      max_fee_per_gas: 2_000_000_000,
      max_priority_fee_per_gas: 1_000_000_000
    }

    deploy_hash = UserOp.hash(deploy_op, @entry_point, 8453)
    {:ok, owner_sig} = Account.sign_user_op_hash(deploy_hash)
    deploy_op = UserOp.put_signature(deploy_op, owner_sig)

    {out, 0} = submit_handle_ops(rpc, deploy_op)
    assert out =~ ~r/status\s+1/
    assert out =~ @user_op_event_topic
    assert deployed?(rpc, sca)

    # 2. Session-key signed UserOp -- entity 1 -- targets a harmless call.
    {nonce1_hex, 0} =
      cast([
        "call",
        @entry_point,
        "getNonce(address,uint192)(uint256)",
        sca,
        "#{ModularAccount.nonce_key(1, true)}",
        "--rpc-url",
        rpc
      ])

    nonce1 = nonce1_hex |> String.split() |> hd() |> String.to_integer()

    session_op = %UserOp{
      sender: sca,
      nonce: nonce1,
      init_code: <<>>,
      call_data: ModularAccount.execute_calldata(@owner, 0, <<>>),
      call_gas_limit: 300_000,
      verification_gas_limit: 800_000,
      pre_verification_gas: 200_000,
      max_fee_per_gas: 2_000_000_000,
      max_priority_fee_per_gas: 1_000_000_000
    }

    session_hash = UserOp.hash(session_op, @entry_point, 8453)
    {:ok, session_sig} = Raxol.ACP.Wallet.SCA.sign_user_op_hash(session_hash, SessionSigner)
    session_op = UserOp.put_signature(session_op, session_sig)

    {out2, 0} = submit_handle_ops(rpc, session_op)
    assert out2 =~ ~r/status\s+1/
    assert out2 =~ @user_op_event_topic
  end

  # -- Harness plumbing --

  defp factory, do: ModularAccount.factory_address()

  defp ensure_foundry! do
    unless System.find_executable("anvil") && System.find_executable("cast") do
      flunk("live_bundler tests require foundry (anvil + cast) on PATH")
    end
  end

  defp start_anvil_fork(fork_url, port) do
    anvil = System.find_executable("anvil")

    port_ref =
      Port.open({:spawn_executable, anvil}, [
        :binary,
        :exit_status,
        args: ["--fork-url", fork_url, "--port", "#{port}", "--silent"]
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    os_pid
  end

  defp wait_until_forked(rpc, attempts \\ 100)
  defp wait_until_forked(_rpc, 0), do: flunk("anvil fork did not become ready")

  defp wait_until_forked(rpc, attempts) do
    case cast(["chain-id", "--rpc-url", rpc]) do
      {out, 0} ->
        if String.trim(out) == "8453", do: :ok, else: retry_fork(rpc, attempts)

      _ ->
        retry_fork(rpc, attempts)
    end
  end

  defp retry_fork(rpc, attempts) do
    Process.sleep(150)
    wait_until_forked(rpc, attempts - 1)
  end

  defp deployed?(rpc, address) do
    {code, 0} = cast(["code", address, "--rpc-url", rpc])
    String.trim(code) not in ["0x", ""]
  end

  # cast plays the bundler: submit the packed UserOp via EntryPoint.handleOps.
  defp submit_handle_ops(rpc, %UserOp{} = op) do
    packed = UserOp.pack(op)
    hex = fn b -> "0x" <> Base.encode16(b, case: :lower) end

    tuple =
      "(#{op.sender},#{op.nonce},#{hex.(packed.init_code)},#{hex.(packed.call_data)}," <>
        "#{hex.(packed.account_gas_limits)},#{packed.pre_verification_gas}," <>
        "#{hex.(packed.gas_fees)},#{hex.(packed.paymaster_and_data)},#{hex.(packed.signature)})"

    cast([
      "send",
      @entry_point,
      "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)",
      "[#{tuple}]",
      @beneficiary,
      "--private-key",
      @anvil_key,
      "--rpc-url",
      rpc
    ])
  end

  defp cast(args), do: System.cmd("cast", args, stderr_to_stdout: true)
end
