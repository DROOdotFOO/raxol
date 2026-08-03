defmodule Raxol.Symphony.PauseReasonConventionTest do
  @moduledoc """
  ADR-0018 §1 mechanical enforcement: every interrupt-reason atom a
  runner declares via the optional `Raxol.Symphony.Runner.pause_reasons/0`
  callback, AND every atom in `Raxol.Earn.Job.Workflow.pause_reasons/0`,
  MUST satisfy `Raxol.Symphony.PauseReason.awaiting?/1`.

  The convention is `:awaiting_<subject>` where `<subject>` names the
  *external party* the run is waiting on. This test catches typos
  (`:awating_review`), shape drift (`:waiting_for_X`), and bare
  `:awaiting_` (missing subject) at PR time -- the ADR is otherwise
  enforced only by code review.
  """

  use ExUnit.Case, async: true

  alias Raxol.Symphony.{PauseReason, Runner}

  # Runners shipped in the repo. Anything that implements the optional
  # pause_reasons/0 callback is checked.
  @runners [
    Raxol.Symphony.Runners.Codex,
    Raxol.Symphony.Runners.Noop,
    Raxol.Symphony.Runners.RaxolAgent
  ]

  defp runner_pause_reasons(runner) do
    Code.ensure_loaded(runner)

    if function_exported?(runner, :pause_reasons, 0) do
      {:ok, apply(runner, :pause_reasons, [])}
    else
      :none
    end
  end

  describe "Symphony runner pause_reasons/0" do
    for runner <- @runners do
      @runner runner

      test "#{inspect(runner)}: every declared reason matches :awaiting_<subject>" do
        case runner_pause_reasons(@runner) do
          {:ok, atoms} ->
            assert is_list(atoms), "#{inspect(@runner)}.pause_reasons/0 must return a list"

            for atom <- atoms do
              assert is_atom(atom),
                     "#{inspect(@runner)} declared a non-atom pause reason: #{inspect(atom)}"

              assert PauseReason.awaiting?(atom),
                     "#{inspect(@runner)} declared reason #{inspect(atom)} that violates ADR-0018 §1 (:awaiting_<subject>)"
            end

          :none ->
            # Runner does not declare pause_reasons/0; the convention
            # is enforced caller-side for these runners.
            :ok
        end
      end
    end

    test "at least one shipped runner declares pause_reasons/0" do
      # Sanity: if every runner stopped declaring its vocabulary the
      # test above becomes a no-op. Keep at least one anchor.
      implementing =
        Enum.filter(@runners, fn r ->
          match?({:ok, _}, runner_pause_reasons(r))
        end)

      assert implementing != [],
             "no shipped runner implements the optional " <>
               "Raxol.Symphony.Runner.pause_reasons/0 callback; ADR-0018 §1 has no mechanical enforcement"
    end

    test "the callback is declared as optional on the behaviour" do
      callbacks = Runner.behaviour_info(:optional_callbacks)
      assert {:pause_reasons, 0} in callbacks
    end
  end

  describe "Raxol.Earn.Job.Workflow.pause_reasons/0" do
    test "every atom matches :awaiting_<subject>" do
      if Code.ensure_loaded?(Raxol.Earn.Job.Workflow) do
        atoms = Raxol.Earn.Job.Workflow.pause_reasons()

        for atom <- atoms do
          assert PauseReason.awaiting?(atom),
                 "ACP Job.Workflow declared reason #{inspect(atom)} that violates ADR-0018 §1"
        end
      end
    end

    test "the four canonical ACP reasons are present" do
      if Code.ensure_loaded?(Raxol.Earn.Job.Workflow) do
        atoms = Raxol.Earn.Job.Workflow.pause_reasons()

        expected = [
          :awaiting_request_response,
          :awaiting_buyer_payment,
          :awaiting_delivery,
          :awaiting_evaluator_approval
        ]

        for atom <- expected do
          assert atom in atoms,
                 "ACP Job.Workflow.pause_reasons/0 must include #{inspect(atom)}"
        end
      end
    end
  end

  describe "PauseReason.canonical/0 vs runner declarations" do
    test "every shipped runner's declared reasons appear in PauseReason.canonical/0" do
      # ADR-0018 §1 says the canonical list is the union of every
      # runner's documented reasons. Drift between runner declarations
      # and PauseReason.canonical/0 means a new pause reason landed
      # without updating the canonical list (or vice versa).
      canonical_set = MapSet.new(PauseReason.canonical())

      declared_set =
        @runners
        |> Enum.flat_map(fn r ->
          case runner_pause_reasons(r) do
            {:ok, atoms} -> atoms
            :none -> []
          end
        end)
        |> MapSet.new()

      missing = MapSet.difference(declared_set, canonical_set)

      assert MapSet.size(missing) == 0,
             "runners declare reasons missing from PauseReason.canonical/0: #{inspect(MapSet.to_list(missing))}"
    end
  end
end
