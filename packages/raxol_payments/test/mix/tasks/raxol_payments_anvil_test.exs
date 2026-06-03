defmodule Mix.Tasks.RaxolPayments.AnvilTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.RaxolPayments.Anvil

  describe "anvil_args/1" do
    test "local devchain mode emits --chain-id" do
      args =
        Anvil.anvil_args(
          fork_url: nil,
          anvil_port: 8545,
          block_time: 1,
          chain_id: 31_337
        )

      assert args == ["--port", "8545", "--block-time", "1", "--chain-id", "31337"]
    end

    test "fork mode emits --fork-url instead of --chain-id" do
      args =
        Anvil.anvil_args(
          fork_url: "https://mainnet.base.org",
          anvil_port: 8545,
          block_time: 2,
          chain_id: 31_337
        )

      assert args == [
               "--port",
               "8545",
               "--block-time",
               "2",
               "--fork-url",
               "https://mainnet.base.org"
             ]
    end

    test "respects custom port and block time" do
      args =
        Anvil.anvil_args(
          fork_url: nil,
          anvil_port: 9999,
          block_time: 5,
          chain_id: 1
        )

      assert args == ["--port", "9999", "--block-time", "5", "--chain-id", "1"]
    end
  end

  describe "check_anvil_available/0" do
    test "returns {:error, :anvil_not_found} when anvil is missing from $PATH" do
      with_path("/nonexistent-#{System.unique_integer([:positive])}", fn ->
        assert {:error, :anvil_not_found} = Anvil.check_anvil_available()
      end)
    end
  end

  defp with_path(path, fun) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      fun.()
    after
      if original do
        System.put_env("PATH", original)
      else
        System.delete_env("PATH")
      end
    end
  end
end
