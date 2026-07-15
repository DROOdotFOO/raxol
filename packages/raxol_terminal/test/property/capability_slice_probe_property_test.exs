defmodule Raxol.Terminal.CapabilitySliceProbePropertyTest do
  @moduledoc """
  Probe fuzz: CAP-F-04 -- termination. For any finite event list mixing
  `{:input, bytes}` with monotonic `{:clock, _}` events, the reducer is
  `{:done, _}` after the first clock past the (at-most-once extended)
  deadline, stays done (idempotent), and never requests a second
  extension. No real clock, no sleeps.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.Probe
  alias Raxol.Test.CapabilitySliceGen, as: Gen

  @runs 500
  @budget 100

  test "CAP-F-04: termination, single extension, idempotence" do
    for i <- 1..@runs do
      Gen.seed(i)

      probe = Probe.new(%{}, budget_ms: @budget, extend_ms: @budget)
      {probe, _} = Probe.step(probe, :start)

      # a random prefix of input events (noise or well-formed replies)
      # and interior clock events below the maximum possible deadline
      events =
        for _ <- 1..(:rand.uniform(6) - 1)//1 do
          case :rand.uniform(3) do
            1 -> {:input, Gen.noise(32)}
            2 -> {:input, elem(Gen.reply(), 0)}
            3 -> {:clock, :rand.uniform(@budget * 2)}
          end
        end

      {probe, all_actions} =
        Enum.reduce(events, {probe, []}, fn event, {p, actions} ->
          {p, new_actions} = Probe.step(p, event)
          {p, actions ++ new_actions}
        end)

      # the reducer never grants a second extension
      extension_count =
        Enum.count(all_actions, &match?({:extend_deadline, _}, &1))

      assert extension_count <= 1, "iteration #{i}: multiple extensions"

      # one clock past the maximum possible deadline forces :done
      {probe, _} = Probe.step(probe, {:clock, @budget * 2 + 1})
      assert {:done, caps} = Probe.result(probe)

      # done is a fixed point: further events cannot change the outcome
      {probe, _} = Probe.step(probe, {:input, Gen.noise(16)})
      {probe, _} = Probe.step(probe, {:clock, @budget * 10})
      assert {:done, ^caps} = Probe.result(probe)
    end
  end
end
