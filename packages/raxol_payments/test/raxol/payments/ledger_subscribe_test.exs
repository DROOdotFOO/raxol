defmodule Raxol.Payments.LedgerSubscribeTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  describe "freeze/unfreeze" do
    setup do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"frz_ledger_#{:erlang.unique_integer([:positive])}")

      on_exit(fn ->
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end)

      %{ledger: ledger, policy: SpendingPolicy.unrestricted()}
    end

    test "starts unfrozen", %{ledger: ledger} do
      refute Ledger.frozen?(ledger)
    end

    test "freeze/1 blocks try_spend with :frozen", %{
      ledger: ledger,
      policy: policy
    } do
      :ok = Ledger.freeze(ledger)
      assert Ledger.frozen?(ledger)

      assert {:over_limit, :frozen} =
               Ledger.try_spend(ledger, :a, Decimal.new("0.01"), policy)
    end

    test "freeze/1 also blocks check_budget", %{ledger: ledger, policy: policy} do
      :ok = Ledger.freeze(ledger)

      assert {:over_limit, :frozen} =
               Ledger.check_budget(ledger, :a, Decimal.new("0.01"), policy)
    end

    test "unfreeze/1 restores normal operation", %{
      ledger: ledger,
      policy: policy
    } do
      :ok = Ledger.freeze(ledger)
      :ok = Ledger.unfreeze(ledger)
      refute Ledger.frozen?(ledger)
      assert :ok = Ledger.try_spend(ledger, :a, Decimal.new("0.01"), policy)
    end

    test "freezing does not block reads", %{ledger: ledger, policy: policy} do
      :ok = Ledger.try_spend(ledger, :a, Decimal.new("0.05"), policy)
      :ok = Ledger.freeze(ledger)

      assert [_entry] = Ledger.get_history(ledger, :a)
    end
  end

  describe "telemetry events" do
    setup do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"tel_ledger_#{:erlang.unique_integer([:positive])}")

      handler_id = :"telemetry_test_#{:erlang.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler_id,
        Raxol.Payments.Telemetry.events(),
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)

        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end)

      %{ledger: ledger}
    end

    test "emits :spend event on successful try_spend", %{ledger: ledger} do
      :ok =
        Ledger.try_spend(
          ledger,
          :tel_a,
          Decimal.new("0.10"),
          SpendingPolicy.unrestricted(),
          %{protocol: "x402"}
        )

      assert_receive {:telemetry, [:raxol, :payments, :spend], measurements, metadata}

      assert Decimal.equal?(measurements.amount, Decimal.new("0.10"))
      assert metadata.agent_id == :tel_a
      assert metadata.currency == "USDC"
      assert metadata.metadata.protocol == "x402"
    end

    test "emits :over_budget event on cap breach", %{ledger: ledger} do
      policy = %SpendingPolicy{
        per_request_max: Decimal.new("0.01"),
        session_max: Decimal.new("10"),
        lifetime_max: Decimal.new("10")
      }

      assert {:over_limit, :per_request} =
               Ledger.try_spend(ledger, :tel_b, Decimal.new("1.00"), policy)

      assert_receive {:telemetry, [:raxol, :payments, :over_budget], measurements, metadata}

      assert Decimal.equal?(measurements.amount, Decimal.new("1.00"))
      assert metadata.limit_type == :per_request
    end

    test "emits :over_budget with :frozen when frozen", %{ledger: ledger} do
      :ok = Ledger.freeze(ledger)

      assert {:over_limit, :frozen} =
               Ledger.try_spend(
                 ledger,
                 :tel_c,
                 Decimal.new("0.01"),
                 SpendingPolicy.unrestricted()
               )

      assert_receive {:telemetry, [:raxol, :payments, :over_budget], _, %{limit_type: :frozen}}
    end

    test "emits :freeze event on freeze/unfreeze", %{ledger: ledger} do
      :ok = Ledger.freeze(ledger)

      assert_receive {:telemetry, [:raxol, :payments, :freeze], _, %{frozen?: true}}

      :ok = Ledger.unfreeze(ledger)

      assert_receive {:telemetry, [:raxol, :payments, :freeze], _, %{frozen?: false}}
    end
  end

  setup do
    {:ok, ledger} =
      Ledger.start_link(table_name: :"sub_ledger_#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      try do
        GenServer.stop(ledger)
      catch
        :exit, _ -> :ok
      end
    end)

    %{ledger: ledger, policy: SpendingPolicy.unrestricted()}
  end

  test "subscribe/2 delivers ledger entries from try_spend", %{
    ledger: ledger,
    policy: policy
  } do
    :ok = Ledger.subscribe(ledger)

    :ok =
      Ledger.try_spend(ledger, :agent_a, Decimal.new("0.10"), policy, %{
        protocol: "x402"
      })

    assert_receive {:ledger_entry, entry}
    assert entry.agent_id == :agent_a
    assert Decimal.equal?(entry.amount, Decimal.new("0.10"))
    assert entry.metadata.protocol == "x402"
  end

  test "subscribe/2 delivers entries from record_spend (cast path)", %{
    ledger: ledger
  } do
    :ok = Ledger.subscribe(ledger)

    :ok =
      Ledger.record_spend(ledger, :agent_b, Decimal.new("0.05"), %{to: "0xabc"})

    assert_receive {:ledger_entry, entry}, 200
    assert entry.agent_id == :agent_b
    assert Decimal.equal?(entry.amount, Decimal.new("0.05"))
  end

  test "agent_id filter only delivers matching entries", %{
    ledger: ledger,
    policy: policy
  } do
    :ok = Ledger.subscribe(ledger, agent_id: :only_me)
    :ok = Ledger.try_spend(ledger, :someone_else, Decimal.new("0.01"), policy)
    refute_receive {:ledger_entry, _}, 50

    :ok = Ledger.try_spend(ledger, :only_me, Decimal.new("0.01"), policy)
    assert_receive {:ledger_entry, entry}
    assert entry.agent_id == :only_me
  end

  test "subscriber DOWN cleans up state without crashing the ledger", %{
    ledger: ledger,
    policy: policy
  } do
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Ledger.subscribe(ledger)
        send(parent, :subscribed)

        receive do
          :die -> exit(:normal)
        end
      end)

    assert_receive :subscribed
    send(subscriber, :die)

    # Give the DOWN message time to land.
    Process.sleep(20)

    # Ledger should still be alive and operational.
    assert :ok =
             Ledger.try_spend(ledger, :post_down, Decimal.new("0.01"), policy)

    assert Process.alive?(ledger)
  end
end
