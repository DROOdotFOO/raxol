defmodule Raxol.ACP.ContractClient.OnchainLiveTest do
  @moduledoc """
  Live end-to-end test of the EOA on-chain pipeline against a real
  Anvil node.

  Opt-in (`mix test --include live_chain`); needs foundry's `anvil` and
  `cast` on PATH. Spins up a fresh Anvil, deploys a stub contract that
  accepts every ACP selector and returns a 32-byte word, then drives
  `create_job` / `set_budget` / `create_memo` through the *real*
  `Onchain` pipeline -- chain-side nonce, EIP-1559 fee history, gas
  estimate, secp256k1 signing, `eth_sendRawTransaction`, and receipt
  polling. No stubs: this is the actual JSON-RPC path against an EVM.

  The bundler/SCA (ERC-4337) path is NOT covered here -- it needs a
  running bundler, which Anvil does not provide.
  """
  use ExUnit.Case, async: false

  @moduletag :live_chain

  alias Raxol.ACP.ContractClient.Onchain
  alias Raxol.ACP.Wallet.NonceServer

  # Anvil dev account #0 (well-known, deterministic).
  @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @anvil_chain_id 31_337
  @env_var "RAXOL_ACP_LIVE_KEY"
  @provider "0x" <> String.duplicate("22", 20)
  @evaluator "0x" <> String.duplicate("33", 20)

  # Stub runtime returns the 32-byte word 0x..01 for any call; init code
  # deploys that runtime. Satisfies both uint256-returning methods
  # (createJob/createMemo) and void ones.
  @stub_init_code "0x69600160005260206000f3600052600a6016f3"

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_LIVE_KEY",
      chain_id: 31_337
  end

  setup_all do
    ensure_foundry!()

    port = 8545 + :erlang.phash2(self(), 1000)
    url = "http://127.0.0.1:#{port}"
    {anvil_os_pid, _port_ref} = start_anvil(port)
    on_exit(fn -> kill(anvil_os_pid) end)

    wait_until_ready(url)
    stub = deploy_stub(url)

    %{url: url, stub: stub}
  end

  setup %{url: url, stub: stub} do
    System.put_env(@env_var, @anvil_key)

    Application.put_env(:raxol_acp, :chain, :sepolia)

    Application.put_env(:raxol_acp, :chain_overrides, %{
      sepolia: %{chain_id: @anvil_chain_id, rpc_url: url, acp_contract_address: stub}
    })

    Application.put_env(:raxol_acp, :onchain_wallet, Wallet)
    Application.delete_env(:raxol_acp, :rpc)
    Application.delete_env(:raxol_acp, :sca_rpc)
    # The minimal stub contract returns a word for every call but emits no
    # JobCreated event, so create_job cannot resolve a real job id. This harness
    # validates the EOA signing/broadcast/receipt pipeline, not event decoding
    # (that is covered against real JobCreated logs elsewhere), so opt into the
    # documented tx-hash placeholder rather than failing closed.
    Application.put_env(:raxol_acp, :allow_placeholder_job_id, true)
    # Unseed so the pipeline reconciles the wallet's real nonce from the fork
    # (the stub deploy bumped anvil account #0), exercising the seed-from-chain
    # path rather than assuming 0.
    NonceServer.resync()

    on_exit(fn ->
      System.delete_env(@env_var)
      Application.delete_env(:raxol_acp, :chain)
      Application.delete_env(:raxol_acp, :chain_overrides)
      Application.delete_env(:raxol_acp, :onchain_wallet)
      Application.delete_env(:raxol_acp, :allow_placeholder_job_id)
    end)

    :ok
  end

  test "create_job runs the full EOA pipeline and returns a real tx hash" do
    assert {:ok, "0x" <> rest = job_id} =
             Onchain.create_job(@provider, @evaluator, future_ts())

    # No event signature configured -> the tx hash is the synthetic id,
    # a real 32-byte hash from a mined Anvil transaction.
    assert byte_size(rest) == 64
    assert job_id =~ ~r/^0x[0-9a-f]{64}$/
  end

  test "set_budget and create_memo mine against the deployed stub" do
    {:ok, job_id} = Onchain.create_job(@provider, @evaluator, future_ts())

    assert {:ok, "0x" <> _} = Onchain.set_budget(job_id, Decimal.new("0.50"))

    assert {:ok, "0x" <> _} =
             Onchain.create_memo(job_id, "hello from anvil", :message, false, :negotiation)
  end

  test "sign_memo and claim_budget mine" do
    {:ok, job_id} = Onchain.create_job(@provider, @evaluator, future_ts())
    assert {:ok, "0x" <> _} = Onchain.sign_memo(1, true, "approved")
    assert {:ok, "0x" <> _} = Onchain.claim_budget(job_id)
  end

  # -- Anvil lifecycle --

  defp ensure_foundry! do
    unless System.find_executable("anvil") && System.find_executable("cast") do
      flunk("live_chain tests require foundry (anvil + cast) on PATH")
    end
  end

  defp start_anvil(port) do
    anvil = System.find_executable("anvil")

    port_ref =
      Port.open({:spawn_executable, anvil}, [
        :binary,
        :exit_status,
        args: ["--port", "#{port}", "--silent"]
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    {os_pid, port_ref}
  end

  defp kill(os_pid), do: System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)

  defp wait_until_ready(url, attempts \\ 50)

  defp wait_until_ready(_url, 0), do: flunk("anvil did not become ready")

  defp wait_until_ready(url, attempts) do
    case System.cmd("cast", ["chain-id", "--rpc-url", url], stderr_to_stdout: true) do
      {out, 0} ->
        assert String.trim(out) == "#{@anvil_chain_id}"
        :ok

      _ ->
        Process.sleep(100)
        wait_until_ready(url, attempts - 1)
    end
  end

  defp deploy_stub(url) do
    {out, 0} =
      System.cmd(
        "cast",
        [
          "send",
          "--private-key",
          @anvil_key,
          "--rpc-url",
          url,
          "--json",
          "--create",
          @stub_init_code
        ],
        stderr_to_stdout: true
      )

    %{"contractAddress" => addr} = Jason.decode!(out)
    addr
  end

  defp future_ts, do: System.os_time(:second) + 3600
end
