defmodule Raxol.Earn.AccountingBootTest do
  @moduledoc """
  The demand knobs from the OS environment all the way to the supervisor that
  reads them, with nothing hand-assembled in between.

  A unit test on `RebalancePolicy.with_demand/2` is necessary and was not
  sufficient: the guard was dead for two releases while its unit tests passed,
  because every one of them passed a keyword list with one key ENTIRELY ABSENT
  and no caller in this repo constructs that. `Accounting.env_config/0` calls
  `System.get_env/1` for both knobs unconditionally, so the shape production
  actually produces is one key set and the other PRESENT as nil. This file
  starts at `System.put_env/2` so it cannot describe a shape that does not
  occur.
  """

  # async: false -- reads/writes process-global OS env and Application env.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Accounting
  alias Raxol.Payments.RebalancePolicy

  @env_vars ~w(
    RAXOL_REBALANCE_DEMAND_MULTIPLIER RAXOL_REBALANCE_DEMAND_FLOOR_CAP
    XOCHI_SOLVER_ADDRESS RPC_BASE
  )

  setup do
    saved_env = Map.new(@env_vars, fn v -> {v, System.get_env(v)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    saved_accounting = Application.get_env(:raxol_payments, :accounting)
    saved_enabled = Application.get_env(:raxol_earn, :accounting_enabled)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)

      restore(:raxol_payments, :accounting, saved_accounting)
      restore(:raxol_earn, :accounting_enabled, saved_enabled)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # What `packages/raxol_earn/config/runtime.exs` does at boot, verbatim: read the
  # env contract once and publish it as the two config values the tree reads.
  defp boot_config do
    {accounting_opts, accounting_enabled} = Accounting.env_config()
    Application.put_env(:raxol_payments, :accounting, accounting_opts)
    Application.put_env(:raxol_earn, :accounting_enabled, accounting_enabled)
    accounting_opts
  end

  describe "a half-configured demand pair, from the environment" do
    setup do
      System.put_env("RAXOL_ACCOUNTING_ENABLED", "true")
      System.put_env("XOCHI_SOLVER_ADDRESS", "0x97D4")
      System.put_env("RPC_BASE", "https://base.example")
      on_exit(fn -> System.delete_env("RAXOL_ACCOUNTING_ENABLED") end)
      :ok
    end

    test "env_config emits the multiplier alongside an explicitly nil cap" do
      # The shape every pair-guard unit test used to miss. Asserting it here
      # pins the reason the absent-key shape is not the production one.
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")

      opts = boot_config()

      assert Keyword.fetch(opts, :demand_multiplier) == {:ok, "2"}
      assert Keyword.fetch(opts, :demand_floor_cap) == {:ok, nil}
    end

    test "the supervisor refuses to build its tree with only a multiplier set" do
      # `Raxol.Earn.Supervisor.init/1` is where the accounting children are
      # assembled, and `with_demand/2` runs there. A refusal here is a boot
      # failure, which is the whole point: the alternative outcome is static
      # floors from a deployment that looks configured for demand-aware ones.
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")
      boot_config()

      assert_raise ArgumentError, ~r/without :demand_floor_cap/, fn ->
        Raxol.Earn.Supervisor.init([])
      end
    end

    test "the supervisor refuses with only a cap set, too" do
      System.put_env("RAXOL_REBALANCE_DEMAND_FLOOR_CAP", "500")
      boot_config()

      assert_raise ArgumentError, ~r/without :demand_multiplier/, fn ->
        Raxol.Earn.Supervisor.init([])
      end
    end

    test "a set-but-empty half is refused like an unset one" do
      # `FOO=` is what a fly.toml or a cleared secret leaves behind. It reaches
      # the policy as `""`, which normalizes to nil -- the same state as never
      # having set it, and therefore the same refusal.
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")
      System.put_env("RAXOL_REBALANCE_DEMAND_FLOOR_CAP", "")
      boot_config()

      assert_raise ArgumentError, ~r/without :demand_floor_cap/, fn ->
        Raxol.Earn.Supervisor.init([])
      end
    end

    test "both knobs together boot, and the tree carries a demand-aware policy" do
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")
      System.put_env("RAXOL_REBALANCE_DEMAND_FLOOR_CAP", "500")
      opts = boot_config()

      assert {:ok, {_flags, _children}} = Raxol.Earn.Supervisor.init([])
      assert RebalancePolicy.demand_aware?(RebalancePolicy.with_demand(default(), opts))
    end

    test "neither knob boots with static floors" do
      opts = boot_config()

      assert {:ok, {_flags, _children}} = Raxol.Earn.Supervisor.init([])
      refute RebalancePolicy.demand_aware?(RebalancePolicy.with_demand(default(), opts))
    end
  end

  describe "the one-shot sweep reads the same environment" do
    # `env_config/0` parses nothing while accounting is off, so the gate has to
    # be ON for there to be a pair to half-configure at all. Without this the
    # test passed for the wrong reason once that gating landed: no opts, so no
    # pair, so no raise.
    setup do
      System.put_env("RAXOL_ACCOUNTING_ENABLED", "true")
      System.put_env("XOCHI_SOLVER_ADDRESS", "0x97D4")
      on_exit(fn -> System.delete_env("RAXOL_ACCOUNTING_ENABLED") end)
      :ok
    end

    test "a half-configured pair fails the task the way it fails a boot" do
      # `mix raxol_earn.rebalance` builds its policy from the same env contract,
      # so it must not accept config the release refuses.
      System.put_env("RAXOL_REBALANCE_DEMAND_MULTIPLIER", "2")
      {opts, _} = Accounting.env_config()

      assert_raise ArgumentError, ~r/without :demand_floor_cap/, fn ->
        Mix.Tasks.RaxolEarn.Rebalance.resolve_policy(opts, [])
      end
    end
  end

  defp default, do: RebalancePolicy.default()
end
