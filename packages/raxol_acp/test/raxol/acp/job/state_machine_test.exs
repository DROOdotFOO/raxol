defmodule Raxol.ACP.Job.StateMachineTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Job.StateMachine

  describe "initial/0" do
    test "is :request" do
      assert StateMachine.initial() == :request
    end
  end

  describe "states/0 and events/0" do
    test "states cover the seven canonical AcpJobPhase values" do
      assert :request in StateMachine.states()
      assert :negotiation in StateMachine.states()
      assert :transaction in StateMachine.states()
      assert :evaluation in StateMachine.states()
      assert :completed in StateMachine.states()
      assert :rejected in StateMachine.states()
      assert :expired in StateMachine.states()
    end

    test "events cover all defined transitions" do
      assert StateMachine.events() == [
               :accept_request,
               :reject,
               :accept_payment,
               :deliver,
               :approve,
               :expire
             ]
    end
  end

  describe "terminal?/1" do
    test "true for :completed, :rejected, and :expired" do
      assert StateMachine.terminal?(:completed)
      assert StateMachine.terminal?(:rejected)
      assert StateMachine.terminal?(:expired)
    end

    test "false for non-terminal states" do
      refute StateMachine.terminal?(:request)
      refute StateMachine.terminal?(:negotiation)
      refute StateMachine.terminal?(:transaction)
      refute StateMachine.terminal?(:evaluation)
    end
  end

  describe ":reject from :request" do
    test "transitions to :rejected" do
      assert StateMachine.next(:request, :reject) == {:ok, :rejected}
    end

    test "is not allowed once past :request" do
      assert {:error, {:invalid_transition, :negotiation, :reject}} =
               StateMachine.next(:negotiation, :reject)

      assert {:error, {:invalid_transition, :transaction, :reject}} =
               StateMachine.next(:transaction, :reject)
    end

    test ":rejected is terminal" do
      assert StateMachine.terminal?(:rejected)

      for event <- StateMachine.events() do
        assert {:error, _} = StateMachine.next(:rejected, event)
      end
    end
  end

  describe "phase_id/1 and from_phase_id/1 (canonical Virtuals enum)" do
    test "round-trips every state" do
      for state <- StateMachine.states() do
        id = StateMachine.phase_id(state)
        assert {:ok, ^state} = StateMachine.from_phase_id(id)
      end
    end

    test "matches the openclaw-acp enum values" do
      assert StateMachine.phase_id(:request) == 0
      assert StateMachine.phase_id(:negotiation) == 1
      assert StateMachine.phase_id(:transaction) == 2
      assert StateMachine.phase_id(:evaluation) == 3
      assert StateMachine.phase_id(:completed) == 4
      assert StateMachine.phase_id(:rejected) == 5
      assert StateMachine.phase_id(:expired) == 6
    end

    test "from_phase_id/1 rejects unknown ids" do
      assert :error = StateMachine.from_phase_id(7)
      assert :error = StateMachine.from_phase_id(-1)
    end
  end

  describe "next/2 forward path" do
    test "request -> negotiation via :accept_request" do
      assert StateMachine.next(:request, :accept_request) == {:ok, :negotiation}
    end

    test "negotiation -> transaction via :accept_payment" do
      assert StateMachine.next(:negotiation, :accept_payment) == {:ok, :transaction}
    end

    test "transaction -> evaluation via :deliver" do
      assert StateMachine.next(:transaction, :deliver) == {:ok, :evaluation}
    end

    test "evaluation -> completed via :approve" do
      assert StateMachine.next(:evaluation, :approve) == {:ok, :completed}
    end

    test "full happy path stitches together" do
      assert {:ok, s1} = StateMachine.next(StateMachine.initial(), :accept_request)
      assert {:ok, s2} = StateMachine.next(s1, :accept_payment)
      assert {:ok, s3} = StateMachine.next(s2, :deliver)
      assert {:ok, :completed} = StateMachine.next(s3, :approve)
    end
  end

  describe "next/2 :expire from non-terminal states" do
    for state <- [:request, :negotiation, :transaction, :evaluation] do
      test "#{state} -> expired via :expire" do
        assert StateMachine.next(unquote(state), :expire) == {:ok, :expired}
      end
    end
  end

  describe "next/2 invalid transitions" do
    test "skipping a step returns invalid_transition" do
      assert {:error, {:invalid_transition, :request, :accept_payment}} =
               StateMachine.next(:request, :accept_payment)

      assert {:error, {:invalid_transition, :request, :deliver}} =
               StateMachine.next(:request, :deliver)
    end

    test "wrong event in negotiation rejected" do
      assert {:error, {:invalid_transition, :negotiation, :deliver}} =
               StateMachine.next(:negotiation, :deliver)
    end

    test "terminal :completed rejects all events" do
      for event <- StateMachine.events() do
        assert {:error, {:invalid_transition, :completed, ^event}} =
                 StateMachine.next(:completed, event)
      end
    end

    test "terminal :expired rejects all events including :expire" do
      for event <- StateMachine.events() do
        assert {:error, {:invalid_transition, :expired, ^event}} =
                 StateMachine.next(:expired, event)
      end
    end
  end
end
