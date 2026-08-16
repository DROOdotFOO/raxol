defmodule Raxol.Payments.LedgerConcurrentPropertyTest do
  @moduledoc """
  Concurrent property: `Ledger.try_spend/5` must be atomic against the
  policy caps even under parallel pressure. We spawn N tasks that all
  attempt small spends against the same agent simultaneously, then
  assert the cumulative accepted total never exceeded `lifetime_max`
  or `session_max`.

  The Ledger is a GenServer, which serializes calls -- so this property
  should hold today. It's here to catch any future refactor that
  introduces a check/record gap (e.g. moving check_budget to a separate
  call to "optimize" throughput).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  defp policy(per_req, lifetime) do
    %SpendingPolicy{
      per_request_max: Decimal.new(per_req),
      session_max: Decimal.new(lifetime),
      lifetime_max: Decimal.new(lifetime),
      session_window_ms: 3_600_000
    }
  end

  defp run_concurrently(ledger, agent_id, policy, attempts) do
    attempts
    |> Task.async_stream(
      fn amount ->
        Ledger.try_spend(ledger, agent_id, amount, policy)
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 5_000
    )
    |> Enum.reduce(Decimal.new(0), fn
      {:ok, :ok}, acc ->
        # We don't know the amount from :ok alone; recover via history below.
        acc

      {:ok, {:over_limit, _}}, acc ->
        acc

      {:exit, _}, acc ->
        acc
    end)
    |> then(fn _ ->
      # Authoritative total: sum the recorded ledger history for the agent.
      ledger
      |> Ledger.get_history(agent_id)
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
    end)
  end

  property "concurrent try_spend never pushes recorded total over lifetime_max" do
    # Realistic-ish scenario: per-request small enough that many fit, lifetime
    # tight enough that not all attempts can succeed.
    check all(
            attempt_count <- integer(20..80),
            per_req <- integer(5..20),
            lifetime <- integer(50..200)
          ) do
      ledger =
        case Ledger.start_link(table_name: :"conc_ledger_#{:erlang.unique_integer([:positive])}") do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      try do
        attempts = for _ <- 1..attempt_count, do: Decimal.new(per_req)

        recorded =
          run_concurrently(
            ledger,
            :conc_agent,
            policy(per_req, lifetime),
            attempts
          )

        assert Decimal.compare(recorded, Decimal.new(lifetime)) != :gt,
               "concurrent recorded total #{Decimal.to_string(recorded)} exceeded lifetime cap #{lifetime}"
      after
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  property "concurrent attempts on a frozen ledger record nothing" do
    check all(
            attempt_count <- integer(10..40),
            amount <- integer(1..10)
          ) do
      ledger =
        case Ledger.start_link(table_name: :"frz_conc_#{:erlang.unique_integer([:positive])}") do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      try do
        :ok = Ledger.freeze(ledger)

        attempts = for _ <- 1..attempt_count, do: Decimal.new(amount)

        results =
          attempts
          |> Task.async_stream(
            fn a ->
              Ledger.try_spend(
                ledger,
                :frz_conc,
                a,
                SpendingPolicy.unrestricted()
              )
            end,
            max_concurrency: System.schedulers_online() * 2,
            ordered: false
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert Enum.all?(results, &(&1 == {:over_limit, :frozen}))
        assert Ledger.get_history(ledger, :frz_conc) == []
      after
        try do
          GenServer.stop(ledger)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end
end
