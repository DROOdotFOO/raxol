defmodule Raxol.Property.BackpressureOrderingTest do
  @moduledoc """
  Pins the ordering invariant from ADR-0013: messages routed through
  `Raxol.Core.Runtime.Backpressure.cast/3` arrive at the target in send
  order, regardless of whether the helper chose a cast or a call.

  Single-caller per-process FIFO is an Erlang guarantee; this test
  catches future refactors of the helper that would reorder messages
  (e.g., by sending via a spawned process).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Test.BackpressureTarget, as: TestTarget

  defp drain_target(target) do
    Process.sleep(20)
    TestTarget.received(target)
  end

  describe ":call_when_full" do
    property "messages arrive in send order under nominal load" do
      check all(
              msgs <- list_of(integer(), min_length: 1, max_length: 50),
              max_runs: 30
            ) do
        {:ok, target} = TestTarget.start_link()

        Enum.each(msgs, fn n ->
          assert :ok =
                   Backpressure.cast(target, {:msg, n},
                     label: :prop_call,
                     policy: :call_when_full,
                     # High watermark keeps the helper on the cast path
                     # for nominal-load ordering verification.
                     watermark: 100_000
                   )
        end)

        received = drain_target(target)
        GenServer.stop(target)

        assert received == msgs
      end
    end
  end

  describe ":drop_when_full" do
    property "delivered messages arrive in send order under nominal load" do
      check all(
              msgs <- list_of(integer(), min_length: 1, max_length: 50),
              max_runs: 30
            ) do
        {:ok, target} = TestTarget.start_link()

        results =
          Enum.map(msgs, fn n ->
            {n,
             Backpressure.cast(target, {:msg, n},
               label: :prop_drop,
               policy: :drop_when_full,
               watermark: 100_000
             )}
          end)

        delivered_in_send_order = for {n, :ok} <- results, do: n
        received = drain_target(target)
        GenServer.stop(target)

        assert received == delivered_in_send_order
      end
    end
  end

  describe "mixed policy stream" do
    property "send order is preserved across policy switches" do
      check all(
              ops <-
                list_of(
                  tuple({
                    integer(),
                    member_of([:call_when_full, :drop_when_full])
                  }),
                  min_length: 1,
                  max_length: 40
                ),
              max_runs: 30
            ) do
        {:ok, target} = TestTarget.start_link()

        Enum.each(ops, fn {n, policy} ->
          assert :ok =
                   Backpressure.cast(target, {:msg, n},
                     label: :prop_mixed,
                     policy: policy,
                     watermark: 100_000
                   )
        end)

        received = drain_target(target)
        GenServer.stop(target)

        assert received == Enum.map(ops, fn {n, _} -> n end)
      end
    end
  end
end
