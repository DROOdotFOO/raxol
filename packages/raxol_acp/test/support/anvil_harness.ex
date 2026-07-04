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
  Start (or attach to) an anvil fork. Returns the RPC URL.

  By default spawns its own `anvil --fork-url ...` and cleans it up on exit. To
  reuse an already-running fork instead (e.g. a persistent anvil in an OrbStack
  container), set `RAXOL_ACP_ANVIL_RPC` to its RPC URL -- the harness attaches to
  it (verifying the chain id), spawns nothing, and leaves it running.

  ## Options

  - `:fork_url` -- chain to fork when spawning. Default
    `System.get_env("RAXOL_ACP_FORK_URL", "https://mainnet.base.org")`.
  - `:port` -- TCP port for the spawned anvil RPC. Default `8600`. Pass a
    unique port per test module.
  - `:chain_id` -- the chain id to expect from `eth_chainId`. Default
    `8453` (Base).
  """
  @spec start!(keyword()) :: String.t()
  def start!(opts \\ []) do
    expected_chain_id = Keyword.get(opts, :chain_id, 8453)

    rpc =
      case System.get_env("RAXOL_ACP_ANVIL_RPC") do
        nil -> spawn_fork(opts)
        external -> reuse_fork(external)
      end

    wait_until_chain_id(rpc, expected_chain_id)
    rpc
  end

  # Spawn our own anvil fork (the default). Needs anvil + cast on PATH.
  defp spawn_fork(opts) do
    ensure_binary!("anvil")
    ensure_binary!("cast")

    port = Keyword.get(opts, :port, 8600)

    fork_url =
      Keyword.get(
        opts,
        :fork_url,
        System.get_env("RAXOL_ACP_FORK_URL", "https://mainnet.base.org")
      )

    os_pid = spawn_anvil(fork_url, port)

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end)

    "http://127.0.0.1:#{port}"
  end

  # Reuse an already-running anvil fork named by RAXOL_ACP_ANVIL_RPC (e.g. a
  # persistent fork in an OrbStack container). We neither spawn nor kill it; only
  # `cast` is needed on PATH to talk to it.
  defp reuse_fork(rpc) do
    ensure_binary!("cast")
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

  @doc """
  Deal ERC-20 `amount` (base units) to `holder` on the fork by overwriting the
  token's `balanceOf[holder]` storage slot.

  `balance_slot` is the storage slot index of the `balances` mapping (Circle
  FiatToken USDC uses slot 9). The slot for `holder` is `cast index address
  holder balance_slot`. Verify with `erc20_balance/3` after -- a wrong slot
  leaves the balance unchanged.
  """
  @spec deal_erc20(String.t(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok
  def deal_erc20(rpc, token, holder, amount, balance_slot) do
    {slot, 0} = cast(["index", "address", holder, "#{balance_slot}"])
    value = "0x" <> (amount |> Integer.to_string(16) |> String.pad_leading(64, "0"))
    {_out, 0} = cast(["rpc", "anvil_setStorageAt", token, slot, value, "--rpc-url", rpc])
    :ok
  end

  @doc "Read an ERC-20 `balanceOf(holder)` on the fork, as an integer (base units)."
  @spec erc20_balance(String.t(), String.t(), String.t()) :: non_neg_integer()
  def erc20_balance(rpc, token, holder) do
    {out, 0} = cast(["call", token, "balanceOf(address)(uint256)", holder, "--rpc-url", rpc])
    parse_uint(out)
  end

  @doc "Read a no-arg `uint256` view function (e.g. `jobCounter()(uint256)`) on the fork."
  @spec read_uint(String.t(), String.t(), String.t()) :: non_neg_integer()
  def read_uint(rpc, to, signature) do
    {out, 0} = cast(["call", to, signature, "--rpc-url", rpc])
    parse_uint(out)
  end

  @doc "Assert a transaction succeeded (receipt status 1); flunk with the status otherwise."
  @spec assert_tx_success!(String.t(), String.t()) :: :ok
  def assert_tx_success!(rpc, tx_hash) do
    {status, 0} = cast(["receipt", tx_hash, "status", "--rpc-url", rpc])

    # `cast receipt <tx> status` prints e.g. "1 (success)" / "0 (failure)"; the
    # leading token is the raw status.
    leading = status |> String.trim() |> String.split() |> List.first()

    if leading in ["1", "0x1"] do
      :ok
    else
      ExUnit.Assertions.flunk("tx #{tx_hash} reverted (status #{status})")
    end
  end

  # `cast call ...(uint256)` prints the decoded decimal (occasionally with a
  # trailing scientific-notation annotation); take the leading token.
  defp parse_uint(out) do
    token = out |> String.trim() |> String.split() |> List.first() || "0"

    case token do
      "0x" <> hex -> String.to_integer(hex, 16)
      dec -> String.to_integer(dec)
    end
  end

  defp ensure_binary!(bin) do
    unless System.find_executable(bin) do
      ExUnit.Assertions.flunk(":live_chain tests require #{bin} on PATH (install foundry)")
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
