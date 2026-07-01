defmodule Raxol.ACP.Job.StateMachinePropertyTest do
  @moduledoc """
  Liveness property behind the escrow-expiry fix (H3).

  A job must never be able to wedge in a non-terminal phase with no way out:
  from ANY state reachable by an arbitrary sequence of events, if the job is
  still non-terminal then `:expire` must always advance it to `:expired`. That
  is what lets the expiry timer un-stick a job whose counterparty abandoned it,
  so escrowed funds can be reclaimed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.ACP.Job.StateMachine

  defp event, do: member_of(StateMachine.events())

  defp walk(events) do
    Enum.reduce(events, StateMachine.initial(), fn e, state ->
      case StateMachine.next(state, e) do
        {:ok, next} -> next
        {:error, _} -> state
      end
    end)
  end

  property "every reachable non-terminal state can always expire to :expired" do
    check all(events <- list_of(event(), max_length: 12)) do
      final = walk(events)

      unless StateMachine.terminal?(final) do
        assert {:ok, :expired} = StateMachine.next(final, :expire),
               "state #{inspect(final)} cannot expire -- a job could wedge here"
      end
    end
  end

  property "a terminal state accepts no further transition" do
    check all(events <- list_of(event(), max_length: 12), extra <- event()) do
      final = walk(events)

      if StateMachine.terminal?(final) do
        assert {:error, {:invalid_transition, ^final, ^extra}} =
                 StateMachine.next(final, extra)
      end
    end
  end
end
