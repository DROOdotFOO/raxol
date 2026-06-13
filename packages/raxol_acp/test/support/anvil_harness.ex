defmodule Raxol.ACP.Test.AnvilHarness do
  @moduledoc """
  Reusable helper for tests that need a local anvil fork.

  Spawns `anvil --fork-url <url> --port <port> --silent` as a port
  process, waits for the chain to come up, and returns an RPC URL the
  test can hit. The port is cleaned up via `on_exit/1`.

  Used by:

  - `Raxol.ACP.Wallet.SCA.BundlerHarnessTest` (the original caller
    -- it inlines this logic; eventually moves over)
  - `Raxol.ACP.ProviderAdapter.JSONRPCTest`
  - `Raxol.ACP.HookClientLiveTest`

  ## Usage

      defmodule MyTest do
        use ExUnit.Case, async: false

        @moduletag :live_chain

        setup_all do
          %{rpc: Raxol.ACP.Test.AnvilHarness.start!(port: 8601)}
        end

        test "...", %{rpc: rpc} do
          ...
        end
      end

  ## Anvil pre-funded accounts

  Anvil's default mnemonic (`test test test test test test test test
  test test test junk`) yields a deterministic set of EOAs. The first
  three are exposed as `anvil_account/1`:

      Raxol.ACP.Test.AnvilHarness.anvil_account(0)
      # => %{address: "0xf39Fd6...", private_key: <<...>>}

  Each account starts with 10000 ETH. Tests can `anvil_set_balance/3`
  to top up an arbitrary address.
  """

  # First 3 pre-funded anvil accounts (deterministic default mnemonic).
  @anvil_accounts [
    {
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    },
    {
      "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
    },
    {
      "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
    }
  ]

  @doc """
  Spawn an anvil fork. Returns the RPC URL.

  ## Options

  - `:fork_url` -- chain to fork. Default
    `System.get_env("RAXOL_ACP_FORK_URL", "https://mainnet.base.org")`.
  - `:port` -- TCP port for the anvil RPC. Default `8600`. Pass a
    unique port per test module.
  - `:chain_id` -- the chain id to expect from `eth_chainId`. Default
    `8453` (Base).
  """
  @spec start!(keyword()) :: String.t()
  def start!(opts \\ []) do
    ensure_foundry!()

    port = Keyword.get(opts, :port, 8600)
    fork_url = Keyword.get(opts, :fork_url, System.get_env("RAXOL_ACP_FORK_URL", "https://mainnet.base.org"))
    expected_chain_id = Keyword.get(opts, :chain_id, 8453)

    rpc = "http://127.0.0.1:#{port}"
    os_pid = spawn_anvil(fork_url, port)
    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end)

    wait_until_chain_id(rpc, expected_chain_id)
    rpc
  end

  @doc """
  Return one of anvil's pre-funded accounts. `index` is 0-9.
  """
  @spec anvil_account(non_neg_integer()) :: %{address: String.t(), private_key: <<_::256>>}
  def anvil_account(index) do
    {addr, key_hex} = Enum.at(@anvil_accounts, index)
    %{address: addr, private_key: Base.decode16!(key_hex, case: :mixed)}
  end

  @doc "Set the on-fork balance for `address` in wei (hex-encoded)."
  @spec anvil_set_balance(String.t(), String.t(), non_neg_integer()) :: :ok
  def anvil_set_balance(rpc, address, wei) do
    hex = "0x" <> Integer.to_string(wei, 16)
    {_out, 0} = cast(["rpc", "anvil_setBalance", address, hex, "--rpc-url", rpc])
    :ok
  end

  @doc "Run `cast` with the given args; return `{stdout, exit_status}`."
  @spec cast([String.t()]) :: {String.t(), non_neg_integer()}
  def cast(args) do
    {out, code} = System.cmd("cast", args, stderr_to_stdout: true)
    {String.trim(out), code}
  end

  defp ensure_foundry! do
    unless System.find_executable("anvil") && System.find_executable("cast") do
      ExUnit.Assertions.flunk(":live_chain tests require foundry (anvil + cast) on PATH")
    end
  end

  defp spawn_anvil(fork_url, port) do
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

  defp wait_until_chain_id(rpc, expected, attempts \\ 100)

  defp wait_until_chain_id(_rpc, expected, 0),
    do: ExUnit.Assertions.flunk("anvil fork did not become ready (expected chain_id #{expected})")

  defp wait_until_chain_id(rpc, expected, attempts) do
    case cast(["chain-id", "--rpc-url", rpc]) do
      {out, 0} ->
        if String.trim(out) == "#{expected}",
          do: :ok,
          else: retry(rpc, expected, attempts)

      _ ->
        retry(rpc, expected, attempts)
    end
  end

  defp retry(rpc, expected, attempts) do
    Process.sleep(150)
    wait_until_chain_id(rpc, expected, attempts - 1)
  end
end
