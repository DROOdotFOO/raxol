defmodule Raxol.Payments.AccountingTest do
  # async: false -- reads/writes process-global OS env vars.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Accounting

  @env_vars ~w(
    RAXOL_ACCOUNTING_ENABLED
    RPC_ETH RPC_OPTIMISM RPC_POLYGON RPC_BASE RPC_ARBITRUM RPC_ROBINHOOD
    XOCHI_SOLVER_ADDRESS RAXOL_REBALANCE_INTERVAL_MS RAXOL_PRICE_SOURCE
  )

  setup do
    saved = Map.new(@env_vars, fn v -> {v, System.get_env(v)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)
    end)

    :ok
  end

  describe "enabled?/0" do
    test "true only when RAXOL_ACCOUNTING_ENABLED is exactly \"true\"" do
      refute Accounting.enabled?()

      System.put_env("RAXOL_ACCOUNTING_ENABLED", "true")
      assert Accounting.enabled?()

      for other <- ["false", "1", "TRUE", "yes", ""] do
        System.put_env("RAXOL_ACCOUNTING_ENABLED", other)
        refute Accounting.enabled?(), "#{inspect(other)} must not enable accounting"
      end
    end
  end

  describe "env_config/0" do
    test "defaults: empty rpc map, nil solver, 5-min interval, coingecko" do
      {opts, enabled?} = Accounting.env_config()

      refute enabled?
      assert opts[:rpc_urls] == %{}
      assert opts[:solver_address] == nil
      assert opts[:rebalance_interval_ms] == 300_000
      assert opts[:price_source] == :coingecko
    end

    test "maps each RPC env var to its chain id, dropping unset/blank ones" do
      System.put_env("RPC_ETH", "https://eth.example")
      System.put_env("RPC_BASE", "https://base.example")
      System.put_env("RPC_ROBINHOOD", "https://rh.example")
      # blank must be treated as unset
      System.put_env("RPC_POLYGON", "")

      {opts, _} = Accounting.env_config()

      assert opts[:rpc_urls] == %{
               1 => "https://eth.example",
               8453 => "https://base.example",
               4663 => "https://rh.example"
             }
    end

    test "reads solver address, interval, price source, and the enabled flag" do
      System.put_env("RAXOL_ACCOUNTING_ENABLED", "true")
      System.put_env("XOCHI_SOLVER_ADDRESS", "0x97D4")
      System.put_env("RAXOL_REBALANCE_INTERVAL_MS", "60000")
      System.put_env("RAXOL_PRICE_SOURCE", "none")

      {opts, enabled?} = Accounting.env_config()

      assert enabled?
      assert opts[:solver_address] == "0x97D4"
      assert opts[:rebalance_interval_ms] == 60_000
      assert opts[:price_source] == :none
    end
  end
end
