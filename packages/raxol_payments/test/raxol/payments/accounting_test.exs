defmodule Raxol.Payments.AccountingTest do
  # async: false -- reads/writes process-global OS env vars.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Accounting

  @env_vars ~w(
    RAXOL_ACCOUNTING_ENABLED
    RPC_ETH RPC_OPTIMISM RPC_POLYGON RPC_BASE RPC_ARBITRUM RPC_ROBINHOOD
    XOCHI_SOLVER_ADDRESS RAXOL_REBALANCE_INTERVAL_MS RAXOL_PRICE_SOURCE
    RAXOL_REBALANCE_DEMAND_MULTIPLIER RAXOL_REBALANCE_DEMAND_FLOOR_CAP
    RAXOL_REBALANCE_DEMAND_WINDOW_MS
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

    test "a blank solver address is unset, not the empty address" do
      # `Raxol.Earn.Supervisor` branches on truthiness to decide whether to start
      # the RebalanceMonitor, and `""` is truthy in Elixir -- so a blank var would
      # start the monitor reading balances for the empty address.
      System.put_env("XOCHI_SOLVER_ADDRESS", "  ")

      {opts, _} = Accounting.env_config()

      assert opts[:solver_address] == nil
    end

    test "the demand knobs are passed through raw for the policy to parse" do
      # This module deliberately does not parse them: `RebalancePolicy` owns the
      # pair rule, and it can only enforce it if it sees BOTH keys every time.
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")

      {opts, _} = Accounting.env_config()

      assert Keyword.fetch(opts, :demand_multiplier) == {:ok, "2"}
      assert Keyword.fetch(opts, :demand_floor_cap) == {:ok, nil}
    end
  end

  describe "the sweep interval" do
    test "a blank value is unset, matching how the RPC vars read" do
      # `String.to_integer("")` used to crash the boot here, naming nothing.
      System.put_env("RAXOL_REBALANCE_INTERVAL_MS", "")

      {opts, _} = Accounting.env_config()

      assert opts[:rebalance_interval_ms] == 300_000
    end

    test "a malformed or non-positive value names the variable it came from" do
      for value <- ["5 minutes", "0", "-1", "300000ms"] do
        System.put_env("RAXOL_REBALANCE_INTERVAL_MS", value)

        assert_raise ArgumentError, ~r/RAXOL_REBALANCE_INTERVAL_MS/, fn ->
          Accounting.env_config()
        end
      end
    end
  end

  describe "the price source" do
    test "defaults to coingecko, and reads the sources the monitor knows" do
      {opts, _} = Accounting.env_config()
      assert opts[:price_source] == :coingecko

      for {value, expected} <- [{"coingecko", :coingecko}, {"none", :none}] do
        System.put_env("RAXOL_PRICE_SOURCE", value)
        {opts, _} = Accounting.env_config()
        assert opts[:price_source] == expected
      end
    end

    test "a blank value is unset, not the atom :\"\"" do
      # `String.to_atom("")` used to yield `:""`, which falls through
      # `RebalanceMonitor.build_price_fn/1`'s catch-all to a price fn returning
      # nil -- silently dropping USD pricing from the whole sweep.
      System.put_env("RAXOL_PRICE_SOURCE", "")

      {opts, _} = Accounting.env_config()

      assert opts[:price_source] == :coingecko
    end

    test "an unrecognized source is refused rather than silently pricing nothing" do
      for value <- ["gecko", "coingeko", "CoinGecko"] do
        System.put_env("RAXOL_PRICE_SOURCE", value)

        assert_raise ArgumentError, ~r/RAXOL_PRICE_SOURCE/, fn ->
          Accounting.env_config()
        end
      end
    end
  end

  describe "the demand window" do
    test "defaults to a day, and reads a set value" do
      {opts, _} = Accounting.env_config()
      assert opts[:demand_window_ms] == 86_400_000

      System.put_env("RAXOL_REBALANCE_DEMAND_WINDOW_MS", "3600000")
      {opts, _} = Accounting.env_config()
      assert opts[:demand_window_ms] == 3_600_000
    end

    test "a blank value is unset, matching how the RPC vars read" do
      System.put_env("RAXOL_REBALANCE_DEMAND_WINDOW_MS", "")

      {opts, _} = Accounting.env_config()

      assert opts[:demand_window_ms] == 86_400_000
    end

    test "a malformed value names the variable it came from" do
      # The var is documented as optional, so an operator who typos it gets a
      # boot crash naming nothing unless the reader says which knob it was.
      System.put_env("RAXOL_REBALANCE_DEMAND_WINDOW_MS", "24h")

      assert_raise ArgumentError, ~r/RAXOL_REBALANCE_DEMAND_WINDOW_MS/, fn ->
        Accounting.env_config()
      end
    end

    test "a non-positive window is refused, as the spec claims" do
      for value <- ["0", "-1"] do
        System.put_env("RAXOL_REBALANCE_DEMAND_WINDOW_MS", value)

        assert_raise ArgumentError, ~r/RAXOL_REBALANCE_DEMAND_WINDOW_MS/, fn ->
          Accounting.env_config()
        end
      end
    end
  end
end
